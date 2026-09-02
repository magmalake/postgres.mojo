"""`postgres.text` — the PostgreSQL text-format codec.

libpq hands back every result cell as text (`PQgetvalue` never returns binary
unless the caller asked for binary-format results, which this tin does not).
This module is the two-way bridge between that text and Mojo values:
`decode_*` turns a column's text into a typed value given its OID; `encode_*`
turns a Mojo value back into the text `PQexecParams`/`COPY` expect. Pure
Mojo — no FFI, no libpq call, so it is usable and testable without a server.

Dates and timestamps decode to integers (days/microseconds since the Unix
epoch, 1970-01-01) using the proleptic Gregorian calendar via Howard
Hinnant's `days_from_civil` / `civil_from_days` — see
http://howardhinnant.github.io/date_algorithms.html. `numeric` deliberately
stays a `String`: coercing arbitrary-precision decimals to `Float64` would
silently lose precision, so callers that want a number parse it themselves.
`bytea` decodes both text sub-formats libpq can emit — hex (the
`bytea_output=hex` server default) and the legacy octal-escape format — so no
`PQunescapeBytea` call is needed either.
"""

from std.utils.numerics import isinf, isnan


# ===----------------------------------------------------------------------===#
# OID constants (see magmalake.org/issues/1 section 5)
# ===----------------------------------------------------------------------===#

comptime OID_BOOL: UInt32 = 16
comptime OID_BYTEA: UInt32 = 17
comptime OID_INT8: UInt32 = 20
comptime OID_INT2: UInt32 = 21
comptime OID_INT4: UInt32 = 23
comptime OID_TEXT: UInt32 = 25
comptime OID_JSON: UInt32 = 114
comptime OID_FLOAT4: UInt32 = 700
comptime OID_FLOAT8: UInt32 = 701
comptime OID_BPCHAR: UInt32 = 1042
comptime OID_VARCHAR: UInt32 = 1043
comptime OID_DATE: UInt32 = 1082
comptime OID_TIME: UInt32 = 1083
comptime OID_TIMESTAMP: UInt32 = 1114
comptime OID_TIMESTAMPTZ: UInt32 = 1184
comptime OID_NUMERIC: UInt32 = 1700
comptime OID_UUID: UInt32 = 2950
comptime OID_JSONB: UInt32 = 3802


def oid_name(oid: UInt32) -> String:
    """Return the PostgreSQL type name for a well-known OID, or `"oid:<n>"`
    for anything this tin does not special-case.
    """
    if oid == OID_BOOL:
        return String("bool")
    elif oid == OID_BYTEA:
        return String("bytea")
    elif oid == OID_INT8:
        return String("int8")
    elif oid == OID_INT2:
        return String("int2")
    elif oid == OID_INT4:
        return String("int4")
    elif oid == OID_TEXT:
        return String("text")
    elif oid == OID_JSON:
        return String("json")
    elif oid == OID_FLOAT4:
        return String("float4")
    elif oid == OID_FLOAT8:
        return String("float8")
    elif oid == OID_BPCHAR:
        return String("bpchar")
    elif oid == OID_VARCHAR:
        return String("varchar")
    elif oid == OID_DATE:
        return String("date")
    elif oid == OID_TIME:
        return String("time")
    elif oid == OID_TIMESTAMP:
        return String("timestamp")
    elif oid == OID_TIMESTAMPTZ:
        return String("timestamptz")
    elif oid == OID_NUMERIC:
        return String("numeric")
    elif oid == OID_UUID:
        return String("uuid")
    elif oid == OID_JSONB:
        return String("jsonb")
    else:
        return String("oid:", oid)


def is_text_oid(oid: UInt32) -> Bool:
    """True for OIDs whose natural Mojo representation is `String` —
    TEXT/VARCHAR/BPCHAR/UUID/JSON/JSONB, and NUMERIC (kept a `String` on
    purpose; see the module docstring).
    """
    return (
        oid == OID_TEXT
        or oid == OID_VARCHAR
        or oid == OID_BPCHAR
        or oid == OID_UUID
        or oid == OID_JSON
        or oid == OID_JSONB
        or oid == OID_NUMERIC
    )


# ===----------------------------------------------------------------------===#
# Small shared byte-scanning helpers
# ===----------------------------------------------------------------------===#


def _is_digit(b: UInt8) -> Bool:
    return b >= UInt8(ord("0")) and b <= UInt8(ord("9"))


