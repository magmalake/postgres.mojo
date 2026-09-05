#!/bin/sh
# The pool suite, plus the negative control that proves its sharpest
# assertion can fail.
#
# Run under `scripts/with-pg-server.sh`, which starts a throwaway cluster and
# exports $POSTGRES_TEST_DSN. `pixi run pool` does that for you.
#
# Two things here are not in tests/run_tests.sh:
#
#   (a) The toolchain gate. `postgres.pool` imports the threads-mojo tin,
#       which arrives as a .mojopkg compiled by mojo 1.0.0 — and a Mojo
#       package is only readable by the compiler version that built it. On the
#       nightly toolchain the import simply does not resolve, so this skips
#       with a reason instead of failing, exactly as with-pg-server.sh skips a
#       machine that cannot start PostgreSQL. The `stable` environment is
#       where the pool is actually exercised, and CI runs both.
#
#   (b) The negative control. tests/pool_escape_control.mojo is built a second
#       time against a copy of src/ with the refcount check removed, and this
#       script fails unless that copy *fails*. An escape that goes undetected
#       is a silent race rather than a visible error, so the one assertion
#       standing between the pool and that outcome has to be shown to have
#       teeth rather than merely to be green.
set -eu
cd "$(dirname "$0")/.."

mkdir -p build
INCLUDES="-I src -I $CONDA_PREFIX/lib/mojo"

# -- (a) can this toolchain read the threads-mojo package at all? ------------
cat > build/pool-toolchain-probe.mojo <<'EOF'
from threads import num_cpus
def main() raises:
    print(num_cpus())
EOF
if ! mojo build build/pool-toolchain-probe.mojo $INCLUDES \
        -o build/pool-toolchain-probe >build/pool-toolchain-probe.log 2>&1
then
    echo "== pool tests: skipped — this toolchain cannot read the threads-mojo"
    echo "   package (a .mojopkg is readable only by the compiler that built"
    echo "   it, and tins are built with mojo 1.0.0). Run \`pixi run -e stable"
    echo "   pool\`."
    exit 0
fi

# -- the suite ---------------------------------------------------------------
echo "== building tests/pool_test.mojo"
mojo build tests/pool_test.mojo $INCLUDES -o build/pool-test
echo "== running pool-test"
./build/pool-test

# -- (b) the negative control ------------------------------------------------
echo "== building the escape control against src/"
mojo build tests/pool_escape_control.mojo $INCLUDES -o build/pool-escape-control
echo "== running the escape control (must pass)"
./build/pool-escape-control

echo "== building the escape control against a pool with the check removed"
broken=build/pool-broken-src
rm -rf "$broken"
mkdir -p "$broken"
cp -R src/postgres "$broken/postgres"

# The check itself, and nothing else: `Lease.__deinit__` asks the connection
# how many things are holding it, and a constant 1 is what "no check" means.
sed 's|var shares = self\._conn\._shares()|var shares = 1  # negative control|' \
    src/postgres/pool.mojo > "$broken/postgres/pool.mojo"

if ! grep -q '# negative control' "$broken/postgres/pool.mojo"; then
    echo "!! the negative control could not patch out the refcount check;" >&2
    echo "   Lease.__deinit__ no longer matches the pattern in this script," >&2
    echo "   so the control proves nothing. Fix the pattern." >&2
    exit 1
fi

mojo build tests/pool_escape_control.mojo -I "$broken" \
    -I "$CONDA_PREFIX/lib/mojo" -o build/pool-escape-broken

echo "== running the escape control against it (must FAIL)"
if ./build/pool-escape-broken >build/pool-escape-broken.log 2>&1; then
    echo "!! NEGATIVE CONTROL FAILED: the escape test passed even with the" >&2
    echo "   refcount check removed, so it was never testing the check." >&2
    cat build/pool-escape-broken.log >&2
    exit 1
fi
echo "== negative control ok: without the refcount check the escape test fails"
sed 's/^/   | /' build/pool-escape-broken.log
