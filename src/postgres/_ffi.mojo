"""Runtime-loaded libpq FFI: `dlopen` + `dlsym` for every C entry point.

This is the only module in the package that talks to C.  Everything above it
(`connection.mojo`, `result.mojo`, `copy.mojo`) goes through the table defined
here, so a libpq bump or a loader change stays local.

**Why a direct `dlopen` and no C shim.**  libpq's public surface is opaque
pointers plus plain C scalars -- no structs by value, no callbacks we need, no
varargs -- so there is nothing for a shim to flatten.  Resolving the symbols at
compile time instead fails on Linux with ``JIT session error: Symbols not
found`` (the failure sqlite.mojo hit), because the Mojo JIT would have to find
them itself.  Loading the library at run time sidesteps that, and it also lets
us pick the conda-forge build out of ``$CONDA_PREFIX`` -- which matters,
because that build links OpenSSL, krb5 and OpenLDAP: it is the one where
``sslmode=require`` works.  ``RTLD.GLOBAL`` makes those transitive dependencies
visible to libpq and to each other, and ``RTLD.NODELETE`` turns ``dlclose``
into a no-op, which suits a handle the `_Global` below never closes: the image
stays resident, with its OpenSSL state intact, for the process lifetime.

**Handles are addresses, not pointers.**  ``PGconn *`` and ``PGresult *`` are
carried as `Int` (the pointer's address; 64-bit on every supported platform,
matching the C ABI on x86-64 and arm64).  This is sqlite.mojo's idiom, and here
it is not merely convenient: Mojo 1.x `Pointer` is non-nullable by construction
-- ``Pointer(unsafe_from_address=0)`` is a compile-time constraint failure --
while libpq returns NULL from `LibpqFFI.PQgetResult` (no more results),
`LibpqFFI.PQresultErrorField` (field absent) and `LibpqFFI.PQconnectdb` (out of
memory).  Those NULLs are load-bearing, so the null-carrying type has to be
`Int`, with ``0`` meaning NULL.  The aliases `PGconnPtr` and `PGresultPtr`
record which is which at the call site.

**Lifetime rules** -- the layer above owns all of these:

- `LibpqFFI.PQconnectdb` returns a `PGconnPtr` that must be released with
  `LibpqFFI.PQfinish` exactly once, *including* when `LibpqFFI.PQstatus`
  reports `CONNECTION_BAD`.  A failed connection still allocates.
- Every call returning a `PGresultPtr` (`LibpqFFI.PQexec`, `exec_params`,
  `LibpqFFI.PQprepare`, `exec_prepared`, `LibpqFFI.PQgetResult`) hands over
  ownership: call `LibpqFFI.PQclear` exactly once, even for
  `PGRES_FATAL_ERROR`.  ``0`` means out of memory or, for
  `LibpqFFI.PQgetResult`, "no more results"; do not clear it.
- C strings returned by libpq point into the `PGresult` or `PGconn` and die
  with it.  Every wrapper here copies them into an owned `String` before
  returning, so callers never hold a borrow and may clear at will.
- `LibpqFFI.PQgetCopyData` allocates its row buffer with ``malloc``; the
  wrapper copies it out and calls `LibpqFFI.PQfreemem` itself.
  `LibpqFFI.PQfreemem` is exposed only for symmetry and the escaping calls.

Do not call `LibpqFFI` methods from user code -- use `connection.mojo`.
"""

from std.ffi import _Global, OwnedDLHandle, RTLD, CStringSlice
from std.memory import Pointer
from std.os import abort, getenv
from std.sys.info import CompilationTarget


# -----------------------------------------------------------------------
# Handle aliases
# -----------------------------------------------------------------------

comptime PGconnPtr = Int
"""Address of a libpq ``PGconn *``.  ``0`` means NULL."""

comptime PGresultPtr = Int
"""Address of a libpq ``PGresult *``.  ``0`` means NULL."""


# -----------------------------------------------------------------------
# ConnStatusType (libpq-fe.h).  Only these two are meaningful for a
# synchronous client; the rest of the enum tracks async connect progress.
# -----------------------------------------------------------------------

comptime CONNECTION_OK = 0
"""The connection is usable."""
comptime CONNECTION_BAD = 1
"""The connection failed, or has since failed fatally, and cannot be used."""


# -----------------------------------------------------------------------
# ExecStatusType (libpq-fe.h), complete through PostgreSQL 18.
# -----------------------------------------------------------------------

comptime PGRES_EMPTY_QUERY = 0
"""The command string was empty."""
comptime PGRES_COMMAND_OK = 1
"""A command returning no rows completed."""
comptime PGRES_TUPLES_OK = 2
"""A row-returning command completed; the result holds the tuples."""
comptime PGRES_COPY_OUT = 3
"""``COPY ... TO STDOUT`` started; read with `LibpqFFI.PQgetCopyData`."""
comptime PGRES_COPY_IN = 4
"""``COPY ... FROM STDIN`` started; write with `LibpqFFI.PQputCopyData`."""
comptime PGRES_BAD_RESPONSE = 5
"""The server's reply could not be understood."""
comptime PGRES_NONFATAL_ERROR = 6
"""A notice or warning."""
comptime PGRES_FATAL_ERROR = 7
"""The command failed; the SQLSTATE is in `PG_DIAG_SQLSTATE`."""
comptime PGRES_COPY_BOTH = 8
"""Bidirectional COPY (streaming replication only)."""
comptime PGRES_SINGLE_TUPLE = 9
"""One row of a single-row-mode result."""
comptime PGRES_PIPELINE_SYNC = 10
"""Pipeline synchronisation point (PostgreSQL 14+)."""
comptime PGRES_PIPELINE_ABORTED = 11
"""Command skipped after an earlier failure in a pipeline (PostgreSQL 14+)."""
comptime PGRES_TUPLES_CHUNK = 12
"""A chunk of a chunked result set (PostgreSQL 17+)."""


# -----------------------------------------------------------------------
# PGTransactionStatusType (libpq-fe.h)
# -----------------------------------------------------------------------

comptime PQTRANS_IDLE = 0
"""Connection idle, no transaction block open."""
comptime PQTRANS_ACTIVE = 1
"""A command is in progress."""
comptime PQTRANS_INTRANS = 2
"""Idle inside a transaction block."""
comptime PQTRANS_INERROR = 3
"""Idle inside a *failed* transaction block; only ROLLBACK will be accepted."""
comptime PQTRANS_UNKNOWN = 4
"""The connection is bad, so the status cannot be determined."""


# -----------------------------------------------------------------------
# PG_DIAG_* error field codes (postgres_ext.h).  The header spells these as
# character literals; here they are the ASCII values, because
# PQresultErrorField takes an `int`.
# -----------------------------------------------------------------------

