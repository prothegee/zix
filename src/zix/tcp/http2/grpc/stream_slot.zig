//! ZIX Http2 Grpc stream slot
//!
//! ### file: src/zix/tcp/http2/grpc/stream_slot.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Stream table of one gRPC connection: claim, find, and the in-flight check.
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
const Stream = @import("Stream.zig");

// --------------------------------------------------------- //
// Public:

/// Claim the first free entry for sid.
///
/// Param:
/// sid - u31 (the new stream id)
/// streams - []Stream (the connection's stream table)
/// used - []bool (which entries are live, same length as streams)
///
/// Return:
/// - ?usize (the claimed index, null when every entry is live)
pub fn claim(sid: u31, streams: []Stream, used: []bool) ?usize {
    for (used, 0..) |in_use, index| {
        if (in_use) continue;

        used[index] = true;
        streams[index].id = sid;

        return index;
    }

    return null;
}

/// Find the live entry for sid.
///
/// Param:
/// sid - u31 (the stream id to look up)
/// streams - []const Stream (the connection's stream table)
/// used - []const bool (which entries are live)
///
/// Return:
/// - ?usize (the index, null when no live entry has sid)
pub fn find(sid: u31, streams: []const Stream, used: []const bool) ?usize {
    for (used, 0..) |in_use, index| {
        if (in_use and streams[index].id == sid) return index;
    }

    return null;
}

/// Whether any live stream is still waiting for the rest of its request.
///
/// Param:
/// streams - []const Stream (the connection's stream table)
/// used - []const bool (which entries are live)
///
/// Return:
/// - bool (true when a request was in flight)
pub fn requestInFlight(streams: []const Stream, used: []const bool) bool {
    for (used, 0..) |in_use, index| {
        if (in_use and !streams[index].end_stream) return true;
    }

    return false;
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const TEST_SLOTS: usize = 2;

test "zix http2 grpc: stream_slot, claim takes the first free entry" {
    var streams: [TEST_SLOTS]Stream = @splat(.{});
    var used = [_]bool{
        true,
        false,
    };

    try std.testing.expectEqual(@as(?usize, 1), claim(7, &streams, &used));
    try std.testing.expect(used[1]);
    try std.testing.expectEqual(@as(u31, 7), streams[1].id);
}

test "zix http2 grpc: stream_slot, claim past the cap returns null" {
    var streams: [TEST_SLOTS]Stream = @splat(.{});
    var used: [TEST_SLOTS]bool = @splat(true);

    try std.testing.expectEqual(@as(?usize, null), claim(9, &streams, &used));
}

test "zix http2 grpc: stream_slot, find returns the live entry" {
    var streams: [TEST_SLOTS]Stream = @splat(.{});
    var used: [TEST_SLOTS]bool = @splat(false);
    _ = claim(3, &streams, &used);
    _ = claim(5, &streams, &used);

    try std.testing.expectEqual(@as(?usize, 1), find(5, &streams, &used));
}

test "zix http2 grpc: stream_slot, find skips a freed entry" {
    var streams: [TEST_SLOTS]Stream = @splat(.{});
    var used: [TEST_SLOTS]bool = @splat(false);
    const index = claim(3, &streams, &used).?;
    used[index] = false;

    try std.testing.expectEqual(@as(?usize, null), find(3, &streams, &used));
}

test "zix http2 grpc: stream_slot, requestInFlight sees an unended stream" {
    var streams: [TEST_SLOTS]Stream = @splat(.{});
    var used: [TEST_SLOTS]bool = @splat(false);
    _ = claim(1, &streams, &used);

    try std.testing.expect(requestInFlight(&streams, &used));
}

test "zix http2 grpc: stream_slot, requestInFlight is false when every stream ended" {
    var streams: [TEST_SLOTS]Stream = @splat(.{});
    var used: [TEST_SLOTS]bool = @splat(false);
    const index = claim(1, &streams, &used).?;
    streams[index].end_stream = true;

    try std.testing.expect(!requestInFlight(&streams, &used));
}

test "zix http2 grpc: stream_slot, requestInFlight is false on an empty table" {
    const streams: [TEST_SLOTS]Stream = @splat(.{});
    const used: [TEST_SLOTS]bool = @splat(false);

    try std.testing.expect(!requestInFlight(&streams, &used));
}

