//! QUIC transport PoC, phase Q4 (http3-plan.md): RFC 9000 section 4 (flow control), section 19.3
//! (ACK frames + ranges) and section 19.17 / 19.18 (PATH_CHALLENGE / PATH_RESPONSE).
//!
//! Note:
//! - Q3 gave the stream and connection-id state. Q4 adds the three control mechanisms that keep a
//!   connection live and bounded: flow control (the receiver-advertised byte limits, per stream and
//!   per connection), acknowledgement (the ACK frame and its relative range encoding), and path
//!   validation (the PATH_CHALLENGE / PATH_RESPONSE echo).
//! - The oracle is the RFC text: section 4.1 fixes the FLOW_CONTROL_ERROR rule and the
//!   only-increasing MAX_DATA / MAX_STREAM_DATA semantics, section 19.3.1 fixes the ACK range
//!   arithmetic (smallest = largest - range, next largest = previous smallest - gap - 2, a negative
//!   result is FRAME_ENCODING_ERROR), and 19.17 / 19.18 fix the 8-byte challenge echo.
//! - Crafted frames and byte counts are exercised in process. This builds on Q1's varint helpers
//!   (reproduced so the PoC stays standalone).
//!
//! Run:    zig run rnd/0.5.x/quic_transport_q4_poc.zig
//! Verify: bash rnd/0.5.x/verify-quic-transport-q4.sh

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

// --------------------------------------------------------------- //

/// A receiver-advertised byte limit, per stream or per connection (RFC 9000 4.1). The sender MUST
/// NOT push data past the limit, and an advertised limit only ever increases.
const FlowLimit = struct {
    limit: u64,
    used: u64 = 0,

    /// Account data arriving up to absolute offset `end` (RFC 9000 4.1). Exceeding the limit is a
    /// FLOW_CONTROL_ERROR.
    fn consume(self: *FlowLimit, end: u64) error{FlowControlError}!void {
        if (end > self.limit) return error.FlowControlError;
        if (end > self.used) self.used = end;
    }

    /// Apply a MAX_DATA / MAX_STREAM_DATA advertisement (RFC 9000 4.1): a smaller limit has no
    /// effect, the sender MUST ignore any value that does not increase the limit.
    fn advertise(self: *FlowLimit, new_limit: u64) void {
        if (new_limit > self.limit) self.limit = new_limit;
    }
};

// --------------------------------------------------------------- //

/// A contiguous acknowledged packet-number range, inclusive (RFC 9000 19.3.1).
const Range = struct { smallest: u64, largest: u64 };

/// A parsed ACK frame (RFC 9000 19.3). The acknowledged ranges are resolved from the relative
/// encoding, the delay is decoded with the peer's ack_delay_exponent, and ECN counts are present
/// only for the 0x03 type.
const Ack = struct {
    largest: u64,
    delay_us: u64,
    ranges: [16]Range,
    range_len: usize,
    ecn: ?[3]u64,
};

/// The ACK errors an endpoint MUST raise (RFC 9000 19.3.1).
const AckError = error{
    Truncated,
    /// A computed packet number went negative, or too many ranges for the buffer: FRAME_ENCODING_ERROR.
    FrameEncodingError,
};

/// Parse an ACK frame including its type byte (RFC 9000 19.3), resolving the relative range
/// encoding into absolute inclusive ranges. `ack_delay_exponent` is the peer's transport parameter.
fn parseAck(data: []const u8, ack_delay_exponent: u6) AckError!Ack {
    var pos: usize = 0;

    const ack_type = try field(data, &pos);
    const largest = try field(data, &pos);
    const delay = try field(data, &pos);
    const range_count = try field(data, &pos);
    const first_ack_range = try field(data, &pos);

    var ack: Ack = .{ .largest = largest, .delay_us = delay << ack_delay_exponent, .ranges = undefined, .range_len = 0, .ecn = null };

    // First ACK Range: the smallest acknowledged below Largest. A negative result is malformed.
    if (first_ack_range > largest) return error.FrameEncodingError;

    var cur_smallest = largest - first_ack_range;
    ack.ranges[0] = .{ .smallest = cur_smallest, .largest = largest };
    ack.range_len = 1;

    // Subsequent ranges step down: next largest = previous smallest - gap - 2.
    for (0..range_count) |_| {
        const gap = try field(data, &pos);
        const range_len = try field(data, &pos);

        if (cur_smallest < gap + 2) return error.FrameEncodingError;

        const next_largest = cur_smallest - gap - 2;
        if (range_len > next_largest) return error.FrameEncodingError;

        const next_smallest = next_largest - range_len;
        if (ack.range_len >= ack.ranges.len) return error.FrameEncodingError;

        ack.ranges[ack.range_len] = .{ .smallest = next_smallest, .largest = next_largest };
        ack.range_len += 1;
        cur_smallest = next_smallest;
    }

    // ECN counts follow only for the 0x03 type.
    if (ack_type == 0x03) {
        const ect0 = try field(data, &pos);
        const ect1 = try field(data, &pos);
        const ce = try field(data, &pos);
        ack.ecn = .{ ect0, ect1, ce };
    }

    return ack;
}

/// Read one variable-length field, advancing the cursor (helper for parseAck).
fn field(data: []const u8, pos: *usize) AckError!u64 {
    const vi = readVarint(data[pos.*..]) catch return error.Truncated;
    pos.* += vi.len;

    return vi.value;
}

// --------------------------------------------------------------- //

