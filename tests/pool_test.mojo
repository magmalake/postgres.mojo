"""The pool suite: `postgres.pool` against a real server, from real threads.

Run through `tests/run_pool.sh`, which starts a throwaway cluster, exports
``$POSTGRES_TEST_DSN`` and stops it again.  With that variable unset this
binary prints one line and exits 0, exactly like `tests/server_test.mojo`.

Every test builds its own `ConnectionPool` over the same throwaway server, and
the ones that need a table make it with a name of their own and drop it after,
because a pool's connections are ordinary sessions and a ``TEMP`` table would
be visible to only one of them.

**On ThreadSanitizer.**  Do not reach for it here.  The Mojo 1.0.0 runtime
allocator is invisible to TSan's intercepts, so *any* allocating threaded Mojo
program reports races that are not there -- `parquet.mojo`'s
``tests/tsan_control.mojo`` demonstrates it on a program with no shared state
at all.  What stands in for it is
`test_repeated_concurrent_bursts_stay_correct`: the same contended workload
run over and over, with assertions that a lost mutex or a shared `PGconn`
would break deterministically rather than statistically.
"""

from std.os import getenv
from std.testing import TestSuite, assert_equal, assert_true
from std.time import sleep

from threads import AtomicCounter, parallel_for

from postgres import Connection, Params, Result, Statement, Transaction
from postgres._ffi import PQTRANS_IDLE, PQTRANS_INTRANS
from postgres.pool import (
    ON_RETURN_DISCARD_ALL,
    ON_RETURN_ROLLBACK,
    ConnectionPool,
    PoolConfig,
    PoolRef,
)
from postgres.sqlstate import sqlstate_of


# ===----------------------------------------------------------------------===#
# Fixtures
# ===----------------------------------------------------------------------===#


def _dsn() raises -> String:
    """The DSN of the test server.

    Returns:
        ``$POSTGRES_TEST_DSN``.

    Raises:
        Error: If the variable is unset -- which `main` checks first, so
            reaching this means the environment changed mid-run.
    """
    var dsn = getenv("POSTGRES_TEST_DSN", "")
    if not dsn:
        raise Error("$POSTGRES_TEST_DSN is not set")
    return dsn


def _pool(config: PoolConfig) raises -> ConnectionPool:
    """A pool over the test server.

    Args:
        config: The pool's configuration.

    Returns:
        The pool.

    Raises:
        Error: If the pool could not be built.
    """
    return ConnectionPool(_dsn(), config)


def _connect() raises -> Connection:
    """A plain connection, outside any pool -- the tests' side channel.

    Returns:
        The connection.

    Raises:
        Error: If it could not be opened.
    """
    return Connection(_dsn())


def _fresh_table(name: String) raises:
    """Drop and recreate `name` as a two-column table, from outside the pool.

    Args:
        name: The table name.

    Raises:
        Error: If the DDL failed.
    """
    var conn = _connect()
    _ = conn.execute("DROP TABLE IF EXISTS " + name)
    _ = conn.execute("CREATE TABLE " + name + " (id bigint primary key)")


def _drop_table(name: String) raises:
    """Drop `name` if it is there.

    Args:
        name: The table name.

    Raises:
        Error: If the DDL failed.
    """
    var conn = _connect()
    _ = conn.execute("DROP TABLE IF EXISTS " + name)


def _count(name: String) raises -> Int:
    """How many rows `name` holds, read from outside the pool.

    Args:
        name: The table name.

    Returns:
        The row count.

    Raises:
        Error: If the query failed.
    """
    var conn = _connect()
    var res = conn.query("SELECT count(*) AS n FROM " + name)
    return Int(res.row(0).int64("n"))


def _lease_pid(pool: PoolRef) raises -> Int:
    """Check a connection out, read its backend PID, and give it straight back.

    Args:
        pool: The pool.

    Returns:
        The backend PID that served the lease.

    Raises:
        Error: If the lease or the query failed.
    """
    with pool.lease() as lease:
        return lease.backend_pid()


# ===----------------------------------------------------------------------===#
# Leasing, reuse and growth
# ===----------------------------------------------------------------------===#


