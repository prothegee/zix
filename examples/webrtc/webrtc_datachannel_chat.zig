// Usage:
// zig build example-webrtc_datachannel_chat
// ./zig-out/bin/example-webrtc_datachannel_chat
// browser: http://<this machine's address>:9085/ in as many tabs as you like
// use `ip -4 -o addr show` to check machine address.
//
// Load it by this machine's network address, not localhost. The answer publishes one candidate,
// the address the page was loaded from, and a browser has to be able to route to it. Firefox
// gathers no loopback candidate of its own, so it never pairs with a loopback one either: over
// localhost its ICE goes straight to failed with nothing said on the wire.
//
// zix as the peer, in a room. Every browser opens a data channel to this process, and a message on
// any of them goes out on all the others. Nothing goes back to the tab that sent it: the page
// already has its own message on screen, and the fan-out skips the sender.
//
// Two servers in one process, on the same port number: the signalling and the page on TCP 9085,
// the WebRTC peer on UDP 9085. Different protocols, so they never collide.
//
// The signalling is one POST. The browser sends its offer, this answers it, and that is the whole
// exchange: an ice-lite answerer has one candidate and nothing to trickle (RFC 8838 8), so there
// is no second round and no WebSocket to keep open. Compare webrtc_signaling, where zix relays an
// exchange between two browsers and is not a peer at all.
//
// Note:
// - .ASYNC on purpose. A broadcast reaches the peers of one worker, and .ASYNC runs exactly one,
//   so the room is whole. Under .EPOLL or .URING the kernel spreads peers across cores by address
//   and each core would fan out to its own share of the room.
// - One set of ICE credentials serves every browser, which is what accept_any_peer_ice_ufrag is
//   for: each browser draws its own ufrag and learns this server's password from the answer, and
//   that password is what every connectivity check is verified against.
// - Anyone who can reach the signalling endpoint gets those same credentials and can join. Put the
//   room behind whatever the deployment already uses to say who may post.

const std = @import("std");
const zix = @import("zix");

// --------------------------------------------------------- //

// Every interface, because the address a browser can reach this on is the one it typed, and the
// answer has to name that same address back.
const BIND_IP: []const u8 = "0.0.0.0";
const SERVER_PORT: u16 = 9085;

// What the answer names when the browser asked for something that is not an address, which is what
// "localhost" is.
const FALLBACK_IP: []const u8 = "127.0.0.1";

// Served page. Loaded per request so editing the file shows up on a browser refresh with no
// rebuild. The path is relative, so run this example from the repository root.
const PAGE_PATH: []const u8 = "templates/html/webrtc_datachannel_chat.html";
const MAX_PAGE_BYTES: usize = 64 * 1024;

// This server's own ICE credentials, published in every answer. The password is the key each
// browser signs its connectivity checks with, so it has to be at least 22 characters
// (RFC 8445 5.3).
const LOCAL_UFRAG: []const u8 = "zixchat";
const LOCAL_PASSWORD: []const u8 = "zixchatpasswordaaaaaaa";

const CERT_PATH: []const u8 = "examples/certs/ecdsa_p256_cert.pem";
const KEY_PATH: []const u8 = "examples/certs/ecdsa_p256_key.pem";

const KERNEL_BACKLOG: u31 = 128;

// An offer with a bundle group and a dozen candidates is a few kilobytes.
const MAX_RECV_BUF: usize = 16 * 1024;

// What the room is told when somebody arrives or goes.
const JOINED: []const u8 = "* somebody joined";
const LEFT: []const u8 = "* somebody left";

// --------------------------------------------------------- //

/// The hash of the certificate this peer presents, computed once and published in every answer.
/// Filled in main, before either server starts.
var g_fingerprint: zix.Webrtc.sdp_fingerprint.Fingerprint = undefined;

/// What the answer names when the browser did not ask for an address. Filled in main.
var g_fallback_address: std.Io.net.IpAddress = undefined;

/// The address to publish as this peer's one candidate: the one the browser used to load the page,
/// which is by definition an address it can already route to.
///
/// Note:
/// - Getting this wrong is a session that dies in ICE with nothing on the wire and nothing in any
///   log, because a browser will not send a check to a candidate it cannot pair with.
fn advertisedAddress(req: *zix.Http1.Request) std.Io.net.IpAddress {
    const host = req.header("host") orelse return g_fallback_address;

    return std.Io.net.IpAddress.parse(hostName(host), SERVER_PORT) catch g_fallback_address;
}

/// The host half of a Host header, with the port cut off. An IPv6 literal is bracketed, so there
/// the closing bracket ends it rather than the first colon.
fn hostName(host: []const u8) []const u8 {
    if (host.len > 0 and host[0] == '[') {
        const close = std.mem.indexOfScalar(u8, host, ']') orelse return host;

        return host[1..close];
    }

    const colon = std.mem.indexOfScalar(u8, host, ':') orelse return host;

    return host[0..colon];
}

// --------------------------------------------------------- //

// Every message goes to the rest of the room and nowhere else. The payload is borrowed for the
// length of this call, and the fan-out copies it, so nothing here has to be kept.
fn onEvent(event: zix.Webrtc.Event, ctx: *zix.Webrtc.Context) !void {
    switch (event) {
        .CHANNEL_OPEN => |channel| {
            std.log.info("channel {d} open, {d} others in the room", .{ channel, ctx.broadcast(.STRING, JOINED) });
        },
        .CHANNEL_CLOSED => |channel| {
            std.log.info("channel {d} closed", .{channel});

            _ = ctx.broadcast(.STRING, LEFT);
        },
        .MESSAGE => |message| _ = ctx.broadcast(message.kind, message.payload),
    }
}

