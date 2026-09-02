"""`postgres.result` — the rows a query returned, and the typed accessors.

`Connection.query` hands back a `Result`: an owned `PGresult` plus the column
metadata read out of it once.  Cells are read on demand -- libpq has already
materialised the whole result set in its own memory, so there is nothing to be
gained by copying it eagerly, and a `Result` costs one `PQclear` no matter how
many rows it holds.

`Row` is the other half, and it is a **snapshot**: `Result.row` copies one
row's cells into owned `String`s, so the `Row` stays valid after the `Result`
that produced it is destroyed.  That is what makes

```mojo
def newest(mut conn: Connection) raises -> Row:
    var res = conn.query("SELECT id, name FROM t ORDER BY id DESC LIMIT 1")
    return res.row(0)          # `res` is cleared here; the Row survives
```

work, and it is why `for row in res:` yields values rather than references.
Column *names* would be expensive to copy per row, so both types share one
`ArcPointer[_Columns]` -- the names and OIDs, read once from the `PGresult`.

**Typed accessors do not check the column's OID.**  `row.int64("n")` parses
the cell's text as an `int8` whatever the server called it, because the
contract is "you asked for int64, we parse the text as int64"; a mismatch
surfaces as the codec's own error, which names both the type and the offending
text (``postgres.text: invalid int8 text: 'abc'``).  Call `column_oid` first if
you would rather dispatch on what the server actually sent.

**NULL is not the empty string.**  libpq renders both as ``""``; `is_null` is
the only thing that separates them.  Every typed accessor raises on NULL, so a
nullable column is read with `Row.is_null` first, or with `Row.opt_text`.
"""

from std.memory import ArcPointer

from ._ffi import LibpqFFI, PGresultPtr, libpq
from .text import (
    decode_bool,
    decode_bytea,
    decode_date,
    decode_float32,
    decode_float64,
    decode_int16,
    decode_int32,
    decode_int64,
    decode_time,
    decode_timestamp,
    decode_timestamptz,
)


# ===----------------------------------------------------------------------===#
# Shared column metadata
# ===----------------------------------------------------------------------===#


struct _Columns(Movable, Sized):
    """The result's column names and type OIDs, read once from the `PGresult`.

    Shared between a `Result` and every `Row` it produces via an `ArcPointer`,
    so name lookup keeps working after the `Result` is gone and costs no
    per-row copying.
    """

    var names: List[String]
    """Column names, in result order.  Folded to lower case unless the query
    quoted them -- the same text `PQfnumber` matches against."""
    var oids: List[UInt32]
    """Column ``pg_type.oid`` values, parallel to `names`."""

    def __init__(out self, var names: List[String], var oids: List[UInt32]):
        """Take ownership of the two parallel lists.

        Args:
            names: Column names in result order.
            oids: Column type OIDs, parallel to `names`.
        """
        self.names = names^
        self.oids = oids^

    def __len__(self) -> Int:
        """The column count."""
        return len(self.names)

    def index_of(self, name: String) -> Int:
        """The index of the column called `name`, or ``-1``.

        A linear scan: result sets are a handful of columns wide, so a `Dict`
        would cost more to build than the scans it saves.  Matching is exact,
        which is `PQfnumber`'s rule -- unquoted SQL identifiers arrive folded
        to lower case, so ask for ``"userid"``, not ``"userId"``.

        Args:
            name: The column name to look for.

        Returns:
            The 0-based index, or ``-1`` if there is no such column.
        """
        for i in range(len(self.names)):
            if self.names[i] == name:
                return i
        return -1

    def listing(self) -> String:
        """The column names joined with ``", "``, for error messages."""
        var out = String("")
        for i in range(len(self.names)):
            if i > 0:
                out += ", "
            out += self.names[i]
        return out^


