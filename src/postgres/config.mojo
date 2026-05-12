"""Typed connection configuration.

`ConnectionConfig` is a small builder that emits a libpq conninfo string
on demand. Field names match libpq's documented keyword/value parameters
(see https://www.postgresql.org/docs/current/libpq-connect.html#LIBPQ-PARAMKEYWORDS),
with underscores only where Mojo requires them.
"""

from collections import Dict


fn _escape_conninfo_value(value: String) -> String:
    """libpq conninfo values containing whitespace or quotes must be quoted.

    Returns the value either bare (if it's free of whitespace and single
    quotes) or single-quoted with backslash-escaped quotes/backslashes.
    """
    var needs_quoting = False
    for ch in value:
        if (
            ch[] == " "
            or ch[] == "\t"
            or ch[] == "\n"
            or ch[] == "'"
            or ch[] == "\\"
        ):
            needs_quoting = True
            break
    if not needs_quoting and len(value) > 0:
        return value
    var out = String("'")
    for ch in value:
        if ch[] == "\\" or ch[] == "'":
            out += "\\"
        out += ch[]
    out += "'"
    return out


@value
struct ConnectionConfig:
    """Connection parameters for a libpq connection.

    Build a `Connection` from this directly, or call `to_conninfo()` if you
    want the raw libpq conninfo string for debugging.
    """

    var host: String
    var port: Int
    var dbname: String
    var user: String
    var password: String
    var application_name: String
    var sslmode: String
    var connect_timeout: Int
    var extra: Dict[String, String]

    fn __init__(
        out self,
        host: String = "localhost",
        port: Int = 5432,
        dbname: String = "",
        user: String = "",
        password: String = "",
        application_name: String = "mojo-postgres",
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
        self.extra = Dict[String, String]()

    fn set(mut self, key: String, value: String):
        """Escape hatch for any libpq keyword we don't expose as a field."""
        self.extra[key] = value

    fn to_conninfo(self) -> String:
        """Render to a libpq conninfo string."""
        var parts = String("")
        parts += "host=" + _escape_conninfo_value(self.host)
        parts += " port=" + String(self.port)
        if len(self.dbname) > 0:
            parts += " dbname=" + _escape_conninfo_value(self.dbname)
        if len(self.user) > 0:
            parts += " user=" + _escape_conninfo_value(self.user)
        if len(self.password) > 0:
            parts += " password=" + _escape_conninfo_value(self.password)
        parts += " application_name=" + _escape_conninfo_value(
            self.application_name
        )
        parts += " sslmode=" + _escape_conninfo_value(self.sslmode)
        parts += " connect_timeout=" + String(self.connect_timeout)
        for item in self.extra.items():
            parts += (
                " " + item[].key + "=" + _escape_conninfo_value(item[].value)
            )
        return parts
