"""`postgres.pool` — connections shared safely between threads.

A `ConnectionPool` keeps a small set of open sessions and hands them out one at
a time.  It is built for a **long-lived service**: one pool for the process
lifetime, several threads checking connections out of it, and connections
recycled underneath so a failover or a nightly restart is survivable without a
restart of your own.

```mojo
from postgres.pool import ConnectionPool, PoolConfig

var cfg = PoolConfig(max_size=8, acquire_timeout_ms=2000)
var pool = ConnectionPool("postgresql://localhost/app?connect_timeout=5", cfg)

with pool.lease() as lease:
    var res = lease.connection().query("SELECT id FROM t WHERE id = $1",
                                       Params().int64(1))
    for row in res:
        print(row.int64("id"))
```

This module is **not** re-exported from `postgres`.  Import it by name, as
above: it pulls in the `threads` tin for its mutex and condition variable, and
a single-threaded caller should not have to carry that.

## The one invariant

`Connection` shares its `PGconn` with every `connection.Statement`,
`connection.Transaction`, `copy.CopyIn` and `copy.CopyOut` made from it, so
that a handle can keep the session open after the `Connection` value is gone.
That is deliberate, documented, and exactly what makes pooling delicate:
libpq forbids two threads touching one `PGconn`, and breaking that rule
corrupts the protocol stream silently rather than crashing.

So the pool's invariant is:

> **A connection goes back into the pool only when nothing else is holding
> it.**

`Lease` enforces it rather than asking for it.  When the lease ends it reads
`Connection._shares`; anything above one means a handle outlived the block, and
the connection is **closed instead of pooled** and counted in
`PoolStats.escaped`.  The escapee then gets SQLSTATE ``08006`` from its next
call, which is loud, local and immediate.

The pool's promise is therefore the same shape as `connection.Transaction`'s:
*the failure mode of losing track is "you lost a connection", never "two
threads share one".*

## Scope the lease with `with`

```mojo
with pool.lease() as lease:
    _ = lease.connection().execute("...")
```

Leaving the block ends the lease, however it is left -- off the end, by
`return`, or by a raise.  Mojo destroys a value after its last *use* rather
than at the end of its scope, so a lease held in a plain `var` also ends
earlier than the indentation suggests; `with` is what makes the extent
visible, and it is the supported form.

A transaction is expected to begin and end inside one lease.  That is not an
honour system either: a `connection.Transaction` still alive when the lease
ends *is* a share, so the connection is discarded rather than handed on with a
block open.

## What happens on return

In order, and only when nothing escaped:

1. If `PQtransactionStatus` is not idle, ``ROLLBACK``.  A lease that left a
   block open, or left it failed, does not leak that into the next caller.
2. With `PoolConfig.on_return` set to `ON_RETURN_DISCARD_ALL`, ``DISCARD
   ALL``.  Opt-in, because it is safer *and* throws away the prepared
   statements a service reissuing the same queries is paying to keep.
3. If the session is older than `PoolConfig.max_lifetime_ms`, or no longer
   alive, it is discarded rather than pooled.

## What happens on checkout

An idle connection is taken most-recently-returned first, then checked:
expired by `PoolConfig.max_lifetime_ms` or `PoolConfig.max_idle_ms`, or no
longer alive.  A connection that fails the check is **recycled in place** with
`Connection.reset` -- one blocking reconnect on a `PGconn` that is already
allocated -- and only closed outright if that fails too.

The liveness check is `Connection.is_alive`: a non-blocking read of what the
server has already sent, with no round trip.  It is not `Connection.ping`,
which is a ``SELECT 1`` per checkout, and it is deliberately *not*
`Connection.is_open`, which cannot see this at all -- `PQstatus` reports a
cached opinion, and a backend killed by ``pg_terminate_backend`` still reads
`CONNECTION_OK` until a command fails on it.

No local check can be certain; a connection can die in the microsecond after
it passes.  The point is not certainty, it is that a *known*-dead connection is
never handed out, and that a connection which dies in a caller's hands is
discarded on return instead of going back in the pool.

## Growth, waiting and reaping

The pool grows lazily to `PoolConfig.max_size`.  `PoolConfig.min_idle` is
opened at construction and kept warm; everything above that is opened when
somebody actually waits for it, because opening blocks and pre-opening the
whole pool would turn a typo in the conninfo into a slow startup failure.

A caller that finds every connection busy blocks on a real
``pthread_cond_t`` -- no spin, no poll -- until one comes back or
`PoolConfig.acquire_timeout_ms` elapses, at which point `ConnectionPool.lease`
raises SQLSTATE ``53300``.

**Reaping is lazy, plus an explicit `ConnectionPool.reap`.**  Idle connections
are aged out when they are next picked up, and `ConnectionPool.reap` does the
same sweep on demand, closing anything past `PoolConfig.max_idle_ms` (never
below `PoolConfig.min_idle`) and reopening back up to `PoolConfig.min_idle`.
There is deliberately no reaper thread: a thread inside a library owes its
caller a lifecycle -- when it starts, how it stops, what happens if the pool is
dropped while it sleeps -- and a detached thread waiting on a condition
variable that is about to be destroyed is precisely the use-after-free this
module exists to rule out.  A service that must not pin backends overnight
already has a timer; `ConnectionPool.reap` is one call on it, and it is the
same code the checkout path runs.

## Threads

`ConnectionPool` is the owner.  `ConnectionPool.ref` hands out a `PoolRef`,
which is copyable, shares the same state, and is what travels into a worker
thread's context.  Every `PoolRef` and every outstanding `Lease` holds a share
of the pool's state, so the state cannot be destroyed underneath a thread that
is still using it.

**A lease may outlive the pool value**, and routinely does: Mojo destroys a
value at its last *use*, so a `ConnectionPool` whose final mention is
`pool.lease()` is gone before the lease it produced, leaving that lease
holding the last share.  Returning the connection then means returning it to a
pool nobody else can see, which is fine and is what the share is for -- but it
also means the pool's mutex is destroyed by the lease that is using it, so
every critical section in this module lives in a function that takes the state
as a *borrowed* argument.  A borrowed argument cannot be destroyed during the
call, which is what keeps the mutex alive across its own unlock; see
`_put_back`.

`ConnectionPool.__init__` checks `PQisthreadsafe` and refuses to build a pool
on a libpq that was compiled without thread safety, because nothing here --
or anywhere else -- is safe on one.
"""

