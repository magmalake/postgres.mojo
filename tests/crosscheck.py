#!/usr/bin/env python3
"""The psql/psycopg half of the cross-check driven by `tests/crosscheck.sh`.

Two jobs, both against the same fixture (five rows: normal, all-NULL,
zero/empty/epoch, and two edge rows -- "edge_min"/"edge_max", because a
single `date` column cannot hold both 0001-01-01 and 9999-12-31 the spec
asks for at once, so that one edge row became two):

1. **Direction A -- Mojo writes, psycopg reads.** `tests/crosscheck_write.mojo`
   has already populated `xc_mojo` (via `Params`, the typed builders) and
   `xc_mojo_copy` (via `CopyIn` + `copyfmt.CopyEncoder`). This script reads
   both back with psycopg 3 and asserts every cell against the same Python
   values computed here -- `datetime.date(...)`, `Decimal(...)` compared as
   *strings* (so a scale mismatch cannot hide behind float rounding),
   `math.isnan`/`math.isinf`, raw `bytes`. `SET TimeZone='UTC'` runs first,
   so `timestamptz` text -- and the tz-aware `datetime` psycopg builds from
   it -- is deterministic regardless of the server's default zone.

2. **Direction B setup -- psycopg writes, Mojo reads.** This script also
   creates `xc_py` and inserts the same fixture through psycopg with native
   Python types (`bool`, `int`, `Decimal`, `bytes`, `date`/`time`/`datetime`,
   a `uuid` string, raw JSON text). `tests/crosscheck_read.mojo` reads it
   back through `Row`'s typed accessors and does the asserting for that half;
   `tests/crosscheck.sh` also dumps `xc_py` with `psql ... COPY ... TO
   STDOUT` for a third, independent read.

Every table is a real table, not `TEMP`: three separate processes each open
their own connection to the one running server.

Run standalone against a live `$POSTGRES_TEST_DSN` for local debugging:

    pixi run -e default sh scripts/with-pg-server.sh sh -c \\
        'mojo build tests/crosscheck_write.mojo -I src -o build/crosscheck-write \\
         && ./build/crosscheck-write && python3 tests/crosscheck.py'
"""

import math
import sys
from datetime import date, datetime, time, timedelta, timezone
from decimal import Decimal

import psycopg

# ===--------------------------------------------------------------------===#
# Fixture -- kept in sync by hand with tests/crosscheck_write.mojo and
# tests/crosscheck_read.mojo. Column order matches the tables' DDL.
# ===--------------------------------------------------------------------===#

COLUMNS = [
    "id", "b", "i2", "i4", "i8", "f4", "f8", "num", "t", "vc", "bp", "by",
    "d", "tm", "ts", "tstz", "u", "j", "jb",
]  # fmt: skip

SCHEMA_SQL = (
    "(id bigint primary key, b bool, i2 int2, i4 int4, i8 int8, f4 float4,"
    " f8 float8, num numeric(20,6), t text, vc varchar(10), bp bpchar(3),"
    " by bytea, d date, tm time, ts timestamp, tstz timestamptz, u uuid,"
    " j json, jb jsonb)"
)

UTC = timezone.utc

