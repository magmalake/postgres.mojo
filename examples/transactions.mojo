"""A transaction with a savepoint, and the `with` block's rollback-by-default.

    sh scripts/with-pg-server.sh sh -c \
        'mojo run -I src examples/transactions.mojo'
"""

from std.os import getenv

from postgres import Connection, Params


def main() raises:
    var dsn = getenv("POSTGRES_TEST_DSN", "postgresql://localhost/postgres")
    var conn = Connection(dsn)

    _ = conn.execute("DROP TABLE IF EXISTS tx_accounts")
    _ = conn.execute("CREATE TABLE tx_accounts (id bigint primary key)")

    # A savepoint is how a statement that fails inside a block is survived --
    # PostgreSQL otherwise refuses everything until the block ends.
    var tx = conn.begin()
    _ = tx.execute("INSERT INTO tx_accounts VALUES ($1)", Params().int64(1))
    tx.savepoint("maybe")
    try:
        _ = tx.execute("INSERT INTO tx_accounts VALUES ($1)", Params().int64(1))
    except:
        tx.rollback_to("maybe")  # the duplicate is undone; row 1 stays
    _ = tx.execute("INSERT INTO tx_accounts VALUES ($1)", Params().int64(2))
    tx.commit()

    var count = (
        conn.query("SELECT count(*) AS n FROM tx_accounts").row(0).int64("n")
    )
    print("after commit:", count, "rows")  # 2

    # Leaving a `with` block WITHOUT calling commit() rolls back -- there is
    # no implicit commit anywhere in `Transaction`.
    with conn.begin() as forgotten:
        _ = forgotten.execute(
            "INSERT INTO tx_accounts VALUES ($1)", Params().int64(3)
        )
        # no commit() here

    count = (
        conn.query("SELECT count(*) AS n FROM tx_accounts").row(0).int64("n")
    )
    print("after the forgotten block:", count, "rows")  # still 2

    _ = conn.execute("DROP TABLE tx_accounts")
