"""Bulk load with `CopyIn` + `CopyEncoder`, and read it back with `CopyOut`.

    sh scripts/with-pg-server.sh sh -c \
        'mojo run -I src examples/copy_roundtrip.mojo'
"""

from std.os import getenv

from postgres import COPY_TEXT, Connection, CopyEncoder, decode_row


def main() raises:
    var dsn = getenv("POSTGRES_TEST_DSN", "postgresql://localhost/postgres")
    var conn = Connection(dsn)

    _ = conn.execute("DROP TABLE IF EXISTS cp_rows")
    _ = conn.execute("CREATE TABLE cp_rows (id bigint, label text)")

    var cp = conn.copy_in("COPY cp_rows (id, label) FROM STDIN")
    var enc = CopyEncoder()
    for i in range(1000):
        enc.field(String(i))
        enc.field("row-" + String(i))
        enc.end_row()
        if enc.size() > 1 << 14:
            cp.write_rows(enc)  # flush whole rows as they accumulate
    cp.write_rows(enc)
    print(cp.finish(), "rows loaded")  # 1000

    var out = conn.copy_out("COPY cp_rows TO STDOUT")
    var lines = out.rows()
    print(len(lines), "rows read back")  # 1000
    var first = decode_row(lines[0], COPY_TEXT, "\t", "\\N")
    print("first row:", first[0].value(), first[1].value())

    _ = conn.execute("DROP TABLE cp_rows")
