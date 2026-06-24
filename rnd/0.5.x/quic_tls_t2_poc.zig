//! QUIC-TLS PoC, phase T2 (http3-plan.md): RFC 9001 section 4.2 (TLS version), 4.9.1 (discarding
//! Initial keys) and 4.6.2 / 4.9.3 (rejecting 0-RTT).
//!
//! Note:
//! - T1 joined the handshake to TLS. T2 adds the three guard rules that keep the join safe: QUIC is
//!   TLS 1.3 only (a negotiated version below 1.3 MUST terminate the connection), Initial keys are
//!   discarded aggressively (a server on first successfully processing a Handshake packet, a client
//!   on first sending one), and 0-RTT, when rejected, MUST NOT have its packets processed at all.
//! - The oracle is the RFC normative text: 4.2 fixes the TLS 1.3 floor, 4.9.1 fixes the role-split
//!   Initial-key discard trigger and the "MUST NOT send Initial packets after this point" rule, and
//!   4.6.2 fixes 0-RTT acceptance signaling (early_data in EncryptedExtensions) and the reject
//!   behavior. These are policy and state, not byte vectors, so the checks are behavioral.
//! - zix rejects 0-RTT by default (session resumption is deferred), so the default server policy is
//!   the reject path. State machines are exercised in process.
//!
//! Run:    zig run rnd/0.5.x/quic_tls_t2_poc.zig
//! Verify: bash rnd/0.5.x/verify-quic-tls-t2.sh

const std = @import("std");

// --------------------------------------------------------------- //

/// The TLS 1.3 version code as it appears in supported_versions (RFC 8446 4.2.1).
const tls_1_3: u16 = 0x0304;

/// Whether the negotiated TLS version is acceptable for QUIC (RFC 9001 4.2): TLS 1.3 or newer. A
/// version below 1.3 MUST terminate the connection.
fn tlsVersionAcceptable(negotiated: u16) bool {
    return negotiated >= tls_1_3;
}

// --------------------------------------------------------------- //

/// Which side of the connection an endpoint is (RFC 9001 4.9.1). The Initial-key discard trigger
/// differs by role.
const Endpoint = enum { client, server };

/// Tracks whether an endpoint still holds Initial keys (RFC 9001 4.9.1). They are discarded
/// aggressively because Initial packets are not authenticated.
const InitialKeys = struct {
    role: Endpoint,
    present: bool = true,

    /// A server discards Initial keys when it first successfully processes a Handshake packet.
    fn onHandshakeProcessed(self: *InitialKeys) void {
        if (self.role == .server) self.present = false;
    }

    /// A client discards Initial keys when it first sends a Handshake packet.
    fn onHandshakeSent(self: *InitialKeys) void {
        if (self.role == .client) self.present = false;
    }

    /// Whether the endpoint may still send Initial packets (RFC 9001 4.9.1): not after discard.
    fn maySendInitial(self: InitialKeys) bool {
        return self.present;
    }
};

// --------------------------------------------------------------- //

/// The server's 0-RTT policy (RFC 9001 4.6.2). Acceptance is signaled by an early_data extension in
/// EncryptedExtensions, and a rejecting server MUST NOT process any 0-RTT packets.
const ZeroRttPolicy = struct {
    accepts: bool,

    /// Whether EncryptedExtensions carries the early_data extension (RFC 9001 4.6.2): present only
    /// when 0-RTT is accepted.
    fn earlyDataInEncryptedExtensions(self: ZeroRttPolicy) bool {
        return self.accepts;
    }

    /// Whether the server may process a received 0-RTT packet (RFC 9001 4.6.2): never when rejected.
    fn mayProcessZeroRtt(self: ZeroRttPolicy) bool {
        return self.accepts;
    }
};

/// zix rejects 0-RTT by default: session resumption is deferred, so there are no early-data keys.
const default_zero_rtt = ZeroRttPolicy{ .accepts = false };

// --------------------------------------------------------------- //

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
    var failures: usize = 0;

    std.debug.print("RFC 9001 4.2: TLS version floor\n", .{});

    expect(&failures, "TLS 1.3 (0x0304) accepted", tlsVersionAcceptable(0x0304));
    expect(&failures, "TLS 1.2 (0x0303) -> terminate", !tlsVersionAcceptable(0x0303));
    expect(&failures, "TLS 1.1 (0x0302) -> terminate", !tlsVersionAcceptable(0x0302));
    expect(&failures, "TLS newer than 1.3 (0x0305) accepted", tlsVersionAcceptable(0x0305));

    std.debug.print("RFC 9001 4.9.1: discarding Initial keys\n", .{});

    // Server: holds Initial keys until it first successfully processes a Handshake packet.
    var server_keys = InitialKeys{ .role = .server };
    expect(&failures, "server holds Initial keys before Handshake processed", server_keys.maySendInitial());

    server_keys.onHandshakeSent();
    expect(&failures, "server: sending Handshake does not discard (wrong trigger)", server_keys.maySendInitial());

    server_keys.onHandshakeProcessed();
    expect(&failures, "server discards Initial keys on first Handshake processed", !server_keys.present);
    expect(&failures, "server MUST NOT send Initial after discard", !server_keys.maySendInitial());

    // Client: discards Initial keys when it first sends a Handshake packet.
    var client_keys = InitialKeys{ .role = .client };
    client_keys.onHandshakeProcessed();
    expect(&failures, "client: processing Handshake does not discard (wrong trigger)", client_keys.maySendInitial());

    client_keys.onHandshakeSent();
    expect(&failures, "client discards Initial keys on first Handshake sent", !client_keys.maySendInitial());

    std.debug.print("RFC 9001 4.6.2: rejecting 0-RTT\n", .{});

    // A rejecting server omits early_data from EncryptedExtensions and processes no 0-RTT packets.
    const rejecting = ZeroRttPolicy{ .accepts = false };
    expect(&failures, "rejecting server omits early_data in EE", !rejecting.earlyDataInEncryptedExtensions());
    expect(&failures, "rejecting server MUST NOT process 0-RTT packets", !rejecting.mayProcessZeroRtt());

    // An accepting server signals early_data and processes the packets.
    const accepting = ZeroRttPolicy{ .accepts = true };
    expect(&failures, "accepting server signals early_data in EE", accepting.earlyDataInEncryptedExtensions());
    expect(&failures, "accepting server processes 0-RTT packets", accepting.mayProcessZeroRtt());

    // zix default policy is reject (resumption deferred).
    expect(&failures, "zix default policy rejects 0-RTT", !default_zero_rtt.mayProcessZeroRtt());

    std.debug.print("\n", .{});
    if (failures == 0) {
        std.debug.print("PASS: all RFC 9001 T2 version / key-discard / 0-RTT checks hold\n", .{});
    } else {
        std.debug.print("FAIL: {d} check(s) failed\n", .{failures});
        std.process.exit(1);
    }
}
