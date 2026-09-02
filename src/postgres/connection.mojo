"""`postgres.connection` — the connection, its statements and its transactions.

`Connection` owns one libpq `PGconn` and closes it when it goes out of scope.
Everything a caller does with a database goes through it: `Connection.execute`
for commands, `Connection.query` for rows, `Connection.prepare` for a
server-side statement to run more than once, `Connection.begin` for a
transaction, and `Connection.copy_in`/`Connection.copy_out` for bulk transfer
(the handles those return live in `postgres.copy`).

Values are never interpolated into SQL.  Write ``$1``, ``$2``, ... and pass a
`Params`; libpq sends the values out of band, so there is nothing to escape and
no injection surface:

```mojo
from postgres import Connection, Params

var conn = Connection("postgresql://localhost/app?connect_timeout=5")
_ = conn.execute("CREATE TABLE t (id bigint primary key, name text)")
_ = conn.execute("INSERT INTO t VALUES ($1, $2)",
                 Params().int64(1).text("Alice"))

var res = conn.query("SELECT id, name FROM t WHERE id = $1", Params().int64(1))
for row in res:
    print(row.int64("id"), row.text("name"))
```

**Errors carry their SQLSTATE.**  Every failure the server reports is raised as
a `PostgresError` formatted by `sqlstate.PostgresError.format` --
``postgres [SQLSTATE 23505] duplicate key value ...`` -- so a `try`/`except`
that only has an `Error` in hand can still branch on `sqlstate.sqlstate_of`.
The structured value is also kept in `Connection.last_error`, where the
`is_unique_violation`-style predicates are available without any parsing.

**Transactions are explicit.**  `Connection.begin` issues ``BEGIN`` and hands
back a `Transaction` that rolls itself back if it is destroyed without a
`Transaction.commit` -- so an early return or a raised error cannot leave a
block half-applied:

```mojo
var tx = conn.begin()
_ = tx.execute("UPDATE accounts SET balance = balance - $1 WHERE id = $2",
               Params().numeric("10.00").int64(1))
tx.savepoint("maybe")
_ = tx.execute("INSERT INTO audit VALUES ($1)", Params().int64(1))
tx.commit()
```

**One connection, one thread.**  libpq's `PGconn` is not safe to use from two
threads at once, and nothing here adds a lock.

**Notices go to stderr.**  A ``NOTICE``/``WARNING`` the server raises -- from a
``RAISE NOTICE``, or from ``CREATE TABLE IF NOT EXISTS`` finding the table
already there -- is printed to standard error by libpq's default notice
processor.  This tin installs none of its own, so those messages are visible
but not capturable; a hook for them is not in v1.
"""

from std.memory import ArcPointer

from ._ffi import (
    CONNECTION_OK,
    PGRES_COMMAND_OK,
    PGRES_COPY_BOTH,
    PGRES_COPY_IN,
    PGRES_COPY_OUT,
    PGRES_EMPTY_QUERY,
    PGRES_TUPLES_OK,
    PG_DIAG_MESSAGE_DETAIL,
    PG_DIAG_MESSAGE_HINT,
    PG_DIAG_MESSAGE_PRIMARY,
    PG_DIAG_SEVERITY,
    PG_DIAG_SEVERITY_NONLOCALIZED,
    PG_DIAG_SQLSTATE,
    PGconnPtr,
    PGresultPtr,
    PQTRANS_IDLE,
    PQTRANS_INERROR,
    PQTRANS_UNKNOWN,
    _error_field,
    exec_params,
    exec_prepared,
    libpq,
)
from .config import ConnectionConfig
from .copy import CopyIn, CopyOut
from .params import Params
from .result import Result
from .sqlstate import (
    CONNECTION_FAILURE,
    PostgresError,
    SQLCLIENT_UNABLE_TO_ESTABLISH,
)
from .text import decode_int64


# ===----------------------------------------------------------------------===#
# SQLSTATEs this module raises on its own behalf
#
# The server never gets a chance to report these: a nested `BEGIN` is only a
# warning to PostgreSQL, and a `COMMIT` inside a failed block is silently
# turned into a `ROLLBACK`.  Both are surprises worth raising for, so they are
# raised here with the code PostgreSQL uses for the same condition elsewhere.
# ===----------------------------------------------------------------------===#

comptime IN_FAILED_SQL_TRANSACTION: StaticString = "25P02"
"""The block has already failed, so ``COMMIT`` would silently roll back."""
comptime ACTIVE_SQL_TRANSACTION: StaticString = "25001"
"""A transaction block is already open on this connection."""
comptime NO_ACTIVE_SQL_TRANSACTION: StaticString = "25P01"
"""The transaction is over -- committed or rolled back already."""
comptime WRONG_OBJECT_TYPE: StaticString = "42809"
"""The statement was not the ``COPY`` the call needed it to be."""


# ===----------------------------------------------------------------------===#
# Small helpers
# ===----------------------------------------------------------------------===#


def _trim(s: String) -> String:
    """Strip leading and trailing ASCII whitespace.

    libpq's messages end in a newline (`PQerrorMessage` promises one), which
    would otherwise land in the middle of the formatted error.

    Args:
        s: The message to trim.

    Returns:
        `s` without its surrounding spaces, tabs, carriage returns and
        newlines.
    """
    var b = s.as_bytes()
    var start = 0
    var end = len(b)
    while start < end and (
        b[start] == UInt8(ord(" "))
        or b[start] == UInt8(ord("\t"))
        or b[start] == UInt8(ord("\n"))
        or b[start] == UInt8(ord("\r"))
    ):
        start += 1
    while end > start and (
        b[end - 1] == UInt8(ord(" "))
        or b[end - 1] == UInt8(ord("\t"))
        or b[end - 1] == UInt8(ord("\n"))
        or b[end - 1] == UInt8(ord("\r"))
    ):
        end -= 1
    if start >= end:
        return String("")
    return String(StringSlice(unsafe_from_utf8=Span(b)[start:end]))


def _quote_ident(name: String) -> String:
    """Wrap `name` in double quotes, doubling any it already contains.

    Used by `Statement.deallocate` and by `Transaction.savepoint` and its two
    companions -- the only places in this module where a value reaches the
    server inside the SQL text rather than as a parameter, because
    ``DEALLOCATE`` and ``SAVEPOINT`` take identifiers and identifiers cannot
    be parameters.  Doubling the quotes is what keeps a hostile name from
    ending the quoting early.

    Args:
        name: The identifier to quote.

    Returns:
        The quoted identifier, e.g. ``"my""stmt"``.
    """
    var out = List[UInt8](capacity=name.byte_length() + 2)
    out.append(UInt8(ord('"')))
    for b in name.as_bytes():
        if b == UInt8(ord('"')):
            out.append(b)
        out.append(b)
    out.append(UInt8(ord('"')))
    return String(StringSlice(unsafe_from_utf8=Span(out)))