comptime PG_DIAG_SEVERITY = 83
"""``'S'`` -- localised severity ("ERROR", "FATAL", "PANIC", "WARNING", ...)."""
comptime PG_DIAG_SEVERITY_NONLOCALIZED = 86
"""``'V'`` -- severity in English regardless of ``lc_messages`` (9.6+)."""
comptime PG_DIAG_SQLSTATE = 67
"""``'C'`` -- the five-character SQLSTATE.  Present on every server error."""
comptime PG_DIAG_MESSAGE_PRIMARY = 77
"""``'M'`` -- the primary, single-line human-readable message."""
comptime PG_DIAG_MESSAGE_DETAIL = 68
"""``'D'`` -- optional secondary detail."""
comptime PG_DIAG_MESSAGE_HINT = 72
"""``'H'`` -- optional suggestion; advisory only, and sometimes wrong."""
comptime PG_DIAG_STATEMENT_POSITION = 80
"""``'P'`` -- 1-based character index of a syntax error within the query."""
comptime PG_DIAG_SCHEMA_NAME = 115
"""``'s'`` -- schema of the object tied to the error, when applicable."""
comptime PG_DIAG_TABLE_NAME = 116
"""``'t'`` -- table of the object tied to the error, when applicable."""
comptime PG_DIAG_COLUMN_NAME = 99
"""``'c'`` -- column of the object tied to the error, when applicable."""
comptime PG_DIAG_CONSTRAINT_NAME = 110
"""``'n'`` -- the constraint that was violated; the key to 23505 handling."""


# -----------------------------------------------------------------------
# Internal helpers
# -----------------------------------------------------------------------


def _cstr_to_string(addr: Int) -> String:
    """Copy the NUL-terminated C string at `addr` into an owned `String`.

    libpq hands back ``char *`` values that live inside the `PGresult` or
    `PGconn` and die with it, so every one of them is copied here before it can
    escape into Mojo code.

    Args:
        addr: Address of a NUL-terminated UTF-8 string, as a raw `Int`.
            `Pointer` is non-nullable in Mojo 1.x, so a C return value that may
            be NULL has to travel as its address.

    Returns:
        An owned `String` copy; empty for a NULL (zero) address.
    """
    if addr == 0:
        return String("")
    var p = Pointer[Int8, MutUntrackedOrigin](unsafe_from_address=addr)
    return String(StringSlice(unsafe_from_utf8=CStringSlice(unsafe_from_ptr=p)))


def _c_string(s: String) -> List[UInt8]:
    """Build an explicit NUL-terminated byte copy of `s` for a ``const char *``.

    `String.unsafe_ptr` is read-only and its buffer may hold stale bytes past
    the logical end (a reused heap allocation), so anything libpq will read
    with ``strlen`` gets a fresh copy with a terminator we appended ourselves.

    The caller must keep the returned `List` alive across the FFI call -- an
    explicit ``_ = buf^`` after it -- or the buffer is freed while C still
    points into it.

    Args:
        s: The string to copy.

    Returns:
        A `List` of `s`'s bytes followed by one ``0`` byte.
    """
    var n = s.byte_length()
    var src = s.unsafe_ptr()
    var buf = List[UInt8](capacity=n + 1)
    for i in range(n):
        buf.append(src[unsafe_offset=i])
    buf.append(0)
    return buf^


def _dl_sym[
    FT: TrivialRegisterPassable
](lib: OwnedDLHandle, name: String) raises -> FT:
    """Look up a C-ABI function symbol as a plain callable value.

    Replaces the `lib.get_function[FT](name)` idiom, whose return type (an
    origin-bound `_DLCallable`) can no longer be invoked directly or stored
    across scopes.  Copying the address out into a plain function value also
    means calls do not borrow the handle; it merely has to outlive them, which
    the `_Global` guarantees.

    Parameters:
        FT: The `def(...) thin abi("C") -> ...` type of the symbol.

    Args:
        lib: An open library handle.
        name: The exact C symbol name.

    Returns:
        The symbol as a callable value of type `FT`.

    Raises:
        Error: If the symbol is not present in the library.
    """
    var opt = lib.get_symbol[FT](name)
    if not opt:
        raise Error("postgres: FFI symbol not found: " + name)
    var addr: Int = Int(opt.value())
    return Pointer(to=addr).unsafe_bitcast[FT]()[]


def _libpq_soname() -> String:
    """The platform's bare libpq soname, for the search-path fallback.

    Returns:
        ``libpq.so.5`` on Linux, ``libpq.5.dylib`` on macOS.  Major version 5
        has been libpq's ABI version since PostgreSQL 8.2 and covers every
        release this tin supports.
    """
    comptime if CompilationTarget.is_linux():
        return String("libpq.so.5")
    else:
        return String("libpq.5.dylib")


def _find_libpq_library() -> String:
    """Locate libpq via ``$CONDA_PREFIX`` (pixi), else fall back to the soname.

    Search order:

    1. ``$CONDA_PREFIX/lib/libpq.so.5`` (Linux) or
       ``$CONDA_PREFIX/lib/libpq.5.dylib`` (macOS) when the variable is set --
       the build the pixi manifest pins, linked against the environment's
       OpenSSL.
    2. The bare soname, resolved through ``LD_LIBRARY_PATH`` or the dyld search
       path, for installs outside a conda environment.

    `LibpqFFI.__init__` tries this path first and the bare soname second, so a
    stale or partial ``$CONDA_PREFIX`` can still find a system libpq.

    Returns:
        A path or soname suitable for `OwnedDLHandle`.
    """
    var prefix = getenv("CONDA_PREFIX", "")
    if prefix:
        return prefix + "/lib/" + _libpq_soname()
    return _libpq_soname()


# -----------------------------------------------------------------------
# LibpqFFI
# -----------------------------------------------------------------------


