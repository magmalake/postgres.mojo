"""Unit tests for `postgres.config` — no server required.

Ported from the pre-1.0 `tests/test_smoke.mojo` config cases (see
`git show 708136f:tests/test_smoke.mojo`), plus coverage for the quoting
edge cases and the ordered `extra` list added in the 1.x rewrite."""

from std.testing import TestSuite, assert_equal, assert_true

from postgres.config import ConnectionConfig


def _contains(haystack: String, needle: String) -> Bool:
    return haystack.find(needle) >= 0


# ── ported from test_smoke.mojo ──────────────────────────────────────────


def test_config_defaults() raises:
    var cfg = ConnectionConfig()
    assert_equal(cfg.host, String("localhost"))
    assert_equal(cfg.port, 5432)
    assert_equal(cfg.dbname, String(""))
    assert_equal(cfg.user, String(""))
    assert_equal(cfg.password, String(""))
    assert_equal(cfg.application_name, String("postgres.mojo"))
    assert_equal(cfg.sslmode, String("prefer"))
    assert_equal(cfg.connect_timeout, 10)


def test_conninfo_render() raises:
    var cfg = ConnectionConfig(
        host="db.example.com",
        port=5433,
        dbname="prod",
        user="reader",
        password="hunter2",
    )
    var s = cfg.to_conninfo()
    assert_true(_contains(s, "host=db.example.com"))
    assert_true(_contains(s, "port=5433"))
    assert_true(_contains(s, "dbname=prod"))
    assert_true(_contains(s, "user=reader"))
    assert_true(_contains(s, "password=hunter2"))
    assert_true(_contains(s, "application_name=postgres.mojo"))


def test_conninfo_quotes_values_with_spaces() raises:
    var cfg = ConnectionConfig(password="a b c")
    var s = cfg.to_conninfo()
    assert_true(_contains(s, "password='a b c'"))


def test_extra_passthrough() raises:
    var cfg = ConnectionConfig()
    cfg.set("target_session_attrs", "read-write")
    var s = cfg.to_conninfo()
    assert_true(_contains(s, "target_session_attrs=read-write"))


def test_libpq_loadable() raises:
    """The pre-1.0 smoke suite paired this with a `libpq_version()` FFI
    call (out of scope for this server-free module); config rendering
    itself needs no library, so this just confirms the type stays
    constructible with no arguments at all."""
    var cfg = ConnectionConfig()
    assert_true(cfg.to_conninfo().byte_length() > 0)


# ── new coverage for the 1.x rewrite ─────────────────────────────────────


def test_empty_value_is_quoted_empty() raises:
    var cfg = ConnectionConfig(dbname="", user="x")
    # dbname is omitted entirely when empty (matches upstream), so exercise
    # the empty-value quoting rule directly through set().
    cfg.set("options", "")
    var s = cfg.to_conninfo()
    assert_true(_contains(s, "options=''"))


def test_backslash_and_quote_escaping() raises:
    var cfg = ConnectionConfig(password="back\\slash'quote")
    var s = cfg.to_conninfo()
    assert_true(_contains(s, "password='back\\\\slash\\'quote'"))


def test_tab_and_newline_force_quoting() raises:
    var cfg = ConnectionConfig(password="a\tb")
    var s = cfg.to_conninfo()
    assert_true(_contains(s, "password='a\tb'"))


def test_set_replaces_existing_key() raises:
    var cfg = ConnectionConfig()
    cfg.set("options", "first")
    cfg.set("options", "second")
    var s = cfg.to_conninfo()
    assert_true(_contains(s, "options=second"))
    assert_true(not _contains(s, "first"))
    # Replacing in place means the key appears exactly once.
    var first_pos = s.find("options=")
    var second_pos = s.find("options=", first_pos + 1)
    assert_true(second_pos < 0)


def test_extra_key_order_is_insertion_order() raises:
    var cfg = ConnectionConfig()
    cfg.set("z_first", "1")
    cfg.set("a_second", "2")
    cfg.set("m_third", "3")
    var s = cfg.to_conninfo()
    var pos_z = s.find("z_first=1")
    var pos_a = s.find("a_second=2")
    var pos_m = s.find("m_third=3")
    assert_true(pos_z >= 0 and pos_a >= 0 and pos_m >= 0)
    assert_true(pos_z < pos_a)
    assert_true(pos_a < pos_m)


def test_bare_value_is_not_quoted() raises:
    var cfg = ConnectionConfig(user="reader")
    var s = cfg.to_conninfo()
    assert_true(_contains(s, "user=reader"))
    assert_true(not _contains(s, "user='reader'"))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