struct _Bound(Movable):
    """The three parallel lists `exec_params` wants, taken off a `Params`."""

    var values: List[String]
    """One text-format value per parameter."""
    var nulls: List[Bool]
    """True where the parameter is SQL NULL."""
    var oids: List[UInt32]
    """One type OID per parameter; ``0`` asks the server to infer that one."""

    def __init__(
        out self,
        var values: List[String],
        var nulls: List[Bool],
        var oids: List[UInt32],
    ):
        """Take ownership of the marshalled lists.

        Args:
            values: One text-format value per parameter.
            nulls: True where the parameter is SQL NULL.
            oids: One type OID per parameter.
        """
        self.values = values^
        self.nulls = nulls^
        self.oids = oids^


def _bind(params: Params) -> _Bound:
    """Flatten a `Params` into the parallel lists the FFI layer takes.

    Args:
        params: The parameter list to read.

    Returns:
        A `_Bound` with one entry per parameter in each list.
    """
    var n = len(params)
    var values = List[String](capacity=n)
    var nulls = List[Bool](capacity=n)
    var oids = List[UInt32](capacity=n)
    for i in range(n):
        values.append(params.value(i))
        nulls.append(params.is_null(i))
        oids.append(params.oid(i))
    return _Bound(values^, nulls^, oids^)


def _affected_rows(res: PGresultPtr) raises -> Int:
    """`PQcmdTuples` as an integer, mapping libpq's ``""`` to ``0``.

    Args:
        res: A successful result handle.

    Returns:
        The count in the server's command tag -- rows changed for
        ``INSERT``/``UPDATE``/``DELETE``, rows returned for a ``SELECT``;
        ``0`` for DDL and ``BEGIN``, which report no count at all.

    Raises:
        Error: If libpq reported a count that is not an integer.
    """
    var s = libpq().PQcmdTuples(res)
    if s.byte_length() == 0:
        return 0
    return Int(decode_int64(s))


def _result_error(
    res: PGresultPtr, conn: PGconnPtr, sql: String
) raises -> PostgresError:
    """Build the structured error behind a failed command.

    Reads the `PG_DIAG_*` fields the server sent, preferring the
    non-localised severity so a server running under a non-English
    ``lc_messages`` still reports ``ERROR`` rather than its translation.

    A failure libpq raised on its own -- a lost connection, out of memory --
    has no fields at all, and may not even have a result: those are reported
    as `sqlstate.CONNECTION_FAILURE` (08006) with `PQerrorMessage`'s text,
    matching what class 08 means to every other PostgreSQL client.

    Args:
        res: The failing result handle; ``0`` when libpq could not produce
            one.  Not cleared here -- the caller owns it.
        conn: The connection the command ran on, for the fallback message.
        sql: The statement text, attached so the formatted error is
            self-contained in a log line.

    Returns:
        The error, ready to store in `Connection.last_error` and raise.

    Raises:
        Error: Only if libpq itself could not be reached.
    """
    ref pq = libpq()
    if res == 0:
        var message = _trim(pq.PQerrorMessage(conn))
        if message.byte_length() == 0:
            message = String(
                "the command could not be sent (out of memory, or the"
                " connection was lost)"
            )
        return PostgresError(
            severity="FATAL",
            sqlstate=String(CONNECTION_FAILURE),
            message=message,
            sql=sql,
        )

    var severity = _error_field(res, PG_DIAG_SEVERITY_NONLOCALIZED)
    if severity.byte_length() == 0:
        severity = _error_field(res, PG_DIAG_SEVERITY)
    var sqlstate = _error_field(res, PG_DIAG_SQLSTATE)
    var message = _error_field(res, PG_DIAG_MESSAGE_PRIMARY)
    var detail = _error_field(res, PG_DIAG_MESSAGE_DETAIL)
    var hint = _error_field(res, PG_DIAG_MESSAGE_HINT)

    if message.byte_length() == 0:
        message = _trim(pq.PQresultErrorMessage(res))
    if sqlstate.byte_length() == 0:
        # No SQLSTATE means the server never reported this: libpq did, which
        # in practice means the connection went away mid-command.
        if message.byte_length() == 0:
            message = _trim(pq.PQerrorMessage(conn))
        if severity.byte_length() == 0:
            severity = String("FATAL")
        sqlstate = String(CONNECTION_FAILURE)

    return PostgresError(
        severity=severity,
        sqlstate=sqlstate,
        message=message,
        detail=detail,
        hint=hint,
        sql=sql,
    )


# ===----------------------------------------------------------------------===#
# The shared error cell
# ===----------------------------------------------------------------------===#


struct _ErrorCell(Movable):
    """The one slot `Connection.last_error` reads, shared by everything on it.

    A `Statement`, a `Transaction`, a `CopyIn` and a `CopyOut` all hold the raw
    `PGconnPtr` rather than a reference to the `Connection` -- which is what
    keeps them free of an origin parameter -- so none of them can reach back to
    a field on it.  They share this instead, through an
    `std.memory.ArcPointer`: every raise anywhere on the connection lands in
    the same cell, and `Connection.last_error` sees all of them.

    `ArcPointer` gives interior mutability -- writes go through an immutable
    `self` -- which is what lets `Statement.execute` record an error without
    taking a mutable borrow of anything.  That is sound here for the same
    reason the whole tin is: one `PGconn` belongs to one thread.
    """

    var error: PostgresError
    """The most recent error raised through this connection, in any form."""

    def __init__(out self):
        """Start empty: every field of the `PostgresError` is ``""``."""
        self.error = PostgresError()


def _record(errors: ArcPointer[_ErrorCell], err: PostgresError):
    """Store `err` as the connection's most recent error.

    Args:
        errors: The connection's shared error cell.
        err: The error to remember.
    """
    errors[].error = err.copy()


def _raise_error(errors: ArcPointer[_ErrorCell], err: PostgresError) raises:
    """Record `err` and raise it.

    Args:
        errors: The connection's shared error cell.
        err: The error to record and raise.

    Raises:
        Error: Always -- `err` formatted by `sqlstate.PostgresError.to_error`.
    """
    _record(errors, err)
    raise err.to_error()


def _raise_result(
    errors: ArcPointer[_ErrorCell],
    res: PGresultPtr,
    conn: PGconnPtr,
    sql: String,
) raises:
    """Record and raise the error behind a failed command, clearing `res`.

    The single implementation of the status-to-error mapping: `Connection`,
    `Statement`, `Transaction` and both COPY handles all come through here, so
    the message shape and the `Connection.last_error` bookkeeping cannot drift
    apart between them.

    Args:
        errors: The connection's shared error cell.
        res: The failing result handle; ``0`` when libpq produced none.
            Cleared here.
        conn: The connection the command ran on.
        sql: The statement text, attached to the error.

    Raises:
        Error: Always -- a `sqlstate.PostgresError` formatted through
            `sqlstate.PostgresError.to_error`.
    """
    var err = _result_error(res, conn, sql)
    libpq().PQclear(res)
    _raise_error(errors, err)