struct LibpqFFI(Movable):
    """The loaded libpq and its resolved entry points.

    Opens the library once with `OwnedDLHandle` and resolves every function
    pointer in `__init__`, so no call site pays for a ``dlsym``.

    **Construct this exactly once per process** -- reach it through `libpq`,
    which borrows the `_Global` instance.  A ``dlopen``/``dlclose`` cycle of an
    already resident library costs hundreds of microseconds; done per
    `Connection` it would dwarf the queries it exists to run, and closing libpq
    would tear down the OpenSSL and krb5 state its dependencies registered.

    Every method taking a `String` copies it into a NUL-terminated buffer that
    stays alive across the call, and every method returning C string memory
    copies it into an owned `String` first.  Callers therefore never hold a
    pointer into libpq's heap -- but they do own the *handles*; see the module
    docstring for who calls `LibpqFFI.PQfinish`, `LibpqFFI.PQclear` and
    `LibpqFFI.PQfreemem`.

    Example:

    ```mojo
    ref pq = libpq()
    var conn = pq.PQconnectdb("postgresql://localhost/postgres")
    if pq.PQstatus(conn) != CONNECTION_OK:
        print(pq.PQerrorMessage(conn))
    pq.PQfinish(conn)
    ```
    """

    var _lib: OwnedDLHandle
    """The open libpq image; never closed, and ``RTLD.NODELETE`` besides."""

    # -- library -------------------------------------------------------------
    var _fn_lib_version: def() thin abi("C") -> Int32
    var _fn_is_threadsafe: def() thin abi("C") -> Int32

    # -- connection ----------------------------------------------------------
    var _fn_connectdb: def(Int) thin abi("C") -> Int
    var _fn_finish: def(Int) thin abi("C") -> None
    var _fn_reset: def(Int) thin abi("C") -> None
    var _fn_status: def(Int) thin abi("C") -> Int32
    var _fn_error_message: def(Int) thin abi("C") -> Int
    var _fn_server_version: def(Int) thin abi("C") -> Int32
    var _fn_transaction_status: def(Int) thin abi("C") -> Int32
    var _fn_consume_input: def(Int) thin abi("C") -> Int32
    var _fn_backend_pid: def(Int) thin abi("C") -> Int32

    # -- command execution ---------------------------------------------------
    var _fn_exec: def(Int, Int) thin abi("C") -> Int
    var _fn_exec_params: def(
        Int, Int, Int32, Int, Int, Int, Int, Int32
    ) thin abi("C") -> Int
    var _fn_prepare: def(Int, Int, Int, Int32, Int) thin abi("C") -> Int
    var _fn_exec_prepared: def(Int, Int, Int32, Int, Int, Int, Int32) thin abi(
        "C"
    ) -> Int
    var _fn_get_result: def(Int) thin abi("C") -> Int

    # -- result inspection ---------------------------------------------------
    var _fn_clear: def(Int) thin abi("C") -> None
    var _fn_result_status: def(Int) thin abi("C") -> Int32
    var _fn_res_status: def(Int32) thin abi("C") -> Int
    var _fn_result_error_message: def(Int) thin abi("C") -> Int
    var _fn_result_error_field: def(Int, Int32) thin abi("C") -> Int
    var _fn_ntuples: def(Int) thin abi("C") -> Int32
    var _fn_nfields: def(Int) thin abi("C") -> Int32
    var _fn_fname: def(Int, Int32) thin abi("C") -> Int
    var _fn_fnumber: def(Int, Int) thin abi("C") -> Int32
    var _fn_ftype: def(Int, Int32) thin abi("C") -> UInt32
    var _fn_getvalue: def(Int, Int32, Int32) thin abi("C") -> Int
    var _fn_getisnull: def(Int, Int32, Int32) thin abi("C") -> Int32
    var _fn_getlength: def(Int, Int32, Int32) thin abi("C") -> Int32
    var _fn_cmd_tuples: def(Int) thin abi("C") -> Int

    # -- COPY ----------------------------------------------------------------
    var _fn_put_copy_data: def(Int, Int, Int32) thin abi("C") -> Int32
    var _fn_put_copy_end: def(Int, Int) thin abi("C") -> Int32
    var _fn_get_copy_data: def(Int, Int, Int32) thin abi("C") -> Int32

    # -- allocation ----------------------------------------------------------
    var _fn_freemem: def(Int) thin abi("C") -> None

    def __init__(out self, lib_path: String = "") raises:
        """Load libpq and resolve every function pointer.

        Args:
            lib_path: An explicit library path.  When empty,
                `_find_libpq_library` is used (honouring ``$CONDA_PREFIX``)
                with the bare soname as a second attempt.

        Raises:
            Error: If neither candidate opens, or a symbol is missing.  The
                message names both paths that were tried, because the usual
                cause is a `pixi install` that has not been run.
        """
        var primary = lib_path if lib_path else _find_libpq_library()
        var fallback = _libpq_soname()
        # RTLD.NOW:      resolve everything up front, so a truncated or
        #                mismatched library fails here, not mid-query.
        # RTLD.GLOBAL:   libpq's dependencies (OpenSSL, krb5, LDAP) have to be
        #                visible to it and to each other.
        # RTLD.NODELETE: dlclose() becomes a no-op.  The `_Global` never closes
        #                this handle anyway; NODELETE keeps the image, and the
        #                OpenSSL state it initialised, resident even if
        #                something else in the process closes libpq.
        comptime FLAGS = RTLD.NOW | RTLD.GLOBAL | RTLD.NODELETE
        try:
            self._lib = OwnedDLHandle(primary, FLAGS)
        except:
            if primary == fallback:
                raise Error(
                    "postgres: could not load libpq ('"
                    + primary
                    + "'). Install it (pixi: `libpq`) or put it on the"
                    " library search path."
                )
            try:
                self._lib = OwnedDLHandle(fallback, FLAGS)
            except:
                raise Error(
                    "postgres: could not load libpq. Tried '"
                    + primary
                    + "' and '"
                    + fallback
                    + "'. Install it (pixi: `libpq`) or put it on the"
                    " library search path."
                )

        self._fn_lib_version = _dl_sym[def() thin abi("C") -> Int32](
            self._lib, "PQlibVersion"
        )
        self._fn_is_threadsafe = _dl_sym[def() thin abi("C") -> Int32](
            self._lib, "PQisthreadsafe"
        )
        self._fn_connectdb = _dl_sym[def(Int) thin abi("C") -> Int](
            self._lib, "PQconnectdb"
        )
        self._fn_finish = _dl_sym[def(Int) thin abi("C") -> None](
            self._lib, "PQfinish"
        )
        self._fn_reset = _dl_sym[def(Int) thin abi("C") -> None](
            self._lib, "PQreset"
        )
        self._fn_status = _dl_sym[def(Int) thin abi("C") -> Int32](
            self._lib, "PQstatus"
        )
        self._fn_consume_input = _dl_sym[def(Int) thin abi("C") -> Int32](
            self._lib, "PQconsumeInput"
        )
        self._fn_backend_pid = _dl_sym[def(Int) thin abi("C") -> Int32](
            self._lib, "PQbackendPID"
        )
        self._fn_error_message = _dl_sym[def(Int) thin abi("C") -> Int](
            self._lib, "PQerrorMessage"
        )
        self._fn_server_version = _dl_sym[def(Int) thin abi("C") -> Int32](
            self._lib, "PQserverVersion"
        )
        self._fn_transaction_status = _dl_sym[def(Int) thin abi("C") -> Int32](
            self._lib, "PQtransactionStatus"
        )
        self._fn_exec = _dl_sym[def(Int, Int) thin abi("C") -> Int](
            self._lib, "PQexec"
        )
        self._fn_exec_params = _dl_sym[
            def(Int, Int, Int32, Int, Int, Int, Int, Int32) thin abi("C") -> Int
        ](self._lib, "PQexecParams")
        self._fn_prepare = _dl_sym[
            def(Int, Int, Int, Int32, Int) thin abi("C") -> Int
        ](self._lib, "PQprepare")
        self._fn_exec_prepared = _dl_sym[
            def(Int, Int, Int32, Int, Int, Int, Int32) thin abi("C") -> Int
        ](self._lib, "PQexecPrepared")
        self._fn_get_result = _dl_sym[def(Int) thin abi("C") -> Int](
            self._lib, "PQgetResult"
        )
        self._fn_clear = _dl_sym[def(Int) thin abi("C") -> None](
            self._lib, "PQclear"
        )
        self._fn_result_status = _dl_sym[def(Int) thin abi("C") -> Int32](
            self._lib, "PQresultStatus"
        )
        self._fn_res_status = _dl_sym[def(Int32) thin abi("C") -> Int](
            self._lib, "PQresStatus"
        )
        self._fn_result_error_message = _dl_sym[def(Int) thin abi("C") -> Int](
            self._lib, "PQresultErrorMessage"
        )
        self._fn_result_error_field = _dl_sym[
            def(Int, Int32) thin abi("C") -> Int
        ](self._lib, "PQresultErrorField")
        self._fn_ntuples = _dl_sym[def(Int) thin abi("C") -> Int32](
            self._lib, "PQntuples"
        )
        self._fn_nfields = _dl_sym[def(Int) thin abi("C") -> Int32](
            self._lib, "PQnfields"
        )
        self._fn_fname = _dl_sym[def(Int, Int32) thin abi("C") -> Int](
            self._lib, "PQfname"
        )
        self._fn_fnumber = _dl_sym[def(Int, Int) thin abi("C") -> Int32](
            self._lib, "PQfnumber"
        )
        self._fn_ftype = _dl_sym[def(Int, Int32) thin abi("C") -> UInt32](
            self._lib, "PQftype"
        )
        self._fn_getvalue = _dl_sym[
            def(Int, Int32, Int32) thin abi("C") -> Int
        ](self._lib, "PQgetvalue")
        self._fn_getisnull = _dl_sym[
            def(Int, Int32, Int32) thin abi("C") -> Int32
        ](self._lib, "PQgetisnull")
        self._fn_getlength = _dl_sym[
            def(Int, Int32, Int32) thin abi("C") -> Int32
        ](self._lib, "PQgetlength")
        self._fn_cmd_tuples = _dl_sym[def(Int) thin abi("C") -> Int](
            self._lib, "PQcmdTuples"
        )
        self._fn_put_copy_data = _dl_sym[
            def(Int, Int, Int32) thin abi("C") -> Int32
        ](self._lib, "PQputCopyData")
        self._fn_put_copy_end = _dl_sym[def(Int, Int) thin abi("C") -> Int32](
            self._lib, "PQputCopyEnd"
        )
        self._fn_get_copy_data = _dl_sym[
            def(Int, Int, Int32) thin abi("C") -> Int32
        ](self._lib, "PQgetCopyData")
        self._fn_freemem = _dl_sym[def(Int) thin abi("C") -> None](
            self._lib, "PQfreemem"
        )

    # -- library -------------------------------------------------------------

    def PQlibVersion(self) -> Int:
        """The version of the libpq that was actually loaded.

        Returns:
            The version packed as ``major * 10000 + minor`` since PostgreSQL 10
            (18.4 is ``180004``), so ``>= 160000`` tests for 16 or newer.  This
            describes the client library, not the server -- for that see
            `LibpqFFI.PQserverVersion`.
        """
        return Int(self._fn_lib_version())

    def PQisthreadsafe(self) -> Bool:
        """Whether this libpq was built with thread safety enabled.

        A libpq compiled without ``--enable-thread-safety`` keeps per-*library*
        rather than per-connection state, so two threads using two different
        `PGconn`s can corrupt each other.  Every build since PostgreSQL 10 has
        it on by default and the conda-forge build certainly does, but a pool
        hands connections to threads for a living, so `pool.ConnectionPool`
        checks this at construction rather than assuming it.

        Returns:
            True if concurrent use of *distinct* connections is safe.  It never
            means two threads may share one `PGconn`; nothing makes that safe.
        """
        return Int(self._fn_is_threadsafe()) != 0

    # -- connection ----------------------------------------------------------

    def PQconnectdb(self, conninfo: String) -> PGconnPtr:
        """Open a connection, blocking until it succeeds or fails.

        Args:
            conninfo: A URI (``postgresql://...``) or a keyword/value conninfo
                string.  Include ``connect_timeout`` to bound the wait: without
                it an unroutable host blocks for the OS TCP timeout.

        Returns:
            A `PGconnPtr` the caller must release with `LibpqFFI.PQfinish`
            whether or not the connection succeeded; ``0`` only on out of
            memory.  Check `LibpqFFI.PQstatus` before using it.
        """
        var buf = _c_string(conninfo)
        var conn = self._fn_connectdb(Int(buf.unsafe_ptr()))
        _ = buf^
        return conn

    def PQfinish(self, conn: PGconnPtr):
        """Close `conn` and free it.  Call exactly once per `PQconnectdb`.

        Every `PGresultPtr` obtained from this connection should already have
        been cleared: libpq lets results outlive the connection, but nothing
        above this file is written to rely on that.

        Args:
            conn: The connection handle; ``0`` is ignored.
        """
        if conn != 0:
            self._fn_finish(conn)

    def PQreset(self, conn: PGconnPtr):
        """Close `conn`'s socket and open a new one with the same parameters.

        Recycling in place: the handle stays valid, so everything holding it
        keeps working, but the *session* is new -- no prepared statements, no
        temp tables, no open transaction, and a different backend PID.  Blocks
        for as long as a fresh connect would, and leaves `LibpqFFI.PQstatus`
        reporting `CONNECTION_BAD` if it failed.

        Args:
            conn: The connection handle; ``0`` is ignored.
        """
        if conn != 0:
            self._fn_reset(conn)

    def PQstatus(self, conn: PGconnPtr) -> Int:
        """Report whether `conn` is usable.

        Args:
            conn: The connection handle.

        Returns:
            `CONNECTION_OK` or `CONNECTION_BAD`; a NULL handle reads as
            `CONNECTION_BAD`.  The status only goes bad on a *fatal* error --
            a failed query leaves it OK.
        """
        if conn == 0:
            return CONNECTION_BAD
        return Int(self._fn_status(conn))

    def PQerrorMessage(self, conn: PGconnPtr) -> String:
        """The most recent error message for `conn`, copied.

        Args:
            conn: The connection handle.

        Returns:
            The message, usually with a trailing newline, or ``""`` when there
            has been no error (or `conn` is NULL).
        """
        if conn == 0:
            return String("")
        return _cstr_to_string(self._fn_error_message(conn))

    def PQserverVersion(self, conn: PGconnPtr) -> Int:
        """The version of the server on the other end of `conn`.

        Args:
            conn: The connection handle.

        Returns:
            ``major * 10000 + minor`` (16.2 is ``160002``), or ``0`` when the
            connection is bad.
        """
        if conn == 0:
            return 0
        return Int(self._fn_server_version(conn))

    def PQtransactionStatus(self, conn: PGconnPtr) -> Int:
        """Report whether a transaction block is open on `conn`.

        Args:
            conn: The connection handle.

        Returns:
            One of `PQTRANS_IDLE`, `PQTRANS_ACTIVE`, `PQTRANS_INTRANS`,
            `PQTRANS_INERROR` or `PQTRANS_UNKNOWN`.  `PQTRANS_INERROR` is the
            one `Transaction` has to act on: the block must be rolled back
            before anything else will be accepted.
        """
        if conn == 0:
            return PQTRANS_UNKNOWN
        return Int(self._fn_transaction_status(conn))

    def PQconsumeInput(self, conn: PGconnPtr) -> Bool:
        """Read whatever the server has already sent, without waiting for more.

        A non-blocking `recv` on the connection's socket: it drains the kernel
        buffer into libpq's, and returns without waiting if there is nothing
        there.  No round trip -- nothing is sent.

        This is how a *dead* connection is noticed cheaply.
        `LibpqFFI.PQstatus` only reports libpq's cached opinion, and that
        opinion does not change when the peer goes away: a backend killed by
        ``pg_terminate_backend``, a server restarted underneath the pool, or a
        connection dropped by a failover all still read `CONNECTION_OK` until
        something actually touches the socket.  The terminating backend does
        send an ``ErrorResponse`` and then closes; this call is what collects
        it, and it flips the status to `CONNECTION_BAD`.

        Args:
            conn: The connection handle.

        Returns:
            True on success -- which says the socket is still healthy, *not*
            that anything arrived.  False means a fatal error, and
            `LibpqFFI.PQstatus` will then report `CONNECTION_BAD`.  A NULL
            handle reads as False.

        Note:
            Only meaningful on an idle connection.  Mid-``COPY`` or with an
            unread result outstanding, this is part of the async protocol and
            belongs to whoever is driving it.
        """
        if conn == 0:
            return False
        return Int(self._fn_consume_input(conn)) != 0

    def PQbackendPID(self, conn: PGconnPtr) -> Int:
        """The process ID of the backend serving `conn`.

        Read from the startup packet, so this costs nothing and needs no
        server round trip.  It is the value ``pg_terminate_backend`` takes, and
        it changes after a `LibpqFFI.PQreset`, which makes it the way to prove
        a connection really was recycled rather than handed back.

        Args:
            conn: The connection handle.

        Returns:
            The backend PID, or ``0`` if the connection is not open.
        """
        if conn == 0:
            return 0
        return Int(self._fn_backend_pid(conn))

    # -- command execution ---------------------------------------------------

    def PQexec(self, conn: PGconnPtr, command: String) -> PGresultPtr:
        """Run one or more semicolon-separated statements.

        Multi-statement strings are allowed here and *not* in `exec_params`,
        which is the only reason to prefer this: the parameterised form is
        otherwise always better (nothing to escape, no injection surface).

        Args:
            conn: The connection handle.
            command: SQL text.

        Returns:
            A `PGresultPtr` the caller must `LibpqFFI.PQclear`, or ``0`` on out
            of memory or a dead connection.  Only the last statement's result
            is returned; the first failing statement aborts the rest.
        """
        var buf = _c_string(command)
        var res = self._fn_exec(conn, Int(buf.unsafe_ptr()))
        _ = buf^
        return res

    def PQprepare(
        self,
        conn: PGconnPtr,
        name: String,
        query: String,
        oids: List[UInt32],
    ) -> PGresultPtr:
        """Create a server-side prepared statement named `name`.

        Args:
            conn: The connection handle.  Prepared statements are
                session-local: `exec_prepared` must use this same connection.
            name: The statement name; ``""`` is the unnamed statement, which
                the next prepare on this connection replaces.
            query: SQL with ``$1``, ``$2``, ... placeholders.
            oids: One ``pg_type.oid`` per parameter, ``0`` to let the server
                infer that one.  An empty list means "infer them all" and is
                the normal case.

        Returns:
            A `PGresultPtr` the caller must `LibpqFFI.PQclear`.
            `LibpqFFI.PQresultStatus` is `PGRES_COMMAND_OK` on success, and the
            statement then lives until the session ends or ``DEALLOCATE`` runs.
        """
        var name_buf = _c_string(name)
        var query_buf = _c_string(query)
        var oid_arr = oids.copy()
        var n = len(oid_arr)
        var res = self._fn_prepare(
            conn,
            Int(name_buf.unsafe_ptr()),
            Int(query_buf.unsafe_ptr()),
            Int32(n),
            Int(oid_arr.unsafe_ptr()) if n > 0 else 0,
        )
        _ = name_buf^
        _ = query_buf^
        _ = oid_arr^
        return res

    def PQgetResult(self, conn: PGconnPtr) -> PGresultPtr:
        """Collect the next result from `conn`, blocking until it arrives.

        This is how a COPY's terminating result is read, and it must be called
        until it returns ``0`` or the connection stays busy and every later
        command fails.

        Args:
            conn: The connection handle.

        Returns:
            A `PGresultPtr` the caller must `LibpqFFI.PQclear`, or ``0`` once
            the command is complete.  ``0`` is not an error and must not be
            cleared.
        """
        return self._fn_get_result(conn)

    # -- result inspection ---------------------------------------------------

    def PQclear(self, res: PGresultPtr):
        """Free a `PGresult`.  Call exactly once per result-returning call.

        Every `String` this module returned out of `res` is an owned copy, so
        clearing is safe as soon as the values have been read.

        Args:
            res: The result handle; ``0`` is ignored.
        """
        if res != 0:
            self._fn_clear(res)

    def PQresultStatus(self, res: PGresultPtr) -> Int:
        """The outcome of the command that produced `res`.

        Args:
            res: The result handle.

        Returns:
            One of the ``PGRES_*`` constants.  A NULL handle reads as
            `PGRES_FATAL_ERROR`, which is how libpq itself treats it.
        """
        if res == 0:
            return PGRES_FATAL_ERROR
        return Int(self._fn_result_status(res))

    def PQresStatus(self, status: Int) -> String:
        """The constant's name for an `ExecStatusType`, for error messages.

        Args:
            status: A ``PGRES_*`` value.

        Returns:
            For example ``"PGRES_TUPLES_OK"``.  Out-of-range values produce a
            libpq-generated "unrecognized" string rather than failing.
        """
        return _cstr_to_string(self._fn_res_status(Int32(status)))

    def PQresultErrorMessage(self, res: PGresultPtr) -> String:
        """The full error message attached to `res`, copied.

        Args:
            res: The result handle.

        Returns:
            The formatted, possibly multi-line message (severity, primary,
            detail and hint, per the connection's verbosity), or ``""`` if the
            command succeeded.  For structured access use
            `LibpqFFI.PQresultErrorField`.
        """
        if res == 0:
            return String("")
        return _cstr_to_string(self._fn_result_error_message(res))

    def PQresultErrorField(self, res: PGresultPtr, fieldcode: Int) -> String:
        """One structured field of the error attached to `res`, copied.

        Args:
            res: The result handle.
            fieldcode: A ``PG_DIAG_*`` constant.

        Returns:
            The field's text, or ``""`` when the field is absent (libpq returns
            NULL) or the command succeeded.  `PG_DIAG_SQLSTATE` accompanies
            every server-reported error and is the field to branch on; a
            failure raised by libpq itself -- a dropped connection, say -- has
            no fields at all, so an empty SQLSTATE means "client-side".
        """
        if res == 0:
            return String("")
        return _cstr_to_string(
            self._fn_result_error_field(res, Int32(fieldcode))
        )

    def PQntuples(self, res: PGresultPtr) -> Int:
        """The number of rows in `res`.

        Args:
            res: The result handle.

        Returns:
            The row count; ``0`` for a command that returned no rows, or for a
            NULL handle.
        """
        if res == 0:
            return 0
        return Int(self._fn_ntuples(res))

    def PQnfields(self, res: PGresultPtr) -> Int:
        """The number of columns in `res`.

        Args:
            res: The result handle.

        Returns:
            The column count; ``0`` for a command that returned no rows, or
            for a NULL handle.
        """
        if res == 0:
            return 0
        return Int(self._fn_nfields(res))

    def PQfname(self, res: PGresultPtr, field_num: Int) -> String:
        """The name of column `field_num` (0-based), copied.

        Args:
            res: The result handle.
            field_num: The column index.

        Returns:
            The column name, or ``""`` when the index is out of range.  Names
            arrive folded to lower case unless the query quoted them.
        """
        if res == 0:
            return String("")
        return _cstr_to_string(self._fn_fname(res, Int32(field_num)))

    def PQfnumber(self, res: PGresultPtr, field_name: String) -> Int:
        """The index of the column named `field_name`.

        Args:
            res: The result handle.
            field_name: The column name, matched exactly against the (usually
                lower-cased) result name.  Pass it double-quoted to match a
                name the query itself quoted.

        Returns:
            The 0-based column index, or ``-1`` if there is no such column.
        """
        if res == 0:
            return -1
        var buf = _c_string(field_name)
        var idx = Int(self._fn_fnumber(res, Int(buf.unsafe_ptr())))
        _ = buf^
        return idx

    def PQftype(self, res: PGresultPtr, field_num: Int) -> UInt32:
        """The type OID of column `field_num` (0-based).

        Args:
            res: The result handle.
            field_num: The column index.

        Returns:
            The column's ``pg_type.oid`` -- 23 for ``int4``, 25 for ``text``,
            and so on -- which is what `text.mojo` decodes against.  ``0`` for
            an out-of-range index.
        """
        if res == 0:
            return UInt32(0)
        return self._fn_ftype(res, Int32(field_num))

    def PQgetvalue(self, res: PGresultPtr, row: Int, col: Int) -> String:
        """The text-format value of one cell, copied.

        Args:
            res: The result handle.
            row: The 0-based row index.
            col: The 0-based column index.

        Returns:
            The cell's text.  **A SQL NULL also reads as ``""``** -- the two
            are told apart only by `LibpqFFI.PQgetisnull`, which callers must
            consult first.  Text format never contains embedded NUL bytes, so
            the NUL-terminated copy is lossless.
        """
        if res == 0:
            return String("")
        return _cstr_to_string(self._fn_getvalue(res, Int32(row), Int32(col)))

    def PQgetisnull(self, res: PGresultPtr, row: Int, col: Int) -> Bool:
        """Whether one cell is SQL NULL.

        Args:
            res: The result handle.
            row: The 0-based row index.
            col: The 0-based column index.

        Returns:
            True for SQL NULL.  This is the only way to distinguish NULL from
            the empty string, which `LibpqFFI.PQgetvalue` renders identically.
        """
        if res == 0:
            return True
        return self._fn_getisnull(res, Int32(row), Int32(col)) != 0

    def PQgetlength(self, res: PGresultPtr, row: Int, col: Int) -> Int:
        """The byte length of one cell's value.

        Args:
            res: The result handle.
            row: The 0-based row index.
            col: The 0-based column index.

        Returns:
            The length in bytes, excluding the terminator; ``0`` for SQL NULL.
        """
        if res == 0:
            return 0
        return Int(self._fn_getlength(res, Int32(row), Int32(col)))

    def PQcmdTuples(self, res: PGresultPtr) -> String:
        """The rows affected by the command, as libpq's decimal string.

        Args:
            res: The result handle.

        Returns:
            For example ``"3"`` after a ``DELETE``.  **Empty for commands that
            report no count** -- DDL, ``BEGIN``, a plain ``SELECT`` -- which
            the caller maps to ``0``.
        """
        if res == 0:
            return String("")
        return _cstr_to_string(self._fn_cmd_tuples(res))

    # -- COPY ----------------------------------------------------------------

    def PQputCopyData(self, conn: PGconnPtr, data: Span[UInt8, _]) -> Int:
        """Send one chunk of ``COPY ... FROM STDIN`` data.

        Chunks need not align with row boundaries, but `LibpqFFI.PQputCopyEnd`
        must not be called mid-row.  libpq copies `data` into its own buffer
        before returning, so nothing has to be kept alive afterwards, and the
        explicit byte count means embedded NULs are sent faithfully.

        Args:
            conn: The connection handle, with a COPY IN in progress.
            data: The raw bytes to send; an empty span is a no-op.

        Returns:
            ``1`` when the data was queued, ``0`` when it could not be (never
            on a blocking connection), or ``-1`` on error -- the reason is in
            `LibpqFFI.PQerrorMessage`.
        """
        var n = len(data)
        if n == 0:
            return 1
        return Int(
            self._fn_put_copy_data(conn, Int(data.unsafe_ptr()), Int32(n))
        )

    def PQputCopyData(self, conn: PGconnPtr, data: List[UInt8]) -> Int:
        """Send one chunk of ``COPY ... FROM STDIN`` data.

        The overload for a buffer a caller owns -- what
        `copyfmt.CopyEncoder.take` hands back.

        Args:
            conn: The connection handle, with a COPY IN in progress.
            data: The raw bytes to send; an empty list is a no-op.

        Returns:
            ``1`` when the data was queued, ``0`` when it could not be, or
            ``-1`` on error.
        """
        return self.PQputCopyData(conn, Span(data))

    def PQputCopyData(self, conn: PGconnPtr, data: String) -> Int:
        """Send one chunk of ``COPY ... FROM STDIN`` data as text.

        The overload for the text and CSV COPY formats, which `copy.mojo`
        produces as `String`.

        Args:
            conn: The connection handle, with a COPY IN in progress.
            data: The chunk, in the COPY format the command declared.

        Returns:
            ``1`` when the data was queued, ``0`` when it could not be, or
            ``-1`` on error.
        """
        return self.PQputCopyData(conn, data.as_bytes())

    def PQputCopyEnd(
        self, conn: PGconnPtr, errormsg: String = String("")
    ) -> Int:
        """Finish ``COPY ... FROM STDIN``, optionally forcing it to fail.

        Args:
            conn: The connection handle, with a COPY IN in progress.
            errormsg: Empty (the default) commits the COPY; any other value is
                passed as libpq's ``errormsg``, which aborts the COPY and makes
                the server report that text as the error.

        Returns:
            ``1`` when the terminator was sent, or ``-1`` on error.  Either way
            the caller must then drain `LibpqFFI.PQgetResult` until it returns
            ``0``; the *first* result carries the COPY's success or failure.
        """
        if not errormsg:
            return Int(self._fn_put_copy_end(conn, 0))
        var buf = _c_string(errormsg)
        var rc = Int(self._fn_put_copy_end(conn, Int(buf.unsafe_ptr())))
        _ = buf^
        return rc

    def PQgetCopyData(self, conn: PGconnPtr, mut into: List[UInt8]) -> Int:
        """Receive one row of ``COPY ... TO STDOUT``, appending it to `into`.

        Always called in synchronous mode (libpq's ``async = 0``), so it blocks
        until a whole row is available.  The ``malloc``ed buffer libpq hands
        back is copied into `into` and released with `LibpqFFI.PQfreemem` here:
        the caller never sees it and must not free anything.

        Args:
            conn: The connection handle, with a COPY OUT in progress.
            into: The destination.  The row's bytes are *appended*, leaving
                any existing content intact.

        Returns:
            The number of bytes appended (always ``> 0``), ``-1`` when the COPY
            is complete -- the caller then drains `LibpqFFI.PQgetResult` -- or
            ``-2`` on error, with the reason in `LibpqFFI.PQerrorMessage`.
        """
        var out = List[Int](capacity=1)
        out.append(0)
        var n = Int(self._fn_get_copy_data(conn, Int(out.unsafe_ptr()), 0))
        var addr = out[0]
        if n > 0 and addr != 0:
            var p = Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=addr)
            into.reserve(len(into) + n)
            for i in range(n):
                into.append(p[unsafe_offset=i])
        if addr != 0:
            self._fn_freemem(addr)
        _ = out^
        return n

    # -- allocation ----------------------------------------------------------

    def PQfreemem(self, ptr: Int):
        """Release memory libpq allocated with ``malloc``.

        `LibpqFFI.PQgetCopyData` already frees its own buffer, so this exists
        for the escaping functions and for symmetry.

        Args:
            ptr: An address returned by a libpq function documented to
                allocate; ``0`` is ignored.
        """
        if ptr != 0:
            self._fn_freemem(ptr)


