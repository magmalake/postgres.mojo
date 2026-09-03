"""`Params`, typed `Row` accessors, NULL handling, and a prepared statement
run more than once.

    sh scripts/with-pg-server.sh sh -c \
        'mojo run -I src examples/params_and_statements.mojo'
"""

from std.os import getenv

from postgres import Connection, Params


def main() raises:
    var dsn = getenv("POSTGRES_TEST_DSN", "postgresql://localhost/postgres")
    var conn = Connection(dsn)

    _ = conn.execute("DROP TABLE IF EXISTS ps_events")
    _ = conn.execute(
        "CREATE TABLE ps_events (id bigint primary key, weight float8,"
        " tag text)"
    )

    # Preparing pays for parsing and planning once; each `execute` after
    # that sends only the name and the new parameter values.
    var ins = conn.prepare(
        "ins_event", "INSERT INTO ps_events VALUES ($1, $2, $3)"
    )
    for i in range(3):
        _ = ins.execute(
            Params()
            .int64(Int64(i))
            .float64(Float64(i) * 1.5)
            .text("row-" + String(i))
        )
    # A NULL weight, so the read side has something to distinguish from 0.0.
    _ = ins.execute(Params().int64(3).null().text("row-3"))

    var res = conn.query("SELECT id, weight, tag FROM ps_events ORDER BY id")
    for row in res:
        # `is_null` first, then the typed accessor -- calling `float64` on a
        # NULL cell raises rather than inventing a zero.
        if row.is_null("weight"):
            print(row.int64("id"), "weight=NULL", row.text("tag"))
        else:
            print(
                row.int64("id"),
                "weight=",
                row.float64("weight"),
                row.text("tag"),
            )

    # `opt_text` is the other way to read a nullable column: `None` for
    # NULL, the text otherwise, no `is_null` check needed first.
    var last = res.row(3)
    var opt = last.opt_text("weight")
    print("opt_text on the NULL row:", opt.value() if opt else "(NULL)")

    _ = conn.execute("DROP TABLE ps_events")
