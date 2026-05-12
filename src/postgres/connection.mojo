"""High-level connection."""

from sys.ffi import OpaquePointer

from ._ffi import (
    CONNECTION_OK,
    PostgresError,
    PQconnectdb,
    PQerrorMessage,
    PQexec,
    PQfinish,
    PQstatus,
)
from .config import ConnectionConfig
from .result import Result


struct Connection:
    """A live libpq connection.

    Construct from a `ConnectionConfig` and call `query(...)` to run
    statements. The connection is closed on `__del__` or via an explicit
    `close()`.
    """

    var _conn: OpaquePointer
    var _closed: Bool

    fn __init__(out self, owned cfg: ConnectionConfig) raises:
        var conninfo = cfg.to_conninfo()
        var conn = PQconnectdb(conninfo)
        if not conn:
            raise Error(
                "PQconnectdb returned null (out of memory or libpq init"
                " failure)"
            )
        if PQstatus(conn) != CONNECTION_OK:
            var msg = PQerrorMessage(conn)
            PQfinish(conn)
            raise Error(String(PostgresError(1, msg)))
        self._conn = conn
        self._closed = False

    fn __del__(owned self):
        if not self._closed and self._conn:
            PQfinish(self._conn)

    fn is_open(self) -> Bool:
        if self._closed or not self._conn:
            return False
        return PQstatus(self._conn) == CONNECTION_OK

    fn query(self, sql: String) raises -> Result:
        """Execute a SQL statement and return the result.

        Use parameterized queries for untrusted input — for now, callers
        should pre-escape via `escape_literal()`. Native parameter binding
        (`PQexecParams`) lands in v0.2 (see issue #4).
        """
        if self._closed:
            raise Error("query on closed connection")
        var res = PQexec(self._conn, sql)
        if not res:
            raise Error(
                "PQexec returned null: " + PQerrorMessage(self._conn)
            )
        var r = Result(res)
        r._check_status()
        return r

    fn close(mut self):
        if not self._closed and self._conn:
            PQfinish(self._conn)
            self._closed = True