# -----------------------------------------------------------------------
# Process-wide instance
# -----------------------------------------------------------------------


def _open_ffi() -> LibpqFFI:
    """`dlopen` libpq and resolve every symbol, once, per process."""
    try:
        return LibpqFFI()
    except e:
        abort(String("postgres.mojo: ", e))


comptime _FFI = _Global["postgres_mojo_libpq", _open_ffi]
"""The loaded library and its resolved entry points, initialised on first use.

`_Global` initialises exactly once even under concurrent first use, and the
value is never destroyed, so the `OwnedDLHandle` it owns is never ``dlclose``d
-- which is exactly right for a library that has initialised OpenSSL, and
possibly krb5, on our behalf.  Every `Connection` borrows this one instance
rather than opening its own: a ``dlopen``/``dlclose`` pair on an already
resident library costs hundreds of microseconds, more than many of the queries
it would be wrapping.
"""


def libpq() raises -> ref[MutUntrackedOrigin] LibpqFFI:
    """The process-wide libpq FFI table, borrowed.  Never destroy the referent.

    Returns:
        A reference to the single `LibpqFFI`, loading the library on the first
        call and reusing it forever after.

    Raises:
        Error: Never in practice -- a failure to load aborts inside `_open_ffi`
            with the diagnostic from `LibpqFFI.__init__`, because there is no
            sensible way to carry on without libpq.
    """
    return _FFI.get_or_create_ptr()[]


