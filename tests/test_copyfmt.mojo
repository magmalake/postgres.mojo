"""Tests for `postgres.copyfmt` — the COPY text/CSV row codec.

`test_psql_text_fixture` and `test_psql_csv_fixture` are literal fixtures
captured from a real server (`scripts/with-pg-server.sh`), so this file
doubles as a check that the encoder matches what `psql`'s
`COPY (SELECT ...) TO STDOUT` actually emits — see the comment above each
fixture for the exact query used to generate it.
"""
from std.testing import TestSuite, assert_equal, assert_true, assert_raises

from postgres.copyfmt import (
    COPY_TEXT,
    COPY_CSV,
    CopyEncoder,
    CopyDecoder,
    decode_row,
    split_rows,
)


# ===----------------------------------------------------------------------===#
# Text format — encoding
# ===----------------------------------------------------------------------===#


def test_text_encode_plain_field() raises:
    var enc = CopyEncoder(COPY_TEXT)
    enc.field("hello")
    enc.end_row()
    var bytes = enc.take()
    assert_equal(String(from_utf8=Span(bytes)), "hello\n")


def test_text_encode_escapes_backslash() raises:
    var enc = CopyEncoder(COPY_TEXT)
    enc.field("a\\b")
    enc.end_row()
    assert_equal(String(from_utf8=Span(enc.take())), "a\\\\b\n")


def test_text_encode_escapes_default_delimiter_tab() raises:
    var enc = CopyEncoder(COPY_TEXT)
    enc.field("a\tb")
    enc.end_row()
    assert_equal(String(from_utf8=Span(enc.take())), "a\\tb\n")


def test_text_encode_escapes_newline_and_cr() raises:
    var enc = CopyEncoder(COPY_TEXT)
    enc.field("a\nb\rc")
    enc.end_row()
    assert_equal(String(from_utf8=Span(enc.take())), "a\\nb\\rc\n")


def test_text_encode_escapes_backspace_formfeed_vtab() raises:
    var enc = CopyEncoder(COPY_TEXT)
    enc.field(String(chr(8)) + String(chr(12)) + String(chr(11)))
    enc.end_row()
    assert_equal(String(from_utf8=Span(enc.take())), "\\b\\f\\v\n")


def test_text_encode_escapes_non_tab_delimiter_when_overridden() raises:
    var enc = CopyEncoder(COPY_TEXT, delimiter=";")
    enc.field("a;b")
    enc.field("tab\there")
    enc.end_row()
    # ';' must be escaped (it's now the delimiter); plain tab must *also*
    # still be escaped even though it is no longer the delimiter.
    assert_equal(String(from_utf8=Span(enc.take())), "a\\;b;tab\\there\n")


def test_text_encode_null() raises:
    var enc = CopyEncoder(COPY_TEXT)
    enc.field("a")
    enc.null()
    enc.field("b")
    enc.end_row()
    assert_equal(String(from_utf8=Span(enc.take())), "a\t\\N\tb\n")


def test_text_encode_field_equal_to_null_string_is_escaped() raises:
    # A real string "\N" must not become indistinguishable from NULL: the
    # backslash escaping rules already make this so (backslash always
    # escapes), producing the 3-byte raw sequence \\N, not the 2-byte \N.
    var enc = CopyEncoder(COPY_TEXT)
    enc.field("\\N")
    enc.end_row()
    assert_equal(String(from_utf8=Span(enc.take())), "\\\\N\n")


def test_text_encode_multi_row() raises:
    var enc = CopyEncoder(COPY_TEXT)
    enc.field("a")
    enc.end_row()
    enc.field("b")
    enc.end_row()
    assert_equal(String(from_utf8=Span(enc.take())), "a\nb\n")


def test_take_resets_buffer() raises:
    var enc = CopyEncoder(COPY_TEXT)
    enc.field("a")
    enc.end_row()
    assert_true(enc.size() > 0)
    var first = enc.take()
    assert_equal(enc.size(), 0)
    var second = enc.take()
    assert_equal(len(second), 0)
    assert_true(len(first) > 0)


