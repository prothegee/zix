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

/// The most concurrent large (multi-packet) response streams one connection tracks for resumption.
pub const max_send_streams = 32;

/// Decrypted 1-RTT payload copy buffer per connection: caps multiplexed request bytes per datagram.
const DEFAULT_APP_PAYLOAD_BUF: usize = 2048;

/// Huffman-decoded :path scratch buffer per connection: caps the decoded path length.
const DEFAULT_PATH_SCRATCH: usize = 1024;

/// A response body being sent across multiple packets, resumed as the client extends flow control
/// (RFC 9000 4.1). The body is a zero-copy slice into handler-owned memory that MUST outlive the
/// stream (the static file cache satisfies this): the engine never copies it. The HTTP/3 prefix
/// (HEADERS + DATA header) is rebuilt on demand from status + body length, so it is not stored.
pub const SendStream = struct {
    active: bool = false,
    stream_id: u64 = 0,
    status: u16 = 200,
    body: []const u8 = "",
    /// Total HTTP/3 stream length: the prefix length plus the body length.
    content_len: usize = 0,
    /// Stream offset already sent.
    sent: usize = 0,
    /// The client's current per-stream flow control limit, raised by MAX_STREAM_DATA.
    stream_limit: u64 = 0,

    /// Whether every byte of the stream content has been sent (the FIN went out).
    pub fn complete(self: *const SendStream) bool {
        return self.sent >= self.content_len;
    }
};

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
    // 1-RTT request / response state.
    app_pn: u32 = 0,
    // Largest 1-RTT packet number received from the client (for the response ACK).
    app_largest_received: ?u64 = null,
    // Whether the first 1-RTT response has been sent. The server control stream (SETTINGS) and
    // HANDSHAKE_DONE ride that first response only, later per-stream responses omit them.
    first_response_sent: bool = false,
    // The most recent decrypted 1-RTT payload, copied off the recv buffer so the response builder can
    // walk every request stream it carries (a connection multiplexes many) without a second decrypt.
    app_payload_buf: [DEFAULT_APP_PAYLOAD_BUF]u8 = undefined,
    app_payload_len: usize = 0,
    // Reusable scratch for a Huffman-encoded :path (curl / h2load encode it), expanded per request.
    path_scratch: [DEFAULT_PATH_SCRATCH]u8 = undefined,
    // Client-advertised flow control limits (RFC 9000 4.1), parsed from the ClientHello transport
    // parameters. The server must not send response stream data past these. Zero until the handshake
    // parses them (a minimal client that sends no transport parameters grants no large-body credit).
    client_max_stream_data: u64 = 0,
    client_max_data: u64 = 0,
    // Running total of stream bytes the server has sent on this connection, against client_max_data.
    conn_data_sent: u64 = 0,
    // Large responses still being sent across packets, resumed as the client extends flow control.
    send_streams: [max_send_streams]SendStream = @splat(.{}),

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

    /// The in-flight large-response send stream for `stream_id`, or null when none is tracked.
    pub fn findSendStream(self: *Connection, stream_id: u64) ?*SendStream {
        for (&self.send_streams) |*stream| {
            if (stream.active and stream.stream_id == stream_id) return stream;
        }

        return null;
    }

    /// Reserve a send-stream slot for `stream_id`: the existing slot if one is tracked, otherwise a
    /// free slot. Returns null when every slot is busy with another in-flight stream.
    pub fn reserveSendStream(self: *Connection, stream_id: u64) ?*SendStream {
        if (self.findSendStream(stream_id)) |stream| return stream;

        for (&self.send_streams) |*stream| {
            if (!stream.active) return stream;
        }

        return null;
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
