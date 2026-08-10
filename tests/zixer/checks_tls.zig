//! Client side of the TLS demo rows: the terminate demo and the webrtc
//! signaling site.
//!
//! Both reach the edge over TLS 1.3 and both are answered by a backend that
//! speaks cleartext. The certificate is the repository fixture, so the client
//! trusts it explicitly rather than skipping verification.

const std = @import("std");
const zix = @import("zix");

const common = @import("runner_common");

/// The fixture certificate the demo sites present, self-signed for localhost.
const CA_PATH: []const u8 = "examples/certs/ecdsa_p256_cert.pem";
/// Longest reply the terminate check reads.
const MAX_BODY: usize = 16 * 1024;

// --------------------------------------------------------- //

/// TLS terminate: https at the edge, and the report shows the backend was
/// reached over cleartext http1. The name must be the certificate's, because a
/// Host that matches no name in it is answered 421.
pub fn runTls(io: std.Io, port: u16) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();

    var client = zix.Http.Client.init(.{
        .allocator = arena.allocator(),
        .io = io,
        .connect_timeout_ms = 3000,
        .response_timeout_ms = common.RESPONSE_TIMEOUT_MS,
        .read_timeout_ms = common.RESPONSE_TIMEOUT_MS,
        .max_response_body = MAX_BODY,
        .tls_ca_path = CA_PATH,
    });
    defer client.deinit();

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "https://localhost:{d}/", .{port});

    var resp = try client.get(url, .{});
    defer resp.deinit();

    if (resp.status() != 200) return error.ZixUnexpectedStatus;
    if (resp.header("Via") == null) return error.MissingVia;
    if (std.mem.indexOf(u8, resp.body(), "upstream: proxies/tls") == null) return error.NotFromUpstream;
    if (std.mem.indexOf(u8, resp.body(), "cleartext http/1.1") == null) return error.UpstreamLegNotCleartext;
}

/// webrtc signaling: the wss handshake and one echoed frame, over the same TLS
/// edge, with an ordinary websocket backend behind it.
pub fn runRtcSignal(io: std.Io, port: u16) !void {
    try common.tlsWsEcho(io, port);
}
