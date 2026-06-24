//! QPACK PoC, phase P3 (http3-plan.md): RFC 9204 section 4.4 (decoder instructions) and section 6
//! (QPACK error codes).
//!
//! Note:
//! - P1 / P2 built the tables. P3 is the feedback channel: the decoder stream instructions that tell
//!   the encoder what the decoder has processed, so both ends keep a consistent view of the dynamic
//!   table. Three instructions, told apart by their leading bits: Section Acknowledgment ('1', 7-bit
//!   stream id), Stream Cancellation ('01', 6-bit stream id), and Insert Count Increment ('00', 6-bit
//!   increment).
//! - The oracle is the RFC text: 4.4 fixes each instruction's bit pattern and prefix width, and an
//!   Insert Count Increment of zero is a QPACK_DECODER_STREAM_ERROR (4.4.3). Section 6 fixes the
//!   three QPACK error code values (0x0200 / 0x0201 / 0x0202). Instructions are encoded and decoded
//!   in process, building on the P1 prefixed-integer codec (reproduced so the PoC stays standalone).
//!
//! Run:    zig run rnd/0.5.x/qpack_p3_poc.zig
//! Verify: bash rnd/0.5.x/verify-qpack-p3.sh

const std = @import("std");

// --------------------------------------------------------------- //

/// A decoded prefixed integer (RFC 7541 5.1): the value plus how many bytes it occupied.
const IntResult = struct { value: u64, len: usize };

/// Decode an N-bit prefixed integer (RFC 7541 5.1, reused by QPACK 4.1.1).
fn decodePrefixedInt(data: []const u8, prefix_bits: u4) error{Truncated}!IntResult {
    if (data.len == 0) return error.Truncated;

    const max: u64 = (@as(u64, 1) << prefix_bits) - 1;
    var value: u64 = data[0] & @as(u8, @intCast(max));
    if (value < max) return .{ .value = value, .len = 1 };

    var len: usize = 1;
    var shift: u6 = 0;
    while (true) {
        if (len >= data.len) return error.Truncated;

        const byte = data[len];
        len += 1;
        value += @as(u64, byte & 0x7f) << shift;
        shift += 7;
        if (byte & 0x80 == 0) break;
    }

    return .{ .value = value, .len = len };
}

/// Encode an N-bit prefixed integer (RFC 7541 5.1). `high_bits` are the bits above the prefix in the
/// first byte. Returns bytes written.
fn encodePrefixedInt(out: []u8, prefix_bits: u4, high_bits: u8, value: u64) usize {
    const max: u64 = (@as(u64, 1) << prefix_bits) - 1;
    if (value < max) {
        out[0] = high_bits | @as(u8, @intCast(value));
        return 1;
    }

    out[0] = high_bits | @as(u8, @intCast(max));
    var remaining = value - max;
    var i: usize = 1;
    while (remaining >= 128) {
        out[i] = @as(u8, @intCast(remaining % 128)) + 128;
        remaining /= 128;
        i += 1;
    }
    out[i] = @intCast(remaining);

    return i + 1;
}

// --------------------------------------------------------------- //

/// A decoder-stream instruction (RFC 9204 4.4). The payload is a stream id or an increment.
const DecoderInstruction = union(enum) {
    /// Section Acknowledgment (4.4.1): the acknowledged field section's stream id.
    section_ack: u64,
    /// Stream Cancellation (4.4.2): the reset / abandoned stream id.
    stream_cancel: u64,
    /// Insert Count Increment (4.4.3): how much to advance the Known Received Count.
    insert_count_increment: u64,
};

/// The decoder-instruction errors an encoder raises (RFC 9204 4.4.3).
const InstructionError = error{
    Truncated,
    /// An Insert Count Increment of zero: QPACK_DECODER_STREAM_ERROR.
    DecoderStreamError,
};

/// Encode a Section Acknowledgment (RFC 9204 4.4.1): '1' then a 7-bit prefix stream id.
fn encodeSectionAck(out: []u8, stream_id: u64) usize {
    return encodePrefixedInt(out, 7, 0x80, stream_id);
}

/// Encode a Stream Cancellation (RFC 9204 4.4.2): '01' then a 6-bit prefix stream id.
fn encodeStreamCancel(out: []u8, stream_id: u64) usize {
    return encodePrefixedInt(out, 6, 0x40, stream_id);
}

/// Encode an Insert Count Increment (RFC 9204 4.4.3): '00' then a 6-bit prefix increment.
fn encodeInsertCountIncrement(out: []u8, increment: u64) usize {
    return encodePrefixedInt(out, 6, 0x00, increment);
}

