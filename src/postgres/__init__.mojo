"""`postgres` — a PostgreSQL client for Mojo, over libpq.

Connections, parameterised statements, prepared statements, and typed results,
with every server error carrying its SQLSTATE.  libpq is loaded at run time
from the conda-forge build in ``$CONDA_PREFIX`` (which links OpenSSL, so
``sslmode=require`` works), and every C call lives behind `postgres._ffi`.

```mojo
from postgres import Connection, Params, sqlstate_of

def main() raises:
    var conn = Connection("postgresql://localhost/app?connect_timeout=5")

    _ = conn.execute(
        "CREATE TABLE IF NOT EXISTS people ("
        "  id bigint primary key, name text not null, note text)"
    )
    _ = conn.execute(
        "INSERT INTO people VALUES ($1, $2, $3)",
        Params().int64(1).text("Ada").null(),
    )

    var res = conn.query(
        "SELECT id, name, note FROM people WHERE id >= $1", Params().int64(1)
    )
    for row in res:
        print(row.int64("id"), row.text("name"), row.is_null("note"))

    try:
        _ = conn.execute("INSERT INTO people VALUES ($1, $2, $3)",
                         Params().int64(1).text("Ada").null())
    except e:
        if sqlstate_of(e) == "23505":
            print("already there")
```

## What this tin promises

**Text format on the wire.**  Parameters go out as text and results come back
as text; `postgres.text` is the codec in both directions, and
`result.Row`'s typed accessors are that codec applied to a cell.  Binary format
is not implemented, so a `numeric` keeps every digit the server sent
(`result.Row.numeric` hands back a `String`) and no value is ever silently
rounded on the way through.

**NULL is distinct from the empty string.**  libpq renders both as ``""``.
`result.Row.is_null` and `result.Row.opt_text` are the two ways to tell them
apart, and every typed accessor raises rather than inventing a zero value for a
NULL cell.

**No ORM, no async, no pooling.**  One `Connection` is one `PGconn`, usable
from one thread, and you write the SQL.

**Typed accessors trust you, not the OID.**  `row.int64("n")` parses the
cell's text as an `int8` whatever the server called the column; a mismatch
surfaces as the codec's own error, naming the type and the text.
`result.Result.column_oid` is there for callers who want to dispatch instead.

## Errors

Every server error is raised as an `Error` whose message was formatted by
`sqlstate.PostgresError`:

```text
postgres [SQLSTATE 23505] duplicate key value violates unique constraint "people_pkey"
  DETAIL: Key (id)=(1) already exists.
  SQL: INSERT INTO people VALUES ($1, $2, $3)
```

Mojo 1.x can only raise a string, so the SQLSTATE travels *inside* the
message; `sqlstate_of` reads it back out of a caught `Error`, and
`connection.Connection.last_error` keeps the structured `sqlstate.PostgresError`
-- severity, SQLSTATE, message, detail, hint, statement -- with its
`is_unique_violation`-style predicates.

## Modules

- `postgres.connection` -- `Connection`, `Statement`.
- `postgres.result` -- `Result`, `Row` and the typed accessors.
- `postgres.params` -- the `Params` builder for ``$1``-style parameters.
- `postgres.config` -- `ConnectionConfig`, for callers who prefer typed fields
  to a URI.
- `postgres.sqlstate` -- `PostgresError`, `sqlstate_of`, the code constants.
- `postgres.text` -- the text-format codec and the ``OID_*`` constants.
- `postgres.copyfmt` -- the COPY text/CSV row codec.
- `postgres._ffi` -- the libpq entry points.  Not for user code.
"""

from .config import ConnectionConfig
from .connection import Connection, Statement
from .params import Params
from .result import Result, Row
from .sqlstate import (
    ADMIN_SHUTDOWN,
    CHECK_VIOLATION,
    CONNECTION_FAILURE,
    DEADLOCK_DETECTED,
    DIVISION_BY_ZERO,
    DUPLICATE_TABLE,
    FOREIGN_KEY_VIOLATION,
    INSUFFICIENT_PRIVILEGE,
    INVALID_TEXT_REPRESENTATION,
    LOCK_NOT_AVAILABLE,
    NOT_NULL_VIOLATION,
    NUMERIC_VALUE_OUT_OF_RANGE,
    PostgresError,
    QUERY_CANCELED,
    SERIALIZATION_FAILURE,
    SQLCLIENT_UNABLE_TO_ESTABLISH,
    SYNTAX_ERROR,
    UNDEFINED_COLUMN,
    UNDEFINED_TABLE,
    UNIQUE_VIOLATION,
    is_connection_error,
    is_deadlock,
    is_integrity_violation,
    is_retryable,
    is_serialization_failure,
    is_unique_violation,
    sqlstate_class,
    sqlstate_of,
)
from .text import (
    OID_BOOL,
    OID_BPCHAR,
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
    OID_TEXT,
    OID_TIME,
    OID_TIMESTAMP,
    OID_TIMESTAMPTZ,
    OID_UUID,
    OID_VARCHAR,
    oid_name,
)
