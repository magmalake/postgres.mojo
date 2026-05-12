# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://github.com/dvirarad/mojo-postgres/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/dvirarad/mojo-postgres/releases/tag/v0.1.0