# -----------------------------------------------------------------------
# Parameterised execution
#
# The C arrays PQexecParams wants are built here, once, so that no layer
# above this file ever holds a raw pointer.  Everything is text format
# (resultFormat = 0): values go out as NUL-terminated UTF-8 and come back
# as text for text.mojo to decode.
# -----------------------------------------------------------------------


def _error_field(res: PGresultPtr, fieldcode: Int) raises -> String:
    """`LibpqFFI.PQresultErrorField` without needing the FFI table in hand.

    Args:
        res: The result handle.
        fieldcode: A ``PG_DIAG_*`` constant.

    Returns:
        The field's text, or ``""`` when the field is absent.

    Raises:
        Error: If the FFI table cannot be borrowed.
    """
    return libpq().PQresultErrorField(res, fieldcode)


struct _ParamArrays(Movable):
    """Owns the buffers behind one `exec_params` or `exec_prepared` call.

    Keeping the arrays in one struct is what makes their lifetime legible: the
    value must stay alive until after the FFI call, and a single ``_ = arr^``
    below the call says exactly that.  Spread over five separate locals it was
    too easy to let one die early and hand libpq a freed buffer.
    """

    var _buffers: List[List[UInt8]]
    """NUL-terminated copies of the non-NULL values; `_pointers` points here."""
    var _pointers: List[Int]
    """``const char *const *paramValues``; ``0`` for a SQL NULL parameter."""
    var _lengths: List[Int32]
    """``const int *paramLengths``; all zero, and unused in text format."""
    var _formats: List[Int32]
    """``const int *paramFormats``; all zero, i.e. every parameter is text."""
    var _oids: List[UInt32]
    """``const Oid *paramTypes``; empty means "let the server infer"."""
    var _count: Int
    """``nParams``."""

    def __init__(
        out self,
        var buffers: List[List[UInt8]],
        var pointers: List[Int],
        var lengths: List[Int32],
        var formats: List[Int32],
        var oids: List[UInt32],
        count: Int,
    ):
        """Take ownership of the marshalled arrays.

        Args:
            buffers: The value byte buffers.
            pointers: The value pointers, or ``0`` for NULL.
            lengths: The per-parameter lengths.
            formats: The per-parameter formats.
            oids: The per-parameter type OIDs, or empty.
            count: The parameter count.
        """
        self._buffers = buffers^
        self._pointers = pointers^
        self._lengths = lengths^
        self._formats = formats^
        self._oids = oids^
        self._count = count

    def _values_ptr(self) -> Int:
        """Address of ``paramValues``, or ``0`` when there are no parameters."""
        return Int(self._pointers.unsafe_ptr()) if self._count > 0 else 0

    def _lengths_ptr(self) -> Int:
        """Address of ``paramLengths``, or ``0`` when there are none."""
        return Int(self._lengths.unsafe_ptr()) if self._count > 0 else 0

    def _formats_ptr(self) -> Int:
        """Address of ``paramFormats``, or ``0`` when there are none."""
        return Int(self._formats.unsafe_ptr()) if self._count > 0 else 0

    def _oids_ptr(self) -> Int:
        """Address of ``paramTypes``; ``0`` asks the server to infer types."""
        return Int(self._oids.unsafe_ptr()) if len(self._oids) > 0 else 0


