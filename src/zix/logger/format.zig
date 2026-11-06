//! ZIX Logger format
//!
//! ### file: src/zix/logger/format.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Bounded record formatting and the level/status mapping.
//!
//! ### note:
//!
//! A record is never dropped for being long. What does not fit is replaced by
//! the truncation mark, so a short line is always readable as short.
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
const Timestamp = @import("Timestamp.zig");

// --------------------------------------------------------- //
// Private:

fn markTruncated(buf: []u8, writer: *std.Io.Writer) []const u8 {
    const kept = writer.buffered().len;
    @memcpy(buf[kept..][0..TRUNCATION_MARK.len], TRUNCATION_MARK);

    return buf[0 .. kept + TRUNCATION_MARK.len];
}

// --------------------------------------------------------- //
// Public:

/// ZIX Logger level.
pub const Level = enum(u8) {
    DEBUG = 0,
    INFO = 1,
    WARN = 2,
    ERROR = 3,
};

/// Stack buffer for formatting one whole log line.
pub const LINE_BUF_SIZE: usize = 4096;

/// What ends a record the buffer could not hold.
pub const TRUNCATION_MARK = " ...[truncated]";

/// Five-byte level label used at the start of every record.
pub fn levelLabel(level: Level) []const u8 {
    return switch (level) {
        .DEBUG => "DEBUG",
        .INFO => "INFO ",
        .WARN => "WARN ",
        .ERROR => "ERROR",
    };
}

/// Derive a record level from an HTTP status.
pub fn statusLevel(status: u16) Level {
    return if (status >= 500)
        .ERROR
    else if (status >= 400)
        .WARN
    else if (status >= 200)
        .INFO
    else
        .DEBUG;
}

/// Format one record into buf, marking it when it does not all fit.
pub fn formatRecord(
    buf: []u8,
    comptime fmt: []const u8,
    args: anytype,
) []const u8 {
    var writer = std.Io.Writer.fixed(buf[0 .. buf.len - TRUNCATION_MARK.len]);
    writer.print(fmt, args) catch return markTruncated(buf, &writer);

    return writer.buffered();
}

/// Format a system record directly after its timestamp and component prefix.
pub fn formatSystem(
    buf: []u8,
    timestamp: *const Timestamp,
    level: Level,
    component: []const u8,
    comptime fmt: []const u8,
    args: anytype,
) []const u8 {
    var writer = std.Io.Writer.fixed(buf[0 .. buf.len - TRUNCATION_MARK.len]);
    writer.print(
        "{s} {s} {s}  [{s}] ",
        .{ &timestamp.date, &timestamp.time, levelLabel(level), component },
    ) catch return markTruncated(buf, &writer);
    writer.print(fmt, args) catch return markTruncated(buf, &writer);

    return writer.buffered();
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "zix logger: format, a record that fits is unchanged" {
    var buf: [64]u8 = undefined;
    const line = formatRecord(&buf, "{s}:{d}", .{ "port", 8080 });

    try std.testing.expectEqualStrings("port:8080", line);
}

test "zix logger: format, an overflow keeps a marked short line" {
    var buf: [32]u8 = undefined;
    const line = formatRecord(
        &buf,
        "{s}",
        .{"0123456789012345678901234567890123456789"},
    );

    try std.testing.expect(line.len <= buf.len);
    try std.testing.expect(std.mem.endsWith(u8, line, TRUNCATION_MARK));
    try std.testing.expect(std.mem.startsWith(u8, line, "0123456789"));
}

test "zix logger: format, exact fit and one byte over" {
    var buf: [24]u8 = undefined;
    const room = buf.len - TRUNCATION_MARK.len;

    const exact = formatRecord(&buf, "{s}", .{"abcdefghi"});
    try std.testing.expectEqualStrings("abcdefghi", exact);
    try std.testing.expect(exact.len <= room);

    var over_buf: [24]u8 = undefined;
    const over = formatRecord(
        &over_buf,
        "{s}",
        .{"abcdefghijklmnop"},
    );
    try std.testing.expect(std.mem.endsWith(u8, over, TRUNCATION_MARK));
}

test "zix logger: format, every level label is five bytes" {
    for ([_]Level{ .DEBUG, .INFO, .WARN, .ERROR }) |level| {
        try std.testing.expectEqual(@as(usize, 5), levelLabel(level).len);
    }
}

test "zix logger: format, status maps to the expected level" {
    try std.testing.expectEqual(Level.DEBUG, statusLevel(100));
    try std.testing.expectEqual(Level.INFO, statusLevel(200));
    try std.testing.expectEqual(Level.INFO, statusLevel(304));
    try std.testing.expectEqual(Level.WARN, statusLevel(404));
    try std.testing.expectEqual(Level.ERROR, statusLevel(502));
}

test "zix logger: format, system record renders prefix and message" {
    const timestamp: Timestamp = .{
        .date = "2026-11-06".*,
        .time = "22:15:00.123".*,
    };

    var buf: [128]u8 = undefined;
    const line = formatSystem(
        &buf,
        &timestamp,
        .INFO,
        "http1",
        "listening on {s}:{d}",
        .{ "127.0.0.1", 8080 },
    );

    try std.testing.expectEqualStrings(
        "2026-11-06 22:15:00.123 INFO   [http1] listening on 127.0.0.1:8080",
        line,
    );
}

