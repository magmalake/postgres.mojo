"""Tests for `postgres._ffi` -- the libpq load path and the pointer plumbing.

Split in two.  The server-free half runs everywhere: it proves the library was
found and dlopened (`PQlibVersion`), and it drives a full `PGconn` lifecycle
against a deliberately unreachable address, which exercises exactly the
plumbing a real connection does -- a handle out of `PQconnectdb`, a status read
off it, a C string copied out of `PQerrorMessage`, and `PQfinish` -- without
needing anything listening.

The live half runs only when ``$POSTGRES_TEST_DSN`` is set (``sh
scripts/with-pg-server.sh`` exports it); otherwise it prints that it was
skipped, so a bare ``pixi run unit`` stays green on a machine with no cluster.
"""

from std.os import getenv
from std.testing import TestSuite, assert_equal, assert_true

from postgres._ffi import (
    CONNECTION_BAD,
    CONNECTION_OK,
    PGRES_COMMAND_OK,
    PGRES_COPY_IN,
    PGRES_COPY_OUT,
    PGRES_FATAL_ERROR,
    PGRES_TUPLES_OK,
    PG_DIAG_MESSAGE_PRIMARY,
    PG_DIAG_SQLSTATE,
    PQTRANS_IDLE,
    exec_params,
    exec_prepared,
    libpq,
)


comptime UNREACHABLE_DSN = "postgresql://127.0.0.1:1/x?connect_timeout=1"
"""Port 1 is reserved and never listening, so ``connect()`` is refused at once.

``connect_timeout=1`` bounds the wait on the hosts where the refusal is dropped
rather than returned (a firewall, a container without loopback), keeping this
test's worst case at a second instead of the OS TCP timeout.
"""


# -----------------------------------------------------------------------
# Server-free
# -----------------------------------------------------------------------


def test_libpq_loads_and_reports_its_version() raises:
    """The library resolves from ``$CONDA_PREFIX`` and answers `PQlibVersion`.

    This is the load-path smoke test: reaching a number at all means the
    `dlopen` found libpq and `_dl_sym` resolved a symbol out of it.  The bound
    matches the pixi manifest's ``libpq >=16,<19``.
    """
    var version = libpq().PQlibVersion()
    assert_true(
        version >= 160000,
        "libpq is older than 16.0: PQlibVersion() = " + String(version),
    )
    assert_true(
        version < 190000,
        "libpq is newer than the pinned range: PQlibVersion() = "
        + String(version),
    )


def test_failed_connection_reports_bad_status_and_a_message() raises:
    """A refused connection still yields a handle that must be finished.

    Everything a successful connection touches is touched here -- the handle,
    `PQstatus`, a C string copied out of `PQerrorMessage`, `PQfinish` -- so the
    pointer plumbing is covered on a machine with no server.  The handle being
    non-zero *despite* the failure is the libpq contract that most bindings get
    wrong: `PQfinish` is still required, or the connection object leaks.
    """
    ref pq = libpq()
    var conn = pq.PQconnectdb(UNREACHABLE_DSN)
    assert_true(conn != 0, "PQconnectdb returned NULL (out of memory)")
    assert_equal(pq.PQstatus(conn), CONNECTION_BAD)
    var message = pq.PQerrorMessage(conn)
    assert_true(
        message.byte_length() > 0,
        "a failed connection reported no error message",
    )
    # The address and port are always named; the rest of the wording is the
    # platform's strerror and not worth pinning.
    assert_true(
        "127.0.0.1" in message,
        "error message does not mention the host: " + message,
    )
    pq.PQfinish(conn)


def test_null_handles_are_answered_rather_than_dereferenced() raises:
    """Every accessor tolerates a ``0`` handle instead of faulting.

    ``0`` is how this module spells NULL, and libpq hands one back on out of
    memory and at the end of `PQgetResult`.  The wrappers answer with the value
    libpq would have produced, so the layer above can check statuses before it
    checks handles.
    """
    ref pq = libpq()
    assert_equal(pq.PQstatus(0), CONNECTION_BAD)
    assert_equal(pq.PQerrorMessage(0), "")
    assert_equal(pq.PQserverVersion(0), 0)
    assert_equal(pq.PQresultStatus(0), PGRES_FATAL_ERROR)
    assert_equal(pq.PQntuples(0), 0)
    assert_equal(pq.PQnfields(0), 0)
    assert_equal(pq.PQfname(0, 0), "")
    assert_equal(pq.PQfnumber(0, "x"), -1)
    assert_equal(pq.PQgetvalue(0, 0, 0), "")
    assert_true(pq.PQgetisnull(0, 0, 0))
    assert_equal(pq.PQcmdTuples(0), "")
    assert_equal(pq.PQresultErrorMessage(0), "")
    assert_equal(pq.PQresultErrorField(0, PG_DIAG_SQLSTATE), "")
    pq.PQclear(0)
    pq.PQfinish(0)
    pq.PQfreemem(0)


