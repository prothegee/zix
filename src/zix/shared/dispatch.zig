//! ZIX share dispatch
//!
//! ### file: src/zix/shared/dispatch_model.zig
//! 
//! ### author: Prana Ron
//! 
//! ---------------------------------------------------------
//! 
//! ### brief:
//! 
//! Dispatch model enum shared by every engine.
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
//! - (c) Prana Ron // @prothegee // prothegeee@pm.me
//! 
//! ### contributors:
//! 
//! - Prana Ron // @prothegee // prothegeee@pm.me
//!

const std = @import("std");

// --------------------------------------------------------- //
// Public:

/// Shared dispatch model
pub const Model = enum(u8) {
    ASYNC = 0,
    EPOLL = 1,
    URING = 2,
    IOCP = 3,
    KQUEUE = 4,
};

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "zix: dispatch model, values are stable" {
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(Model.ASYNC));
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(Model.EPOLL));
    try std.testing.expectEqual(@as(u8, 2), @intFromEnum(Model.URING));
    try std.testing.expectEqual(@as(u8, 3), @intFromEnum(Model.IOCP));
    try std.testing.expectEqual(@as(u8, 4), @intFromEnum(Model.KQUEUE));
}

test "zix: dispatch model, tag names match the enum" {
    try std.testing.expectEqualStrings("ASYNC", @tagName(Model.ASYNC));
    try std.testing.expectEqualStrings("KQUEUE", @tagName(Model.KQUEUE));
}

