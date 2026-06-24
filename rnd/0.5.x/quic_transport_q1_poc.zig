//! QUIC transport PoC, phase Q1 (http3-plan.md): RFC 9000 section 16 (variable-length integers),
//! 17.1 (packet number encoding) and 17.2 / 17.3 (long / short header parse).
//!
//! Note:
//! - Layer C proved the crypto. Layer Q builds the wire format on top, and Q1 is the base codec:
//!   the variable-length integer that every QUIC length / id / offset uses, the truncated packet
//!   number, and the header parse that splits a datagram into its fields. Everything above (frames,
//!   streams, flow control) reads through these.
//! - The deterministic oracle here is RFC 9000 Appendix A. A.1 publishes four varint decodings (and
//!   a non-minimal fifth), A.2 publishes two packet-number encoding-length examples, and A.3
//!   publishes a packet-number decode. The header cases are crafted from the section 17 field
//!   diagrams, checking the version-1 invariants: Fixed Bit MUST be 1 (else discard), and a long
//!   header connection ID length MUST NOT exceed 20 (else drop the packet).
//! - No std type is needed beyond integer helpers, this layer is pure wire format.
//!
//! Run:    zig run rnd/0.5.x/quic_transport_q1_poc.zig
//! Verify: bash rnd/0.5.x/verify-quic-transport-q1.sh

const std = @import("std");

// --------------------------------------------------------------- //

/// A decoded variable-length integer (RFC 9000 16): the value plus how many bytes it occupied.
const Varint = struct { value: u64, len: usize };

