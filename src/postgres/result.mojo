"""Result set returned from `Connection.query()`.

Wraps a `PGresult*` and provides typed row/column access. Lifetime is
RAII: `__del__` calls `PQclear` so users don't have to think about it.
"""

from sys.ffi import OpaquePointer

from ._ffi import (
    PGRES_COMMAND_OK,
    PGRES_TUPLES_OK,
    PostgresError,
    PQclear,
    PQcmdTuples,
    PQfname,
    PQgetisnull,
    PQgetvalue,
    PQnfields,
    PQntuples,
    PQresStatus,
    PQresultErrorMessage,
    PQresultStatus,
)


struct Result:
    """A query result. Drops the underlying `PGresult*` on destruction."""

    var _res: OpaquePointer
    var _cleared: Bool

    fn __init__(out self, res: OpaquePointer):
        self._res = res
        self._cleared = False

    fn __del__(owned self):
        if not self._cleared and self._res:
            PQclear(self._res)

    fn _check_status(self) raises:
        """Raise `PostgresError` if the result is an error."""
        var status = PQresultStatus(self._res)
        if status != PGRES_COMMAND_OK and status != PGRES_TUPLES_OK:
            var msg = PQresultErrorMessage(self._res)
            if len(msg) == 0:
                msg = PQresStatus(status)
            raise Error(String(PostgresError(status, msg)))

    fn nrows(self) -> Int:
        """Number of rows returned (0 for non-SELECT statements)."""
        return Int(PQntuples(self._res))

    fn ncols(self) -> Int:
        """Number of columns in the result."""
        return Int(PQnfields(self._res))

    fn column_name(self, col: Int) -> String:
        """Column name at index `col`."""
        return PQfname(self._res, Int32(col))

    fn value(self, row: Int, col: Int) -> String:
        """String value at `(row, col)`. Empty string for SQL NULL."""
        if PQgetisnull(self._res, Int32(row), Int32(col)) != 0:
            return String("")
        return PQgetvalue(self._res, Int32(row), Int32(col))

    fn is_null(self, row: Int, col: Int) -> Bool:
        """True iff the value at `(row, col)` is SQL NULL."""
        return PQgetisnull(self._res, Int32(row), Int32(col)) != 0

    fn rows_affected(self) -> Int:
        """Rows affected by INSERT / UPDATE / DELETE. 0 for SELECT."""
        var s = PQcmdTuples(self._res)
        if len(s) == 0:
            return 0
        return Int(atof(s))