def _closed_error() -> PostgresError:
    """The error every method raises once the connection has been closed.

    Returns:
        A `sqlstate.PostgresError` with SQLSTATE
        `sqlstate.CONNECTION_FAILURE` (08006).
    """
    return PostgresError(
        severity="FATAL",
        sqlstate=String(CONNECTION_FAILURE),
        message="the connection is closed",
    )


def drain_results(
    conn: PGconnPtr, errors: ArcPointer[_ErrorCell], sql: String
) raises -> Int:
    """Collect every outstanding result, then report on the first one.

    This is how a ``COPY`` ends.  `LibpqFFI.PQgetResult` must be called until
    it returns ``0`` or the connection stays busy and every later command
    fails, so the drain happens **first, unconditionally** -- only then is the
    first result's status examined and, if it failed, raised.  A malformed
    ``COPY`` row therefore surfaces as the server's own error (``22P02`` with
    its ``DETAIL``/``CONTEXT``) on a connection that is already clean.

    Args:
        conn: The connection handle.
        errors: The connection's shared error cell.
        sql: The statement text, attached to any error raised.

    Returns:
        The count in the first result's command tag -- the rows a ``COPY``
        transferred -- or ``0`` if there was no result at all.

    Raises:
        Error: A `sqlstate.PostgresError` if the first result reports a
            failure.
    """
    ref pq = libpq()
    var first: PGresultPtr = 0
    var status = PGRES_COMMAND_OK
    while True:
        var res = pq.PQgetResult(conn)
        if res == 0:
            break
        if first == 0:
            first = res
            status = pq.PQresultStatus(res)
        else:
            pq.PQclear(res)
    if first == 0:
        return 0
    if (
        status == PGRES_COMMAND_OK
        or status == PGRES_TUPLES_OK
        or status == PGRES_EMPTY_QUERY
    ):
        var n = _affected_rows(first)
        pq.PQclear(first)
        return n
    _raise_result(errors, first, conn, sql)
    return 0  # unreachable: `_raise_result` always raises


def drain_results_quietly(conn: PGconnPtr):
    """Collect and discard every outstanding result, reporting nothing.

    The destructor's half of `drain_results`: a handle that is dropped rather
    than finished still has to leave the connection idle, and a destructor has
    nobody to raise to.

    Args:
        conn: The connection handle.
    """
    try:
        ref pq = libpq()
        while True:
            var res = pq.PQgetResult(conn)
            if res == 0:
                break
            pq.PQclear(res)
    except:
        pass


def discard_copy_quietly(conn: PGconnPtr, status: Int):
    """End whatever COPY `status` says is in progress, and drain it, silently.

    A COPY holds the connection until it is finished one way or another, and
    the way out depends on the direction: a ``COPY FROM STDIN`` is ended by
    telling libpq the stream failed, while a ``COPY TO STDOUT`` can only be
    consumed -- PostgreSQL offers no cancel for it.  This does whichever
    applies and then drains the results, so the connection comes back idle.

    Used by the COPY destructors, which have nobody to raise to, and by
    `Connection.copy_in`/`Connection.copy_out` when the statement started a
    COPY in the *other* direction.

    Args:
        conn: The connection handle.
        status: `_ffi.PGRES_COPY_IN`, `_ffi.PGRES_COPY_OUT` or
            `_ffi.PGRES_COPY_BOTH` -- the state the connection is in.  Any
            other value only drains.
    """
    try:
        ref pq = libpq()
        if status == PGRES_COPY_IN or status == PGRES_COPY_BOTH:
            _ = pq.PQputCopyEnd(conn, "the COPY was abandoned by the client")
        if status == PGRES_COPY_OUT or status == PGRES_COPY_BOTH:
            var sink = List[UInt8]()
            while True:
                sink.clear()
                if pq.PQgetCopyData(conn, sink) < 0:
                    break
    except:
        pass
    drain_results_quietly(conn)


# ===----------------------------------------------------------------------===#
# Statement
# ===----------------------------------------------------------------------===#


