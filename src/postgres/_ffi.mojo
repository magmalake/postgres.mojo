"""Raw libpq FFI declarations.

This is the only file that talks to C directly. Everything else in the
package goes through the symbols defined here so that bumping libpq or
switching loader strategies (`DLHandle` vs static link) stays local.
"""

from sys.ffi import external_call, OpaquePointer
from memory import UnsafePointer


# ConnStatusType (libpq-fe.h)
alias CONNECTION_OK: Int32 = 0
alias CONNECTION_BAD: Int32 = 1

# ExecStatusType (libpq-fe.h)
alias PGRES_EMPTY_QUERY: Int32 = 0
alias PGRES_COMMAND_OK: Int32 = 1
alias PGRES_TUPLES_OK: Int32 = 2
alias PGRES_COPY_OUT: Int32 = 3
alias PGRES_COPY_IN: Int32 = 4
alias PGRES_BAD_RESPONSE: Int32 = 5
alias PGRES_NONFATAL_ERROR: Int32 = 6
alias PGRES_FATAL_ERROR: Int32 = 7


@value
struct PostgresError(Stringable):
    """Wraps a libpq error message (and optionally a result status code)."""

    var code: Int32
    var message: String

    fn __str__(self) -> String:
        return "PostgresError(" + String(Int(self.code)) + "): " + self.message


fn PQlibVersion() -> Int32:
    """libpq build version as a packed int (MMmmpp)."""
    return external_call["PQlibVersion", Int32]()


fn libpq_version() -> Int32:
    """Public convenience — version of the loaded libpq."""
    return PQlibVersion()


# --- PGconn -----------------------------------------------------------------


fn PQconnectdb(conninfo: String) -> OpaquePointer:
    return external_call["PQconnectdb", OpaquePointer, UnsafePointer[Int8]](
        conninfo.unsafe_cstr_ptr()
    )


fn PQfinish(conn: OpaquePointer):
    external_call["PQfinish", NoneType, OpaquePointer](conn)


fn PQstatus(conn: OpaquePointer) -> Int32:
    return external_call["PQstatus", Int32, OpaquePointer](conn)


fn PQerrorMessage(conn: OpaquePointer) -> String:
    var p = external_call["PQerrorMessage", UnsafePointer[Int8], OpaquePointer](
        conn
    )
    return String(p)


fn PQdb(conn: OpaquePointer) -> String:
    var p = external_call["PQdb", UnsafePointer[Int8], OpaquePointer](conn)
    return String(p)


fn PQuser(conn: OpaquePointer) -> String:
    var p = external_call["PQuser", UnsafePointer[Int8], OpaquePointer](conn)
    return String(p)


fn PQhost(conn: OpaquePointer) -> String:
    var p = external_call["PQhost", UnsafePointer[Int8], OpaquePointer](conn)
    return String(p)


fn PQport(conn: OpaquePointer) -> String:
    var p = external_call["PQport", UnsafePointer[Int8], OpaquePointer](conn)
    return String(p)


# --- PGresult ---------------------------------------------------------------


fn PQexec(conn: OpaquePointer, query: String) -> OpaquePointer:
    return external_call[
        "PQexec", OpaquePointer, OpaquePointer, UnsafePointer[Int8]
    ](conn, query.unsafe_cstr_ptr())


fn PQclear(res: OpaquePointer):
    external_call["PQclear", NoneType, OpaquePointer](res)


fn PQresultStatus(res: OpaquePointer) -> Int32:
    return external_call["PQresultStatus", Int32, OpaquePointer](res)


fn PQresStatus(status: Int32) -> String:
    var p = external_call["PQresStatus", UnsafePointer[Int8], Int32](status)
    return String(p)


fn PQresultErrorMessage(res: OpaquePointer) -> String:
    var p = external_call[
        "PQresultErrorMessage", UnsafePointer[Int8], OpaquePointer
    ](res)
    return String(p)


fn PQntuples(res: OpaquePointer) -> Int32:
    return external_call["PQntuples", Int32, OpaquePointer](res)


fn PQnfields(res: OpaquePointer) -> Int32:
    return external_call["PQnfields", Int32, OpaquePointer](res)


fn PQfname(res: OpaquePointer, col: Int32) -> String:
    var p = external_call["PQfname", UnsafePointer[Int8], OpaquePointer, Int32](
        res, col
    )
    return String(p)


fn PQgetvalue(res: OpaquePointer, row: Int32, col: Int32) -> String:
    var p = external_call[
        "PQgetvalue", UnsafePointer[Int8], OpaquePointer, Int32, Int32
    ](res, row, col)
    return String(p)


fn PQgetisnull(res: OpaquePointer, row: Int32, col: Int32) -> Int32:
    return external_call["PQgetisnull", Int32, OpaquePointer, Int32, Int32](
        res, row, col
    )


fn PQcmdTuples(res: OpaquePointer) -> String:
    """Number of rows affected by an INSERT/UPDATE/DELETE (as a string)."""
    var p = external_call["PQcmdTuples", UnsafePointer[Int8], OpaquePointer](
        res
    )
    return String(p)


# --- escaping ---------------------------------------------------------------


fn PQescapeLiteral(conn: OpaquePointer, s: String) -> UnsafePointer[Int8]:
    """Caller must `PQfreemem` the returned pointer."""
    return external_call[
        "PQescapeLiteral",
        UnsafePointer[Int8],
        OpaquePointer,
        UnsafePointer[Int8],
        Int,
    ](conn, s.unsafe_cstr_ptr(), len(s))


fn PQfreemem(p: UnsafePointer[Int8]):
    external_call["PQfreemem", NoneType, UnsafePointer[Int8]](p)
