"""`postgres.copyfmt` — encode and parse rows for PostgreSQL's COPY text and
CSV sub-formats.

`COPY ... TO/FROM STDOUT/STDIN` streams raw bytes over
`PQputCopyData`/`PQgetCopyData` (wired up separately, in `copy.mojo`). This
module is the pure-Mojo codec for what flows through that pipe: `CopyEncoder`
builds row bytes a caller hands to `PQputCopyData` in chunks via `take()`;
`CopyDecoder` (and the free `decode_row`/`split_rows` functions) turn bytes
delivered by `PQgetCopyData` back into typed fields. Neither type touches
libpq — see
https://www.postgresql.org/docs/current/sql-copy.html ("Text Format" and
"CSV Format") for the wire formats implemented here.

A COPY row is a list of fields, each either NULL or a text value; this module
represents that as `List[Optional[String]]` — `None` is NULL, `Optional[String]("")`
is a real empty string, which text format and (quoted) CSV can both express
distinctly from NULL.
"""

comptime COPY_TEXT = 0
"""PostgreSQL's default COPY sub-format: tab-delimited, `\\N` for NULL,
backslash escapes."""
comptime COPY_CSV = 1
"""`COPY ... (FORMAT CSV)`: comma-delimited, double-quote quoting, empty
unquoted string for NULL."""

comptime _BACKSLASH: UInt8 = 92
comptime _DQUOTE: UInt8 = 34
comptime _LF: UInt8 = 10
comptime _CR: UInt8 = 13
comptime _TAB: UInt8 = 9
comptime _BACKSPACE: UInt8 = 8
comptime _FORMFEED: UInt8 = 12
comptime _VTAB: UInt8 = 11

# ASCII bytes for the named backslash-escape letters used by text format.
comptime _ESC_B: UInt8 = 98  # 'b'
comptime _ESC_F: UInt8 = 102  # 'f'
comptime _ESC_N: UInt8 = 110  # 'n'
comptime _ESC_R: UInt8 = 114  # 'r'
comptime _ESC_T: UInt8 = 116  # 't'
comptime _ESC_V: UInt8 = 118  # 'v'
comptime _ESC_X: UInt8 = 120  # 'x'


def _default_delimiter(format: Int) -> String:
    if format == COPY_CSV:
        return ","
    return "\t"


def _default_null(format: Int) -> String:
    if format == COPY_CSV:
        return ""
    return "\\N"


def _resolve_delim_byte(delimiter: String) raises -> UInt8:
    """PostgreSQL COPY delimiters are exactly one byte (never the CSV quote
    character); reject anything else up front rather than silently matching
    only the first byte."""
    if delimiter.byte_length() != 1:
        raise Error(
            "postgres.copyfmt: delimiter must be exactly one byte, got "
            + String(delimiter.byte_length())
            + " bytes ("
            + delimiter
            + ")"
        )
    var b = delimiter.as_bytes()[0]
    if b == _DQUOTE:
        raise Error(
            'postgres.copyfmt: delimiter cannot be the CSV quote character (")'
        )
    return b


# ===----------------------------------------------------------------------===#
# Encoding
# ===----------------------------------------------------------------------===#


