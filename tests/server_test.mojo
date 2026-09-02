"""The live suite: everything that needs a real PostgreSQL on the other end.

Run through `tests/run_tests.sh`, which starts a throwaway cluster, exports
``$POSTGRES_TEST_DSN`` and stops it again.  With that variable unset this
binary prints one line and exits 0 -- so `pixi run unit` on a machine with no
cluster stays green, and CI on a platform where the server will not start
skips rather than fails.

Every test opens its own `Connection`: connections are cheap next to starting
a cluster, and a test that leaves a failed transaction behind then cannot
poison the next one.  Tables are ``CREATE TEMP TABLE``, which the server drops
with the session, so nothing needs cleaning up.
"""

from std.os import getenv
from std.testing import TestSuite, assert_equal, assert_false, assert_true
from std.utils.numerics import isinf, isnan

from postgres import (
    Connection,
    OID_INT4,
    OID_TEXT,
    Params,
    Result,
    Row,
    Statement,
    sqlstate_of,
)


# ===----------------------------------------------------------------------===#
# Fixtures
# ===----------------------------------------------------------------------===#


comptime UUID_SAMPLE = "6ba7b810-9dad-11d1-80b4-00c04fd430c8"
"""RFC 4122's example UUID -- a fixed value, so the round trip is exact."""

comptime DAYS_2024_02_29: Int32 = 19782
"""2024-02-29 as days since 1970-01-01.  A leap day in a year that is a leap
year for the century rule as well, so it exercises the calendar arithmetic
rather than just the arithmetic."""

comptime MICROS_2024_02_29_131415_123456: Int64 = 1_709_212_455_123_456
"""``2024-02-29 13:14:15.123456`` as naive epoch microseconds."""

comptime MICROS_2024_02_29_131415_PLUS_0530: Int64 = 1_709_192_655_000_000
"""``2024-02-29 13:14:15+05:30`` as **UTC** epoch microseconds, i.e.
``07:44:15Z``.  The offset is the point: the value is the same instant however
the session's ``TimeZone`` chooses to render it."""


def _dsn() raises -> String:
    """The DSN of the test server.

    Returns:
        ``$POSTGRES_TEST_DSN``.

    Raises:
        Error: If the variable is unset -- which `main` checks for first, so
            reaching this means the environment changed mid-run.
    """
    var dsn = getenv("POSTGRES_TEST_DSN", "")
    if not dsn:
        raise Error("$POSTGRES_TEST_DSN is not set")
    return dsn


def _connect() raises -> Connection:
    """Open a connection to the test server.

    Returns:
        A live `Connection`, closed when the caller drops it.

    Raises:
        Error: If the server refused the connection.
    """
    return Connection(_dsn())


# ===----------------------------------------------------------------------===#
# Connect, ping, versions
# ===----------------------------------------------------------------------===#


def test_connect_ping_and_server_version() raises:
    """A connection comes up, answers a query, and reports its server version.

    `Connection.ping` is the one that matters: `Connection.is_open` only
    reports libpq's cached view, while `ping` actually goes to the server.
    """
    var conn = _connect()
    assert_true(conn.is_open(), "a fresh connection is not open")
    assert_true(conn.ping(), "SELECT 1 did not reach the server")
    var version = conn.server_version()
    assert_true(
        version >= 160000,
        "server older than 16: " + String(version),
    )


def test_close_is_idempotent_and_observable() raises:
    """`Connection.close` may be called twice, and takes effect the first time.

    After it, the connection reports closed and `ping` fails rather than
    reconnecting behind the caller's back.
    """
    var conn = _connect()
    assert_true(conn.ping(), "the connection did not come up")
    conn.close()
    assert_false(conn.is_open(), "close() left the connection open")
    assert_false(conn.ping(), "ping() succeeded on a closed connection")
    conn.close()  # idempotent: the second call is a no-op
    var raised = False
    try:
        _ = conn.execute("SELECT 1")
    except e:
        raised = True
        assert_equal(sqlstate_of(e), "08006")
    assert_true(raised, "a closed connection accepted a command")


