"""Smoke tests — no Postgres server required."""

from postgres import ConnectionConfig, libpq_version


def test_libpq_loadable():
    """If `libpq.so` isn't on the loader path, this errors at link time."""
    var v = libpq_version()
    assert_true(v > 0)


def test_config_defaults():
    var cfg = ConnectionConfig()
    assert_equal(cfg.host, String("localhost"))
    assert_equal(cfg.port, 5432)
    assert_equal(cfg.application_name, String("mojo-postgres"))
    assert_equal(cfg.sslmode, String("prefer"))


def test_conninfo_render():
    var cfg = ConnectionConfig(
        host="db.example.com",
        port=5433,
        dbname="prod",
        user="reader",
        password="hunter2",
    )
    var s = cfg.to_conninfo()
    assert_contains(s, "host=db.example.com")
    assert_contains(s, "port=5433")
    assert_contains(s, "dbname=prod")
    assert_contains(s, "user=reader")
    assert_contains(s, "password=hunter2")
    assert_contains(s, "application_name=mojo-postgres")


def test_conninfo_quotes_values_with_spaces():
    var cfg = ConnectionConfig(password="a b c")
    var s = cfg.to_conninfo()
    assert_contains(s, "password='a b c'")


def test_extra_passthrough():
    var cfg = ConnectionConfig()
    cfg.set("target_session_attrs", "read-write")
    var s = cfg.to_conninfo()
    assert_contains(s, "target_session_attrs=read-write")


fn assert_true(b: Bool) raises:
    if not b:
        raise Error("assertion failed")


fn assert_equal[T: EqualityComparable & Stringable](a: T, b: T) raises:
    if a != b:
        raise Error("expected " + String(b) + " got " + String(a))


fn assert_contains(haystack: String, needle: String) raises:
    if haystack.find(needle) < 0:
        raise Error("expected '" + haystack + "' to contain '" + needle + "'")
