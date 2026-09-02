"""Minimal insert example: create a table, insert with parameters, read back.

Every value goes to the server as a `$n` parameter rather than spliced into
the SQL, which is the point of the exercise — nothing here has to be escaped.
See `query_basic.mojo` for how to point this at a server.

    sh scripts/with-pg-server.sh sh -c \
        'mojo run -I src examples/insert_basic.mojo'
"""

from std.os import getenv

from postgres import Connection, ConnectionConfig, Params


def main() raises:
    var dsn = getenv("POSTGRES_TEST_DSN", "")
    var conn: Connection
    if dsn:
        conn = Connection(dsn)
    else:
        conn = Connection(
            ConnectionConfig(
                host="localhost",
                port=5432,
                dbname="postgres",
                user="postgres",
                password="postgres",
                connect_timeout=5,
            )
        )

    _ = conn.execute("DROP TABLE IF EXISTS mojo_events")
    _ = conn.execute(
        "CREATE TABLE mojo_events ("
        "  id serial primary key,"
        "  name text not null,"
        "  weight double precision,"
        "  ts timestamptz default now())"
    )

    # One prepared statement, run five times with different parameters.
    var ins = conn.prepare(
        "insert_event",
        "INSERT INTO mojo_events (name, weight) VALUES ($1, $2)",
    )
    for i in range(5):
        var affected = ins.execute(
            Params().text("event-" + String(i)).float64(Float64(i) * 1.5)
        )
        print("inserted", affected, "row(s)")

    # ... and one row deliberately left NULL, to show it reading back as NULL
    # rather than as a zero.
    _ = conn.execute(
        "INSERT INTO mojo_events (name, weight) VALUES ($1, $2)",
        Params().text("event-null").null(),
    )

    var res = conn.query("SELECT id, name, weight FROM mojo_events ORDER BY id")
    print("\n", res.num_rows(), "rows in mojo_events:")
    for row in res:
        var weight = row.opt_text("weight")
        print(
            " ",
            row.int32("id"),
            row.text("name"),
            weight.value() if weight else String("NULL"),
        )