# ===----------------------------------------------------------------------===#
# Rows in, rows out
# ===----------------------------------------------------------------------===#


def test_insert_reports_affected_rows_and_select_reads_them_back() raises:
    """The DDL/DML/SELECT loop, including both ways of naming a column.

    `Connection.execute`'s return value is `PQcmdTuples`: a count for the
    statements that report one, ``0`` for the DDL and the ``SELECT`` that do
    not.
    """
    var conn = _connect()
    assert_equal(
        conn.execute("CREATE TEMP TABLE t (id bigint primary key, name text)"),
        0,
        "DDL reported a row count",
    )
    assert_equal(
        conn.execute(
            "INSERT INTO t VALUES ($1, $2), ($3, $4)",
            Params().int64(1).text("Ada").int64(2).text("Grace"),
        ),
        2,
    )
    assert_equal(
        conn.execute("DELETE FROM t WHERE id = $1", Params().int64(2)), 1
    )
    assert_equal(
        conn.execute(
            "INSERT INTO t VALUES ($1, $2)", Params().int64(2).text("Grace")
        ),
        1,
    )

    var res = conn.query("SELECT id, name FROM t ORDER BY id")
    assert_equal(res.num_rows(), 2)
    assert_equal(res.num_cols(), 2)
    assert_equal(len(res), 2)
    assert_equal(res.column_name(0), "id")
    assert_equal(res.column_name(1), "name")
    assert_equal(res.column_index("name"), 1)
    assert_equal(res.column_oid(1), OID_TEXT)
    assert_equal(res.text(0, 1), "Ada")

    var first = res.row(0)
    assert_equal(first.int64(0), 1)  # by index
    assert_equal(first.text("name"), "Ada")  # by name
    assert_equal(first.num_cols(), 2)
    assert_equal(first.column_name(1), "name")
    var second = res.row(1)
    assert_equal(second.int64("id"), 2)
    assert_equal(second.text(1), "Grace")


def test_select_of_no_rows_is_empty_not_an_error() raises:
    """A ``SELECT`` that matches nothing is a result with zero rows.

    Columns are still described, so `column_name` and `column_index` work on
    an empty result -- which is what lets a caller build a header before it
    knows whether there is any data.
    """
    var conn = _connect()
    _ = conn.execute("CREATE TEMP TABLE t (id int)")
    var res = conn.query("SELECT id FROM t WHERE id = $1", Params().int32(9))
    assert_equal(res.num_rows(), 0)
    assert_equal(res.num_cols(), 1)
    assert_equal(res.column_name(0), "id")
    assert_equal(res.column_oid(0), OID_INT4)


def test_query_of_a_command_yields_an_empty_result() raises:
    """`Connection.query` on an ``INSERT`` is allowed and returns no rows.

    The count is still there, in `Result.affected_rows` -- so a caller that
    always calls `query` never has to special-case a command.
    """
    var conn = _connect()
    _ = conn.execute("CREATE TEMP TABLE t (id int)")
    var res = conn.query("INSERT INTO t VALUES (1), (2), (3)")
    assert_equal(res.num_rows(), 0)
    assert_equal(res.num_cols(), 0)
    assert_equal(res.affected_rows(), 3)


def test_execute_of_a_select_fetches_and_drops_the_rows() raises:
    """A ``SELECT`` through `Connection.execute` keeps only the count.

    PostgreSQL's command tag for a ``SELECT`` is ``SELECT <n>``, so
    `PQcmdTuples` -- and with it `Connection.execute` -- reports the rows the
    query returned, even though they were discarded.  Ten thousand times,
    because this is the shape that leaks if `PQclear` is ever skipped on the
    success path: the assertion is that it finishes, and it does so in well
    under a second when nothing is retained.
    """
    var conn = _connect()
    assert_equal(conn.execute("SELECT generate_series(1, 3)"), 3)
    for _ in range(10_000):
        assert_equal(conn.execute("SELECT 1"), 1)


