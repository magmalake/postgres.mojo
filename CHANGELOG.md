# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- `postgres.pool` -- a connection pool for a long-lived, multi-threaded
  service: `ConnectionPool`, `PoolConfig`, `PoolStats`, `PoolRef` and `Lease`.
  Lazy growth to `max_size` with `min_idle` kept warm, blocking checkout on a
  real `pthread_cond_t` (no spin) bounded by `acquire_timeout_ms`, `ROLLBACK`
  on a dirty return (`DISCARD ALL` opt-in), and `max_lifetime_ms` /
  `max_idle_ms` recycling so a failover is recovered from rather than held
  through. Not re-exported from `postgres`: import it as
  `from postgres.pool import ...`.
- **The lease is the safety property.** `Statement`, `Transaction`, `CopyIn`
  and `CopyOut` share the connection's `PGconn`, so one that outlived its
  `with` block would become two threads on one `PGconn` once the connection
  was pooled. `Lease` reads the share count when the lease ends and *closes*
  such a connection instead of pooling it, counting it in `stats().escaped`;
  the escapee then gets SQLSTATE `08006`. `tests/run_pool.sh` builds that
  assertion a second time against a copy of the pool with the check removed,
  and fails unless it fails.
- `Connection.is_alive()` -- liveness with no round trip. `PQstatus` is a
  cached opinion and still reads `CONNECTION_OK` after a backend is killed by
  `pg_terminate_backend`; this consumes what the server already sent and sees
  the death. It is what `PoolConfig.validate_on_checkout` uses.
- `Connection.reset()` (reconnect in place: same handle, new session) and
  `Connection.backend_pid()`.
- `PQisthreadsafe`, `PQreset`, `PQconsumeInput` and `PQbackendPID` bound in
  `postgres._ffi`. `ConnectionPool` refuses to build on a libpq without thread
  safety rather than pretending it is safe.
- SQLSTATE constants `CONNECTION_DOES_NOT_EXIST` (`08003`, a lease taken after
  `close()`) and `TOO_MANY_CONNECTIONS` (`53300`, `acquire_timeout_ms`
  elapsed).
- **A lease may outlive the pool value**, and holds the last share of the
  pool's state when it does -- which is the ordinary case, since Mojo destroys
  a value at its last use and `pool.lease()` is often the last mention of the
  pool. Every critical section therefore lives in a function that takes the
  state as a *borrowed* argument, so the mutex cannot be freed before its own
  unlock. `test_a_lease_may_outlive_the_pool_value` pins it, a hundred times
  over, because the failure it guards against is a silent few-byte write into
  freed heap that surfaces as a crash somewhere else entirely.
- `pixi run pool` -- the pool suite (22 tests: concurrent checkout with
  per-session exclusivity assertions, exhaustion and timeout, a backend killed
  with `pg_terminate_backend`, dirty-return rollback, escape detection,
  `close()` with leases outstanding) plus the negative control.

### Changed
- `threads-mojo` is a new dependency, pinned at the revision published as
  0.4.0. Only `postgres.pool` needs it, which is why that module is not
  re-exported from the package root.

### Known issues
- `postgres.pool` builds on the **stable** toolchain only: a `.mojopkg` is
  readable only by the compiler version that built it, and tins are built with
  mojo 1.0.0, so `from threads import ...` does not resolve under the nightly.
  `tests/run_pool.sh` detects that and skips with a reason rather than
  failing. Nothing else in the tin is affected; the rest still builds and
  tests on both toolchains.

## [0.2.0] — 2026-09-02

