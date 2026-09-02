"""Tests for `postgres.params.Params` — every builder method, ordering,
chaining, and the empty-builder case."""

from std.testing import TestSuite, assert_equal, assert_true

from postgres.params import Params
from postgres.text import (
    OID_BOOL,
    OID_BYTEA,
    OID_DATE,
    OID_FLOAT4,
    OID_FLOAT8,
    OID_INT2,
    OID_INT4,
    OID_INT8,
    OID_JSON,
    OID_JSONB,
    OID_NUMERIC,
    OID_TIME,
    OID_TIMESTAMP,
    OID_TIMESTAMPTZ,
    OID_UUID,
)


def test_empty_params() raises:
    var p = Params()
    assert_equal(len(p), 0)


def test_text_binds_oid_zero() raises:
    var p = Params().text("gold")
    assert_equal(len(p), 1)
    assert_equal(p.value(0), "gold")
    assert_equal(p.oid(0), UInt32(0))
    assert_true(not p.is_null(0))


def test_int_builders() raises:
    var p = (
        Params()
        .int16(Int16(-5))
        .int32(Int32(2147483647))
        .int64(Int64(-9223372036854775808))
    )
    assert_equal(len(p), 3)
    assert_equal(p.value(0), "-5")
    assert_equal(p.oid(0), OID_INT2)
    assert_equal(p.value(1), "2147483647")
    assert_equal(p.oid(1), OID_INT4)
    assert_equal(p.value(2), "-9223372036854775808")
    assert_equal(p.oid(2), OID_INT8)


def test_float_builders() raises:
    var p = Params().float32(Float32(1.5)).float64(Float64(-2.5))
    assert_equal(p.value(0), "1.5")
    assert_equal(p.oid(0), OID_FLOAT4)
    assert_equal(p.value(1), "-2.5")
    assert_equal(p.oid(1), OID_FLOAT8)


def test_bool_builder() raises:
    var p = Params().bool(True).bool(False)
    assert_equal(p.value(0), "t")
    assert_equal(p.oid(0), OID_BOOL)
    assert_equal(p.value(1), "f")


def test_numeric_builder() raises:
    var p = Params().numeric("123.456000")
    assert_equal(p.value(0), "123.456000")
    assert_equal(p.oid(0), OID_NUMERIC)


def test_bytea_builder() raises:
    var data: List[UInt8] = [UInt8(0x0A), UInt8(0xFF)]
    var p = Params().bytea(data)
    assert_equal(p.value(0), "\\x0aff")
    assert_equal(p.oid(0), OID_BYTEA)


def test_date_time_builders() raises:
    var p = (
        Params()
        .date_days(Int32(0))
        .time_micros(Int64(0))
        .timestamp_micros(Int64(0))
        .timestamptz_micros(Int64(0))
    )
    assert_equal(len(p), 4)
    assert_equal(p.value(0), "1970-01-01")
    assert_equal(p.oid(0), OID_DATE)
    assert_equal(p.value(1), "00:00:00.000000")
    assert_equal(p.oid(1), OID_TIME)
    assert_equal(p.value(2), "1970-01-01 00:00:00.000000")
    assert_equal(p.oid(2), OID_TIMESTAMP)
    assert_equal(p.value(3), "1970-01-01 00:00:00.000000+00")
    assert_equal(p.oid(3), OID_TIMESTAMPTZ)


def test_uuid_json_builders() raises:
    var p = (
        Params()
        .uuid("123e4567-e89b-12d3-a456-426614174000")
        .json('{"a": 1}')
        .jsonb('{"b": 2}')
    )
    assert_equal(p.value(0), "123e4567-e89b-12d3-a456-426614174000")
    assert_equal(p.oid(0), OID_UUID)
    assert_equal(p.value(1), '{"a": 1}')
    assert_equal(p.oid(1), OID_JSON)
    assert_equal(p.value(2), '{"b": 2}')
    assert_equal(p.oid(2), OID_JSONB)


def test_null_builder() raises:
    var p = Params().null().null(OID_INT4)
    assert_equal(len(p), 2)
    assert_true(p.is_null(0))
    assert_equal(p.oid(0), UInt32(0))
    assert_true(p.is_null(1))
    assert_equal(p.oid(1), OID_INT4)


def test_typed_escape_hatch() raises:
    var p = Params().typed("42", OID_INT4)
    assert_equal(p.value(0), "42")
    assert_equal(p.oid(0), OID_INT4)
    assert_true(not p.is_null(0))


def test_chaining_preserves_order() raises:
    var p = Params().text("gold").int64(Int64(7)).bool(True).null().text("last")
    assert_equal(len(p), 5)
    assert_equal(p.value(0), "gold")
    assert_equal(p.value(1), "7")
    assert_equal(p.value(2), "t")
    assert_true(p.is_null(3))
    assert_equal(p.value(4), "last")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