def test_a_lease_runs_a_query_and_comes_back() raises:
    var pool = _pool(PoolConfig(max_size=2))

    assert_equal(pool.stats().opened, 0, "the pool opened something too early")

    with pool.lease() as lease:
        var res = lease.connection().query("SELECT 7 AS n")
        assert_equal(res.row(0).int64("n"), 7)
        assert_equal(pool.stats().busy, 1, "the lease was not counted busy")

    var after = pool.stats()
    assert_equal(after.busy, 0, "the lease did not come back")
    assert_equal(after.idle, 1, "the connection was not pooled")
    assert_equal(after.opened, 1, "more than one connection was opened")
    assert_equal(after.escaped, 0, "nothing escaped, but the pool said it did")
    assert_equal(after.discarded, 0)


def test_the_same_backend_is_handed_out_again() raises:
    var pool = _pool(PoolConfig(max_size=4))
    var first = _lease_pid(pool.ref())
    var second = _lease_pid(pool.ref())
    var third = _lease_pid(pool.ref())

    assert_equal(first, second, "the pool reopened instead of reusing")
    assert_equal(second, third, "the pool reopened instead of reusing")
    assert_equal(pool.stats().opened, 1, "the pool opened more than it needed")


def test_growth_is_lazy_and_min_idle_is_eager() raises:
    var lazy = _pool(PoolConfig(max_size=8))
    assert_equal(lazy.stats().idle, 0, "a max_size=8 pool preopened")
    assert_equal(lazy.stats().opened, 0)

    var warm = _pool(PoolConfig(max_size=8, min_idle=3))
    assert_equal(warm.stats().idle, 3, "min_idle was not opened at build time")
    assert_equal(warm.stats().opened, 3)
    assert_equal(warm.stats().busy, 0)


def test_a_bad_conninfo_fails_at_construction_when_min_idle_is_set() raises:
    var raised = False
    try:
        var pool = ConnectionPool(
            "postgresql://127.0.0.1:1/nope?connect_timeout=2",
            PoolConfig(max_size=2, min_idle=1),
        )
        _ = pool.stats()
    except e:
        raised = True
        assert_equal(sqlstate_of(e), "08001")
    assert_true(raised, "a pool was built over a server that is not there")


def test_max_size_and_min_idle_are_checked() raises:
    var raised_size = False
    try:
        var p = _pool(PoolConfig(max_size=0))
        _ = p.stats()
    except:
        raised_size = True
    assert_true(raised_size, "max_size=0 was accepted")

    var raised_idle = False
    try:
        var p = _pool(PoolConfig(max_size=2, min_idle=3))
        _ = p.stats()
    except:
        raised_idle = True
    assert_true(raised_idle, "min_idle above max_size was accepted")


# ===----------------------------------------------------------------------===#
# Concurrency
#
# The shape of every threaded test below: a `Ctx` the workers share by `mut`
# reference, counters inside it read and written atomically, and every failure
# recorded rather than raised -- a `parallel_for` task is non-raising, because
# pthread has no exception channel.
# ===----------------------------------------------------------------------===#


comptime CONCURRENT_TABLE: StaticString = "pool_concurrent"
"""The table `_concurrent_task` writes one row per task into."""

comptime CONCURRENT_TASKS: Int = 240
"""Tasks per burst.  Far more than `CONCURRENT_MAX_SIZE`, so every worker
queues behind the others repeatedly rather than getting lucky."""

comptime CONCURRENT_MAX_SIZE: Int = 4
"""Pool size for the concurrency tests: smaller than the worker count, so the
condition variable is exercised rather than bypassed."""

comptime CONCURRENT_WORKERS: Int = 12
"""Threads.  Three times the pool size, so somebody is always waiting."""


@fieldwise_init
struct Ctx(Copyable, Movable):
    """What every concurrent worker shares.

    The three counters are plain `Int64` fields, reached through
    `threads.atomic.AtomicCounter` views built on their addresses -- the `Ctx`
    is passed to `threads.parallel_for` by `mut` reference, so those addresses
    are stable for the whole call.
    """

    var pool: PoolRef
    """The pool under test."""
    var ok: Int64
    """Tasks that leased, worked and verified their own session."""
    var failed: Int64
    """Tasks that raised anywhere."""
    var shared: Int64
    """Tasks that saw *another task's* session marker on their connection.

    This is the number that must be zero.  Anything else is two threads on one
    `PGconn`."""


