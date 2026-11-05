//! ZIX utils date and time
//!
//! ### file: src/zix/utils/date_and_time.zig
//! 
//! ### author: Prana Ron
//! 
//! ---------------------------------------------------------
//! 
//! ### brief:
//! 
//! n/a
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

// --------------------------------------------------------- //
// Private:

const OFFSET_HOURS_MIN = -12;
const OFFSET_HOURS_MAX = 14;

fn formatTimestamp(
    timestamp_ms: i64,
    buffer: []u8,
    format: Format,
    offset_hours: i8,
    use_t: bool
) Error![]u8 {
    if (offset_hours < OFFSET_HOURS_MIN or offset_hours > OFFSET_HOURS_MAX) {
        return Error.ZixUtils_DateAndTime_ErrorTimezoneOffset;
    }

    // RFC 7231 IMF-fixdate is always expressed in GMT (UTC). The caller
    // supplied offset is still validated above for API consistency, but
    // it is ignored when formatting this variant.
    const effective_offset_hours: i8 = if (format == .RFC7231) 0 else offset_hours;
    const offset_ms = @as(i64, effective_offset_hours) * 3_600 * 1_000;
    const local_ms = timestamp_ms + offset_ms;

    const ms_per_sec = 1_000;
    const seconds: u64 = @intCast(@divTrunc(local_ms, ms_per_sec));
    const ms: u16 = @intCast(@rem(local_ms, ms_per_sec));

    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = seconds };
    const epoch_day = epoch_seconds.getEpochDay();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch_seconds.getDaySeconds();

    const year = year_day.year;
    const month = month_day.month.numeric();
    const day = month_day.day_index + 1;
    const hour = day_seconds.getHoursIntoDay();
    const minute = day_seconds.getMinutesIntoHour();
    const second = day_seconds.getSecondsIntoMinute();

    const seperator: u8 = if (use_t) 'T' else ' ';

    return switch (format) {
        .RFC3339 => {
            if (offset_hours == 0) {
                return std.fmt.bufPrint(
                    buffer,
                    "{d:0>4}-{d:0>2}-{d:0>2}{c}{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z",
                    .{ year, month, day, seperator, hour, minute, second, ms },
                ) catch return Error.ZixUtils_DateAndTime_NoSpaceLeft;
            } else {
                const sign: u8 = if (offset_hours > 0) '+' else '-';
                const abs_offset: u8 =
                    @intCast(if (offset_hours < 0) -offset_hours else offset_hours);
                
                return std.fmt.bufPrint(
                    buffer,
                    "{d:0>4}-{d:0>2}-{d:0>2}{c}{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}{c}{d:0>2}:00",
                    .{ year, month, day, seperator, hour, minute, second, ms, sign, abs_offset },
                ) catch return Error.ZixUtils_DateAndTime_NoSpaceLeft;
            }
        },
        .RFC7231 => {
            const dow_names = [_][]const u8{
                "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat",
            };
            const month_names = [_][]const u8{
                "Jan", "Feb", "Mar", "Apr", "May", "Jun",
                "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
            };

            const dow: usize =
                @intCast((@as(u64, epoch_day.day) + 4) % 7);
            const month_idx: usize = @intCast(month - 1);

            return std.fmt.bufPrint(
                buffer,
                "{s}, {d:0>2} {s} {d:0>4} {d:0>2}:{d:0>2}:{d:0>2} GMT",
                .{
                    dow_names[dow], day,
                    month_names[month_idx],
                    year, hour, minute, second,
                },
            ) catch return Error.ZixUtils_DateAndTime_NoSpaceLeft;
        },
        .ISO8601 => std.fmt.bufPrint(
            buffer,
            "{d:0>4}-{d:0>2}-{d:0>2}{c}{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}",
            .{ year, month, day, seperator, hour, minute, second, ms },
        ) catch return Error.ZixUtils_DateAndTime_NoSpaceLeft,
    };
}

// --------------------------------------------------------- //
// Public:

pub const Error = error {
    ZixUtils_DateAndTime_NoSpaceLeft,
    ZixUtils_DateAndTime_ErrorTimezoneOffset,
};

pub const OUT_BUFFER_SIZE_RFC3339: usize = 30;
pub const OUT_BUFFER_SIZE_ISO8601: usize = 23;
// "Sun, 06 Nov 1994 08:49:37 GMT" = 29 bytes; +1 margin.
pub const OUT_BUFFER_SIZE_RFC7231: usize = 30;

pub const Format = enum {
    RFC3339,
    RFC7231,
    ISO8601,
};

/// Param:
/// io - std.Io
/// buffer - min for RC3339 and RFC7231 is 30 & for ISO8601 23
/// offset_hours - min -12 & max 14, error otherwise (check OUT_BUFFER_*)
/// uset_t - if true, result has `T` seperator, ` ` otherwise
pub fn now(io: std.Io, buffer: []u8, format: Format, offset_hours: i8, use_t: bool) Error![]u8 {
    const timestamp = std.Io.Clock.Timestamp.now(io, .real);
    return formatTimestamp(timestamp.raw.toMilliseconds(), buffer, format, offset_hours, use_t);
}

/// Read the monotonic clock, in milliseconds.
///
/// Note:
/// - Compare a read only against another read from this same function. Two stamps that reach the
///   same comparison must come from one clock, mixing this with a wall-clock stamp is a bug.
///
/// Param:
/// io - std.Io (the same io the caller sleeps and polls on)
///
/// Return:
/// - i64 (milliseconds since an unspecified point, never decreasing between calls)
pub fn nowMs(io: std.Io) i64 {
    return std.Io.Clock.Timestamp.now(io, .awake).raw.toMilliseconds();
}

