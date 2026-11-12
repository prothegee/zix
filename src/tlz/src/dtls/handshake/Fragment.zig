//! TLZ dtls handshake Fragment
//!
//! ### file: src/tlz/src/dtls/handshake/Fragment.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! A DTLS handshake header together with the fragment bytes it describes.
//!
//! ### note:
//!
//! `data` borrows the record body it was read from, it is not copied.
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

test "tlz dtls handshake: Fragment, data length matches fragment_length" {
    const fragment: Self = .{
        .header = .{
            .msg_type = .FINISHED,
            .length = 12,
            .message_seq = 5,
            .fragment_offset = 0,
            .fragment_length = 12,
        },
        .data = "verify_data!",
    };

    try std.testing.expectEqual(@as(usize, fragment.header.fragment_length), fragment.data.len);
}