struct CopyEncoder(Movable):
    """Builds COPY row bytes in `format`, ready for `PQputCopyData` in chunks
    via `take()`.

    Field values are escaped/quoted as they are appended, so the buffer is
    always valid COPY data up to the last completed row — `size()`/`take()`
    can be called mid-row, though a caller normally flushes only after
    `end_row()`.
    """

    var format: Int
    var delimiter: String
    var null_string: String
    var _delim_byte: UInt8
    var _buf: List[UInt8]
    var _row_has_field: Bool

    def __init__(
        out self,
        format: Int = COPY_TEXT,
        delimiter: Optional[String] = None,
        null: Optional[String] = None,
    ) raises:
        """Configure the encoder.

        Args:

        format: `COPY_TEXT` or `COPY_CSV`.
        delimiter: One-byte field separator. Defaults to tab (text) or comma
            (CSV).
        null: The NULL marker. Defaults to `\\N` (text) or the empty string
            (CSV) — PostgreSQL's own defaults for each sub-format.
        """
        if format != COPY_TEXT and format != COPY_CSV:
            raise Error(
                "postgres.copyfmt: unknown COPY format " + String(format)
            )
        self.format = format
        if delimiter:
            self.delimiter = delimiter.value()
        else:
            self.delimiter = _default_delimiter(format)
        self._delim_byte = _resolve_delim_byte(self.delimiter)
        if null:
            self.null_string = null.value()
        else:
            self.null_string = _default_null(format)
        self._buf = List[UInt8]()
        self._row_has_field = False

    def _before_field(mut self):
        if self._row_has_field:
            self._buf.append(self._delim_byte)
        else:
            self._row_has_field = True

    def field(mut self, v: StringSlice):
        """Append a non-NULL field, escaping/quoting it for `self.format`."""
        self._before_field()
        if self.format == COPY_CSV:
            self._encode_csv_field(v)
        else:
            self._encode_text_field(v)

    def null(mut self):
        """Append a NULL field (the raw, unescaped null marker)."""
        self._before_field()
        for b in self.null_string.as_bytes():
            self._buf.append(b)

    def end_row(mut self):
        """Terminate the current row with `\\n` and reset for the next one."""
        self._buf.append(_LF)
        self._row_has_field = False

    def row(mut self, values: List[Optional[String]]):
        """Convenience: append a whole row (`None` entries as NULL) and
        terminate it."""
        for v in values:
            if v:
                self.field(v.value())
            else:
                self.null()
        self.end_row()

    def _encode_text_field(mut self, v: StringSlice):
        # Named escapes take priority over the generic delimiter-escape rule
        # below: a tab is always written as `\t` (matching what `psql`
        # emits), never as backslash + a raw tab byte, even though the
        # default delimiter *is* tab and both would decode identically.
        for b in v.as_bytes():
            if b == _BACKSLASH:
                self._buf.append(_BACKSLASH)
                self._buf.append(_BACKSLASH)
            elif b == _LF:
                self._buf.append(_BACKSLASH)
                self._buf.append(_ESC_N)
            elif b == _CR:
                self._buf.append(_BACKSLASH)
                self._buf.append(_ESC_R)
            elif b == _TAB:
                self._buf.append(_BACKSLASH)
                self._buf.append(_ESC_T)
            elif b == _BACKSPACE:
                self._buf.append(_BACKSLASH)
                self._buf.append(_ESC_B)
            elif b == _FORMFEED:
                self._buf.append(_BACKSLASH)
                self._buf.append(_ESC_F)
            elif b == _VTAB:
                self._buf.append(_BACKSLASH)
                self._buf.append(_ESC_V)
            elif b == self._delim_byte:
                self._buf.append(_BACKSLASH)
                self._buf.append(self._delim_byte)
            else:
                self._buf.append(b)

    def _csv_needs_quote(self, v: StringSlice) -> Bool:
        # Empty is quoted so it round-trips distinctly from an unquoted-empty
        # NULL marker; a field that happens to equal the null string is
        # quoted for the same reason.
        if v.byte_length() == 0:
            return True
        if String(v) == self.null_string:
            return True
        for b in v.as_bytes():
            if b == self._delim_byte or b == _DQUOTE or b == _LF or b == _CR:
                return True
        return False

    def _encode_csv_field(mut self, v: StringSlice):
        if self._csv_needs_quote(v):
            self._buf.append(_DQUOTE)
            for b in v.as_bytes():
                if b == _DQUOTE:
                    self._buf.append(_DQUOTE)
                    self._buf.append(_DQUOTE)
                else:
                    self._buf.append(b)
            self._buf.append(_DQUOTE)
        else:
            for b in v.as_bytes():
                self._buf.append(b)

    def size(self) -> Int:
        """Bytes currently buffered."""
        return len(self._buf)

    def take(mut self) -> List[UInt8]:
        """Hand back the buffered bytes and reset the buffer, so a caller can
        flush in chunks without losing anything already appended."""
        var out = self._buf^
        self._buf = List[UInt8]()
        return out^

    def bytes(ref self) -> Span[UInt8, origin_of(self._buf)]:
        """A read-only view of the currently buffered bytes, without taking
        them."""
        return Span(self._buf)


