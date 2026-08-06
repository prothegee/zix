//! Client side of the http3 demo row.
//!
//! The client is the hand-rolled QUIC one the zix runner already uses, so the
//! whole exchange is native: ClientHello, handshake, QPACK request, and the
//! response reassembled from real packets.

const std = @import("std");

const http3_client = @import("runner_http3_client");

/// Longest reply body the check reads back.
const MAX_BODY: usize = 4096;

// --------------------------------------------------------- //

/// http3 edge: one GET over QUIC, answered by the http1 upstream behind it.
/// The via element proves which edge rebuilt the request.
pub fn runHttp3(io: std.Io, port: u16) !void {
    var body_buf: [MAX_BODY]u8 = undefined;
    const body = try http3_client.fetch(io, "127.0.0.1", port, "/", &body_buf);

    if (std.mem.indexOf(u8, body, "upstream: proxies/http3") == null) return error.NotFromUpstream;
    if (std.mem.indexOf(u8, body, "via: 3 zixer") == null) return error.UpstreamMissedVia;
}
