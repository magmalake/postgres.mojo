"""Errors carry their SQLSTATE: `sqlstate_of(err)` reads it out of a caught
`Error`, and `Connection.last_error()` keeps the structured form with
predicates like `is_unique_violation`.

    sh scripts/with-pg-server.sh sh -c 'mojo run -I src examples/errors.mojo'
"""

from std.os import getenv

from postgres import Connection, Params, sqlstate_of


def main() raises:
    var dsn = getenv("POSTGRES_TEST_DSN", "postgresql://localhost/postgres")
    var conn = Connection(dsn)

    _ = conn.execute("DROP TABLE IF EXISTS err_people")
    _ = conn.execute("CREATE TABLE err_people (id bigint primary key)")
    _ = conn.execute("INSERT INTO err_people VALUES ($1)", Params().int64(1))

    try:
        _ = conn.execute(
            "INSERT INTO err_people VALUES ($1)", Params().int64(1)
        )
    except e:
        # The SQLSTATE travels inside the message; sqlstate_of reads it back.
        print("sqlstate_of(e) =", sqlstate_of(e))
        if sqlstate_of(e) == "23505":
            print("that id is already there")

    # `last_error()` keeps the structured `PostgresError` -- severity,
    # SQLSTATE, message, detail, hint, statement -- with predicates like
    # `is_unique_violation` so no string parsing is needed.
    if conn.last_error().is_unique_violation():
        print("last_error confirms a unique violation:")
        print(" ", conn.last_error().detail)

    # The connection is still usable: a rejected statement is not fatal.
    try:
        _ = conn.execute("SELECT * FROM no_such_table")
    except e:
        print("sqlstate_of(e) =", sqlstate_of(e))  # 42P01

    _ = conn.execute("DROP TABLE err_people")
