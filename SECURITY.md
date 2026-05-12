# Security Policy

## Reporting a Vulnerability

If you find a security issue in `mojo-postgres` — particularly anything that could allow SQL injection through the wrapper, memory corruption via the FFI layer, or credential leakage through misconfigured TLS — please **do not** open a public issue.

Instead, use GitHub's private vulnerability reporting:

1. Go to https://github.com/dvirarad/mojo-postgres/security/advisories/new
2. Describe the issue with a minimal repro.
3. Expect an acknowledgment within 72 hours.

For non-security bugs, regular issues are the right place.

## Scope

In scope:

- Anything inside `src/postgres/` that talks to `libpq`.
- Examples that mishandle untrusted input.

Out of scope:

- Vulnerabilities in `libpq` / PostgreSQL itself — report those upstream at https://www.postgresql.org/support/security/.
- Vulnerabilities in user code that happens to import `mojo-postgres`.
