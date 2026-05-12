<div align="center">

# mojo-postgres

**PostgreSQL client for [Mojo🔥](https://www.modular.com/mojo) — backed by [`libpq`](https://www.postgresql.org/docs/current/libpq.html).**

Talk to Postgres straight from your Mojo / MAX inference loop. No Python hop, no GIL on the hot path.

[![CI](https://github.com/dvirarad/mojo-postgres/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/dvirarad/mojo-postgres/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/dvirarad/mojo-postgres?include_prereleases&sort=semver&label=release)](https://github.com/dvirarad/mojo-postgres/releases)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue)](LICENSE)
[![Mojo](https://img.shields.io/badge/Mojo-0.25.x-orange)](https://docs.modular.com/mojo/)
[![libpq](https://img.shields.io/badge/libpq-%E2%89%A516-336791)](https://www.postgresql.org/docs/current/libpq.html)
[![Status](https://img.shields.io/badge/status-alpha-yellow)](#status)

</div>

---

## Why this exists

Mojo's pitch is *"Python ergonomics, systems performance, AI-native."* The place that pitch meets the real world is the **data layer** — and most ML pipelines today pull features, labels, or config from Postgres.

If you want a Postgres table feeding a Mojo model today, your options are:

1. **Hop through Python** with `psycopg2` / `psycopg` — every row pays a Python ↔ Mojo FFI tax, plus you're back in GIL territory.
2. **Hand-roll `libpq` bindings** yourself — possible, but it's a lot of opaque pointers and `PGresult*` lifetimes.

`mojo-postgres` is **option 3**: a Mojo-idiomatic, Pythonic API over the same `libpq` C foundation that every non-JVM Postgres client (Go, Rust, Python, Node, .NET) is already built on. Familiar shape, native perf, no FFI tax per row.

```mojo
from postgres import Connection, ConnectionConfig

fn main() raises:
    var conn = Connection(ConnectionConfig(
        host="localhost",
        dbname="features",
        user="reader",
        password="hunter2",
    ))
    var res = conn.query("SELECT id, embedding FROM users WHERE active")
    for row in range(res.nrows()):
        run_inference(res.value(row, 1))    # straight into your Mojo / MAX model
```

## Install

`mojo-postgres` depends on `libpq` at runtime. Recommended: let `pixi` handle everything.

```toml
# pixi.toml
[workspace]
channels = ["https://conda.modular.com/max", "conda-forge"]
platforms = ["linux-64", "osx-arm64"]

[dependencies]
max = "==25.7.0"
mojo = "==0.25.7.0"
libpq = ">=16.0"
```

Then add `mojo-postgres` as a Mojo dependency (vendor the package, or pull `src/postgres/` into your tree — it's small and dependency-free on the Mojo side):

```bash
git clone https://github.com/dvirarad/mojo-postgres.git
cp -r mojo-postgres/src/postgres your_project/src/
```

Prefer system packages? `libpq` is widely available:

```bash
brew install libpq                      # macOS
sudo apt install libpq-dev              # Debian / Ubuntu
sudo dnf install libpq-devel            # Fedora
```

## Quickstart

### Query

```mojo
from postgres import Connection, ConnectionConfig

fn main() raises:
    var conn = Connection(ConnectionConfig(
        host="localhost",
        dbname="postgres",
        user="postgres",
        password="postgres",
    ))
    var res = conn.query("SELECT id, name FROM users LIMIT 10")
    for row in range(res.nrows()):
        print(res.value(row, 0), res.value(row, 1))
```

### Insert

```mojo
var ins = conn.query("INSERT INTO events (name) VALUES ('signup')")
print(ins.rows_affected(), "row(s) inserted")
```

### Inspect columns

```mojo
var res = conn.query("SELECT * FROM users LIMIT 1")
for col in range(res.ncols()):
    print(res.column_name(col))
```

See [`examples/`](examples/) for runnable scripts, including [`examples/ml_pipeline.mojo`](examples/ml_pipeline.mojo) — a streaming feature pipeline that pulls rows from Postgres and feeds them into a tensor.

## API surface (v0.1)

| Symbol | What it does |
|---|---|
| `Connection` / `ConnectionConfig` | Open a connection, run statements, close |
| `Result` | Row/column access via `nrows()`, `ncols()`, `value(row, col)`, `column_name(col)`, `is_null(row, col)`, `rows_affected()` |
| `PostgresError` | Raised with libpq status code + human description |
| `libpq_version()` | Loaded libpq version (for diagnostics) |

The full configuration surface mirrors libpq's [conninfo parameters](https://www.postgresql.org/docs/current/libpq-connect.html#LIBPQ-PARAMKEYWORDS) — under-the-hood, `ConnectionConfig` translates its typed fields into a conninfo string, so anything libpq supports is reachable.

## Architecture

```
┌─────────────────────────────────────────────────────┐
│  your Mojo / MAX code                               │
│                                                     │
│  from postgres import Connection, ConnectionConfig  │
└────────────────────┬────────────────────────────────┘
                     │  Pythonic Mojo API
┌────────────────────▼────────────────────────────────┐
│  src/postgres/{connection,result,config}.mojo       │
│  typed structs, lifetime management, error mapping  │
└────────────────────┬────────────────────────────────┘
                     │  external_call[...]
┌────────────────────▼────────────────────────────────┐
│  src/postgres/_ffi.mojo                             │
│  raw libpq symbol declarations                      │
└────────────────────┬────────────────────────────────┘
                     │  C ABI
┌────────────────────▼────────────────────────────────┐
│  libpq.so / .dylib       (PostgreSQL License)       │
└─────────────────────────────────────────────────────┘
```

See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for the longer write-up on FFI lifetimes and the `PGconn` / `PGresult` story.

## Status

**Alpha.** `v0.1.0` is the first public release. The FFI layer binds real `libpq` symbols and smoke tests pass against `libpq` 16+. Expect:

- API shape may still shift in `v0.2`.
- A few rough edges are tracked as [`good first issue`](https://github.com/dvirarad/mojo-postgres/labels/good%20first%20issue) — including [parameterized queries via `PQexecParams`](https://github.com/dvirarad/mojo-postgres/issues/4), [a typed `PostgresErrorKind`](https://github.com/dvirarad/mojo-postgres/issues/5), [`COPY` streaming](https://github.com/dvirarad/mojo-postgres/issues/6), and [connection pooling](https://github.com/dvirarad/mojo-postgres/issues/3).

Use it in spikes and prototypes today. Wait for `v1.0` before betting a production pipeline.

## Roadmap

- **v0.2** — `PQexecParams` parameter binding, typed `PostgresErrorKind`, `Result` iterator protocol.
- **v0.3** — `COPY FROM` / `COPY TO` streaming, prepared statements, `NOTIFY`/`LISTEN`.
- **v0.4** — Connection pooling, tensor-zero-copy result accessors (`UnsafePointer` row views for MAX tensors).
- **v1.0** — API stable; feature parity with `psycopg3`'s sync surface.

Feature requests go in the [issue tracker](https://github.com/dvirarad/mojo-postgres/issues). Comment with a 👍 to vote.

## Contributing

We protect `main` — contributions land via PR with passing CI and a review from a maintainer. See [`CONTRIBUTING.md`](CONTRIBUTING.md) for the full guide, but the short version is:

1. Fork & branch.
2. `pixi install`
3. Make your change; add a test in `tests/` if behavior changes.
4. `pixi run lint && pixi run test`
5. Open a PR. CI must be green.

Interesting layers if you're new:

- [`src/postgres/_ffi.mojo`](src/postgres/_ffi.mojo) — raw `libpq` symbol declarations.
- [`src/postgres/config.mojo`](src/postgres/config.mojo) — typed config builder over libpq conninfo strings.
- [`src/postgres/{connection,result}.mojo`](src/postgres/) — public API.

Security issues? See [`SECURITY.md`](SECURITY.md) — please **don't** open a public issue for a CVE-shaped thing.

## License

Apache 2.0 — see [`LICENSE`](LICENSE). `libpq` itself is under the [PostgreSQL License](https://www.postgresql.org/about/licence/) and is dynamically linked, not bundled or redistributed.

## Acknowledgments

- The PostgreSQL Global Development Group's [`libpq`](https://www.postgresql.org/docs/current/libpq.html) — the C client this whole project stands on.
- [`psycopg`](https://www.psycopg.org/) — API shape we tried to honor.
- The Modular team, for [Mojo🔥](https://www.modular.com/mojo) and a C FFI that makes wrappers like this possible.
