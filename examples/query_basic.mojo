"""Connect, run a query, read typed rows -- including a NULL one.

    export POSTGRES_TEST_DSN=postgresql://postgres@localhost:5432/postgres
    mojo run -I src examples/query_basic.mojo

or, against the throwaway test cluster:

    sh scripts/with-pg-server.sh sh -c 'mojo run -I src examples/query_basic.mojo'
"""

from std.os import getenv

from postgres import Connection, Params


def main() raises:
    var dsn = getenv("POSTGRES_TEST_DSN", "postgresql://localhost/postgres")
    var conn = Connection(dsn)

    _ = conn.execute("DROP TABLE IF EXISTS qb_people")
    _ = conn.execute(
        "CREATE TABLE qb_people (id bigint primary key, name text, note text)"
    )
    _ = conn.execute(
        "INSERT INTO qb_people VALUES ($1, $2, $3), ($4, $5, $6)",
        Params()
        .int64(1)
        .text("Ada")
        .text("first")
        .int64(2)
        .text("Grace")
        .null(),
    )

    # By column name...
    var res = conn.query("SELECT id, name, note FROM qb_people ORDER BY id")
    for row in res:
        var note = "NULL" if row.is_null("note") else row.text("note")
        print(row.int64("id"), row.text("name"), note)

    # ... and by 0-based index, which works the same on a `Row` obtained
    # either way -- both ways resolve through the same column metadata.
    var first = res.row(0)
    print("by index:", first.int64(0), first.text(1))

    _ = conn.execute("DROP TABLE qb_people")
