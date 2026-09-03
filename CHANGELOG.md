# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://github.com/magmalake/postgres.mojo/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/dvirarad/mojo-postgres/releases/tag/v0.1.0