def _concurrent_task(i: Int, mut ctx: Ctx) -> None:
    """One task: take a lease, mark the session, work, check the mark is still
    ours, and write a row.

    The marker is the exclusivity proof.  ``set_config`` writes a session
    variable on this backend; the ``pg_sleep`` in between gives any other
    thread that had been handed the same `PGconn` time to overwrite it, and
    reading it back afterwards is what would catch that.  A pool that let two
    leases share a connection fails this deterministically, not statistically
    -- and long before that, the two threads' replies would cross on the wire.

    Args:
        i: The task index, used as the marker and as the row's primary key.
        ctx: The shared context.
    """
    var ok = AtomicCounter.at(Int(Pointer(to=ctx.ok)))
    var failed = AtomicCounter.at(Int(Pointer(to=ctx.failed)))
    var shared = AtomicCounter.at(Int(Pointer(to=ctx.shared)))
    var tag = String(i)
    try:
        with ctx.pool.lease() as lease:
            ref conn = lease.connection()
            _ = conn.execute(
                "SELECT set_config('pool.tag', $1, false)", Params().text(tag)
            )
            _ = conn.execute("SELECT pg_sleep(0.001)")
            var seen = (
                conn.query("SELECT current_setting('pool.tag') AS tag")
                .row(0)
                .text("tag")
            )
            if seen != tag:
                _ = shared.fetch_add(1)
                return
            _ = conn.execute(
                "INSERT INTO " + String(CONCURRENT_TABLE) + " VALUES ($1)",
                Params().int64(Int64(i)),
            )
        _ = ok.fetch_add(1)
    except:
        _ = failed.fetch_add(1)


def _run_one_burst(pool: PoolRef) raises -> Ctx:
    """Run `CONCURRENT_TASKS` tasks across `CONCURRENT_WORKERS` threads.

    Args:
        pool: The pool under test.

    Returns:
        The context, with its counters filled in.

    Raises:
        Error: If a thread could not be started or joined.
    """
    var ctx = Ctx(pool=pool, ok=0, failed=0, shared=0)
    parallel_for[_concurrent_task](
        CONCURRENT_TASKS, ctx, num_workers=CONCURRENT_WORKERS
    )
    return ctx^


def test_concurrent_checkout_gives_every_thread_exclusive_use() raises:
    _fresh_table(String(CONCURRENT_TABLE))
    var pool = _pool(
        PoolConfig(
            max_size=CONCURRENT_MAX_SIZE,
            min_idle=1,
            acquire_timeout_ms=30_000,
        )
    )

    var ctx = _run_one_burst(pool.ref())

    assert_equal(Int(ctx.shared), 0, "two threads were given one connection")
    assert_equal(Int(ctx.failed), 0, "a task failed")
    assert_equal(Int(ctx.ok), CONCURRENT_TASKS, "not every task finished")
    assert_equal(
        _count(String(CONCURRENT_TABLE)),
        CONCURRENT_TASKS,
        "the work did not all land",
    )

    var stats = pool.stats()
    assert_equal(stats.busy, 0, "a lease was left outstanding")
    assert_equal(stats.escaped, 0, "something escaped a lease")
    assert_equal(stats.timeouts, 0, "a task timed out waiting")
    assert_true(
        stats.opened <= CONCURRENT_MAX_SIZE,
        String(
            "the pool opened ",
            stats.opened,
            " connections, above max_size ",
            CONCURRENT_MAX_SIZE,
        ),
    )
    assert_true(
        stats.waits > 0,
        "no task ever had to wait, so the contention path was never taken",
    )
    _drop_table(String(CONCURRENT_TABLE))


