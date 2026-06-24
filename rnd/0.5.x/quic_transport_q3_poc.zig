//! QUIC transport PoC, phase Q3 (http3-plan.md): RFC 9000 section 2.1 (stream identifiers),
//! section 3 (stream state machines), and section 5.1.1 / 19.15 (connection ID management).
//!
//! Note:
//! - Q1 / Q2 handled bytes and frames. Q3 is the first stateful layer: the stream id namespace, the
//!   send / receive state machines a stream walks through, and the connection-id pool with its
//!   active_connection_id_limit. These are the rules that decide whether an arriving frame is legal
//!   for the stream it names.
//! - The oracle is the RFC text: Table 1 fixes the four stream types from the two low id bits, the
//!   Figure 2 / Figure 3 diagrams fix the state transitions, and 19.15 / 5.1.1 fix the
//!   NEW_CONNECTION_ID validation (length 1..20, Retire Prior To <= Sequence Number) and the
//!   CONNECTION_ID_LIMIT_ERROR when the active count exceeds the advertised limit.
//! - State machines here are modeled as transition functions: a null result is an event that is not
//!   legal in that state, which is how the PoC proves the terminal and invalid edges. This builds on
//!   Q1's varint helpers (reproduced so the PoC stays standalone).
//!
//! Run:    zig run rnd/0.5.x/quic_transport_q3_poc.zig
//! Verify: bash rnd/0.5.x/verify-quic-transport-q3.sh

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

/// The four stream types from the two low bits of a stream id (RFC 9000 2.1, Table 1).
const StreamType = enum { client_bidi, server_bidi, client_uni, server_uni };

/// Classify a stream id (RFC 9000 2.1): bit 0x01 is the initiator, bit 0x02 the directionality.
fn streamType(id: u64) StreamType {
    return switch (id & 0x03) {
        0x00 => .client_bidi,
        0x01 => .server_bidi,
        0x02 => .client_uni,
        0x03 => .server_uni,
        else => unreachable,
    };
}

/// Whether the stream was initiated by the client (RFC 9000 2.1): the low bit is 0.
fn clientInitiated(id: u64) bool {
    return id & 0x01 == 0;
}

/// Whether the stream is unidirectional (RFC 9000 2.1): the second bit is 1.
fn unidirectional(id: u64) bool {
    return id & 0x02 != 0;
}

// --------------------------------------------------------------- //

/// The sending part state machine (RFC 9000 3.1, Figure 2).
const SendState = enum { ready, send, data_sent, data_recvd, reset_sent, reset_recvd };

/// Events that drive the sending part (RFC 9000 3.1).
const SendEvent = enum { send_stream, send_fin, recv_all_acks, send_reset, recv_reset_ack };

/// Apply a sending-part event (RFC 9000 3.1, Figure 2). A null result means the event is not legal
/// in that state, including the terminal "Data Recvd" / "Reset Recvd" states.
fn sendTransition(state: SendState, event: SendEvent) ?SendState {
    return switch (state) {
        .ready => switch (event) {
            .send_stream => .send,
            .send_reset => .reset_sent,
            else => null,
        },
        .send => switch (event) {
            .send_fin => .data_sent,
            .send_reset => .reset_sent,
            else => null,
        },
        .data_sent => switch (event) {
            .recv_all_acks => .data_recvd,
            .send_reset => .reset_sent,
            else => null,
        },
        .reset_sent => switch (event) {
            .recv_reset_ack => .reset_recvd,
            else => null,
        },
        .data_recvd, .reset_recvd => null,
    };
}

/// The receiving part state machine (RFC 9000 3.2, Figure 3).
const RecvState = enum { recv, size_known, data_recvd, data_read, reset_recvd, reset_read };

/// Events that drive the receiving part (RFC 9000 3.2).
const RecvEvent = enum { recv_stream, recv_fin, recv_all_data, app_read_all, recv_reset, app_read_reset };

/// Apply a receiving-part event (RFC 9000 3.2, Figure 3). A null result means the event is not legal
/// in that state, including the terminal "Data Read" / "Reset Read" states.
fn recvTransition(state: RecvState, event: RecvEvent) ?RecvState {
    return switch (state) {
        .recv => switch (event) {
            .recv_stream => .recv,
            .recv_fin => .size_known,
            .recv_reset => .reset_recvd,
            else => null,
        },
        .size_known => switch (event) {
            .recv_all_data => .data_recvd,
            .recv_reset => .reset_recvd,
            else => null,
        },
        .data_recvd => switch (event) {
            .app_read_all => .data_read,
            .recv_reset => .reset_recvd,
            else => null,
        },
        .reset_recvd => switch (event) {
            .app_read_reset => .reset_read,
            else => null,
        },
        .data_read, .reset_read => null,
    };
}