/// Decode one decoder-stream instruction (RFC 9204 4.4), told apart by the leading bits. An Insert
/// Count Increment of zero is a QPACK_DECODER_STREAM_ERROR.
fn decodeDecoderInstruction(data: []const u8) InstructionError!DecoderInstruction {
    if (data.len == 0) return error.Truncated;

    const first = data[0];
    if (first & 0x80 != 0) {
        const int = decodePrefixedInt(data, 7) catch return error.Truncated;
        return .{ .section_ack = int.value };
    }
    if (first & 0x40 != 0) {
        const int = decodePrefixedInt(data, 6) catch return error.Truncated;
        return .{ .stream_cancel = int.value };
    }

    const int = decodePrefixedInt(data, 6) catch return error.Truncated;
    if (int.value == 0) return error.DecoderStreamError;

    return .{ .insert_count_increment = int.value };
}

// --------------------------------------------------------------- //

/// The QPACK error codes in the HTTP/3 Error Codes registry (RFC 9204 section 6).
const QpackError = enum(u16) {
    decompression_failed = 0x0200,
    encoder_stream_error = 0x0201,
    decoder_stream_error = 0x0202,
};

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

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var failures: usize = 0;
    var buf: [16]u8 = undefined;

    std.debug.print("RFC 9204 4.4: decoder instruction encode\n", .{});

    // Section Acknowledgment: '1' + 7-bit stream id. Stream 4 fits the prefix -> 0x84.
    expectBytes(&failures, "Section Ack stream 4 = 0x84", buf[0..encodeSectionAck(&buf, 4)], "84");

    // Stream 200 overflows the 7-bit prefix (127): 0xff then 200-127=73 -> 0x49.
    expectBytes(&failures, "Section Ack stream 200 = ff 49", buf[0..encodeSectionAck(&buf, 200)], "ff49");

    // Stream Cancellation: '01' + 6-bit stream id. Stream 8 -> 0x48.
    expectBytes(&failures, "Stream Cancellation stream 8 = 0x48", buf[0..encodeStreamCancel(&buf, 8)], "48");

    // Insert Count Increment: '00' + 6-bit increment. Increment 10 -> 0x0a.
    expectBytes(&failures, "Insert Count Increment 10 = 0x0a", buf[0..encodeInsertCountIncrement(&buf, 10)], "0a");

    std.debug.print("RFC 9204 4.4: decoder instruction decode + discrimination\n", .{});

    // Leading bits route each byte to the right instruction.
    const ack = try decodeDecoderInstruction(try hex(arena, "84"));
    expect(&failures, "0x84 -> Section Ack stream 4", ack == .section_ack and ack.section_ack == 4);

    const ack_big = try decodeDecoderInstruction(try hex(arena, "ff49"));
    expect(&failures, "ff49 -> Section Ack stream 200", ack_big == .section_ack and ack_big.section_ack == 200);

    const cancel = try decodeDecoderInstruction(try hex(arena, "48"));
    expect(&failures, "0x48 -> Stream Cancellation stream 8", cancel == .stream_cancel and cancel.stream_cancel == 8);

    const increment = try decodeDecoderInstruction(try hex(arena, "0a"));
    expect(&failures, "0x0a -> Insert Count Increment 10", increment == .insert_count_increment and increment.insert_count_increment == 10);

    // An Insert Count Increment of zero is invalid.
    expect(&failures, "Insert Count Increment 0 -> QPACK_DECODER_STREAM_ERROR", decodeDecoderInstruction(try hex(arena, "00")) == error.DecoderStreamError);

    std.debug.print("RFC 9204 section 6: QPACK error codes\n", .{});

    expect(&failures, "QPACK_DECOMPRESSION_FAILED = 0x0200", @intFromEnum(QpackError.decompression_failed) == 0x0200);
    expect(&failures, "QPACK_ENCODER_STREAM_ERROR = 0x0201", @intFromEnum(QpackError.encoder_stream_error) == 0x0201);
    expect(&failures, "QPACK_DECODER_STREAM_ERROR = 0x0202", @intFromEnum(QpackError.decoder_stream_error) == 0x0202);

    std.debug.print("\n", .{});
    if (failures == 0) {
        std.debug.print("PASS: all RFC 9204 P3 decoder-instruction + error-code checks hold\n", .{});
    } else {
        std.debug.print("FAIL: {d} check(s) failed\n", .{failures});
        std.process.exit(1);
    }
}