def _no_such_column(cols: _Columns, name: String) -> Error:
    """The error `column_index` and the name-keyed accessors raise."""
    if len(cols) == 0:
        return Error(
            "postgres: no column named '"
            + name
            + "'; the result has no columns"
        )
    return Error(
        "postgres: no column named '"
        + name
        + "'; available columns: "
        + cols.listing()
    )


def _out_of_range(what: String, i: Int, n: Int) -> Error:
    """The error every index-keyed accessor raises for an out-of-range index."""
    return Error(
        "postgres: "
        + what
        + " index "
        + String(i)
        + " is out of range (the result has "
        + String(n)
        + " "
        + what
        + ("" if n == 1 else "s")
        + ")"
    )


# ===----------------------------------------------------------------------===#
# Row
# ===----------------------------------------------------------------------===#


struct Row(Copyable, Movable):
    """One result row, copied out of the `PGresult` and independent of it.

    Obtained from `Result.row` or by iterating a `Result`.  Every cell is an
    owned `String` plus a NULL flag, so a `Row` may outlive the `Result` --
    and may be stored, returned, or copied freely.

    Each accessor comes in two overloads: one taking a 0-based column index,
    one taking the column name.  The name form resolves through the shared
    column metadata, so it works on a `Row` whose `Result` is long gone.

    Example:

    ```mojo
    var res = conn.query("SELECT id, name, note FROM t")
    for row in res:
        print(row.int64("id"), row.text("name"), row.opt_text("note"))
    ```
    """

    var _values: List[String]
    """One text-format cell per column; ``""`` for a NULL cell."""
    var _nulls: List[Bool]
    """True where the cell is SQL NULL, parallel to `_values`."""
    var _cols: ArcPointer[_Columns]
    """The result's shared names and OIDs."""

    def __init__(
        out self,
        var values: List[String],
        var nulls: List[Bool],
        cols: ArcPointer[_Columns],
    ):
        """Build a snapshot from already-copied cells.

        Args:
            values: One text-format value per column.
            nulls: True where the cell is SQL NULL, parallel to `values`.
            cols: The result's shared column metadata.
        """
        self._values = values^
        self._nulls = nulls^
        self._cols = cols

    # -- shape ---------------------------------------------------------------

    def num_cols(self) -> Int:
        """The number of columns in this row.

        Returns:
            The column count.
        """
        return len(self._values)

    def column_name(self, col: Int) raises -> String:
        """The name of column `col`.

        Args:
            col: The 0-based column index.

        Returns:
            The column's name.

        Raises:
            Error: If `col` is out of range.
        """
        self._check(col)
        return self._cols[].names[col]

    def column_index(self, name: String) raises -> Int:
        """The index of the column called `name`.

        Args:
            name: The column name, matched exactly (see `_Columns.index_of`).

        Returns:
            The 0-based column index.

        Raises:
            Error: If there is no such column; the message lists the ones
                there are.
        """
        var i = self._cols[].index_of(name)
        if i < 0:
            raise _no_such_column(self._cols[], name)
        return i

    def column_oid(self, col: Int) raises -> UInt32:
        """The ``pg_type.oid`` of column `col`.

        Args:
            col: The 0-based column index.

        Returns:
            The column's type OID -- 23 for ``int4``, 25 for ``text``, and so
            on; `postgres.text`'s ``OID_*`` constants name the common ones.

        Raises:
            Error: If `col` is out of range.
        """
        self._check(col)
        return self._cols[].oids[col]

    # -- internals -----------------------------------------------------------

    def _check(self, col: Int) raises:
        """Raise unless `col` is a valid column index."""
        if col < 0 or col >= len(self._values):
            raise _out_of_range("column", col, len(self._values))

    def _cell(self, col: Int) raises -> String:
        """The text of a non-NULL cell, or raise saying it is NULL."""
        self._check(col)
        if self._nulls[col]:
            raise Error(
                "postgres: column '"
                + self._cols[].names[col]
                + "' is NULL; use is_null() or opt_text() first"
            )
        return self._values[col]

    # -- NULL ----------------------------------------------------------------

    def is_null(self, col: Int) raises -> Bool:
        """Whether column `col` is SQL NULL.

        Args:
            col: The 0-based column index.

        Returns:
            True for SQL NULL -- which libpq renders identically to the empty
            string, so this is the only way to tell them apart.

        Raises:
            Error: If `col` is out of range.
        """
        self._check(col)
        return self._nulls[col]

    def is_null(self, col: String) raises -> Bool:
        """Whether the column named `col` is SQL NULL.

        Args:
            col: The column name.

        Returns:
            True for SQL NULL.

        Raises:
            Error: If there is no such column.
        """
        return self.is_null(self.column_index(col))

    def opt_text(self, col: Int) raises -> Optional[String]:
        """Column `col` as text, or `None` when it is SQL NULL.

        The NULL-tolerant counterpart to `Row.text`.

        Args:
            col: The 0-based column index.

        Returns:
            The cell's text, or `None` for SQL NULL.

        Raises:
            Error: If `col` is out of range.
        """
        self._check(col)
        if self._nulls[col]:
            return None
        return self._values[col]

    def opt_text(self, col: String) raises -> Optional[String]:
        """The column named `col` as text, or `None` when it is SQL NULL.

        Args:
            col: The column name.

        Returns:
            The cell's text, or `None` for SQL NULL.

        Raises:
            Error: If there is no such column.
        """
        return self.opt_text(self.column_index(col))

    # -- text ----------------------------------------------------------------

    def text(self, col: Int) raises -> String:
        """Column `col` exactly as the server rendered it.

        The escape hatch for every type this module has no accessor for, and
        the only way to read the values the typed decoders refuse -- an
        ``infinity`` date, a ``BC`` timestamp, an array, a composite.

        Args:
            col: The 0-based column index.

        Returns:
            The cell's text.

        Raises:
            Error: If `col` is out of range, or the cell is SQL NULL.
        """
        return self._cell(col)

    def text(self, col: String) raises -> String:
        """The column named `col`, exactly as the server rendered it.

        Args:
            col: The column name.

        Returns:
            The cell's text.

        Raises:
            Error: If there is no such column, or the cell is SQL NULL.
        """
        return self._cell(self.column_index(col))

    # -- typed accessors -----------------------------------------------------

    def bool(self, col: Int) raises -> Bool:
        """Column `col` decoded as `bool` (`t`/`f`).

        Args:
            col: The 0-based column index.

        Returns:
            The decoded value.

        Raises:
            Error: If the cell is NULL or is not valid `bool` text.
        """
        var v = self._cell(col)
        return decode_bool(v)

    def bool(self, col: String) raises -> Bool:
        """The column named `col`, decoded as `bool`.

        Args:
            col: The column name.

        Returns:
            The decoded value.

        Raises:
            Error: If there is no such column, the cell is NULL, or the text
                is not valid `bool`.
        """
        return self.bool(self.column_index(col))

    def int16(self, col: Int) raises -> Int16:
        """Column `col` decoded as `int2`.

        Args:
            col: The 0-based column index.

        Returns:
            The decoded value.

        Raises:
            Error: If the cell is NULL, or the text is not an in-range `int2`.
        """
        var v = self._cell(col)
        return decode_int16(v)

    def int16(self, col: String) raises -> Int16:
        """The column named `col`, decoded as `int2`.

        Args:
            col: The column name.

        Returns:
            The decoded value.

        Raises:
            Error: If there is no such column, the cell is NULL, or the text
                is not an in-range `int2`.
        """
        return self.int16(self.column_index(col))

    def int32(self, col: Int) raises -> Int32:
        """Column `col` decoded as `int4`.

        Args:
            col: The 0-based column index.

        Returns:
            The decoded value.

        Raises:
            Error: If the cell is NULL, or the text is not an in-range `int4`.
        """
        var v = self._cell(col)
        return decode_int32(v)

    def int32(self, col: String) raises -> Int32:
        """The column named `col`, decoded as `int4`.

        Args:
            col: The column name.

        Returns:
            The decoded value.

        Raises:
            Error: If there is no such column, the cell is NULL, or the text
                is not an in-range `int4`.
        """
        return self.int32(self.column_index(col))

    def int64(self, col: Int) raises -> Int64:
        """Column `col` decoded as `int8`.

        Args:
            col: The 0-based column index.

        Returns:
            The decoded value.

        Raises:
            Error: If the cell is NULL, or the text is not an in-range `int8`.
        """
        var v = self._cell(col)
        return decode_int64(v)

    def int64(self, col: String) raises -> Int64:
        """The column named `col`, decoded as `int8`.

        Args:
            col: The column name.

        Returns:
            The decoded value.

        Raises:
            Error: If there is no such column, the cell is NULL, or the text
                is not an in-range `int8`.
        """
        return self.int64(self.column_index(col))

    def float32(self, col: Int) raises -> Float32:
        """Column `col` decoded as `float4`.

        Args:
            col: The 0-based column index.

        Returns:
            The decoded value; PostgreSQL's `NaN`, `Infinity` and `-Infinity`
            all decode to the corresponding IEEE value.

        Raises:
            Error: If the cell is NULL, or the text is not a valid float.
        """
        var v = self._cell(col)
        return decode_float32(v)

    def float32(self, col: String) raises -> Float32:
        """The column named `col`, decoded as `float4`.

        Args:
            col: The column name.

        Returns:
            The decoded value.

        Raises:
            Error: If there is no such column, the cell is NULL, or the text
                is not a valid float.
        """
        return self.float32(self.column_index(col))

    def float64(self, col: Int) raises -> Float64:
        """Column `col` decoded as `float8`.

        Args:
            col: The 0-based column index.

        Returns:
            The decoded value; `NaN`, `Infinity` and `-Infinity` decode to the
            corresponding IEEE value.

        Raises:
            Error: If the cell is NULL, or the text is not a valid float.
        """
        var v = self._cell(col)
        return decode_float64(v)

    def float64(self, col: String) raises -> Float64:
        """The column named `col`, decoded as `float8`.

        Args:
            col: The column name.

        Returns:
            The decoded value.

        Raises:
            Error: If there is no such column, the cell is NULL, or the text
                is not a valid float.
        """
        return self.float64(self.column_index(col))

    def numeric(self, col: Int) raises -> String:
        """Column `col` as a `numeric` literal, kept as text.

        `numeric` is arbitrary precision; turning it into a `Float64` would
        silently lose digits, so this hands back exactly the digits the server
        sent -- trailing zeros of the column's scale included.

        Args:
            col: The 0-based column index.

        Returns:
            The literal, e.g. ``"12345.678900"``.

        Raises:
            Error: If `col` is out of range, or the cell is SQL NULL.
        """
        return self._cell(col)

    def numeric(self, col: String) raises -> String:
        """The column named `col` as a `numeric` literal, kept as text.

        Args:
            col: The column name.

        Returns:
            The literal.

        Raises:
            Error: If there is no such column, or the cell is SQL NULL.
        """
        return self._cell(self.column_index(col))

    def bytea(self, col: Int) raises -> List[UInt8]:
        """Column `col` decoded as `bytea`.

        Both text sub-formats are accepted: the ``\\x``-prefixed hex the
        server emits by default, and the legacy octal-escape format.

        Args:
            col: The 0-based column index.

        Returns:
            The raw bytes.

        Raises:
            Error: If the cell is NULL, or the text is not valid `bytea`.
        """
        var v = self._cell(col)
        return decode_bytea(v)

    def bytea(self, col: String) raises -> List[UInt8]:
        """The column named `col`, decoded as `bytea`.

        Args:
            col: The column name.

        Returns:
            The raw bytes.

        Raises:
            Error: If there is no such column, the cell is NULL, or the text
                is not valid `bytea`.
        """
        return self.bytea(self.column_index(col))

    def date_days(self, col: Int) raises -> Int32:
        """Column `col` decoded as `date`, in days since 1970-01-01.

        Args:
            col: The 0-based column index.

        Returns:
            Days since the Unix epoch; negative before it.

        Raises:
            Error: If the cell is NULL, the text is not a valid date, or the
                date is ``infinity``/``-infinity`` or a ``BC`` year -- neither
                of which the epoch encoding can carry.  Read `Row.text` for
                those.
        """
        var v = self._cell(col)
        return decode_date(v)

    def date_days(self, col: String) raises -> Int32:
        """The column named `col`, decoded as `date` in days since the epoch.

        Args:
            col: The column name.

        Returns:
            Days since 1970-01-01.

        Raises:
            Error: If there is no such column, the cell is NULL, or the date
                cannot be expressed as an epoch day count.
        """
        return self.date_days(self.column_index(col))

    def time_micros(self, col: Int) raises -> Int64:
        """Column `col` decoded as `time`, in microseconds since midnight.

        Args:
            col: The 0-based column index.

        Returns:
            Microseconds since 00:00:00.

        Raises:
            Error: If the cell is NULL, or the text is not a valid time.
        """
        var v = self._cell(col)
        return decode_time(v)

    def time_micros(self, col: String) raises -> Int64:
        """The column named `col`, decoded as `time` in microseconds.

        Args:
            col: The column name.

        Returns:
            Microseconds since midnight.

        Raises:
            Error: If there is no such column, the cell is NULL, or the text
                is not a valid time.
        """
        return self.time_micros(self.column_index(col))

    def timestamp_micros(self, col: Int) raises -> Int64:
        """Column `col` decoded as naive `timestamp`, in epoch microseconds.

        Args:
            col: The 0-based column index.

        Returns:
            Microseconds since 1970-01-01 00:00:00, with no zone applied --
            `timestamp` carries none.

        Raises:
            Error: If the cell is NULL, the text is not a valid timestamp, or
                it is infinite or ``BC``.
        """
        var v = self._cell(col)
        return decode_timestamp(v)

    def timestamp_micros(self, col: String) raises -> Int64:
        """The column named `col`, decoded as naive `timestamp`.

        Args:
            col: The column name.

        Returns:
            Microseconds since 1970-01-01 00:00:00.

        Raises:
            Error: If there is no such column, the cell is NULL, or the
                timestamp cannot be expressed in epoch microseconds.
        """
        return self.timestamp_micros(self.column_index(col))

    def timestamptz_micros(self, col: Int) raises -> Int64:
        """Column `col` decoded as `timestamptz`, in **UTC** epoch microseconds.

        The server renders `timestamptz` in the session's ``TimeZone``, with
        the offset appended; the offset is applied here, so the result is UTC
        regardless of what the session is set to.

        Args:
            col: The 0-based column index.

        Returns:
            UTC microseconds since 1970-01-01 00:00:00Z.

        Raises:
            Error: If the cell is NULL, the text is not a valid zoned
                timestamp, or it is infinite or ``BC``.
        """
        var v = self._cell(col)
        return decode_timestamptz(v)

    def timestamptz_micros(self, col: String) raises -> Int64:
        """The column named `col`, decoded as `timestamptz` in UTC micros.

        Args:
            col: The column name.

        Returns:
            UTC microseconds since 1970-01-01 00:00:00Z.

        Raises:
            Error: If there is no such column, the cell is NULL, or the
                timestamp cannot be expressed in epoch microseconds.
        """
        return self.timestamptz_micros(self.column_index(col))

    def uuid(self, col: Int) raises -> String:
        """Column `col` as `uuid` text, e.g. ``"a0ee-...-4f1b"``.

        The server always renders a `uuid` in the canonical lower-case
        8-4-4-4-12 form, so this is the raw text.

        Args:
            col: The 0-based column index.

        Returns:
            The UUID text.

        Raises:
            Error: If `col` is out of range, or the cell is SQL NULL.
        """
        return self._cell(col)

    def uuid(self, col: String) raises -> String:
        """The column named `col` as `uuid` text.

        Args:
            col: The column name.

        Returns:
            The UUID text.

        Raises:
            Error: If there is no such column, or the cell is SQL NULL.
        """
        return self._cell(self.column_index(col))

    def json(self, col: Int) raises -> String:
        """Column `col` as `json`/`jsonb` text.

        Not parsed -- this tin has no JSON model.  `json` comes back exactly
        as it was stored; `jsonb` comes back in the server's normalised form
        (keys reordered, whitespace canonical).

        Args:
            col: The 0-based column index.

        Returns:
            The JSON text.

        Raises:
            Error: If `col` is out of range, or the cell is SQL NULL.
        """
        return self._cell(col)

    def json(self, col: String) raises -> String:
        """The column named `col` as `json`/`jsonb` text.

        Args:
            col: The column name.

        Returns:
            The JSON text.

        Raises:
            Error: If there is no such column, or the cell is SQL NULL.
        """
        return self._cell(self.column_index(col))


