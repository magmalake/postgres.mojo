# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

Forked into [magmalake/postgres.mojo](https://github.com/magmalake/postgres.mojo)
and rewritten for the Mojo 1.x toolchain (stable 1.0.0 + nightly); published to
[mojoshelf](https://mojoshelf.org/tins/postgres-mojo) as `postgres-mojo` 0.2.0.

### Changed
- libpq is `dlopen`ed once per process from `$CONDA_PREFIX` (`OwnedDLHandle`
  with `RTLD_NODELETE`) instead of resolved through `external_call`.
- `Connection.query` / `execute` take a `Params` builder and go through
  `PQexecParams`; `PQescapeLiteral` is gone (#4).
- Errors carry the SQLSTATE (#5).

### Added
- Named prepared statements, transactions with savepoints, `COPY` in and out (#6).
- Typed result access per column OID; NULL distinct from empty.
- Tests against a real server started from the conda `postgresql` package, and
  a cell-exact cross-check against `psql` and `psycopg`.

### Removed
- `ml_pipeline.mojo` example, `docs/ARCHITECTURE.md`, and the upstream
  repository-hygiene files (CODEOWNERS, FUNDING, Dependabot, CodeQL, SECURITY).

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
