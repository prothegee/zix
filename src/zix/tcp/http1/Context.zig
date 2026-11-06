//! ZIX Http1 Context
//!
//! ### file: src/zix/tcp/http1/Context.zig
//! 
//! ### author: Prana Ron
//! 
//! ---------------------------------------------------------
//! 
//! ### brief:
//! 
//! Handler context: worker io, allocator, connection fd, and deadline.
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
const Logger = @import("../../logger/Logger.zig");

// --------------------------------------------------------- //
// Fields:

io: std.Io,
fd: std.posix.fd_t,
allocator: std.mem.Allocator,
logger: ?*Logger = null,
deadline: ?std.Io.Clock.Timestamp = null,

const Self = @This();

// --------------------------------------------------------- //
// Public:

/// Build a context over an io, allocator, and fd.
///
/// Param:
/// io - std.Io (async lane: a yielding backend, sync path: the worker io)
/// allocator - std.mem.Allocator (per-request scratch)
/// fd - std.posix.fd_t (the connection)
///
/// Return:
/// - Context
pub fn init(io: std.Io, allocator: std.mem.Allocator, fd: std.posix.fd_t) Self {
    return .{ .io = io, .allocator = allocator, .fd = fd };
}

/// Return a copy with the deadline set to now + ms.
pub fn withTimeout(self: Self, ms: u64) Self {
    var ctx = self;
    ctx.deadline = std.Io.Clock.Timestamp.fromNow(
        self.io,
        std.Io.Clock.Duration{
            .raw = std.Io.Duration.fromMilliseconds(@intCast(ms)),
            .clock = .real,
        },
    );

    return ctx;
}

/// Return a copy with an explicit deadline timestamp.
pub fn withDeadline(self: Self, ts: std.Io.Clock.Timestamp) Self {
    var ctx = self;
    ctx.deadline = ts;

    return ctx;
}

/// Set the deadline to now + ms in place.
pub fn setTimeout(self: *Self, ms: u64) void {
    self.deadline = std.Io.Clock.Timestamp.fromNow(
        self.io,
        std.Io.Clock.Duration{
            .raw = std.Io.Duration.fromMilliseconds(@intCast(ms)),
            .clock = .real,
        },
    );
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

test "zix http1: Context, starts without a deadline" {
    const ctx = Self.init(std.testing.io, std.testing.allocator, -1);

    try std.testing.expect(!ctx.timedOut());
    try std.testing.expect(!ctx.isExpired());
    try std.testing.expectEqual(@as(?*Logger, null), ctx.logger);
}

test "zix http1: Context, deadline edges" {
    const io = std.testing.io;

    const expired = Self.init(io, std.testing.allocator, -1).withTimeout(0);
    try std.testing.expect(expired.timedOut());

    const fresh = Self.init(io, std.testing.allocator, -1).withTimeout(60_000);
    try std.testing.expect(!fresh.timedOut());
}

test "zix http1: Context, setTimeout replaces the deadline" {
    var ctx = Self.init(std.testing.io, std.testing.allocator, -1);

    ctx.setTimeout(60_000);
    try std.testing.expect(!ctx.timedOut());

    ctx.setTimeout(0);
    try std.testing.expect(ctx.timedOut());
}