### Added
- `Connection`, `Statement`, `Transaction`, `CopyIn`/`CopyOut`, `Result`/`Row`,
  `Params` and `ConnectionConfig` -- connect, parameterized `query`/`execute`,
  named prepared statements, transactions with savepoints and rollback on
  drop, and `COPY` in both directions and both sub-formats (text and CSV)
  (#4, #5, #6).
- The full §5 type table: typed `Row` accessors and `Params` builders for
  `bool`, `int2`/`int4`/`int8`, `float4`/`float8` (including
  `NaN`/`Infinity`/`-Infinity`), `numeric` (kept a `String` -- see
  [README](README.md#the-type-table)), `text`/`varchar`/`bpchar`, `bytea`,
  `date`/`time`/`timestamp`/`timestamptz` (epoch-relative integers,
  `timestamptz` normalized to UTC), `uuid`, and `json`/`jsonb`.
- Every server error raised with its SQLSTATE (`PostgresError`, `sqlstate_of`,
  the code constants and predicates like `is_unique_violation`), plus
  `Connection.last_error()` for the structured form.
- `postgres.copyfmt` -- the COPY text/CSV row codec (`CopyEncoder`,
  `CopyDecoder`, `decode_row`, `split_rows`), independent of libpq and usable
  without a server.
- A live test suite (149 unit tests, 42 server tests) against a throwaway
  PostgreSQL cluster started from the conda `postgresql` package, a benchmark
  suite (`bench/bench_postgres.mojo`), and a cell-exact psql/psycopg
  cross-check in both directions (`tests/crosscheck.sh`).

### Changed
- Forked into [magmalake/postgres.mojo](https://github.com/magmalake/postgres.mojo)
  and rewritten for the Mojo 1.x toolchain (stable 1.0.0 + nightly); published
  to [mojoshelf](https://mojoshelf.org/tins/postgres-mojo) as `postgres-mojo`.
- libpq is `dlopen`ed once per process from `$CONDA_PREFIX` (`OwnedDLHandle`
  with `RTLD_NODELETE`) instead of resolved through `external_call`.
- `Connection.query`/`execute` take a `Params` builder and go through
  `PQexecParams`, so values are sent out of band rather than escaped into the
  SQL text -- there is nothing to escape and no injection surface.
- **Ownership rule**: a `Statement`, `Transaction`, `CopyIn` and `CopyOut`
  co-own the connection through a shared, refcounted cell rather than
  borrowing the `Connection` -- the session stays open for as long as any of
  them lives, even after the `Connection` value that made them has gone out
  of scope. `Connection.close()` is the exception: it invalidates all of them
  at once, and every later call on one raises SQLSTATE `08006`.

### Removed
- The `PQescapeLiteral`-based API: values are no longer escaped into SQL
  text; every parameter now goes out through `PQexecParams`/`PQexecPrepared`
  (#4).
- `ml_pipeline.mojo` example, `docs/ARCHITECTURE.md`, and the upstream
  repository-hygiene files (CODEOWNERS, FUNDING, Dependabot, CodeQL, SECURITY).

### Compatibility

PostgreSQL 16-18 servers, conda-forge `libpq` 16-18, Mojo 1.0.0 and nightly.

### Known limitations
- Toolchain: a `String` captured by a parametric closure (`@parameter def`
  passed as a `def[f: def() capturing raises -> None]()` parameter -- the
  shape `vectorize` and the bench harness take) is read with a corrupt length
  at `-O1` and above ([modular/modular#7070](https://github.com/modular/modular/issues/7070)).
  `Statement.execute`/`query` copy the statement name before handing it to
  libpq, which is enough on Mojo 1.0.0. On the 1.1.0 nightly the captured
  value is already corrupt when the copy is made, so a `Statement` captured by
  such a closure can still abort there -- take the `Statement` as a closure
  *argument*, or call it outside the closure, until the fix lands.

## [0.1.0] — 2026-05-12

Initial public alpha.

### Added
- `Connection` / `ConnectionConfig` — typed connection over `PGconn` with `query()`, `close()`, `is_open()`.
- `Result` — row/column accessors (`nrows()`, `ncols()`, `value(row, col)`, `column_name(col)`, `is_null(row, col)`, `rows_affected()`); RAII over `PGresult*`.
- `PostgresError` wrapping libpq error message + status code.
- Examples: `query_basic.mojo`, `insert_basic.mojo`, `ml_pipeline.mojo`.
- CI: format check + env-check matrix on Linux + macOS (verifies `libpq-fe.h` is on the include path).
- Project hygiene: `LICENSE` (Apache-2.0), `SECURITY.md`, `CONTRIBUTING.md`, `CODEOWNERS`, issue / PR templates, Dependabot for GitHub Actions, CodeQL scanning.

### Known limitations
- No parameter binding yet — callers must build SQL by hand (#4).
- No typed `PostgresErrorKind` enum — error codes are raw `Int32` (#5).
- No `COPY` streaming (#6).
- No connection pooling (#3).

[Unreleased]: https://github.com/magmalake/postgres.mojo/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/magmalake/postgres.mojo/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/dvirarad/mojo-postgres/releases/tag/v0.1.0