# ===----------------------------------------------------------------------===#
# Decoding
# ===----------------------------------------------------------------------===#


def _is_octal_digit(b: UInt8) -> Bool:
    return b >= 48 and b <= 55


def _is_hex_digit(b: UInt8) -> Bool:
    return (
        (b >= 48 and b <= 57) or (b >= 97 and b <= 102) or (b >= 65 and b <= 70)
    )


def _hex_value(b: UInt8) -> UInt8:
    if b <= 57:
        return b - 48
    if b >= 97:
        return b - 97 + 10
    return b - 65 + 10


def _unescape_text(
    bytes: Span[UInt8, _], start: Int, end: Int
) raises -> String:
    """Backslash-unescape a raw text-format field. PostgreSQL defines named
    escapes for `\\b \\f \\n \\r \\t \\v \\\\`, octal (`\\ddd`, up to 3 digits)
    and hex (`\\xHH`, up to 2 digits); any other character following a
    backslash is emitted literally with the backslash dropped."""
    var out = List[UInt8]()
    var i = start
    while i < end:
        var b = bytes[i]
        if b == _BACKSLASH and i + 1 < end:
            var c = bytes[i + 1]
            if c == _ESC_B:
                out.append(_BACKSPACE)
                i += 2
            elif c == _ESC_F:
                out.append(_FORMFEED)
                i += 2
            elif c == _ESC_N:
                out.append(_LF)
                i += 2
            elif c == _ESC_R:
                out.append(_CR)
                i += 2
            elif c == _ESC_T:
                out.append(_TAB)
                i += 2
            elif c == _ESC_V:
                out.append(_VTAB)
                i += 2
            elif c == _BACKSLASH:
                out.append(_BACKSLASH)
                i += 2
            elif _is_octal_digit(c):
                var value: UInt8 = c - 48
                var j = i + 2
                var count = 1
                while count < 3 and j < end and _is_octal_digit(bytes[j]):
                    value = value * 8 + (bytes[j] - 48)
                    j += 1
                    count += 1
                out.append(value)
                i = j
            elif c == _ESC_X:
                var value: UInt8 = 0
                var j = i + 2
                var count = 0
                while count < 2 and j < end and _is_hex_digit(bytes[j]):
                    value = value * 16 + _hex_value(bytes[j])
                    j += 1
                    count += 1
                if count == 0:
                    out.append(c)
                    i += 2
                else:
                    out.append(value)
                    i = j
            else:
                out.append(c)
                i += 2
        else:
            out.append(b)
            i += 1
    return String(from_utf8=Span(out))


def _raw_equals_null(
    bytes: Span[UInt8, _], start: Int, end: Int, null_string: String
) -> Bool:
    """True when the raw (still-escaped) field bytes exactly match the null
    marker — checked *before* unescaping, which is what makes `\\N` (NULL)
    and `\\\\N` (the literal two-character string `\\N`) distinguishable."""
    var nb = null_string.as_bytes()
    if end - start != len(nb):
        return False
    var i = start
    var j = 0
    while i < end:
        if bytes[i] != nb[j]:
            return False
        i += 1
        j += 1
    return True


def _decode_text_row(
    line: StringSlice, delim_byte: UInt8, null_string: String
) raises -> List[Optional[String]]:
    var result = List[Optional[String]]()
    var bytes = line.as_bytes()
    var n = len(bytes)
    var i = 0
    var field_start = 0
    while i < n:
        var b = bytes[i]
        if b == delim_byte:
            if _raw_equals_null(bytes, field_start, i, null_string):
                result.append(None)
            else:
                result.append(
                    Optional[String](_unescape_text(bytes, field_start, i))
                )
            i += 1
            field_start = i
        elif b == _BACKSLASH:
            if i + 1 < n:
                i += 2
            else:
                i += 1
        else:
            i += 1
    if _raw_equals_null(bytes, field_start, n, null_string):
        result.append(None)
    else:
        result.append(Optional[String](_unescape_text(bytes, field_start, n)))
    return result^


