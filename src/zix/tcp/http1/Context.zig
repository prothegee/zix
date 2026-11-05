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
// Fields:

io: std.Io,
fd: std.posix.fd_t,
allocator: std.mem.Allocator,
// logger: ?*Logger = null,
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
        std.Io.Clock.Duration{ .raw = std.Io.Duration.fromMilliseconds(@intCast(ms)), .clock = .real },
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
        std.Io.Clock.Duration{ .raw = std.Io.Duration.fromMilliseconds(@intCast(ms)), .clock = .real },
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