from std.ffi import c_int, external_call
from std.memory import ArcPointer, Pointer
from std.memory.alloc import unsafe_alloc
from std.time import perf_counter_ns

from threads import CondVar, CondVarRef, Mutex, MutexRef

from ._ffi import PQTRANS_IDLE, libpq
from .config import ConnectionConfig
from .connection import Connection
from .sqlstate import (
    CONNECTION_DOES_NOT_EXIST,
    PostgresError,
    SQLCLIENT_UNABLE_TO_ESTABLISH,
    TOO_MANY_CONNECTIONS,
)


# ===----------------------------------------------------------------------===#
# What a returned connection is cleaned with
# ===----------------------------------------------------------------------===#

comptime ON_RETURN_ROLLBACK: Int = 0
"""Roll back an open block and pool the connection.  The default.

Cheap -- a ``ROLLBACK`` only when `PQtransactionStatus` says one is needed, so
the common case of a clean lease costs nothing -- and it keeps the session's
prepared statements, temp tables and session GUCs, which is what a service
reissuing the same queries is paying for."""

comptime ON_RETURN_DISCARD_ALL: Int = 1
"""Issue ``DISCARD ALL`` on every return, on top of the rollback.

Safer and more expensive: it resets the session to its just-connected state,
which also throws away every prepared statement, temp table, cursor,
``SET``-in-session and advisory lock.  Worth it when leases cannot be trusted
to leave the session alone; not worth it otherwise."""


# ===----------------------------------------------------------------------===#
# Small time and pthread helpers
# ===----------------------------------------------------------------------===#

comptime _BlobPtr = Pointer[UInt8, MutUntrackedOrigin]
"""A `pthread_mutex_t` or `pthread_cond_t`, as `threads.mutex` carries them."""

comptime _TimespecPtr = Pointer[Int64, MutUntrackedOrigin]
"""A ``struct timespec`` -- ``{ time_t tv_sec; long tv_nsec; }``, two 64-bit
words on every platform this tin supports."""

comptime _CLOCK_REALTIME: Int32 = 0
"""``CLOCK_REALTIME``.  ``0`` on glibc, musl and macOS alike, and the clock
`pthread_cond_timedwait` measures its absolute deadline against by default."""