def test_execute_runs_a_multi_statement_string() raises:
    """Without parameters, `Connection.execute` goes through `PQexec`.

    Which accepts several statements separated by semicolons -- `PQexecParams`
    does not -- and reports the last one's count.
    """
    var conn = _connect()
    var affected = conn.execute(
        "CREATE TEMP TABLE m (id int);"
        " INSERT INTO m VALUES (1), (2);"
        " INSERT INTO m VALUES (3), (4), (5)"
    )
    assert_equal(affected, 3, "the last statement's count was not reported")
    var res = conn.query("SELECT count(*) AS n FROM m")
    assert_equal(res.row(0).int64("n"), 5)


# ===----------------------------------------------------------------------===#
# NULL
# ===----------------------------------------------------------------------===#


def test_null_is_distinct_from_the_empty_string() raises:
    """The distinction libpq's own API cannot express in a value.

    `PQgetvalue` renders a NULL and an empty string identically, so
    `Result.is_null` / `Row.is_null` is the only thing separating them --
    and every typed accessor has to refuse a NULL rather than hand back
    ``""``.
    """
    var conn = _connect()
    _ = conn.execute("CREATE TEMP TABLE t (id int, note text)")
    _ = conn.execute(
        "INSERT INTO t VALUES ($1, $2), ($3, $4)",
        Params().int32(1).null().int32(2).text(""),
    )

    var res = conn.query("SELECT id, note FROM t ORDER BY id")
    assert_equal(res.num_rows(), 2)
    assert_true(res.is_null(0, 1), "a NULL column did not read as NULL")
    assert_false(res.is_null(1, 1), "an empty string read as NULL")
    assert_equal(res.text(1, 1), "")

    var null_row = res.row(0)
    var empty_row = res.row(1)
    assert_true(null_row.is_null("note"))
    assert_false(empty_row.is_null("note"))
    assert_false(Bool(null_row.opt_text("note")), "opt_text() invented a value")
    assert_true(Bool(empty_row.opt_text("note")), "opt_text() dropped an empty")
    assert_equal(empty_row.opt_text("note").value(), "")

    # Reading a NULL as a value is an error, not a zero.
    var raised = False
    try:
        _ = null_row.text("note")
    except e:
        raised = True
        assert_true("NULL" in String(e), "unexpected message: " + String(e))
    assert_true(raised, "text() on a NULL cell did not raise")

    var raised_typed = False
    try:
        _ = null_row.int64("note")
    except:
        raised_typed = True
    assert_true(raised_typed, "int64() on a NULL cell did not raise")

    var raised_result = False
    try:
        _ = res.text(0, 1)
    except:
        raised_result = True
    assert_true(raised_result, "Result.text() on a NULL cell did not raise")


# ===----------------------------------------------------------------------===#
# The type table (spec section 5)
# ===----------------------------------------------------------------------===#