def test_bytes_view_does_not_take() raises:
    var enc = CopyEncoder(COPY_TEXT)
    enc.field("a")
    enc.end_row()
    var view_len = len(enc.bytes())
    assert_equal(enc.size(), view_len)
    assert_true(enc.size() > 0)


def test_row_convenience_with_optional_null() raises:
    var enc = CopyEncoder(COPY_TEXT)
    var values: List[Optional[String]] = [
        Optional[String]("a"),
        None,
        Optional[String](""),
    ]
    enc.row(values)
    assert_equal(String(from_utf8=Span(enc.take())), "a\t\\N\t\n")


# ===----------------------------------------------------------------------===#
# CSV format — encoding
# ===----------------------------------------------------------------------===#


def test_csv_encode_plain_field() raises:
    var enc = CopyEncoder(COPY_CSV)
    enc.field("hello")
    enc.end_row()
    assert_equal(String(from_utf8=Span(enc.take())), "hello\n")


def test_csv_encode_quotes_delimiter() raises:
    var enc = CopyEncoder(COPY_CSV)
    enc.field("a,b")
    enc.end_row()
    assert_equal(String(from_utf8=Span(enc.take())), '"a,b"\n')


def test_csv_encode_doubles_embedded_quote() raises:
    var enc = CopyEncoder(COPY_CSV)
    enc.field('x"y')
    enc.end_row()
    assert_equal(String(from_utf8=Span(enc.take())), '"x""y"\n')


def test_csv_encode_quotes_newline_and_cr() raises:
    var enc = CopyEncoder(COPY_CSV)
    enc.field("a\nb\rc")
    enc.end_row()
    assert_equal(String(from_utf8=Span(enc.take())), '"a\nb\rc"\n')


def test_csv_encode_null_is_bare_unquoted_marker() raises:
    var enc = CopyEncoder(COPY_CSV)
    enc.field("a")
    enc.null()
    enc.end_row()
    assert_equal(String(from_utf8=Span(enc.take())), "a,\n")


def test_csv_encode_empty_string_is_quoted_distinct_from_null() raises:
    var enc = CopyEncoder(COPY_CSV)
    enc.field("")
    enc.null()
    enc.end_row()
    assert_equal(String(from_utf8=Span(enc.take())), '"",\n')


def test_csv_encode_field_equal_to_null_string_is_quoted() raises:
    var enc = CopyEncoder(COPY_CSV, null="NULL")
    enc.field("NULL")
    enc.end_row()
    assert_equal(String(from_utf8=Span(enc.take())), '"NULL"\n')


def test_csv_encode_custom_delimiter() raises:
    var enc = CopyEncoder(COPY_CSV, delimiter=";")
    enc.field("a,b")
    enc.field("c;d")
    enc.end_row()
    # ',' is a plain character now that the delimiter is ';' — only the
    # field containing the *configured* delimiter needs quoting.
    assert_equal(String(from_utf8=Span(enc.take())), 'a,b;"c;d"\n')


# ===----------------------------------------------------------------------===#
# Text format — decoding
# ===----------------------------------------------------------------------===#


def test_text_decode_plain_row() raises:
    var got = decode_row("a\tb\tc", COPY_TEXT, "\t", "\\N")
    assert_equal(len(got), 3)
    assert_equal(got[0].value(), "a")
    assert_equal(got[1].value(), "b")
    assert_equal(got[2].value(), "c")


def test_text_decode_null() raises:
    var got = decode_row("a\t\\N\tb", COPY_TEXT, "\t", "\\N")
    assert_equal(got[0].value(), "a")
    assert_true(not got[1])
    assert_equal(got[2].value(), "b")


def test_text_decode_escaped_backslash_n_is_not_null() raises:
    # Raw two-char sequence \N is NULL; raw \\N (escaped backslash + N) is
    # the literal string "\N".
    var got = decode_row("\\\\N", COPY_TEXT, "\t", "\\N")
    assert_equal(len(got), 1)
    assert_equal(got[0].value(), "\\N")


