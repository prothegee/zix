//! ZIX Http2 Grpc deadline
//!
//! ### file: src/zix/tcp/http2/grpc/deadline.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! The deadline of one gRPC call: the tightest of the server budget, the
//! route budget, and the client grpc-timeout header.
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
const timeout = @import("timeout.zig");
const Header = @import("../hpack/Header.zig");

const Timestamp = std.Io.Clock.Timestamp;

// --------------------------------------------------------- //
// Private:

/// Wall-clock timestamp ns nanoseconds from now.
fn fromNowNs(io: std.Io, ns: u64) Timestamp {
    return Timestamp.fromNow(io, .{
        .raw = std.Io.Duration.fromNanoseconds(@intCast(ns)),
        .clock = .real,
    });
}

// --------------------------------------------------------- //
// Public:

/// The earlier of two deadlines.
///
/// Param:
/// current - ?Timestamp (the deadline so far, null when none)
/// candidate - Timestamp (a new deadline)
///
/// Return:
/// - Timestamp (candidate when current is null or later)
pub fn tighter(current: ?Timestamp, candidate: Timestamp) Timestamp {
    const held = current orelse return candidate;

    return if (candidate.compare(.lt, held)) candidate else held;
}

/// Tighten a deadline with a millisecond budget from now.
///
/// Param:
/// io - std.Io (the worker io, read for the wall clock)
/// current - ?Timestamp (the deadline so far, null when none)
/// ms - u32 (budget in milliseconds, 0 leaves current untouched)
///
/// Return:
/// - ?Timestamp
pub fn tightenMs(io: std.Io, current: ?Timestamp, ms: u32) ?Timestamp {
    if (ms == 0) return current;

    return tighter(current, fromNowNs(io, @as(u64, ms) * std.time.ns_per_ms));
}

/// Deadline for a call at dispatch.
///
/// Note:
/// - A grpc-timeout header that does not parse is ignored, as the gRPC spec
///   leaves the call without a client deadline then.
///
/// Param:
/// io - std.Io (the worker io, read for the wall clock)
/// handler_timeout_ms - u32 (server budget, 0 disables it)
/// headers - []const Header (decoded request headers)
///
/// Return:
/// - ?Timestamp (null when neither budget is set)
pub fn computeDeadline(
    io: std.Io,
    handler_timeout_ms: u32,
    headers: []const Header,
) ?Timestamp {
    var best = tightenMs(io, null, handler_timeout_ms);

    for (headers) |header| {
        if (!std.mem.eql(u8, header.name, "grpc-timeout")) continue;

        const ns = timeout.parseTimeout(header.value) catch |err| switch (err) {
            error.ZixHttp2_GrpcTimeout_InvalidFormat,
            error.ZixHttp2_GrpcTimeout_TooManyDigits,
            error.ZixHttp2_GrpcTimeout_InvalidNumber,
            error.ZixHttp2_GrpcTimeout_NotPositive,
            error.ZixHttp2_GrpcTimeout_InvalidUnit,
            error.ZixHttp2_GrpcTimeout_Overflow,
            => continue,
        };

        best = tighter(best, fromNowNs(io, ns));
    }

    return best;
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

fn timeoutHeader(value: []const u8) [1]Header {
    return .{
        .{
            .name = "grpc-timeout",
            .value = value,
        },
    };
}

fn isPast(stamp: Timestamp) bool {
    return Timestamp.now(std.testing.io, .real).compare(.gte, stamp);
}

test "zix http2 grpc: deadline, tighter without a current takes the candidate" {
    const now = Timestamp.now(std.testing.io, .real);

    try std.testing.expect(tighter(null, now).compare(.eq, now));
}

test "zix http2 grpc: deadline, tighter keeps the earlier" {
    const early = Timestamp.now(std.testing.io, .real);
    const late = fromNowNs(std.testing.io, std.time.ns_per_s);

    try std.testing.expect(tighter(late, early).compare(.eq, early));
    try std.testing.expect(tighter(early, late).compare(.eq, early));
}

test "zix http2 grpc: deadline, tightenMs zero leaves the deadline" {
    try std.testing.expect(tightenMs(std.testing.io, null, 0) == null);
}

test "zix http2 grpc: deadline, tightenMs sets a future deadline" {
    const stamp = tightenMs(std.testing.io, null, 60_000).?;

    try std.testing.expect(!isPast(stamp));
}

test "zix http2 grpc: deadline, tightenMs keeps an earlier deadline" {
    const early = Timestamp.now(std.testing.io, .real);

    const stamp = tightenMs(std.testing.io, early, 60_000).?;

    try std.testing.expect(stamp.compare(.eq, early));
}

test "zix http2 grpc: deadline, computeDeadline without budgets is null" {
    try std.testing.expect(computeDeadline(std.testing.io, 0, &.{}) == null);
}

test "zix http2 grpc: deadline, computeDeadline takes the server budget" {
    const stamp = computeDeadline(std.testing.io, 60_000, &.{}).?;

    try std.testing.expect(!isPast(stamp));
}

test "zix http2 grpc: deadline, computeDeadline takes a tighter grpc-timeout" {
    const headers = timeoutHeader("1n");

    const stamp = computeDeadline(std.testing.io, 60_000, &headers).?;

    try std.testing.expect(isPast(stamp));
}

test "zix http2 grpc: deadline, computeDeadline keeps a tighter server budget" {
    const headers = timeoutHeader("1H");

    const stamp = computeDeadline(std.testing.io, 60_000, &headers).?;
    const hour_out = fromNowNs(std.testing.io, 30 * std.time.ns_per_min);

    try std.testing.expect(stamp.compare(.lt, hour_out));
}

test "zix http2 grpc: deadline, computeDeadline ignores a malformed grpc-timeout" {
    const headers = timeoutHeader("10X");

    try std.testing.expect(computeDeadline(std.testing.io, 0, &headers) == null);
}