/// Parse a PATH_CHALLENGE (0x1a) or PATH_RESPONSE (0x1b) frame and return its 8-byte data field
/// (RFC 9000 19.17 / 19.18).
fn parsePathData(data: []const u8) error{ Truncated, WrongType }![8]u8 {
    if (data.len < 9) return error.Truncated;
    if (data[0] != 0x1a and data[0] != 0x1b) return error.WrongType;

    return data[1..9].*;
}

/// A path is validated when a PATH_RESPONSE echoes the data of a previously sent PATH_CHALLENGE
/// (RFC 9000 8.2.3 / 19.18). A mismatch is grounds for a PROTOCOL_VIOLATION.
fn pathValidates(sent_challenge: [8]u8, received_response: [8]u8) bool {
    return std.mem.eql(u8, &sent_challenge, &received_response);
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

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var failures: usize = 0;

    std.debug.print("RFC 9000 4.1: stream + connection flow control\n", .{});

    // Stream flow control: data within the limit is fine, past it is a FLOW_CONTROL_ERROR.
    var stream_flow = FlowLimit{ .limit = 100 };
    try stream_flow.consume(80);
    expect(&failures, "stream data within limit ok", stream_flow.used == 80);
    expect(&failures, "stream data past limit -> FLOW_CONTROL_ERROR", stream_flow.consume(120) == error.FlowControlError);

    // MAX_STREAM_DATA raises the limit; a non-increasing advertisement is ignored.
    stream_flow.advertise(200);
    try stream_flow.consume(150);
    expect(&failures, "raised limit admits more data", stream_flow.used == 150);

    stream_flow.advertise(50);
    expect(&failures, "non-increasing MAX_STREAM_DATA ignored", stream_flow.limit == 200);

    // Connection flow control is the same mechanism over the sum across all streams.
    var conn_flow = FlowLimit{ .limit = 1000 };
    try conn_flow.consume(1000);
    expect(&failures, "connection data at limit ok", conn_flow.used == 1000);
    expect(&failures, "connection data past limit -> FLOW_CONTROL_ERROR", conn_flow.consume(1001) == error.FlowControlError);

    conn_flow.advertise(2000);
    try conn_flow.consume(1500);
    expect(&failures, "MAX_DATA raises connection limit", conn_flow.used == 1500);

    std.debug.print("RFC 9000 19.3: ACK frame parse + range arithmetic\n", .{});

    // Single range: type 0x02, largest 10, delay 0, range count 0, first ack range 3 -> acks 7..10.
    const ack_single = try parseAck(try hex(arena, "020a000003"), 0);
    expect(&failures, "single range largest = 10", ack_single.largest == 10);
    expect(&failures, "single range acks 7..10", ack_single.range_len == 1 and ack_single.ranges[0].smallest == 7 and ack_single.ranges[0].largest == 10);

    // Two ranges: first acks 8..10, then gap 3 + range 1 -> next largest 8-3-2=3, acks 2..3.
    const ack_multi = try parseAck(try hex(arena, "020a00010203" ++ "01"), 0);
    expect(&failures, "multi range count = 2", ack_multi.range_len == 2);
    expect(&failures, "multi range first acks 8..10", ack_multi.ranges[0].smallest == 8 and ack_multi.ranges[0].largest == 10);
    expect(&failures, "multi range second acks 2..3", ack_multi.ranges[1].smallest == 2 and ack_multi.ranges[1].largest == 3);

    // ECN ACK (type 0x03): the three counts follow the ranges.
    const ack_ecn = try parseAck(try hex(arena, "030a000003" ++ "010203"), 0);
    expect(&failures, "ECN ACK carries counts 1/2/3", ack_ecn.ecn != null and ack_ecn.ecn.?[0] == 1 and ack_ecn.ecn.?[1] == 2 and ack_ecn.ecn.?[2] == 3);

    // ACK delay is decoded by shifting left by the ack_delay_exponent: 100 << 3 = 800 us.
    const ack_delay = try parseAck(try hex(arena, "020a" ++ "4064" ++ "0000"), 3);
    expect(&failures, "ack delay 100 with exponent 3 = 800us", ack_delay.delay_us == 800);

    // A first ack range larger than Largest computes a negative packet number: FRAME_ENCODING_ERROR.
    const ack_bad = try hex(arena, "0202000005");
    expect(&failures, "negative range -> FRAME_ENCODING_ERROR", parseAck(ack_bad, 0) == error.FrameEncodingError);

    std.debug.print("RFC 9000 19.17 / 19.18: path validation\n", .{});

    // A PATH_CHALLENGE carries 8 bytes; the PATH_RESPONSE MUST echo them.
    const challenge = try parsePathData(try hex(arena, "1a0102030405060708"));
    expect(&failures, "PATH_CHALLENGE data parsed", challenge[0] == 0x01 and challenge[7] == 0x08);

    const response = try parsePathData(try hex(arena, "1b0102030405060708"));
    expect(&failures, "matching PATH_RESPONSE validates path", pathValidates(challenge, response));

    const wrong = try parsePathData(try hex(arena, "1b01020304050607ff"));
    expect(&failures, "mismatched PATH_RESPONSE fails validation", !pathValidates(challenge, wrong));

    // The wrong type byte is rejected by the parser.
    expect(&failures, "non-path type rejected", parsePathData(try hex(arena, "0c0102030405060708")) == error.WrongType);

    std.debug.print("\n", .{});
    if (failures == 0) {
        std.debug.print("PASS: all RFC 9000 Q4 flow / ACK / path rules hold\n", .{});
    } else {
        std.debug.print("FAIL: {d} check(s) failed\n", .{failures});
        std.process.exit(1);
    }
}
