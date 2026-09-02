"""`postgres.params` — the `Params` builder for `PQexecParams` / `PQexecPrepared`.

Collects `$1`-style query parameters, always in text format (this tin never
sends binary-format parameters). `Params` keeps three parallel lists —
values, null flags, and OIDs — that the FFI layer reads by index when it
builds the `char* const*`/`Oid*`/`int*` arrays libpq wants.

Every typed builder method encodes through `postgres.text` and is chainable
by consuming and returning `self`, so a call reads like::

    var p = Params().text("gold").int64(7).timestamptz_micros(now)

`.text()` binds OID 0 — the server infers the parameter's type from query
context, which is what you want for an untyped literal. Use `.typed()` as an
escape hatch for a value/OID pair this module has no dedicated method for.
"""

from .text import (
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
    encode_bool,
    encode_bytea,
    encode_date,
    encode_float32,
    encode_float64,
    encode_int16,
    encode_int32,
    encode_int64,
    encode_time,
    encode_timestamp,
    encode_timestamptz,
)


struct Params(Copyable, Movable, Sized):
    """A builder for one query's parameter list.

    `Params()` starts empty. Each builder method appends one parameter and
    returns `self` so calls chain; `__len__`, `value(i)`, `is_null(i)`, and
    `oid(i)` are the read side the FFI layer uses to fill libpq's parameter
    arrays.
    """

    var _values: List[String]
    var _nulls: List[Bool]
    var _oids: List[UInt32]

    def __init__(out self):
        self._values = List[String]()
        self._nulls = List[Bool]()
        self._oids = List[UInt32]()

    # -- accessors ------------------------------------------------------

    def __len__(self) -> Int:
        """Number of parameters bound so far."""
        return len(self._values)

    def value(self, i: Int) -> String:
        """The text form of parameter `i` (0-based). Meaningless — and
        conventionally the empty string — when `is_null(i)` is `True`."""
        return self._values[i]

    def is_null(self, i: Int) -> Bool:
        """Whether parameter `i` is SQL NULL."""
        return self._nulls[i]

    def oid(self, i: Int) -> UInt32:
        """The OID parameter `i` was bound with; `0` lets the server infer
        the type from query context."""
        return self._oids[i]

    # -- shared push ------------------------------------------------------

    def _push(
        var self, v: String, o: UInt32, *, is_null_val: Bool = False
    ) -> Self:
        self._values.append(v)
        self._nulls.append(is_null_val)
        self._oids.append(o)
        return self^

    # -- typed builders (chainable) ---------------------------------------

    def text(var self, v: String) -> Self:
        """Bind `v` untyped (OID 0) — the server infers the type from
        context."""
        return self^._push(v, UInt32(0))

    def int16(var self, v: Int16) -> Self:
        return self^._push(encode_int16(v), OID_INT2)

    def int32(var self, v: Int32) -> Self:
        return self^._push(encode_int32(v), OID_INT4)

    def int64(var self, v: Int64) -> Self:
        return self^._push(encode_int64(v), OID_INT8)

    def float32(var self, v: Float32) -> Self:
        return self^._push(encode_float32(v), OID_FLOAT4)

    def float64(var self, v: Float64) -> Self:
        return self^._push(encode_float64(v), OID_FLOAT8)

    def bool(var self, v: Bool) -> Self:
        return self^._push(encode_bool(v), OID_BOOL)

    def numeric(var self, v: String) -> Self:
        """Bind an already-formatted `numeric` literal. Kept a `String` —
        see `postgres.text`'s module docstring for why."""
        return self^._push(v, OID_NUMERIC)

    def bytea(var self, v: Span[UInt8, _]) -> Self:
        return self^._push(encode_bytea(v), OID_BYTEA)

    def date_days(var self, v: Int32) -> Self:
        """`v` is days since 1970-01-01, as returned by `text.decode_date`."""
        return self^._push(encode_date(v), OID_DATE)

    def time_micros(var self, v: Int64) -> Self:
        """`v` is microseconds since midnight, as returned by
        `text.decode_time`."""
        return self^._push(encode_time(v), OID_TIME)

    def timestamp_micros(var self, v: Int64) -> Self:
        """`v` is microseconds since 1970-01-01 00:00:00 (naive, no zone), as
        returned by `text.decode_timestamp`."""
        return self^._push(encode_timestamp(v), OID_TIMESTAMP)

    def timestamptz_micros(var self, v: Int64) -> Self:
        """`v` is UTC microseconds since 1970-01-01 00:00:00, as returned by
        `text.decode_timestamptz`."""
        return self^._push(encode_timestamptz(v), OID_TIMESTAMPTZ)

    def uuid(var self, v: String) -> Self:
        return self^._push(v, OID_UUID)

    def json(var self, v: String) -> Self:
        return self^._push(v, OID_JSON)

    def jsonb(var self, v: String) -> Self:
        return self^._push(v, OID_JSONB)

    def null(var self, oid: UInt32 = 0) -> Self:
        """Bind SQL NULL, optionally typed with `oid` (default 0, server
        infers)."""
        return self^._push(String(""), oid, is_null_val=True)

    def typed(var self, value: String, oid: UInt32) -> Self:
        """Escape hatch: bind an already-formatted text value with an
        explicit OID this module has no dedicated method for."""
        return self^._push(value, oid)
