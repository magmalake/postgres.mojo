# postgres.mojo

[![mojoshelf](https://mojoshelf.org/badge/postgres-mojo.svg)](https://mojoshelf.org/tins/postgres-mojo) [![mojo nightly](https://mojoshelf.org/badge/postgres-mojo/nightly.svg)](https://mojoshelf.org/tins/postgres-mojo)

[![CI](https://github.com/magmalake/postgres.mojo/actions/workflows/ci.yml/badge.svg)](https://github.com/magmalake/postgres.mojo/actions/workflows/ci.yml) [![License: Apache-2.0](https://img.shields.io/badge/License-Apache--2.0-blue.svg)](LICENSE)

> Part of [**magmalake**](https://magmalake.org) — data lake building blocks in Mojo.

A PostgreSQL client for Mojo over [libpq](https://www.postgresql.org/docs/current/libpq.html):
connections, parameterized statements, typed results, transactions and `COPY`,
with errors that carry their SQLSTATE. Text format on the wire, no ORM, no
async, no pooling — a client, not a framework.

## This is a fork

This repository is a fork of
**[dvirarad/mojo-postgres](https://github.com/dvirarad/mojo-postgres) by Dvir
Arad**, Apache-2.0, and it stays Apache-2.0 with his copyright (see `NOTICE`).
The package layout, the `ConnectionConfig` builder and the first libpq symbol
inventory are his. Thank you.

**What changed here, and why.** Upstream targets Mojo 0.25.7, where FFI and
pointer APIs have since moved, and it reaches libpq through `PQexec` plus
`PQescapeLiteral` — values are escaped into SQL text, so there is no way to
bind a parameter. This fork is a rewrite on the 1.x toolchain (stable 1.0.0 and
nightly) that keeps the shape and replaces the substance: `PQexecParams` and
prepared statements instead of escaping, a process-wide libpq handle instead
of `external_call`, SQLSTATE on every error, transactions, `COPY`, and a test
suite that runs against a real server. Upstream's open issues
[#4](https://github.com/dvirarad/mojo-postgres/issues/4),
[#5](https://github.com/dvirarad/mojo-postgres/issues/5) and
[#6](https://github.com/dvirarad/mojo-postgres/issues/6) are what the
milestones below implement. The design is written up at
[magmalake.org/issues/1](https://magmalake.org/issues/1).

## Install

```sh
pixi shelf add postgres-mojo
```

Working with a coding agent? `npx skills add mojoshelf/mojoshelf --skill mojoshelf-consume --yes` teaches it to find and install tins itself — it installs the `shelf` CLI too.

That resolves the tin from [mojoshelf](https://mojoshelf.org) and adds it — along with the tins it depends on — as **pixi git source dependencies**. magmalake tins are not published to a conda channel, so `pixi add postgres-mojo` will not find them.

`libpq` comes from conda-forge as a declared dependency; the conda-forge build
links OpenSSL, so `sslmode=require` works without anything else installed.

## Why postgres.mojo

libpq is the reference PostgreSQL client library — every other client
(psycopg included) either wraps it or reimplements its wire protocol, so
binding it directly gives connections, `COPY`, and error reporting that match
what the server actually does. This tin sends parameters and reads results as
**text**, not libpq's binary format: one codec (`postgres.text`) is both
directions of the wire, and there is nothing to keep in sync between an
encoder and a separate binary decoder. It is deliberately **not** an ORM, has
no `async`, and pools nothing — one `Connection` is one `PGconn`, used from
one thread, and the caller writes the SQL. The motivating use is a
Postgres-backed Iceberg catalog (PyIceberg's `SqlCatalog`) for
[iceberg.mojo](https://github.com/magmalake/iceberg.mojo), which needs exactly
this: connect, run parameterized SQL, read typed rows, and nothing more.

## Use

Every snippet below is real code, compiled against a throwaway test server —
see [`examples/`](examples/) for the full, runnable files.

**Connect, query by name or index** (from [`examples/query_basic.mojo`](examples/query_basic.mojo)):

```mojo
    # By column name...
    var res = conn.query("SELECT id, name, note FROM qb_people ORDER BY id")
    for row in res:
        var note = "NULL" if row.is_null("note") else row.text("note")
        print(row.int64("id"), row.text("name"), note)

    # ... and by 0-based index, which works the same on a `Row` obtained
    # either way -- both ways resolve through the same column metadata.
    var first = res.row(0)
    print("by index:", first.int64(0), first.text(1))
```

**`Params`, a prepared statement, and NULL handling** (from
[`examples/params_and_statements.mojo`](examples/params_and_statements.mojo)):

```mojo
    # Preparing pays for parsing and planning once; each `execute` after
    # that sends only the name and the new parameter values.
    var ins = conn.prepare(
        "ins_event", "INSERT INTO ps_events VALUES ($1, $2, $3)"
    )
    for i in range(3):
        _ = ins.execute(
            Params()
            .int64(Int64(i))
            .float64(Float64(i) * 1.5)
            .text("row-" + String(i))
        )
    # A NULL weight, so the read side has something to distinguish from 0.0.
    _ = ins.execute(Params().int64(3).null().text("row-3"))

    var res = conn.query("SELECT id, weight, tag FROM ps_events ORDER BY id")
    for row in res:
        # `is_null` first, then the typed accessor -- calling `float64` on a
        # NULL cell raises rather than inventing a zero.
        if row.is_null("weight"):
            print(row.int64("id"), "weight=NULL", row.text("tag"))
        else:
            print(
                row.int64("id"),
                "weight=",
                row.float64("weight"),
                row.text("tag"),
            )

    # `opt_text` is the other way to read a nullable column: `None` for
    # NULL, the text otherwise, no `is_null` check needed first.
    var last = res.row(3)
    var opt = last.opt_text("weight")
    print("opt_text on the NULL row:", opt.value() if opt else "(NULL)")
```

**A transaction with a savepoint** — leaving a `with` block without calling
`commit()` rolls back; there is no implicit commit anywhere in `Transaction`
(from [`examples/transactions.mojo`](examples/transactions.mojo)):

```mojo
    # A savepoint is how a statement that fails inside a block is survived --
    # PostgreSQL otherwise refuses everything until the block ends.
    var tx = conn.begin()
    _ = tx.execute("INSERT INTO tx_accounts VALUES ($1)", Params().int64(1))
    tx.savepoint("maybe")
    try:
        _ = tx.execute("INSERT INTO tx_accounts VALUES ($1)", Params().int64(1))
    except:
        tx.rollback_to("maybe")  # the duplicate is undone; row 1 stays
    _ = tx.execute("INSERT INTO tx_accounts VALUES ($1)", Params().int64(2))
    tx.commit()

    # Leaving a `with` block WITHOUT calling commit() rolls back -- there is
    # no implicit commit anywhere in `Transaction`.
    with conn.begin() as forgotten:
        _ = forgotten.execute(
            "INSERT INTO tx_accounts VALUES ($1)", Params().int64(3)
        )
        # no commit() here
```

**`COPY` in with `CopyEncoder`, `COPY` out with `rows()` + `decode_row`**
(from [`examples/copy_roundtrip.mojo`](examples/copy_roundtrip.mojo)):

```mojo
    var cp = conn.copy_in("COPY cp_rows (id, label) FROM STDIN")
    var enc = CopyEncoder()
    for i in range(1000):
        enc.field(String(i))
        enc.field("row-" + String(i))
        enc.end_row()
        if enc.size() > 1 << 14:
            cp.write_rows(enc)  # flush whole rows as they accumulate
    cp.write_rows(enc)
    print(cp.finish(), "rows loaded")  # 1000

    var out = conn.copy_out("COPY cp_rows TO STDOUT")
    var lines = out.rows()
    print(len(lines), "rows read back")  # 1000
    var first = decode_row(lines[0], COPY_TEXT, "\t", "\\N")
    print("first row:", first[0].value(), first[1].value())
```

**Error handling** — every SQLSTATE without parsing the message by hand
(from [`examples/errors.mojo`](examples/errors.mojo)):

```mojo
    try:
        _ = conn.execute(
            "INSERT INTO err_people VALUES ($1)", Params().int64(1)
        )
    except e:
        # The SQLSTATE travels inside the message; sqlstate_of reads it back.
        print("sqlstate_of(e) =", sqlstate_of(e))
        if sqlstate_of(e) == "23505":
            print("that id is already there")

    # `last_error()` keeps the structured `PostgresError` -- severity,
    # SQLSTATE, message, detail, hint, statement -- with predicates like
    # `is_unique_violation` so no string parsing is needed.
    if conn.last_error().is_unique_violation():
        print("last_error confirms a unique violation:")
        print(" ", conn.last_error().detail)
```

## API

| Type / function | Purpose |
|---|---|
| `Connection` | One `PGconn`. `execute`, `query`, `prepare`, `begin`, `copy_in`/`copy_out`, `close`. |
| `Statement` | A server-prepared statement from `Connection.prepare`; `execute`/`query` with new params. |
| `Transaction` | The guard from `Connection.begin`; rolls back on drop unless `commit()` ran. |
| `CopyIn` / `CopyOut` | The `COPY ... FROM/TO STDIN/STDOUT` stream handles, from `copy_in`/`copy_out`. |
| `Result` / `Row` | A query's rows; `Row` is a snapshot that outlives the `Result` that produced it. |
| `Params` | A chainable builder for `$1`-style parameters, one typed method per type below. |
| `ConnectionConfig` | Typed connection fields, for callers who would rather not build a URI by hand. |
| `CopyEncoder` / `CopyDecoder` / `decode_row` / `split_rows` | The `COPY` text/CSV row codec, independent of libpq. |
| `PostgresError` / `sqlstate_of` / `sqlstate_class` | The structured error and the code constants (`UNIQUE_VIOLATION`, ...). |
| `is_unique_violation`, `is_deadlock`, `is_retryable`, ... | SQLSTATE predicates, as free functions and as `PostgresError` methods. |

### The type table

`Row`'s typed accessors do not check the column's OID — they parse the cell's
text as whatever type you asked for, and a mismatch surfaces as the codec's
own error. `Params`' builders bind the matching OID so the server needs no
cast in the SQL.

| PostgreSQL type | OID | `Row` accessor | `Params` builder | Mojo type |
|---|---:|---|---|---|
| `bool` | 16 | `.bool(col)` | `.bool(v)` | `Bool` |
| `int2` | 21 | `.int16(col)` | `.int16(v)` | `Int16` |
| `int4` | 23 | `.int32(col)` | `.int32(v)` | `Int32` |
| `int8` | 20 | `.int64(col)` | `.int64(v)` | `Int64` |
| `float4` | 700 | `.float32(col)` | `.float32(v)` | `Float32` |
| `float8` | 701 | `.float64(col)` | `.float64(v)` | `Float64` |
| `numeric` | 1700 | `.numeric(col)` | `.numeric(v)` | `String` |
| `text` | 25 | `.text(col)` | `.text(v)` | `String` |
| `varchar` | 1043 | `.text(col)` | `.text(v)` | `String` |
| `bpchar` | 1042 | `.text(col)` | `.text(v)` | `String` |
| `bytea` | 17 | `.bytea(col)` | `.bytea(v)` | `List[UInt8]` |
| `date` | 1082 | `.date_days(col)` | `.date_days(v)` | `Int32` (days since 1970-01-01) |
| `time` | 1083 | `.time_micros(col)` | `.time_micros(v)` | `Int64` (µs since midnight) |
| `timestamp` | 1114 | `.timestamp_micros(col)` | `.timestamp_micros(v)` | `Int64` (µs since epoch, no zone) |
| `timestamptz` | 1184 | `.timestamptz_micros(col)` | `.timestamptz_micros(v)` | `Int64` (**UTC** µs since epoch) |
| `uuid` | 2950 | `.uuid(col)` | `.uuid(v)` | `String` (canonical lower-case) |
| `json` | 114 | `.json(col)` | `.json(v)` | `String` (stored verbatim) |
| `jsonb` | 3802 | `.json(col)` | `.jsonb(v)` | `String` (server-normalized text) |

Notes:

- **`numeric` stays a `String`.** Coercing arbitrary-precision decimals to
  `Float64` would silently lose digits; `.numeric()` hands back exactly the
  digits the server sent, trailing zeros of the column's declared scale
  included.
- **Dates and timestamps are epoch-relative integers**, decoded with a
  proleptic-Gregorian calendar (Howard Hinnant's `days_from_civil`). An
  `infinity`/`-infinity` date or timestamp, or a `BC` year, has no encoding in
  that scheme and raises — read `Row.text()` for those instead.
- **`timestamptz` is normalized to UTC.** The server renders it in the
  session's `TimeZone` with an offset appended; the offset is applied on
  decode, so the result is the same instant regardless of session timezone.
- **`NaN`/`Infinity`/`-Infinity`** decode to and encode from the corresponding
  IEEE-754 float values, case-insensitively on decode.

### Errors

Every server error is raised as an `Error` formatted by `PostgresError`:

```text
postgres [SQLSTATE 23505] duplicate key value violates unique constraint "people_pkey"
  DETAIL: Key (id)=(1) already exists.
  SQL: INSERT INTO people VALUES ($1, $2, $3)
```

Mojo 1.x can only raise a string, so the SQLSTATE travels *inside* the
message; `sqlstate_of` reads it back out, and `Connection.last_error()` keeps
the structured `PostgresError` — severity, SQLSTATE, message, detail, hint,
statement — with its `is_unique_violation`-style predicates. Two SQLSTATEs are
synthesized rather than sent by the server: `08001` for a `Connection` that
never came up, `08006` for one that was open and then closed or lost — both
match what class `08` means to every other PostgreSQL client. Committing a
transaction block that has already failed raises `25P02` rather than quietly
rolling back the way PostgreSQL itself would: `Transaction.commit` issues the
`ROLLBACK` itself first, so the connection is left clean, but the outcome is
*reported* instead of hidden.

## Ownership

A `Statement`, `Transaction`, `CopyIn` and `CopyOut` **co-own** the connection
they were made from — they hold a share of the same `PGconn`, not a borrow of
the `Connection` value — so the session stays open for as long as any of them
lives, even after the `Connection` that made them has gone out of scope
(Mojo destroys a value after its last *use*, so this is the ordinary case, not
an exotic one). `Connection.close()` is the exception: it ends the session
immediately, whoever else is still holding it, and every handle then raises
SQLSTATE `08006` on its next call rather than reaching a freed `PGconn`.

## Performance

Four benchmarks over `(id int8, price numeric(12,4), qty int4, label text)`,
through the shared harness ([bench.mojo](https://github.com/magmalake/bench.mojo)):

| Benchmark | Rate | What it measures |
|---|---:|---|
| `COPY ... FROM STDIN`, 100k rows | 5.46 M rows/s (≈167 MB/s) | The bulk load path |
| `SELECT`, 100k rows scanned | 2.29 M rows/s | Decoding `int8` + `numeric` + `text` per row |
| Prepared `INSERT`, 10k round trips | 54.8 K rows/s | One parse/plan, many single-row round trips |
| `SELECT ... WHERE id = $1`, 10k lookups | 34.0 K rows/s | The same round trip plus a parse and a plan each time |

```sh
pixi run -e bench bench
```

Measured on an Apple M4, PostgreSQL 18.4 on loopback with `fsync=off` and
`synchronous_commit=off` (`scripts/pg-server.sh`'s throwaway cluster) — best
case for the client, since there is no network and no disk flush. These are
the baseline a future binary-format decision (spec §9) will be measured
against: text format's known cost is exactly what a `numeric` column in the
scan benchmark pays for, arriving as digits and staying a `String`.

## Test

```sh
pixi run test              # unit + server + crosscheck
pixi run -e stable test    # same, on Mojo 1.0.0
pixi run examples          # every examples/*.mojo file, against a live server
```

- **149 unit tests** (`pixi run unit`, no server) — config rendering, SQLSTATE
  parsing, the text-format codec (including a 4,321-day date sweep and every
  `timestamptz` offset spelling), the `Params` builder, the `COPY` encoder and
  decoder, and a `PQlibVersion()` call proving libpq loads from
  `$CONDA_PREFIX`.
- **42 server tests** (`pixi run server`, starts a throwaway cluster) — every
  type round-tripped through `Params` and decoded from a server-side cast,
  NULL vs. empty string, transactions and savepoints, `COPY` in both
  directions and both sub-formats, every error path, and ownership: a
  `Transaction`, `Statement` and `CopyOut` each outliving the `Connection`
  they came from, and `Connection.close()` invalidating every handle type
  with SQLSTATE `08006`.
- **The psql/psycopg cross-check** (`tests/crosscheck.sh`, part of `server`) —
  the same eighteen-column fixture (every type in the table above, a NULL row,
  an empty/zero/epoch row, and two edge rows covering int min/max,
  `NaN`/`Infinity`/`-Infinity`, `0001-01-01`/`9999-12-31`, non-UTC
  `timestamptz` offsets, and non-ASCII/tab/newline/quote/backslash text)
  written **by this tin** (both the `Params` path and the `CopyIn` path) and
  read back cell-for-cell by psycopg 3; and the mirror image, written by
  psycopg with native Python types and read back by `Row`'s typed accessors,
  cross-checked a third way against `psql ... COPY ... TO STDOUT` of the same
  table.

The server suite and the cross-check start a throwaway PostgreSQL cluster from
the conda `postgresql` package on a free port and stop it on exit. No Docker.

## Scope

In scope: connections, `$n` parameters, prepared statements, typed text-format
results, transactions with savepoints, `COPY` (text and CSV), and SQLSTATE on
every error.

Out of scope: an ORM or query builder, `async`, connection pooling,
`LISTEN`/`NOTIFY`, and binary-format results or parameters (§9's open
question — the [Performance](#performance) numbers above are the baseline it
will be measured against). A `NOTICE`/`WARNING` the server raises is printed
to stderr by libpq's default handler, which this tin installs no override
for; pass `options=-c client_min_messages=warning` in the conninfo to quiet
it.

## Status

- [x] **M1** connect and query: `Connection`, text results by index and name, errors with SQLSTATE
- [x] **M2** parameters and statements: `PQexecParams`, prepared statements, the `Params` builder, the full type table
- [x] **M3** transactions and `COPY`: `Transaction` with savepoints and rollback on drop, `CopyIn`/`CopyOut`
- [ ] **M4** a Postgres-backed Iceberg catalog, in [iceberg.mojo](https://github.com/magmalake/iceberg.mojo)

## License

Apache-2.0 — see [LICENSE](LICENSE) and [NOTICE](NOTICE). libpq itself is under
the [PostgreSQL License](https://www.postgresql.org/about/licence/) and is
loaded at runtime, not bundled.