def test_text_decode_named_escapes() raises:
    var got = decode_row(
        "a\\tb\\nc\\rd\\be\\ff\\vg\\\\h", COPY_TEXT, "\t", "\\N"
    )
    assert_equal(len(got), 1)
    assert_equal(
        got[0].value(),
        "a"
        + String(chr(9))
        + "b"
        + String(chr(10))
        + "c"
        + String(chr(13))
        + "d"
        + String(chr(8))
        + "e"
        + String(chr(12))
        + "f"
        + String(chr(11))
        + "g"
        + "\\"
        + "h",
    )


def test_text_decode_octal_escape() raises:
    # \101 = 'A' (octal 101 = decimal 65).
    var got = decode_row("x\\101y", COPY_TEXT, "\t", "\\N")
    assert_equal(got[0].value(), "xAy")


def test_text_decode_hex_escape() raises:
    # \x41 = 'A'.
    var got = decode_row("x\\x41y", COPY_TEXT, "\t", "\\N")
    assert_equal(got[0].value(), "xAy")


def test_text_decode_unrecognized_escape_drops_backslash() raises:
    var got = decode_row("a\\qb", COPY_TEXT, "\t", "\\N")
    assert_equal(got[0].value(), "aqb")


def test_text_decode_escaped_delimiter_not_a_boundary() raises:
    var got = decode_row("a\\\tb\tc", COPY_TEXT, "\t", "\\N")
    assert_equal(len(got), 2)
    assert_equal(got[0].value(), "a\tb")
    assert_equal(got[1].value(), "c")


def test_text_decode_empty_field_is_empty_string_not_null() raises:
    var got = decode_row("a\t\tb", COPY_TEXT, "\t", "\\N")
    assert_equal(got[1].value(), "")


def test_text_decode_custom_delimiter() raises:
    var got = decode_row("a;b;c", COPY_TEXT, ";", "\\N")
    assert_equal(len(got), 3)
    assert_equal(got[1].value(), "b")


# ===----------------------------------------------------------------------===#
# CSV format — decoding
# ===----------------------------------------------------------------------===#


def test_csv_decode_plain_row() raises:
    var got = decode_row("a,b,c", COPY_CSV, ",", "")
    assert_equal(len(got), 3)
    assert_equal(got[0].value(), "a")
    assert_equal(got[1].value(), "b")
    assert_equal(got[2].value(), "c")


def test_csv_decode_quoted_field_with_delimiter() raises:
    var got = decode_row('"a,b",c', COPY_CSV, ",", "")
    assert_equal(got[0].value(), "a,b")
    assert_equal(got[1].value(), "c")


def test_csv_decode_doubled_quote() raises:
    var got = decode_row('"x""y"', COPY_CSV, ",", "")
    assert_equal(got[0].value(), 'x"y')


def test_csv_decode_unquoted_null_marker() raises:
    var got = decode_row("a,,b", COPY_CSV, ",", "")
    assert_equal(got[0].value(), "a")
    assert_true(not got[1])
    assert_equal(got[2].value(), "b")


def test_csv_decode_quoted_empty_is_empty_string_not_null() raises:
    var got = decode_row('a,"",b', COPY_CSV, ",", "")
    assert_equal(got[0].value(), "a")
    assert_true(got[1])
    assert_equal(got[1].value(), "")
    assert_equal(got[2].value(), "b")


def test_csv_decode_quoted_field_equal_to_null_string_is_not_null() raises:
    var got = decode_row('"NULL"', COPY_CSV, ",", "NULL")
    assert_true(got[0])
    assert_equal(got[0].value(), "NULL")


def test_csv_decode_unquoted_field_equal_to_custom_null() raises:
    var got = decode_row("NULL", COPY_CSV, ",", "NULL")
    assert_true(not got[0])


