"""Half of the psql/psycopg cross-check: write the §5 type-table fixture with
this tin, for `tests/crosscheck.py` to read back cell for cell.

Driven by `tests/crosscheck.sh`. Writes two tables against `$POSTGRES_TEST_DSN`
-- real tables, not `TEMP`, because three separate processes (this binary,
`crosscheck.py`, `tests/crosscheck_read.mojo`) each open their own connection
to the same running server and have to see what the others wrote:

- `xc_mojo` -- the five fixture rows via `Params`' *typed* builders
  (`date_days`, `timestamp_micros`, `bytea`, ...), not text casts. Proves the
  encode half of `postgres.text` by having an independent client (psycopg)
  read the result and agree.
- `xc_mojo_copy` -- the same five rows loaded through `CopyIn` +
  `copyfmt.CopyEncoder` in text format. Proves the COPY encoder produces the
  same values `PQexecParams` does, and that psycopg agrees with both.

The five rows -- normal, all-NULL, zero/empty/epoch, and two edge rows -- are
the same fixture `tests/crosscheck.py` and `tests/crosscheck_read.mojo` use,
so all three files' constants must be kept in sync by hand; see each file's
docstring for the row-by-row values. `tests/crosscheck.py` has the full
rationale for the split between "edge_min" and "edge_max": a single date
column cannot hold both 0001-01-01 and 9999-12-31 at once, so the spec's "int
min/max ... dates 0001-01-01 and 9999-12-31" edge row became two.
"""

from std.os import getenv

from postgres import Connection, CopyEncoder, Params
from postgres.text import (
    decode_float32,
    decode_float64,
    encode_bool,
    encode_bytea,
    encode_date,
    encode_float32,
    encode_float64,
    encode_int64,
    encode_time,
    encode_timestamp,
    encode_timestamptz,
)

# ===----------------------------------------------------------------------===#
# Fixture constants -- see the module docstring; kept in sync by hand with
# tests/crosscheck.py and tests/crosscheck_read.mojo.
# ===----------------------------------------------------------------------===#

comptime DAYS_2024_02_29: Int32 = 19782
comptime DAYS_0001_01_01: Int32 = -719162
comptime DAYS_9999_12_31: Int32 = 2932896

comptime TIME_NORMAL_MICROS: Int64 = 47_655_123_456  # 13:14:15.123456
comptime TIME_MIN_MICROS: Int64 = 1  # 00:00:00.000001
comptime TIME_MAX_MICROS: Int64 = 86_399_999_999  # 23:59:59.999999

comptime TS_NORMAL_MICROS: Int64 = 1_709_212_455_123_456
comptime TS_MIN_MICROS: Int64 = -62_135_596_799_999_999
comptime TS_MAX_MICROS: Int64 = 253_402_300_799_999_999

comptime TSTZ_NORMAL_MICROS: Int64 = 1_709_212_455_123_456  # offset +00
comptime TSTZ_MIN_MICROS: Int64 = -62_121_317_400_000_000  # 0001-06-15+05:30
comptime TSTZ_MAX_MICROS: Int64 = 253_402_297_199_999_999  # 9999-12-31+01:00
# TSTZ_MAX uses +01:00, not a more extreme offset: psycopg's C extension
# rejects any timestamptz whose UTC-normalized value would fall in year
# 10000 ("timestamp too large (after year 10K)"), which a negative offset on
# this already-end-of-9999 local time would do. +01:00 keeps the instant
# inside year 9999 while still exercising a non-UTC offset in the literal.

comptime SCHEMA: StaticString = (
    "(id bigint primary key, b bool, i2 int2, i4 int4, i8 int8, f4 float4,"
    " f8 float8, num numeric(20,6), t text, vc varchar(10), bp bpchar(3),"
    " by bytea, d date, tm time, ts timestamp, tstz timestamptz, u uuid,"
    " j json, jb jsonb)"
)

comptime INSERT_SQL: StaticString = (
    "INSERT INTO xc_mojo VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,"
    "$14,$15,$16,$17,$18,$19)"
)


def _dsn() raises -> String:
    var dsn = getenv("POSTGRES_TEST_DSN", "")
    if not dsn:
        raise Error(
            "$POSTGRES_TEST_DSN is not set -- run via `pixi run server` or"
            " `tests/crosscheck.sh`"
        )
    return dsn


# ===----------------------------------------------------------------------===#
# Direction A, table 1: typed `Params`
# ===----------------------------------------------------------------------===#


