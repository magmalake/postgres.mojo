"""`postgres.copy` — bulk transfer with ``COPY``, in both directions.

``COPY`` is PostgreSQL's bulk path: one statement sets up the stream, and rows
then flow over the connection with no per-row parse, plan or round trip.  It is
the fastest way to load a table by a wide margin, and the fastest way to read
one out whole.

Two handles, both from a `connection.Connection`:

```mojo
from postgres import Connection, CopyEncoder, decode_row, COPY_TEXT

var conn = Connection("postgresql://localhost/app")
_ = conn.execute("CREATE TABLE t (id bigint, name text)")

var cp = conn.copy_in("COPY t (id, name) FROM STDIN")
var enc = CopyEncoder()
for i in range(100_000):
    enc.field(String(i))
    enc.field("row")
    enc.end_row()
    if enc.size() > 1 << 16:
        cp.write_rows(enc)          # flush whole rows as they accumulate
cp.write_rows(enc)
print(cp.finish(), "rows loaded")   # 100000

var out = conn.copy_out("COPY t TO STDOUT")
for line in out.rows():
    var fields = decode_row(line, COPY_TEXT, "\\t", "\\N")
    print(fields[0].value(), fields[1].value())
```

`copyfmt.CopyEncoder` and `copyfmt.decode_row` are the codec for what flows
through the pipe -- text or CSV, escaping and NULLs -- and know nothing about
libpq.  This module is the pipe: it owns the protocol state, and the rule that
state imposes.

**A COPY holds the connection.**  From the moment `connection.Connection.copy_in`
or `connection.Connection.copy_out` returns until the handle is finished,
aborted or destroyed, the connection is in COPY mode and will accept nothing
else -- and the handle keeps that connection open for as long as it lives, so
the `Connection` value may be dropped in the meantime.  Both handles therefore clean up after themselves when destroyed --
`CopyIn` aborts, `CopyOut` drains -- so a handle that goes out of scope early
leaves a connection that still works.  Draining is the only way out of a
``COPY TO STDOUT`` short of closing the connection: PostgreSQL has no cancel
for it, so `CopyOut.__deinit__` reads the rest of the stream and throws it
away, which for a large table costs the time to transfer it.

**Errors arrive at the end.**  The server validates rows as it reads them, but
a `CopyIn.write` only queues bytes: a malformed row surfaces from
`CopyIn.finish`, as the server's own error (``22P02`` for a bad number, with
the offending line in its ``CONTEXT``).  Do not read a `CopyIn.write` returning
normally as "the rows were accepted".
"""

from std.memory import ArcPointer

from ._ffi import PGconnPtr, libpq
from ._ffi import PGRES_COPY_IN, PGRES_COPY_OUT
from .connection import (
    _ConnCell,
    _open_conn,
    _raise_error,
    discard_copy_quietly,
    drain_results,
    drain_results_quietly,
)
from .copyfmt import CopyEncoder
from .sqlstate import CONNECTION_FAILURE, PostgresError


def _put_failed(conn: PGconnPtr, sql: String) raises -> PostgresError:
    """The error behind a failed `LibpqFFI.PQputCopyData`/`PQputCopyEnd`.

    libpq -- not the server -- reports these, so there is no result and no
    SQLSTATE to read: in practice the only way to get one is a connection that
    has died mid-stream, which is what `sqlstate.CONNECTION_FAILURE` means.

    Args:
        conn: The connection handle, for `LibpqFFI.PQerrorMessage`.
        sql: The ``COPY`` statement, attached to the error.

    Returns:
        The error, ready to record and raise.

    Raises:
        Error: Only if libpq itself could not be reached.
    """
    var message = libpq().PQerrorMessage(conn)
    if message.byte_length() == 0:
        message = String("the COPY data could not be sent")
    return PostgresError(
        severity="FATAL",
        sqlstate=String(CONNECTION_FAILURE),
        message=message,
        sql=sql,
    )


# ===----------------------------------------------------------------------===#
# CopyIn
# ===----------------------------------------------------------------------===#


