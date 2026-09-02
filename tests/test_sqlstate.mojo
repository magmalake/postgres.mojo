"""Unit tests for `postgres.sqlstate` — no server required.

Covers `PostgresError.format()` (the message shape, the DETAIL/HINT/SQL
lines, and SQL-text truncation), the `sqlstate_of()` round trip through a
raised `Error`, and every predicate."""

from std.testing import (
    TestSuite,
    assert_equal,
    assert_true,
    assert_false,
    assert_raises,
)

from postgres.sqlstate import (
    PostgresError,
    sqlstate_of,
    sqlstate_class,
    is_unique_violation,
    is_serialization_failure,
    is_deadlock,
    is_integrity_violation,
    is_connection_error,
    is_retryable,
    UNIQUE_VIOLATION,
    FOREIGN_KEY_VIOLATION,
    NOT_NULL_VIOLATION,
    CHECK_VIOLATION,
    SERIALIZATION_FAILURE,
    DEADLOCK_DETECTED,
    UNDEFINED_TABLE,
    UNDEFINED_COLUMN,
    SYNTAX_ERROR,
    INSUFFICIENT_PRIVILEGE,
    DUPLICATE_TABLE,
    QUERY_CANCELED,
    INVALID_TEXT_REPRESENTATION,
    NUMERIC_VALUE_OUT_OF_RANGE,
    DIVISION_BY_ZERO,
    LOCK_NOT_AVAILABLE,
    ADMIN_SHUTDOWN,
    CONNECTION_FAILURE,
    SQLCLIENT_UNABLE_TO_ESTABLISH,
)


# ── format() ─────────────────────────────────────────────────────────────


def test_format_message_only() raises:
    var err = PostgresError(message="boom")
    assert_equal(err.format(), String("postgres: boom"))


def test_format_with_sqlstate() raises:
    var err = PostgresError(sqlstate="23505", message="duplicate key")
    assert_equal(
        err.format(), String("postgres [SQLSTATE 23505] duplicate key")
    )


def test_format_with_detail_and_hint() raises:
    var err = PostgresError(
        sqlstate="23505",
        message="duplicate key value violates unique constraint",
        detail="Key (id)=(1) already exists.",
        hint="Use ON CONFLICT to ignore or update duplicate rows.",
    )
    var got = err.format()
    assert_equal(
        got,
        String(
            "postgres [SQLSTATE 23505] duplicate key value violates unique"
            " constraint\n  DETAIL: Key (id)=(1) already exists.\n  HINT:"
            " Use ON CONFLICT to ignore or update duplicate rows."
        ),
    )


def test_format_detail_without_hint() raises:
    var err = PostgresError(
        sqlstate="23502", message="null value", detail="Column x is null."
    )
    var got = err.format()
    assert_true(got.find("DETAIL: Column x is null.") >= 0)
    assert_true(got.find("HINT:") < 0)


def test_format_hint_without_detail() raises:
    var err = PostgresError(
        sqlstate="42703", message="column missing", hint="Check spelling."
    )
    var got = err.format()
    assert_true(got.find("HINT: Check spelling.") >= 0)
    assert_true(got.find("DETAIL:") < 0)


def test_format_with_sql() raises:
    var err = PostgresError(
        sqlstate="42601", message="syntax error", sql="SELECT * FROM t"
    )
    assert_equal(
        err.format(),
        String(
            "postgres [SQLSTATE 42601] syntax error\n  SQL: SELECT * FROM t"
        ),
    )


def test_format_full() raises:
    var err = PostgresError(
        severity="ERROR",
        sqlstate="23505",
        message="duplicate key",
        detail="Key (id)=(1) already exists.",
        hint="Use ON CONFLICT.",
        sql="INSERT INTO t VALUES (1)",
    )
    var got = err.format()
    var expect_prefix = "postgres [SQLSTATE 23505] duplicate key"
    assert_true(got.find(expect_prefix) == 0)
    assert_true(got.find("DETAIL: Key (id)=(1) already exists.") > 0)
    assert_true(got.find("HINT: Use ON CONFLICT.") > 0)
    assert_true(got.find("SQL: INSERT INTO t VALUES (1)") > 0)
    # Lines appear in DETAIL, HINT, SQL order.
    var detail_pos = got.find("DETAIL:")
    var hint_pos = got.find("HINT:")
    var sql_pos = got.find("SQL:")
    assert_true(detail_pos < hint_pos)
    assert_true(hint_pos < sql_pos)