# ===----------------------------------------------------------------------===#
# Result
# ===----------------------------------------------------------------------===#


struct Result(Iterable, Movable, Sized):
    """The rows one command returned, owning the underlying `PGresult`.

    Built by `Connection.query` from an already status-checked result handle,
    and cleared exactly once when it is destroyed.  Not copyable: two owners
    would mean two `PQclear`s.

    A command that returns no rows -- an ``INSERT``, a ``CREATE TABLE`` --
    still yields a `Result`, with `num_rows` and `num_cols` both ``0`` and
    `affected_rows` carrying the count.

    Example:

    ```mojo
    var res = conn.query("SELECT id, name FROM t WHERE id > $1",
                         Params().int64(10))
    print(res.num_rows(), "rows")
    for row in res:
        print(row.int64("id"), row.text("name"))
    ```
    """

    comptime IteratorType[
        iterable_mut: Bool, //, iterable_origin: Origin[mut=iterable_mut]
    ]: Iterator = _RowIter[iterable_origin]
    """The iterator `for row in res:` uses; it yields `Row` snapshots."""

    var _res: PGresultPtr
    """The owned ``PGresult *``; cleared in `Result.__deinit__`."""
    var _pq: Pointer[LibpqFFI, MutUntrackedOrigin]
    """The process-wide FFI table, borrowed once so cell reads cannot fail.

    `libpq` is declared `raises` (it may have to load the library), which an
    iterator's `__next__` -- allowed to raise only `StopIteration` -- cannot
    call.  Resolving it here, where raising is fine, makes every later cell
    read infallible.  The referent is a `_Global` that is never destroyed, so
    the pointer stays valid for the process lifetime.
    """
    var _cols: ArcPointer[_Columns]
    """Column names and OIDs, shared with every `Row` this result produces."""
    var _nrows: Int
    """`PQntuples`, cached -- it cannot change."""
    var _ncols: Int
    """`PQnfields`, cached -- it cannot change."""

    def __init__(out self, res: PGresultPtr) raises:
        """Take ownership of an already status-checked result handle.

        The status check belongs to the caller: by the time a `Result` exists
        the command has succeeded, so none of its accessors have to answer for
        `PGRES_FATAL_ERROR`.  `Connection.query` is the only intended caller.

        Args:
            res: A `PGresultPtr` whose `PQresultStatus` is `PGRES_TUPLES_OK`,
                `PGRES_COMMAND_OK` or `PGRES_EMPTY_QUERY`.  This `Result` now
                owns it and will `PQclear` it exactly once.

        Raises:
            Error: Only if libpq itself could not be reached, which cannot
                happen once a `Connection` exists.
        """
        ref pq = libpq()
        self._pq = Pointer(to=pq)
        self._res = res
        self._nrows = pq.PQntuples(res)
        self._ncols = pq.PQnfields(res)
        var names = List[String](capacity=self._ncols)
        var oids = List[UInt32](capacity=self._ncols)
        for i in range(self._ncols):
            names.append(pq.PQfname(res, i))
            oids.append(pq.PQftype(res, i))
        self._cols = ArcPointer(_Columns(names^, oids^))

    def __deinit__(deinit self):
        """Clear the `PGresult`, releasing libpq's copy of every row."""
        self._pq[].PQclear(self._res)

    # -- shape ---------------------------------------------------------------

    def num_rows(self) -> Int:
        """The number of rows.

        Returns:
            The row count; ``0`` for a command that returns none.
        """
        return self._nrows

    def num_cols(self) -> Int:
        """The number of columns.

        Returns:
            The column count; ``0`` for a command that returns no rows.
        """
        return self._ncols

    def __len__(self) -> Int:
        """The number of rows, so `len(res)` reads naturally.

        Returns:
            The row count.
        """
        return self._nrows

    def column_name(self, col: Int) raises -> String:
        """The name of column `col`.

        Args:
            col: The 0-based column index.

        Returns:
            The column's name, folded to lower case unless the query quoted
            it.

        Raises:
            Error: If `col` is out of range.
        """
        if col < 0 or col >= self._ncols:
            raise _out_of_range("column", col, self._ncols)
        return self._cols[].names[col]

    def column_index(self, name: String) raises -> Int:
        """The index of the column called `name`.

        Matching is exact, as in `PQfnumber`: an unquoted SQL identifier
        arrives folded to lower case, so ask for ``"userid"``, not
        ``"userId"``.

        Args:
            name: The column name.

        Returns:
            The 0-based column index.

        Raises:
            Error: If there is no such column; the message lists the ones
                there are.
        """
        var i = self._cols[].index_of(name)
        if i < 0:
            raise _no_such_column(self._cols[], name)
        return i

    def column_oid(self, col: Int) raises -> UInt32:
        """The ``pg_type.oid`` of column `col`.

        The hook for callers who want to dispatch on the server's actual type
        rather than assert one -- `Row`'s typed accessors deliberately do not
        consult it.

        Args:
            col: The 0-based column index.

        Returns:
            The column's type OID.

        Raises:
            Error: If `col` is out of range.
        """
        if col < 0 or col >= self._ncols:
            raise _out_of_range("column", col, self._ncols)
        return self._cols[].oids[col]

    def affected_rows(self) raises -> Int:
        """Rows inserted, updated, deleted or retrieved by the command.

        Returns:
            `PQcmdTuples` parsed as an integer -- the count in the server's
            command tag.  ``INSERT``/``UPDATE``/``DELETE`` report what they
            changed, and a ``SELECT`` reports what it returned (so this equals
            `Result.num_rows`); DDL and ``BEGIN`` report nothing at all, which
            reads here as ``0``.

        Raises:
            Error: If libpq reported a count that is not an integer, which
                would mean a libpq bug rather than a user error.
        """
        var s = self._pq[].PQcmdTuples(self._res)
        if s.byte_length() == 0:
            return 0
        return Int(decode_int64(s))

    # -- cells ---------------------------------------------------------------

    def _check(self, row: Int, col: Int) raises:
        """Raise unless `row` and `col` are both in range."""
        if row < 0 or row >= self._nrows:
            raise _out_of_range("row", row, self._nrows)
        if col < 0 or col >= self._ncols:
            raise _out_of_range("column", col, self._ncols)

    def is_null(self, row: Int, col: Int) raises -> Bool:
        """Whether the cell at (`row`, `col`) is SQL NULL.

        Args:
            row: The 0-based row index.
            col: The 0-based column index.

        Returns:
            True for SQL NULL.  libpq renders NULL and the empty string
            identically, so this is the only way to separate them.

        Raises:
            Error: If either index is out of range.
        """
        self._check(row, col)
        return self._pq[].PQgetisnull(self._res, row, col)

    def text(self, row: Int, col: Int) raises -> String:
        """The cell at (`row`, `col`) as the server rendered it.

        Args:
            row: The 0-based row index.
            col: The 0-based column index.

        Returns:
            The cell's text.

        Raises:
            Error: If either index is out of range, or the cell is SQL NULL --
                check `Result.is_null` first, or read the whole row with
                `Result.row` and use `Row.opt_text`.
        """
        self._check(row, col)
        if self._pq[].PQgetisnull(self._res, row, col):
            raise Error(
                "postgres: row "
                + String(row)
                + ", column '"
                + self._cols[].names[col]
                + "' is NULL; use is_null() first"
            )
        return self._pq[].PQgetvalue(self._res, row, col)

    def row(self, row: Int) raises -> Row:
        """Copy row `row` into a standalone `Row` snapshot.

        The snapshot owns its cells and shares only the column metadata, so it
        stays usable after this `Result` is destroyed.

        Args:
            row: The 0-based row index.

        Returns:
            The row, independent of this `Result`'s lifetime.

        Raises:
            Error: If `row` is out of range.
        """
        if row < 0 or row >= self._nrows:
            raise _out_of_range("row", row, self._nrows)
        return self._snapshot(row)

    def _snapshot(self, row: Int) -> Row:
        """Copy one in-range row's cells.  Infallible, so `__next__` can use
        it."""
        var values = List[String](capacity=self._ncols)
        var nulls = List[Bool](capacity=self._ncols)
        for col in range(self._ncols):
            nulls.append(self._pq[].PQgetisnull(self._res, row, col))
            values.append(self._pq[].PQgetvalue(self._res, row, col))
        return Row(values^, nulls^, self._cols)

    # -- iteration -----------------------------------------------------------

    def __iter__(ref self) -> Self.IteratorType[origin_of(self)]:
        """Iterate the rows, yielding one `Row` snapshot at a time.

        Rows are copied lazily -- only the row the loop is on exists as a
        `Row` -- so a large result costs one row's worth of `String`s at a
        time on top of what libpq already holds.

        Returns:
            An iterator over `Row` values.
        """
        return _RowIter[origin_of(self)](Pointer(to=self), 0, self._nrows)