def test_res_status_names_the_status_constant() raises:
    """`PQresStatus` maps the enum back to its name, for error messages.

    Server-free because it is a pure lookup in a static table inside libpq.
    """
    ref pq = libpq()
    assert_equal(pq.PQresStatus(PGRES_TUPLES_OK), "PGRES_TUPLES_OK")
    assert_equal(pq.PQresStatus(PGRES_COMMAND_OK), "PGRES_COMMAND_OK")
    assert_equal(pq.PQresStatus(PGRES_FATAL_ERROR), "PGRES_FATAL_ERROR")


def test_param_length_mismatches_are_rejected_before_the_call() raises:
    """`exec_params` validates the parallel lists rather than trusting them.

    A short `nulls` or `oids` list would otherwise be read past its end while
    building the C arrays.  The check runs before any pointer is taken, so a
    dead connection handle is never even touched -- which is why this needs no
    server.
    """
    var values: List[String] = ["a", "b"]
    var one_null: List[Bool] = [False]
    var one_oid: List[UInt32] = [UInt32(25)]

    var raised_for_nulls = False
    try:
        _ = exec_params(0, "SELECT $1, $2", values, one_null, List[UInt32]())
    except e:
        raised_for_nulls = True
        assert_true("null flags" in String(e), "unexpected error: " + String(e))
    assert_true(raised_for_nulls, "a short `nulls` list was accepted")

    var raised_for_oids = False
    try:
        _ = exec_params(0, "SELECT $1, $2", values, List[Bool](), one_oid)
    except e:
        raised_for_oids = True
        assert_true("type OIDs" in String(e), "unexpected error: " + String(e))
    assert_true(raised_for_oids, "a short `oids` list was accepted")


# -----------------------------------------------------------------------
# Live round trip -- only with $POSTGRES_TEST_DSN
# -----------------------------------------------------------------------


def _connect(dsn: String) raises -> Int:
    """Open `dsn` and assert it came up, so each live test can just use it.

    Args:
        dsn: A conninfo string or URI.

    Returns:
        A live `PGconnPtr` the caller must `PQfinish`.

    Raises:
        Error: If the connection failed, with libpq's message attached.
    """
    ref pq = libpq()
    var conn = pq.PQconnectdb(dsn)
    if pq.PQstatus(conn) != CONNECTION_OK:
        var message = pq.PQerrorMessage(conn)
        pq.PQfinish(conn)
        raise Error("could not connect to $POSTGRES_TEST_DSN: " + message)
    return conn


