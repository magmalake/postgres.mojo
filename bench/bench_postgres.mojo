"""Four numbers against a real PostgreSQL, through the shared harness
(magmalake/bench.mojo).

    pixi run -e bench bench
    pixi run -e bench bench -- --json
    pixi run -e bench bench -- --only bench_copy_in_100k

The task runs under `scripts/with-pg-server.sh`, so a throwaway cluster is
started first and ``$POSTGRES_TEST_DSN`` points at it: **local loopback,
`fsync=off`, `synchronous_commit=off`** (see `scripts/pg-server.sh`).  These are
therefore best-case numbers for the client -- no network, no disk flush -- which
is what they are for: they measure how much of the wire cost is *ours*.

The four are the ones spec section 9 asks for, over
``(id int8, price numeric(12,4), qty int4, label text)``:

- `bench_copy_in_100k` -- 100k rows through ``COPY ... FROM STDIN``: the bulk
  path, and the number the binary-format decision will be measured against.
- `bench_select_scan_100k` -- reading those rows back through `Row`, decoding
  an `int8`, a `numeric` and a `text` per row.  Text format means `numeric`
  arrives as digits and stays a `String`, which is exactly the cost binary
  format would remove.
- `bench_insert_prepared_10k` -- 10k single-row inserts through one prepared
  statement: one round trip per row, the shape ``COPY`` exists to replace.
- `bench_select_by_id_10k` -- 10k single-row lookups by primary key, through
  `Connection.query` rather than a prepared statement: the same round trip as
  above plus a parse and a plan every time, which is what preparing buys back.

Each body opens its own connection and rebuilds its fixture outside `b.iter`,
so that setup is wall-clock cost and never enters the numbers -- and since the
tables are ``TEMP``, a fresh connection is a fresh empty table with no cleanup
to do.  The harness re-enters a body once per phase; `min_runtime_secs` is set
below one pass, so each timed region is exactly one pass over the table the
setup just built.
"""

from std.os import getenv

from bench import Benchmark, BenchSuite, Metric, keep

from postgres import Connection, CopyEncoder, Params

comptime COPY_ROWS = 100_000
"""Rows per ``COPY`` pass, and per scan."""
comptime ROUND_TRIPS = 10_000
"""Statements per round-trip benchmark."""
comptime SCHEMA: StaticString = (
    "(id int8, price numeric(12,4), qty int4, label text)"
)
"""Spec section 9's row: an integer, a numeric, a small integer and a string."""


def _dsn() raises -> String:
    """The test server's DSN.

    Returns:
        ``$POSTGRES_TEST_DSN``.

    Raises:
        Error: If it is unset -- `main` checks first, so this cannot happen in
            a normal run.
    """
    var dsn = getenv("POSTGRES_TEST_DSN", "")
    if not dsn:
        raise Error("$POSTGRES_TEST_DSN is not set")
    return dsn


def _price(i: Int) -> String:
    """A ``numeric(12,4)`` literal that varies from row to row.

    Args:
        i: The row number.

    Returns:
        A literal such as ``"1234.5678"``.
    """
    return String(1000 + (i % 9000)) + "." + String(1000 + (i % 8999))


def _payload(rows: Int) raises -> List[UInt8]:
    """The COPY text-format bytes for `rows` rows of `SCHEMA`.

    Built once per benchmark entry, outside the timed region: encoding is this
    tin's work but not the work being measured.

    Args:
        rows: How many rows to encode.

    Returns:
        The whole stream, ready for `copy.CopyIn.write`.

    Raises:
        Error: If the encoder rejected its configuration.
    """
    var enc = CopyEncoder()
    for i in range(rows):
        enc.field(String(i))
        enc.field(_price(i))
        enc.field(String(i % 100))
        enc.field("label-" + String(i))
        enc.end_row()
    return enc.take()


def _fill(mut conn: Connection, table: String, rows: Int) raises:
    """Create `table` and fill it with `rows` rows, server-side.

    ``generate_series`` rather than a ``COPY`` from here: the fixture is not
    what is being measured, and this is several times faster to build.

    Args:
        conn: The connection to build on.
        table: The (temporary) table name.
        rows: How many rows to generate.

    Raises:
        Error: If the DDL failed.
    """
    _ = conn.execute(
        "CREATE TEMP TABLE "
        + table
        + " AS SELECT i::int8 AS id,"
        " (1000 + i % 9000)::numeric(12,4) AS price,"
        " (i % 100)::int4 AS qty,"
        " 'label-' || i AS label"
        " FROM generate_series(0, "
        + String(rows - 1)
        + ") AS i"
    )


