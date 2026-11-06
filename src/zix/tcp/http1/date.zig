//! ZIX Http1 date
//!
//! ### file: src/zix/tcp/http1/date.zig
//! 
//! ### author: Prana Ron
//! 
//! ---------------------------------------------------------
//! 
//! ### brief:
//! 
//! Per-worker Date header cache.
//! 
//! ### note:
//! 
//! n/a
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
const dt = @import("../../utils/date_and_time.zig");

// --------------------------------------------------------- //
// Private:

/// One worker's formatted Date header and the clock second it describes.
const DateCache = struct {
    secs: u64 = 0,
    buf: [40]u8 = undefined,
    len: usize = 0,
};

threadlocal var tl_date: DateCache = .{};
threadlocal var tl_date_tick: u8 = 0;

/// Wall-clock nanoseconds since the epoch.
fn wallClockNs(io: std.Io) u64 {
    const ts = std.Io.Clock.Timestamp.now(io, .real);

    return @intCast(ts.raw.toNanoseconds());
}

/// Reformat the cached Date when the wall clock has moved to a new second.
fn refreshDate(io: std.Io) Error![]const u8 {
    const secs = wallClockNs(io) / std.time.ns_per_s;
    if (tl_date.len == 0 or secs != tl_date.secs) {
        const formatted = dt.now(io, &tl_date.buf, .RFC7231, 0, false) catch |err| switch (err) {
            error.ZixUtils_DateAndTime_NoSpaceLeft => return Error.ZixHttp1_Date_NoSpaceLeft,
            error.ZixUtils_DateAndTime_ErrorTimezoneOffset
            => return Error.ZixHttp1_Date_InvalidTimezone,
        };

        tl_date.secs = secs;
        tl_date.len = formatted.len;
    }

    return tl_date.buf[0..tl_date.len];
}

// --------------------------------------------------------- //
// Public:

/// ZIX Http1 date error
pub const Error = error {
    ZixHttp1_Date_NoSpaceLeft,
    ZixHttp1_Date_InvalidTimezone,
};

/// The Date header value for this worker.
///
/// Note:
/// - Reformatted only when the tick counter wraps or the cache is empty, so
///   the clock is read once per 256 responses on the steady path.
/// - The cached bytes are per worker, so concurrent workers never share them.
///
/// Param:
/// io - std.Io (the worker io used to read the wall clock)
///
/// Return:
/// - ![]const u8 (the RFC 7231 date, valid until the next refresh)
pub fn cachedDate(io: std.Io) Error![]const u8 {
    tl_date_tick +%= 1;
    if (tl_date_tick == 0 or tl_date.len == 0) {
        return refreshDate(io);
    }

    return tl_date.buf[0..tl_date.len];
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "zix http1: date, caches the header" {
    const value = try cachedDate(std.testing.io);

    try std.testing.expectEqual(@as(usize, 29), value.len);
    try std.testing.expect(std.mem.endsWith(u8, value, " GMT"));
}

test "zix http1: date, cache is stable between refreshes" {
    const first = try cachedDate(std.testing.io);
    const second = try cachedDate(std.testing.io);

    try std.testing.expectEqualStrings(first, second);
}