def _write_via_params(mut conn: Connection) raises -> Int:
    var f4_nan = decode_float32("NaN")
    var f4_inf = decode_float32("Infinity")
    var f8_neg_inf = decode_float64("-Infinity")
    var f8_inf = decode_float64("Infinity")

    var total = 0

    # id=1 "normal"
    var blob1: List[UInt8] = [0xDE, 0xAD, 0xBE, 0xEF]
    total += conn.execute(
        INSERT_SQL,
        Params()
        .int64(1)
        .bool(True)
        .int16(42)
        .int32(123456)
        .int64(9_000_000_000_000)
        .float32(1.5)
        .float64(2.25)
        .numeric("12345.678900")
        .text("Ada Lovelace")
        .text("shortval")
        .text("yo")
        .bytea(Span(blob1))
        .date_days(DAYS_2024_02_29)
        .time_micros(TIME_NORMAL_MICROS)
        .timestamp_micros(TS_NORMAL_MICROS)
        .timestamptz_micros(TSTZ_NORMAL_MICROS)
        .uuid("6ba7b810-9dad-11d1-80b4-00c04fd430c8")
        .json('{"a": 1}')
        .jsonb('{"a":1}'),
    )

    # id=2 "nulls" -- every column but `id` is NULL.
    var nulls = Params().int64(2)
    for _ in range(18):
        nulls = nulls^.null()
    total += conn.execute(INSERT_SQL, nulls)

    # id=3 "zero/empty/epoch"
    var blob3: List[UInt8] = []
    total += conn.execute(
        INSERT_SQL,
        Params()
        .int64(3)
        .bool(False)
        .int16(0)
        .int32(0)
        .int64(0)
        .float32(0.0)
        .float64(0.0)
        .numeric("0")
        .text("")
        .text("")
        .text("")
        .bytea(Span(blob3))
        .date_days(0)
        .time_micros(0)
        .timestamp_micros(0)
        .timestamptz_micros(0)
        .uuid("00000000-0000-0000-0000-000000000000")
        .json("{}")
        .jsonb("{}"),
    )

    # id=4 "edge_min" -- int mins, NaN/-Infinity, 0001-01-01, a non-UTC
    # offset, and the tab/newline/quote/backslash/\N/non-ASCII text combo.
    var blob4: List[UInt8] = [0x00, 0xFF, 0x00, 0xFF, 0x7F]
    total += conn.execute(
        INSERT_SQL,
        Params()
        .int64(4)
        .bool(True)
        .int16(-32768)
        .int32(-2147483648)
        .int64(-9223372036854775808)
        .float32(f4_nan)
        .float64(f8_neg_inf)
        .numeric("-123.4")
        .text('a\tb\nc"d\\e\\Nf日本語')
        .text("0123456789")
        .text("é中")
        .bytea(Span(blob4))
        .date_days(DAYS_0001_01_01)
        .time_micros(TIME_MIN_MICROS)
        .timestamp_micros(TS_MIN_MICROS)
        .timestamptz_micros(TSTZ_MIN_MICROS)
        .uuid("ffffffff-ffff-ffff-ffff-ffffffffffff")
        .json('{"k": "v"}')
        .jsonb('{"k":"v"}'),
    )

    # id=5 "edge_max" -- int maxes, Infinity, 9999-12-31, another non-UTC
    # offset, and max-precision numeric.
    var blob5: List[UInt8] = [0xFF, 0x00, 0xFF, 0x00]
    total += conn.execute(
        INSERT_SQL,
        Params()
        .int64(5)
        .bool(False)
        .int16(32767)
        .int32(2147483647)
        .int64(9223372036854775807)
        .float32(f4_inf)
        .float64(f8_inf)
        .numeric("99999999999999.99")
        .text('Row 5: quoted "text", back\\slash, tab\tend')
        .text("row5-vc")
        .text("z")
        .bytea(Span(blob5))
        .date_days(DAYS_9999_12_31)
        .time_micros(TIME_MAX_MICROS)
        .timestamp_micros(TS_MAX_MICROS)
        .timestamptz_micros(TSTZ_MAX_MICROS)
        .uuid("00112233-4455-6677-8899-aabbccddeeff")
        .json('{"n": 5}')
        .jsonb('{"n":5}'),
    )

    return total


# ===----------------------------------------------------------------------===#
# Direction A, table 2: the same rows through CopyIn + CopyEncoder
# ===----------------------------------------------------------------------===#


