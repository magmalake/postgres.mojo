"""`postgres` — a PostgreSQL client for Mojo, over libpq.

Connections, parameterised statements, prepared statements, typed results,
transactions and ``COPY``, with every server error carrying its SQLSTATE.
libpq is loaded at run time from the conda-forge build in ``$CONDA_PREFIX``
(which links OpenSSL, so ``sslmode=require`` works), and every C call lives
behind `postgres._ffi`.

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

## Transactions and COPY

`connection.Connection.begin` issues ``BEGIN`` and returns a
`connection.Transaction` that **rolls back when it is destroyed** unless
`connection.Transaction.commit` ran first -- so an early return or a raised
error leaves nothing behind rather than half a block.  Savepoints are
`connection.Transaction.savepoint`, `connection.Transaction.rollback_to` and
`connection.Transaction.release`; a savepoint is how a statement that failed
inside a block is survived, because PostgreSQL otherwise refuses everything
until the block ends.  Committing a block that has already failed raises
SQLSTATE ``25P02`` rather than quietly rolling back the way the server would:

```mojo
var tx = conn.begin()
_ = tx.execute("INSERT INTO t VALUES ($1)", Params().int64(1))
tx.savepoint("maybe")
try:
    _ = tx.execute("INSERT INTO t VALUES ($1)", Params().int64(1))
except:
    tx.rollback_to("maybe")      # the duplicate is undone; the first row stays
tx.commit()
```

``COPY`` is the bulk path -- no per-row parse, plan or round trip.
`connection.Connection.copy_in` returns a `copy.CopyIn` to write rows into
(`copyfmt.CopyEncoder` produces the bytes; `copy.CopyIn.finish` returns the
row count and is where a malformed row is reported), and
`connection.Connection.copy_out` returns a `copy.CopyOut` to read them back
(`copy.CopyOut.rows` pairs with `copyfmt.decode_row`).  Both handles clean up
after themselves if dropped, so an abandoned COPY leaves a usable connection:

```mojo
var cp = conn.copy_in("COPY t (id, name) FROM STDIN")
var enc = CopyEncoder()
enc.row([Optional[String]("1"), Optional[String]("Ada")])
enc.row([Optional[String]("2"), None])          # None is SQL NULL
cp.write_rows(enc)
print(cp.finish(), "rows")                      # 2
```

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

- `postgres.connection` -- `Connection`, `Statement`, `Transaction`.
- `postgres.copy` -- `CopyIn` and `CopyOut`, the ``COPY`` stream handles.
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
from .connection import Connection, Statement, Transaction
from .copy import CopyIn, CopyOut
from .copyfmt import (
    COPY_CSV,
    COPY_TEXT,
    CopyDecoder,
    CopyEncoder,
    decode_row,
    split_rows,
)
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