def _is_octal_digit(b: UInt8) -> Bool:
    return b >= UInt8(ord("0")) and b <= UInt8(ord("7"))


def _parse_unsigned_digits(s: StringSlice, start: Int, end: Int) -> Int64:
    """Parse `s[byte=start:end]` as an unsigned decimal integer. The caller
    must have already verified every byte in the range is an ASCII digit."""
    var data = s.as_bytes()
    var v: Int64 = 0
    for i in range(start, end):
        v = v * 10 + Int64(Int(data[i]) - Int(ord("0")))
    return v


def _zero_pad(v: Int64, width: Int) -> String:
    var s = String(v)
    while s.byte_length() < width:
        s = String("0", s)
    return s


# ===----------------------------------------------------------------------===#
# bool
# ===----------------------------------------------------------------------===#


def decode_bool(s: StringSlice) raises -> Bool:
    """Decode `bool` text. The server always emits `t`/`f`; `true`/`false`
    are also accepted because COPY CSV round-trips can carry them."""
    if s == "t" or s == "true":
        return True
    if s == "f" or s == "false":
        return False
    raise Error(String("postgres.text: invalid bool text: '", s, "'"))


def encode_bool(v: Bool) -> String:
    if v:
        return String("t")
    return String("f")


# ===----------------------------------------------------------------------===#
# Integers
# ===----------------------------------------------------------------------===#

comptime _U64_MAX_DIV10: UInt64 = 1844674407370955161
comptime _U64_MAX_MOD10: UInt64 = 5


def _decode_signed(
    s: StringSlice, type_name: String, max_pos: UInt64, max_neg_mag: UInt64
) raises -> Int64:
    """Shared strict decimal-integer parser: optional leading `+`/`-`, ASCII
    digits only (no whitespace, no underscores, no base prefixes), and a
    range check against `max_pos` / `max_neg_mag` (`|min|`)."""
    var invalid_msg = String(
        "postgres.text: invalid ", type_name, " text: '", s, "'"
    )
    var n = s.byte_length()
    if n == 0:
        raise Error(invalid_msg)
    var data = s.as_bytes()
    var i = 0
    var negative = False
    if data[0] == UInt8(ord("+")):
        i = 1
    elif data[0] == UInt8(ord("-")):
        negative = True
        i = 1
    if i == n:
        raise Error(invalid_msg)

    var acc: UInt64 = 0
    while i < n:
        var b = data[i]
        if not _is_digit(b):
            raise Error(invalid_msg)
        var d = UInt64(Int(b) - Int(ord("0")))
        if acc > _U64_MAX_DIV10 or (
            acc == _U64_MAX_DIV10 and d > _U64_MAX_MOD10
        ):
            raise Error(
                String("postgres.text: ", type_name, " out of range: '", s, "'")
            )
        acc = acc * 10 + d
        i += 1

    var range_msg = String(
        "postgres.text: ", type_name, " out of range: '", s, "'"
    )
    if negative:
        if acc > max_neg_mag:
            raise Error(range_msg)
        if acc == 0:
            return Int64(0)
        # `-(acc)` computed via `acc - 1` so the intermediate fits in Int64
        # even when `acc` is exactly `|Int64.MIN|` (2**63).
        return -(Int64(acc - 1)) - 1
    else:
        if acc > max_pos:
            raise Error(range_msg)
        return Int64(acc)


def decode_int16(s: StringSlice) raises -> Int16:
    return Int16(_decode_signed(s, "int2", 32767, 32768))


def decode_int32(s: StringSlice) raises -> Int32:
    return Int32(_decode_signed(s, "int4", 2147483647, 2147483648))


def decode_int64(s: StringSlice) raises -> Int64:
    return _decode_signed(s, "int8", 9223372036854775807, 9223372036854775808)


def encode_int16(v: Int16) -> String:
    return String(v)


def encode_int32(v: Int32) -> String:
    return String(v)


def encode_int64(v: Int64) -> String:
    return String(v)


# ===----------------------------------------------------------------------===#
# Floats
# ===----------------------------------------------------------------------===#


def decode_float32(s: StringSlice) raises -> Float32:
    """`atof` already accepts PostgreSQL's `NaN`/`Infinity`/`-Infinity`
    spellings case-insensitively (and the `inf`/`nan` short forms), plus
    standard decimal/scientific notation, so this is a thin wrapper that
    narrows to `Float32` and rewraps the error with the offending text."""
    try:
        return Float32(atof(s))
    except:
        raise Error(String("postgres.text: invalid float4 text: '", s, "'"))


