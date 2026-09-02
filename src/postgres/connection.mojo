"""`postgres.connection` — the connection, and the statements prepared on it.

`Connection` owns one libpq `PGconn` and closes it when it goes out of scope.
Everything a caller does with a database goes through it: `Connection.execute`
for commands, `Connection.query` for rows, `Connection.prepare` for a
server-side statement to run more than once.

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

**One connection, one thread.**  libpq's `PGconn` is not safe to use from two
threads at once, and nothing here adds a lock.

**Notices go to stderr.**  A ``NOTICE``/``WARNING`` the server raises -- from a
``RAISE NOTICE``, or from ``CREATE TABLE IF NOT EXISTS`` finding the table
already there -- is printed to standard error by libpq's default notice
processor.  This tin installs none of its own, so those messages are visible
but not capturable; a hook for them is not in v1.
"""

from ._ffi import (
    CONNECTION_OK,
    PGRES_COMMAND_OK,
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
    _error_field,
    exec_params,
    exec_prepared,
    libpq,
)
from .config import ConnectionConfig
from .params import Params
from .result import Result
from .sqlstate import (
    CONNECTION_FAILURE,
    PostgresError,
    SQLCLIENT_UNABLE_TO_ESTABLISH,
)
from .text import decode_int64


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

    Used only by `Statement.deallocate`, which has to splice a statement name
    into ``DEALLOCATE`` -- the one place in this module where a value reaches
    the server inside the SQL text rather than as a parameter, because
    ``DEALLOCATE`` takes an identifier and identifiers cannot be parameters.

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
    using it is undefined behaviour, not an error.  Drop the statements before
    the connection, which is what happens naturally when both are locals in
    the same scope.

    Example:

    ```mojo
    var stmt = conn.prepare("insert_row", "INSERT INTO t VALUES ($1, $2)")
    for i in range(1000):
        _ = stmt.execute(Params().int64(i).text("row"))
    ```

    Note:
        Errors raised through a `Statement` are *not* recorded in
        `Connection.last_error`, which only tracks what went through the
        `Connection`'s own methods.  Use `Connection.execute_prepared` and
        `Connection.query_prepared` -- the methods this type is a convenience
        over -- if you want that.
    """

    var _conn: PGconnPtr
    """The connection the statement lives on; borrowed, never finished here."""
    var _name: String
    """The server-side statement name."""
    var _sql: String
    """The SQL it was prepared from, kept for error messages."""

    def __init__(out self, conn: PGconnPtr, name: String, sql: String):
        """Record an already-prepared statement.

        `Connection.prepare` is the only intended caller: it issues
        `PQprepare` and checks the status before constructing this.

        Args:
            conn: The connection the statement was prepared on.
            name: The server-side statement name.
            sql: The SQL it was prepared from.
        """
        self._conn = conn
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
        var res = exec_prepared(
            self._conn, self._name, bound.values, bound.nulls
        )
        var status = libpq().PQresultStatus(res)
        if (
            status == PGRES_COMMAND_OK
            or status == PGRES_TUPLES_OK
            or status == PGRES_EMPTY_QUERY
        ):
            var n = _affected_rows(res)
            libpq().PQclear(res)
            return n
        var err = _result_error(res, self._conn, self._sql)
        libpq().PQclear(res)
        raise err.to_error()

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
        var res = exec_prepared(
            self._conn, self._name, bound.values, bound.nulls
        )
        var status = libpq().PQresultStatus(res)
        if (
            status == PGRES_TUPLES_OK
            or status == PGRES_COMMAND_OK
            or status == PGRES_EMPTY_QUERY
        ):
            return Result(res)
        var err = _result_error(res, self._conn, self._sql)
        libpq().PQclear(res)
        raise err.to_error()

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
            var err = _result_error(res, self._conn, sql)
            pq.PQclear(res)
            raise err.to_error()
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
    var _last_error: PostgresError
    """The most recent error raised through this connection's own methods."""

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
        self._last_error = PostgresError()

        ref pq = libpq()
        var conn = pq.PQconnectdb(conninfo)
        if pq.PQstatus(conn) != CONNECTION_OK:
            var message = _trim(pq.PQerrorMessage(conn))
            if message.byte_length() == 0:
                message = String("could not establish the connection")
            # A failed connection still allocates: finish it or leak it.
            pq.PQfinish(conn)
            var err = PostgresError(
                severity="FATAL",
                sqlstate=String(SQLCLIENT_UNABLE_TO_ESTABLISH),
                message=message,
            )
            self._last_error = err.copy()
            raise err.to_error()
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
            raised through a `Statement`'s own methods are not recorded.
        """
        return self._last_error.copy()

    # -- internals -----------------------------------------------------------

    def _check_open(self) raises:
        """Raise unless the connection is open."""
        if self._conn == 0:
            raise PostgresError(
                severity="FATAL",
                sqlstate=String(CONNECTION_FAILURE),
                message="the connection is closed",
            ).to_error()

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
        var err = _result_error(res, self._conn, sql)
        self._last_error = err.copy()
        libpq().PQclear(res)
        raise err.to_error()

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
        return Statement(self._conn, name, sql)

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