/// Read the monotonic clock, in nanoseconds.
pub fn nowUs(io: std.Io) i96 {
    return std.Io.Clock.Timestamp.now(io, .awake).raw.toNanoseconds();
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "zix utils: date and time RFC3339" {
    var buffer: [OUT_BUFFER_SIZE_RFC3339]u8 = undefined;
    const out = try now(std.testing.io, &buffer, .RFC3339, 7, true);

    try std.testing.expectEqual(@as(usize, 29), out.len);

    // Guarantee the offset hours
    const err = now(std.testing.io, &buffer, .RFC3339, 15, true);
    try std.testing.expectError(Error.ZixUtils_DateAndTime_ErrorTimezoneOffset, err);
}

test "zix utils: date and time RFC7231" {
    var buffer: [OUT_BUFFER_SIZE_RFC7231]u8 = undefined;
    const out = try now(std.testing.io, &buffer, .RFC7231, 7, false);

    // "Wdy, DD Mon YYYY HH:MM:SS GMT" is always 29 bytes.
    try std.testing.expectEqual(@as(usize, 29), out.len);
    try std.testing.expect(std.mem.endsWith(u8, out, " GMT"));

    // Shape: "Wdy, DD Mon YYYY HH:MM:SS GMT"
    try std.testing.expectEqual(@as(u8, ','), out[3]);
    try std.testing.expectEqual(@as(u8, ' '), out[4]);
    try std.testing.expectEqual(@as(u8, ' '), out[7]);
    try std.testing.expectEqual(@as(u8, ' '), out[11]);
    try std.testing.expectEqual(@as(u8, ' '), out[16]);

    // Guarantee the offset hours (both ends of the range).
    const err_hi = now(std.testing.io, &buffer, .RFC7231, 15, false);
    try std.testing.expectError(Error.ZixUtils_DateAndTime_ErrorTimezoneOffset, err_hi);

    const err_lo = now(std.testing.io, &buffer, .RFC7231, -13, false);
    try std.testing.expectError(Error.ZixUtils_DateAndTime_ErrorTimezoneOffset, err_lo);
}

test "zix utils: date and time RFC7231 deterministic" {
    var buffer: [OUT_BUFFER_SIZE_RFC7231]u8 = undefined;

    // RFC 7231 7.1.1.1 canonical example.
    // 784111777 = 1994-11-06 08:49:37 UTC (Sunday).
    try std.testing.expectEqualStrings(
        "Sun, 06 Nov 1994 08:49:37 GMT",
        try formatTimestamp(784_111_777_000, &buffer, .RFC7231, 0, false),
    );

    // Unix epoch.
    try std.testing.expectEqualStrings(
        "Thu, 01 Jan 1970 00:00:00 GMT",
        try formatTimestamp(0, &buffer, .RFC7231, 0, false),
    );

    // End-of-year rollover.
    try std.testing.expectEqualStrings(
        "Fri, 31 Dec 1999 23:59:59 GMT",
        try formatTimestamp(946_684_799_000, &buffer, .RFC7231, 0, false),
    );

    // Leap day inside a century leap year (2000 is divisible by 400).
    try std.testing.expectEqualStrings(
        "Tue, 29 Feb 2000 12:34:56 GMT",
        try formatTimestamp(951_827_696_000, &buffer, .RFC7231, 0, false),
    );

    // IMF-fixdate is always GMT: the caller offset must not shift components.
    try std.testing.expectEqualStrings(
        "Sun, 06 Nov 1994 08:49:37 GMT",
        try formatTimestamp(784_111_777_000, &buffer, .RFC7231, 7, false),
    );
    try std.testing.expectEqualStrings(
        "Sun, 06 Nov 1994 08:49:37 GMT",
        try formatTimestamp(784_111_777_000, &buffer, .RFC7231, -5, false),
    );

    // Sub-second precision is dropped (RFC 7231 has no ms field).
    try std.testing.expectEqualStrings(
        "Sun, 06 Nov 1994 08:49:37 GMT",
        try formatTimestamp(784_111_777_999, &buffer, .RFC7231, 0, false),
    );

    // use_t is irrelevant for RFC7231 - both must produce the same line.
    var buf_a: [OUT_BUFFER_SIZE_RFC7231]u8 = undefined;
    var buf_b: [OUT_BUFFER_SIZE_RFC7231]u8 = undefined;
    const line_space = try formatTimestamp(784_111_777_000, &buf_a, .RFC7231, 0, false);
    const line_t = try formatTimestamp(784_111_777_000, &buf_b, .RFC7231, 0, true);
    try std.testing.expectEqualStrings(line_space, line_t);

    // Out-of-range offset still rejected before formatting.
    try std.testing.expectError(
        Error.ZixUtils_DateAndTime_ErrorTimezoneOffset,
        formatTimestamp(784_111_777_000, &buffer, .RFC7231, 15, false),
    );
    try std.testing.expectError(
        Error.ZixUtils_DateAndTime_ErrorTimezoneOffset,
        formatTimestamp(784_111_777_000, &buffer, .RFC7231, -13, false),
    );
}

test "zix utils: date and time ISO8601" {
    var buffer: [OUT_BUFFER_SIZE_ISO8601]u8 = undefined;
    const out = try now(std.testing.io, &buffer, .ISO8601, 7, false);

    try std.testing.expectEqual(@as(usize, 23), out.len);

    // Guarantee the offset hours
    const err = now(std.testing.io, &buffer, .ISO8601, -13, false);
    try std.testing.expectError(Error.ZixUtils_DateAndTime_ErrorTimezoneOffset, err);
}

