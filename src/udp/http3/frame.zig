//! zix HTTP/3 QUIC frame parsing (RFC 9000 12.4 / 12.5 / 19, Layer Q).
//!
//! What:
//! - Reads frames out of a packet payload and enforces the two framing rules an endpoint MUST apply:
//!   an unknown frame type is a FRAME_ENCODING_ERROR (12.4), and a known frame in a packet type that
//!   does not permit it is a PROTOCOL_VIOLATION (12.5, Table 3).
//! - The frame type MUST use its shortest encoding (12.4), so a non-minimal type varint is rejected.
//!   Proven against crafted frames and the Table 3 permission matrix in the tests below.
//!
//! Note:
//! - parseFrame is live. framePermittedIn (the Table 3 per-space permission matrix) plus Space and
//!   FrameError are implemented and tested but not enforced in the serve path yet (deferred).

const std = @import("std");

const varint = @import("varint.zig");

/// The version-1 packet number spaces, named by the packet type that carries them (RFC 9000 12.5).
pub const Space = enum { initial, handshake, zero_rtt, one_rtt };

/// A parsed frame, the Q2 subset (RFC 9000 19). The rest decode the same way and arrive in later
/// modules (ACK in flow.zig, close frames in close.zig). Connection-id frames are modeled in
/// stream.zig, not yet wired into the serve path (NEW_CONNECTION_ID is skipped for now).
pub const Frame = union(enum) {
    /// A run of PADDING bytes (19.1), coalesced into one length.
    padding: usize,
    /// PING (19.2), no fields.
    ping,
    /// CRYPTO (19.6): an offset and the carried handshake bytes.
    crypto: struct { offset: u64, data: []const u8 },
    /// STREAM (19.8): id, offset, the FIN marker, and the stream bytes.
    stream: struct { id: u64, offset: u64, fin: bool, data: []const u8 },
};

/// One parsed frame plus how many bytes it consumed from the payload.
pub const ParsedFrame = struct { frame: Frame, len: usize };

/// The framing errors an endpoint MUST raise (RFC 9000 12.4 / 12.5).
pub const FrameError = error{
    Truncated,
    /// Unknown frame type, or a malformed known frame (e.g. empty NEW_TOKEN): FRAME_ENCODING_ERROR.
    FrameEncodingError,
    /// A frame type encoded on more bytes than necessary: PROTOCOL_VIOLATION (12.4).
    ProtocolViolation,
};

/// Parse one frame from the front of a payload (RFC 9000 19). The frame type MUST use its shortest
/// encoding, and an unknown type is a FRAME_ENCODING_ERROR.
pub fn parseFrame(data: []const u8) FrameError!ParsedFrame {
    const type_vi = varint.read(data) catch return error.Truncated;
    if (type_vi.len != varint.encodedLen(type_vi.value)) return error.ProtocolViolation;

    const frame_type = type_vi.value;
    var pos = type_vi.len;

    switch (frame_type) {
        0x00 => {
            // PADDING: coalesce the run of zero bytes.
            var run: usize = 0;
            while (pos + run < data.len and data[pos + run] == 0x00) run += 1;

            return .{ .frame = .{ .padding = run + 1 }, .len = pos + run };
        },
        0x01 => return .{ .frame = .ping, .len = pos },
        0x06 => {
            const offset = try readField(data, &pos);
            const length = try readField(data, &pos);
            if (data.len < pos + length) return error.Truncated;

            const body = data[pos .. pos + length];

            return .{ .frame = .{ .crypto = .{ .offset = offset, .data = body } }, .len = pos + length };
        },
        0x07 => {
            // NEW_TOKEN: the token MUST NOT be empty (19.7).
            const length = try readField(data, &pos);
            if (length == 0) return error.FrameEncodingError;
            if (data.len < pos + length) return error.Truncated;

            return .{ .frame = .ping, .len = pos + length };
        },
        0x08...0x0f => {
            const has_offset = frame_type & 0x04 != 0;
            const has_length = frame_type & 0x02 != 0;
            const fin = frame_type & 0x01 != 0;

            const id = try readField(data, &pos);
            const offset = if (has_offset) try readField(data, &pos) else 0;

            const length = if (has_length) try readField(data, &pos) else data.len - pos;
            if (data.len < pos + length) return error.Truncated;

            const body = data[pos .. pos + length];

            return .{ .frame = .{ .stream = .{ .id = id, .offset = offset, .fin = fin, .data = body } }, .len = pos + length };
        },
        else => return error.FrameEncodingError,
    }
}

