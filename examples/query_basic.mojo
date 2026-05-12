"""Minimal query example.

Bring up a local Postgres first:

    docker run -d --name=pg -p 5432:5432 \
        -e POSTGRES_PASSWORD=postgres postgres:16

Then:

    mojo run examples/query_basic.mojo
"""

from postgres import Connection, ConnectionConfig


fn main() raises:
    var cfg = ConnectionConfig(
        host="localhost",
        port=5432,
        dbname="postgres",
        user="postgres",
        password="postgres",
    )
    var conn = Connection(cfg)

    var res = conn.query(
        "SELECT version(), current_database(), current_user"
    )
    for col in range(res.ncols()):
        print(res.column_name(col), end=" | ")
    print()
    for row in range(res.nrows()):
        for col in range(res.ncols()):
            print(res.value(row, col), end=" | ")
        print()