# ── SQL truncation ───────────────────────────────────────────────────────


def test_sql_under_limit_is_not_truncated() raises:
    var sql = "SELECT 1"
    var err = PostgresError(message="x", sql=sql)
    var got = err.format()
    assert_true(got.find("SQL: SELECT 1") >= 0)
    assert_true(got.find("…") < 0)


def test_sql_exactly_200_is_not_truncated() raises:
    var sql = String("")
    for _ in range(200):
        sql += "a"
    assert_equal(sql.byte_length(), 200)
    var err = PostgresError(message="x", sql=sql)
    var got = err.format()
    assert_true(got.find("…") < 0)
    assert_true(got.find("SQL: " + sql) >= 0)


def test_sql_over_200_is_truncated_with_ellipsis() raises:
    var sql = String("")
    for _ in range(250):
        sql += "a"
    var err = PostgresError(message="x", sql=sql)
    var got = err.format()
    var marker = "SQL: "
    var start = got.find(marker)
    assert_true(start >= 0)
    var sql_line_start = start + marker.byte_length()
    var sql_line = String("")
    var b = got.as_bytes()
    for i in range(sql_line_start, len(b)):
        sql_line += String(StringSlice(unsafe_from_utf8=Span(b)[i : i + 1]))
    # 200 'a's plus the ellipsis marker.
    var expect = String("")
    for _ in range(200):
        expect += "a"
    expect += "…"
    assert_equal(sql_line, expect)


def test_sql_newlines_collapsed_to_spaces() raises:
    # Each CR and LF byte becomes one space, so "\r\n" becomes two spaces.
    var err = PostgresError(message="x", sql="SELECT 1\nFROM t\r\nWHERE x=1")
    var got = err.format()
    assert_true(got.find("SQL: SELECT 1 FROM t  WHERE x=1") >= 0)
    var sql_marker = got.find("SQL:")
    assert_true(got.find("\n", sql_marker + 4) < 0)


# ── sqlstate_of() ────────────────────────────────────────────────────────


def test_sqlstate_of_message_round_trip() raises:
    var err = PostgresError(sqlstate="23505", message="dup")
    var code = sqlstate_of(err.format())
    assert_equal(code, String("23505"))


def test_sqlstate_of_error_round_trip() raises:
    var err = PostgresError(sqlstate="40P01", message="deadlock detected")
    with assert_raises(contains="40P01"):
        raise err.to_error()
    try:
        raise err.to_error()
    except caught:
        assert_equal(sqlstate_of(caught), String("40P01"))


def test_sqlstate_of_absent_token_is_empty() raises:
    assert_equal(sqlstate_of(String("connection refused")), String(""))
    assert_equal(sqlstate_of(String("")), String(""))


def test_sqlstate_of_malformed_short_code_is_empty() raises:
    assert_equal(sqlstate_of(String("postgres [SQLSTATE 2350] x")), String(""))


def test_sqlstate_of_malformed_unclosed_token_is_empty() raises:
    assert_equal(sqlstate_of(String("postgres [SQLSTATE 23505 x")), String(""))


def test_sqlstate_of_letter_code() raises:
    var err = PostgresError(sqlstate="40P01", message="deadlock detected")
    assert_equal(sqlstate_of(err.format()), String("40P01"))


def test_sqlstate_of_takes_first_token() raises:
    var msg = String(
        "postgres [SQLSTATE 23505] dup; nested: [SQLSTATE 40001] retry"
    )
    assert_equal(sqlstate_of(msg), String("23505"))


# ── sqlstate_class() ─────────────────────────────────────────────────────


