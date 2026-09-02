"""SQLSTATE handling: structured errors, and the codes libpq reports.

Every error a PostgreSQL server sends carries a five-character SQLSTATE code
(`23505`, `40P01`, ...) alongside a human-readable message — see
https://www.postgresql.org/docs/current/errcodes-appendix.html. Mojo 1.x can
only `raise Error(String)`, so there is no field to hang the code on when an
error crosses a `raises` boundary. Instead this module packs the code into a
parseable token inside the message text (`"[SQLSTATE 23505]"`), and gives
callers two ways back out:

- `PostgresError` is the structured value: build one from a libpq result,
  call `.to_error()` to raise it, and keep the original struct around
  wherever a `try`/`except` block has an `Error` in hand and wants the
  fields back — reconstruct a `PostgresError(...)`, or just pull the code
  via `sqlstate_of(err)`.
- `sqlstate_of()` recovers the raw code from an `Error` or a `String` even
  when the `PostgresError` itself is gone — the common case, since Mojo's
  `except err:` only ever hands back an `Error`.

`08001` and `08006` are not real server SQLSTATEs — libpq itself reports no
SQLSTATE at all for a connection that never came up or that dropped mid-use
(`PQerrorMessage` on a failed/lost connection carries only free text). The FFI
layer synthesizes `SQLCLIENT_UNABLE_TO_ESTABLISH` (08001) for a failed
`PQconnectdb` and `CONNECTION_FAILURE` (08006) for a connection lost after it
was established, mirroring the meaning class 08 has for every other client.
"""


# ===----------------------------------------------------------------------===#
# Well-known SQLSTATE codes (a small, curated subset — the full list is in
# the PostgreSQL manual linked above). Typed as `StaticString`, which is a
# zero-allocation constant string slice that converts implicitly to `String`
# at any call site that expects one.
# ===----------------------------------------------------------------------===#

comptime UNIQUE_VIOLATION: StaticString = "23505"
comptime FOREIGN_KEY_VIOLATION: StaticString = "23503"
comptime NOT_NULL_VIOLATION: StaticString = "23502"
comptime CHECK_VIOLATION: StaticString = "23514"
comptime SERIALIZATION_FAILURE: StaticString = "40001"
comptime DEADLOCK_DETECTED: StaticString = "40P01"
comptime UNDEFINED_TABLE: StaticString = "42P01"
comptime UNDEFINED_COLUMN: StaticString = "42703"
comptime SYNTAX_ERROR: StaticString = "42601"
comptime INSUFFICIENT_PRIVILEGE: StaticString = "42501"
comptime DUPLICATE_TABLE: StaticString = "42P07"
comptime QUERY_CANCELED: StaticString = "57014"
comptime INVALID_TEXT_REPRESENTATION: StaticString = "22P02"
comptime NUMERIC_VALUE_OUT_OF_RANGE: StaticString = "22003"
comptime DIVISION_BY_ZERO: StaticString = "22012"
comptime LOCK_NOT_AVAILABLE: StaticString = "55P03"
comptime ADMIN_SHUTDOWN: StaticString = "57P01"
comptime CONNECTION_FAILURE: StaticString = "08006"
comptime SQLCLIENT_UNABLE_TO_ESTABLISH: StaticString = "08001"


# ===----------------------------------------------------------------------===#
# Byte-level string helpers. Mojo's `String` has no slice syntax
# (`s[0:10]`), so a byte-range substring goes through a `Span`.
# ===----------------------------------------------------------------------===#


def _substr(s: String, start: Int, end: Int) -> String:
    """Byte-range substring `s[start:end]`, clamped to the string's bounds."""
    var b = s.as_bytes()
    var a = start if start > 0 else 0
    var z = end if end < len(b) else len(b)
    if a >= z:
        return String("")
    return String(StringSlice(unsafe_from_utf8=Span(b)[a:z]))