def test_repeated_concurrent_bursts_stay_correct() raises:
    """The repetition stress that stands in for ThreadSanitizer.

    The same contended workload, several times over one pool, so a connection
    that is returned wrongly on one burst is leased by the next.

    Raises:
        Error: On any assertion failure.
    """
    _fresh_table(String(CONCURRENT_TABLE))
    var pool = _pool(
        PoolConfig(
            max_size=CONCURRENT_MAX_SIZE,
            min_idle=2,
            acquire_timeout_ms=30_000,
        )
    )

    var total = 0
    for burst in range(5):
        var conn = _connect()
        _ = conn.execute("TRUNCATE " + String(CONCURRENT_TABLE))
        var ctx = _run_one_burst(pool.ref())
        assert_equal(
            Int(ctx.shared),
            0,
            String("burst ", burst, ": two threads shared a connection"),
        )
        assert_equal(
            Int(ctx.failed), 0, String("burst ", burst, ": a task failed")
        )
        assert_equal(Int(ctx.ok), CONCURRENT_TASKS)
        assert_equal(_count(String(CONCURRENT_TABLE)), CONCURRENT_TASKS)
        total += Int(ctx.ok)

    assert_equal(total, 5 * CONCURRENT_TASKS)
    var stats = pool.stats()
    assert_equal(stats.busy, 0)
    assert_equal(stats.escaped, 0)
    assert_true(stats.opened <= CONCURRENT_MAX_SIZE)
    _drop_table(String(CONCURRENT_TABLE))


# ===----------------------------------------------------------------------===#
# Exhaustion
# ===----------------------------------------------------------------------===#


def test_exhaustion_times_out_and_then_recovers() raises:
    var pool = _pool(PoolConfig(max_size=1, acquire_timeout_ms=200))

    with pool.lease() as held:
        _ = held.connection().execute("SELECT 1")

        var raised = False
        try:
            var second = pool.lease()
            _ = second^
        except e:
            raised = True
            assert_equal(
                sqlstate_of(e),
                "53300",
                "exhaustion raised the wrong SQLSTATE",
            )
        assert_true(raised, "a second lease was granted on a max_size=1 pool")
        assert_equal(pool.stats().timeouts, 1)
        assert_true(pool.stats().waits >= 1, "the waiter was never counted")

    # The lease is back; the pool works again, with no new connection needed.
    with pool.lease() as again:
        var res = again.connection().query("SELECT 11 AS n")
        assert_equal(res.row(0).int64("n"), 11)

    assert_equal(pool.stats().opened, 1, "recovery cost a new connection")
    assert_equal(pool.stats().timeouts, 1)


# ===----------------------------------------------------------------------===#
# Server-side death: the failover case
# ===----------------------------------------------------------------------===#


def _terminate_backend(pid: Int) raises:
    """Kill backend `pid` and wait until the server agrees it is gone.

    Waiting on ``pg_stat_activity`` rather than sleeping a fixed amount is what
    makes the test that follows deterministic: once the backend is off that
    view the process has exited, so its socket is closed and the ``FIN`` is on
    its way to us.

    Args:
        pid: The backend to terminate.

    Raises:
        Error: If the backend was still there after five seconds.
    """
    var conn = _connect()
    _ = conn.execute(
        "SELECT pg_terminate_backend($1)", Params().int32(Int32(pid))
    )
    for _ in range(500):
        var res = conn.query(
            "SELECT count(*) AS n FROM pg_stat_activity WHERE pid = $1",
            Params().int32(Int32(pid)),
        )
        if res.row(0).int64("n") == 0:
            # The backend has exited. Give the loopback a generous moment to
            # deliver what it sent on the way out; `Connection.is_alive` reads
            # what has arrived, and cannot see what has not.
            sleep(0.25)
            return
        sleep(0.01)
    raise Error("backend " + String(pid) + " never went away")