def _now_ms() -> Int:
    """A monotonic millisecond clock, for ages and deadlines.

    Returns:
        Milliseconds from an arbitrary fixed point.  Monotonic, so unlike wall
        time it cannot go backwards when the machine's clock is corrected --
        which matters for a pool that decides what to close by subtracting two
        of these.
    """
    return Int(perf_counter_ns() // 1_000_000)


def _cond_wait(cond_addr: Int, mutex_addr: Int, timeout_ms: Int):
    """Release the mutex and block until signalled, or until `timeout_ms`.

    `threads.mutex.CondVar` has no timed wait, so this is
    `pthread_cond_timedwait` called on the same blob addresses it hands out --
    the documented way to reach one of those from elsewhere.

    The return code is deliberately dropped.  A timeout, a signal and a
    spurious wakeup are all answered the same way: the caller re-takes the
    mutex, re-checks its predicate, and consults its own deadline.  Reading
    ``ETIMEDOUT`` (which is 60 on macOS and 110 on Linux) would add a platform
    constant and change nothing.

    Args:
        cond_addr: From `threads.mutex.CondVar.address`.
        mutex_addr: From `threads.mutex.Mutex.address`.  Held by this thread on
            entry, and held again on return.
        timeout_ms: How long to wait at most.  Zero or negative waits without a
            deadline.
    """
    if timeout_ms <= 0:
        CondVarRef.at(cond_addr).wait(MutexRef.at(mutex_addr))
        return

    var ts = unsafe_alloc[Int64](2)
    var deadline = _TimespecPtr(unsafe_from_address=Int(ts))
    _ = external_call["clock_gettime", c_int, Int32, _TimespecPtr](
        _CLOCK_REALTIME, deadline
    )
    # Normalise: tv_nsec has to stay inside [0, 1e9) or the call is EINVAL.
    var nsec = deadline[unsafe_offset=1] + Int64(timeout_ms) * 1_000_000
    deadline[unsafe_offset=0] = (
        deadline[unsafe_offset=0] + nsec // 1_000_000_000
    )
    deadline[unsafe_offset=1] = nsec % 1_000_000_000
    _ = external_call[
        "pthread_cond_timedwait", c_int, _BlobPtr, _BlobPtr, _TimespecPtr
    ](
        _BlobPtr(unsafe_from_address=cond_addr),
        _BlobPtr(unsafe_from_address=mutex_addr),
        deadline,
    )
    ts.unsafe_free()


# ===----------------------------------------------------------------------===#
# Configuration and statistics
# ===----------------------------------------------------------------------===#


struct PoolConfig(Copyable, ImplicitlyCopyable, Movable):
    """How big the pool gets, how long a caller waits, and when to recycle.

    Every default is chosen for a long-lived service rather than a script: a
    small pool, a bounded wait, and connections that age out on their own so a
    server restarted underneath the process is recovered from rather than
    hoarded through.

    Example:

    ```mojo
    var cfg = PoolConfig(
        max_size=16,
        min_idle=2,
        acquire_timeout_ms=2000,
        max_lifetime_ms=900_000,
    )
    ```
    """

    var max_size: Int
    """The most connections that may exist at once, idle and busy together.

    A caller that finds all of them busy waits.  This is a ceiling on what the
    *server* has to carry from this process, so it belongs next to the
    server's own ``max_connections`` rather than next to the thread count."""

    var min_idle: Int
    """Connections opened at construction and kept warm.

    These are opened eagerly, so a wrong conninfo fails
    `ConnectionPool.__init__` rather than the first query -- and with the
    default of ``0`` nothing is opened up front at all, so a typo does not turn
    into a slow startup failure either.  `ConnectionPool.reap` never closes
    below this, and tops back up to it."""

    var acquire_timeout_ms: Int
    """How long `ConnectionPool.lease` waits for a connection before raising.

    Zero or negative waits forever, which a service should not do: a pool that
    blocks without a bound converts a slow database into a hung process with
    no error to log."""

    var max_lifetime_ms: Int
    """Retire a connection this long after it was opened.  ``0`` disables it.

    Thirty minutes by default.  This is what lets a pool follow a failover or
    a rolling restart: without it a process holds the same sessions until
    something kills them, and finds out one query at a time."""

    var max_idle_ms: Int
    """Close a connection idle this long.  ``0`` disables it.

    Ten minutes by default, and never below `PoolConfig.min_idle`.  Applied
    when a connection is next picked up, and on `ConnectionPool.reap`."""

    var on_return: Int
    """`ON_RETURN_ROLLBACK` or `ON_RETURN_DISCARD_ALL`; see both."""

    var validate_on_checkout: Bool
    """Check `Connection.is_alive` before handing a connection out.

    On by default and cheap -- no round trip.  Turning it off saves one
    non-blocking socket read per checkout and gives up the pool's ability to
    notice a dead backend before a caller does."""

    def __init__(
        out self,
        max_size: Int = 10,
        min_idle: Int = 0,
        acquire_timeout_ms: Int = 5000,
        max_lifetime_ms: Int = 1_800_000,
        max_idle_ms: Int = 600_000,
        on_return: Int = ON_RETURN_ROLLBACK,
        validate_on_checkout: Bool = True,
    ):
        """Build a configuration, taking the defaults for what you do not set.

        Args:
            max_size: See `PoolConfig.max_size`; ten by default.
            min_idle: See `PoolConfig.min_idle`; none by default, so nothing is
                opened until something is leased.
            acquire_timeout_ms: See `PoolConfig.acquire_timeout_ms`; five
                seconds by default.
            max_lifetime_ms: See `PoolConfig.max_lifetime_ms`; thirty minutes
                by default.
            max_idle_ms: See `PoolConfig.max_idle_ms`; ten minutes by default.
            on_return: See `PoolConfig.on_return`; `ON_RETURN_ROLLBACK` by
                default.
            validate_on_checkout: See `PoolConfig.validate_on_checkout`; on by
                default.
        """
        self.max_size = max_size
        self.min_idle = min_idle
        self.acquire_timeout_ms = acquire_timeout_ms
        self.max_lifetime_ms = max_lifetime_ms
        self.max_idle_ms = max_idle_ms
        self.on_return = on_return
        self.validate_on_checkout = validate_on_checkout


@fieldwise_init
struct PoolStats(Copyable, ImplicitlyCopyable, Movable, Writable):
    """A snapshot of what the pool has been doing.  Cheap; takes the lock.

    The counters are cumulative since the pool was built; `PoolStats.idle` and
    `PoolStats.busy` are instantaneous.
    """

    var idle: Int
    """Connections in the pool right now, ready to hand out."""
    var busy: Int
    """Connections checked out right now, plus slots reserved by a caller that
    is in the middle of opening one."""
    var opened: Int
    """Connections opened, ever -- at construction, on growth, and by
    `ConnectionPool.reap` topping back up to `PoolConfig.min_idle`."""
    var recycled: Int
    """Connections reconnected in place by `Connection.reset` after failing a
    checkout validation.  A rising count is a server that is dropping
    sessions, not a bug in the pool."""
    var discarded: Int
    """Connections closed rather than pooled: expired, dead beyond recycling,
    escaped, or returned after `ConnectionPool.close`.  Includes
    `PoolStats.escaped`."""
    var escaped: Int
    """Leases that ended with something still holding the connection.

    Every one of these is a `connection.Statement`, `connection.Transaction`,
    `copy.CopyIn` or `copy.CopyOut` that outlived its `with` block.  The
    connection was closed rather than pooled -- see the module docstring -- so
    a non-zero count is a **bug in the calling code** that the pool contained
    rather than a cost it absorbed.  It should be zero."""
    var waits: Int
    """Times a caller blocked because every connection was busy.

    Counted per trip through the wait, so a caller woken and then passed over
    -- see `ConnectionPool.lease` on fairness -- counts more than once.  Read
    it against `PoolStats.timeouts` as a pressure signal, not as a count of
    callers."""
    var timeouts: Int
    """Times that block ran out of `PoolConfig.acquire_timeout_ms` and
    `ConnectionPool.lease` raised ``53300``."""

    def write_to(self, mut writer: Some[Writer]):
        """Render as one line, for a log.

        Args:
            writer: The sink to write to.
        """
        writer.write(
            "PoolStats(idle=",
            self.idle,
            ", busy=",
            self.busy,
            ", opened=",
            self.opened,
            ", recycled=",
            self.recycled,
            ", discarded=",
            self.discarded,
            ", escaped=",
            self.escaped,
            ", waits=",
            self.waits,
            ", timeouts=",
            self.timeouts,
            ")",
        )


# ===----------------------------------------------------------------------===#
# The shared state
# ===----------------------------------------------------------------------===#


struct _Pooled(Movable):
    """One idle connection and the two ages the pool retires it by."""

    var conn: Connection
    """The connection, owned by the pool while it sits here."""
    var opened_at_ms: Int
    """When the *session* began -- reset by a `Connection.reset`, because that
    is a new session even though it is the same handle."""
    var idle_since_ms: Int
    """When it was last returned."""

    def __init__(
        out self, var conn: Connection, opened_at_ms: Int, idle_since_ms: Int
    ):
        """Take ownership of an idle connection.

        Args:
            conn: The connection.
            opened_at_ms: From `_now_ms` when the session began.
            idle_since_ms: From `_now_ms` when it was returned.
        """
        self.conn = conn^
        self.opened_at_ms = opened_at_ms
        self.idle_since_ms = idle_since_ms

    def take(deinit self) -> Connection:
        """Give the connection up, destroying the entry.

        A consuming method rather than a plain ``entry.conn^`` at the call
        site: Mojo refuses to move one field out of an owned struct and leave
        the rest to be destroyed, so the entry has to end here.

        Returns:
            The connection, moved.
        """
        return self.conn^


struct _PoolState(Movable):
    """Everything shared between the pool, its refs and its outstanding leases.

    Lives in an `std.memory.ArcPointer`, so it outlives every `PoolRef` and
    every `Lease` no matter which order they are destroyed in -- which is the
    point, because a `Lease` returning a connection to a pool that had already
    been destroyed is exactly the kind of quiet corruption this module is here
    to prevent.

    Every field below `_PoolState.mutex` is guarded by it.  `_PoolState.idle`
    is used most-recently-returned first, so a busy pool keeps reusing its hot
    connections and the cold ones age out at the front.
    """

    var mutex: Mutex
    """Guards everything below.  Its blob address is stable, so
    `threads.mutex.MutexRef` views of it are safe to hand around."""
    var cond: CondVar
    """Signalled whenever a connection is returned, discarded or the pool is
    closed -- i.e. whenever a waiter's predicate could have changed."""
    var conninfo: String
    """What every connection in this pool is opened from."""
    var config: PoolConfig
    """Written once, in `_PoolState.__init__`, before this state is reachable
    from any other thread -- so it is the one field here that may be read
    without the mutex, which is what lets the slow parts of a checkout and a
    return happen outside the critical section."""

    var idle: List[_Pooled]
    """Idle connections, oldest first."""
    var busy: Int
    """Checked out, plus slots reserved by a caller currently opening one."""
    var closed: Bool
    """Set by `ConnectionPool.close`; makes every later lease raise."""

    var opened: Int
    var recycled: Int
    var discarded: Int
    var escaped: Int
    var waits: Int
    var timeouts: Int

    def __init__(out self, conninfo: String, config: PoolConfig) raises:
        """Build the state with no connections in it yet.

        Args:
            conninfo: The libpq conninfo string or URI.
            config: The pool's configuration.

        Raises:
            Error: If the mutex or condition variable could not be created.
        """
        self.mutex = Mutex()
        self.cond = CondVar()
        self.conninfo = conninfo
        self.config = config
        self.idle = List[_Pooled]()
        self.busy = 0
        self.closed = False
        self.opened = 0
        self.recycled = 0
        self.discarded = 0
        self.escaped = 0
        self.waits = 0
        self.timeouts = 0


def _lock(state: ArcPointer[_PoolState]) -> MutexRef:
    """Take the pool's mutex and hand back a view for releasing it.

    Args:
        state: The pool's shared state.

    Returns:
        A `threads.mutex.MutexRef` on the now-held mutex.  Deliberately not a
        scope guard: Mojo destroys a value at its last *use*, so a guard whose
        destructor unlocks would release the mutex at the first line of the
        critical section rather than the last.  Call `MutexRef.unlock`.

    Note:
        **Every critical section must be a function that takes `state`
        borrowed**, as this one does, and every one of them here is.  The view
        returned points into the state's heap block, so if the caller happened
        to hold the last share of the state and that share reached *its* last
        use partway through the critical section, the state -- mutex included
        -- would be freed before the unlock.  A borrowed argument cannot be
        destroyed during the call, which is what rules that out; see
        `_put_back`, where it actually bit.
    """
    var view = MutexRef.at(state[].mutex.address())
    view.lock()
    return view


def _timed_out_error() -> PostgresError:
    """The error `ConnectionPool.lease` raises when the wait runs out.

    Returns:
        A `sqlstate.PostgresError` with SQLSTATE
        `sqlstate.TOO_MANY_CONNECTIONS` (53300).
    """
    return PostgresError(
        severity="ERROR",
        sqlstate=String(TOO_MANY_CONNECTIONS),
        message=(
            "no pooled connection became available before"
            " acquire_timeout_ms elapsed; every connection is checked out"
        ),
    )


def _closed_pool_error() -> PostgresError:
    """The error every lease raises once the pool has been closed.

    Returns:
        A `sqlstate.PostgresError` with SQLSTATE
        `sqlstate.CONNECTION_DOES_NOT_EXIST` (08003).
    """
    return PostgresError(
        severity="FATAL",
        sqlstate=String(CONNECTION_DOES_NOT_EXIST),
        message="the connection pool is closed",
    )


def _open_one(state: ArcPointer[_PoolState]) raises -> Connection:
    """Open one connection.  Blocks; must not be called holding the mutex.

    Args:
        state: The pool's shared state, for the conninfo.

    Returns:
        The new connection.

    Raises:
        Error: A `sqlstate.PostgresError` with SQLSTATE 08001 if it could not
            be established.
    """
    var n = state[].conninfo.byte_length()
    if n < 8 or n > 500:
        raise Error("DEBUG: conninfo byte_length is ", n, " -- corrupt")
    var ci = state[].conninfo.copy()
    var m = ci.byte_length()
    if m != n:
        raise Error("DEBUG: copy length ", m, " != source ", n)
    return Connection(ci^)


def _expired(state: ArcPointer[_PoolState], entry: _Pooled, now: Int) -> Bool:
    """Whether an idle entry is too old to hand out.

    Args:
        state: The pool's shared state, for the limits.
        entry: The idle connection.
        now: From `_now_ms`.

    Returns:
        True if it is past `PoolConfig.max_lifetime_ms` or
        `PoolConfig.max_idle_ms`.  A limit of ``0`` or less is off.
    """
    var life = state[].config.max_lifetime_ms
    if life > 0 and now - entry.opened_at_ms >= life:
        return True
    var idle = state[].config.max_idle_ms
    if idle > 0 and now - entry.idle_since_ms >= idle:
        return True
    return False


def _clean_for_reuse(mut conn: Connection, on_return: Int) -> Bool:
    """Leave the session as the next lease should find it.

    Args:
        conn: The connection coming back.
        on_return: `ON_RETURN_ROLLBACK` or `ON_RETURN_DISCARD_ALL`.

    Returns:
        True if the session is clean and reusable.  False means the connection
        is not fit to pool -- the caller discards it.  Never raises: a
        connection that cannot be cleaned is an answer, not an error.
    """
    try:
        # Only when there is something to roll back: the common case of a
        # lease that ran plain statements pays nothing here.
        if conn.transaction_status() != PQTRANS_IDLE:
            _ = conn.execute("ROLLBACK")
        if on_return == ON_RETURN_DISCARD_ALL:
            _ = conn.execute("DISCARD ALL")
        return conn.is_open()
    except:
        return False


def _release_slot(
    state: ArcPointer[_PoolState], discarded: Bool, escaped: Bool = False
):
    """Give a busy slot back without a connection in it, and wake a waiter.

    Args:
        state: The pool's shared state.  Borrowed, which is load-bearing --
            see `_put_back`.
        discarded: Whether a connection was destroyed to get here, for
            `PoolStats.discarded`.
        escaped: Whether it was destroyed because something outlived the
            lease, for `PoolStats.escaped`.
    """
    var view = _lock(state)
    state[].busy -= 1
    if discarded:
        state[].discarded += 1
    if escaped:
        state[].escaped += 1
    state[].cond.signal()
    view.unlock()


def _put_back(
    state: ArcPointer[_PoolState],
    var conn: Connection,
    opened_at_ms: Int,
    now: Int,
    reusable: Bool,
):
    """Put `conn` back in the pool, or close it, and release its busy slot.

    **`state` is borrowed on purpose, and the whole critical section lives in
    this function for that reason.**  A `Lease` may hold the *last* share of
    the pool's state -- Mojo destroys a value at its last use, so a
    `ConnectionPool` whose final mention is `pool.lease()` is gone before the
    lease it produced.  Written inline in `Lease.__deinit__`, the owning share
    would then also be at *its* last use partway through the critical section,
    and the state -- with its `pthread_mutex_t` -- would be destroyed and
    freed before the matching unlock, which would then write into freed heap.
    That is a use-after-free that corrupts quietly and only surfaces in a
    later, unrelated allocation.

    A borrowed argument cannot be destroyed for the duration of the call, so
    the mutex is guaranteed to outlive its own unlock.  This is the same
    guarantee `threads.parallel_for`'s typed form leans on, for the same
    reason.

    Args:
        state: The pool's shared state, borrowed.
        conn: The connection coming back.  Moved on every path, so there is no
            drop flag and no chance of it being closed under the lock.
        opened_at_ms: When its session began.
        now: From `_now_ms`.
        reusable: Whether it is fit to hand out again.

    """
    var doomed = List[_Pooled]()
    var view = _lock(state)
    state[].busy -= 1
    if reusable and not state[].closed:
        state[].idle.append(_Pooled(conn^, opened_at_ms, now))
    else:
        state[].discarded += 1
        doomed.append(_Pooled(conn^, opened_at_ms, now))
    state[].cond.signal()
    view.unlock()
    # Closed outside the lock: `PQfinish` is a syscall, and nothing else can
    # reach this connection any more.
    _ = doomed^


# ===----------------------------------------------------------------------===#
# Lease
# ===----------------------------------------------------------------------===#


struct Lease(Movable):
    """One connection, checked out, for the extent of a `with` block.

    Produced by `ConnectionPool.lease`.  Reach the connection through
    `Lease.connection`:

    ```mojo
    with pool.lease() as lease:
        var res = lease.connection().query("SELECT 1")
        print(res.num_rows())
    ```

    **The lease ends when this value is destroyed**, which for a `with` block
    is when the block ends -- off the end, by `return`, or by a raise -- and
    for a plain `var` is at its last *use*, which is usually earlier than it
    looks.  Prefer `with`; it is the form that makes the extent match the
    indentation.

    Ending the lease does one of two things.  If nothing else is holding the
    connection, the session is cleaned -- rolled back if a block was left open
    -- and it goes back into the pool.  If something *is* holding it -- a
    `connection.Statement`, a `connection.Transaction`, a `copy.CopyIn` or a
    `copy.CopyOut` that outlived the block -- the connection is **closed**, and
    `PoolStats.escaped` records it.

    That second branch is the whole reason this type exists.  Those handles
    share the `PGconn` on purpose, so one of them can outlive the `Connection`
    value; pooled and handed to a second thread, that sharing becomes two
    threads on one `PGconn`, which libpq forbids and which corrupts the
    protocol stream without crashing.  Closing costs one connection and reports
    itself.  Pooling would cost correctness and say nothing.

    Not copyable: a lease is exclusive use, and two of them would not be.
    """

    var _state: ArcPointer[_PoolState]
    """A share of the pool's state, so the pool cannot be destroyed while this
    lease still has a connection to give back."""
    var _conn: Connection
    """The connection, owned for the extent of the lease."""
    var _opened_at_ms: Int
    """When this session began, carried through so the age survives a round
    trip through a caller."""

    def __init__(
        out self,
        state: ArcPointer[_PoolState],
        var conn: Connection,
        opened_at_ms: Int,
    ):
        """Take a checked-out connection.  `ConnectionPool.lease` builds these.

        Args:
            state: The pool's shared state.
            conn: The connection, already counted in `PoolStats.busy`.
            opened_at_ms: From `_now_ms`, when the session began.
        """
        self._state = state
        self._conn = conn^
        self._opened_at_ms = opened_at_ms

    def __enter__(deinit self) -> Self:
        """Hand the lease to ``with pool.lease() as lease:``.

        The lease is transferred into the block rather than borrowed, so it is
        destroyed -- and the connection therefore returned or discarded -- when
        the block ends, however it ends.

        Returns:
            This lease, moved.
        """
        return self^

    def __deinit__(deinit self):
        """End the lease: return the connection, or discard it.

        The refcount check is here rather than in an `__exit__`, because Mojo
        refuses a type that has both a consuming `__enter__` and an `__exit__`
        -- and a consuming `__enter__` is what makes `with` transfer the guard
        into the block.  `connection.Transaction` is shaped the same way for
        the same reason.  It is also the stronger of the two: a `Lease` that
        never reaches a `with` block at all still ends here.
        """
        var shares = self._conn._shares()
        var state = self._state

        if shares != 1:
            # Something outlived the lease and is still holding this PGconn.
            # Close it: the escapee gets 08006 from its next call, which is a
            # diagnosable error, where pooling it would be a silent race.
            self._conn.close()
            _release_slot(state, discarded=True, escaped=True)
            return

        # Cleaning talks to the server, so it happens with the mutex released.
        # `config` is written once, before the state is shared, so reading it
        # here needs no lock; `closed` is not, and is read inside one.
        var now = _now_ms()
        var life = state[].config.max_lifetime_ms
        var too_old = life > 0 and now - self._opened_at_ms >= life
        var clean = not too_old and _clean_for_reuse(
            self._conn, state[].config.on_return
        )
        _put_back(state, self._conn^, self._opened_at_ms, now, clean)

    def connection(mut self) -> ref[origin_of(self._conn)] Connection:
        """The leased connection.

        Returns:
            A mutable reference to it, valid for as long as the lease is.
            Anything made from it -- a `connection.Statement`, a
            `connection.Transaction`, a `copy.CopyIn` or a `copy.CopyOut` --
            must not outlive the lease; one that does costs the connection.
            A `result.Result` is not one of those: it owns its rows outright
            and is free to outlive the lease.
        """
        return self._conn

    def backend_pid(self) -> Int:
        """The backend serving this lease, for logging and for tests.

        Returns:
            The server-side process ID; see `Connection.backend_pid`.
        """
        return self._conn.backend_pid()


# ===----------------------------------------------------------------------===#
# PoolRef
# ===----------------------------------------------------------------------===#


@fieldwise_init
struct PoolRef(Copyable, ImplicitlyCopyable, Movable):
    """A copyable handle on a pool, for the threads that share it.

    A worker thread reaches its pool through one of these -- put it in the
    context struct `threads.parallel_for` or `threads.pool.TypedPool` hands
    around, and every worker leases from the same pool:

    ```mojo
    @fieldwise_init
    struct Ctx(Copyable, Movable):
        var pool: PoolRef

    def worker(i: Int, mut ctx: Ctx) -> None:
        try:
            with ctx.pool.lease() as lease:
                _ = lease.connection().execute("SELECT 1")
        except:
            pass

    parallel_for[worker](64, ctx, num_workers=8)
    ```

    It holds a share of the pool's state, so the state stays alive for as long
    as any thread can still reach it.  What it does *not* carry is ownership of
    the pool's lifecycle: `ConnectionPool.close` remains the owner's call.
    """

    var _state: ArcPointer[_PoolState]
    """The shared state; see `_PoolState`."""

    def lease(self) raises -> Lease:
        """Check a connection out.  See `ConnectionPool.lease`.

        Returns:
            The `Lease`.

        Raises:
            Error: A `sqlstate.PostgresError`; see `ConnectionPool.lease`.
        """
        return _lease(self._state)

    def stats(self) -> PoolStats:
        """A snapshot of the pool's counters.  See `ConnectionPool.stats`.

        Returns:
            The `PoolStats`.
        """
        return _stats(self._state)

    def reap(self):
        """Age out idle connections.  See `ConnectionPool.reap`."""
        _reap(self._state)


# ===----------------------------------------------------------------------===#
# ConnectionPool
# ===----------------------------------------------------------------------===#


struct ConnectionPool(Movable):
    """A pool of connections, safe to lease from several threads.

    Build one per process and keep it for the process lifetime; see the module
    docstring for the invariant it enforces and how.

    Example:

    ```mojo
    from postgres.pool import ConnectionPool, PoolConfig

    var pool = ConnectionPool(
        "postgresql://localhost/app?connect_timeout=5",
        PoolConfig(max_size=8, min_idle=1, acquire_timeout_ms=2000),
    )

    with pool.lease() as lease:
        _ = lease.connection().execute("DELETE FROM sessions WHERE expired")
    ```

    Not copyable -- `ConnectionPool.ref` is how a second holder is made, and it
    is deliberately not an owner.
    """

    var _state: ArcPointer[_PoolState]
    """The shared state; see `_PoolState`."""

    def __init__(
        out self, conninfo: String, config: PoolConfig = PoolConfig()
    ) raises:
        """Build a pool over `conninfo`, opening `PoolConfig.min_idle` now.

        Args:
            conninfo: A libpq URI or keyword string, exactly as
                `connection.Connection` takes it.  **Set ``connect_timeout``**:
                a pool whose opens can block for the OS TCP timeout blocks
                every waiter behind them.
            config: The pool's configuration.

        Raises:
            Error: If libpq was built without thread safety -- a pool is not
                safe on such a build and this refuses to pretend otherwise --
                if `PoolConfig.max_size` is below one or `PoolConfig.min_idle`
                is above it, or if one of the `PoolConfig.min_idle`
                connections could not be opened.  Opening those eagerly is
                what turns a wrong conninfo into a failure here rather than a
                failure in whichever thread happens to lease first.
        """
        if not libpq().PQisthreadsafe():
            raise Error(
                "postgres: this libpq was built without thread safety"
                " (PQisthreadsafe() is false), so a connection pool cannot be"
                " made safe on it. Install a thread-safe libpq -- every build"
                " since PostgreSQL 10, including conda-forge's, is one."
            )
        if config.max_size < 1:
            raise Error(
                "postgres: PoolConfig.max_size must be at least 1, got ",
                config.max_size,
            )
        if config.min_idle < 0 or config.min_idle > config.max_size:
            raise Error(
                (
                    "postgres: PoolConfig.min_idle must be between 0 and"
                    " max_size ("
                ),
                config.max_size,
                "), got ",
                config.min_idle,
            )

        if conninfo.byte_length() < 8 or conninfo.byte_length() > 500:
            raise Error(
                "DEBUG: incoming conninfo byte_length is ",
                conninfo.byte_length(),
                " -- corrupt at ConnectionPool.__init__ entry",
            )
        self._state = ArcPointer(_PoolState(conninfo, config))
        if self._state[].conninfo.byte_length() != conninfo.byte_length():
            raise Error(
                "DEBUG: stored conninfo length ",
                self._state[].conninfo.byte_length(),
                " != incoming ",
                conninfo.byte_length(),
            )

        var now = _now_ms()
        for _ in range(config.min_idle):
            var conn = _open_one(self._state)
            self._state[].idle.append(_Pooled(conn^, now, now))
            self._state[].opened += 1

    def ref(self) -> PoolRef:
        """A copyable handle on this pool, for a worker thread's context.

        Returns:
            The `PoolRef`.  It shares this pool's state and keeps it alive,
            but it is not an owner: only this `ConnectionPool` closes the pool.
        """
        return PoolRef(self._state)

    def lease(self) raises -> Lease:
        """Check a connection out, blocking until one is free.

        Takes the most recently returned idle connection, or opens a new one if
        the pool is below `PoolConfig.max_size`, or blocks on the pool's
        condition variable until somebody returns one.  An idle connection that
        has expired or is no longer alive is recycled with `Connection.reset`
        before it is handed out, and closed if that fails.

        Waiters are not queued.  A returning connection wakes one of them, and
        a thread arriving at that moment may take it first -- so a waiter can
        be passed over, and `PoolConfig.acquire_timeout_ms` rather than its
        place in a line is what bounds how long it waits.  That is the usual
        trade for a pool (a fair queue costs a handoff per return and starves
        throughput under load), and it is worth knowing before reading a
        latency histogram with a long tail on it.

        Returns:
            The `Lease`.  Use it in a `with` block; see `Lease` for what
            happens when the block ends.

        Raises:
            Error: A `sqlstate.PostgresError` with SQLSTATE ``53300`` if
                `PoolConfig.acquire_timeout_ms` elapsed with every connection
                busy; ``08003`` if `ConnectionPool.close` has run; or ``08001``
                if a new connection was needed and could not be opened.
        """
        return _lease(self._state)

    def stats(self) -> PoolStats:
        """A snapshot of the pool's counters.

        Takes the lock, so it is consistent with itself; it is a snapshot all
        the same, and another thread may have changed it before you read it.

        Returns:
            The `PoolStats`.  `PoolStats.escaped` above zero is the one to
            alert on: it means calling code let a handle outlive its lease.
        """
        return _stats(self._state)

    def reap(self):
        """Close idle connections that have aged out, and top back up.

        Closes every idle connection past `PoolConfig.max_idle_ms` or
        `PoolConfig.max_lifetime_ms`, never going below `PoolConfig.min_idle`,
        and then opens whatever it takes to get back *to*
        `PoolConfig.min_idle`.  Safe to call from any thread, at any time, as
        often as you like.

        This is the pool's maintenance tick, and it is deliberately yours to
        call rather than a thread of the pool's own; the module docstring says
        why.  A service that leases at least occasionally does not need it --
        the same ageing happens on checkout -- but one that goes quiet
        overnight does, or it holds its backends until morning.

        Never raises: a connection it could not reopen leaves the pool smaller,
        and the next `ConnectionPool.lease` will try again.
        """
        _reap(self._state)

    def close(self):
        """Close every idle connection and refuse every later lease.
        Idempotent.

        Safe to call with leases outstanding, and it does not touch them: a
        connection another thread is using is that thread's, and reaching into
        it is the exact race this module exists to prevent.  Each outstanding
        lease finds the pool closed when it ends and closes its connection
        instead of pooling it, so the pool drains as its leases come home.
        `PoolStats.busy` is how many are still out.

        Waiters blocked in `ConnectionPool.lease` are woken and raise ``08003``.
        """
        var view = _lock(self._state)
        self._state[].closed = True
        var doomed = List[_Pooled]()
        while len(self._state[].idle) > 0:
            doomed.append(self._state[].idle.pop())
        self._state[].discarded += len(doomed)
        self._state[].cond.broadcast()
        view.unlock()
        # Closed outside the lock: PQfinish is a syscall, and nothing else can
        # reach these -- they are off the idle list and nobody has them.
        _ = doomed^


# ===----------------------------------------------------------------------===#
# The implementation the pool and its refs share
# ===----------------------------------------------------------------------===#


def _stats(state: ArcPointer[_PoolState]) -> PoolStats:
    """Read every counter under the lock.

    Args:
        state: The pool's shared state.

    Returns:
        A consistent snapshot.
    """
    var view = _lock(state)
    var out = PoolStats(
        idle=len(state[].idle),
        busy=state[].busy,
        opened=state[].opened,
        recycled=state[].recycled,
        discarded=state[].discarded,
        escaped=state[].escaped,
        waits=state[].waits,
        timeouts=state[].timeouts,
    )
    view.unlock()
    return out


def _lease(state: ArcPointer[_PoolState]) raises -> Lease:
    """Check a connection out.  See `ConnectionPool.lease`.

    The loop terminates: every trip either returns, raises, removes a
    connection from the pool for good, or blocks until the deadline.  A server
    that is refusing connections therefore fails the caller rather than
    spinning on it.

    Args:
        state: The pool's shared state.

    Returns:
        The lease.

    Raises:
        Error: A `sqlstate.PostgresError`; see `ConnectionPool.lease`.
    """
    var timeout_ms = state[].config.acquire_timeout_ms
    var deadline = _now_ms() + timeout_ms if timeout_ms > 0 else 0

    var view = _lock(state)
    while True:
        if state[].closed:
            view.unlock()
            raise _closed_pool_error().to_error()

        if len(state[].idle) > 0:
            # Most recently returned first: the hot connections stay hot and
            # the cold ones collect at the front, where the reaper finds them.
            var entry = state[].idle.pop()
            state[].busy += 1
            view.unlock()
            var checked = _check_out(state, entry^)
            if checked:
                return checked.take()
            # That one was beyond recycling and has been closed and accounted
            # for; try again from the top.
            view = _lock(state)
            continue

        if len(state[].idle) + state[].busy < state[].config.max_size:
            state[].busy += 1
            view.unlock()
            var conn: Connection
            try:
                # Opening blocks, so it happens with the mutex released; the
                # busy slot above is what stops the pool overshooting max_size
                # while several callers open at once.
                conn = _open_one(state)
            except e:
                _release_slot(state, discarded=False)
                raise e
            var opened_at = _now_ms()
            var counted = _lock(state)
            state[].opened += 1
            counted.unlock()
            return Lease(state, conn^, opened_at)

        if timeout_ms > 0 and _now_ms() >= deadline:
            state[].timeouts += 1
            view.unlock()
            raise _timed_out_error().to_error()

        state[].waits += 1
        var remaining = deadline - _now_ms() if timeout_ms > 0 else 0
        if timeout_ms > 0 and remaining < 1:
            remaining = 1
        _cond_wait(state[].cond.address(), view.address(), remaining)
        # The mutex is held again here; the loop re-checks every predicate,
        # which is what makes a spurious wakeup harmless.


def _check_out(
    state: ArcPointer[_PoolState], var entry: _Pooled
) -> Optional[Lease]:
    """Validate an idle connection and turn it into a lease, or discard it.

    The busy slot is already reserved by the caller.  On failure the slot is
    released and the connection destroyed, so the caller can simply loop.

    Args:
        state: The pool's shared state.
        entry: The idle connection, already off the idle list.

    Returns:
        The lease, or `None` if the connection was past saving.
    """
    var now = _now_ms()
    var stale = _expired(state, entry, now)
    var opened_at = entry.opened_at_ms
    # Taken out of the entry up front: moving a field out of an owned struct
    # on some branches and not others is what Mojo refuses, and a local moves
    # freely.
    var conn = entry^.take()
    var dead = state[].config.validate_on_checkout and not conn.is_alive()

    if not stale and not dead:
        return Optional(Lease(state, conn^, opened_at))

    # Recycle in place rather than paying for a fresh PGconn: PQreset reuses
    # the handle and the parsed conninfo.  Nothing else holds this connection
    # -- it came off the idle list -- so the new session cannot surprise a
    # handle that outlived a lease.  (The escape path never resets, precisely
    # because there such a handle exists.)
    if conn.reset():
        var counted = _lock(state)
        state[].recycled += 1
        counted.unlock()
        return Optional(Lease(state, conn^, _now_ms()))

    _release_slot(state, discarded=True)
    return None


def _reap(state: ArcPointer[_PoolState]):
    """Age out idle connections and top back up to `PoolConfig.min_idle`.

    Args:
        state: The pool's shared state.
    """
    var now = _now_ms()
    var doomed = List[_Pooled]()
    var deficit = 0

    var view = _lock(state)
    if not state[].closed:
        var min_idle = state[].config.min_idle
        # The idle list is oldest first, so everything reapable is at the
        # front; stop at the first survivor.
        while len(state[].idle) > min_idle:
            if not _expired(state, state[].idle[0], now):
                break
            doomed.append(state[].idle.pop(0))
        state[].discarded += len(doomed)
        var have = len(state[].idle) + state[].busy
        if have < min_idle:
            deficit = min_idle - have
    view.unlock()
    _ = doomed^

    for _ in range(deficit):
        try:
            var conn = _open_one(state)
            var opened_at = _now_ms()
            var counted = _lock(state)
            if state[].closed:
                counted.unlock()
                return
            state[].idle.append(_Pooled(conn^, opened_at, opened_at))
            state[].opened += 1
            state[].cond.signal()
            counted.unlock()
        except:
            # The server is not taking connections. Leave the pool short; the
            # next lease will try again and report the failure to somebody who
            # can act on it.
            return
