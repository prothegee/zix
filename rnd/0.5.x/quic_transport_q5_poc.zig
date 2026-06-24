//! QUIC transport PoC, phase Q5 (http3-plan.md): RFC 9000 section 19.19 (CONNECTION_CLOSE),
//! section 10.2 (closing / draining), section 10.3 (stateless reset), and section 8.1 (the 3x
//! anti-amplification limit + the 1200-byte Initial floor).
//!
//! Note:
//! - Q5 closes Layer Q with how a connection ends and how it is protected from abuse before the
//!   peer address is validated. Four rules: CONNECTION_CLOSE field layout differs between the QUIC
//!   (0x1c) and application (0x1d) variants, the closing / draining states bound what may still be
//!   sent, a datagram ending in a known stateless reset token drops the connection into draining,
//!   and a server MUST NOT amplify (3x) or accept short (1200) Initials before validation.
//! - The oracle is the RFC text: 19.19 fixes the field layout (only 0x1c carries a Frame Type),
//!   10.2 fixes the state transitions, 10.3 fixes the trailing-16-byte detection and the size
//!   limits, and 8.1 fixes the 3x send cap and the 1200-byte client Initial floor.
//! - Crafted frames, byte counts, and datagrams are exercised in process. This builds on Q1's
//!   varint helper (reproduced so the PoC stays standalone).
//!
//! Run:    zig run rnd/0.5.x/quic_transport_q5_poc.zig
//! Verify: bash rnd/0.5.x/verify-quic-transport-q5.sh

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

/// A parsed CONNECTION_CLOSE frame (RFC 9000 19.19). The QUIC variant (0x1c) carries a Frame Type
/// field, the application variant (0x1d) does not.
const ConnClose = struct {
    is_application: bool,
    error_code: u64,
    frame_type: u64,
    reason: []const u8,
};

/// Parse a CONNECTION_CLOSE frame including its type byte (RFC 9000 19.19). Only the 0x1c variant
/// has the Frame Type field.
fn parseConnectionClose(data: []const u8) error{ Truncated, ProtocolViolation }!ConnClose {
    var pos: usize = 0;

    const type_vi = readVarint(data) catch return error.Truncated;
    pos += type_vi.len;
    if (type_vi.value != 0x1c and type_vi.value != 0x1d) return error.ProtocolViolation;

    const is_application = type_vi.value == 0x1d;

    const error_code = readField(data, &pos) catch return error.Truncated;

    var frame_type: u64 = 0;
    if (!is_application) frame_type = readField(data, &pos) catch return error.Truncated;

    const reason_len = readField(data, &pos) catch return error.Truncated;
    if (data.len < pos + reason_len) return error.Truncated;

    return .{ .is_application = is_application, .error_code = error_code, .frame_type = frame_type, .reason = data[pos .. pos + reason_len] };
}

/// Read one variable-length field, advancing the cursor (helper for parseConnectionClose).
fn readField(data: []const u8, pos: *usize) error{Truncated}!u64 {
    const vi = try readVarint(data[pos.*..]);
    pos.* += vi.len;

    return vi.value;
}

// --------------------------------------------------------------- //

/// The connection-termination states (RFC 9000 10.2): an endpoint that sends CONNECTION_CLOSE
/// enters closing, one that receives it enters draining, and both end in the terminal closed state.
const CloseState = enum { open, closing, draining, closed };

/// Events that drive connection termination (RFC 9000 10.2).
const CloseEvent = enum { send_close, recv_close, timeout };

/// Apply a termination event (RFC 9000 10.2.1 / 10.2.2). A null result means the event is not legal
/// in that state.
fn closeTransition(state: CloseState, event: CloseEvent) ?CloseState {
    return switch (state) {
        .open => switch (event) {
            .send_close => .closing,
            .recv_close => .draining,
            else => null,
        },
        .closing => switch (event) {
            .recv_close => .draining,
            .timeout => .closed,
            else => null,
        },
        .draining => switch (event) {
            .timeout => .closed,
            else => null,
        },
        .closed => null,
    };
}

/// Whether an endpoint may still send packets in a termination state (RFC 9000 10.2.2): the
/// draining state sends nothing.
fn maySendInState(state: CloseState) bool {
    return state == .open or state == .closing;
}

// --------------------------------------------------------------- //

/// Detect a Stateless Reset by the trailing 16 bytes of the datagram (RFC 9000 10.3.1). A short
/// header packet smaller than 21 bytes is never a valid QUIC packet, so it cannot be a reset.
fn isStatelessReset(datagram: []const u8, token: [16]u8) bool {
    if (datagram.len < 21) return false;

    return std.mem.eql(u8, datagram[datagram.len - 16 ..], &token);
}

/// Whether a Stateless Reset of `reset_len` bytes is allowed in response to a `received_len`-byte
/// packet (RFC 9000 10.3): it MUST NOT be three times or more larger, to avoid amplification.
fn resetSizeAllowed(received_len: usize, reset_len: usize) bool {
    return reset_len < 3 * received_len;
}

// --------------------------------------------------------------- //