/// Decode a variable-length integer (RFC 9000 16, Appendix A.1). The top two bits of the first byte
/// give the base-2 log of the length (1 / 2 / 4 / 8 bytes), the rest is the value in network order.
fn readVarint(data: []const u8) error{Truncated}!Varint {
    if (data.len == 0) return error.Truncated;

    const prefix = data[0] >> 6;
    const len: usize = @as(usize, 1) << @intCast(prefix);

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

/// Select the packet-number encoding length in bytes (RFC 9000 17.1, Appendix A.2): the sender MUST
/// use a size able to represent more than twice the range of unacknowledged packet numbers.
fn packetNumberLength(full_pn: u64, largest_acked: ?u64) usize {
    const num_unacked = if (largest_acked) |acked| full_pn - acked else full_pn + 1;

    var bytes: usize = 1;
    while (bytes < 4) : (bytes += 1) {
        const range = @as(u128, 1) << @intCast(8 * bytes);
        if (range > 2 * @as(u128, num_unacked)) break;
    }

    return bytes;
}

/// Recover the full packet number from the truncated wire value (RFC 9000 17.1, Appendix A.3):
/// pick the candidate closest to the next expected packet number.
fn decodePacketNumber(largest_pn: u64, truncated_pn: u64, pn_nbits: u6) u64 {
    const expected_pn = largest_pn + 1;
    const pn_win: u64 = @as(u64, 1) << pn_nbits;
    const pn_hwin = pn_win / 2;
    const pn_mask = pn_win - 1;

    const candidate_pn = (expected_pn & ~pn_mask) | truncated_pn;
    if (candidate_pn <= expected_pn - pn_hwin and candidate_pn < (@as(u64, 1) << 62) - pn_win) {
        return candidate_pn + pn_win;
    }
    if (candidate_pn > expected_pn + pn_hwin and candidate_pn >= pn_win) {
        return candidate_pn - pn_win;
    }

    return candidate_pn;
}

// --------------------------------------------------------------- //

/// A version-1 long header packet split into its fields (RFC 9000 17.2).
const LongHeader = struct {
    packet_type: u2,
    version: u32,
    dcid: []const u8,
    scid: []const u8,
    rest: []const u8,
};

/// The errors a version-1 header parse can raise (RFC 9000 17.2 / 17.3 invariants).
const ParseError = error{
    Truncated,
    /// Header Form bit says this is not the expected header shape.
    WrongHeaderForm,
    /// Fixed Bit is 0: not a valid version-1 packet, MUST be discarded.
    FixedBitZero,
    /// A connection ID length exceeds the 20-byte version-1 maximum, MUST drop the packet.
    ConnectionIdTooLong,
};

/// Parse a version-1 long header (RFC 9000 17.2). Validates Header Form, Fixed Bit, and the 20-byte
/// connection ID ceiling.
fn parseLongHeader(data: []const u8) ParseError!LongHeader {
    if (data.len < 6) return error.Truncated;

    const first = data[0];
    if (first & 0x80 == 0) return error.WrongHeaderForm;
    if (first & 0x40 == 0) return error.FixedBitZero;

    const version = std.mem.readInt(u32, data[1..5], .big);

    var pos: usize = 5;
    const dcid_len = data[pos];
    if (dcid_len > 20) return error.ConnectionIdTooLong;
    pos += 1;
    if (data.len < pos + dcid_len) return error.Truncated;
    const dcid = data[pos .. pos + dcid_len];
    pos += dcid_len;

    if (data.len < pos + 1) return error.Truncated;
    const scid_len = data[pos];
    if (scid_len > 20) return error.ConnectionIdTooLong;
    pos += 1;
    if (data.len < pos + scid_len) return error.Truncated;
    const scid = data[pos .. pos + scid_len];
    pos += scid_len;

    return .{
        .packet_type = @intCast((first & 0x30) >> 4),
        .version = version,
        .dcid = dcid,
        .scid = scid,
        .rest = data[pos..],
    };
}

/// A version-1 short header (1-RTT) packet split into its fields (RFC 9000 17.3). The Destination
/// Connection ID length is not on the wire, the receiver knows the length it issued.
const ShortHeader = struct {
    spin_bit: bool,
    key_phase: bool,
    pn_length: usize,
    dcid: []const u8,
    rest: []const u8,
};

/// Parse a version-1 short header (RFC 9000 17.3) given the locally issued connection ID length.
/// Validates Header Form and Fixed Bit.
fn parseShortHeader(data: []const u8, dcid_len: usize) ParseError!ShortHeader {
    if (data.len < 1 + dcid_len) return error.Truncated;

    const first = data[0];
    if (first & 0x80 != 0) return error.WrongHeaderForm;
    if (first & 0x40 == 0) return error.FixedBitZero;

    return .{
        .spin_bit = first & 0x20 != 0,
        .key_phase = first & 0x04 != 0,
        .pn_length = @as(usize, first & 0x03) + 1,
        .dcid = data[1 .. 1 + dcid_len],
        .rest = data[1 + dcid_len ..],
    };
}

// --------------------------------------------------------------- //

/// Decode a hex literal (no separators) into a freshly allocated byte slice.
fn hex(allocator: std.mem.Allocator, comptime text: []const u8) ![]u8 {
    const bytes = try allocator.alloc(u8, text.len / 2);
    _ = try std.fmt.hexToBytes(bytes, text);

    return bytes;
}

/// Report a u64 equality expectation against the RFC's value and flag a failure.
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

/// Report a boolean expectation and flag a failure.
fn expect(failures: *usize, name: []const u8, ok: bool) void {
    if (ok) {
        std.debug.print("  ok    {s}\n", .{name});
    } else {
        std.debug.print("  FAIL  {s}\n", .{name});
        failures.* += 1;
    }
}

/// Compare a byte slice against the RFC's expected hex and flag a failure.
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

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var failures: usize = 0;

    std.debug.print("RFC 9000 Appendix A.1: variable-length integer decode\n", .{});

    // The four worked decodings plus the non-minimal two-byte form of 37.
    const v8 = try readVarint(try hex(arena, "c2197c5eff14e88c"));
    expectEq(&failures, "8-byte 0xc2197c5eff14e88c", v8.value, 151288809941952652);
    expectEq(&failures, "8-byte length", v8.len, 8);

    const v4 = try readVarint(try hex(arena, "9d7f3e7d"));
    expectEq(&failures, "4-byte 0x9d7f3e7d", v4.value, 494878333);

    const v2 = try readVarint(try hex(arena, "7bbd"));
    expectEq(&failures, "2-byte 0x7bbd", v2.value, 15293);

    const v1 = try readVarint(try hex(arena, "25"));
    expectEq(&failures, "1-byte 0x25", v1.value, 37);

    const v1b = try readVarint(try hex(arena, "4025"));
    expectEq(&failures, "non-minimal 2-byte 0x4025", v1b.value, 37);
    expectEq(&failures, "non-minimal length is 2", v1b.len, 2);

    std.debug.print("RFC 9000 16: variable-length integer encode (minimal) + round trip\n", .{});

    // Encoding picks the minimal length; the round trip reproduces the A.1 bytes.
    var buf: [8]u8 = undefined;
    expectBytes(&failures, "encode 37", buf[0..writeVarint(&buf, 37)], "25");
    expectBytes(&failures, "encode 15293", buf[0..writeVarint(&buf, 15293)], "7bbd");
    expectBytes(&failures, "encode 494878333", buf[0..writeVarint(&buf, 494878333)], "9d7f3e7d");
    expectBytes(&failures, "encode 151288809941952652", buf[0..writeVarint(&buf, 151288809941952652)], "c2197c5eff14e88c");

    // Table 4 length boundaries: 63 / 64, 16383 / 16384, 2^30-1 / 2^30.
    expectEq(&failures, "len(63) = 1", varintLen(63), 1);
    expectEq(&failures, "len(64) = 2", varintLen(64), 2);
    expectEq(&failures, "len(16383) = 2", varintLen(16383), 2);
    expectEq(&failures, "len(16384) = 4", varintLen(16384), 4);
    expectEq(&failures, "len(1073741823) = 4", varintLen(1073741823), 4);
    expectEq(&failures, "len(1073741824) = 8", varintLen(1073741824), 8);

    std.debug.print("RFC 9000 Appendix A.2 / A.3: packet number encode length + decode\n", .{});

    // A.2: largest_acked 0xabe8b3, sending 0xac5c02 needs 2 bytes; sending 0xace8fe needs 3.
    expectEq(&failures, "pn length 0xac5c02 -> 2", packetNumberLength(0xac5c02, 0xabe8b3), 2);
    expectEq(&failures, "pn length 0xace8fe -> 3", packetNumberLength(0xace8fe, 0xabe8b3), 3);

    // A.3: largest_pn 0xa82f30ea, 16-bit truncated 0x9b32 decodes to 0xa82f9b32.
    expectEq(&failures, "pn decode 0x9b32 -> 0xa82f9b32", decodePacketNumber(0xa82f30ea, 0x9b32, 16), 0xa82f9b32);

    std.debug.print("RFC 9000 17.2: long header parse + invariants\n", .{});

    // A crafted Initial long header: first byte 0xc3 (long form, fixed bit, type 0, pn len bits),
    // version 1, DCID 8 bytes, SCID 4 bytes, then one payload byte.
    const long = try hex(arena, "c300000001088394c8f03e515708041122334400");
    const header = try parseLongHeader(long);
    expectEq(&failures, "long type = 0 (Initial)", header.packet_type, 0);
    expectEq(&failures, "long version = 1", header.version, 1);
    expectBytes(&failures, "long DCID", header.dcid, "8394c8f03e515708");
    expectBytes(&failures, "long SCID", header.scid, "11223344");
    expectBytes(&failures, "long payload tail", header.rest, "00");

    // Fixed Bit zero MUST be discarded; a 21-byte DCID length MUST drop the packet.
    const fixed_zero = try hex(arena, "830000000100");
    expect(&failures, "fixed bit zero -> rejected", parseLongHeader(fixed_zero) == error.FixedBitZero);

    const big_cid = try hex(arena, "c30000000115");
    expect(&failures, "DCID length 21 -> rejected", parseLongHeader(big_cid) == error.ConnectionIdTooLong);

    std.debug.print("RFC 9000 17.3: short header parse + invariants\n", .{});

    // A crafted 1-RTT short header: first byte 0x43 (short form, fixed bit, spin 0, key phase 0,
    // pn len 4), 8-byte DCID known by the receiver, then payload.
    const short = try hex(arena, "43cafebabe11223344aabbcc");
    const sh = try parseShortHeader(short, 8);
    expect(&failures, "short spin bit clear", !sh.spin_bit);
    expect(&failures, "short key phase clear", !sh.key_phase);
    expectEq(&failures, "short pn length = 4", sh.pn_length, 4);
    expectBytes(&failures, "short DCID", sh.dcid, "cafebabe11223344");
    expectBytes(&failures, "short payload tail", sh.rest, "aabbcc");

    // Short header with Fixed Bit zero MUST be discarded.
    const short_fixed_zero = try hex(arena, "03cafebabe11223344");
    expect(&failures, "short fixed bit zero -> rejected", parseShortHeader(short_fixed_zero, 8) == error.FixedBitZero);

    std.debug.print("\n", .{});
    if (failures == 0) {
        std.debug.print("PASS: all RFC 9000 Q1 vectors + invariants hold\n", .{});
    } else {
        std.debug.print("FAIL: {d} check(s) failed\n", .{failures});
        std.process.exit(1);
    }
}