def decode_float64(s: StringSlice) raises -> Float64:
    try:
        return atof(s)
    except:
        raise Error(String("postgres.text: invalid float8 text: '", s, "'"))


def encode_float32(v: Float32) -> String:
    if isnan(v):
        return String("NaN")
    if isinf(v):
        if v < 0:
            return String("-Infinity")
        return String("Infinity")
    return String(v)


def encode_float64(v: Float64) -> String:
    if isnan(v):
        return String("NaN")
    if isinf(v):
        if v < 0:
            return String("-Infinity")
        return String("Infinity")
    return String(v)


# ===----------------------------------------------------------------------===#
# bytea — hex (server default) and legacy escape format
# ===----------------------------------------------------------------------===#

comptime _HEX_DIGITS: StaticString = "0123456789abcdef"


def _hex_nibble(b: UInt8, s: StringSlice) raises -> UInt8:
    if b >= UInt8(ord("0")) and b <= UInt8(ord("9")):
        return b - UInt8(ord("0"))
    if b >= UInt8(ord("a")) and b <= UInt8(ord("f")):
        return b - UInt8(ord("a")) + 10
    if b >= UInt8(ord("A")) and b <= UInt8(ord("F")):
        return b - UInt8(ord("A")) + 10
    raise Error(String("postgres.text: invalid bytea hex text: '", s, "'"))