def test_csv_decode_embedded_newline_in_quotes() raises:
    var got = decode_row('"a\nb",c', COPY_CSV, ",", "")
    assert_equal(got[0].value(), "a\nb")
    assert_equal(got[1].value(), "c")


def test_csv_decode_unterminated_quote_raises() raises:
    with assert_raises():
        _ = decode_row('"abc', COPY_CSV, ",", "")


# ===----------------------------------------------------------------------===#
# CopyDecoder (bound configuration)
# ===----------------------------------------------------------------------===#


def test_copy_decoder_text() raises:
    var dec = CopyDecoder(COPY_TEXT)
    var got = dec.decode_row("a\t\\N")
    assert_equal(got[0].value(), "a")
    assert_true(not got[1])


def test_copy_decoder_csv_custom_delimiter() raises:
    var dec = CopyDecoder(COPY_CSV, delimiter=";")
    var got = dec.decode_row("a;b")
    assert_equal(got[0].value(), "a")
    assert_equal(got[1].value(), "b")


def test_encoder_rejects_multi_byte_delimiter() raises:
    with assert_raises():
        _ = CopyEncoder(COPY_TEXT, delimiter="ab")


def test_encoder_rejects_quote_as_delimiter() raises:
    with assert_raises():
        _ = CopyEncoder(COPY_CSV, delimiter='"')


# ===----------------------------------------------------------------------===#
# split_rows
# ===----------------------------------------------------------------------===#


def test_split_rows_multi_row_buffer() raises:
    var buf: List[UInt8] = []
    for b in "row1\nrow2\nrow3\n".as_bytes():
        buf.append(b)
    var result = split_rows(Span(buf))
    var lines = result[0].copy()
    var remainder = result[1]
    assert_equal(len(lines), 3)
    assert_equal(lines[0], "row1")
    assert_equal(lines[1], "row2")
    assert_equal(lines[2], "row3")
    assert_equal(remainder, "")


def test_split_rows_partial_trailing_line() raises:
    var buf: List[UInt8] = []
    for b in "row1\nrow2\npartial".as_bytes():
        buf.append(b)
    var result = split_rows(Span(buf))
    var lines = result[0].copy()
    var remainder = result[1]
    assert_equal(len(lines), 2)
    assert_equal(lines[1], "row2")
    assert_equal(remainder, "partial")


def test_split_rows_empty_buffer() raises:
    var buf = List[UInt8]()
    var result = split_rows(Span(buf))
    assert_equal(len(result[0]), 0)
    assert_equal(result[1], "")


def test_split_rows_no_newline_is_all_remainder() raises:
    var buf: List[UInt8] = []
    for b in "onlypartial".as_bytes():
        buf.append(b)
    var result = split_rows(Span(buf))
    assert_equal(len(result[0]), 0)
    assert_equal(result[1], "onlypartial")


# ===----------------------------------------------------------------------===#
# Round trip over tricky strings
# ===----------------------------------------------------------------------===#


def test_round_trip_text_tricky_strings() raises:
    var cases: List[String] = [
        "plain",
        "",
        "tab\there",
        "newline\nhere",
        "cr\rhere",
        "back\\slash",
        'quote"here',
        "\\N",
        "a\\Nb",
        "unicode: héllo wörld 日本語 🎉",
        String(chr(8)) + String(chr(12)) + String(chr(11)),
    ]
    for i in range(len(cases)):
        var enc = CopyEncoder(COPY_TEXT)
        enc.field(cases[i])
        enc.end_row()
        var raw = enc.take()
        var result = split_rows(Span(raw))
        var lines = result[0].copy()
        assert_equal(len(lines), 1)
        var decoded = decode_row(lines[0], COPY_TEXT, "\t", "\\N")
        assert_equal(len(decoded), 1)
        assert_true(Bool(decoded[0]))
        assert_equal(decoded[0].value(), cases[i])


