#!/bin/sh
# Runs every example under examples/, in order, against a live server.
# Driven by the `examples` pixi task, which wraps this in
# scripts/with-pg-server.sh -- a failing example aborts the run.
set -eu
cd "$(dirname "$0")/.."
for f in examples/*.mojo; do
    echo "== $f"
    mojo run -I src "$f"
done
