//! zix HTTP/3 per-connection state.
//!
//! What:
//! - The state one QUIC connection owns, tying the deterministic layers together: the Initial packet
//!   keys (crypto.zig), the Initial-level CRYPTO reassembly stream (tls.zig), the RTT estimator and
//!   congestion controller (recovery.zig), the anti-amplification budget and close state (close.zig),
//!   and the HTTP/3 control stream (h3.zig).
//!
//! Note:
//! - `init` derives the Initial secrets and per-direction AES-128-GCM keys from the client's
//!   Destination Connection ID (RFC 9001 5.2), the entry point a new Initial packet takes. Driving
//!   the TLS 1.3 handshake over the CRYPTO stream (through src/tls) is the live-handshake step that
//!   the server loop wires on top.

const std = @import("std");

const crypto = @import("crypto.zig");
const tls = @import("tls.zig");
const recovery = @import("recovery.zig");
const close = @import("close.zig");
const h3 = @import("h3.zig");
const demux = @import("demux.zig");
const keyschedule = @import("keyschedule.zig");
const ks = @import("../../tls/key_schedule.zig");

/// One QUIC / HTTP-3 connection's state, keyed in the demux table by its Destination Connection ID.
pub const Connection = struct {
    dcid: demux.ConnId,
    initial_client: crypto.AesKeys,
    initial_server: crypto.AesKeys,
    initial_keys: tls.InitialKeys = .{ .role = .server },
    zero_rtt: tls.ZeroRttPolicy = tls.default_zero_rtt,
    rtt: recovery.RttEstimator = .{},
    cc: recovery.CongestionController,
    anti_amplification: close.AntiAmplification = .{},
    close_state: close.CloseState = .open,
    control: h3.ControlStream = .{},
    crypto_initial: tls.CryptoStream = .{},

    // Handshake step 2 (server send path) state.
    server_hello_sent: bool = false,
    our_scid: demux.ConnId = .{},
    handshake_shared: [32]u8 = undefined,
    // Handshake-level keys + transcript, ready once ServerHello has been sent.
    handshake_ready: bool = false,
    hs_keys: keyschedule.HandshakeKeys = undefined,
    handshake_transcript: ks.Transcript = undefined,
    // 1-RTT application keys + the client's Source Connection ID, ready once the flight is sent.
    app_ready: bool = false,
    app_keys: keyschedule.AppKeys = undefined,
    peer_scid: demux.ConnId = .{},
    // 1-RTT response state.
    response_sent: bool = false,
    app_pn: u32 = 0,

    /// Initialize a server-side connection from the client's Destination Connection ID
    /// (RFC 9001 5.2): derive the Initial secrets and the per-direction AES-128-GCM packet keys, and
    /// start the congestion controller at the initial window.
    ///
    /// Param:
    /// dcid - []const u8 (the client's Destination Connection ID from the first Initial packet)
    /// max_datagram_size - u64 (the path MTU estimate, for the initial congestion window)
    ///
    /// Return:
    /// - Connection
    pub fn init(dcid: []const u8, max_datagram_size: u64) Connection {
        const secrets = crypto.initialSecrets(dcid);

        return .{
            .dcid = demux.ConnId.fromSlice(dcid),
            .initial_client = crypto.AesKeys.fromSecret(secrets.client),
            .initial_server = crypto.AesKeys.fromSecret(secrets.server),
            .cc = recovery.CongestionController.init(max_datagram_size),
        };
    }

    /// Whether the server may still send `bytes` more before the client address is validated
    /// (RFC 9000 8.1): the 3x anti-amplification cap.
    pub fn maySend(self: *const Connection, bytes: u64) bool {
        return self.anti_amplification.maySend(bytes);
    }
};

// --------------------------------------------------------------- //
// --------------------------------------------------------------- //

test "zix test: Connection init derives Initial keys from DCID (RFC 9001 A.1)" {
    const dcid = [_]u8{ 0x83, 0x94, 0xc8, 0xf0, 0x3e, 0x51, 0x57, 0x08 };
    var conn = Connection.init(&dcid, 1200);

    // The client Initial key from the RFC 9001 Appendix A.1 worked example.
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x1f, 0x36, 0x96, 0x13, 0xdd, 0x76, 0xd5, 0x46, 0x77, 0x30, 0xef, 0xcb, 0xe3, 0xb1, 0xa2, 0x2d }, &conn.initial_client.key);
    try std.testing.expectEqualSlices(u8, dcid[0..], conn.dcid.slice());
    try std.testing.expectEqual(@as(u64, 12_000), conn.cc.congestion_window);
    try std.testing.expect(conn.close_state == .open);
    try std.testing.expect(conn.initial_keys.maySendInitial());

    // Before address validation the 3x cap applies once bytes have been received.
    conn.anti_amplification.onReceive(1200);
    try std.testing.expect(conn.maySend(3600) and !conn.maySend(3601));
}
