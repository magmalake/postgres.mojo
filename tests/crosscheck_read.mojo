"""The other half of `tests/crosscheck.sh`: read a table psycopg wrote, with
this tin, and check every value.

`tests/crosscheck.py` created `xc_py` and inserted the five fixture rows
(normal, all-NULL, zero/empty/epoch, "edge_min", "edge_max" -- see that
file's docstring for the full rationale) with native Python types. This
binary reads them back through `Row`'s typed accessors and asserts each one
against a hard-coded Mojo literal -- the same fixture, transcribed by hand
and kept in sync with `tests/crosscheck_write.mojo` and `tests/crosscheck.py`.

It then does a second, independent check: `tests/crosscheck.sh` also dumps
`xc_py` with `psql ... COPY ... TO STDOUT` to a file, whose path arrives here
as `$POSTGRES_XC_PSQL_FILE`. Every cell this binary read through `Row.text`
is compared, line by line and column by column, against `copyfmt.decode_row`
applied to psql's dump -- proving `PQgetvalue`'s text and what `psql`'s own
libpq prints agree byte for byte, for all nineteen columns, not just the
`numeric` one the spec calls out by name.
"""

from std.os import getenv
from std.testing import assert_equal, assert_false, assert_true
from std.utils.numerics import isinf, isnan

from postgres import COPY_TEXT, Connection, Row, decode_row, split_rows

# ===----------------------------------------------------------------------===#
# Fixture constants -- kept in sync by hand with tests/crosscheck_write.mojo
# and tests/crosscheck.py.
# ===----------------------------------------------------------------------===#

comptime DAYS_2024_02_29: Int32 = 19782
comptime DAYS_0001_01_01: Int32 = -719162
comptime DAYS_9999_12_31: Int32 = 2932896

comptime TIME_NORMAL_MICROS: Int64 = 47_655_123_456
comptime TIME_MIN_MICROS: Int64 = 1
comptime TIME_MAX_MICROS: Int64 = 86_399_999_999

comptime TS_NORMAL_MICROS: Int64 = 1_709_212_455_123_456
comptime TS_MIN_MICROS: Int64 = -62_135_596_799_999_999
comptime TS_MAX_MICROS: Int64 = 253_402_300_799_999_999

comptime TSTZ_NORMAL_MICROS: Int64 = 1_709_212_455_123_456
comptime TSTZ_MIN_MICROS: Int64 = -62_121_317_400_000_000
comptime TSTZ_MAX_MICROS: Int64 = 253_402_297_199_999_999  # see crosscheck_write.mojo

comptime SELECT_SQL: StaticString = (
    "SELECT id,b,i2,i4,i8,f4,f8,num,t,vc,bp,by,d,tm,ts,tstz,u,j,jb FROM"
    " xc_py ORDER BY id"
)
comptime NUM_COLS = 19


def _dsn() raises -> String:
    var dsn = getenv("POSTGRES_TEST_DSN", "")
    if not dsn:
        raise Error(
            "$POSTGRES_TEST_DSN is not set -- run via `pixi run server` or"
            " `tests/crosscheck.sh`"
        )
    return dsn


def _assert_bytea(
    label: String, var actual: List[UInt8], var expected: List[UInt8]
) raises:
    assert_equal(len(actual), len(expected), label + ": length")
    for i in range(len(expected)):
        assert_equal(actual[i], expected[i], label + ": byte " + String(i))


# ===----------------------------------------------------------------------===#
# Typed-accessor assertions, one function per fixture row
# ===----------------------------------------------------------------------===#