struct CopyIn(Movable):
    """A ``COPY ... FROM STDIN`` in progress: write rows, then finish.

    Created by `connection.Connection.copy_in`.  Bytes written here are the
    COPY data itself in the format the statement declared -- text by default,
    CSV with ``(FORMAT csv)`` -- which `copyfmt.CopyEncoder` produces.

    Chunks need not align with rows on the way to `CopyIn.write`, but
    `CopyIn.finish` must not be called mid-row: flush whole rows.
    `CopyIn.write_rows` does that for you.

    **Finish it, or it is aborted.**  `CopyIn.finish` is what commits the
    rows; if the handle is destroyed first -- an early return, a raised error
    -- `CopyIn.abort` runs instead and the server discards everything the
    stream carried.  Nothing is half-loaded either way, since ``COPY`` is a
    single statement and rolls back as one.

    Like `connection.Statement`, this shares ownership of the connection
    rather than borrowing it, so the session stays open for as long as the
    COPY does even if the `Connection` value was dropped first -- which Mojo
    does at its last use.  An explicit `connection.Connection.close` ends the
    COPY: every call then raises SQLSTATE ``08006``.
    """

    var _cell: ArcPointer[_ConnCell]
    """The connection the COPY is running on, shared; see `_ConnCell`."""
    var _sql: String
    """The ``COPY`` statement, kept for error messages."""
    var _done: Bool
    """True once finished or aborted; silences the destructor."""

    def __init__(out self, cell: ArcPointer[_ConnCell], sql: String):
        """Record a COPY that libpq has already put into `PGRES_COPY_IN`.

        `connection.Connection.copy_in` is the only intended caller: it runs
        the statement and checks the status before constructing this.

        Args:
            cell: The shared cell of the connection the COPY is running on; a
                share of it is kept, so the connection stays open at least as
                long as this handle does.
            sql: The ``COPY`` statement text.
        """
        self._cell = cell
        self._sql = sql
        self._done = False

    def __deinit__(deinit self):
        """Abort the COPY unless it was already finished or aborted.

        The server is told the stream failed and discards it, and the
        outstanding results are drained so the connection is idle again.
        Errors are swallowed -- a destructor has nobody to raise to -- and a
        connection that has been closed is left alone.
        """
        if not self._done and self._cell[].conn != 0:
            discard_copy_quietly(self._cell[].conn, PGRES_COPY_IN)

    # -- state ---------------------------------------------------------------

    def is_open(self) -> Bool:
        """Whether the COPY is still accepting data.

        Returns:
            True until `CopyIn.finish` or `CopyIn.abort` runs.
        """
        return not self._done

    def _check_open(self) raises:
        """Raise unless the COPY is still open."""
        if self._done:
            _raise_error(
                self._cell,
                PostgresError(
                    severity="ERROR",
                    sqlstate=String(CONNECTION_FAILURE),
                    message="the COPY is finished; it accepts no more data",
                    sql=self._sql.copy(),
                ),
            )

    # -- writing -------------------------------------------------------------

    def write(mut self, data: Span[UInt8, _]) raises:
        """Queue `data` as the next bytes of the COPY stream.

        libpq copies the bytes into its own buffer before returning, so
        nothing has to be kept alive afterwards.

        Args:
            data: Raw COPY data, in the format the statement declared.  Not
                required to end on a row boundary; an empty span is a no-op.

        Raises:
            Error: A `sqlstate.PostgresError` if the COPY is already finished,
                or if libpq could not queue the data -- which means the
                connection has gone.  A row the *server* rejects is not
                reported here; see `CopyIn.finish`.
        """
        self._check_open()
        var conn = _open_conn(self._cell)
        if libpq().PQputCopyData(conn, data) < 0:
            _raise_error(self._cell, _put_failed(conn, self._sql.copy()))

    def write(mut self, data: String) raises:
        """Queue `data` as the next bytes of the COPY stream.

        The overload for callers holding text rather than bytes -- both COPY
        sub-formats this tin encodes are text.

        Args:
            data: Raw COPY data, in the format the statement declared.

        Raises:
            Error: A `sqlstate.PostgresError` if the COPY is already finished
                or the data could not be queued.
        """
        self.write(data.as_bytes())

    def write_rows(mut self, mut encoder: CopyEncoder) raises:
        """Flush everything buffered in `encoder` into the stream.

        The usual way to drive a COPY: append rows to the encoder, and call
        this whenever `copyfmt.CopyEncoder.size` has grown enough to be worth
        a write.  The encoder is emptied, so the same one can be refilled and
        flushed again as many times as the load needs.

        Args:
            encoder: The encoder to take the buffered bytes from.  Flush only
                after `copyfmt.CopyEncoder.end_row`: a partial row would split
                across writes correctly, but `CopyIn.finish` must not land in
                the middle of one.

        Raises:
            Error: A `sqlstate.PostgresError` if the COPY is already finished
                or the data could not be queued.
        """
        var bytes = encoder.take()
        if len(bytes) == 0:
            return
        self._check_open()
        var conn = _open_conn(self._cell)
        if libpq().PQputCopyData(conn, bytes) < 0:
            _raise_error(self._cell, _put_failed(conn, self._sql.copy()))

    # -- ending the stream ---------------------------------------------------

    def finish(mut self) raises -> Int:
        """End the stream, commit the rows, and report how many there were.

        Every write so far is flushed, the server finishes reading, and the
        outstanding results are drained -- which is where the server's verdict
        on the data arrives.

        Returns:
            The number of rows the COPY loaded, from the command tag.

        Raises:
            Error: A `sqlstate.PostgresError` if the COPY was already
                finished, or if the server rejected the data.  A malformed row
                is the usual cause and reports the type's own SQLSTATE --
                ``22P02`` for text that is not a valid number -- with the
                offending line in the error's ``CONTEXT``.  The connection is
                idle and usable afterwards either way.
        """
        self._check_open()
        var conn = _open_conn(self._cell)
        self._done = True
        if libpq().PQputCopyEnd(conn) < 0:
            var err = _put_failed(conn, self._sql.copy())
            drain_results_quietly(conn)
            _raise_error(self._cell, err)
        # A copy of `_sql`, not the field itself; see `connection.Statement`.
        return drain_results(conn, self._cell, self._sql.copy())

    def abort(mut self, reason: String = "COPY aborted by the client") raises:
        """End the stream by failing it, so the server discards every row.

        The deliberate counterpart to `CopyIn.finish`, and what the destructor
        does on its own.  This does *not* raise: the failure is the point.

        Args:
            reason: The text the server attaches to the error it records for
                the aborted COPY.  It appears in the server log, not in
                anything raised here.

        Raises:
            Error: Only if the COPY was already finished or aborted.  The
                abort itself is silent, whatever libpq makes of it.
        """
        self._check_open()
        var conn = _open_conn(self._cell)
        self._done = True
        _ = libpq().PQputCopyEnd(conn, reason)
        drain_results_quietly(conn)