def _decode_csv_row(
    line: StringSlice, delim_byte: UInt8, null_string: String
) raises -> List[Optional[String]]:
    var result = List[Optional[String]]()
    var bytes = line.as_bytes()
    var n = len(bytes)
    var i = 0
    while True:
        if i < n and bytes[i] == _DQUOTE:
            i += 1
            var out = List[UInt8]()
            while True:
                if i >= n:
                    raise Error(
                        "postgres.copyfmt: unterminated quoted CSV field"
                    )
                if bytes[i] == _DQUOTE:
                    if i + 1 < n and bytes[i + 1] == _DQUOTE:
                        out.append(_DQUOTE)
                        i += 2
                    else:
                        i += 1
                        break
                else:
                    out.append(bytes[i])
                    i += 1
            # A quoted field is never NULL, even if it equals the null
            # marker's text — that is exactly why the encoder quotes it.
            result.append(Optional[String](String(from_utf8=Span(out))))
            while i < n and bytes[i] != delim_byte:
                i += 1
        else:
            var start = i
            while i < n and bytes[i] != delim_byte:
                i += 1
            var text = String(from_utf8=bytes[start:i])
            if text == null_string:
                result.append(None)
            else:
                result.append(Optional[String](text))
        if i < n:
            i += 1  # consume the delimiter; another field follows
        else:
            break
    return result^


def decode_row(
    line: StringSlice, format: Int, delimiter: String, null: String
) raises -> List[Optional[String]]:
    """Parse one line of `COPY ... TO STDOUT` output into its fields.

    `line` must not include the trailing newline (`split_rows` strips it).
    """
    var delim_byte = _resolve_delim_byte(delimiter)
    if format == COPY_CSV:
        return _decode_csv_row(line, delim_byte, null)
    return _decode_text_row(line, delim_byte, null)


struct CopyDecoder(Movable):
    """`decode_row` bound to a fixed format/delimiter/null configuration, for
    callers decoding many rows of the same COPY stream."""

    var format: Int
    var delimiter: String
    var null_string: String

    def __init__(
        out self,
        format: Int = COPY_TEXT,
        delimiter: Optional[String] = None,
        null: Optional[String] = None,
    ) raises:
        if format != COPY_TEXT and format != COPY_CSV:
            raise Error(
                "postgres.copyfmt: unknown COPY format " + String(format)
            )
        self.format = format
        if delimiter:
            self.delimiter = delimiter.value()
        else:
            self.delimiter = _default_delimiter(format)
        _ = _resolve_delim_byte(self.delimiter)  # validate eagerly
        if null:
            self.null_string = null.value()
        else:
            self.null_string = _default_null(format)

    def decode_row(self, line: StringSlice) raises -> List[Optional[String]]:
        return decode_row(line, self.format, self.delimiter, self.null_string)


def split_rows(buffer: Span[UInt8, _]) raises -> Tuple[List[String], String]:
    """Split a buffer of concatenated COPY row bytes on `\\n`, returning the
    complete lines (newline stripped) and any trailing partial line still
    waiting for more bytes.

    This is a byte-oriented batching helper for the common case where
    `PQgetCopyData` results have been concatenated before parsing — it does
    not track CSV quote state, so a row containing a *raw* embedded newline
    (a CSV field with a real newline inside quotes) is indistinguishable here
    from a row boundary. `PQgetCopyData` itself always delivers one complete
    row per call regardless of embedded newlines; feed `decode_row` from
    those calls directly if embedded raw newlines are possible.
    """
    var lines = List[String]()
    var n = len(buffer)
    var start = 0
    var i = 0
    while i < n:
        if buffer[i] == _LF:
            lines.append(String(from_utf8=buffer[start:i]))
            start = i + 1
        i += 1
    var remainder = String(from_utf8=buffer[start:n])
    return (lines^, remainder^)