def test_a_terminated_backend_is_recycled_not_handed_back() raises:
    var pool = _pool(PoolConfig(max_size=1, min_idle=1, max_idle_ms=0))

    var doomed = _lease_pid(pool.ref())
    assert_equal(pool.stats().idle, 1, "the connection was not pooled")

    _terminate_backend(doomed)

    # `Connection.is_open` still says True here -- PQstatus is a cached
    # opinion. The pool asks `Connection.is_alive` instead, which reads the
    # socket, and recycles the handle in place with PQreset.
    with pool.lease() as lease:
        assert_true(
            lease.backend_pid() != doomed,
            "the pool handed back the dead backend",
        )
        var res = lease.connection().query("SELECT 5 AS n")
        assert_equal(res.row(0).int64("n"), 5, "the replacement did not work")

    var stats = pool.stats()
    assert_equal(stats.recycled, 1, "the dead connection was not recycled")
    assert_equal(
        stats.opened, 1, "recycling paid for a whole new PGconn after all"
    )
    assert_equal(stats.escaped, 0)
    assert_equal(stats.idle, 1, "the recycled connection was not pooled")


def test_a_backend_that_dies_mid_lease_is_discarded_on_return() raises:
    var pool = _pool(PoolConfig(max_size=1, min_idle=1, max_idle_ms=0))

    var before = pool.stats().opened
    with pool.lease() as lease:
        var pid = lease.backend_pid()
        _terminate_backend(pid)
        var raised = False
        try:
            _ = lease.connection().execute("SELECT 1")
        except e:
            raised = True
            assert_true(
                sqlstate_of(e) == "08006" or sqlstate_of(e) == "57P01",
                "a dead backend raised " + sqlstate_of(e),
            )
        assert_true(raised, "a query on a dead backend succeeded")

    var stats = pool.stats()
    assert_equal(stats.idle, 0, "a dead connection went back into the pool")
    assert_equal(stats.busy, 0)
    assert_equal(stats.discarded, 1, "the dead connection was not discarded")

    # And the pool still works: the next lease opens a replacement.
    with pool.lease() as lease:
        var res = lease.connection().query("SELECT 3 AS n")
        assert_equal(res.row(0).int64("n"), 3)
    assert_equal(pool.stats().opened, before + 1)


# ===----------------------------------------------------------------------===#
# Dirty returns
# ===----------------------------------------------------------------------===#


comptime DIRTY_TABLE: StaticString = "pool_dirty"
"""The table the dirty-return test writes into and expects to stay empty."""


def _abandon_an_open_transaction(pool: PoolRef, table: String) raises -> Int:
    """Leave a lease with a transaction block open on it.

    Raw ``BEGIN``, not `Connection.begin`: a `connection.Transaction` guard
    would roll itself back on the way out, which is the guard's promise rather
    than the pool's, and would also count as an escape.  This leaves the block
    genuinely open at lease end, with nothing holding the connection.

    Args:
        pool: The pool to lease from.
        table: A table to insert an uncommitted row into.

    Returns:
        The backend PID that served the lease.

    Raises:
        Error: If the lease or the statements failed.
    """
    with pool.lease() as lease:
        ref conn = lease.connection()
        _ = conn.execute("BEGIN")
        _ = conn.execute("INSERT INTO " + table + " VALUES (1)")
        assert_equal(
            conn.transaction_status(),
            PQTRANS_INTRANS,
            "the block did not open",
        )
        return conn.backend_pid()


def test_a_lease_that_leaves_a_transaction_open_is_rolled_back() raises:
    _fresh_table(String(DIRTY_TABLE))
    var pool = _pool(PoolConfig(max_size=1, min_idle=1, max_idle_ms=0))

    var pid_before = _abandon_an_open_transaction(
        pool.ref(), String(DIRTY_TABLE)
    )

    with pool.lease() as lease:
        ref conn = lease.connection()
        assert_equal(
            conn.backend_pid(),
            pid_before,
            "the pool replaced the connection instead of cleaning it",
        )
        assert_equal(
            conn.transaction_status(),
            PQTRANS_IDLE,
            "the next lease inherited an open transaction",
        )

    assert_equal(
        _count(String(DIRTY_TABLE)), 0, "the abandoned insert was committed"
    )
    assert_equal(pool.stats().escaped, 0)
    assert_equal(pool.stats().discarded, 0, "cleaning cost the connection")
    _drop_table(String(DIRTY_TABLE))