def _assert_normal(row: Row) raises:
    assert_equal(row.int64("id"), Int64(1))
    assert_true(row.bool("b"))
    assert_equal(row.int16("i2"), Int16(42))
    assert_equal(row.int32("i4"), Int32(123456))
    assert_equal(row.int64("i8"), Int64(9_000_000_000_000))
    assert_equal(row.float32("f4"), Float32(1.5))
    assert_equal(row.float64("f8"), Float64(2.25))
    assert_equal(row.numeric("num"), "12345.678900")
    assert_equal(row.text("t"), "Ada Lovelace")
    assert_equal(row.text("vc"), "shortval")
    assert_equal(row.text("bp"), "yo ")  # bpchar(3) pads "yo" with one space
    _assert_bytea("row 1 by", row.bytea("by"), [0xDE, 0xAD, 0xBE, 0xEF])
    assert_equal(row.date_days("d"), DAYS_2024_02_29)
    assert_equal(row.time_micros("tm"), TIME_NORMAL_MICROS)
    assert_equal(row.timestamp_micros("ts"), TS_NORMAL_MICROS)
    assert_equal(row.timestamptz_micros("tstz"), TSTZ_NORMAL_MICROS)
    assert_equal(row.uuid("u"), "6ba7b810-9dad-11d1-80b4-00c04fd430c8")
    assert_equal(row.json("j"), '{"a": 1}')
    assert_equal(row.json("jb"), '{"a": 1}')  # jsonb normalizes the input


def _assert_nulls(row: Row) raises:
    assert_equal(row.int64("id"), Int64(2))
    var cols: List[String] = [
        "b",
        "i2",
        "i4",
        "i8",
        "f4",
        "f8",
        "num",
        "t",
        "vc",
        "bp",
        "by",
        "d",
        "tm",
        "ts",
        "tstz",
        "u",
        "j",
        "jb",
    ]
    for col in cols:
        assert_true(row.is_null(col), "row 2 column '" + col + "' is not NULL")


def _assert_zero(row: Row) raises:
    assert_equal(row.int64("id"), Int64(3))
    assert_false(row.bool("b"))
    assert_equal(row.int16("i2"), Int16(0))
    assert_equal(row.int32("i4"), Int32(0))
    assert_equal(row.int64("i8"), Int64(0))
    assert_equal(row.float32("f4"), Float32(0.0))
    assert_equal(row.float64("f8"), Float64(0.0))
    assert_equal(row.numeric("num"), "0.000000")
    assert_equal(row.text("t"), "")
    assert_equal(row.text("vc"), "")
    assert_equal(row.text("bp"), "   ")  # bpchar(3) of "" is three spaces
    assert_false(row.is_null("bp"), "the empty string became NULL")
    _assert_bytea("row 3 by", row.bytea("by"), List[UInt8]())
    assert_equal(row.date_days("d"), Int32(0))
    assert_equal(row.time_micros("tm"), Int64(0))
    assert_equal(row.timestamp_micros("ts"), Int64(0))
    assert_equal(row.timestamptz_micros("tstz"), Int64(0))
    assert_equal(row.uuid("u"), "00000000-0000-0000-0000-000000000000")
    assert_equal(row.json("j"), "{}")
    assert_equal(row.json("jb"), "{}")


def _assert_edge_min(row: Row) raises:
    assert_equal(row.int64("id"), Int64(4))
    assert_true(row.bool("b"))
    assert_equal(row.int16("i2"), Int16(-32768))
    assert_equal(row.int32("i4"), Int32(-2147483648))
    assert_equal(row.int64("i8"), Int64(-9223372036854775808))
    assert_true(isnan(row.float32("f4")), "f4 was not NaN")
    assert_true(isinf(row.float64("f8")), "f8 was not infinite")
    assert_true(row.float64("f8") < 0, "f8 was not -Infinity")
    assert_equal(row.numeric("num"), "-123.400000")
    assert_equal(row.text("t"), 'a\tb\nc"d\\e\\Nf日本語')
    assert_equal(row.text("vc"), "0123456789")
    assert_equal(row.text("bp"), "é中 ")  # bpchar(3) pads "é中" (2 chars)
    _assert_bytea("row 4 by", row.bytea("by"), [0x00, 0xFF, 0x00, 0xFF, 0x7F])
    assert_equal(row.date_days("d"), DAYS_0001_01_01)
    assert_equal(row.time_micros("tm"), TIME_MIN_MICROS)
    assert_equal(row.timestamp_micros("ts"), TS_MIN_MICROS)
    assert_equal(row.timestamptz_micros("tstz"), TSTZ_MIN_MICROS)
    assert_equal(row.uuid("u"), "ffffffff-ffff-ffff-ffff-ffffffffffff")
    assert_equal(row.json("j"), '{"k": "v"}')
    assert_equal(row.json("jb"), '{"k": "v"}')


