//! TLZ dtls record Opened
//!
//! ### file: src/tlz/src/dtls/record/Opened.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! A DTLS record opened out of a datagram: its header and its plaintext.
//!
//! ### note:
//!
//! `data` borrows the caller's output buffer, it is not copied.
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
const Header = @import("Header.zig");

// --------------------------------------------------------- //
// Fields:

header: Header,
data: []const u8,

const Self = @This();

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "tlz dtls record: Opened, carries the header next to the data" {
    const opened: Self = .{
        .header = .{
            .content_type = .APPLICATION_DATA,
            .version = 0xFEFD,
            .epoch = 1,
            .sequence_number = 7,
            .length = 4,
        },
        .data = "ping",
    };

    try std.testing.expectEqual(@as(u48, 7), opened.header.sequence_number);
    try std.testing.expectEqualStrings("ping", opened.data);
}

