#!/usr/bin/env python3
"""Generate round-trip fixtures for tests/test_text.mojo.

Run with `pixi run -e default python tests/gen_text_fixtures.py` and paste
the printed Mojo `List` literals into test_text.mojo. Kept checked in beside
the test file so the fixtures are reproducible (and easy to extend) instead
of being hand-typed.

- Dates: `(iso_string, days_since_epoch)` pairs, computed with `date.toordinal()`
  differences against 1970-01-01 (Python's `date` is proleptic Gregorian, same
  as text.mojo's Howard Hinnant civil_from_days/days_from_civil), stepping
  4,321 days from 0001-01-01 through 9999-12-31 plus a handful of named edge
  cases (epoch boundary, century leap-year rules, Y2038).
- Naive timestamps: `(text, micros_since_epoch)` pairs, text always carries
  exactly 6 fractional digits so `decode_timestamp`/`encode_timestamp` are
  exact inverses of each other on the same string.
- timestamptz: `(text, utc_micros)` pairs across the offset spellings the
  spec calls out (`+00`, `-05`, `+05:30`, `+01:00`). `encode_timestamptz`
  always emits `+00` (UTC microseconds carry no original offset), so these
  are decode-direction fixtures; the round-trip-through-UTC property
  (`decode(encode(decode(text))) == decode(text)`) is checked in Mojo
  instead of expecting `encode(micros) == text`.
"""

import datetime as dt

EPOCH = dt.date(1970, 1, 1)


def days_since_epoch(d: dt.date) -> int:
    return (d - EPOCH).days


def mojo_str_literal(s: str) -> str:
    escaped = s.replace("\\", "\\\\").replace('"', '\\"')
    return '"' + escaped + '"'


def sweep_dates():
    start = dt.date(1, 1, 1)
    end = dt.date(9999, 12, 31)
    out = []
    d = start
    step = dt.timedelta(days=4321)
    while d <= end:
        out.append(d)
        if d > end - step:
            break
        d += step
    if out[-1] != end:
        out.append(end)

    edge_cases = [
        dt.date(1969, 12, 31),
        dt.date(1970, 1, 1),
        dt.date(2000, 2, 29),  # divisible by 400 -> leap
        dt.date(1900, 3, 1),  # 1900 divisible by 100, not 400 -> not leap
        dt.date(2038, 1, 19),  # 32-bit Unix time overflow
        dt.date(2024, 2, 29),  # ordinary leap day
        dt.date(1600, 2, 29),  # leap century
        dt.date(2100, 3, 1),  # non-leap century (2100 not div by 400)
        dt.date(4, 2, 29),  # early leap year
        dt.date(1, 1, 1),  # earliest supported date
        dt.date(9999, 12, 31),  # latest supported date
    ]
    out.extend(edge_cases)

    seen = set()
    deduped = []
    for d in out:
        if d not in seen:
            seen.add(d)
            deduped.append(d)
    deduped.sort()
    return deduped


def print_date_fixtures():
    dates = sweep_dates()
    print("    var date_fixtures: List[Tuple[String, Int64]] = [")
    for d in dates:
        print(
            "        ({}, Int64({})),".format(
                mojo_str_literal(d.isoformat()), days_since_epoch(d)
            )
        )
    print("    ]")


def ts_micros(d: dt.date, h: int, mi: int, s: int, micro: int) -> int:
    days = days_since_epoch(d)
    return (
        days * 86_400_000_000
        + h * 3_600_000_000
        + mi * 60_000_000
        + s * 1_000_000
        + micro
    )


def timestamp_text(d: dt.date, h: int, mi: int, s: int, micro: int) -> str:
    return "{} {:02d}:{:02d}:{:02d}.{:06d}".format(
        d.isoformat(), h, mi, s, micro
    )


def print_timestamp_fixtures():
    cases = [
        (dt.date(1970, 1, 1), 0, 0, 0, 0),
        (dt.date(1969, 12, 31), 23, 59, 59, 999999),
        (dt.date(1969, 12, 31), 0, 0, 0, 0),
        (dt.date(2000, 1, 1), 0, 0, 0, 0),
        (dt.date(2000, 2, 29), 12, 30, 45, 123456),
        (dt.date(2038, 1, 19), 3, 14, 8, 0),
        (dt.date(1, 1, 1), 0, 0, 0, 0),
        (dt.date(9999, 12, 31), 23, 59, 59, 999999),
        (dt.date(1900, 3, 1), 6, 0, 0, 500000),
        (dt.date(2024, 2, 29), 18, 45, 0, 1),
    ]
    print("    var timestamp_fixtures: List[Tuple[String, Int64]] = [")
    for d, h, mi, s, micro in cases:
        text = timestamp_text(d, h, mi, s, micro)
        micros = ts_micros(d, h, mi, s, micro)
        print(
            "        ({}, Int64({})),".format(mojo_str_literal(text), micros)
        )
    print("    ]")


def print_timestamptz_fixtures():
    # (date, h, mi, s, micro, offset_text, offset_seconds)
    cases = [
        (dt.date(1970, 1, 1), 0, 0, 0, 0, "+00", 0),
        (dt.date(2000, 1, 1), 0, 0, 0, 0, "-05", -5 * 3600),
        (dt.date(2000, 1, 1), 0, 0, 0, 0, "+05:30", 5 * 3600 + 30 * 60),
        (dt.date(2024, 6, 15), 12, 0, 0, 250000, "+01:00", 3600),
        (dt.date(1969, 12, 31), 23, 0, 0, 0, "-05", -5 * 3600),
        (dt.date(2038, 1, 19), 3, 14, 7, 0, "+00", 0),
        (dt.date(1900, 3, 1), 6, 0, 0, 0, "+05:30", 5 * 3600 + 30 * 60),
        (dt.date(9999, 12, 31), 23, 59, 59, 999999, "+00", 0),
        (dt.date(1, 1, 1), 0, 0, 0, 0, "-05", -5 * 3600),
        (dt.date(2000, 2, 29), 12, 0, 0, 0, "+01:00", 3600),
    ]
    print("    var timestamptz_fixtures: List[Tuple[String, Int64]] = [")
    for d, h, mi, s, micro, offset_text, offset_seconds in cases:
        text = timestamp_text(d, h, mi, s, micro) + offset_text
        local_micros = ts_micros(d, h, mi, s, micro)
        utc_micros = local_micros - offset_seconds * 1_000_000
        print(
            "        ({}, Int64({})),".format(mojo_str_literal(text), utc_micros)
        )
    print("    ]")


if __name__ == "__main__":
    print("# --- date_fixtures ---")
    print_date_fixtures()
    print()
    print("# --- timestamp_fixtures ---")
    print_timestamp_fixtures()
    print()
    print("# --- timestamptz_fixtures ---")
    print_timestamptz_fixtures()
