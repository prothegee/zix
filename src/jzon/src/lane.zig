//! JZON lane
//!
//! ### file: src/jzon/src/lane.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Lane basics shared by the vector writer and the vector reader: the lane width, the
//! lane type, and where the first special byte of a lane sits.
//!
//! ### note:
//!
//! `firstEscaped` answers for the same byte set as `escape.isEscaped`, a lane at a
//! time. Change one and the other must change with it.
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
// Public:

/// Bytes classified per comparison.
///
/// Note:
/// - Held at 16 because that is the width the measurement was taken at, and it is the
///   widest vector every supported target can lower without splitting.
pub const LANES = 16;

/// One lane of text.
pub const Chunk = @Vector(LANES, u8);

/// Where the first byte that cannot go out raw sits inside one lane.
///
/// Note:
/// - Three comparisons, all lane parallel. A clean lane costs the comparisons and
///   nothing more, because finding the position only runs once a lane has a hit.
/// - Both directions ask this. On the way out these are the bytes that have to be
///   spelled differently. On the way in they are the bytes that end a string token,
///   open an escape, or may not appear raw at all.
///
/// Param:
/// chunk - Chunk (one lane of text)
///
/// Return:
/// - usize (the offset inside the lane of the first such byte)
/// - null when every byte in the lane may stand as itself
pub inline fn firstEscaped(chunk: Chunk) ?usize {
    const quote: Chunk = @splat('"');
    const backslash: Chunk = @splat('\\');
    const first_printable: Chunk = @splat(0x20);

    const hits = (chunk == quote) | (chunk == backslash) | (chunk < first_printable);

    // The lane index comes back at its own narrow width, which every caller wants as
    // an offset it can add to a position.
    const offset = std.simd.firstTrue(hits) orelse return null;

    return offset;
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const escape = @import("escape.zig");

test "jzon: lane, firstEscaped on a clean lane is null" {
    const chunk: Chunk = @splat('x');

    try std.testing.expect(firstEscaped(chunk) == null);
}

test "jzon: lane, firstEscaped finds the quote, backslash, or control at every offset" {
    for (0..LANES) |offset| {
        for ([_]u8{ '"', '\\', '\n' }) |special| {
            var bytes: [LANES]u8 = @splat('x');
            bytes[offset] = special;

            try std.testing.expectEqual(@as(?usize, offset), firstEscaped(bytes));
        }
    }
}

test "jzon: lane, firstEscaped reports the earliest hit in a lane" {
    var bytes: [LANES]u8 = @splat('x');
    bytes[3] = '\\';
    bytes[9] = '"';

    try std.testing.expectEqual(@as(?usize, 3), firstEscaped(bytes));
}

test "jzon: lane, firstEscaped agrees with escape.isEscaped on every byte" {
    for (0..256) |value| {
        const byte: u8 = @intCast(value);
        const chunk: Chunk = @splat(byte);

        const expected: ?usize = if (escape.isEscaped(byte)) 0 else null;

        try std.testing.expectEqual(expected, firstEscaped(chunk));
    }
}

test "jzon: lane, firstEscaped passes 0x20, 0x7f, and 0xff raw" {
    for ([_]u8{ 0x20, 0x7f, 0xff }) |byte| {
        const chunk: Chunk = @splat(byte);

        try std.testing.expect(firstEscaped(chunk) == null);
    }
}

test "jzon: lane, firstEscaped finds a hit in the last lane slot" {
    var bytes: [LANES]u8 = @splat('x');
    bytes[LANES - 1] = 0x1f;

    try std.testing.expectEqual(@as(?usize, LANES - 1), firstEscaped(bytes));
}

