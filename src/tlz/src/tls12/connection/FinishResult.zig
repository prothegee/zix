//! TLZ tls12 connection FinishResult
//!
//! ### file: src/tlz/src/tls12/connection/FinishResult.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! What `serverFinish` produces: ChangeCipherSpec plus the encrypted server Finished
//! to send, and the established Connection.
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
const Connection = @import("Connection.zig");

// --------------------------------------------------------- //
// Fields:

/// ChangeCipherSpec record, then the encrypted server Finished record. A view into
/// the caller's buffer.
to_send: []const u8,
/// The established connection.
connection: Connection,

const Self = @This();

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "tlz tls12 connection: FinishResult, connection starts after the Finished" {
    const result: Self = .{
        .to_send = &.{},
        .connection = .{
            .km = undefined,
        },
    };

    try std.testing.expectEqual(@as(u64, 1), result.connection.server_seq);
    try std.testing.expectEqual(@as(u64, 1), result.connection.client_seq);
}

test "tlz tls12 connection: FinishResult, keeps the bytes to send" {
    const result: Self = .{
        .to_send = "ccs",
        .connection = .{
            .km = undefined,
        },
    };

    try std.testing.expectEqualStrings("ccs", result.to_send);
}