def test_a_failed_block_is_also_rolled_back() raises:
    var pool = _pool(PoolConfig(max_size=1, min_idle=1, max_idle_ms=0))

    with pool.lease() as lease:
        ref conn = lease.connection()
        _ = conn.execute("BEGIN")
        try:
            _ = conn.execute("SELECT this_function_does_not_exist()")
        except:
            pass

    with pool.lease() as lease:
        ref conn = lease.connection()
        assert_equal(
            conn.transaction_status(),
            PQTRANS_IDLE,
            "the next lease inherited a failed transaction block",
        )
        var res = conn.query("SELECT 1 AS n")
        assert_equal(res.row(0).int64("n"), 1)

    assert_equal(pool.stats().discarded, 0)


def test_discard_all_is_opt_in_and_clears_the_session() raises:
    var keeping = _pool(
        PoolConfig(
            max_size=1, min_idle=1, max_idle_ms=0, on_return=ON_RETURN_ROLLBACK
        )
    )
    with keeping.lease() as lease:
        _ = lease.connection().execute("PREPARE ps AS SELECT 1")
    with keeping.lease() as lease:
        # The default keeps the session, prepared statements and all: that is
        # the whole reason DISCARD ALL is not the default.
        _ = lease.connection().execute("EXECUTE ps")

    var wiping = _pool(
        PoolConfig(
            max_size=1,
            min_idle=1,
            max_idle_ms=0,
            on_return=ON_RETURN_DISCARD_ALL,
        )
    )
    with wiping.lease() as lease:
        _ = lease.connection().execute("PREPARE ps AS SELECT 1")
    with wiping.lease() as lease:
        var raised = False
        try:
            _ = lease.connection().execute("EXECUTE ps")
        except e:
            raised = True
            assert_equal(sqlstate_of(e), "26000")
        assert_true(raised, "DISCARD ALL left the prepared statement behind")


# ===----------------------------------------------------------------------===#
# Escape detection -- the hard problem
#
# `Statement`, `Transaction`, `CopyIn` and `CopyOut` all share the connection's
# `_ConnCell`, deliberately, so that a handle can outlive the `Connection`
# value it came from. One that outlives its *lease* would be a second holder of
# a `PGconn` the pool is about to give to another thread, so the lease closes
# the connection instead of pooling it.
#
# `Result` is the one that does not: it owns its `PGresult` outright, and libpq
# lets a result outlive its connection. So a `Result` escaping a lease is fine,
# and `test_a_result_may_outlive_its_lease` pins that too -- the two tests
# together say exactly where the line is.
# ===----------------------------------------------------------------------===#


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


def test_a_statement_that_escapes_its_lease_costs_the_connection() raises:
    var pool = _pool(PoolConfig(max_size=2, min_idle=1, max_idle_ms=0))
    var opened_before = pool.stats().opened

    var escapee = _statement_escaping_a_lease(pool.ref())

    var stats = pool.stats()
    assert_equal(stats.escaped, 1, "the escape was not detected")
    assert_equal(stats.discarded, 1, "the escaped connection was pooled")
    assert_equal(stats.busy, 0, "the busy slot was not released")
    assert_equal(stats.idle, 0, "the escaped connection went back in the pool")

    # The escapee is not left holding a live session either: closing it is what
    # turns a silent race into an error at the one call site that deserves it.
    var raised = False
    try:
        var res = escapee.query()
        _ = res^
    except e:
        raised = True
        assert_equal(
            sqlstate_of(e), "08006", "the escapee did not get a closed session"
        )
    assert_true(raised, "the escaped statement still had a live connection")

    # And the pool carries on: the next lease opens a replacement.
    with pool.lease() as lease:
        var res = lease.connection().query("SELECT 2 AS n")
        assert_equal(res.row(0).int64("n"), 2)
    assert_equal(
        pool.stats().opened,
        opened_before + 1,
        "the pool did not replace the connection it lost",
    )


def _transaction_escaping_a_lease(pool: PoolRef) raises -> Transaction:
    """Open a transaction inside a lease and let it out.  A bug, on purpose.

    Args:
        pool: The pool to lease from.

    Returns:
        The open transaction, still holding the connection.

    Raises:
        Error: If the lease or the ``BEGIN`` failed.
    """
    with pool.lease() as lease:
        return lease.connection().begin()