// --------------------------------------------------------------- //

/// The connection-id errors an endpoint MUST raise (RFC 9000 19.15 / 5.1.1).
const ConnIdError = error{
    Truncated,
    /// Connection ID length out of 1..20, or Retire Prior To > Sequence Number: FRAME_ENCODING_ERROR.
    FrameEncodingError,
    /// The active connection ID count exceeds active_connection_id_limit: CONNECTION_ID_LIMIT_ERROR.
    ConnectionIdLimitError,
};

/// The validated fields of a NEW_CONNECTION_ID frame (RFC 9000 19.15).
const NewConnId = struct { seq: u64, retire_prior_to: u64, length: u8 };

/// Parse and field-validate a NEW_CONNECTION_ID frame body, i.e. the bytes after the 0x18 type
/// (RFC 9000 19.15). The connection ID length MUST be 1..20, and Retire Prior To MUST be <= Sequence
/// Number, both FRAME_ENCODING_ERROR otherwise.
fn parseNewConnectionId(body: []const u8) ConnIdError!NewConnId {
    var pos: usize = 0;

    const seq_vi = readVarint(body[pos..]) catch return error.Truncated;
    pos += seq_vi.len;

    const retire_vi = readVarint(body[pos..]) catch return error.Truncated;
    pos += retire_vi.len;

    if (retire_vi.value > seq_vi.value) return error.FrameEncodingError;
    if (pos >= body.len) return error.Truncated;

    const length = body[pos];
    if (length < 1 or length > 20) return error.FrameEncodingError;

    return .{ .seq = seq_vi.value, .retire_prior_to = retire_vi.value, .length = length };
}