/// Read one variable-length field, advancing the cursor (helper for parseFrame).
fn readField(data: []const u8, pos: *usize) FrameError!u64 {
    const vi = varint.read(data[pos.*..]) catch return error.Truncated;
    pos.* += vi.len;

    return vi.value;
}

/// Whether a known frame type may appear in a given packet number space (RFC 9000 Table 3, "Pkts").
pub fn framePermittedIn(frame_type: u64, space: Space) bool {
    return switch (frame_type) {
        0x00, 0x01 => true, // PADDING, PING: IH01
        0x02, 0x03 => space != .zero_rtt, // ACK: IH_1
        0x06 => space != .zero_rtt, // CRYPTO: IH_1
        0x07 => space == .one_rtt, // NEW_TOKEN: ___1
        0x1b => space == .one_rtt, // PATH_RESPONSE: ___1
        0x1c => true, // CONNECTION_CLOSE 0x1c: ih01
        0x1d => space == .zero_rtt or space == .one_rtt, // CONNECTION_CLOSE 0x1d: __01
        0x1e => space == .one_rtt, // HANDSHAKE_DONE: ___1
        0x04...0x05, 0x08...0x1a => space == .zero_rtt or space == .one_rtt, // the __01 group
        else => false,
    };
}

// --------------------------------------------------------------- //
// --------------------------------------------------------------- //

fn h(comptime text: []const u8) [text.len / 2]u8 {
    var out: [text.len / 2]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, text) catch unreachable;

    return out;
}

test "zix test: RFC 9000 19 frame parse" {
    const padding = try parseFrame(&h("000000"));
    try std.testing.expect(padding.frame.padding == 3 and padding.len == 3);

    const ping = try parseFrame(&h("01"));
    try std.testing.expect(ping.frame == .ping and ping.len == 1);

    const crypto = try parseFrame(&h("0600040a0b0c0d"));
    try std.testing.expectEqual(@as(u64, 0), crypto.frame.crypto.offset);
    try std.testing.expectEqualSlices(u8, &h("0a0b0c0d"), crypto.frame.crypto.data);

    const stream_min = try parseFrame(&h("0804deadbeef"));
    try std.testing.expectEqual(@as(u64, 4), stream_min.frame.stream.id);
    try std.testing.expectEqual(@as(u64, 0), stream_min.frame.stream.offset);
    try std.testing.expect(!stream_min.frame.stream.fin);
    try std.testing.expectEqualSlices(u8, &h("deadbeef"), stream_min.frame.stream.data);

    const stream_full = try parseFrame(&h("0f04080241420000"));
    try std.testing.expectEqual(@as(u64, 8), stream_full.frame.stream.offset);
    try std.testing.expect(stream_full.frame.stream.fin);
    try std.testing.expectEqualSlices(u8, &h("4142"), stream_full.frame.stream.data);
    try std.testing.expectEqual(@as(usize, 6), stream_full.len);
}

test "zix test: RFC 9000 12.4 frame type rules" {
    try std.testing.expectError(error.FrameEncodingError, parseFrame(&h("20")));
    try std.testing.expectError(error.ProtocolViolation, parseFrame(&h("4001")));
    try std.testing.expectError(error.FrameEncodingError, parseFrame(&h("0700")));
}

test "zix test: RFC 9000 12.5 / Table 3 number-space permission matrix" {
    try std.testing.expect(framePermittedIn(0x00, .initial));
    try std.testing.expect(framePermittedIn(0x01, .initial));

    try std.testing.expect(framePermittedIn(0x02, .initial));
    try std.testing.expect(!framePermittedIn(0x02, .zero_rtt));

    try std.testing.expect(framePermittedIn(0x06, .handshake));
    try std.testing.expect(!framePermittedIn(0x06, .zero_rtt));

    try std.testing.expect(!framePermittedIn(0x08, .initial));
    try std.testing.expect(framePermittedIn(0x08, .one_rtt));

    try std.testing.expect(framePermittedIn(0x07, .one_rtt) and !framePermittedIn(0x07, .initial));
    try std.testing.expect(!framePermittedIn(0x1e, .handshake));
    try std.testing.expect(framePermittedIn(0x1b, .one_rtt) and !framePermittedIn(0x1b, .zero_rtt));
    try std.testing.expect(framePermittedIn(0x1a, .zero_rtt));

    try std.testing.expect(framePermittedIn(0x1c, .initial));
    try std.testing.expect(!framePermittedIn(0x1d, .initial));

    try std.testing.expect(!framePermittedIn(0x10, .initial));
    try std.testing.expect(framePermittedIn(0x10, .one_rtt));
}