def test_a_transaction_cannot_span_two_checkouts() raises:
    var pool = _pool(PoolConfig(max_size=2, min_idle=1, max_idle_ms=0))

    var escapee = _transaction_escaping_a_lease(pool.ref())

    var stats = pool.stats()
    assert_equal(
        stats.escaped, 1, "an open transaction was pooled with its connection"
    )
    assert_equal(stats.idle, 0)
    assert_equal(stats.busy, 0)

    var raised = False
    try:
        _ = escapee.execute("SELECT 1")
    except e:
        raised = True
        assert_equal(sqlstate_of(e), "08006")
    assert_true(raised, "the escaped transaction was still usable")


def _result_from_a_lease(pool: PoolRef) raises -> Result:
    """Read rows inside a lease and return them.  Deliberately fine.

    Args:
        pool: The pool to lease from.

    Returns:
        The rows, which own themselves.

    Raises:
        Error: If the lease or the query failed.
    """
    with pool.lease() as lease:
        return lease.connection().query("SELECT 42 AS n")


def _lease_from_a_pool_that_dies_first() raises:
    """One lease whose `ConnectionPool` value is already gone.

    `pool.lease()` is the last textual mention of `pool`, so Mojo destroys the
    `ConnectionPool` right there, and the `Lease` is left holding the **last**
    share of the pool's state -- the `pthread_mutex_t` included.  Ending the
    lease then has to not free that mutex out from under its own unlock.

    Raises:
        Error: If the lease or the query failed.
    """
    var pool = _pool(PoolConfig(max_size=1, min_idle=1, max_idle_ms=0))
    with pool.lease() as lease:
        _ = lease.connection().execute("SELECT 1")


def test_a_lease_may_outlive_the_pool_value() raises:
    """Repeated, because what this pins is a *quiet* corruption.

    The failure it guards against writes a few bytes into a freed heap block:
    nothing observable happens at the time, and it surfaces as a crash in
    whatever allocates next -- which was, when this was a live bug, an
    unrelated test three functions later.  One iteration proves nothing; a
    hundred, each opening and closing a real connection, gives the allocator
    every chance to hand that block to somebody else first.  It failed on
    Linux at five iterations and never on macOS at all.

    Raises:
        Error: On any failure, including a crash in a later allocation.
    """
    for _ in range(100):
        _lease_from_a_pool_that_dies_first()

    # And the pool machinery still works afterwards.
    var pool = _pool(PoolConfig(max_size=2, min_idle=1, max_idle_ms=0))
    with pool.lease() as lease:
        var res = lease.connection().query("SELECT 8 AS n")
        assert_equal(res.row(0).int64("n"), 8)
    assert_equal(pool.stats().escaped, 0)


def test_a_result_may_outlive_its_lease() raises:
    var pool = _pool(PoolConfig(max_size=2, min_idle=1, max_idle_ms=0))

    var res = _result_from_a_lease(pool.ref())

    assert_equal(res.row(0).int64("n"), 42, "the rows did not survive")
    var stats = pool.stats()
    assert_equal(
        stats.escaped, 0, "a Result was mistaken for a connection handle"
    )
    assert_equal(stats.idle, 1, "the connection was not pooled")
    assert_equal(stats.discarded, 0)


# ===----------------------------------------------------------------------===#
# Recycling and reaping
# ===----------------------------------------------------------------------===#


def test_max_lifetime_retires_a_connection() raises:
    # Long enough that the connection opened at construction is still fresh
    # for the first lease, short enough to step over between the two.
    var pool = _pool(
        PoolConfig(max_size=1, min_idle=1, max_lifetime_ms=300, max_idle_ms=0)
    )
    var first = _lease_pid(pool.ref())
    assert_equal(pool.stats().recycled, 0, "a fresh connection was recycled")

    sleep(0.4)
    var second = _lease_pid(pool.ref())

    assert_true(second != first, "an expired connection was handed back")
    assert_equal(pool.stats().recycled, 1, "it was not recycled in place")
    assert_equal(pool.stats().opened, 1, "retiring paid for a whole new PGconn")
    assert_equal(pool.stats().idle, 1, "the fresh session was not pooled")