def _is_sqlstate_shaped(code: String) -> Bool:
    """True for exactly five uppercase-alphanumeric bytes (`40P01`,
    `23505`) — the shape every real SQLSTATE has."""
    var b = code.as_bytes()
    if len(b) != 5:
        return False
    for i in range(5):
        var c = b[i]
        var is_digit = c >= UInt8(ord("0")) and c <= UInt8(ord("9"))
        var is_upper = c >= UInt8(ord("A")) and c <= UInt8(ord("Z"))
        if not (is_digit or is_upper):
            return False
    return True


comptime _TOKEN_PREFIX: StaticString = "[SQLSTATE "
comptime _TOKEN_SUFFIX: StaticString = "]"


def sqlstate_of(message: String) -> String:
    """Extract the code inside the first `"[SQLSTATE XXXXX]"` token in
    `message`.

    Returns `""` if no such token is present, or if what's between the
    brackets isn't exactly five uppercase-alphanumeric characters (a
    truncated or hand-edited message)."""
    var prefix = String(_TOKEN_PREFIX)
    var start = message.find(prefix)
    if start < 0:
        return ""
    var code_start = start + prefix.byte_length()
    var end = message.find(String(_TOKEN_SUFFIX), code_start)
    if end < 0:
        return ""
    var code = _substr(message, code_start, end)
    if not _is_sqlstate_shaped(code):
        return ""
    return code


def sqlstate_of(err: Error) -> String:
    """Extract the SQLSTATE code from a caught `Error` — the usual case,
    since Mojo's `except err:` hands back only an `Error`. See the
    `String` overload for the parsing rules."""
    return sqlstate_of(String(err))


def sqlstate_class(code: String) -> String:
    """The two-character SQLSTATE class (`"23"` for `"23505"`), or `""` if
    `code` is shorter than two characters.

    The class is the coarse-grained grouping PostgreSQL itself uses in the
    errcodes appendix — class `23` is every integrity-constraint violation,
    class `08` is every connection error, and so on."""
    if code.byte_length() < 2:
        return ""
    return _substr(code, 0, 2)


# ===----------------------------------------------------------------------===#
# Predicates on a bare SQLSTATE code.
# ===----------------------------------------------------------------------===#


def is_unique_violation(code: String) -> Bool:
    """True for `UNIQUE_VIOLATION` (`23505`)."""
    return code == UNIQUE_VIOLATION


def is_serialization_failure(code: String) -> Bool:
    """True for `SERIALIZATION_FAILURE` (`40001`), the code a
    `SERIALIZABLE` transaction gets when it loses a conflict."""
    return code == SERIALIZATION_FAILURE


def is_deadlock(code: String) -> Bool:
    """True for `DEADLOCK_DETECTED` (`40P01`)."""
    return code == DEADLOCK_DETECTED


def is_integrity_violation(code: String) -> Bool:
    """True for class `23` — every constraint violation (unique, foreign
    key, not-null, check)."""
    return sqlstate_class(code) == "23"


def is_connection_error(code: String) -> Bool:
    """True for class `08` — every connection-establishment or
    connection-loss error, including the synthesized `08001`/`08006`
    documented at the top of this module."""
    return sqlstate_class(code) == "08"


def is_retryable(code: String) -> Bool:
    """True for `SERIALIZATION_FAILURE` or `DEADLOCK_DETECTED` — the two
    codes PostgreSQL's own docs recommend retrying the whole transaction
    for, rather than surfacing to the caller."""
    return code == SERIALIZATION_FAILURE or code == DEADLOCK_DETECTED


# ===----------------------------------------------------------------------===#
# PostgresError — the structured value.
# ===----------------------------------------------------------------------===#


