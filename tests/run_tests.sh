#!/bin/sh
# The server suite: everything that needs a live PostgreSQL. Starts a
# throwaway cluster via with-pg-server.sh (which exports POSTGRES_TEST_DSN
# and tears the server down on exit, or skips cleanly if it can't start one
# at all), then runs three checks:
#
#   (a) a plain `psql -c 'select 1'` — proves the whole start/connect flow
#       works, independent of anything this tin builds.
#   (b) tests/server_test.mojo, if it exists yet (a later work item) — the
#       FFI-level server suite (connect, query, COPY, transactions...).
#   (c) tests/crosscheck.sh, if it exists yet (a later work item) — the
#       psql/psycopg cross-check oracle.
#
# (b) and (c) are written by other agents in parallel; until they land this
# script still runs cleanly and says so.
set -eu
cd "$(dirname "$0")/.."

sh scripts/with-pg-server.sh sh -c '
    set -eu

    echo "== select 1"
    result="$(psql "$POSTGRES_TEST_DSN" -Atc "select 1")"
    if [ "$result" != "1" ]; then
        echo "!! expected 1, got: $result" >&2
        exit 1
    fi
    echo "$result"

    if [ -f tests/server_test.mojo ]; then
        echo "== building tests/server_test.mojo"
        mkdir -p build
        mojo build tests/server_test.mojo -I src -o build/server-test
        echo "== running server-test"
        ./build/server-test
    else
        echo "== tests/server_test.mojo not present yet; skipping"
    fi

    if [ -f tests/crosscheck.sh ]; then
        echo "== running tests/crosscheck.sh"
        sh tests/crosscheck.sh
    else
        echo "== tests/crosscheck.sh not present yet; skipping"
    fi
'
