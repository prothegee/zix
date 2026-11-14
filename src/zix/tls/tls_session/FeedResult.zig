//! ZIX tls session feed result
//!
//! ### file: src/zix/tls/tls_session/FeedResult.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! What one feed hands back: bytes to send, decrypted plaintext, and the outcome.
//!
//! ### note:
//!
//! Both slices point into the buffers the caller passed to feed, so they live
//! only as long as those buffers.
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
const Outcome = @import("outcome.zig").Outcome;

// --------------------------------------------------------- //
// Fields:

/// Handshake flight or alert bytes to write.
to_send: []const u8 = "",
/// Decrypted application plaintext.
plaintext: []const u8 = "",
/// What the caller does next.
outcome: Outcome = .OK,

const Self = @This();

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "zix tls: FeedResult, defaults are empty and OK" {
    const result: Self = .{};

    try std.testing.expectEqual(@as(usize, 0), result.to_send.len);
    try std.testing.expectEqual(@as(usize, 0), result.plaintext.len);
    try std.testing.expectEqual(Outcome.OK, result.outcome);
}

test "zix tls: FeedResult, keeps a close outcome" {
    const result: Self = .{
        .to_send = "alert",
        .outcome = .CLOSE,
    };

    try std.testing.expectEqualStrings("alert", result.to_send);
    try std.testing.expectEqual(Outcome.CLOSE, result.outcome);
}

