# Architecture

This is the longer write-up on how `mojo-postgres` is layered. Read [`README.md`](../README.md) first for the usage story; this document is for contributors and people considering the FFI design.

## Layers

```
┌────────────────────────────────────────────────────────┐
│  user code (Mojo / MAX)                                │
│     from postgres import Connection, ConnectionConfig  │
├────────────────────────────────────────────────────────┤  ← public Mojo surface
│  Pythonic Mojo API                                     │
│     src/postgres/__init__.mojo                         │
│     src/postgres/{connection,result,config}.mojo       │
├────────────────────────────────────────────────────────┤  ← `external_call`
│  raw FFI surface                                       │
│     src/postgres/_ffi.mojo                             │
├────────────────────────────────────────────────────────┤  ← C ABI
│  libpq.so / .dylib       (PostgreSQL License)          │
└────────────────────────────────────────────────────────┘
```

Each arrow is a contract. The Mojo layer hides everything underneath — users see typed `struct`s and Mojo exceptions, not `OpaquePointer`s or `ExecStatusType` ints.

## Why `libpq`

It's the C foundation under almost every non-JVM Postgres client (`psycopg`, `node-postgres` via libpq mode, `lib/pq` historically, Rust's `tokio-postgres` shares wire-format ancestry with it). That means:

- The wire protocol, authentication (SCRAM, GSS, certificate), TLS, and `COPY` paths are battle-tested.
- Behavior on connection loss, server upgrade, and reconnect matches what production Postgres users expect.
- We inherit the documentation, the bug fixes, and the PostgreSQL Global Development Group's release discipline.

Writing the Postgres wire protocol from scratch in Mojo would be more "native" but would either take years or be subtly broken on real clusters. We chose battle-tested over native.

## Why a Pythonic Mojo API

Mojo's superpower is being Python-like. Two consequences:

1. The audience most likely to pick this up is Python data / ML engineers — `psycopg`'s API is the one they know.
2. Mojo has direct syntactic support for Python-style `class`-like usage via `struct`. Mirroring the Python API costs little and lowers the learning curve to ~zero.

We diverge from `psycopg` only where:
- Mojo's lack of `**kwargs` would make a Python-style call awkward (we use explicit fields on `ConnectionConfig`).
- Mojo's resource management (`__del__`) lets us drop the explicit `del cursor` / `del conn` dance.

## FFI design: `_ffi.mojo`

This file declares every `libpq` symbol we call. Each declaration looks like:

```mojo
fn PQexec(conn: OpaquePointer, query: String) -> OpaquePointer:
    return external_call[
        "PQexec", OpaquePointer, OpaquePointer, UnsafePointer[Int8]
    ](conn, query.unsafe_cstr_ptr())
```

Two rules we follow rigidly:

1. **One `external_call` per symbol.** No higher-level conveniences here. The point of this layer is auditability — anyone tracing libpq documentation should be able to find the corresponding declaration verbatim.
2. **Mojo types only.** No `__init__`, no methods. Lifetime is the caller's problem at this layer. The `Connection` / `Result` structs above own the lifetimes.

## Lifetime story

Every `libpq` resource has a paired constructor and destructor. The Mojo wrappers tie those to Mojo's RAII:

- `Connection.__init__` calls `PQconnectdb(conninfo)` and stores the resulting `PGconn*` as `OpaquePointer`. If status is not `CONNECTION_OK`, we `PQfinish` and raise.
- `Connection.__del__` calls `PQfinish`.
- `Result.__init__` takes ownership of a `PGresult*`.
- `Result.__del__` calls `PQclear` so callers never have to.

`ConnectionConfig.to_conninfo()` just renders to a libpq conninfo string — libpq owns parsing and validation.

## Error mapping

libpq returns errors in two places: connection-level (`PQstatus` + `PQerrorMessage`) and per-result (`PQresultStatus` + `PQresultErrorMessage`). We:

1. Check `PQstatus` after `PQconnectdb` and raise on `CONNECTION_BAD`.
2. Check `PQresultStatus` after every `PQexec` and raise on anything other than `PGRES_COMMAND_OK` or `PGRES_TUPLES_OK`.
3. Wrap the message + status into our `PostgresError(code: Int32, message: String)` and `raise`.

The roadmap is to expose a typed `PostgresErrorKind` enum keyed on the [SQLSTATE](https://www.postgresql.org/docs/current/errcodes-appendix.html) class so users can `match` on `unique_violation` / `serialization_failure` / etc. instead of comparing magic numbers — see [#5](https://github.com/dvirarad/mojo-postgres/issues/5).

## conninfo rendering

libpq accepts either a connection URI (`postgresql://user:pass@host:port/db`) or keyword-value pairs (`host=... port=... dbname=...`). We render the keyword form because:

- Each field is independently typed in `ConnectionConfig`, so we don't have to URL-encode anything.
- Values containing whitespace or single quotes get wrapped in single quotes with backslash-escaped specials — `_escape_conninfo_value` in `config.mojo`.

## What we do *not* do

- We don't ship `libpq` itself. We dynamic-link against whatever the user provides (system package, conda-forge, or vendored).
- We don't implement `PQexecParams` parameter binding yet — that's [#4](https://github.com/dvirarad/mojo-postgres/issues/4).
- We don't expose libpq's async API (`PQsendQuery` / `PQconsumeInput`). The Mojo idiom is a synchronous call; we lean into that for v0.1.
- We don't pool connections. That's [#3](https://github.com/dvirarad/mojo-postgres/issues/3).

## Testing strategy

- **Smoke tests** (`tests/test_smoke.mojo`) — load libpq, build configs, render conninfo strings. No server required; catches FFI breakage and obvious memory issues.
- **Examples** — runnable against `postgres:16` for end-to-end verification.
- **Lint** — `mojo format` over `src/`, `examples/`, `tests/`, with `git diff --exit-code` as the drift gate.

All of these gate every PR. See `.github/workflows/ci.yml`.