def test_live_round_trip() raises:
    """Exercise the query path end to end against a real server.

    Covers, in one connection so the cost of starting a cluster is paid once:
    `PQexec` and cell access, `exec_params` with two parameters, a NULL
    parameter reaching the server as NULL, `PQprepare` plus `exec_prepared`,
    the affected-row count from `PQcmdTuples`, a COPY in both directions (the
    only wrappers with an output pointer and a buffer to free), and a syntax
    error surfacing as SQLSTATE 42601 through `PQresultErrorField`.

    Skipped with a printed note when ``$POSTGRES_TEST_DSN`` is unset.
    """
    var dsn = getenv("POSTGRES_TEST_DSN", "")
    if not dsn:
        print(
            "  (skipped: set $POSTGRES_TEST_DSN, or run via"
            " scripts/with-pg-server.sh, for the live round trip)"
        )
        return

    ref pq = libpq()
    var conn = _connect(dsn)

    # -- a plain query -----------------------------------------------------
    var res = pq.PQexec(conn, "SELECT 1")
    assert_equal(pq.PQresultStatus(res), PGRES_TUPLES_OK)
    assert_equal(pq.PQntuples(res), 1)
    assert_equal(pq.PQnfields(res), 1)
    assert_equal(pq.PQgetvalue(res, 0, 0), "1")
    assert_true(not pq.PQgetisnull(res, 0, 0))
    assert_equal(pq.PQgetlength(res, 0, 0), 1)
    pq.PQclear(res)

    # The server is reachable, so its version and idle transaction state are
    # both readable -- the two connection accessors a plain query never hits.
    assert_true(
        pq.PQserverVersion(conn) >= 160000,
        "server older than 16: " + String(pq.PQserverVersion(conn)),
    )
    assert_equal(pq.PQtransactionStatus(conn), PQTRANS_IDLE)

    # -- column metadata ---------------------------------------------------
    res = pq.PQexec(conn, "SELECT 7 AS n, 'x'::text AS label")
    assert_equal(pq.PQresultStatus(res), PGRES_TUPLES_OK)
    assert_equal(pq.PQfname(res, 0), "n")
    assert_equal(pq.PQfnumber(res, "label"), 1)
    assert_equal(pq.PQfnumber(res, "nosuchcolumn"), -1)
    # 25 is `text`; the OID of an unadorned integer literal is 23 (`int4`).
    assert_equal(pq.PQftype(res, 1), UInt32(25))
    assert_equal(pq.PQftype(res, 0), UInt32(23))
    pq.PQclear(res)

    # -- parameters --------------------------------------------------------
    var two_three: List[String] = ["2", "3"]
    res = exec_params(
        conn,
        "SELECT $1::int + $2::int",
        two_three,
        List[Bool](),
        List[UInt32](),
    )
    assert_equal(pq.PQresultStatus(res), PGRES_TUPLES_OK)
    assert_equal(pq.PQgetvalue(res, 0, 0), "5")
    pq.PQclear(res)

    # Explicit OIDs instead of casts: 23 is int4, so the server needs no hint
    # from the SQL text.
    var oids: List[UInt32] = [UInt32(23), UInt32(23)]
    res = exec_params(conn, "SELECT $1 + $2", two_three, List[Bool](), oids)
    assert_equal(pq.PQresultStatus(res), PGRES_TUPLES_OK)
    assert_equal(pq.PQgetvalue(res, 0, 0), "5")
    pq.PQclear(res)

    # -- NULL vs the empty string -----------------------------------------
    var one_value: List[String] = [""]
    var is_null: List[Bool] = [True]
    res = exec_params(
        conn,
        "SELECT $1::text AS v, $1::text IS NULL AS was_null",
        one_value,
        is_null,
        List[UInt32](),
    )
    assert_equal(pq.PQresultStatus(res), PGRES_TUPLES_OK)
    assert_true(
        pq.PQgetisnull(res, 0, 0), "a NULL parameter did not come back NULL"
    )
    assert_equal(pq.PQgetvalue(res, 0, 0), "")
    assert_equal(pq.PQgetvalue(res, 0, 1), "t")
    pq.PQclear(res)

    # The same parameter *not* flagged NULL is the empty string, and libpq
    # renders both as "" -- PQgetisnull is the only thing that separates them.
    res = exec_params(
        conn,
        "SELECT $1::text AS v, $1::text IS NULL AS was_null",
        one_value,
        List[Bool](),
        List[UInt32](),
    )
    assert_equal(pq.PQresultStatus(res), PGRES_TUPLES_OK)
    assert_true(
        not pq.PQgetisnull(res, 0, 0), "an empty string came back as NULL"
    )
    assert_equal(pq.PQgetvalue(res, 0, 0), "")
    assert_equal(pq.PQgetvalue(res, 0, 1), "f")
    pq.PQclear(res)

    # -- prepared statements ----------------------------------------------
    res = pq.PQprepare(
        conn, "ffi_add", "SELECT $1::int * $2::int", List[UInt32]()
    )
    assert_equal(pq.PQresultStatus(res), PGRES_COMMAND_OK)
    pq.PQclear(res)

    var six_seven: List[String] = ["6", "7"]
    res = exec_prepared(conn, "ffi_add", six_seven, List[Bool]())
    assert_equal(pq.PQresultStatus(res), PGRES_TUPLES_OK)
    assert_equal(pq.PQgetvalue(res, 0, 0), "42")
    pq.PQclear(res)

    # -- affected rows -----------------------------------------------------
    res = pq.PQexec(
        conn, "CREATE TEMP TABLE ffi_smoke (id int primary key, v text)"
    )
    assert_equal(pq.PQresultStatus(res), PGRES_COMMAND_OK)
    # DDL reports no row count at all; "" is what the layer above maps to 0.
    assert_equal(pq.PQcmdTuples(res), "")
    pq.PQclear(res)

    res = pq.PQexec(
        conn, "INSERT INTO ffi_smoke VALUES (1, 'a'), (2, 'b'), (3, 'c')"
    )
    assert_equal(pq.PQresultStatus(res), PGRES_COMMAND_OK)
    assert_equal(pq.PQcmdTuples(res), "3")
    pq.PQclear(res)

    res = pq.PQexec(conn, "DELETE FROM ffi_smoke WHERE id > 1")
    assert_equal(pq.PQresultStatus(res), PGRES_COMMAND_OK)
    assert_equal(pq.PQcmdTuples(res), "2")
    pq.PQclear(res)

    # -- COPY out ----------------------------------------------------------
    # PQgetCopyData is the one wrapper with an output-pointer argument and a
    # malloc'ed buffer to free, so it gets exercised here rather than waiting
    # for copy.mojo.
    res = pq.PQexec(conn, "COPY ffi_smoke TO STDOUT")
    assert_equal(pq.PQresultStatus(res), PGRES_COPY_OUT)
    pq.PQclear(res)

    var out = List[UInt8]()
    var rows = 0
    while True:
        var n = pq.PQgetCopyData(conn, out)
        if n == -1:
            break
        assert_true(n > 0, "PQgetCopyData failed: " + pq.PQerrorMessage(conn))
        rows += 1
    assert_equal(rows, 1)
    assert_equal(String(from_utf8=Span(out)), "1\ta\n")
    # The terminating result has to be drained or the connection stays busy.
    res = pq.PQgetResult(conn)
    assert_equal(pq.PQresultStatus(res), PGRES_COMMAND_OK)
    pq.PQclear(res)
    assert_equal(pq.PQgetResult(conn), 0)

    # -- COPY in -----------------------------------------------------------
    res = pq.PQexec(conn, "COPY ffi_smoke FROM STDIN")
    assert_equal(pq.PQresultStatus(res), PGRES_COPY_IN)
    pq.PQclear(res)

    assert_equal(pq.PQputCopyData(conn, String("4\td\n5\te\n")), 1)
    assert_equal(pq.PQputCopyEnd(conn), 1)
    res = pq.PQgetResult(conn)
    assert_equal(pq.PQresultStatus(res), PGRES_COMMAND_OK)
    assert_equal(pq.PQcmdTuples(res), "2")
    pq.PQclear(res)
    assert_equal(pq.PQgetResult(conn), 0)

    res = pq.PQexec(conn, "SELECT count(*) FROM ffi_smoke")
    assert_equal(pq.PQgetvalue(res, 0, 0), "3")
    pq.PQclear(res)

    # -- errors carry a SQLSTATE ------------------------------------------
    res = pq.PQexec(conn, "SELEC 1")
    assert_equal(pq.PQresultStatus(res), PGRES_FATAL_ERROR)
    # 42601 is syntax_error; sqlstate.mojo classifies on exactly this string.
    assert_equal(pq.PQresultErrorField(res, PG_DIAG_SQLSTATE), "42601")
    assert_true(
        pq.PQresultErrorField(res, PG_DIAG_MESSAGE_PRIMARY).byte_length() > 0,
        "a syntax error carried no primary message",
    )
    assert_true(
        "syntax error" in pq.PQresultErrorMessage(res),
        "unexpected error message: " + pq.PQresultErrorMessage(res),
    )
    pq.PQclear(res)

    # A unique violation is 23505, the code the SQL catalog turns into
    # "table already exists".
    var dup: List[String] = ["1", "again"]
    res = exec_params(
        conn,
        "INSERT INTO ffi_smoke VALUES ($1::int, $2::text)",
        dup,
        List[Bool](),
        List[UInt32](),
    )
    assert_equal(pq.PQresultStatus(res), PGRES_FATAL_ERROR)
    assert_equal(pq.PQresultErrorField(res, PG_DIAG_SQLSTATE), "23505")
    pq.PQclear(res)

    pq.PQfinish(conn)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
