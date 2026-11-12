//! TLZ record Opened
//!
//! ### file: src/tlz/src/record/Opened.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! The inner of a deprotected TLS 1.3 record: the true content type and the data.
//!
//! ### note:
//!
//! `data` points into the caller's output buffer. It stays valid only while that
//! buffer is not reused.
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
const ContentType = @import("content_type.zig").ContentType;

// --------------------------------------------------------- //
// Fields:

/// The true content type, read from inside the AEAD.
inner_type: ContentType,
/// The record payload with padding and inner type stripped.
data: []const u8,

const Self = @This();

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "tlz record: Opened, keeps the inner type and data" {
    const payload = "hello";
    const opened: Self = .{
        .inner_type = .HANDSHAKE,
        .data = payload,
    };

    try std.testing.expectEqual(ContentType.HANDSHAKE, opened.inner_type);
    try std.testing.expectEqualStrings(payload, opened.data);
}

test "tlz record: Opened, empty data is allowed" {
    const opened: Self = .{
        .inner_type = .APPLICATION_DATA,
        .data = &.{},
    };

    try std.testing.expectEqual(@as(usize, 0), opened.data.len);
}