def test_round_trip_csv_tricky_strings() raises:
    var cases: List[String] = [
        "plain",
        "",
        "comma,here",
        'quote"here',
        "newline\nhere",
        "cr\rhere",
        "back\\slash",
        "unicode: héllo wörld 日本語 🎉",
    ]
    for i in range(len(cases)):
        var enc = CopyEncoder(COPY_CSV)
        enc.field(cases[i])
        enc.end_row()
        var raw = enc.take()
        # Strip the trailing newline ourselves, at the byte level:
        # split_rows is not safe for CSV fields with raw embedded newlines
        # (documented limitation), and this case list intentionally includes
        # one.
        assert_true(len(raw) > 0)
        var trimmed = String(from_utf8=Span(raw)[0 : len(raw) - 1])
        var decoded = decode_row(trimmed, COPY_CSV, ",", "")
        assert_equal(len(decoded), 1)
        assert_true(Bool(decoded[0]))
        assert_equal(decoded[0].value(), cases[i])


def test_round_trip_multi_row_text() raises:
    var enc = CopyEncoder(COPY_TEXT)
    var row1: List[Optional[String]] = [
        Optional[String]("a"),
        None,
        Optional[String]("c\td"),
    ]
    var row2: List[Optional[String]] = [
        Optional[String](""),
        Optional[String]("\\N"),
        None,
    ]
    enc.row(row1)
    enc.row(row2)
    var raw = enc.take()
    var result = split_rows(Span(raw))
    var lines = result[0].copy()
    assert_equal(len(lines), 2)

    var got1 = decode_row(lines[0], COPY_TEXT, "\t", "\\N")
    assert_equal(got1[0].value(), "a")
    assert_true(not got1[1])
    assert_equal(got1[2].value(), "c\td")

    var got2 = decode_row(lines[1], COPY_TEXT, "\t", "\\N")
    assert_equal(got2[0].value(), "")
    assert_equal(got2[1].value(), "\\N")
    assert_true(not got2[2])


# ===----------------------------------------------------------------------===#
# psql fixtures — captured from a real server via with-pg-server.sh, see
# scripts/pg-server.sh. Regenerate with:
#   psql "$POSTGRES_TEST_DSN" -c "COPY (SELECT E'a\\tb', NULL, 'x\"y', '') TO STDOUT"
#   psql "$POSTGRES_TEST_DSN" -c "COPY (SELECT E'a\\tb', NULL, 'x\"y', '') TO STDOUT (FORMAT CSV)"
# ===----------------------------------------------------------------------===#


def test_psql_text_fixture() raises:
    # `psql "$POSTGRES_TEST_DSN" -c "COPY (SELECT E'a\\tb', NULL, 'x\"y', '') TO STDOUT"`
    # printed exactly: a\tb<TAB>\N<TAB>x"y<TAB>\n  (fields: "a<TAB>b", NULL,
    # 'x"y', '') — captured against PostgreSQL 18.4 on this machine.
    var enc = CopyEncoder(COPY_TEXT)
    var row: List[Optional[String]] = [
        Optional[String]("a\tb"),
        None,
        Optional[String]('x"y'),
        Optional[String](""),
    ]
    enc.row(row)
    var got = String(from_utf8=Span(enc.take()))
    assert_equal(got, 'a\\tb\t\\N\tx"y\t\n')


def test_psql_csv_fixture() raises:
    # `psql "$POSTGRES_TEST_DSN" -c "COPY (SELECT E'a\\tb', NULL, 'x\"y', '') TO STDOUT (FORMAT CSV)"`
    # printed exactly: a<TAB>b,,"x""y",""  — captured against PostgreSQL 18.4
    # on this machine (a real tab is not special in CSV, so it is emitted
    # raw and unquoted).
    var enc = CopyEncoder(COPY_CSV)
    var row: List[Optional[String]] = [
        Optional[String]("a\tb"),
        None,
        Optional[String]('x"y'),
        Optional[String](""),
    ]
    enc.row(row)
    var got = String(from_utf8=Span(enc.take()))
    assert_equal(got, 'a\tb,,"x""y",""\n')


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
