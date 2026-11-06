//! ZIX Logger Timestamp
//!
//! ### file: src/zix/logger/Timestamp.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! UTC wall-clock stamp for one log record.
//!
//! ### note:
//!
//! The logger runs on background OS threads with no `std.Io` instance, so the
//! clock is read through the platform surface directly. A clock read failure
//! falls back to the Unix epoch rather than failing a log call.
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
const builtin = @import("builtin");

// --------------------------------------------------------- //
// Fields:

/// `YYYY-MM-DD`.
date: [10]u8,
/// `HH:MM:SS.mmm`.
time: [12]u8,

const Self = @This();

// --------------------------------------------------------- //
// Private:

const Cache = struct {
    secs: u64 = std.math.maxInt(u64),
    date: [10]u8 = undefined,
    hms: [8]u8 = undefined,
};

threadlocal var cache: Cache = .{};

fn write2(buf: *[2]u8, value: u8) void {
    buf[0] = '0' + value / 10;
    buf[1] = '0' + value % 10;
}

fn write3(buf: *[3]u8, value: u16) void {
    buf[0] = '0' + @as(u8, @intCast(value / 100));
    buf[1] = '0' + @as(u8, @intCast((value / 10) % 10));
    buf[2] = '0' + @as(u8, @intCast(value % 10));
}

fn write4(buf: *[4]u8, value: u16) void {
    buf[0] = '0' + @as(u8, @intCast(value / 1000));
    buf[1] = '0' + @as(u8, @intCast((value / 100) % 10));
    buf[2] = '0' + @as(u8, @intCast((value / 10) % 10));
    buf[3] = '0' + @as(u8, @intCast(value % 10));
}

fn fromEpoch(secs: u64, ms: u16) Self {
    const epoch_secs = std.time.epoch.EpochSeconds{ .secs = secs };
    const day_secs = epoch_secs.getDaySeconds();
    const epoch_day = epoch_secs.getEpochDay();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    var timestamp: Self = undefined;

    write4(timestamp.date[0..4], year_day.year);
    timestamp.date[4] = '-';
    write2(timestamp.date[5..7], month_day.month.numeric());
    timestamp.date[7] = '-';
    write2(timestamp.date[8..10], month_day.day_index + 1);

    write2(timestamp.time[0..2], day_secs.getHoursIntoDay());
    timestamp.time[2] = ':';
    write2(timestamp.time[3..5], day_secs.getMinutesIntoHour());
    timestamp.time[5] = ':';
    write2(timestamp.time[6..8], day_secs.getSecondsIntoMinute());
    timestamp.time[8] = '.';
    write3(timestamp.time[9..12], ms);

    return timestamp;
}

fn clockNs() u64 {
    if (comptime builtin.os.tag == .linux) {
        var spec: std.os.linux.timespec = undefined;
        const rc = std.os.linux.clock_gettime(.REALTIME, &spec);
        switch (std.posix.errno(rc)) {
            .SUCCESS => {},
            else => return 0,
        }

        if (spec.sec < 0 or spec.nsec < 0) return 0;

        return @as(u64, @intCast(spec.sec)) * std.time.ns_per_s +
            @as(u64, @intCast(spec.nsec));
    }

    if (comptime builtin.os.tag == .windows) {
        const epoch_ns: i96 = @as(i96, std.time.epoch.windows) *
            std.time.ns_per_s;
        const filetime_ns: i96 =
            @as(i96, std.os.windows.ntdll.RtlGetSystemTimePrecise()) * 100;
        const total = filetime_ns + epoch_ns;

        return if (total > 0) @intCast(total) else 0;
    }

    var spec: std.posix.timespec = undefined;
    const rc = std.posix.system.clock_gettime(.REALTIME, &spec);
    switch (std.posix.errno(rc)) {
        .SUCCESS => {},
        else => return 0,
    }

    if (spec.sec < 0 or spec.nsec < 0) return 0;

    return @as(u64, @intCast(spec.sec)) * std.time.ns_per_s +
        @as(u64, @intCast(spec.nsec));
}

// --------------------------------------------------------- //
// Public:

/// Read the current UTC stamp.
///
/// Note:
/// - The civil date and `HH:MM:SS` are cached per thread for the whole second,
///   so a burst formats only the milliseconds per record.
pub fn now() Self {
    const ns = clockNs();
    const secs: u64 = ns / std.time.ns_per_s;
    const ms: u16 = @intCast((ns % std.time.ns_per_s) / std.time.ns_per_ms);

    if (cache.secs != secs) {
        const fresh = fromEpoch(secs, 0);
        cache.secs = secs;
        cache.date = fresh.date;
        @memcpy(&cache.hms, fresh.time[0..8]);
    }

    var timestamp: Self = .{
        .date = cache.date,
        .time = undefined,
    };
    @memcpy(timestamp.time[0..8], &cache.hms);
    timestamp.time[8] = '.';
    write3(timestamp.time[9..12], ms);

    return timestamp;
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "zix logger: Timestamp, epoch renders the exact UTC date and time" {
    const timestamp = fromEpoch(0, 0);

    try std.testing.expectEqualStrings("1970-01-01", &timestamp.date);
    try std.testing.expectEqualStrings("00:00:00.000", &timestamp.time);
}

test "zix logger: Timestamp, known epoch renders the exact UTC date" {
    const timestamp = fromEpoch(1_700_000_000, 123);

    try std.testing.expectEqualStrings("2023-11-14", &timestamp.date);
    try std.testing.expectEqualStrings("22:13:20.123", &timestamp.time);
}

test "zix logger: Timestamp, leap day is rendered" {
    const timestamp = fromEpoch(951_782_400, 7);

    try std.testing.expectEqualStrings("2000-02-29", &timestamp.date);
    try std.testing.expectEqualStrings("00:00:00.007", &timestamp.time);
}

test "zix logger: Timestamp, last second of the day" {
    const timestamp = fromEpoch(86_399, 999);

    try std.testing.expectEqualStrings("1970-01-01", &timestamp.date);
    try std.testing.expectEqualStrings("23:59:59.999", &timestamp.time);
}