def _param_arrays(
    values: List[String],
    nulls: List[Bool],
    var oids: List[UInt32],
) raises -> _ParamArrays:
    """Marshal Mojo parameter lists into the C arrays libpq expects.

    Args:
        values: One text-format value per parameter.  The entry for a NULL
            parameter is ignored, but must still be present.
        nulls: True where the parameter is SQL NULL.  May be empty, meaning no
            parameter is NULL.
        oids: One type OID per parameter, ``0`` to infer that one.  May be
            empty, meaning infer them all.

    Returns:
        A `_ParamArrays` owning every buffer its pointers refer to.  It must
        outlive the libpq call.

    Raises:
        Error: If `nulls` or `oids` is non-empty and disagrees in length with
            `values`, or if there are more than 65535 parameters -- the wire
            protocol's limit, which libpq otherwise reports from deep inside a
            failed query.
    """
    var n = len(values)
    if len(nulls) != 0 and len(nulls) != n:
        raise Error(
            "postgres: "
            + String(len(nulls))
            + " null flags for "
            + String(n)
            + " parameters"
        )
    if len(oids) != 0 and len(oids) != n:
        raise Error(
            "postgres: "
            + String(len(oids))
            + " type OIDs for "
            + String(n)
            + " parameters"
        )
    if n > 65535:
        raise Error(
            "postgres: "
            + String(n)
            + " parameters exceeds the protocol limit of 65535"
        )

    var buffers = List[List[UInt8]](capacity=n)
    var pointers = List[Int](capacity=n)
    var lengths = List[Int32](capacity=n)
    var formats = List[Int32](capacity=n)
    for i in range(n):
        # Growing `buffers` moves the inner List *headers*, but each one's heap
        # block stays where it is, so the addresses taken in the second loop
        # remain valid for the whole call.
        buffers.append(_c_string(values[i]))
        lengths.append(0)  # ignored for text-format parameters
        formats.append(0)  # 0 = text, 1 = binary
    for i in range(n):
        var is_null = nulls[i] if len(nulls) != 0 else False
        pointers.append(0 if is_null else Int(buffers[i].unsafe_ptr()))

    var arrays = _ParamArrays(buffers^, pointers^, lengths^, formats^, oids^, n)
    return arrays^


