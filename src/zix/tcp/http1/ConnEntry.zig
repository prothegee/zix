//! ZIX Http1 ConnEntry
//!
//! ### file: src/zix/tcp/http1/ConnEntry.zig
//! 
//! ### author: Prana Ron
//! 
//! ---------------------------------------------------------
//! 
//! ### brief:
//! 
//! One live connection tracked by the timeout registry.
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

fd: std.posix.fd_t,
done: std.atomic.Value(bool) = .init(false),
deadline: std.Io.Clock.Timestamp,

const Self = @This();

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "zix http1: ConnEntry, starts not done" {
    const entry: @This() = .{
        .fd = 3,
        .deadline = std.Io.Clock.Timestamp.now(std.testing.io, .real),
    };

    try std.testing.expect(!entry.done.load(.acquire));
}

test "zix http1: ConnEntry, done is one way" {
    var entry: @This() = .{
        .fd = 4,
        .deadline = std.Io.Clock.Timestamp.now(std.testing.io, .real),
    };

    entry.done.store(true, .release);

    try std.testing.expect(entry.done.load(.acquire));
}

