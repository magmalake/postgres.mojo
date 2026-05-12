"""Minimal insert example.

Creates a temp table, inserts a few rows, reads them back. Bring up a
local Postgres (see `query_basic.mojo`) before running.
"""

from postgres import Connection, ConnectionConfig


fn main() raises:
    var conn = Connection(
        ConnectionConfig(
            host="localhost",
            port=5432,
            dbname="postgres",
            user="postgres",
            password="postgres",
        )
    )

    _ = conn.query("DROP TABLE IF EXISTS mojo_events")
    _ = conn.query(
        "CREATE TABLE mojo_events (id SERIAL PRIMARY KEY, name TEXT, ts"
        " TIMESTAMPTZ DEFAULT now())"
    )

    for i in range(5):
        var sql = (
            "INSERT INTO mojo_events (name) VALUES ('event-" + String(i) + "')"
        )
        var ins = conn.query(sql)
        print("inserted", ins.rows_affected(), "row(s)")

    var res = conn.query("SELECT id, name FROM mojo_events ORDER BY id")
    print("\n", res.nrows(), "rows in mojo_events:")
    for row in range(res.nrows()):
        print(" ", res.value(row, 0), res.value(row, 1))
