//! TLZ openssl error
//!
//! ### file: src/tlz/src/openssl/error.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Read the OpenSSL error queue: clear it, look for one library reason, and copy the
//! readable error line into a caller buffer for the log line.
//!
//! ### note:
//!
//! The queue is per thread. Clear it before an OpenSSL call, so a later read sees only
//! the entries of that call. The text is for logs, control flow uses the codes.
//!
//! ---------------------------------------------------------
//!
//! ### licenses:
//!
//! - BSD-3-Clause
//!
//! ### copyright:
//!
//! - (c) Prana Ron // @prothegee // prothegee@pm.me
//!
//! ### contributors:
//!
//! - Prana Ron // @prothegee // prothegee@pm.me
//!

const std = @import("std");
const c = @import("c.zig").raw;

// --------------------------------------------------------- //
// Public:

/// A buffer size that holds one full OpenSSL error line.
pub const LINE_BUF_LEN: usize = 256;

/// Drop every queued error of this thread.
///
/// Return:
/// - void
pub fn clearQueue() void {
    c.ERR_clear_error();
}

/// Pop the oldest queued error code.
///
/// Return:
/// - c_ulong (0 when the queue is empty)
pub fn popCode() c_ulong {
    return c.ERR_get_error();
}

/// Pop every queued error and report if one of them is `lib` with a reason in `reasons`.
///
/// Note:
/// - The queue is empty afterwards, whatever the result.
///
/// Param:
/// lib - c_int (the library code, e.g. `ERR_LIB_SSL`)
/// reasons - []const c_int (the reason codes to look for, e.g. `SSL_R_NO_APPLICATION_PROTOCOL`)
///
/// Return:
/// - true when one queued error matches
/// - false when none does, or the queue was empty
pub fn drainMatch(lib: c_int, reasons: []const c_int) bool {
    var found = false;

    while (true) {
        const code = popCode();
        if (code == 0) break;

        if (c.ERR_GET_LIB(code) != lib) continue;

        const reason = c.ERR_GET_REASON(code);
        for (reasons) |wanted| {
            if (reason == wanted) found = true;
        }
    }

    return found;
}

/// Copy the readable line of one error code into `buf`.
///
/// Param:
/// code - c_ulong (an error code from the queue)
/// buf - []u8 (the output buffer, `LINE_BUF_LEN` holds a full line)
///
/// Return:
/// - []const u8 (the line inside `buf`, cut to fit, empty when `buf` is empty)
pub fn describe(code: c_ulong, buf: []u8) []const u8 {
    if (buf.len == 0) return buf[0..0];

    c.ERR_error_string_n(code, buf.ptr, buf.len);

    return std.mem.sliceTo(buf, 0);
}

/// Pop every queued error and keep the line of the newest one in `buf`.
///
/// Param:
/// buf - []u8 (the output buffer, `LINE_BUF_LEN` holds a full line)
///
/// Return:
/// - []const u8 (the newest line inside `buf`, empty when the queue was empty)
pub fn drainLastLine(buf: []u8) []const u8 {
    var last: c_ulong = 0;

    while (true) {
        const code = popCode();
        if (code == 0) break;

        last = code;
    }

    if (last == 0) return buf[0..0];

    return describe(last, buf);
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

/// Queue one SSL library error with `reason`, the way a failing OpenSSL call does.
fn pushSslError(reason: c_int) void {
    c.ERR_new();
    c.ERR_set_debug("error.zig", 0, "pushSslError");
    c.ERR_set_error(c.ERR_LIB_SSL, reason, null);
}

test "tlz openssl: error, popCode on an empty queue is 0" {
    clearQueue();

    try std.testing.expectEqual(@as(c_ulong, 0), popCode());
}

test "tlz openssl: error, clearQueue drops a queued error" {
    pushSslError(c.SSL_R_NO_APPLICATION_PROTOCOL);

    clearQueue();

    try std.testing.expectEqual(@as(c_ulong, 0), popCode());
}

test "tlz openssl: error, drainMatch finds the queued reason" {
    clearQueue();
    pushSslError(c.SSL_R_NO_APPLICATION_PROTOCOL);

    try std.testing.expect(drainMatch(c.ERR_LIB_SSL, &.{c.SSL_R_NO_APPLICATION_PROTOCOL}));
}

test "tlz openssl: error, drainMatch with another reason is false" {
    clearQueue();
    pushSslError(c.SSL_R_NO_APPLICATION_PROTOCOL);

    try std.testing.expect(!drainMatch(c.ERR_LIB_SSL, &.{c.SSL_R_WRONG_VERSION_NUMBER}));
}

test "tlz openssl: error, drainMatch with another library is false" {
    clearQueue();
    pushSslError(c.SSL_R_NO_APPLICATION_PROTOCOL);

    try std.testing.expect(!drainMatch(c.ERR_LIB_X509, &.{c.SSL_R_NO_APPLICATION_PROTOCOL}));
}

test "tlz openssl: error, drainMatch empties the queue" {
    clearQueue();
    pushSslError(c.SSL_R_WRONG_VERSION_NUMBER);
    pushSslError(c.SSL_R_NO_APPLICATION_PROTOCOL);

    _ = drainMatch(c.ERR_LIB_SSL, &.{c.SSL_R_WRONG_VERSION_NUMBER});

    try std.testing.expectEqual(@as(c_ulong, 0), popCode());
}

test "tlz openssl: error, describe writes a readable line" {
    clearQueue();
    pushSslError(c.SSL_R_NO_APPLICATION_PROTOCOL);
    var buf: [LINE_BUF_LEN]u8 = undefined;

    const line = describe(popCode(), &buf);

    try std.testing.expect(std.mem.find(u8, line, "no application protocol") != null);
}

test "tlz openssl: error, describe with an empty buffer is empty" {
    var buf: [0]u8 = undefined;

    try std.testing.expectEqual(@as(usize, 0), describe(0x0A000001, &buf).len);
}

test "tlz openssl: error, describe with a small buffer is cut to fit" {
    clearQueue();
    pushSslError(c.SSL_R_NO_APPLICATION_PROTOCOL);
    var buf: [8]u8 = undefined;

    const line = describe(popCode(), &buf);

    try std.testing.expect(line.len < buf.len);
}

test "tlz openssl: error, drainLastLine keeps the newest error" {
    clearQueue();
    pushSslError(c.SSL_R_WRONG_VERSION_NUMBER);
    pushSslError(c.SSL_R_NO_APPLICATION_PROTOCOL);
    var buf: [LINE_BUF_LEN]u8 = undefined;

    const line = drainLastLine(&buf);

    try std.testing.expect(std.mem.find(u8, line, "no application protocol") != null);
}

test "tlz openssl: error, drainLastLine on an empty queue is empty" {
    clearQueue();
    var buf: [LINE_BUF_LEN]u8 = undefined;

    try std.testing.expectEqual(@as(usize, 0), drainLastLine(&buf).len);
}