def test_every_type_round_trips_through_params() raises:
    """Bind one value of every supported type, read it back, compare.

    Each parameter carries its own OID -- that is what `Params`' typed
    builders are for -- so the server needs no cast in the SQL to know what it
    is being handed.  Reading the row back with the matching accessor closes
    the loop through both halves of `postgres.text`.
    """
    var conn = _connect()
    var blob: List[UInt8] = [0xDE, 0xAD, 0xBE, 0xEF]
    var params = (
        Params()
        .bool(True)
        .int16(-32768)
        .int32(2147483647)
        .int64(-9223372036854775808)
        .float32(1.5)
        .float64(2.25)
        .numeric("12345.678900")
        .bytea(Span(blob))
        .date_days(DAYS_2024_02_29)
        .time_micros(47_655_123_456)
        .timestamp_micros(MICROS_2024_02_29_131415_123456)
        .timestamptz_micros(MICROS_2024_02_29_131415_PLUS_0530)
        .uuid(UUID_SAMPLE)
        .json('{"a": 1}')
        .text("hello")
    )
    var res = conn.query(
        (
            "SELECT $1 AS b, $2 AS i2, $3 AS i4, $4 AS i8, $5 AS f4, $6 AS f8,"
            " $7 AS num, $8 AS blob, $9 AS d, $10 AS t, $11 AS ts, $12 AS tstz,"
            " $13 AS u, $14 AS j, $15 AS s"
        ),
        params,
    )
    assert_equal(res.num_rows(), 1)
    var row = res.row(0)

    assert_true(row.bool("b"))
    assert_equal(row.int16("i2"), Int16(-32768))
    assert_equal(row.int32("i4"), Int32(2147483647))
    assert_equal(row.int64("i8"), Int64(-9223372036854775808))
    assert_equal(row.float32("f4"), Float32(1.5))
    assert_equal(row.float64("f8"), Float64(2.25))
    # numeric keeps its scale: the trailing zeros are part of the value.
    assert_equal(row.numeric("num"), "12345.678900")
    var back = row.bytea("blob")
    assert_equal(len(back), 4)
    assert_equal(back[0], UInt8(0xDE))
    assert_equal(back[3], UInt8(0xEF))
    assert_equal(row.date_days("d"), DAYS_2024_02_29)
    assert_equal(row.time_micros("t"), Int64(47_655_123_456))
    assert_equal(row.timestamp_micros("ts"), MICROS_2024_02_29_131415_123456)
    assert_equal(
        row.timestamptz_micros("tstz"), MICROS_2024_02_29_131415_PLUS_0530
    )
    assert_equal(row.uuid("u"), UUID_SAMPLE)
    assert_equal(row.json("j"), '{"a": 1}')
    assert_equal(row.text("s"), "hello")


def test_every_type_decodes_from_a_server_side_cast() raises:
    """The other direction: values the *server* produced, not ones we sent.

    A round trip through `Params` can agree with itself while both halves are
    wrong; a literal cast in SQL is the server's own rendering of each type,
    which is what the decoders actually have to read in the wild.
    """
    var conn = _connect()
    var res = conn.query(
        (
            "SELECT $1::int2 AS i2, $1::int8 AS i8, 1.5::float4 AS f4,"
            " 'NaN'::float8 AS nan, 'Infinity'::float8 AS inf,"
            " '-Infinity'::float8 AS neginf, 12345.678900::numeric AS num,"
            " '\\xdeadbeef'::bytea AS blob, '2024-02-29'::date AS d,"
            " '13:14:15.123456'::time AS t,"
            " '2024-02-29 13:14:15.123456'::timestamp AS ts,"
            " '2024-02-29 13:14:15+05:30'::timestamptz AS tstz,"
            " gen_random_uuid() AS u, '{\"a\":1}'::jsonb AS j,"
            " true AS yes, false AS no"
        ),
        Params().text("42"),
    )
    var row = res.row(0)

    assert_equal(row.int16("i2"), Int16(42))
    assert_equal(row.int64("i8"), Int64(42))
    assert_equal(row.float32("f4"), Float32(1.5))
    assert_true(
        isnan(row.float64("nan")), "'NaN'::float8 did not decode to NaN"
    )
    assert_true(isinf(row.float64("inf")), "'Infinity' did not decode to inf")
    assert_true(
        row.float64("inf") > 0, "'Infinity' decoded with the wrong sign"
    )
    assert_true(row.float64("neginf") < 0, "'-Infinity' decoded positive")
    # The literal's scale survives: this is why numeric stays a String.
    assert_equal(row.numeric("num"), "12345.678900")

    var blob = row.bytea("blob")
    assert_equal(len(blob), 4)
    assert_equal(blob[0], UInt8(0xDE))
    assert_equal(blob[1], UInt8(0xAD))
    assert_equal(blob[2], UInt8(0xBE))
    assert_equal(blob[3], UInt8(0xEF))

    assert_equal(row.date_days("d"), DAYS_2024_02_29)
    assert_equal(row.time_micros("t"), Int64(47_655_123_456))
    assert_equal(row.timestamp_micros("ts"), MICROS_2024_02_29_131415_123456)
    # The offset is applied, so the answer is UTC whatever the session's
    # TimeZone renders it as.
    assert_equal(
        row.timestamptz_micros("tstz"), MICROS_2024_02_29_131415_PLUS_0530
    )

    # A generated uuid is different every run; its shape is what is stable.
    var u = row.uuid("u")
    assert_equal(u.byte_length(), 36)
    assert_equal(u[byte=8], "-")
    assert_equal(u[byte=13], "-")
    assert_equal(u[byte=18], "-")
    assert_equal(u[byte=23], "-")

    # jsonb is stored parsed, so it comes back in the server's normal form --
    # note the space that was not in the literal.
    assert_equal(row.json("j"), '{"a": 1}')

    assert_true(row.bool("yes"))
    assert_false(row.bool("no"))
    assert_equal(row.text("yes"), "t")
    assert_equal(row.text("no"), "f")