def _assert_edge_max(row: Row) raises:
    assert_equal(row.int64("id"), Int64(5))
    assert_false(row.bool("b"))
    assert_equal(row.int16("i2"), Int16(32767))
    assert_equal(row.int32("i4"), Int32(2147483647))
    assert_equal(row.int64("i8"), Int64(9223372036854775807))
    assert_true(isinf(row.float32("f4")), "f4 was not infinite")
    assert_true(row.float32("f4") > 0, "f4 was not +Infinity")
    assert_true(isinf(row.float64("f8")), "f8 was not infinite")
    assert_true(row.float64("f8") > 0, "f8 was not +Infinity")
    assert_equal(row.numeric("num"), "99999999999999.990000")
    assert_equal(row.text("t"), 'Row 5: quoted "text", back\\slash, tab\tend')
    assert_equal(row.text("vc"), "row5-vc")
    assert_equal(row.text("bp"), "z  ")  # bpchar(3) pads "z" with two spaces
    _assert_bytea("row 5 by", row.bytea("by"), [0xFF, 0x00, 0xFF, 0x00])
    assert_equal(row.date_days("d"), DAYS_9999_12_31)
    assert_equal(row.time_micros("tm"), TIME_MAX_MICROS)
    assert_equal(row.timestamp_micros("ts"), TS_MAX_MICROS)
    assert_equal(row.timestamptz_micros("tstz"), TSTZ_MAX_MICROS)
    assert_equal(row.uuid("u"), "00112233-4455-6677-8899-aabbccddeeff")
    assert_equal(row.json("j"), '{"n": 5}')
    assert_equal(row.json("jb"), '{"n": 5}')


# ===----------------------------------------------------------------------===#
# psql parity: line-by-line, column-by-column against `psql ... COPY ...
# TO STDOUT` of the same table.
# ===----------------------------------------------------------------------===#


def _check_psql_parity(mut conn: Connection, path: String) raises:
    var f = open(path, "r")
    var content = f.read()
    f.close()

    var split = split_rows(Span(content.as_bytes()))
    var lines = split[0].copy()
    assert_equal(len(lines), 5, "psql COPY dump had the wrong row count")

    var res = conn.query(SELECT_SQL)
    for i in range(5):
        var row = res.row(i)
        var fields = decode_row(lines[i], COPY_TEXT, "\t", "\\N")
        assert_equal(
            len(fields), NUM_COLS, "psql COPY dump had the wrong column count"
        )
        for col in range(NUM_COLS):
            var loc = "row " + String(i) + " column " + String(col)
            if row.is_null(col):
                assert_false(
                    Bool(fields[col]),
                    loc + ": psql printed a value where Mojo read NULL",
                )
            else:
                assert_true(
                    Bool(fields[col]),
                    loc + ": psql printed NULL where Mojo read a value",
                )
                assert_equal(
                    fields[col].value(),
                    row.text(col),
                    loc + ": psql and Row.text() disagree",
                )
    print(
        "xc_py vs psql COPY dump: byte-identical across all 5 rows x",
        NUM_COLS,
        "columns",
    )


def main() raises:
    var dsn = _dsn()
    var conn = Connection(dsn)
    _ = conn.execute("SET TimeZone='UTC'")

    var res = conn.query(SELECT_SQL)
    if res.num_rows() != 5:
        raise Error(
            "crosscheck_read: expected 5 rows in xc_py, got "
            + String(res.num_rows())
        )

    _assert_normal(res.row(0))
    _assert_nulls(res.row(1))
    _assert_zero(res.row(2))
    _assert_edge_min(res.row(3))
    _assert_edge_max(res.row(4))
    print(
        "xc_py: typed accessors match the fixture (5 rows x",
        NUM_COLS,
        "columns)",
    )

    var psql_path = getenv("POSTGRES_XC_PSQL_FILE", "")
    if psql_path:
        _check_psql_parity(conn, psql_path)
    else:
        print(
            "crosscheck_read: $POSTGRES_XC_PSQL_FILE not set; skipping psql"
            " parity check"
        )
