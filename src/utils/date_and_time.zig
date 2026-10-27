const std = @import("std");

// --------------------------------------------------------- //

const OFFSET_HOURS_MIN = -12;
const OFFSET_HOURS_MAX = 14;

pub const OUT_BUFFER_SIZE_RFC3339: usize = 30;
pub const OUT_BUFFER_SIZE_ISO8601: usize = 23;

pub const Format = enum {
    RFC3339,
    ISO8601,
};

pub const Error = error {
    ZixUtilsDT_WrongTimezoneOffset,
    ZixUtilsDT_NoSpaceLeft,
};

// --------------------------------------------------------- //

fn formatTimestamp(
    timestamp_ms: i64,
    buffer: []u8,
    format: Format,
    offset_hours: i8,
    use_t: bool
) Error![]u8 {
    if (offset_hours < OFFSET_HOURS_MIN or offset_hours > OFFSET_HOURS_MAX) {
        return Error.ZixUtilsDT_WrongTimezoneOffset;
    }

    const offset_ms = @as(i64, offset_hours) * 3_600 * 1_000;
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
                ) catch return Error.ZixUtilsDT_NoSpaceLeft;
            } else {
                const sign: u8 = if (offset_hours > 0) '+' else '-';
                const abs_offset: u8 =
                    @intCast(if (offset_hours < 0) -offset_hours else offset_hours);
                
                return std.fmt.bufPrint(
                    buffer,
                    "{d:0>4}-{d:0>2}-{d:0>2}{c}{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}{c}{d:0>2}:00",
                    .{ year, month, day, seperator, hour, minute, second, ms, sign, abs_offset },
                ) catch return Error.ZixUtilsDT_NoSpaceLeft;
            }
        },
        .ISO8601 => std.fmt.bufPrint(
            buffer,
            "{d:0>4}-{d:0>2}-{d:0>2}{c}{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}",
            .{ year, month, day, seperator, hour, minute, second, ms },
        ) catch return Error.ZixUtilsDT_NoSpaceLeft,
    };
}

// --------------------------------------------------------- //

/// Param:
/// io - std.Io
/// buffer - min for RC3339 30 & for ISO8601 23
/// offset_hours - min -12 & max 14, error otherwise (check OUT_BUFFER_*)
/// uset_t - if true, result has `T` seperator, ` ` otherwise
pub fn now(io: std.Io, buffer: []u8, format: Format, offset_hours: i8, use_t: bool) Error![]u8 {
    const timestamp = std.Io.Clock.Timestamp.now(io, .real);
    return formatTimestamp(timestamp.raw.toMilliseconds(), buffer, format, offset_hours, use_t);
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //

test "zix utils: date and time RFC3339" {
    var buffer: [OUT_BUFFER_SIZE_RFC3339]u8 = undefined;
    const out = try now(std.testing.io, &buffer, .RFC3339, 7, true);

    try std.testing.expectEqual(@as(usize, 29), out.len);

    // Guarantee the offset hours
    const err = now(std.testing.io, &buffer, .RFC3339, 15, true);
    try std.testing.expectError(Error.ZixUtilsDT_WrongTimezoneOffset, err);
}

test "zix utils: date and time ISO8601" {
    var buffer: [OUT_BUFFER_SIZE_ISO8601]u8 = undefined;
    const out = try now(std.testing.io, &buffer, .ISO8601, 7, false);

    try std.testing.expectEqual(@as(usize, 23), out.len);

    // Guarantee the offset hours
    const err = now(std.testing.io, &buffer, .ISO8601, -13, false);
    try std.testing.expectError(Error.ZixUtilsDT_WrongTimezoneOffset, err);
}