# ===----------------------------------------------------------------------===#
# CopyOut
# ===----------------------------------------------------------------------===#


struct CopyOut(Movable):
    """A ``COPY ... TO STDOUT`` in progress: read rows until they run out.

    Created by `connection.Connection.copy_out`.  libpq delivers **one whole
    row per call** whatever the chunking on the wire, so `CopyOut.next` never
    hands back a partial line and a field containing a raw newline cannot be
    mistaken for a row boundary.

    ```mojo
    var out = conn.copy_out("COPY t TO STDOUT")
    var chunk = List[UInt8]()
    while out.next(chunk):
        ...                    # `chunk` is one row, newline included
    ```

    `CopyOut.rows` is the same loop with the newline stripped and each row as
    a `String`, ready for `copyfmt.decode_row`; `CopyOut.read_all` is the whole
    stream in one buffer, for `copyfmt.split_rows`.

    **Abandoning one costs the transfer.**  PostgreSQL cannot cancel a ``COPY
    TO STDOUT``: the only ways out are to consume it or to close the
    connection.  Dropping the handle early therefore drains the rest of the
    stream in `CopyOut.__deinit__` -- correct, and on a large table not free.

    Like `connection.Statement`, this shares ownership of the connection
    rather than borrowing it, which matters most here: the handle is normally
    used *after* the last mention of the connection, and Mojo destroys a value
    at its last use.  The session stays open for the stream either way.

    ```mojo
    var out = conn.copy_out("COPY t TO STDOUT")   # last mention of `conn`,
    var lines = out.rows()                        # and the stream is still up
    ```

    An explicit `connection.Connection.close` is the exception, and ends the
    stream: every call then raises SQLSTATE ``08006``.
    """

    var _cell: ArcPointer[_ConnCell]
    """The connection the COPY is running on, shared; see `_ConnCell`."""
    var _sql: String
    """The ``COPY`` statement, kept for error messages."""
    var _done: Bool
    """True once the stream has been read to its end."""

    def __init__(out self, cell: ArcPointer[_ConnCell], sql: String):
        """Record a COPY that libpq has already put into `PGRES_COPY_OUT`.

        `connection.Connection.copy_out` is the only intended caller: it runs
        the statement and checks the status before constructing this.

        Args:
            cell: The shared cell of the connection the COPY is running on; a
                share of it is kept, so the connection stays open at least as
                long as this handle does.
            sql: The ``COPY`` statement text.
        """
        self._cell = cell
        self._sql = sql
        self._done = False

    def __deinit__(deinit self):
        """Consume whatever is left of the stream, leaving the connection idle.

        There is no way to tell the server to stop, so the rest of the rows
        are read and dropped and the outstanding results are drained.  Errors
        are swallowed -- a destructor has nobody to raise to -- and a
        connection that has been closed is left alone.
        """
        if not self._done and self._cell[].conn != 0:
            discard_copy_quietly(self._cell[].conn, PGRES_COPY_OUT)

    # -- state ---------------------------------------------------------------

    def is_open(self) -> Bool:
        """Whether there may be more rows to read.

        Returns:
            True until `CopyOut.next` has reported the end of the stream.
        """
        return not self._done

    # -- reading -------------------------------------------------------------

    def next(mut self, mut chunk: List[UInt8]) raises -> Bool:
        """Read the next row into `chunk`.

        Args:
            chunk: The destination, **cleared first**.  On True it holds
                exactly one row, including its trailing newline; on False it
                is empty.  Passing the same list back each time reuses its
                allocation.

        Returns:
            True if a row was read, False once the stream is complete -- at
            which point the outstanding results have been drained and the
            connection is idle again.

        Raises:
            Error: A `sqlstate.PostgresError` if the transfer failed, either
                while reading (libpq reports it, so ``08006``) or in the
                server's terminating result -- a ``COPY (SELECT ...)`` whose
                query fails halfway through reports it there.
        """
        chunk.clear()
        if self._done:
            return False
        var conn = _open_conn(self._cell)
        var n = libpq().PQgetCopyData(conn, chunk)
        if n > 0:
            return True
        self._done = True
        if n == -2:
            var message = libpq().PQerrorMessage(conn)
            if message.byte_length() == 0:
                message = String("the COPY data could not be read")
            drain_results_quietly(conn)
            _raise_error(
                self._cell,
                PostgresError(
                    severity="FATAL",
                    sqlstate=String(CONNECTION_FAILURE),
                    message=message,
                    sql=self._sql.copy(),
                ),
            )
        # -1: the stream ended.  The terminating result carries the verdict.
        _ = drain_results(conn, self._cell, self._sql.copy())
        return False

    def read_all(mut self) raises -> List[UInt8]:
        """Read the whole stream into one buffer.

        Convenient for a result that comfortably fits in memory; for anything
        else, loop on `CopyOut.next`.

        Returns:
            Every remaining row, concatenated, each still ending in its
            newline -- which is what `copyfmt.split_rows` expects.

        Raises:
            Error: A `sqlstate.PostgresError` if the transfer failed.
        """
        var out = List[UInt8]()
        var chunk = List[UInt8]()
        while self.next(chunk):
            out.extend(Span(chunk))
        return out^

    def rows(mut self) raises -> List[String]:
        """Read the whole stream as one `String` per row.

        Returns:
            The rows, each **without** its trailing newline -- exactly what
            `copyfmt.decode_row` takes.  A CSV field containing a raw newline
            keeps it: libpq's row framing is the server's, not a scan for
            newlines.

        Raises:
            Error: A `sqlstate.PostgresError` if the transfer failed, or if a
                row is not valid UTF-8.
        """
        var out = List[String]()
        var chunk = List[UInt8]()
        while self.next(chunk):
            var end = len(chunk)
            if end > 0 and chunk[end - 1] == UInt8(ord("\n")):
                end -= 1
            out.append(String(from_utf8=Span(chunk)[0:end]))
        return out^