def _write_via_copy(mut conn: Connection) raises -> Int:
    var f4_nan = decode_float32("NaN")
    var f4_inf = decode_float32("Infinity")
    var f8_neg_inf = decode_float64("-Infinity")
    var f8_inf = decode_float64("Infinity")

    var enc = CopyEncoder()

    # id=1 "normal"
    var blob1: List[UInt8] = [0xDE, 0xAD, 0xBE, 0xEF]
    enc.field(encode_int64(1))
    enc.field(encode_bool(True))
    enc.field("42")
    enc.field("123456")
    enc.field("9000000000000")
    enc.field(encode_float32(1.5))
    enc.field(encode_float64(2.25))
    enc.field("12345.678900")
    enc.field("Ada Lovelace")
    enc.field("shortval")
    enc.field("yo")
    enc.field(encode_bytea(Span(blob1)))
    enc.field(encode_date(DAYS_2024_02_29))
    enc.field(encode_time(TIME_NORMAL_MICROS))
    enc.field(encode_timestamp(TS_NORMAL_MICROS))
    enc.field(encode_timestamptz(TSTZ_NORMAL_MICROS))
    enc.field("6ba7b810-9dad-11d1-80b4-00c04fd430c8")
    enc.field('{"a": 1}')
    enc.field('{"a":1}')
    enc.end_row()

    # id=2 "nulls"
    enc.field(encode_int64(2))
    for _ in range(18):
        enc.null()
    enc.end_row()

    # id=3 "zero/empty/epoch"
    var blob3: List[UInt8] = []
    enc.field(encode_int64(3))
    enc.field(encode_bool(False))
    enc.field("0")
    enc.field("0")
    enc.field("0")
    enc.field(encode_float32(0.0))
    enc.field(encode_float64(0.0))
    enc.field("0")
    enc.field("")
    enc.field("")
    enc.field("")
    enc.field(encode_bytea(Span(blob3)))
    enc.field(encode_date(0))
    enc.field(encode_time(0))
    enc.field(encode_timestamp(0))
    enc.field(encode_timestamptz(0))
    enc.field("00000000-0000-0000-0000-000000000000")
    enc.field("{}")
    enc.field("{}")
    enc.end_row()

    # id=4 "edge_min"
    var blob4: List[UInt8] = [0x00, 0xFF, 0x00, 0xFF, 0x7F]
    enc.field(encode_int64(4))
    enc.field(encode_bool(True))
    enc.field("-32768")
    enc.field("-2147483648")
    enc.field("-9223372036854775808")
    enc.field(encode_float32(f4_nan))
    enc.field(encode_float64(f8_neg_inf))
    enc.field("-123.400000")
    enc.field('a\tb\nc"d\\e\\Nf日本語')
    enc.field("0123456789")
    enc.field("é中")
    enc.field(encode_bytea(Span(blob4)))
    enc.field(encode_date(DAYS_0001_01_01))
    enc.field(encode_time(TIME_MIN_MICROS))
    enc.field(encode_timestamp(TS_MIN_MICROS))
    enc.field(encode_timestamptz(TSTZ_MIN_MICROS))
    enc.field("ffffffff-ffff-ffff-ffff-ffffffffffff")
    enc.field('{"k": "v"}')
    enc.field('{"k":"v"}')
    enc.end_row()

    # id=5 "edge_max"
    var blob5: List[UInt8] = [0xFF, 0x00, 0xFF, 0x00]
    enc.field(encode_int64(5))
    enc.field(encode_bool(False))
    enc.field("32767")
    enc.field("2147483647")
    enc.field("9223372036854775807")
    enc.field(encode_float32(f4_inf))
    enc.field(encode_float64(f8_inf))
    enc.field("99999999999999.990000")
    enc.field('Row 5: quoted "text", back\\slash, tab\tend')
    enc.field("row5-vc")
    enc.field("z")
    enc.field(encode_bytea(Span(blob5)))
    enc.field(encode_date(DAYS_9999_12_31))
    enc.field(encode_time(TIME_MAX_MICROS))
    enc.field(encode_timestamp(TS_MAX_MICROS))
    enc.field(encode_timestamptz(TSTZ_MAX_MICROS))
    enc.field("00112233-4455-6677-8899-aabbccddeeff")
    enc.field('{"n": 5}')
    enc.field('{"n":5}')
    enc.end_row()

    var cp = conn.copy_in("COPY xc_mojo_copy FROM STDIN")
    cp.write_rows(enc)
    return cp.finish()


def main() raises:
    var dsn = _dsn()
    var conn = Connection(dsn)

    _ = conn.execute("DROP TABLE IF EXISTS xc_mojo")
    _ = conn.execute("CREATE TABLE xc_mojo " + SCHEMA)
    var n_params = _write_via_params(conn)
    print("xc_mojo:", n_params, "rows via Params")

    _ = conn.execute("DROP TABLE IF EXISTS xc_mojo_copy")
    _ = conn.execute("CREATE TABLE xc_mojo_copy " + SCHEMA)
    var n_copy = _write_via_copy(conn)
    print("xc_mojo_copy:", n_copy, "rows via CopyIn")

    if n_params != 5 or n_copy != 5:
        raise Error("crosscheck_write: expected 5 rows in each table")