struct Statement(Movable):
    """A statement prepared on the server, ready to run with new parameters.

    Created by `Connection.prepare`.  Preparing pays for parsing and planning
    once; each `Statement.execute` or `Statement.query` then sends only the
    name and the parameter values.

    A prepared statement is **session-local**: it lives on the connection it
    was prepared on, until that connection closes or `Statement.deallocate`
    runs.  This type therefore holds the raw connection handle, not a
    reference to the `Connection` -- which is what keeps it free of an origin
    parameter, and means keeping a `Statement` does *not* keep the
    `Connection` alive.

    The cost of that is a rule the compiler cannot enforce for you:

    **A `Statement` must not outlive its `Connection`, or be used after
    `Connection.close`.**  The handle it holds is dangling at that point and
    using it is undefined behaviour, not an error.

    Watch for the case where that happens without anything leaving scope:
    **Mojo destroys a value after its last use, not at the end of the block**,
    so a connection whose final mention comes *before* the statement's is
    closed while the statement is still live.

    ```mojo
    var stmt = conn.prepare("s", "SELECT 1")   # the last mention of `conn` --
    _ = stmt.query()                           # so it is closed by now
    ```

    Any later use of the connection fixes it -- one is usually there already
    -- and ``_ = conn^`` after the last use of the statement says so
    explicitly.  The same applies to `Transaction`, `copy.CopyIn` and
    `copy.CopyOut`.

    Example:

    ```mojo
    var stmt = conn.prepare("insert_row", "INSERT INTO t VALUES ($1, $2)")
    for i in range(1000):
        _ = stmt.execute(Params().int64(i).text("row"))
    ```

    Note:
        Errors raised through a `Statement` *are* recorded in
        `Connection.last_error`: the statement holds a share of the same
        error cell the connection does.
    """

    var _conn: PGconnPtr
    """The connection the statement lives on; borrowed, never finished here."""
    var _errors: ArcPointer[_ErrorCell]
    """The connection's shared error cell; see `_ErrorCell`."""
    var _name: String
    """The server-side statement name."""
    var _sql: String
    """The SQL it was prepared from, kept for error messages."""

    def __init__(
        out self,
        conn: PGconnPtr,
        errors: ArcPointer[_ErrorCell],
        name: String,
        sql: String,
    ):
        """Record an already-prepared statement.

        `Connection.prepare` is the only intended caller: it issues
        `PQprepare` and checks the status before constructing this.

        Args:
            conn: The connection the statement was prepared on.
            errors: That connection's shared error cell.
            name: The server-side statement name.
            sql: The SQL it was prepared from.
        """
        self._conn = conn
        self._errors = errors
        self._name = name
        self._sql = sql

    def name(self) -> String:
        """The server-side statement name.

        Returns:
            The name given to `Connection.prepare`, which is also the name
            `Connection.execute_prepared` takes.
        """
        return self._name

    def sql(self) -> String:
        """The SQL this statement was prepared from.

        Returns:
            The statement text.
        """
        return self._sql

    def execute(self, params: Params = Params()) raises -> Int:
        """Run the statement and discard any rows.

        Args:
            params: The values for ``$1``, ``$2``, ....

        Returns:
            The rows the command affected, or ``0`` for a command that reports
            no count.

        Raises:
            Error: A `sqlstate.PostgresError` if the server rejected the
                command.
        """
        var bound = _bind(params)
        # `self._name.copy()`, not `self._name`: passing a `String` *field* of
        # this statement straight into `exec_prepared` miscompiles when the
        # `Statement` is captured by a parametric closure (`@parameter def`,
        # which is what `vectorize` and the benchmark harness take) -- libpq
        # is handed a garbage length and the process aborts in `alloc`.  One
        # small copy per execute, next to a network round trip, buys immunity
        # from that; both toolchains as of 1.0.0 need it.
        var name = self._name.copy()
        var res = exec_prepared(self._conn, name, bound.values, bound.nulls)
        var status = libpq().PQresultStatus(res)
        if (
            status == PGRES_COMMAND_OK
            or status == PGRES_TUPLES_OK
            or status == PGRES_EMPTY_QUERY
        ):
            var n = _affected_rows(res)
            libpq().PQclear(res)
            return n
        _raise_result(self._errors, res, self._conn, self._sql.copy())
        return 0  # unreachable: `_raise_result` always raises

    def query(self, params: Params = Params()) raises -> Result:
        """Run the statement and return its rows.

        Args:
            params: The values for ``$1``, ``$2``, ....

        Returns:
            The `Result`, empty (0 rows, 0 columns) for a statement that
            returns none.

        Raises:
            Error: A `sqlstate.PostgresError` if the server rejected the
                command.
        """
        var bound = _bind(params)
        var name = (
            self._name.copy()
        )  # a copy on purpose; see `Statement.execute`
        var res = exec_prepared(self._conn, name, bound.values, bound.nulls)
        var status = libpq().PQresultStatus(res)
        if (
            status == PGRES_TUPLES_OK
            or status == PGRES_COMMAND_OK
            or status == PGRES_EMPTY_QUERY
        ):
            return Result(res)
        _raise_result(self._errors, res, self._conn, self._sql.copy())
        raise Error("unreachable")  # `_raise_result` always raises

    def deallocate(mut self) raises:
        """Drop the statement from the server session.

        Rarely needed -- closing the connection drops every statement it
        prepared -- but a long-lived connection that prepares statements
        dynamically will otherwise accumulate them.

        Raises:
            Error: A `sqlstate.PostgresError` if ``DEALLOCATE`` failed, which
                for an already-deallocated statement is SQLSTATE ``26000``.
        """
        ref pq = libpq()
        var sql = "DEALLOCATE " + _quote_ident(self._name)
        var res = pq.PQexec(self._conn, sql)
        var status = pq.PQresultStatus(res)
        if status != PGRES_COMMAND_OK:
            _raise_result(self._errors, res, self._conn, sql)
        pq.PQclear(res)


# ===----------------------------------------------------------------------===#
# Connection
# ===----------------------------------------------------------------------===#


