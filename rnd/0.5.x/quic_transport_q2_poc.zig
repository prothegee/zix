//! QUIC transport PoC, phase Q2 (http3-plan.md): RFC 9000 section 12.4 / 12.5 (frame types and
//! number-space rules) and section 19 (frame formats).
//!
//! Note:
//! - Q1 gave the base codec. Q2 reads frames out of a packet payload and enforces the two framing
//!   rules an endpoint MUST apply: an unknown frame type is a FRAME_ENCODING_ERROR (12.4), and a
//!   known frame in a packet type that does not permit it is a PROTOCOL_VIOLATION (12.5, Table 3).
//! - The deterministic oracle is the RFC text: the Table 3 "Pkts" column fixes which frames may
//!   appear in Initial / Handshake / 0-RTT / 1-RTT, and section 19 fixes each frame's field layout.
//!   STREAM is the interesting parse: the three low type bits (OFF / LEN / FIN) decide which fields
//!   are present. Crafted frames are parsed and re-encoded in process, no live tool needed yet.
//! - This builds on Q1's varint helpers (reproduced here so the PoC stays standalone). The frame
//!   type MUST use its shortest encoding (12.4), so a non-minimal type varint is rejected.
//!
//! Run:    zig run rnd/0.5.x/quic_transport_q2_poc.zig
//! Verify: bash rnd/0.5.x/verify-quic-transport-q2.sh

const std = @import("std");

// --------------------------------------------------------------- //

/// A decoded variable-length integer (RFC 9000 16): the value plus how many bytes it occupied.
const Varint = struct { value: u64, len: usize };

/// Decode a variable-length integer (RFC 9000 16, Appendix A.1).
fn readVarint(data: []const u8) error{Truncated}!Varint {
    if (data.len == 0) return error.Truncated;

    const len: usize = @as(usize, 1) << @intCast(data[0] >> 6);
    if (data.len < len) return error.Truncated;

    var value: u64 = data[0] & 0x3f;
    for (1..len) |i| value = (value << 8) + data[i];

    return .{ .value = value, .len = len };
}

/// The minimal number of bytes a value needs as a variable-length integer (RFC 9000 Table 4).
fn varintLen(value: u64) usize {
    if (value <= 63) return 1;
    if (value <= 16383) return 2;
    if (value <= 1073741823) return 4;

    return 8;
}

/// Encode a value as a variable-length integer on its minimal length (RFC 9000 16). Returns the
/// number of bytes written into `out`.
fn writeVarint(out: []u8, value: u64) usize {
    const len = varintLen(value);
    const prefix: u8 = switch (len) {
        1 => 0x00,
        2 => 0x40,
        4 => 0x80,
        else => 0xc0,
    };

    for (0..len) |i| out[len - 1 - i] = @truncate(value >> @intCast(8 * i));
    out[0] |= prefix;

    return len;
}

// --------------------------------------------------------------- //

/// The version-1 packet number spaces, named by the packet type that carries them (RFC 9000 12.5).
const Space = enum { initial, handshake, zero_rtt, one_rtt };

