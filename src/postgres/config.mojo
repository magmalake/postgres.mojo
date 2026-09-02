"""Typed connection configuration.

`ConnectionConfig` is a small builder that emits a libpq conninfo string on
demand. Field names match libpq's documented keyword/value parameters (see
https://www.postgresql.org/docs/current/libpq-connect.html#LIBPQ-PARAMKEYWORDS),
with underscores only where Mojo requires them.

`Connection` (elsewhere in this package) also accepts a URI directly —
`postgresql://user:pass@host:port/dbname?sslmode=require` — since libpq
parses both a conninfo string and a URI through the same entry point. This
builder exists for callers who would rather set typed fields than assemble a
URI by hand.
"""


def _needs_quoting(value: String) -> Bool:
    """A conninfo value must be quoted if it's empty or contains
    whitespace, `'`, or `\\` — any of which would otherwise be read as a
    keyword/value separator or a quote delimiter."""
    if value.byte_length() == 0:
        return True
    for b in value.as_bytes():
        if (
            b == UInt8(ord(" "))
            or b == UInt8(ord("\t"))
            or b == UInt8(ord("\n"))
            or b == UInt8(ord("'"))
            or b == UInt8(ord("\\"))
        ):
            return True
    return False


def _escape_conninfo_value(value: String) -> String:
    """Render a single conninfo value: bare if it needs no quoting,
    otherwise single-quoted with `'` and `\\` backslash-escaped."""
    if not _needs_quoting(value):
        return value
    var out = List[UInt8](capacity=value.byte_length() + 2)
    out.append(UInt8(ord("'")))
    for b in value.as_bytes():
        if b == UInt8(ord("\\")) or b == UInt8(ord("'")):
            out.append(UInt8(ord("\\")))
        out.append(b)
    out.append(UInt8(ord("'")))
    return String(StringSlice(unsafe_from_utf8=Span(out)))


struct ConnectionConfig(Copyable, Movable):
    """Connection parameters for a libpq connection.

    Build a `Connection` from this directly, or call `to_conninfo()` if you
    want the raw libpq conninfo string for debugging or logging.
    """

    var host: String
    var port: Int
    var dbname: String
    var user: String
    var password: String
    var application_name: String
    var sslmode: String
    var connect_timeout: Int
    var _extra_keys: List[String]
    """Keys set via `set()`, beyond the typed fields above, in the order
    they were first set."""
    var _extra_values: List[String]
    """Values parallel to `_extra_keys`."""

    def __init__(
        out self,
        host: String = "localhost",
        port: Int = 5432,
        dbname: String = "",
        user: String = "",
        password: String = "",
        application_name: String = "postgres.mojo",
        sslmode: String = "prefer",
        connect_timeout: Int = 10,
    ):
        self.host = host
        self.port = port
        self.dbname = dbname
        self.user = user
        self.password = password
        self.application_name = application_name
        self.sslmode = sslmode
        self.connect_timeout = connect_timeout
        self._extra_keys = []
        self._extra_values = []

    def set(mut self, key: String, value: String):
        """Escape hatch for any libpq conninfo keyword not exposed as a
        typed field above (e.g. `target_session_attrs`, `options`).

        Setting a key that was already set — by an earlier `set()` call —
        replaces its value in place rather than adding a duplicate, so
        `to_conninfo()` stays deterministic and each keyword appears at
        most once."""
        for i in range(len(self._extra_keys)):
            if self._extra_keys[i] == key:
                self._extra_values[i] = value
                return
        self._extra_keys.append(key)
        self._extra_values.append(value)

    def to_conninfo(self) -> String:
        """Render to a libpq conninfo string (`key=value key=value ...`).

        Extra keys set via `set()` are emitted last, in the order they were
        first set."""
        var parts = String("")
        parts += "host=" + _escape_conninfo_value(self.host)
        parts += " port=" + String(self.port)
        if self.dbname.byte_length() > 0:
            parts += " dbname=" + _escape_conninfo_value(self.dbname)
        if self.user.byte_length() > 0:
            parts += " user=" + _escape_conninfo_value(self.user)
        if self.password.byte_length() > 0:
            parts += " password=" + _escape_conninfo_value(self.password)
        parts += " application_name=" + _escape_conninfo_value(
            self.application_name
        )
        parts += " sslmode=" + _escape_conninfo_value(self.sslmode)
        parts += " connect_timeout=" + String(self.connect_timeout)
        for i in range(len(self._extra_keys)):
            parts += (
                " "
                + self._extra_keys[i]
                + "="
                + _escape_conninfo_value(self._extra_values[i])
            )
        return parts