def _decode_bytea_hex(s: StringSlice) raises -> List[UInt8]:
    var data = s.as_bytes()
    var n = s.byte_length()
    var hex_len = n - 2
    if hex_len % 2 != 0:
        raise Error(
            String(
                "postgres.text: invalid bytea hex text (odd length): '",
                s,
                "'",
            )
        )
    var out = List[UInt8](capacity=hex_len // 2)
    var i = 2
    while i < n:
        var hi = _hex_nibble(data[i], s)
        var lo = _hex_nibble(data[i + 1], s)
        out.append((hi << 4) | lo)
        i += 2
    return out^


def _decode_bytea_escape(s: StringSlice) raises -> List[UInt8]:
    var data = s.as_bytes()
    var n = s.byte_length()
    var invalid_msg = String(
        "postgres.text: invalid bytea escape text: '", s, "'"
    )
    var out = List[UInt8]()
    var i = 0
    while i < n:
        var b = data[i]
        if b == UInt8(ord("\\")):
            if i + 1 < n and data[i + 1] == UInt8(ord("\\")):
                out.append(UInt8(0x5C))
                i += 2
            elif (
                i + 3 < n
                and _is_octal_digit(data[i + 1])
                and _is_octal_digit(data[i + 2])
                and _is_octal_digit(data[i + 3])
            ):
                var value = (
                    Int(data[i + 1] - UInt8(ord("0"))) * 64
                    + Int(data[i + 2] - UInt8(ord("0"))) * 8
                    + Int(data[i + 3] - UInt8(ord("0")))
                )
                if value > 255:
                    raise Error(invalid_msg)
                out.append(UInt8(value))
                i += 4
            else:
                raise Error(invalid_msg)
        else:
            out.append(b)
            i += 1
    return out^


def decode_bytea(s: StringSlice) raises -> List[UInt8]:
    """Decode `bytea` text — either the `\\x`-prefixed hex format
    (`bytea_output=hex`, the server default) or the legacy escape format
    (`\\\\` for a literal backslash, `\\ooo` three-octal-digit byte escapes,
    every other byte literal)."""
    var n = s.byte_length()
    if n >= 2:
        var data = s.as_bytes()
        if data[0] == UInt8(ord("\\")) and data[1] == UInt8(ord("x")):
            return _decode_bytea_hex(s)
    return _decode_bytea_escape(s)


def encode_bytea(data: Span[UInt8, _]) -> String:
    """`\\x` + lowercase hex — the format `bytea_output=hex` expects."""
    var out = String("\\x")
    for b in data:
        out += _HEX_DIGITS[byte=Int(b >> 4)]
        out += _HEX_DIGITS[byte=Int(b & 0xF)]
    return out^


# ===----------------------------------------------------------------------===#
# Dates and times — proleptic Gregorian, Howard Hinnant's civil_from_days /
# days_from_civil (http://howardhinnant.github.io/date_algorithms.html).
#
# Mojo's `//` and `%` are floor division/modulo (same sign as the divisor,
# like Python's), which is exactly what Hinnant's algorithm wants — the
# reference C++ implementation's `y >= 0 ? y : y-399` sign special-case
# exists only to fake floor division out of C++'s truncating `/`, so it is
# dropped here.
# ===----------------------------------------------------------------------===#

comptime _MICROS_PER_DAY: Int64 = 86_400_000_000
comptime _MICROS_PER_SECOND: Int64 = 1_000_000


def _days_from_civil(y: Int64, m: Int64, d: Int64) -> Int64:
    var yy = y
    if m <= 2:
        yy -= 1
    var era = yy // 400
    var yoe = yy - era * 400  # [0, 399]
    var doy: Int64
    if m > 2:
        doy = (153 * (m - 3) + 2) // 5 + d - 1
    else:
        doy = (153 * (m + 9) + 2) // 5 + d - 1
    var doe = yoe * 365 + yoe // 4 - yoe // 100 + doy  # [0, 146096]
    return era * 146097 + doe - 719468


def _civil_from_days(days: Int64) -> Tuple[Int64, Int64, Int64]:
    var z = days + 719468
    var era = z // 146097
    var doe = z - era * 146097  # [0, 146096]
    var yoe = (
        doe - doe // 1460 + doe // 36524 - doe // 146096
    ) // 365  # [0, 399]
    var y = yoe + era * 400
    var doy = doe - (365 * yoe + yoe // 4 - yoe // 100)  # [0, 365]
    var mp = (5 * doy + 2) // 153  # [0, 11]
    var d = doy - (153 * mp + 2) // 5 + 1  # [1, 31]
    var m: Int64
    if mp < 10:
        m = mp + 3
    else:
        m = mp - 9
    if m <= 2:
        y += 1
    return (y, m, d)


def is_infinite(s: StringSlice) -> Bool:
    """True for the literal spellings PostgreSQL uses for the unbounded
    date/timestamp values, `infinity` and `-infinity`."""
    return s == "infinity" or s == "-infinity"


def _check_not_bc(s: StringSlice) raises:
    if s.endswith(" BC"):
        raise Error(
            String(
                (
                    "postgres.text: BC dates are not supported by the epoch"
                    " encoding; read the raw text instead: '"
                ),
                s,
                "'",
            )
        )


def _format_date(y: Int64, m: Int64, d: Int64) -> String:
    var year_str: String
    if y >= 1:
        year_str = _zero_pad(y, 4)
    else:
        # Astronomical year <= 0 is 1 BC or earlier; PostgreSQL's own BC
        # convention: year_of_era = 1 - y, suffixed " BC".
        year_str = String(_zero_pad(1 - y, 4), " BC")
    return String(year_str, "-", _zero_pad(m, 2), "-", _zero_pad(d, 2))


def _parse_date_prefix(
    s: StringSlice, start: Int
) raises -> Tuple[Int64, Int64, Int64, Int]:
    """Parse `YYYY-MM-DD` beginning at byte offset `start`. Returns
    `(year, month, day, end)` where `end` is the byte offset just past the
    day digits."""
    var invalid_msg = String("postgres.text: invalid date text: '", s, "'")
    var n = s.byte_length()
    var data = s.as_bytes()

    var year_start = start
    var i = start
    while i < n and _is_digit(data[i]):
        i += 1
    if i == year_start or i >= n or data[i] != UInt8(ord("-")):
        raise Error(invalid_msg)
    var year = _parse_unsigned_digits(s, year_start, i)
    i += 1

    var month_start = i
    while i < n and _is_digit(data[i]):
        i += 1
    if i == month_start or i >= n or data[i] != UInt8(ord("-")):
        raise Error(invalid_msg)
    var month = _parse_unsigned_digits(s, month_start, i)
    i += 1

    var day_start = i
    while i < n and _is_digit(data[i]):
        i += 1
    if i == day_start:
        raise Error(invalid_msg)
    var day = _parse_unsigned_digits(s, day_start, i)

    if month < 1 or month > 12:
        raise Error(invalid_msg)
    if day < 1 or day > 31:
        raise Error(invalid_msg)

    return (year, month, day, i)


def _parse_time_prefix(s: StringSlice, start: Int) raises -> Tuple[Int64, Int]:
    """Parse `HH:MM:SS[.ffffff]` beginning at byte offset `start`. Returns
    `(micros_since_midnight, end)`."""
    var invalid_msg = String("postgres.text: invalid time text: '", s, "'")
    var n = s.byte_length()
    var data = s.as_bytes()

    var hh_start = start
    var i = start
    while i < n and _is_digit(data[i]):
        i += 1
    if i == hh_start or i >= n or data[i] != UInt8(ord(":")):
        raise Error(invalid_msg)
    var hh = _parse_unsigned_digits(s, hh_start, i)
    i += 1

    var mm_start = i
    while i < n and _is_digit(data[i]):
        i += 1
    if i == mm_start or i >= n or data[i] != UInt8(ord(":")):
        raise Error(invalid_msg)
    var mm = _parse_unsigned_digits(s, mm_start, i)
    i += 1

    var ss_start = i
    while i < n and _is_digit(data[i]):
        i += 1
    if i == ss_start:
        raise Error(invalid_msg)
    var ss = _parse_unsigned_digits(s, ss_start, i)

    var micros: Int64 = 0
    if i < n and data[i] == UInt8(ord(".")):
        i += 1
        var frac_start = i
        while i < n and _is_digit(data[i]):
            i += 1
        var frac_len = i - frac_start
        if frac_len == 0 or frac_len > 6:
            raise Error(invalid_msg)
        var frac_val = _parse_unsigned_digits(s, frac_start, i)
        var scale: Int64 = 1
        var pad = 6 - frac_len
        var k = 0
        while k < pad:
            scale *= 10
            k += 1
        micros = frac_val * scale

    if hh < 0 or hh > 23 or mm < 0 or mm > 59 or ss < 0 or ss > 59:
        raise Error(invalid_msg)

    var total = (
        hh * 3600 * _MICROS_PER_SECOND
        + mm * 60 * _MICROS_PER_SECOND
        + ss * _MICROS_PER_SECOND
        + micros
    )
    return (total, i)


def decode_date(s: StringSlice) raises -> Int32:
    """Decode `date` text (`YYYY-MM-DD`, year may exceed 4 digits) to days
    since 1970-01-01. `infinity`/`-infinity` and a ` BC` suffix raise —
    read `Result.value()`'s raw text for those instead of the epoch
    encoding."""
    if is_infinite(s):
        raise Error(
            String(
                "postgres.text: date '",
                s,
                "' is infinite; read the raw text instead",
            )
        )
    _check_not_bc(s)
    var parsed = _parse_date_prefix(s, 0)
    var end = parsed[3]
    if end != s.byte_length():
        raise Error(String("postgres.text: invalid date text: '", s, "'"))
    var days = _days_from_civil(parsed[0], parsed[1], parsed[2])
    if days < Int64(Int32.MIN) or days > Int64(Int32.MAX):
        raise Error(String("postgres.text: date out of range: '", s, "'"))
    return Int32(days)


def decode_time(s: StringSlice) raises -> Int64:
    """Decode `time` text (`HH:MM:SS[.ffffff]`) to microseconds since
    midnight."""
    var parsed = _parse_time_prefix(s, 0)
    if parsed[1] != s.byte_length():
        raise Error(String("postgres.text: invalid time text: '", s, "'"))
    return parsed[0]


def decode_timestamp(s: StringSlice) raises -> Int64:
    """Decode naive `timestamp` text (`YYYY-MM-DD HH:MM:SS[.ffffff]`, no
    zone) to microseconds since 1970-01-01 00:00:00."""
    if is_infinite(s):
        raise Error(
            String(
                "postgres.text: timestamp '",
                s,
                "' is infinite; read the raw text instead",
            )
        )
    _check_not_bc(s)
    var n = s.byte_length()
    var invalid_msg = String("postgres.text: invalid timestamp text: '", s, "'")
    var date_part = _parse_date_prefix(s, 0)
    var pos = date_part[3]
    if pos >= n or s.as_bytes()[pos] != UInt8(ord(" ")):
        raise Error(invalid_msg)
    pos += 1
    var time_part = _parse_time_prefix(s, pos)
    if time_part[1] != n:
        raise Error(invalid_msg)
    var days = _days_from_civil(date_part[0], date_part[1], date_part[2])
    return days * _MICROS_PER_DAY + time_part[0]


def decode_timestamptz(s: StringSlice) raises -> Int64:
    """Decode zoned `timestamptz` text (`YYYY-MM-DD HH:MM:SS[.ffffff]` plus
    an offset `+HH`, `+HH:MM`, or `+HH:MM:SS`, either sign) to UTC
    microseconds since 1970-01-01 00:00:00."""
    if is_infinite(s):
        raise Error(
            String(
                "postgres.text: timestamptz '",
                s,
                "' is infinite; read the raw text instead",
            )
        )
    _check_not_bc(s)
    var n = s.byte_length()
    var data = s.as_bytes()
    var invalid_msg = String(
        "postgres.text: invalid timestamptz text: '", s, "'"
    )

    var date_part = _parse_date_prefix(s, 0)
    var pos = date_part[3]
    if pos >= n or data[pos] != UInt8(ord(" ")):
        raise Error(invalid_msg)
    pos += 1
    var time_part = _parse_time_prefix(s, pos)
    pos = time_part[1]

    if pos >= n:
        raise Error(invalid_msg)
    var offset_sign: Int64
    if data[pos] == UInt8(ord("+")):
        offset_sign = 1
    elif data[pos] == UInt8(ord("-")):
        offset_sign = -1
    else:
        raise Error(invalid_msg)
    pos += 1

    var oh_start = pos
    while pos < n and _is_digit(data[pos]):
        pos += 1
    if pos == oh_start:
        raise Error(invalid_msg)
    var offset_hours = _parse_unsigned_digits(s, oh_start, pos)

    var offset_minutes: Int64 = 0
    var offset_seconds: Int64 = 0
    if pos < n and data[pos] == UInt8(ord(":")):
        pos += 1
        var om_start = pos
        while pos < n and _is_digit(data[pos]):
            pos += 1
        if pos == om_start:
            raise Error(invalid_msg)
        offset_minutes = _parse_unsigned_digits(s, om_start, pos)

        if pos < n and data[pos] == UInt8(ord(":")):
            pos += 1
            var os_start = pos
            while pos < n and _is_digit(data[pos]):
                pos += 1
            if pos == os_start:
                raise Error(invalid_msg)
            offset_seconds = _parse_unsigned_digits(s, os_start, pos)

    if pos != n:
        raise Error(invalid_msg)

    var offset_micros = (
        offset_sign
        * (offset_hours * 3600 + offset_minutes * 60 + offset_seconds)
        * _MICROS_PER_SECOND
    )
    var days = _days_from_civil(date_part[0], date_part[1], date_part[2])
    var local_micros = days * _MICROS_PER_DAY + time_part[0]
    return local_micros - offset_micros


def encode_date(days: Int32) -> String:
    var ymd = _civil_from_days(Int64(days))
    return _format_date(ymd[0], ymd[1], ymd[2])


def encode_time(micros: Int64) -> String:
    var total_seconds = micros // _MICROS_PER_SECOND
    var frac = micros % _MICROS_PER_SECOND
    var hh = total_seconds // 3600
    var mm = (total_seconds % 3600) // 60
    var ss = total_seconds % 60
    return String(
        _zero_pad(hh, 2),
        ":",
        _zero_pad(mm, 2),
        ":",
        _zero_pad(ss, 2),
        ".",
        _zero_pad(frac, 6),
    )


def encode_timestamp(micros: Int64) -> String:
    """Always 6 fractional digits: `YYYY-MM-DD HH:MM:SS.ffffff`. Negative
    `micros` (dates before 1970) work because `//`/`%` are floor
    division/modulo."""
    var days = micros // _MICROS_PER_DAY
    var micros_of_day = micros % _MICROS_PER_DAY
    var ymd = _civil_from_days(days)
    return String(
        _format_date(ymd[0], ymd[1], ymd[2]), " ", encode_time(micros_of_day)
    )


def encode_timestamptz(micros: Int64) -> String:
    """Same as `encode_timestamp`, with a `+00` suffix — `micros` is already
    UTC, so there is no original offset to restore."""
    return String(encode_timestamp(micros), "+00")


# ===----------------------------------------------------------------------===#
# text / varchar / bpchar / uuid / json / jsonb / numeric — identity
# ===----------------------------------------------------------------------===#


def decode_text(s: StringSlice) -> String:
    """Identity decode, so a dispatch-by-OID table can call every decoder
    uniformly."""
    return String(s)