/// What the WebRTC half needs to start, passed by value so it can be copied into the task.
const PeerCap = struct {
    config: zix.Webrtc.ServerConfig,
};

// The WebRTC peer runs alongside the signalling server for the process lifetime.
fn peerTask(cap: PeerCap) void {
    var server = zix.Webrtc.Server.init(onEvent, cap.config);
    defer server.deinit();

    server.run() catch |err| std.log.err("webrtc peer stopped: {s}", .{@errorName(err)});
}

// --------------------------------------------------------- //

// POST /offer
// The browser's session description in, this peer's answer out. Body and reply are both plain SDP,
// which is what RTCPeerConnection hands over and takes back.
fn offerHandler(req: *zix.Http1.Request, res: *zix.Http1.Response, _: *zix.Http1.Context) !void {
    if (req.method() != .POST) {
        res.setStatus(.METHOD_NOT_ALLOWED);

        try res.sendJson("{\"error\":\"post an sdp offer here\"}");
        return;
    }

    const body = req.body() catch {
        res.setStatus(.BAD_REQUEST);

        try res.sendJson("{\"error\":\"could not read the offer\"}");
        return;
    };

    const offered = zix.Webrtc.sdp_offer.read(body) catch |err| {
        res.setStatus(.BAD_REQUEST);

        std.log.warn("offer refused: {s}", .{@errorName(err)});

        try res.sendJson("{\"error\":\"that is not an offer this peer can answer\"}");
        return;
    };

    var out: [zix.Webrtc.sdp_answer.MAX_ANSWER_BYTES]u8 = undefined;
    const answer = zix.Webrtc.sdp_answer.write(&out, offered, .{
        .ice_ufrag = LOCAL_UFRAG,
        .ice_pwd = LOCAL_PASSWORD,
        .fingerprint = g_fingerprint,
        .address = advertisedAddress(req),
        // Unique per session (RFC 8829 5.2.1). Masked because a browser reads this field into a
        // signed 64-bit integer, and refuses the whole answer when a full-range draw does not fit.
        .session_id = zix.utils.secure_random.int(u64) & zix.Webrtc.sdp_answer.MAX_SESSION_ID,
    }) catch |err| {
        res.setStatus(.BAD_REQUEST);

        std.log.warn("answer refused: {s}", .{@errorName(err)});

        try res.sendJson("{\"error\":\"that offer leaves this peer no role it can take\"}");
        return;
    };

    res.setContentType(.TEXT_PLAIN);

    try res.send(answer.text);
}

// GET /
// The page every tab loads.
fn pageHandler(_: *zix.Http1.Request, res: *zix.Http1.Response, ctx: *zix.Http1.Context) !void {
    const page = try zix.utils.file.load(ctx.io, ctx.allocator, PAGE_PATH, MAX_PAGE_BYTES);
    defer ctx.allocator.free(page);

    res.setContentType(.TEXT_HTML);

    try res.send(page);
}

// --------------------------------------------------------- //

const Routes = zix.Http1.Router(&[_]zix.Http1.Route{
    .{ .path = "/offer", .handler = offerHandler },
    .{ .path = "/", .handler = pageHandler },
});

pub fn main(process: std.process.Init) !void {
    const io = process.io;
    const allocator = std.heap.smp_allocator;

    // The engine says nothing without a logger, and this is an example somebody watches while a
    // browser tries to reach it. Every peer opened, every handshake finished, and every layer that
    // refused something comes through here.
    var logger = try zix.Logger.init(allocator, .{
        .console = .ALWAYS,
        .console_min_level = .INFO,
    });
    defer logger.deinit();

    // The certificate and the key that signs the ServerKeyExchange. WebRTC has no cleartext mode,
    // and the one DTLS 1.2 suite this engine implements is ECDHE-ECDSA, so the key has to be P-256.
    var tls = try zix.Tls.Context.init(allocator, io, .{
        .cert_path = CERT_PATH,
        .key_path = KEY_PATH,
    });
    defer tls.deinit();

    // Both of these are read by the signalling handler on every offer, so they are settled before
    // either server starts.
    g_fingerprint = zix.Webrtc.sdp_fingerprint.compute(tls.cert_der, .SHA_256);
    g_fallback_address = try std.Io.net.IpAddress.parse(FALLBACK_IP, SERVER_PORT);

    const peer_config: zix.Webrtc.ServerConfig = .{
        .io = io,
        .allocator = allocator,
        .ip = BIND_IP,
        .port = SERVER_PORT,
        .dispatch_model = .ASYNC,
        .ice_ufrag = LOCAL_UFRAG,
        .ice_password = LOCAL_PASSWORD,
        .accept_any_peer_ice_ufrag = true,
        .tls = &tls,
        .logger = &logger,
    };

    if (io.concurrent(peerTask, .{PeerCap{ .config = peer_config }})) |_| {} else |err| {
        std.log.err("webrtc peer did not start: {s}", .{@errorName(err)});
    }

    var server = zix.Http1.Server.init(Routes.dispatch, .{
        .io = io,
        .ip = BIND_IP,
        .port = SERVER_PORT,
        .dispatch_model = .ASYNC,
        .kernel_backlog = KERNEL_BACKLOG,
        .max_recv_buf = MAX_RECV_BUF,
    });
    defer server.deinit();

    std.log.info("webrtc chat peer on udp {s}:{d}, page on http://{s}:{d}/ (load it by this machine's address, not localhost)", .{ BIND_IP, SERVER_PORT, BIND_IP, SERVER_PORT });

    try server.run();
}