struct Connection(Movable):
    """One connection to a PostgreSQL server.

    Opening blocks until the connection succeeds or fails.  **Set
    ``connect_timeout``** in the conninfo (or on the `ConnectionConfig`, where
    it defaults to 10 seconds): without it, a host that silently drops packets
    blocks for the operating system's TCP timeout, which can be minutes.

    The connection is closed when the `Connection` is destroyed, or earlier by
    `Connection.close`.  Not copyable -- two owners would mean two
    `PQfinish`es.

    Example:

    ```mojo
    var conn = Connection("postgresql://user@localhost/app?connect_timeout=5")
    var n = conn.execute("DELETE FROM sessions WHERE expires < now()")
    print(n, "sessions expired")
    ```
    """

    var _conn: PGconnPtr
    """The owned ``PGconn *``; ``0`` once closed."""
    var _errors: ArcPointer[_ErrorCell]
    """The most recent error raised anywhere on this connection.

    Shared with every `Statement`, `Transaction`, `copy.CopyIn` and
    `copy.CopyOut` made from it, so `Connection.last_error` reports all of
    them; see `_ErrorCell`."""

    def __init__(out self, conninfo: String) raises:
        """Connect using a libpq conninfo string or URI.

        Args:
            conninfo: Either a URI --
                ``postgresql://user:pass@host:5432/db?sslmode=require`` -- or
                a keyword string -- ``host=localhost dbname=app
                connect_timeout=5``.  libpq parses both through the same entry
                point, and an empty string means "everything from the
                environment" (``PGHOST``, ``PGDATABASE``, ...).

        Raises:
            Error: A `sqlstate.PostgresError` with SQLSTATE
                `sqlstate.SQLCLIENT_UNABLE_TO_ESTABLISH` (08001) if the
                connection could not be established, carrying libpq's own
                explanation.
        """
        self._conn = 0
        self._errors = ArcPointer(_ErrorCell())

        ref pq = libpq()
        var conn = pq.PQconnectdb(conninfo)
        if pq.PQstatus(conn) != CONNECTION_OK:
            var message = _trim(pq.PQerrorMessage(conn))
            if message.byte_length() == 0:
                message = String("could not establish the connection")
            # A failed connection still allocates: finish it or leak it.
            pq.PQfinish(conn)
            _raise_error(
                self._errors,
                PostgresError(
                    severity="FATAL",
                    sqlstate=String(SQLCLIENT_UNABLE_TO_ESTABLISH),
                    message=message,
                ),
            )
        self._conn = conn

    def __init__(out self, config: ConnectionConfig) raises:
        """Connect using a typed `config.ConnectionConfig`.

        Args:
            config: The connection parameters; rendered with
                `config.ConnectionConfig.to_conninfo`.

        Raises:
            Error: A `sqlstate.PostgresError` with SQLSTATE 08001 if the
                connection could not be established.
        """
        self = Self(config.to_conninfo())

    def __deinit__(deinit self):
        """Close the connection if it is still open."""
        if self._conn != 0:
            try:
                libpq().PQfinish(self._conn)
            except:
                pass

    # -- lifecycle -----------------------------------------------------------

    def close(mut self):
        """Close the connection now.  Idempotent.

        Every `Result` already handed out stays valid -- their rows were
        copied out of libpq's memory -- but any `Statement` prepared on this
        connection is gone with the session.
        """
        if self._conn != 0:
            try:
                libpq().PQfinish(self._conn)
            except:
                pass
            self._conn = 0

    def is_open(self) -> Bool:
        """Whether the connection is open and usable.

        Returns:
            True while `PQstatus` reports `_ffi.CONNECTION_OK`.  It goes false
            only on a *fatal* error -- a rejected query leaves the connection
            perfectly usable.
        """
        if self._conn == 0:
            return False
        try:
            return libpq().PQstatus(self._conn) == CONNECTION_OK
        except:
            return False

    def ping(mut self) -> Bool:
        """Whether the server answers a trivial query right now.

        Stronger than `Connection.is_open`, which only reports libpq's cached
        view: this actually goes to the server, so it notices a connection
        that has died since the last command.

        Returns:
            True if ``SELECT 1`` succeeded.  Never raises -- a dead connection
            is the answer, not an error.
        """
        try:
            _ = self.execute("SELECT 1")
            return True
        except:
            return False

    def server_version(self) raises -> Int:
        """The version of the server on the other end.

        Returns:
            ``major * 10000 + minor`` (16.2 is ``160002``), or ``0`` if the
            connection is closed.  This is the *server*; the client library's
            version is `_ffi.LibpqFFI.PQlibVersion`.

        Raises:
            Error: Only if libpq itself could not be reached.
        """
        if self._conn == 0:
            return 0
        return libpq().PQserverVersion(self._conn)

    def transaction_status(self) raises -> Int:
        """Whether a transaction block is open on this connection.

        Returns:
            One of `_ffi.PQTRANS_IDLE`, `_ffi.PQTRANS_ACTIVE`,
            `_ffi.PQTRANS_INTRANS`, `_ffi.PQTRANS_INERROR` or
            `_ffi.PQTRANS_UNKNOWN`.  `_ffi.PQTRANS_INERROR` means the block
            has failed and will accept nothing but a rollback.

        Raises:
            Error: Only if libpq itself could not be reached.
        """
        return libpq().PQtransactionStatus(self._conn)

    def last_error(self) -> PostgresError:
        """The most recent error raised through this connection.

        The structured form of what was raised, so the SQLSTATE predicates are
        available without parsing the message back:

        ```mojo
        try:
            _ = conn.execute("INSERT INTO t VALUES (1)")
        except:
            if conn.last_error().is_unique_violation():
                ...
        ```

        Returns:
            A copy of the last `sqlstate.PostgresError`, or a default-built
            one -- every field empty -- if nothing has failed yet.  Errors
            raised through a `Statement`, a `Transaction` or a COPY handle
            made from this connection are recorded here too.
        """
        return self._errors[].error.copy()

    # -- internals -----------------------------------------------------------

    def _check_open(self) raises:
        """Raise unless the connection is open."""
        if self._conn == 0:
            _raise_error(self._errors, _closed_error())

    def _raise(mut self, res: PGresultPtr, sql: String) raises:
        """Record and raise the error behind a failed command, clearing `res`.

        Args:
            res: The failing result handle; ``0`` when libpq produced none.
                Cleared here.
            sql: The statement text, attached to the error.

        Raises:
            Error: Always -- a `sqlstate.PostgresError` formatted through
                `sqlstate.PostgresError.to_error`.
        """
        _raise_result(self._errors, res, self._conn, sql)

    def _run(mut self, sql: String, params: Params) raises -> PGresultPtr:
        """Send one command, parameterised or not, and hand back the result.

        Args:
            sql: The statement text.
            params: The parameters; empty selects the `PQexec` path.

        Returns:
            The result handle, of any status -- the caller checks it and owns
            it.

        Raises:
            Error: If the connection is closed, or the parameter lists are
                malformed.
        """
        self._check_open()
        if len(params) == 0:
            return libpq().PQexec(self._conn, sql)
        var bound = _bind(params)
        return exec_params(
            self._conn, sql, bound.values, bound.nulls, bound.oids
        )

    # -- commands ------------------------------------------------------------

    def execute(mut self, sql: String, params: Params = Params()) raises -> Int:
        """Run a command and discard any rows it returned.

        With no parameters this goes through `PQexec`, which accepts
        **several statements separated by semicolons** -- handy for a schema
        script, and the only reason to prefer it.  The return value is then
        the last statement's count, and the first failure aborts the rest.
        With parameters it goes through `PQexecParams`, which allows exactly
        one statement.

        Running a ``SELECT`` here is allowed: the rows are fetched and
        dropped, and the count of them is returned.  Use `Connection.query` if
        you want the rows themselves.

        Args:
            sql: The statement text, with ``$1``-style placeholders if
                `params` is non-empty.
            params: The parameter values; empty by default.

        Returns:
            The count in the server's command tag -- rows changed by an
            ``INSERT``/``UPDATE``/``DELETE``, rows returned by a ``SELECT``,
            and ``0`` for DDL and ``BEGIN``, which report no count.  For a
            multi-statement string this is the *last* statement's count.

        Raises:
            Error: A `sqlstate.PostgresError` if the connection is closed or
                the server rejected the command.  The SQLSTATE is recoverable
                from the message with `sqlstate.sqlstate_of`, and the whole
                structured error from `Connection.last_error`.
        """
        var res = self._run(sql, params)
        var status = libpq().PQresultStatus(res)
        if (
            status == PGRES_COMMAND_OK
            or status == PGRES_TUPLES_OK
            or status == PGRES_EMPTY_QUERY
        ):
            var n = _affected_rows(res)
            libpq().PQclear(res)
            return n
        self._raise(res, sql)
        return 0  # unreachable: `_raise` always raises

    def query(
        mut self, sql: String, params: Params = Params()
    ) raises -> Result:
        """Run a command and return its rows.

        Args:
            sql: The statement text, with ``$1``-style placeholders if
                `params` is non-empty.  With parameters libpq allows exactly
                one statement.
            params: The parameter values; empty by default.

        Returns:
            The `Result`.  A command that returns no rows -- an ``INSERT``,
            a ``CREATE TABLE`` -- yields an empty one (0 rows, 0 columns)
            rather than an error, with the count in
            `result.Result.affected_rows`.

        Raises:
            Error: A `sqlstate.PostgresError` if the connection is closed or
                the server rejected the command.
        """
        var res = self._run(sql, params)
        var status = libpq().PQresultStatus(res)
        if (
            status == PGRES_TUPLES_OK
            or status == PGRES_COMMAND_OK
            or status == PGRES_EMPTY_QUERY
        ):
            return Result(res)
        self._raise(res, sql)
        raise Error("unreachable")  # `_raise` always raises

    # -- prepared statements -------------------------------------------------

    def prepare(mut self, name: String, sql: String) raises -> Statement:
        """Prepare `sql` on the server under `name`.

        Parameter types are left to the server to infer from the statement --
        which is what you want in almost every case, and why there is no OID
        argument.  Add a cast (``$1::int``) where the inference would
        otherwise land on ``text``.

        Args:
            name: The statement name.  ``""`` is libpq's unnamed statement,
                which the next `Connection.prepare` on this connection
                replaces.  Any other name persists until the session ends or
                `Statement.deallocate` runs, and re-preparing the same name
                is an error (SQLSTATE ``42P05``).
            sql: The statement text, with ``$1``, ``$2``, ... placeholders.

        Returns:
            The `Statement`, ready to run.

        Raises:
            Error: A `sqlstate.PostgresError` if the statement did not parse
                or the name is already taken.
        """
        self._check_open()
        ref pq = libpq()
        var res = pq.PQprepare(self._conn, name, sql, List[UInt32]())
        if pq.PQresultStatus(res) != PGRES_COMMAND_OK:
            self._raise(res, sql)
        pq.PQclear(res)
        return Statement(self._conn, self._errors, name, sql)

    def execute_prepared(
        mut self, name: String, params: Params = Params()
    ) raises -> Int:
        """Run the prepared statement `name` and discard any rows.

        The method `Statement.execute` is a convenience over; use it directly
        when the statement was prepared elsewhere -- by another library, or by
        a ``PREPARE`` statement -- and there is no `Statement` value in hand.

        Args:
            name: The server-side statement name.
            params: The values for ``$1``, ``$2``, ....

        Returns:
            The rows the command affected.

        Raises:
            Error: A `sqlstate.PostgresError` if the connection is closed, no
                such statement is prepared (SQLSTATE ``26000``), or the server
                rejected the command.
        """
        self._check_open()
        var bound = _bind(params)
        var res = exec_prepared(self._conn, name, bound.values, bound.nulls)
        var status = libpq().PQresultStatus(res)
        if (
            status == PGRES_COMMAND_OK
            or status == PGRES_TUPLES_OK
            or status == PGRES_EMPTY_QUERY
        ):
            var n = _affected_rows(res)
            libpq().PQclear(res)
            return n
        self._raise(res, "EXECUTE " + name)
        return 0  # unreachable: `_raise` always raises

    def query_prepared(
        mut self, name: String, params: Params = Params()
    ) raises -> Result:
        """Run the prepared statement `name` and return its rows.

        Args:
            name: The server-side statement name.
            params: The values for ``$1``, ``$2``, ....

        Returns:
            The `Result`.

        Raises:
            Error: A `sqlstate.PostgresError` if the connection is closed, no
                such statement is prepared, or the server rejected the
                command.
        """
        self._check_open()
        var bound = _bind(params)
        var res = exec_prepared(self._conn, name, bound.values, bound.nulls)
        var status = libpq().PQresultStatus(res)
        if (
            status == PGRES_TUPLES_OK
            or status == PGRES_COMMAND_OK
            or status == PGRES_EMPTY_QUERY
        ):
            return Result(res)
        self._raise(res, "EXECUTE " + name)
        raise Error("unreachable")  # `_raise` always raises

    # -- transactions --------------------------------------------------------

    def begin(mut self) raises -> Transaction:
        """Issue ``BEGIN`` and return the guard that ends the block.

        The returned `Transaction` rolls back when it is destroyed unless
        `Transaction.commit` or `Transaction.rollback` ran first, so the
        failure mode of forgetting about it is "nothing happened" rather than
        "half of it happened".  Statements inside the block go through the
        `Transaction`'s own `Transaction.execute` and `Transaction.query`,
        which are the same calls with the same error path.

        Returns:
            The open transaction.

        Raises:
            Error: A `sqlstate.PostgresError` if the connection is closed, if
                ``BEGIN`` itself failed, or -- SQLSTATE ``25001`` -- if a
                transaction block is **already** open on this connection.
                PostgreSQL answers a nested ``BEGIN`` with a warning and
                ignores it, which would leave the second guard's ``COMMIT``
                ending the first one's block; raising is the only way to keep
                the guard's promise.
        """
        self._check_open()
        var status = libpq().PQtransactionStatus(self._conn)
        if status == PQTRANS_UNKNOWN:
            _raise_error(self._errors, _closed_error())
        if status != PQTRANS_IDLE:
            _raise_error(
                self._errors,
                PostgresError(
                    severity="ERROR",
                    sqlstate=String(ACTIVE_SQL_TRANSACTION),
                    message=(
                        "a transaction is already open on this connection;"
                        " commit or roll it back, or use a savepoint, before"
                        " calling begin() again"
                    ),
                    sql="BEGIN",
                ),
            )
        return Transaction(self._conn, self._errors)

    # -- COPY ----------------------------------------------------------------

    def copy_in(mut self, sql: String) raises -> CopyIn:
        """Start a ``COPY ... FROM STDIN`` and return the handle to write to.

        The fast path for bulk loading: one statement, then rows streamed
        straight into the table with no per-row parse, plan or round trip.
        Encode the rows with `copyfmt.CopyEncoder` and hand them to
        `copy.CopyIn.write_rows`, or write already-formatted bytes with
        `copy.CopyIn.write`.

        Args:
            sql: The full ``COPY`` statement, for example ``COPY t (a, b)
                FROM STDIN`` or ``COPY t FROM STDIN (FORMAT csv)``.  It takes
                no parameters -- ``COPY`` never has -- so this goes through
                `PQexec`.

        Returns:
            The open `copy.CopyIn`.

        Raises:
            Error: A `sqlstate.PostgresError` if the connection is closed, the
                server rejected the statement (a missing table is ``42P01``),
                or -- SQLSTATE ``42809`` -- the statement was valid but did
                not start a ``COPY ... FROM STDIN``.
        """
        self._check_open()
        var res = libpq().PQexec(self._conn, sql)
        var status = libpq().PQresultStatus(res)
        if status != PGRES_COPY_IN:
            self._copy_mismatch(res, status, sql, "FROM STDIN")
        libpq().PQclear(res)
        return CopyIn(self._conn, self._errors, sql)

    def copy_out(mut self, sql: String) raises -> CopyOut:
        """Start a ``COPY ... TO STDOUT`` and return the handle to read from.

        Args:
            sql: The full ``COPY`` statement, for example ``COPY t TO
                STDOUT`` or ``COPY (SELECT ...) TO STDOUT (FORMAT csv)``.

        Returns:
            The open `copy.CopyOut`.

        Raises:
            Error: A `sqlstate.PostgresError` if the connection is closed, the
                server rejected the statement, or -- SQLSTATE ``42809`` -- the
                statement did not start a ``COPY ... TO STDOUT``.
        """
        self._check_open()
        var res = libpq().PQexec(self._conn, sql)
        var status = libpq().PQresultStatus(res)
        if status != PGRES_COPY_OUT:
            self._copy_mismatch(res, status, sql, "TO STDOUT")
        libpq().PQclear(res)
        return CopyOut(self._conn, self._errors, sql)

    def _copy_mismatch(
        mut self, res: PGresultPtr, status: Int, sql: String, wanted: String
    ) raises:
        """Raise for a statement that did not start the COPY it was asked to.

        Args:
            res: The result handle; cleared here.
            status: Its `LibpqFFI.PQresultStatus`.
            sql: The statement text.
            wanted: ``"FROM STDIN"`` or ``"TO STDOUT"``, for the message.

        Raises:
            Error: Always -- the server's own error if the statement failed,
                otherwise a `sqlstate.PostgresError` with SQLSTATE ``42809``.
        """
        if (
            status == PGRES_COMMAND_OK
            or status == PGRES_TUPLES_OK
            or status == PGRES_EMPTY_QUERY
            or status == PGRES_COPY_IN
            or status == PGRES_COPY_OUT
            or status == PGRES_COPY_BOTH
        ):
            var named = libpq().PQresStatus(status)
            libpq().PQclear(res)
            # It ran -- it is simply not the COPY that was asked for.  It may
            # even be a COPY in the other direction, which is holding the
            # connection: end it before raising, or every later command fails.
            discard_copy_quietly(self._conn, status)
            _raise_error(
                self._errors,
                PostgresError(
                    severity="ERROR",
                    sqlstate=String(WRONG_OBJECT_TYPE),
                    message=(
                        "the statement did not start a COPY ... "
                        + wanted
                        + " (libpq reported "
                        + named
                        + ")"
                    ),
                    sql=sql,
                ),
            )
        self._raise(res, sql)