# Each row: the "natural" value a caller would supply. `bp` is the
# *unpadded* text (bpchar(3) blank-pads it server-side to a length in
# *characters*, not bytes -- see `_bpchar` below); `jb` is the *compact*
# text a caller would write, which jsonb normalizes on the way in ("k":"v"
# grows a space; keys would also be sorted, which is why every jsonb value
# here has a single key).
FIXTURES = [
    # id=1 "normal"
    {
        "id": 1, "b": True, "i2": 42, "i4": 123456, "i8": 9_000_000_000_000,
        "f4": 1.5, "f8": 2.25, "num": "12345.678900", "t": "Ada Lovelace",
        "vc": "shortval", "bp": "yo", "by": bytes([0xDE, 0xAD, 0xBE, 0xEF]),
        "d": date(2024, 2, 29), "tm": time(13, 14, 15, 123456),
        "ts": datetime(2024, 2, 29, 13, 14, 15, 123456),
        "tstz": datetime(2024, 2, 29, 13, 14, 15, 123456, tzinfo=UTC),
        "u": "6ba7b810-9dad-11d1-80b4-00c04fd430c8",
        "j": '{"a": 1}', "jb": '{"a":1}',
    },  # fmt: skip
    # id=2 "nulls" -- every column but `id` is NULL.
    {col: None for col in COLUMNS} | {"id": 2},
    # id=3 "zero/empty/epoch"
    {
        "id": 3, "b": False, "i2": 0, "i4": 0, "i8": 0, "f4": 0.0, "f8": 0.0,
        "num": "0.000000", "t": "", "vc": "", "bp": "", "by": b"",
        "d": date(1970, 1, 1), "tm": time(0, 0, 0, 0),
        "ts": datetime(1970, 1, 1, 0, 0, 0),
        "tstz": datetime(1970, 1, 1, 0, 0, 0, tzinfo=UTC),
        "u": "00000000-0000-0000-0000-000000000000",
        "j": "{}", "jb": "{}",
    },  # fmt: skip
    # id=4 "edge_min" -- int mins, NaN/-Infinity, 0001-01-01, a non-UTC
    # offset (+05:30) in the literal, and the tab/newline/quote/backslash/
    # \N/non-ASCII text combo.
    {
        "id": 4, "b": True, "i2": -32768, "i4": -2147483648,
        "i8": -9223372036854775808, "f4": math.nan, "f8": -math.inf,
        "num": "-123.400000", "t": 'a\tb\nc"d\\e\\Nf日本語',
        "vc": "0123456789", "bp": "é中",
        "by": bytes([0x00, 0xFF, 0x00, 0xFF, 0x7F]),
        "d": date(1, 1, 1), "tm": time(0, 0, 0, 1),
        "ts": datetime(1, 1, 1, 0, 0, 0, 1),
        "tstz": datetime(1, 6, 15, 12, 0, 0, tzinfo=timezone(timedelta(hours=5, minutes=30))),
        "u": "ffffffff-ffff-ffff-ffff-ffffffffffff",
        "j": '{"k": "v"}', "jb": '{"k":"v"}',
    },  # fmt: skip
    # id=5 "edge_max" -- int maxes, Infinity, 9999-12-31, another non-UTC
    # offset, and max-precision numeric(20,6). The offset is +01:00, not a
    # more extreme one: psycopg's C extension rejects any timestamptz whose
    # UTC-normalized value falls in year 10000 ("timestamp too large (after
    # year 10K)"), which a negative offset on this already-end-of-9999 local
    # time would do.
    {
        "id": 5, "b": False, "i2": 32767, "i4": 2147483647,
        "i8": 9223372036854775807, "f4": math.inf, "f8": math.inf,
        "num": "99999999999999.990000",
        "t": 'Row 5: quoted "text", back\\slash, tab\tend',
        "vc": "row5-vc", "bp": "z",
        "by": bytes([0xFF, 0x00, 0xFF, 0x00]),
        "d": date(9999, 12, 31), "tm": time(23, 59, 59, 999999),
        "ts": datetime(9999, 12, 31, 23, 59, 59, 999999),
        "tstz": datetime(9999, 12, 31, 23, 59, 59, 999999, tzinfo=timezone(timedelta(hours=1))),
        "u": "00112233-4455-6677-8899-aabbccddeeff",
        "j": '{"n": 5}', "jb": '{"n":5}',
    },  # fmt: skip
]


def _bpchar(s, n=3):
    """Blank-pad `s` to `n` *characters* -- what bpchar(n) does on output."""
    return s + " " * (n - len(s))


def _jsonb_expected(jb_in):
    """The normalized text jsonb stores a compact single-key object as.

    Every non-empty `jb` fixture above has exactly one key, so normalization
    is only ever "add a space after the colon" -- no key reordering to model.
    `{}` has no colon to add a space around, and stays `{}`.
    """
    if jb_in == "{}":
        return "{}"
    key, _, val = jb_in[1:-1].partition(":")
    return "{" + key + ": " + val + "}"


# ===--------------------------------------------------------------------===#
# Direction A: read xc_mojo / xc_mojo_copy, assert against FIXTURES
# ===--------------------------------------------------------------------===#

FAILURES = []


def _check(table, row_id, col, expected, actual):
    if expected != actual:
        FAILURES.append(
            f"{table}: row id={row_id} column {col!r}: expected"
            f" {expected!r}, got {actual!r}"
        )


