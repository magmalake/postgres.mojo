"""The `PGconn` a connection and its handles share (`_ConnCell`), and the
helpers that run commands and raise errors on it. `postgres.connection` and
`postgres.copy` both build on these, so they live below both."""

from std.memory import ArcPointer

from ._ffi import (
    _error_field,
    libpq,
    PG_DIAG_MESSAGE_DETAIL,
    PG_DIAG_MESSAGE_HINT,
    PG_DIAG_MESSAGE_PRIMARY,
    PG_DIAG_SEVERITY,
    PG_DIAG_SEVERITY_NONLOCALIZED,
    PG_DIAG_SQLSTATE,
    PGconnPtr,
    PGRES_COMMAND_OK,
    PGRES_COPY_BOTH,
    PGRES_COPY_IN,
    PGRES_COPY_OUT,
    PGRES_EMPTY_QUERY,
    PGRES_TUPLES_OK,
    PGresultPtr,
)
from .sqlstate import (
    CONNECTION_FAILURE,
    PostgresError,
)
from .text import decode_int64


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
    return String(StringSpan(unsafe_from_utf8=Span(b)[start:end]))


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
# The shared connection cell
# ===----------------------------------------------------------------------===#


struct _ConnCell(Movable):
    """The `PGconn` itself, and the last error raised on it, shared by all.

    A `Statement`, a `Transaction`, a `CopyIn` and a `CopyOut` cannot hold a
    reference to the `Connection` -- that would give every one of them an
    origin parameter, and infect their return types with it -- so they hold a
    share of *this* instead, through an `std.memory.ArcPointer`.  Two things
    follow, and they are the whole point:

    - **The connection lives as long as the handles do.**  The `PGconn` is
      closed by this cell's destructor, which runs when the last share of it
      goes away.  Mojo destroys a value after its last *use*, so a
      `Connection` is routinely dropped while a handle made from it is still
      working; that is now simply a transfer of ownership, not a dangling
      pointer.
    - **Every error lands in one place.**  `Connection.last_error` reads this
      slot, so it sees what was raised through a `Statement` or a COPY too.

    `ArcPointer` gives interior mutability -- writes go through an immutable
    `self` -- which is what lets `Statement.execute` record an error without
    taking a mutable borrow of anything.  That is sound here for the same
    reason the whole tin is: one `PGconn` belongs to one thread.
    """

    var conn: PGconnPtr
    """The owned ``PGconn *``; ``0`` once `Connection.close` has run."""
    var error: PostgresError
    """The most recent error raised through this connection, in any form."""

    def __init__(out self, conn: PGconnPtr):
        """Take ownership of an open connection handle.

        Args:
            conn: The ``PGconn *`` this cell now owns and will finish, or
                ``0`` for a cell that owns nothing yet.
        """
        self.conn = conn
        self.error = PostgresError()

    def __deinit__(deinit self):
        """Close the connection, if `Connection.close` has not already.

        This runs when the last share of the cell is dropped -- which is the
        last of the `Connection` and every handle made from it, in whatever
        order they happen to be destroyed.
        """
        if self.conn != 0:
            try:
                libpq().PQfinish(self.conn)
            except:
                pass


def _record(cell: ArcPointer[_ConnCell], err: PostgresError):
    """Store `err` as the connection's most recent error.

    Args:
        cell: The connection's shared cell.
        err: The error to remember.
    """
    cell[].error = err.copy()


def _raise_error(cell: ArcPointer[_ConnCell], err: PostgresError) raises:
    """Record `err` and raise it.

    Args:
        cell: The connection's shared cell.
        err: The error to record and raise.

    Raises:
        Error: Always -- `err` formatted by `sqlstate.PostgresError.to_error`.
    """
    _record(cell, err)
    raise err.to_error()


def _open_conn(cell: ArcPointer[_ConnCell]) raises -> PGconnPtr:
    """The cell's connection handle, or raise because it has been closed.

    Every call that reaches libpq goes through here, which is what makes
    `Connection.close` safe to call while a `Statement`, a `Transaction` or a
    COPY handle is still alive: they find ``0`` and report it, rather than
    using a freed pointer.

    Args:
        cell: The connection's shared cell.

    Returns:
        The live ``PGconn *``.

    Raises:
        Error: A `sqlstate.PostgresError` with SQLSTATE
            `sqlstate.CONNECTION_FAILURE` (08006) if the connection has been
            closed.
    """
    var conn = cell[].conn
    if conn == 0:
        _raise_error(cell, _closed_error())
    return conn


def _raise_result(
    cell: ArcPointer[_ConnCell],
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
        cell: The connection's shared cell.
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
    _raise_error(cell, err)


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
    conn: PGconnPtr, cell: ArcPointer[_ConnCell], sql: String
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
        cell: The connection's shared cell.
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
    _raise_result(cell, first, conn, sql)
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
