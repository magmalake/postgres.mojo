"""The escape check, on its own, so it can be run against a broken pool.

`tests/run_pool.sh` builds this **twice**: once against `src/`, where it must
pass, and once against a copy of `src/` with the refcount check in
`pool.Lease.__deinit__` replaced by a constant, where it must fail.  A test
that cannot fail is not evidence, and the escape check is the one assertion in
this tin where that matters most -- what it rules out is a silent corruption,
so nothing else would notice if the check quietly stopped working.

It is a `main` rather than a `TestSuite` case because the control needs the
process exit status to carry the verdict, and it duplicates one test from
`tests/pool_test.mojo` on purpose: that suite is what runs in CI, this is what
proves the suite has teeth.
"""

from std.os import getenv

from postgres import Statement
from postgres.pool import ConnectionPool, PoolConfig, PoolRef
from postgres.sqlstate import sqlstate_of


def _statement_escaping_a_lease(pool: PoolRef) raises -> Statement:
    """Prepare a statement inside a lease and let it out.  A bug, on purpose.

    Args:
        pool: The pool to lease from.

    Returns:
        The statement, still holding the connection the lease just ended.

    Raises:
        Error: If the lease or the prepare failed.
    """
    with pool.lease() as lease:
        return lease.connection().prepare("escapee", "SELECT 1 AS n")


def main() raises:
    var dsn = getenv("POSTGRES_TEST_DSN", "")
    if not dsn:
        print(
            "pool_escape_control: skipped -- set $POSTGRES_TEST_DSN, or run"
            " via `pixi run pool`"
        )
        return

    var pool = ConnectionPool(
        dsn, PoolConfig(max_size=2, min_idle=1, max_idle_ms=0)
    )
    var escapee = _statement_escaping_a_lease(pool.ref())
    var stats = pool.stats()

    if stats.escaped != 1:
        raise Error(
            "the escape was not detected: stats().escaped is ",
            stats.escaped,
            ", expected 1",
        )
    if stats.idle != 0:
        raise Error(
            "the escaped connection went back into the pool: stats().idle is ",
            stats.idle,
            ", expected 0",
        )
    if stats.discarded != 1:
        raise Error(
            "the escaped connection was not discarded: stats().discarded is ",
            stats.discarded,
            ", expected 1",
        )

    var raised = False
    try:
        var res = escapee.query()
        _ = res^
    except e:
        raised = True
        if sqlstate_of(e) != "08006":
            raise Error(
                "the escapee failed with SQLSTATE ",
                sqlstate_of(e),
                ", expected 08006",
            )
    if not raised:
        raise Error(
            "the escaped statement still had a live connection, which is"
            " exactly the state that becomes two threads on one PGconn"
        )

    print("pool_escape_control: the escape was detected and contained")