def _check_float(table, row_id, col, expected, actual):
    if math.isnan(expected):
        ok = actual is not None and math.isnan(actual)
    else:
        ok = actual == expected
    if not ok:
        FAILURES.append(
            f"{table}: row id={row_id} column {col!r}: expected"
            f" {expected!r}, got {actual!r}"
        )


def verify_table(conn, table):
    select_cols = ",".join(c if c not in ("j", "jb") else f"{c}::text AS {c}" for c in COLUMNS)
    sql = f"SELECT {select_cols} FROM {table} ORDER BY id"
    with conn.cursor(row_factory=psycopg.rows.dict_row) as cur:
        cur.execute(sql)
        rows = cur.fetchall()

    if len(rows) != len(FIXTURES):
        FAILURES.append(
            f"{table}: expected {len(FIXTURES)} rows, got {len(rows)}"
        )
        return

    for fixture, row in zip(FIXTURES, rows):
        row_id = fixture["id"]
        if fixture["b"] is None:
            for col in COLUMNS:
                if col == "id":
                    continue
                _check(table, row_id, col, None, row[col])
            continue

        _check(table, row_id, "b", fixture["b"], row["b"])
        for col in ("i2", "i4", "i8"):
            _check(table, row_id, col, fixture[col], row[col])
        for col in ("f4", "f8"):
            _check_float(table, row_id, col, fixture[col], row[col])
        _check(table, row_id, "num", fixture["num"], str(row["num"]))
        _check(table, row_id, "t", fixture["t"], row["t"])
        _check(table, row_id, "vc", fixture["vc"], row["vc"])
        _check(table, row_id, "bp", _bpchar(fixture["bp"]), row["bp"])
        _check(table, row_id, "by", fixture["by"], bytes(row["by"]))
        _check(table, row_id, "d", fixture["d"], row["d"])
        _check(table, row_id, "tm", fixture["tm"], row["tm"])
        _check(table, row_id, "ts", fixture["ts"], row["ts"])
        _check(table, row_id, "tstz", fixture["tstz"], row["tstz"])
        _check(table, row_id, "u", fixture["u"], str(row["u"]).lower())
        _check(table, row_id, "j", fixture["j"], row["j"])
        _check(
            table, row_id, "jb", _jsonb_expected(fixture["jb"]), row["jb"]
        )


# ===--------------------------------------------------------------------===#
# Direction B: write xc_py with native psycopg types
# ===--------------------------------------------------------------------===#

INSERT_SQL = (
    "INSERT INTO xc_py VALUES (%(id)s, %(b)s::bool, %(i2)s::int2,"
    " %(i4)s::int4, %(i8)s::int8, %(f4)s::real, %(f8)s::double precision,"
    " %(num)s::numeric(20,6), %(t)s::text, %(vc)s::varchar(10),"
    " %(bp)s::bpchar(3), %(by)s::bytea, %(d)s::date, %(tm)s::time,"
    " %(ts)s::timestamp, %(tstz)s::timestamptz, %(u)s::uuid,"
    " %(j)s::json, %(jb)s::jsonb)"
)


def write_xc_py(conn):
    with conn.cursor() as cur:
        cur.execute("DROP TABLE IF EXISTS xc_py")
        cur.execute("CREATE TABLE xc_py " + SCHEMA_SQL)
        for fixture in FIXTURES:
            params = dict(fixture)
            if params["num"] is not None:
                params["num"] = Decimal(params["num"])
            cur.execute(INSERT_SQL, params)
    print(f"xc_py: {len(FIXTURES)} rows via psycopg native types")


# ===--------------------------------------------------------------------===#

def main():
    dsn = __import__("os").environ.get("POSTGRES_TEST_DSN", "")
    if not dsn:
        print("crosscheck.py: $POSTGRES_TEST_DSN is not set", file=sys.stderr)
        return 1

    with psycopg.connect(dsn, autocommit=True) as conn:
        conn.execute("SET TimeZone='UTC'")

        verify_table(conn, "xc_mojo")
        verify_table(conn, "xc_mojo_copy")
        if FAILURES:
            print("direction A: cell mismatches found")
            for msg in FAILURES:
                print("  !!", msg, file=sys.stderr)
            return 1
        print(
            f"direction A: {len(FIXTURES)} rows x {len(COLUMNS)} columns"
            f" verified across xc_mojo and xc_mojo_copy"
        )

        write_xc_py(conn)

    return 0


if __name__ == "__main__":
    sys.exit(main())