struct PostgresError(Copyable, Movable, Writable):
    """A PostgreSQL error, decomposed the way `PQresultErrorField` reports
    it: severity, SQLSTATE, primary message, and the optional detail/hint
    the server adds to explain or suggest a fix.

    All fields are `String` and empty when the server didn't supply them.
    `sql` is not one of libpq's fields — it's the statement text the caller
    was executing, attached here so the formatted error is self-contained
    in a log line.
    """

    var severity: String
    """`ERROR`, `FATAL`, `PANIC`, or a localized equivalent. Empty if
    unknown."""
    var sqlstate: String
    """The five-character SQLSTATE code, e.g. `23505`. Empty if the source
    of this error didn't have one (see the module docstring)."""
    var message: String
    """The primary human-readable message."""
    var detail: String
    """An optional secondary message with more detail. Empty if absent."""
    var hint: String
    """An optional suggestion of how to fix the problem. Empty if
    absent."""
    var sql: String
    """The SQL text being executed when the error occurred. Empty if not
    attached."""

    def __init__(
        out self,
        severity: String = "",
        sqlstate: String = "",
        message: String = "",
        detail: String = "",
        hint: String = "",
        sql: String = "",
    ):
        self.severity = severity
        self.sqlstate = sqlstate
        self.message = message
        self.detail = detail
        self.hint = hint
        self.sql = sql

    def format(self) -> String:
        """Render the multi-line form this type prints and raises as.

        Line one is `"postgres [SQLSTATE 23505] <message>"`, or
        `"postgres: <message>"` when there's no SQLSTATE to report. A
        `DETAIL:` line follows if `detail` is set, then a `HINT:` line if
        `hint` is set, then a `SQL:` line — collapsed to one line and
        capped at 200 characters — if `sql` is set."""
        var out = String("")
        if self.sqlstate == "":
            out += "postgres: " + self.message
        else:
            out += "postgres [SQLSTATE " + self.sqlstate + "] " + self.message
        if self.detail != "":
            out += "\n  DETAIL: " + self.detail
        if self.hint != "":
            out += "\n  HINT: " + self.hint
        if self.sql != "":
            out += "\n  SQL: " + _display_sql(self.sql)
        return out

    def __str__(self) -> String:
        """Same as `format()`."""
        return self.format()

    def write_to(self, mut writer: Some[Writer]):
        """Write `format()` to `writer` — what makes `String(err)` and
        `print(err)` produce the formatted form."""
        writer.write(self.format())

    def to_error(self) -> Error:
        """Wrap `format()` in an `Error`, ready to `raise`.

        `sqlstate_of()` recovers `self.sqlstate` back out of the raised
        `Error` on the far side of a `try`/`except`."""
        return Error(self.format())

    # -- predicates, mirroring the free functions above ---------------------

    def is_unique_violation(self) -> Bool:
        """See the free function of the same name."""
        return is_unique_violation(self.sqlstate)

    def is_serialization_failure(self) -> Bool:
        """See the free function of the same name."""
        return is_serialization_failure(self.sqlstate)

    def is_deadlock(self) -> Bool:
        """See the free function of the same name."""
        return is_deadlock(self.sqlstate)

    def is_integrity_violation(self) -> Bool:
        """See the free function of the same name."""
        return is_integrity_violation(self.sqlstate)

    def is_connection_error(self) -> Bool:
        """See the free function of the same name."""
        return is_connection_error(self.sqlstate)

    def is_retryable(self) -> Bool:
        """See the free function of the same name."""
        return is_retryable(self.sqlstate)


# ===----------------------------------------------------------------------===#
# SQL text formatting for the "SQL:" line — collapsed to one line and capped
# at 200 characters, so one bad statement can't blow up a log line.
# ===----------------------------------------------------------------------===#

comptime _SQL_DISPLAY_LIMIT = 200


def _display_sql(sql: String) -> String:
    """Collapse embedded CR/LF into spaces, then cap the result at
    `_SQL_DISPLAY_LIMIT` codepoints, appending `"…"` if anything was cut."""
    var flattened = List[UInt8](capacity=sql.byte_length())
    for c in sql.as_bytes():
        if c == UInt8(ord("\n")) or c == UInt8(ord("\r")):
            flattened.append(UInt8(ord(" ")))
        else:
            flattened.append(c)
    var collapsed = String(StringSlice(unsafe_from_utf8=Span(flattened)))

    var out = String("")
    var count = 0
    var truncated = False
    for cp in collapsed.codepoint_slices():
        if count >= _SQL_DISPLAY_LIMIT:
            truncated = True
            break
        out += String(cp)
        count += 1
    if truncated:
        out += "…"
    return out