def test_sqlstate_class() raises:
    assert_equal(sqlstate_class(String("23505")), String("23"))
    assert_equal(sqlstate_class(String("40P01")), String("40"))
    assert_equal(sqlstate_class(String("")), String(""))
    assert_equal(sqlstate_class(String("2")), String(""))


# ── predicates: free functions ───────────────────────────────────────────


def test_is_unique_violation() raises:
    assert_true(is_unique_violation(String(UNIQUE_VIOLATION)))
    assert_false(is_unique_violation(String(FOREIGN_KEY_VIOLATION)))


def test_is_serialization_failure() raises:
    assert_true(is_serialization_failure(String(SERIALIZATION_FAILURE)))
    assert_false(is_serialization_failure(String(DEADLOCK_DETECTED)))


def test_is_deadlock() raises:
    assert_true(is_deadlock(String(DEADLOCK_DETECTED)))
    assert_false(is_deadlock(String(SERIALIZATION_FAILURE)))


def test_is_integrity_violation() raises:
    assert_true(is_integrity_violation(String(UNIQUE_VIOLATION)))
    assert_true(is_integrity_violation(String(FOREIGN_KEY_VIOLATION)))
    assert_true(is_integrity_violation(String(NOT_NULL_VIOLATION)))
    assert_true(is_integrity_violation(String(CHECK_VIOLATION)))
    assert_false(is_integrity_violation(String(UNDEFINED_TABLE)))


def test_is_connection_error() raises:
    assert_true(is_connection_error(String(CONNECTION_FAILURE)))
    assert_true(is_connection_error(String(SQLCLIENT_UNABLE_TO_ESTABLISH)))
    assert_false(is_connection_error(String(UNIQUE_VIOLATION)))


def test_is_retryable() raises:
    assert_true(is_retryable(String(SERIALIZATION_FAILURE)))
    assert_true(is_retryable(String(DEADLOCK_DETECTED)))
    assert_false(is_retryable(String(UNIQUE_VIOLATION)))


def test_remaining_named_codes_are_the_documented_values() raises:
    assert_equal(String(UNDEFINED_TABLE), String("42P01"))
    assert_equal(String(UNDEFINED_COLUMN), String("42703"))
    assert_equal(String(SYNTAX_ERROR), String("42601"))
    assert_equal(String(INSUFFICIENT_PRIVILEGE), String("42501"))
    assert_equal(String(DUPLICATE_TABLE), String("42P07"))
    assert_equal(String(QUERY_CANCELED), String("57014"))
    assert_equal(String(INVALID_TEXT_REPRESENTATION), String("22P02"))
    assert_equal(String(NUMERIC_VALUE_OUT_OF_RANGE), String("22003"))
    assert_equal(String(DIVISION_BY_ZERO), String("22012"))
    assert_equal(String(LOCK_NOT_AVAILABLE), String("55P03"))
    assert_equal(String(ADMIN_SHUTDOWN), String("57P01"))


# ── predicates: PostgresError methods mirror the free functions ─────────


def test_error_method_predicates() raises:
    var unique = PostgresError(sqlstate="23505", message="dup")
    assert_true(unique.is_unique_violation())
    assert_true(unique.is_integrity_violation())
    assert_false(unique.is_retryable())

    var deadlock = PostgresError(sqlstate="40P01", message="deadlock")
    assert_true(deadlock.is_deadlock())
    assert_true(deadlock.is_retryable())
    assert_false(deadlock.is_integrity_violation())

    var serialization = PostgresError(sqlstate="40001", message="retry")
    assert_true(serialization.is_serialization_failure())
    assert_true(serialization.is_retryable())

    var conn = PostgresError(sqlstate="08006", message="lost")
    assert_true(conn.is_connection_error())
    assert_false(conn.is_retryable())


def test_error_no_sqlstate_predicates_all_false() raises:
    var err = PostgresError(message="no code here")
    assert_false(err.is_unique_violation())
    assert_false(err.is_serialization_failure())
    assert_false(err.is_deadlock())
    assert_false(err.is_integrity_violation())
    assert_false(err.is_connection_error())
    assert_false(err.is_retryable())


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
