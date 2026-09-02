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

## Status

Under construction — see the milestones in
[magmalake.org/issues/1](https://magmalake.org/issues/1):

- [x] **M1** connect and query: `Connection`, text results by index and name, errors with SQLSTATE
- [x] **M2** parameters and statements: `PQexecParams`, prepared statements, the `Params` builder, the full type table
- [x] **M3** transactions and `COPY`: `Transaction` with savepoints and rollback on drop, `CopyIn`/`CopyOut`
- [ ] **M4** a Postgres-backed Iceberg catalog, in [iceberg.mojo](https://github.com/magmalake/iceberg.mojo)

## Test

```sh
pixi run test              # unit (no server) + server suite + psql/psycopg cross-check
pixi run -e stable test    # same, on Mojo 1.0.0
```

The server suite starts a throwaway PostgreSQL cluster from the conda
`postgresql` package on a free port, runs against it, and stops it. No Docker.

## License

Apache-2.0 — see [LICENSE](LICENSE) and [NOTICE](NOTICE). libpq itself is under
the [PostgreSQL License](https://www.postgresql.org/about/licence/) and is
loaded at runtime, not bundled.