def bench_copy_in_100k(mut b: Benchmark) raises:
    """100k rows into an empty table through ``COPY ... FROM STDIN``."""
    var conn = Connection(_dsn())
    _ = conn.execute("CREATE TEMP TABLE bench_copy " + SCHEMA)
    var payload = _payload(COPY_ROWS)
    b.throughput(Metric.elements(), COPY_ROWS)

    @parameter
    def call() raises:
        var cp = conn.copy_in("COPY bench_copy FROM STDIN")
        cp.write(Span(payload))
        keep(cp.finish())

    b.iter[call]()
    keep(payload)
    _ = conn.server_version()  # a use after `b.iter`: the capture stays live


def bench_select_scan_100k(mut b: Benchmark) raises:
    """100k rows out, decoding an int8, a numeric and a text from each."""
    var conn = Connection(_dsn())
    _fill(conn, "bench_scan", COPY_ROWS)
    b.throughput(Metric.elements(), COPY_ROWS)

    @parameter
    def call() raises:
        var res = conn.query("SELECT id, price, label FROM bench_scan")
        var total: Int64 = 0
        var bytes = 0
        for row in res:
            total += row.int64(0)
            bytes += row.numeric(1).byte_length() + row.text(2).byte_length()
        keep(total)
        keep(bytes)

    b.iter[call]()
    _ = conn.server_version()


def bench_insert_prepared_10k(mut b: Benchmark) raises:
    """10k single-row inserts through one prepared statement."""
    var conn = Connection(_dsn())
    _ = conn.execute("CREATE TEMP TABLE bench_ins " + SCHEMA)
    var stmt = conn.prepare(
        "bench_ins_stmt", "INSERT INTO bench_ins VALUES ($1, $2, $3, $4)"
    )
    b.throughput(Metric.elements(), ROUND_TRIPS)

    @parameter
    def call() raises:
        for i in range(ROUND_TRIPS):
            keep(
                stmt.execute(
                    Params()
                    .int64(Int64(i))
                    .numeric(_price(i))
                    .int32(Int32(i % 100))
                    .text("label-" + String(i))
                )
            )

    b.iter[call]()
    _ = conn.server_version()  # a use after `b.iter`: the capture stays live


def bench_select_by_id_10k(mut b: Benchmark) raises:
    """10k single-row lookups by primary key, one round trip each."""
    var conn = Connection(_dsn())
    _fill(conn, "bench_lookup", COPY_ROWS)
    _ = conn.execute("ALTER TABLE bench_lookup ADD PRIMARY KEY (id)")
    b.throughput(Metric.elements(), ROUND_TRIPS)

    @parameter
    def call() raises:
        for i in range(ROUND_TRIPS):
            var res = conn.query(
                "SELECT id, price, qty, label FROM bench_lookup WHERE id = $1",
                Params().int64(Int64(i)),
            )
            keep(res.row(0).int64(0))

    b.iter[call]()
    _ = conn.server_version()


def _print_shape() raises:
    """The fixture's size, once, so the row rates convert to byte rates.

    A ``COPY`` benchmark reported in rows/s is the number that matters for a
    loader, but the wire cost is bytes; printing both halves of the conversion
    keeps the reported figure honest without a second timed pass.

    Raises:
        Error: If the server could not be reached.
    """
    var conn = Connection(_dsn())
    var payload = _payload(COPY_ROWS)
    print(
        "server",
        conn.server_version(),
        "| COPY payload",
        len(payload),
        "bytes for",
        COPY_ROWS,
        "rows (",
        Float64(len(payload)) / Float64(COPY_ROWS),
        "bytes/row )",
    )


def main() raises:
    if not getenv("POSTGRES_TEST_DSN", ""):
        print(
            "bench_postgres: skipped -- set $POSTGRES_TEST_DSN, or run"
            " `pixi run -e bench bench`, which starts a server first"
        )
        return
    _print_shape()
    # A single pass of each of these takes long enough to measure on its own,
    # so the calibration target is set below one pass: every timed region is
    # then exactly one, over the table the setup just truncated.
    BenchSuite.run[__functions_in_module()](min_runtime_secs=0.01)