def exec_params(
    conn: PGconnPtr,
    sql: String,
    values: List[String],
    nulls: List[Bool],
    oids: List[UInt32],
) raises -> PGresultPtr:
    """Run one parameterised statement and return its result.

    Wraps ``PQexecParams(conn, command, nParams, paramTypes, paramValues,
    paramLengths, paramFormats, resultFormat)``, building all four C arrays
    from Mojo lists and keeping them alive across the call.  Both directions
    are text format (``resultFormat = 0``), so ``paramLengths`` goes unused and
    the returned cells arrive as text for `text.mojo` to decode.

    Parameters are written ``$1``, ``$2``, ... in `sql` and are never
    interpolated into it, so there is nothing to escape and no injection
    surface.  Exactly one statement is allowed -- libpq rejects a
    semicolon-separated string here, unlike `LibpqFFI.PQexec`.

    Args:
        conn: The connection handle.
        sql: SQL with ``$n`` placeholders.
        values: One text-format value per parameter, in ``$1``..``$n`` order.
            The entry for a NULL parameter is ignored but must be present, so
            a placeholder ``""`` is fine.
        nulls: True where the parameter is SQL NULL, in which case C NULL is
            passed in place of the value pointer.  Pass an empty list when
            nothing is NULL.
        oids: One ``pg_type.oid`` per parameter, ``0`` to let the server infer
            that one.  Pass an empty list to infer them all -- which usually
            wants a cast in the SQL (``$1::int``), since the server otherwise
            resolves ambiguous cases to text.

    Returns:
        A `PGresultPtr` the caller must `LibpqFFI.PQclear` exactly once,
        including on error; ``0`` on out of memory or a dead connection.

    Raises:
        Error: If `nulls` or `oids` disagrees in length with `values`, or the
            parameter count exceeds the protocol's 65535.
    """
    var arrays = _param_arrays(values, nulls, oids.copy())
    var sql_buf = _c_string(sql)
    ref pq = libpq()
    var res = pq._fn_exec_params(
        conn,
        Int(sql_buf.unsafe_ptr()),
        Int32(arrays._count),
        arrays._oids_ptr(),
        arrays._values_ptr(),
        arrays._lengths_ptr(),
        arrays._formats_ptr(),
        0,  # resultFormat: 0 = text
    )
    _ = sql_buf^
    _ = arrays^
    return res


