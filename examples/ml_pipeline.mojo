"""Hero example: pull a feature table out of Postgres and run inference.

Reads a `(id, feature)` table out of Postgres, runs a toy "inference"
step on each row, and prints predictions. Swap `run_inference` for a
real MAX/Mojo model — the data-pull layer above it doesn't change.

This is the reason `mojo-postgres` exists: keep the data-path in Mojo
end-to-end so you don't pay a Python hop per row.
"""

from postgres import Connection, ConnectionConfig


fn run_inference(feature: Float64) -> Float64:
    """Stand-in for a real model. Logistic-ish over a single input."""
    var x = feature
    var s = 1.0 / (1.0 + (-x).exp())
    return s


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

    # Seed table so the example is runnable standalone.
    _ = conn.query("DROP TABLE IF EXISTS mojo_features")
    _ = conn.query(
        "CREATE TABLE mojo_features (id SERIAL PRIMARY KEY, x DOUBLE PRECISION)"
    )
    for i in range(5):
        _ = conn.query(
            "INSERT INTO mojo_features (x) VALUES ("
            + String(Float64(i) - 2.0)
            + ")"
        )

    print("Scoring rows from mojo_features:")
    var res = conn.query("SELECT id, x FROM mojo_features ORDER BY id")
    for row in range(res.nrows()):
        var id = res.value(row, 0)
        var x = Float64(atof(res.value(row, 1)))
        var y = run_inference(x)
        print("id=", id, " x=", x, " y_hat=", y)