/// The pool of connection IDs a peer has issued to us (RFC 9000 5.1.1). Issuance is sequential, so
/// the active count is (highest sequence + 1) minus the retire floor.
const ConnIdPool = struct {
    limit: u64,
    highest_seq: u64 = 0,
    retire_floor: u64 = 0,

    /// The number of connection IDs not yet retired (RFC 9000 5.1.1).
    fn active(self: ConnIdPool) u64 {
        return self.highest_seq + 1 - self.retire_floor;
    }

    /// Account a validated NEW_CONNECTION_ID frame. Retire Prior To only advances (a non-increasing
    /// value is ignored, 19.15), and exceeding the limit is a CONNECTION_ID_LIMIT_ERROR.
    fn onNewConnectionId(self: *ConnIdPool, frame: NewConnId) ConnIdError!void {
        if (frame.seq > self.highest_seq) self.highest_seq = frame.seq;
        if (frame.retire_prior_to > self.retire_floor) self.retire_floor = frame.retire_prior_to;

        if (self.active() > self.limit) return error.ConnectionIdLimitError;
    }
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

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var failures: usize = 0;

    std.debug.print("RFC 9000 2.1 / Table 1: stream id classification\n", .{});

    expect(&failures, "stream 0 = client bidi", streamType(0) == .client_bidi);
    expect(&failures, "stream 1 = server bidi", streamType(1) == .server_bidi);
    expect(&failures, "stream 2 = client uni", streamType(2) == .client_uni);
    expect(&failures, "stream 3 = server uni", streamType(3) == .server_uni);

    // The maximum 62-bit id (2^62-1) has both low bits set: server-initiated, unidirectional.
    const max_id: u64 = (@as(u64, 1) << 62) - 1;
    expect(&failures, "max id (2^62-1) = server uni", streamType(max_id) == .server_uni);
    expect(&failures, "client-initiated even id", clientInitiated(4) and !clientInitiated(5));
    expect(&failures, "unidirectional second bit", unidirectional(2) and !unidirectional(0));

    // Stream ids ride on the wire as varints: id 4 is the one-byte 0x04.
    const id_vi = try readVarint(try hex(arena, "04"));
    expect(&failures, "stream id 4 decodes from varint", id_vi.value == 4);

    std.debug.print("RFC 9000 3.1 / Figure 2: sending stream states\n", .{});

    expect(&failures, "Ready --send STREAM--> Send", sendTransition(.ready, .send_stream) == .send);
    expect(&failures, "Send --send FIN--> Data Sent", sendTransition(.send, .send_fin) == .data_sent);
    expect(&failures, "Data Sent --recv all ACKs--> Data Recvd", sendTransition(.data_sent, .recv_all_acks) == .data_recvd);
    expect(&failures, "Ready --send RESET--> Reset Sent", sendTransition(.ready, .send_reset) == .reset_sent);
    expect(&failures, "Reset Sent --recv ACK--> Reset Recvd", sendTransition(.reset_sent, .recv_reset_ack) == .reset_recvd);
    expect(&failures, "Data Recvd is terminal", sendTransition(.data_recvd, .send_reset) == null);
    expect(&failures, "Ready --recv all ACKs--> illegal", sendTransition(.ready, .recv_all_acks) == null);

    std.debug.print("RFC 9000 3.2 / Figure 3: receiving stream states\n", .{});

    expect(&failures, "Recv --recv FIN--> Size Known", recvTransition(.recv, .recv_fin) == .size_known);
    expect(&failures, "Size Known --recv all data--> Data Recvd", recvTransition(.size_known, .recv_all_data) == .data_recvd);
    expect(&failures, "Data Recvd --app read all--> Data Read", recvTransition(.data_recvd, .app_read_all) == .data_read);
    expect(&failures, "Recv --recv RESET--> Reset Recvd", recvTransition(.recv, .recv_reset) == .reset_recvd);
    expect(&failures, "Reset Recvd --app read reset--> Reset Read", recvTransition(.reset_recvd, .app_read_reset) == .reset_read);
    expect(&failures, "Data Read is terminal", recvTransition(.data_read, .recv_stream) == null);
    expect(&failures, "Size Known --app read all--> illegal", recvTransition(.size_known, .app_read_all) == null);

    std.debug.print("RFC 9000 19.15 / 5.1.1: NEW_CONNECTION_ID validation + limit\n", .{});

    // A well-formed NCI body: seq 1, retire prior to 0, length 8, then 8-byte cid + 16-byte token.
    const nci_ok = try parseNewConnectionId(try hex(arena, "010008" ++ "f067a5502a4262b5" ++ "0102030405060708090a0b0c0d0e0f10"));
    expect(&failures, "valid NCI parses (seq 1, length 8)", nci_ok.seq == 1 and nci_ok.length == 8);

    // Length 0 and length 21 are FRAME_ENCODING_ERROR.
    const nci_len0 = try hex(arena, "010000");
    expect(&failures, "NCI length 0 -> FRAME_ENCODING_ERROR", parseNewConnectionId(nci_len0) == error.FrameEncodingError);

    const nci_len21 = try hex(arena, "010015");
    expect(&failures, "NCI length 21 -> FRAME_ENCODING_ERROR", parseNewConnectionId(nci_len21) == error.FrameEncodingError);

    // Retire Prior To greater than Sequence Number is FRAME_ENCODING_ERROR.
    const nci_retire = try hex(arena, "010208");
    expect(&failures, "NCI retire > seq -> FRAME_ENCODING_ERROR", parseNewConnectionId(nci_retire) == error.FrameEncodingError);

    // active_connection_id_limit accounting: the limit is 2, the handshake id (seq 0) is active.
    var pool = ConnIdPool{ .limit = 2 };
    try pool.onNewConnectionId(.{ .seq = 1, .retire_prior_to = 0, .length = 8 });
    expect(&failures, "two active ids within limit 2", pool.active() == 2);

    // A third active id (seq 2) without retirement exceeds the limit.
    expect(&failures, "third active id -> CONNECTION_ID_LIMIT_ERROR", pool.onNewConnectionId(.{ .seq = 2, .retire_prior_to = 0, .length = 8 }) == error.ConnectionIdLimitError);

    // Retiring prior ids brings the active count back within the limit.
    var pool2 = ConnIdPool{ .limit = 2 };
    try pool2.onNewConnectionId(.{ .seq = 1, .retire_prior_to = 0, .length = 8 });
    try pool2.onNewConnectionId(.{ .seq = 2, .retire_prior_to = 1, .length = 8 });
    expect(&failures, "retire prior to 1 keeps active within limit", pool2.active() == 2);

    // A re-received frame with a lower Retire Prior To is ignored (the floor does not move back).
    try pool2.onNewConnectionId(.{ .seq = 2, .retire_prior_to = 0, .length = 8 });
    expect(&failures, "non-increasing retire ignored (floor stays 1)", pool2.retire_floor == 1);

    std.debug.print("\n", .{});
    if (failures == 0) {
        std.debug.print("PASS: all RFC 9000 Q3 stream + connection-id rules hold\n", .{});
    } else {
        std.debug.print("FAIL: {d} check(s) failed\n", .{failures});
        std.process.exit(1);
    }
}
