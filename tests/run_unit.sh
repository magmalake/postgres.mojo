#!/bin/sh
# Build and run every server-free suite: tests/test_*.mojo, one binary each.
# Each file is self-contained (its own main()) so modules can be developed and
# tested independently; a failing build or run aborts with that file's name.
set -eu
cd "$(dirname "$0")/.."
mkdir -p build
status=0
for f in tests/test_*.mojo; do
    name=$(basename "$f" .mojo)
    echo "== $name"
    if ! mojo build "$f" -I src -o "build/$name"; then
        echo "!! build failed: $f"; status=1; continue
    fi
    if ! "./build/$name"; then
        echo "!! FAILED: $f"; status=1
    fi
done
# Again with CONDA_PREFIX unset, as from a plain shell: libpq must then be
# found through the binary's rpath (src/postgres/_dlopen.mojo).
for name in test_dlopen test_ffi; do
    echo "== $name (no CONDA_PREFIX)"
    if ! env -u CONDA_PREFIX "./build/$name"; then
        echo "!! FAILED without CONDA_PREFIX: $name"; status=1
    fi
done
exit $status