# ===----------------------------------------------------------------------===#
# Row iterator
# ===----------------------------------------------------------------------===#


@fieldwise_init
struct _RowIter[mut: Bool, //, origin: Origin[mut=mut]](
    ImplicitlyCopyable, Iterable, Iterator
):
    """Yields `Row` snapshots from a borrowed `Result`.

    `Iterator.__next__` may raise only `StopIteration`, which is why `Result`
    resolves the FFI table up front: `Result._snapshot` cannot fail, so this
    iterator has nothing else to report.
    """

    comptime Element = Row
    comptime IteratorType[
        iterable_mut: Bool, //, iterable_origin: Origin[mut=iterable_mut]
    ]: Iterator = Self

    var _res: Pointer[Result, Self.origin]
    """The result being walked; it outlives the loop."""
    var _index: Int
    """The next row to yield."""
    var _len: Int
    """`Result.num_rows`, cached."""

    def __iter__(ref self) -> Self.IteratorType[origin_of(self)]:
        """An iterator is its own iterable.

        Returns:
            A copy of this iterator.
        """
        return self.copy()

    def __next__(mut self) raises StopIteration -> Row:
        """The next row snapshot.

        Returns:
            The row at the current position.

        Raises:
            StopIteration: Once every row has been yielded.
        """
        if self._index >= self._len:
            raise StopIteration()
        self._index += 1
        return self._res[]._snapshot(self._index - 1)

    def bounds(self) -> Tuple[Int, Optional[Int]]:
        """The exact number of rows left, so `List(res)` can pre-allocate.

        Returns:
            ``(remaining, remaining)`` -- a result set's length is known.
        """
        var remaining = self._len - self._index
        return (remaining, {remaining})