def exec_prepared(
    conn: PGconnPtr,
    name: String,
    values: List[String],
    nulls: List[Bool],
) raises -> PGresultPtr:
    """Execute a statement previously created with `LibpqFFI.PQprepare`.

    Wraps ``PQexecPrepared(conn, stmtName, nParams, paramValues, paramLengths,
    paramFormats, resultFormat)``.  There is no `oids` argument: the parameter
    types were fixed when the statement was prepared.

    Args:
        conn: The connection handle.  It must be the one the statement was
            prepared on -- prepared statements are session-local.
        name: The name given to `LibpqFFI.PQprepare`; ``""`` for the unnamed
            statement.
        values: One text-format value per parameter, in ``$1``..``$n`` order.
        nulls: True where the parameter is SQL NULL.  May be empty.

    Returns:
        A `PGresultPtr` the caller must `LibpqFFI.PQclear` exactly once,
        including on error; ``0`` on out of memory or a dead connection.

    Raises:
        Error: If `nulls` disagrees in length with `values`, or the parameter
            count exceeds the protocol's 65535.
    """
    var arrays = _param_arrays(values, nulls, List[UInt32]())
    var name_buf = _c_string(name)
    ref pq = libpq()
    var res = pq._fn_exec_prepared(
        conn,
        Int(name_buf.unsafe_ptr()),
        Int32(arrays._count),
        arrays._values_ptr(),
        arrays._lengths_ptr(),
        arrays._formats_ptr(),
        0,  # resultFormat: 0 = text
    )
    _ = name_buf^
    _ = arrays^
    return res