def test_infinite_date_is_readable_as_text_but_not_as_days() raises:
    """``'infinity'::date`` has no epoch-day encoding, and says so.

    Refusing beats returning a sentinel that would compare as a real date.
    `Row.text` is the escape hatch, and it hands back exactly what the server
    sent.
    """
    var conn = _connect()
    var res = conn.query("SELECT 'infinity'::date AS d")
    var row = res.row(0)
    assert_equal(row.text("d"), "infinity")
    var raised = False
    try:
        _ = row.date_days("d")
    except e:
        raised = True
        assert_true("infinite" in String(e), "unexpected message: " + String(e))
    assert_true(raised, "'infinity'::date decoded as a day count")


# ===----------------------------------------------------------------------===#
# Prepared statements
# ===----------------------------------------------------------------------===#


def test_prepared_statement_runs_twice_with_different_params() raises:
    """The whole point of preparing: one parse, many executions.

    Both `Statement.query` and `Statement.execute` are covered, plus the
    `Connection.execute_prepared` form the `Statement` is a convenience over.
    """
    var conn = _connect()
    var stmt = conn.prepare("addup", "SELECT $1::int + $2::int AS total")
    assert_equal(stmt.name(), "addup")

    var first = stmt.query(Params().int32(2).int32(3))
    assert_equal(first.row(0).int32("total"), Int32(5))
    var second = stmt.query(Params().int32(40).int32(2))
    assert_equal(second.row(0).int32("total"), Int32(42))

    # ... and the same statement reached by name through the connection.
    var third = conn.query_prepared("addup", Params().int32(10).int32(11))
    assert_equal(third.row(0).int32("total"), Int32(21))

    _ = conn.execute("CREATE TEMP TABLE t (id int, name text)")
    var ins = conn.prepare("ins", "INSERT INTO t VALUES ($1, $2)")
    assert_equal(ins.execute(Params().int32(1).text("a")), 1)
    assert_equal(ins.execute(Params().int32(2).text("b")), 1)
    assert_equal(conn.execute_prepared("ins", Params().int32(3).text("c")), 1)
    var counted = conn.query("SELECT count(*) AS n FROM t")
    assert_equal(counted.row(0).int64("n"), 3)

    # Deallocating drops it from the session; running it again is an error.
    ins.deallocate()
    var raised = False
    try:
        _ = conn.execute_prepared("ins", Params().int32(4).text("d"))
    except:
        raised = True
    assert_true(raised, "a deallocated statement still executed")


# ===----------------------------------------------------------------------===#
# Errors
# ===----------------------------------------------------------------------===#


