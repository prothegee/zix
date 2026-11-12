//! TLZ dtls handshake
//!
//! ### file: src/tlz/src/dtls/handshake.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! DTLS 1.2 handshake message framing (RFC 6347 4.2.2 and 4.2.3): the 12-byte
//! header codec, plus the fragment walker, the fragmenter, and the reassembler.
//!
//! ### note:
//!
//! Fragments may OVERLAP and handling that is required (RFC 6347 4.2.3). A sender
//! that lowers its fragment size after a PMTU change resends the same bytes cut
//! differently. An unfragmented message is the degenerate case: fragment_offset 0
//! and fragment_length equal to length.
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
// Public:

pub const MessageType = @import("handshake/message_type.zig").MessageType;
pub const Header = @import("handshake/Header.zig");
pub const Fragment = @import("handshake/Fragment.zig");
pub const FragmentIterator = @import("handshake/FragmentIterator.zig");
pub const Fragmenter = @import("handshake/Fragmenter.zig");
pub const Reassembler = @import("handshake/reassembler.zig").Reassembler;

pub const Error = error{
    Tlz_DtlsHandshake_Truncated,
};

/// Bytes before the fragment body: type 1, length 3, message_seq 2,
/// fragment_offset 3, fragment_length 3.
pub const HEADER_LEN: usize = 12;

/// Ceiling on any single handshake message, from the 24-bit length field.
pub const MAX_MESSAGE_LEN: usize = (1 << 24) - 1;

/// Read a handshake message header. Does not touch the body.
///
/// Param:
/// bytes - []const u8 (start of a handshake message, header first)
///
/// Return:
/// - Header
/// - Error.Tlz_DtlsHandshake_Truncated when fewer than HEADER_LEN bytes are present
pub fn parseHeader(bytes: []const u8) Error!Header {
    if (bytes.len < HEADER_LEN) return Error.Tlz_DtlsHandshake_Truncated;

    return .{
        .msg_type = @enumFromInt(bytes[0]),
        .length = std.mem.readInt(u24, bytes[1..4], .big),
        .message_seq = std.mem.readInt(u16, bytes[4..6], .big),
        .fragment_offset = std.mem.readInt(u24, bytes[6..9], .big),
        .fragment_length = std.mem.readInt(u24, bytes[9..12], .big),
    };
}

/// Write a handshake message header into the first HEADER_LEN bytes of `out`.
///
/// Param:
/// out - []u8 (at least HEADER_LEN bytes)
/// header - Header (the fields to write)
///
/// Return:
/// - void
pub fn writeHeader(out: []u8, header: Header) void {
    out[0] = @intFromEnum(header.msg_type);
    std.mem.writeInt(u24, out[1..4], header.length, .big);
    std.mem.writeInt(u16, out[4..6], header.message_seq, .big);
    std.mem.writeInt(u24, out[6..9], header.fragment_offset, .big);
    std.mem.writeInt(u24, out[9..12], header.fragment_length, .big);
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "tlz dtls: handshake, header is 12 bytes in wire order" {
    var buf: [HEADER_LEN]u8 = undefined;
    const expected = [_]u8{
        1,    0x00, 0x00, 0xC8, 0x00, 0x01,
        0x00, 0x00, 0x64, 0x00, 0x00, 0x32,
    };

    writeHeader(&buf, .{
        .msg_type = .CLIENT_HELLO,
        .length = 200,
        .message_seq = 1,
        .fragment_offset = 100,
        .fragment_length = 50,
    });

    try std.testing.expectEqualSlices(u8, &expected, &buf);
}

test "tlz dtls: handshake, parseHeader reads what writeHeader wrote" {
    var buf: [HEADER_LEN]u8 = undefined;

    writeHeader(&buf, .{
        .msg_type = .CLIENT_HELLO,
        .length = 200,
        .message_seq = 1,
        .fragment_offset = 100,
        .fragment_length = 50,
    });
    const header = try parseHeader(&buf);

    try std.testing.expectEqual(MessageType.CLIENT_HELLO, header.msg_type);
    try std.testing.expectEqual(@as(u24, 200), header.length);
    try std.testing.expectEqual(@as(u16, 1), header.message_seq);
    try std.testing.expectEqual(@as(u24, 100), header.fragment_offset);
    try std.testing.expectEqual(@as(u24, 50), header.fragment_length);
}

test "tlz dtls: handshake, HELLO_VERIFY_REQUEST survives the round trip" {
    var buf: [HEADER_LEN]u8 = undefined;

    writeHeader(&buf, .{
        .msg_type = .HELLO_VERIFY_REQUEST,
        .length = 35,
        .message_seq = 0,
        .fragment_offset = 0,
        .fragment_length = 35,
    });
    const header = try parseHeader(&buf);

    try std.testing.expectEqual(MessageType.HELLO_VERIFY_REQUEST, header.msg_type);
    try std.testing.expect(header.isWholeMessage());
}

test "tlz dtls: handshake, parseHeader on a stub is truncated" {
    try std.testing.expectError(
        Error.Tlz_DtlsHandshake_Truncated,
        parseHeader(&[_]u8{ 1, 0, 0 }),
    );
}

test "tlz dtls: handshake, MAX_MESSAGE_LEN is the 24-bit ceiling" {
    try std.testing.expectEqual(@as(usize, 0xFFFFFF), MAX_MESSAGE_LEN);
}

