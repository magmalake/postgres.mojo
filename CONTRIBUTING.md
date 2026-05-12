# Contributing

Thanks for considering a contribution. `mojo-postgres` is small and the bar for getting changes in is "does it move the alpha closer to a stable v0.1".

## Areas where help is especially welcome

- **Parameterized queries.** Today `Connection.query()` is single-string; we need a `query_params(sql, params)` wrapping `PQexecParams` so callers don't build SQL by hand.
- **Typed error kind.** `PostgresError.code` is the raw `ExecStatusType` int. A `enum PostgresErrorKind` (or at least helpers like `is_unique_violation()`, `is_serialization_failure()`) parsing SQLSTATE codes would be nicer to pattern-match against.
- **COPY streaming.** `PQputCopyData` / `PQgetCopyData` aren't wrapped yet. Huge perf win for bulk loads / dumps.
- **Connection pooling.** A small `ConnectionPool` over a `List[Connection]` with checkout/return semantics — the obvious next step for any real workload.
- **Async / `LISTEN`/`NOTIFY`.** `PQsendQuery` + `PQconsumeInput` + `PQnotifies` give us push-driven workflows without polling.

## Workflow

1. Fork, branch off `main`.
2. Run `pixi run test` locally — keep smoke tests green.
3. If you change the public API, update `README.md` and `examples/`.
4. Open a PR. Small focused PRs > big ones.

## Style

- Prefer Mojo stdlib types over custom ones.
- Keep `_ffi.mojo` the only file that touches `external_call`.
- One public symbol per concept (`Connection`, not `PgConnection` — the module already says `postgres`).
