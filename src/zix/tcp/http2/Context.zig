//! ZIX Http2 Context
//!
//! ### file: src/zix/tcp/http2/Context.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Handler context for one HTTP/2 stream: io, allocator, fd, stream id, and deadline.
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
const builtin = @import("builtin");

// --------------------------------------------------------- //
// Fields:

io: std.Io,
/// Connection fd, the raw escape hatch.
fd: std.posix.fd_t,
/// HTTP/2 stream id.
sid: u31,
/// Per-request scratch allocator.
allocator: std.mem.Allocator,
deadline: ?std.Io.Clock.Timestamp = null,
/// Static file directory from Config.public_dir. Empty sends an unmatched
/// route straight to 404.
public_dir: []const u8 = "",
/// Peer SETTINGS_MAX_FRAME_SIZE, the cap on every DATA frame the static
/// fallback emits.
max_frame_size: u32 = 16384,

const Self = @This();

// --------------------------------------------------------- //
// Private:

fn fromNow(io: std.Io, ms: u64) std.Io.Clock.Timestamp {
    return std.Io.Clock.Timestamp.fromNow(
        io,
        std.Io.Clock.Duration{
            .raw = std.Io.Duration.fromMilliseconds(@intCast(ms)),
            .clock = .real,
        },
    );
}

// --------------------------------------------------------- //
// Public:

/// Backing size in bytes of the per-request stack arena behind allocator.
pub const CTX_ARENA_BYTES: usize = 4096;

/// Build a context for one stream.
///
/// Param:
/// io - std.Io (the worker io)
/// allocator - std.mem.Allocator (per-request scratch)
/// fd - std.posix.fd_t (the connection)
/// sid - u31 (the stream id)
///
/// Return:
/// - Context
pub fn init(io: std.Io, allocator: std.mem.Allocator, fd: std.posix.fd_t, sid: u31) Self {
    return .{
        .io = io,
        .allocator = allocator,
        .fd = fd,
        .sid = sid,
    };
}

/// Return a copy with the deadline set to now + ms.
pub fn withTimeout(self: Self, ms: u64) Self {
    var ctx = self;
    ctx.deadline = fromNow(self.io, ms);

    return ctx;
}

/// Return a copy with an explicit deadline timestamp.
pub fn withDeadline(self: Self, timestamp: std.Io.Clock.Timestamp) Self {
    var ctx = self;
    ctx.deadline = timestamp;

    return ctx;
}

/// Set the deadline to now + ms in place.
pub fn setTimeout(self: *Self, ms: u64) void {
    self.deadline = fromNow(self.io, ms);
}

/// Whether the deadline has passed. False when no deadline is set.
pub fn isExpired(self: Self) bool {
    return self.timedOut();
}

/// Whether the deadline has passed. False when no deadline is set. The
/// handler must check this explicitly, it does not interrupt anything.
pub fn timedOut(self: Self) bool {
    const deadline = self.deadline orelse return false;

    return std.Io.Clock.Timestamp.now(self.io, .real).compare(.gte, deadline);
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const TEST_FD: std.posix.fd_t = if (builtin.os.tag == .windows)
    std.os.windows.INVALID_HANDLE_VALUE
else
    -1;

fn testContext() Self {
    return Self.init(std.testing.io, std.testing.allocator, TEST_FD, 1);
}

test "zix http2: Context, init keeps fd and stream id" {
    const ctx = Self.init(std.testing.io, std.testing.allocator, TEST_FD, 7);

    try std.testing.expectEqual(TEST_FD, ctx.fd);
    try std.testing.expectEqual(@as(u31, 7), ctx.sid);
}

test "zix http2: Context, defaults to no static dir and a 16 KiB frame" {
    const ctx = testContext();

    try std.testing.expectEqualStrings("", ctx.public_dir);
    try std.testing.expectEqual(@as(u32, 16384), ctx.max_frame_size);
}

test "zix http2: Context, starts without a deadline" {
    const ctx = testContext();

    try std.testing.expect(ctx.deadline == null);
    try std.testing.expect(!ctx.timedOut());
    try std.testing.expect(!ctx.isExpired());
}

test "zix http2: Context, withTimeout zero is expired" {
    const ctx = testContext().withTimeout(0);

    try std.testing.expect(ctx.timedOut());
    try std.testing.expect(ctx.isExpired());
}

test "zix http2: Context, withTimeout in the future is not expired" {
    const ctx = testContext().withTimeout(60_000);

    try std.testing.expect(!ctx.timedOut());
}

test "zix http2: Context, withTimeout leaves the original untouched" {
    const base = testContext();
    _ = base.withTimeout(60_000);

    try std.testing.expect(base.deadline == null);
}

test "zix http2: Context, withDeadline in the past is expired" {
    const past = std.Io.Clock.Timestamp.now(std.testing.io, .real);
    const ctx = testContext().withDeadline(past);

    try std.testing.expect(ctx.timedOut());
}

test "zix http2: Context, setTimeout replaces the deadline" {
    var ctx = testContext();

    ctx.setTimeout(60_000);
    try std.testing.expect(!ctx.timedOut());

    ctx.setTimeout(0);
    try std.testing.expect(ctx.timedOut());
}