def test_unique_violation_carries_23505_and_its_detail() raises:
    """The error the SQL catalog turns into "that table already exists".

    Three things have to survive: the SQLSTATE, in the message where
    `sqlstate_of` finds it and in `Connection.last_error` where the predicates
    do; the server's ``DETAIL`` line, which names the conflicting key; and the
    statement text.
    """
    var conn = _connect()
    _ = conn.execute("CREATE TEMP TABLE t (id int primary key)")
    _ = conn.execute("INSERT INTO t VALUES ($1)", Params().int32(1))

    var raised = False
    try:
        _ = conn.execute("INSERT INTO t VALUES ($1)", Params().int32(1))
    except e:
        raised = True
        var message = String(e)
        assert_equal(sqlstate_of(e), "23505")
        assert_true(
            message.startswith("postgres [SQLSTATE 23505] "),
            "unexpected message shape: " + message,
        )
        assert_true(
            "duplicate key" in message, "unexpected message: " + message
        )
        assert_true(
            "\n  DETAIL: " in message,
            "the server's DETAIL line was dropped: " + message,
        )
        assert_true(
            "\n  SQL: INSERT INTO t VALUES ($1)" in message,
            "the statement was not echoed: " + message,
        )
    assert_true(raised, "a duplicate key did not raise")

    var last = conn.last_error()
    assert_true(
        last.is_unique_violation(), "last_error() lost the unique violation"
    )
    assert_true(last.is_integrity_violation())
    assert_equal(last.sqlstate, "23505")
    assert_equal(last.severity, "ERROR")
    assert_true(
        last.detail.byte_length() > 0, "last_error() lost the DETAIL field"
    )

    # The connection is still usable: a rejected statement is not a fatal
    # error, and nothing above rolled anything back.
    assert_true(conn.ping(), "a constraint violation broke the connection")


def test_syntax_error_carries_42601_and_echoes_the_sql() raises:
    """A statement the parser rejects, with the statement in the message.

    Which is the whole reason `sqlstate.PostgresError` carries `sql`: a
    syntax error five layers down a call stack is unreadable without it.
    """
    var conn = _connect()
    var raised = False
    try:
        _ = conn.execute("SELEC 1")
    except e:
        raised = True
        var message = String(e)
        assert_equal(sqlstate_of(e), "42601")
        assert_true(
            message.startswith("postgres [SQLSTATE 42601] "),
            "unexpected message shape: " + message,
        )
        assert_true(
            "\n  SQL: SELEC 1" in message,
            "the statement was not echoed: " + message,
        )
    assert_true(raised, "a syntax error did not raise")
    assert_equal(conn.last_error().sqlstate, "42601")


def test_undefined_table_carries_42p01() raises:
    """The other error every caller meets, through the parameterised path.

    `Connection.query` and `Connection.execute` take different branches
    (`PQexecParams` versus `PQexec`); both have to produce the same
    structured error.
    """
    var conn = _connect()
    var raised = False
    try:
        _ = conn.query(
            "SELECT * FROM no_such_table WHERE id = $1", Params().int32(1)
        )
    except e:
        raised = True
        assert_equal(sqlstate_of(e), "42P01")
    assert_true(raised, "selecting from a missing table did not raise")
    assert_true(conn.last_error().sqlstate == "42P01")


def test_column_index_of_a_missing_name_raises_and_lists_the_columns() raises:
    """Asking for a column that is not there names the ones that are.

    A misspelled or unexpectedly-cased column name is the most common way to
    get this wrong -- unquoted identifiers arrive folded to lower case -- so
    the message has to be enough to see the problem without a debugger.
    """
    var conn = _connect()
    var res = conn.query("SELECT 1 AS alpha, 2 AS beta")
    var raised = False
    try:
        _ = res.column_index("nope")
    except e:
        raised = True
        var message = String(e)
        assert_true("nope" in message, "unexpected message: " + message)
        assert_true(
            "alpha" in message, "the columns were not listed: " + message
        )
        assert_true(
            "beta" in message, "the columns were not listed: " + message
        )
    assert_true(raised, "an unknown column name did not raise")

    var raised_on_row = False
    try:
        _ = res.row(0).int64("nope")
    except:
        raised_on_row = True
    assert_true(raised_on_row, "Row accepted an unknown column name")


