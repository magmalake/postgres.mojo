"""Minimal query example: connect, ask the server about itself, print a table.

Point it at any PostgreSQL. The quickest one to hand is the throwaway cluster
the tests use:

    sh scripts/with-pg-server.sh sh -c \
        'mojo run -I src examples/query_basic.mojo'

which exports `$POSTGRES_TEST_DSN` for the run. Otherwise set that variable
yourself, or edit the `ConnectionConfig` below:

    export POSTGRES_TEST_DSN=postgresql://postgres@localhost:5432/postgres
    mojo run -I src examples/query_basic.mojo
"""

from std.os import getenv

from postgres import Connection, ConnectionConfig


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

    print("server version:", conn.server_version())

    var res = conn.query(
        "SELECT current_database() AS db, current_user AS who, version() AS v"
    )

    var header = String("")
    for col in range(res.num_cols()):
        if col > 0:
            header += " | "
        header += res.column_name(col)
    print(header)

    for row in res:
        var line = String("")
        for col in range(row.num_cols()):
            if col > 0:
                line += " | "
            line += row.text(col)
        print(line)