/// A parsed frame, only the Q2 subset (RFC 9000 19). The rest decode the same way and arrive in
/// later phases (ACK in Q4, the flow-control and connection-id frames in Q3 / Q4).
const Frame = union(enum) {
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
const ParsedFrame = struct { frame: Frame, len: usize };

/// The framing errors an endpoint MUST raise (RFC 9000 12.4 / 12.5).
const FrameError = error{
    Truncated,
    /// Unknown frame type, or a malformed known frame (e.g. empty NEW_TOKEN): FRAME_ENCODING_ERROR.
    FrameEncodingError,
    /// A frame type encoded on more bytes than necessary: PROTOCOL_VIOLATION (12.4).
    ProtocolViolation,
};

/// Parse one frame from the front of a payload (RFC 9000 19). The frame type MUST use its shortest
/// encoding, and an unknown type is a FRAME_ENCODING_ERROR.
fn parseFrame(data: []const u8) FrameError!ParsedFrame {
    const type_vi = readVarint(data) catch return error.Truncated;
    if (type_vi.len != varintLen(type_vi.value)) return error.ProtocolViolation;

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
    const vi = readVarint(data[pos.*..]) catch return error.Truncated;
    pos.* += vi.len;

    return vi.value;
}

/// Whether a known frame type may appear in a given packet number space (RFC 9000 Table 3, "Pkts").
fn framePermittedIn(frame_type: u64, space: Space) bool {
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

/// Decode a hex literal (no separators) into a freshly allocated byte slice.
fn hex(allocator: std.mem.Allocator, comptime text: []const u8) ![]u8 {
    const bytes = try allocator.alloc(u8, text.len / 2);
    _ = try std.fmt.hexToBytes(bytes, text);

    return bytes;
}

/// Report a boolean expectation and flag a failure.
fn expect(failures: *usize, name: []const u8, ok: bool) void {
    if (ok) {
        std.debug.print("  ok    {s}\n", .{name});
    } else {
        std.debug.print("  FAIL  {s}\n", .{name});
        failures.* += 1;
    }
}

/// Report a u64 equality expectation and flag a failure.
fn expectEq(failures: *usize, name: []const u8, actual: u64, expected: u64) void {
    if (actual == expected) {
        std.debug.print("  ok    {s}\n", .{name});
    } else {
        std.debug.print("  FAIL  {s}\n", .{name});
        std.debug.print("        want {d}\n", .{expected});
        std.debug.print("        got  {d}\n", .{actual});
        failures.* += 1;
    }
}

/// Compare a byte slice against the expected hex and flag a failure.
fn expectBytes(failures: *usize, name: []const u8, actual: []const u8, comptime expected_hex: []const u8) void {
    var expected: [expected_hex.len / 2]u8 = undefined;
    _ = std.fmt.hexToBytes(&expected, expected_hex) catch unreachable;

    if (actual.len == expected.len and std.mem.eql(u8, actual, &expected)) {
        std.debug.print("  ok    {s}\n", .{name});
    } else {
        std.debug.print("  FAIL  {s}\n", .{name});
        std.debug.print("        want {s}\n", .{expected_hex});
        std.debug.print("        got  {x}\n", .{actual});
        failures.* += 1;
    }
}

/// Whether parsing the payload raised the given framing error.
fn parseRaises(data: []const u8, want: FrameError) bool {
    if (parseFrame(data)) |_| {
        return false;
    } else |got| {
        return got == want;
    }
}

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var failures: usize = 0;

    std.debug.print("RFC 9000 19: frame parse\n", .{});

    // PADDING: three zero bytes coalesce into one frame of length 3.
    const padding = try parseFrame(try hex(arena, "000000"));
    expect(&failures, "PADDING run -> length 3", padding.frame.padding == 3 and padding.len == 3);

    // PING: a single 0x01 byte.
    const ping = try parseFrame(try hex(arena, "01"));
    expect(&failures, "PING single byte", ping.frame == .ping and ping.len == 1);

    // CRYPTO: type 06, offset 0, length 4, then four data bytes.
    const crypto = try parseFrame(try hex(arena, "0600040a0b0c0d"));
    expect(&failures, "CRYPTO offset = 0", crypto.frame.crypto.offset == 0);
    expectBytes(&failures, "CRYPTO data", crypto.frame.crypto.data, "0a0b0c0d");

    // STREAM 0x08 (no OFF / LEN / FIN): id 4, data runs to the end, offset 0, not final.
    const stream_min = try parseFrame(try hex(arena, "0804deadbeef"));
    expect(&failures, "STREAM 0x08 id = 4", stream_min.frame.stream.id == 4);
    expect(&failures, "STREAM 0x08 offset = 0", stream_min.frame.stream.offset == 0);
    expect(&failures, "STREAM 0x08 not final", !stream_min.frame.stream.fin);
    expectBytes(&failures, "STREAM 0x08 data to end", stream_min.frame.stream.data, "deadbeef");

    // STREAM 0x0f (OFF | LEN | FIN): id 4, offset 8, length 2, final.
    const stream_full = try parseFrame(try hex(arena, "0f04080241420000"));
    expect(&failures, "STREAM 0x0f offset = 8", stream_full.frame.stream.offset == 8);
    expect(&failures, "STREAM 0x0f is final", stream_full.frame.stream.fin);
    expectBytes(&failures, "STREAM 0x0f data (length 2)", stream_full.frame.stream.data, "4142");
    expectEq(&failures, "STREAM 0x0f consumed 6", stream_full.len, 6);

    std.debug.print("RFC 9000 12.4: frame type rules\n", .{});

    // An unknown frame type is a FRAME_ENCODING_ERROR.
    expect(&failures, "unknown type 0x20 -> FRAME_ENCODING_ERROR", parseRaises(try hex(arena, "20"), error.FrameEncodingError));

    // A frame type that is not on its shortest encoding (0x4001 for PING) is a PROTOCOL_VIOLATION.
    expect(&failures, "non-minimal type 0x4001 -> PROTOCOL_VIOLATION", parseRaises(try hex(arena, "4001"), error.ProtocolViolation));

    // NEW_TOKEN with an empty token is a FRAME_ENCODING_ERROR (19.7).
    expect(&failures, "NEW_TOKEN empty token -> FRAME_ENCODING_ERROR", parseRaises(try hex(arena, "0700"), error.FrameEncodingError));

    std.debug.print("RFC 9000 12.5 / Table 3: number-space permission matrix\n", .{});

    // PADDING / PING appear in every space.
    expect(&failures, "PADDING permitted in Initial", framePermittedIn(0x00, .initial));
    expect(&failures, "PING permitted in Initial", framePermittedIn(0x01, .initial));

    // ACK is IH_1: permitted in Initial, never in 0-RTT.
    expect(&failures, "ACK permitted in Initial", framePermittedIn(0x02, .initial));
    expect(&failures, "ACK not permitted in 0-RTT", !framePermittedIn(0x02, .zero_rtt));

    // CRYPTO is IH_1: permitted in Handshake, never in 0-RTT.
    expect(&failures, "CRYPTO permitted in Handshake", framePermittedIn(0x06, .handshake));
    expect(&failures, "CRYPTO not permitted in 0-RTT", !framePermittedIn(0x06, .zero_rtt));

    // STREAM is __01: a PROTOCOL_VIOLATION in Initial, fine in 1-RTT.
    expect(&failures, "STREAM not permitted in Initial", !framePermittedIn(0x08, .initial));
    expect(&failures, "STREAM permitted in 1-RTT", framePermittedIn(0x08, .one_rtt));

    // NEW_TOKEN, HANDSHAKE_DONE, PATH_RESPONSE are ___1: 1-RTT only.
    expect(&failures, "NEW_TOKEN only in 1-RTT", framePermittedIn(0x07, .one_rtt) and !framePermittedIn(0x07, .initial));
    expect(&failures, "HANDSHAKE_DONE not in Handshake", !framePermittedIn(0x1e, .handshake));
    expect(&failures, "PATH_RESPONSE only in 1-RTT", framePermittedIn(0x1b, .one_rtt) and !framePermittedIn(0x1b, .zero_rtt));

    // PATH_CHALLENGE is __01: permitted in 0-RTT.
    expect(&failures, "PATH_CHALLENGE permitted in 0-RTT", framePermittedIn(0x1a, .zero_rtt));

    // CONNECTION_CLOSE: 0x1c is ih01 (allowed in Initial), 0x1d is __01 (not in Initial).
    expect(&failures, "CONNECTION_CLOSE 0x1c permitted in Initial", framePermittedIn(0x1c, .initial));
    expect(&failures, "CONNECTION_CLOSE 0x1d not in Initial", !framePermittedIn(0x1d, .initial));

    // MAX_DATA is __01: not in Initial, fine in 1-RTT.
    expect(&failures, "MAX_DATA not in Initial", !framePermittedIn(0x10, .initial));
    expect(&failures, "MAX_DATA permitted in 1-RTT", framePermittedIn(0x10, .one_rtt));

    std.debug.print("\n", .{});
    if (failures == 0) {
        std.debug.print("PASS: all RFC 9000 Q2 frame rules hold\n", .{});
    } else {
        std.debug.print("FAIL: {d} check(s) failed\n", .{failures});
        std.process.exit(1);
    }
}
