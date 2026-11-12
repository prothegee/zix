//! TLZ dtls handshake Header
//!
//! ### file: src/tlz/src/dtls/handshake/Header.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! One DTLS handshake message header (RFC 6347 4.2.2): the 4-byte TLS header plus
//! message_seq, fragment_offset, and fragment_length.
//!
//! ### note:
//!
//! `length` is the length of the WHOLE message in every fragment, never the
//! fragment's own. The fragment's size is `fragment_length`.
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
const MessageType = @import("message_type.zig").MessageType;

// --------------------------------------------------------- //
// Fields:

msg_type: MessageType,
/// Length of the whole message, the same in every fragment of it.
length: u24,
/// Message counter, shared by every fragment and reused on retransmission.
message_seq: u16,
/// Where this fragment starts inside the message.
fragment_offset: u24,
/// How many bytes of the message this fragment carries.
fragment_length: u24,

const Self = @This();

// --------------------------------------------------------- //
// Public:

/// Whether this header carries the entire message rather than a piece of it.
///
/// Return:
/// - bool
pub fn isWholeMessage(self: Self) bool {
    return self.fragment_offset == 0 and self.fragment_length == self.length;
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "tlz dtls handshake: Header, offset 0 with the full length is whole" {
    const header: Self = .{
        .msg_type = .SERVER_HELLO_DONE,
        .length = 0,
        .message_seq = 3,
        .fragment_offset = 0,
        .fragment_length = 0,
    };

    try std.testing.expect(header.isWholeMessage());
}

test "tlz dtls handshake: Header, a later offset is a fragment" {
    const header: Self = .{
        .msg_type = .CERTIFICATE,
        .length = 200,
        .message_seq = 2,
        .fragment_offset = 100,
        .fragment_length = 100,
    };

    try std.testing.expect(!header.isWholeMessage());
}

test "tlz dtls handshake: Header, a short first piece is a fragment" {
    const header: Self = .{
        .msg_type = .CERTIFICATE,
        .length = 200,
        .message_seq = 2,
        .fragment_offset = 0,
        .fragment_length = 50,
    };

    try std.testing.expect(!header.isWholeMessage());
}