/// The server-side anti-amplification budget before the client address is validated (RFC 9000 8.1):
/// the server MUST NOT send more than three times the bytes it has received.
const AntiAmplification = struct {
    received: u64 = 0,
    sent: u64 = 0,
    validated: bool = false,

    /// Count payload bytes received on the connection (RFC 9000 8.1).
    fn onReceive(self: *AntiAmplification, bytes: u64) void {
        self.received += bytes;
    }

    /// Whether sending `bytes` more is within the 3x cap (or address validation has lifted it).
    fn maySend(self: AntiAmplification, bytes: u64) bool {
        return self.validated or self.sent + bytes <= 3 * self.received;
    }
};

/// Whether a datagram carrying a client Initial meets the 1200-byte floor (RFC 9000 8.1 / 14.1).
fn initialDatagramValid(size: usize) bool {
    return size >= 1200;
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

    std.debug.print("RFC 9000 19.19: CONNECTION_CLOSE frame variants\n", .{});

    // QUIC-layer close (0x1c): error code 7, frame type 0, reason "ok" (length 2).
    const close_quic = try parseConnectionClose(try hex(arena, "1c07000" ++ "26f6b"));
    expect(&failures, "0x1c is QUIC-layer (not application)", !close_quic.is_application);
    expect(&failures, "0x1c error code = 7", close_quic.error_code == 7);
    expect(&failures, "0x1c carries frame type field", close_quic.frame_type == 0);
    expect(&failures, "0x1c reason = ok", std.mem.eql(u8, close_quic.reason, "ok"));

    // Application close (0x1d): error code 1, no frame type field, empty reason.
    const close_app = try parseConnectionClose(try hex(arena, "1d0100"));
    expect(&failures, "0x1d is application-layer", close_app.is_application);
    expect(&failures, "0x1d error code = 1", close_app.error_code == 1);
    expect(&failures, "0x1d has no frame type field (reason empty)", close_app.reason.len == 0);

    std.debug.print("RFC 9000 10.2: closing / draining states\n", .{});

    expect(&failures, "open --send CC--> closing", closeTransition(.open, .send_close) == .closing);
    expect(&failures, "open --recv CC--> draining", closeTransition(.open, .recv_close) == .draining);
    expect(&failures, "closing --recv CC--> draining", closeTransition(.closing, .recv_close) == .draining);
    expect(&failures, "closing --timeout--> closed", closeTransition(.closing, .timeout) == .closed);
    expect(&failures, "draining --timeout--> closed", closeTransition(.draining, .timeout) == .closed);
    expect(&failures, "draining sends no packets", !maySendInState(.draining));
    expect(&failures, "closing may still send the close", maySendInState(.closing));

    std.debug.print("RFC 9000 10.3: stateless reset detection + size\n", .{});

    const token: [16]u8 = .{ 0xa0, 0xa1, 0xa2, 0xa3, 0xa4, 0xa5, 0xa6, 0xa7, 0xa8, 0xa9, 0xaa, 0xab, 0xac, 0xad, 0xae, 0xaf };

    // A 25-byte datagram whose trailing 16 bytes are the known token is a Stateless Reset.
    const reset_dg = try hex(arena, "4111223344556677" ++ "88" ++ "a0a1a2a3a4a5a6a7a8a9aaabacadaeaf");
    expect(&failures, "datagram ending in token detected as reset", isStatelessReset(reset_dg, token));

    // Same length, different trailing bytes: not a reset.
    const not_reset = try hex(arena, "4111223344556677" ++ "88" ++ "ffffffffffffffffffffffffffffffff");
    expect(&failures, "other trailing bytes not a reset", !isStatelessReset(not_reset, token));

    // A 20-byte datagram is too small to be a valid QUIC packet, so never a reset.
    const tiny = try hex(arena, "a0a1a2a3a4a5a6a7a8a9aaabacadaeaf11223344");
    expect(&failures, "20-byte datagram too small for a reset", !isStatelessReset(tiny, token));

    // Size limits: a reset must be smaller than three times the packet it answers.
    expect(&failures, "reset 3x+ larger than received rejected", !resetSizeAllowed(20, 60));
    expect(&failures, "reset smaller than 3x received allowed", resetSizeAllowed(20, 59));

    std.debug.print("RFC 9000 8.1: anti-amplification + Initial floor\n", .{});

    // Before validation the server may send up to 3x the bytes received, no further.
    var anti = AntiAmplification{};
    anti.onReceive(1200);
    expect(&failures, "may send up to 3x received (3600)", anti.maySend(3600));
    expect(&failures, "may not send beyond 3x received (3601)", !anti.maySend(3601));

    // Address validation lifts the cap entirely.
    var anti_validated = AntiAmplification{ .validated = true };
    anti_validated.onReceive(100);
    expect(&failures, "validated address lifts the 3x cap", anti_validated.maySend(1_000_000));

    // The client Initial datagram floor is 1200 bytes.
    expect(&failures, "Initial datagram of 1200 valid", initialDatagramValid(1200));
    expect(&failures, "Initial datagram of 1199 invalid", !initialDatagramValid(1199));

    std.debug.print("\n", .{});
    if (failures == 0) {
        std.debug.print("PASS: all RFC 9000 Q5 close / reset / amplification rules hold\n", .{});
    } else {
        std.debug.print("FAIL: {d} check(s) failed\n", .{failures});
        std.process.exit(1);
    }
}
