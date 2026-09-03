#!/bin/sh
# The psql/psycopg cross-check: prove the text codec agrees with an
# independent client, cell for cell, in both directions.
#
#   Direction A -- Mojo writes (tests/crosscheck_write.mojo, both the typed
#     Params path and the CopyIn/CopyEncoder path), psycopg reads
#     (tests/crosscheck.py).
#   Direction B -- psycopg writes (tests/crosscheck.py), Mojo reads
#     (tests/crosscheck_read.mojo), cross-checked a third way against
#     `psql ... COPY ... TO STDOUT` of the same table.
#
# Run through tests/run_tests.sh, under scripts/with-pg-server.sh, so
# $POSTGRES_TEST_DSN is already exported by the time this runs. Can also be
# run standalone:
#
#   pixi run -e default sh scripts/with-pg-server.sh sh tests/crosscheck.sh
set -eu
cd "$(dirname "$0")/.."
mkdir -p build

t0=$(date +%s)

echo "== building tests/crosscheck_write.mojo"
mojo build tests/crosscheck_write.mojo -I src -o build/crosscheck-write
echo "== building tests/crosscheck_read.mojo"
mojo build tests/crosscheck_read.mojo -I src -o build/crosscheck-read

echo "== direction A: writing xc_mojo / xc_mojo_copy"
./build/crosscheck-write

echo "== direction A: reading back with psycopg, and writing xc_py"
python3 tests/crosscheck.py

echo "== dumping xc_py with psql COPY ... TO STDOUT, for direction B parity"
# TimeZone is set via PGOPTIONS (a startup option), not a `SET` command in
# the -c string: -At suppresses column headers and footers but not a
# command tag, so a leading `SET ...;` would otherwise print a "SET" line
# before the COPY data and throw off the row count.
PGOPTIONS="-c TimeZone=UTC" psql "$POSTGRES_TEST_DSN" -Atc \
    "COPY (SELECT id,b,i2,i4,i8,f4,f8,num,t,vc,bp,by,d,tm,ts,tstz,u,j,jb FROM xc_py ORDER BY id) TO STDOUT" \
    >build/xc_psql_copy.txt

echo "== direction B: reading xc_py with Row's typed accessors"
POSTGRES_XC_PSQL_FILE="$(pwd)/build/xc_psql_copy.txt" ./build/crosscheck-read

t1=$(date +%s)

echo "== direction A (mojo writes, psycopg reads): PASS"
echo "== direction B (python writes, mojo reads):  PASS"
echo "== crosscheck.sh: PASS ($((t1 - t0))s)"