def test_out_of_range_indices_raise() raises:
    """Row and column indices are bounds-checked, not trusted.

    libpq answers an out-of-range `PQgetvalue` with ``""``, which would
    otherwise turn a bug into a silently empty value.
    """
    var conn = _connect()
    var res = conn.query("SELECT 1 AS n")
    for _ in range(1):
        var raised_row = False
        try:
            _ = res.row(1)
        except:
            raised_row = True
        assert_true(raised_row, "an out-of-range row index was accepted")

        var raised_col = False
        try:
            _ = res.text(0, 5)
        except:
            raised_col = True
        assert_true(raised_col, "an out-of-range column index was accepted")


# ===----------------------------------------------------------------------===#
# Row lifetime and iteration
# ===----------------------------------------------------------------------===#


def _fetch_one(mut conn: Connection) raises -> Row:
    """Return a row whose `Result` is destroyed before the caller sees it.

    The `Result` is a local: it clears the `PGresult` when this function
    returns.  A `Row` that borrowed libpq's memory would be dangling by then;
    this one copied it.

    Args:
        conn: The connection to query.

    Returns:
        The single row of a one-row query.

    Raises:
        Error: If the query failed.
    """
    var res = conn.query("SELECT 42 AS n, 'x'::text AS s, NULL::text AS z")
    return res.row(0)


def test_a_row_outlives_the_result_that_produced_it() raises:
    """The snapshot promise, checked where it would actually break.

    Both the values and the *column names* have to survive -- the names live
    in a refcounted block the `Row` holds a share of, not in the `PGresult`.
    """
    var conn = _connect()
    var row = _fetch_one(conn)
    assert_equal(row.int64("n"), 42)
    assert_equal(row.text("s"), "x")
    assert_true(row.is_null("z"))
    assert_equal(row.column_name(1), "s")
    assert_equal(row.num_cols(), 3)

    # A copy is independent of the original, which is what makes a Row safe to
    # stash in a collection.
    var copied = row.copy()
    assert_equal(copied.text("s"), "x")


def test_a_thousand_rows_iterate_cleanly() raises:
    """`for row in res:` over a result big enough for a mistake to show.

    A thousand rows is far past any small-size optimisation, so an iterator
    that mismanaged its index or its snapshots would drop, repeat or corrupt
    values here rather than accidentally working.
    """
    var conn = _connect()
    var res = conn.query("SELECT generate_series(1, 1000) AS n")
    assert_equal(res.num_rows(), 1000)

    var seen = 0
    var total: Int64 = 0
    for row in res:
        seen += 1
        total += row.int64("n")
    assert_equal(seen, 1000)
    assert_equal(total, Int64(500500))

    # The result is still usable after a full pass -- iteration borrows it,
    # it does not consume it.
    assert_equal(res.row(999).int64(0), Int64(1000))

    var second_pass = 0
    for _ in res:
        second_pass += 1
    assert_equal(second_pass, 1000)


def test_iterating_an_empty_result_yields_nothing() raises:
    """The boundary the loop gets wrong first."""
    var conn = _connect()
    var res = conn.query("SELECT 1 AS n WHERE false")
    var seen = 0
    for _ in res:
        seen += 1
    assert_equal(seen, 0)


def main() raises:
    if not getenv("POSTGRES_TEST_DSN", ""):
        print(
            "server_test: skipped -- set $POSTGRES_TEST_DSN, or run via"
            " `pixi run server`, to exercise the live suite"
        )
        return
    TestSuite.discover_tests[__functions_in_module()]().run()