# ===----------------------------------------------------------------------===#
# Transaction
# ===----------------------------------------------------------------------===#


struct Transaction(Movable):
    """An open transaction block, and the guard that ends it.

    Created by `Connection.begin`, which issues ``BEGIN``.  Run the block's
    statements through `Transaction.execute` and `Transaction.query` -- the
    same calls as the `Connection`'s, with the same parameters and the same
    errors -- and finish with `Transaction.commit`:

    ```mojo
    var tx = conn.begin()
    _ = tx.execute("INSERT INTO orders VALUES ($1)", Params().int64(1))
    _ = tx.execute("INSERT INTO items VALUES ($1, $2)",
                   Params().int64(1).int32(3))
    tx.commit()
    ```

    **Destruction rolls back.**  If the guard is destroyed without a
    `Transaction.commit` -- an early return, a raised error, a forgotten call
    -- its destructor issues ``ROLLBACK``.  The failure mode of losing track
    of a transaction is therefore "nothing happened", never "half of it
    happened".  Since a `with` block ends by destroying the guard, that is
    also what makes this shape work:

    ```mojo
    with conn.begin() as tx:
        _ = tx.execute("INSERT INTO orders VALUES ($1)", Params().int64(1))
        tx.commit()          # explicit: leaving the block does NOT commit
    ```

    Leaving that block without the `Transaction.commit` line -- by falling off
    the end, by returning, or by raising -- rolls back.  There is no implicit
    commit anywhere in this type.

    **A failed block cannot be committed.**  PostgreSQL turns a ``COMMIT``
    inside a failed transaction into a ``ROLLBACK`` and reports success;
    `Transaction.commit` raises SQLSTATE ``25P02`` instead, after issuing the
    ``ROLLBACK`` itself so the connection is left clean.  Recover from a
    failed statement with `Transaction.savepoint` and
    `Transaction.rollback_to`.

    Like `Statement`, this holds the raw connection handle rather than a
    reference to the `Connection`, so the same rule applies:

    **A `Transaction` must not outlive its `Connection`, or be used after
    `Connection.close`.**  Mind in particular that Mojo destroys a value after
    its *last use*, not at the end of the block -- see `Statement`, which
    documents that hazard and the ``_ = conn^`` that settles it.
    """

    var _conn: PGconnPtr
    """The connection the block is open on; borrowed, never finished here."""
    var _errors: ArcPointer[_ErrorCell]
    """The connection's shared error cell; see `_ErrorCell`."""
    var _done: Bool
    """True once committed or rolled back; silences the destructor."""

    def __init__(
        out self, conn: PGconnPtr, errors: ArcPointer[_ErrorCell]
    ) raises:
        """Issue ``BEGIN`` on `conn`.

        `Connection.begin` is the only intended caller: it checks that the
        connection is open and that no block is open already.

        Args:
            conn: The connection to open a transaction on.
            errors: That connection's shared error cell.

        Raises:
            Error: A `sqlstate.PostgresError` if ``BEGIN`` failed.
        """
        self._conn = conn
        self._errors = errors
        self._done = False
        _ = self._command("BEGIN")

    def __deinit__(deinit self):
        """Roll back unless the block was already committed or rolled back.

        Unconditional: a ``ROLLBACK`` is accepted in every transaction state,
        including the failed one where nothing else is, and it is the only
        statement that leaves the connection idle again.  Errors are swallowed
        -- a destructor has nobody to raise to, and a connection that has died
        has already lost the transaction.
        """
        if not self._done:
            try:
                ref pq = libpq()
                var res = pq.PQexec(self._conn, "ROLLBACK")
                pq.PQclear(res)
            except:
                pass

    def __enter__(deinit self) -> Self:
        """Hand the guard to ``with conn.begin() as tx:``.

        The guard is transferred into the block rather than borrowed, so it is
        destroyed -- and therefore rolled back, unless `Transaction.commit`
        ran -- when the block ends, however it ends.

        Returns:
            This transaction, moved.
        """
        return self^

    # -- state ---------------------------------------------------------------

    def is_open(self) -> Bool:
        """Whether the block is still open.

        Returns:
            True until `Transaction.commit` or `Transaction.rollback` runs.
            It says nothing about whether the block has *failed* -- for that,
            ask `Connection.transaction_status` for `_ffi.PQTRANS_INERROR`.
        """
        return not self._done

    # -- internals -----------------------------------------------------------

    def _check_active(self) raises:
        """Raise unless the block is still open."""
        if self._done:
            _raise_error(
                self._errors,
                PostgresError(
                    severity="ERROR",
                    sqlstate=String(NO_ACTIVE_SQL_TRANSACTION),
                    message=(
                        "the transaction is finished; it was already"
                        " committed or rolled back"
                    ),
                ),
            )

    def _command(self, sql: String) raises -> Int:
        """Run one parameterless statement, raising through the error cell.

        Args:
            sql: The statement text.

        Returns:
            The count in the server's command tag, or ``0``.

        Raises:
            Error: A `sqlstate.PostgresError` if the server rejected it.
        """
        ref pq = libpq()
        var res = pq.PQexec(self._conn, sql)
        var status = pq.PQresultStatus(res)
        if (
            status == PGRES_COMMAND_OK
            or status == PGRES_TUPLES_OK
            or status == PGRES_EMPTY_QUERY
        ):
            var n = _affected_rows(res)
            pq.PQclear(res)
            return n
        _raise_result(self._errors, res, self._conn, sql)
        return 0  # unreachable: `_raise_result` always raises

    # -- commands ------------------------------------------------------------

    def execute(mut self, sql: String, params: Params = Params()) raises -> Int:
        """Run a command inside the block and discard any rows.

        `Connection.execute`'s behaviour exactly, including the `PQexec` path
        for a parameterless call and the multi-statement strings that allows.

        Args:
            sql: The statement text, with ``$1``-style placeholders if
                `params` is non-empty.
            params: The parameter values; empty by default.

        Returns:
            The count in the server's command tag; ``0`` for a command that
            reports none.

        Raises:
            Error: A `sqlstate.PostgresError` if the transaction is finished
                or the server rejected the command.  A rejected statement puts
                the block in the failed state, where nothing but a rollback --
                whole, or to a savepoint -- will be accepted.
        """
        self._check_active()
        var res = self._run(sql, params)
        var status = libpq().PQresultStatus(res)
        if (
            status == PGRES_COMMAND_OK
            or status == PGRES_TUPLES_OK
            or status == PGRES_EMPTY_QUERY
        ):
            var n = _affected_rows(res)
            libpq().PQclear(res)
            return n
        _raise_result(self._errors, res, self._conn, sql)
        return 0  # unreachable: `_raise_result` always raises

    def query(
        mut self, sql: String, params: Params = Params()
    ) raises -> Result:
        """Run a command inside the block and return its rows.

        Args:
            sql: The statement text, with ``$1``-style placeholders if
                `params` is non-empty.
            params: The parameter values; empty by default.

        Returns:
            The `Result`; empty (0 rows, 0 columns) for a command that returns
            none.

        Raises:
            Error: A `sqlstate.PostgresError` if the transaction is finished
                or the server rejected the command.
        """
        self._check_active()
        var res = self._run(sql, params)
        var status = libpq().PQresultStatus(res)
        if (
            status == PGRES_TUPLES_OK
            or status == PGRES_COMMAND_OK
            or status == PGRES_EMPTY_QUERY
        ):
            return Result(res)
        _raise_result(self._errors, res, self._conn, sql)
        raise Error("unreachable")  # `_raise_result` always raises

    def _run(self, sql: String, params: Params) raises -> PGresultPtr:
        """Send one command, parameterised or not, and hand back the result.

        Args:
            sql: The statement text.
            params: The parameters; empty selects the `PQexec` path.

        Returns:
            The result handle, of any status -- the caller checks it and owns
            it.

        Raises:
            Error: If the parameter lists are malformed.
        """
        if len(params) == 0:
            return libpq().PQexec(self._conn, sql)
        var bound = _bind(params)
        return exec_params(
            self._conn, sql, bound.values, bound.nulls, bound.oids
        )

    # -- savepoints ----------------------------------------------------------

    def savepoint(mut self, name: String) raises:
        """Mark a point inside the block to come back to.

        The way to survive a *failed* statement without losing the whole
        transaction: set a savepoint, try the statement, and
        `Transaction.rollback_to` the savepoint if it fails.  The block is
        usable again afterwards.

        Args:
            name: The savepoint name, spliced into the SQL as a quoted
                identifier -- ``SAVEPOINT`` takes an identifier, and
                identifiers cannot be parameters.  Any embedded double quotes
                are doubled, so a name can never end the quoting early.
                Re-using a name is allowed: the newer savepoint hides the
                older one, which is still there after a
                `Transaction.release`.

        Raises:
            Error: A `sqlstate.PostgresError` if the transaction is finished,
                or if the block has already failed -- a savepoint cannot be
                *set* in the failed state, only rolled back to.
        """
        self._check_active()
        _ = self._command("SAVEPOINT " + _quote_ident(name))

    def rollback_to(mut self, name: String) raises:
        """Undo everything after the savepoint `name`, keeping the block open.

        Also clears the failed state, which is the point: after this the
        transaction accepts statements again and can still be committed.

        Args:
            name: The savepoint name, quoted as an identifier.

        Raises:
            Error: A `sqlstate.PostgresError` if the transaction is finished,
                or if there is no such savepoint (SQLSTATE ``3B001``).
        """
        self._check_active()
        _ = self._command("ROLLBACK TO SAVEPOINT " + _quote_ident(name))

    def release(mut self, name: String) raises:
        """Forget the savepoint `name`, keeping everything done since it.

        The opposite of `Transaction.rollback_to`: the work stays, and the
        savepoint -- along with every savepoint set after it -- is gone.

        Args:
            name: The savepoint name, quoted as an identifier.

        Raises:
            Error: A `sqlstate.PostgresError` if the transaction is finished,
                or if there is no such savepoint (SQLSTATE ``3B001``).
        """
        self._check_active()
        _ = self._command("RELEASE SAVEPOINT " + _quote_ident(name))

    # -- ending the block ----------------------------------------------------

    def commit(mut self) raises:
        """Commit the block, making everything in it permanent.

        The destructor becomes a no-op afterwards, and the `Transaction` is
        finished: any further use raises.

        Raises:
            Error: A `sqlstate.PostgresError` if the transaction is already
                finished, if ``COMMIT`` itself failed, or -- SQLSTATE
                ``25P02``, ``transaction is aborted`` -- if a statement inside
                the block failed and was not rolled back to a savepoint.
                PostgreSQL would answer that ``COMMIT`` with ``ROLLBACK`` and
                report success, so a caller who did not check every statement
                would believe the block had been committed; the ``ROLLBACK``
                is issued here too, leaving the connection idle, but the
                outcome is *reported* rather than hidden.
        """
        self._check_active()
        if libpq().PQtransactionStatus(self._conn) == PQTRANS_INERROR:
            # The block is dead either way; end it cleanly, then say so.
            try:
                _ = self._command("ROLLBACK")
            except:
                pass
            self._done = True
            _raise_error(
                self._errors,
                PostgresError(
                    severity="ERROR",
                    sqlstate=String(IN_FAILED_SQL_TRANSACTION),
                    message=(
                        "transaction is aborted; roll back or roll back to a"
                        " savepoint. The transaction has been rolled back and"
                        " nothing in it was committed"
                    ),
                    sql="COMMIT",
                ),
            )
        _ = self._command("COMMIT")
        self._done = True

    def rollback(mut self) raises:
        """Roll the block back, discarding everything in it.

        Accepted in every state, including the failed one.  The destructor
        becomes a no-op afterwards, and the `Transaction` is finished: any
        further use raises.

        Raises:
            Error: A `sqlstate.PostgresError` if the transaction is already
                finished, or if ``ROLLBACK`` itself failed -- which in
                practice means the connection has gone.
        """
        self._check_active()
        _ = self._command("ROLLBACK")
        self._done = True
