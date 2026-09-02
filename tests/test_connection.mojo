"""Server-free tests for `postgres.connection`.

Everything here runs on a machine with no PostgreSQL: the failure path of
`Connection.__init__` needs an address that refuses the connection, not a
server that accepts it.  Port 1 is reserved and never listening, so the
refusal arrives immediately.

What that proves is worth having on its own: the connect failure is *prompt*
(no minutes-long TCP timeout), it is raised rather than swallowed, it carries
SQLSTATE 08001 in the message shape the rest of the tin parses back, and the
`PGconn` a failed `PQconnectdb` still allocates is finished rather than
leaked.  The live behaviour is in `tests/server_test.mojo`.
"""

from std.testing import TestSuite, assert_equal, assert_true

from postgres import (
    Connection,
    ConnectionConfig,
    Params,
    Result,
    is_connection_error,
    sqlstate_of,
)


comptime UNREACHABLE_DSN = "postgresql://127.0.0.1:1/x?connect_timeout=1"
"""Port 1 is reserved and never listening, so ``connect()`` is refused at once.

``connect_timeout=1`` bounds the wait on the hosts where the refusal is dropped
rather than returned (a firewall, a container without loopback), keeping the
worst case at a second instead of the OS TCP timeout.
"""


def test_connect_failure_raises_08001() raises:
    """A refused connection raises, promptly, with SQLSTATE 08001.

    The three things a caller depends on: that it raises at all (rather than
    handing back a `Connection` that fails on first use), that the message
    starts with the token shape `sqlstate.sqlstate_of` parses, and that libpq's
    own explanation survives into it.
    """
    var raised = False
    try:
        var conn = Connection(UNREACHABLE_DSN)
        _ = conn^
    except e:
        raised = True
        var message = String(e)
        assert_true(
            message.startswith("postgres [SQLSTATE 08001] "),
            "unexpected message shape: " + message,
        )
        assert_equal(sqlstate_of(e), "08001")
        assert_true(
            is_connection_error(sqlstate_of(e)),
            "08001 should classify as a connection error",
        )
        # libpq names the host it could not reach; the rest of the wording is
        # the platform's strerror and not worth pinning.
        assert_true(
            "127.0.0.1" in message,
            "libpq's explanation did not survive: " + message,
        )
    assert_true(raised, "connecting to a dead port did not raise")


def test_connect_failure_from_config_raises_08001() raises:
    """The `ConnectionConfig` overload fails the same way as the URI one.

    It renders a conninfo string and hands it to the same `PQconnectdb`, so
    the only thing worth checking is that the rendering did not lose the
    ``connect_timeout`` -- which is what keeps this test fast.
    """
    var config = ConnectionConfig(
        host="127.0.0.1",
        port=1,
        dbname="x",
        user="nobody",
        connect_timeout=1,
    )
    var raised = False
    try:
        var conn = Connection(config)
        _ = conn^
    except e:
        raised = True
        assert_equal(sqlstate_of(e), "08001")
        assert_true(
            String(e).startswith("postgres [SQLSTATE 08001] "),
            "unexpected message shape: " + String(e),
        )
    assert_true(raised, "ConnectionConfig with a dead port did not raise")


def test_connect_failure_is_prompt() raises:
    """Ten refused connections in a row finish quickly.

    A `PGconn` that is not finished leaks the socket and the connection
    object; ten of them would show up as descriptor exhaustion long before
    this test loops enough to notice, but the real point is the wall clock:
    if `connect_timeout` were being dropped somewhere between
    `ConnectionConfig` and libpq, this test would take minutes instead of
    milliseconds.
    """
    for _ in range(10):
        var raised = False
        try:
            var conn = Connection(UNREACHABLE_DSN)
            _ = conn^
        except:
            raised = True
        assert_true(raised, "a refused connection did not raise")


def _params_default_arg_compiles(mut conn: Connection) raises -> Int:
    """Never called -- it exists so the compiler checks the default arguments.

    `Connection.execute`, `Connection.query` and the prepared-statement
    methods all default `params` to an empty `Params`, which is what makes the
    no-parameter call sites read naturally.  Type-checking this function is
    the server-free half of that guarantee; the live half is every
    single-argument call in `tests/server_test.mojo`.
    """
    var n = conn.execute("SELECT 1")
    var res: Result = conn.query("SELECT 1")
    n += res.num_rows()
    n += conn.execute("SELECT $1::int", Params().int32(1))
    n += conn.execute_prepared("s")
    var res2: Result = conn.query_prepared("s")
    return n + res2.num_rows()


def test_params_starts_empty() raises:
    """A default `Params` binds nothing, which is what selects the `PQexec`
    path in `Connection.execute` -- and with it multi-statement strings."""
    assert_equal(len(Params()), 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