def test_reap_closes_idle_connections_but_never_below_min_idle() raises:
    var pool = _pool(
        PoolConfig(max_size=4, min_idle=1, max_idle_ms=1, max_lifetime_ms=0)
    )
    # Three at once, so three end up idle.
    with pool.lease() as a:
        with pool.lease() as b:
            with pool.lease() as c:
                _ = a.connection().execute("SELECT 1")
                _ = b.connection().execute("SELECT 1")
                _ = c.connection().execute("SELECT 1")
    assert_equal(pool.stats().idle, 3, "three leases did not make three idle")

    sleep(0.05)
    pool.reap()

    var stats = pool.stats()
    assert_equal(stats.idle, 1, "reap did not stop at min_idle")
    assert_equal(stats.discarded, 2, "reap did not account for what it closed")

    # And the survivor still works.
    with pool.lease() as lease:
        var res = lease.connection().query("SELECT 9 AS n")
        assert_equal(res.row(0).int64("n"), 9)


def test_reap_tops_back_up_to_min_idle() raises:
    # No ageing at all here: the deficit comes from a connection the pool
    # *lost*, which is the case topping up exists for.
    var pool = _pool(
        PoolConfig(max_size=4, min_idle=2, max_idle_ms=0, max_lifetime_ms=0)
    )
    assert_equal(pool.stats().idle, 2)
    assert_equal(pool.stats().opened, 2)

    # An escaped handle costs the pool a connection; see the escape tests.
    var escapee = _statement_escaping_a_lease(pool.ref())
    _ = escapee^
    var after_loss = pool.stats()
    assert_equal(after_loss.escaped, 1)
    assert_equal(after_loss.idle, 1, "the pool did not lose one")

    pool.reap()

    var stats = pool.stats()
    assert_equal(stats.idle, 2, "reap did not top back up to min_idle")
    assert_equal(stats.opened, 3, "the replacement was not opened")
    # Nothing had aged out, so nothing beyond the escapee was closed.
    assert_equal(stats.discarded, 1)


# ===----------------------------------------------------------------------===#
# close()
# ===----------------------------------------------------------------------===#


def test_close_drains_idle_and_refuses_new_leases() raises:
    var pool = _pool(PoolConfig(max_size=3, min_idle=2, max_idle_ms=0))
    assert_equal(pool.stats().idle, 2)

    pool.close()

    var stats = pool.stats()
    assert_equal(stats.idle, 0, "close left connections in the pool")
    assert_equal(stats.discarded, 2)

    var raised = False
    try:
        var l = pool.lease()
        _ = l^
    except e:
        raised = True
        assert_equal(sqlstate_of(e), "08003")
    assert_true(raised, "a closed pool granted a lease")

    pool.close()  # idempotent
    assert_equal(pool.stats().discarded, 2)


def test_close_with_a_lease_outstanding_does_not_touch_it() raises:
    var pool = _pool(PoolConfig(max_size=3, min_idle=2, max_idle_ms=0))

    with pool.lease() as lease:
        pool.close()

        # The connection this thread is using is this thread's. Reaching into
        # it from close() would be exactly the race the pool exists to stop.
        var res = lease.connection().query("SELECT 4 AS n")
        assert_equal(
            res.row(0).int64("n"), 4, "close() broke an outstanding lease"
        )
        assert_equal(pool.stats().busy, 1, "the outstanding lease was lost")

    var stats = pool.stats()
    assert_equal(stats.busy, 0, "the lease never came home")
    assert_equal(stats.idle, 0, "a closed pool accepted a connection back")
    # One idle at close, plus the one that came home afterwards.
    assert_equal(stats.discarded, 2)
    assert_equal(stats.escaped, 0)


def main() raises:
    if not getenv("POSTGRES_TEST_DSN", ""):
        print(
            "pool_test: skipped -- set $POSTGRES_TEST_DSN, or run via"
            " `pixi run pool`, to exercise the pool suite"
        )
        return
    TestSuite.discover_tests[__functions_in_module()]().run()
