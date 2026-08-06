// Usage:
// zig build example-webrtc_sfu_broadcast
// ./zig-out/bin/zix-example-webrtc_sfu_broadcast
// browser: http://localhost:9087/ to send, and the same page in more tabs to watch
// use `ip -4 -o addr show` to find the address the page asks for
//
// One camera, many watchers, and zix in the middle. Every browser holds ONE connection, to this
// process, and this process forwards the sender's audio and video to everybody else. That is what
// makes it a forwarding unit rather than a call: webrtc_video_call is a mesh, where each pair of
// tabs holds its own connection and the count grows with the square of the room.
//
// zix decodes nothing. A packet is opened with the sender's key, its header is rewritten where a
// receiver needs different numbering, and it is sealed again under that receiver's key. The
// payload is copied and never read, so a codec this process has never heard of crosses it
// unchanged. Re-protection is the one unavoidable cost: no two peers share an SRTP key, so a
// packet cannot be passed along as it arrived.
//
// Two servers in one process, on the same port number: the signalling and the page on TCP 9087,
// the WebRTC peer on UDP 9087. Different protocols, so they never collide.
//
// Note:
// - The page asks for the address to publish, and it matters. This server answers with ONE
//   candidate, and a browser has to be able to route to it. A loopback address is not one: Firefox
//   gathers no loopback candidate of its own, so it never pairs with a loopback one either, and
//   the session dies in ICE with nothing on the wire to explain it.
// - The sender's page has to be loaded at http://localhost:9087/ even so, because a camera is
//   handed out in a secure context only and a plain http page on a network address is not one.
//   Those two rules pull opposite ways, which is exactly why the address is asked for rather than
//   taken from the address bar. A watcher's page needs no camera and can be loaded either way.
// - .ASYNC on purpose. Forwarding reaches the peers of one worker, and .ASYNC runs exactly one, so
//   the room is whole. Under .EPOLL or .URING the kernel spreads peers across cores by address and
//   a sender would only reach the share of the room that landed on its core.
// - Every browser opens a data channel alongside its media, because the answer builder is built
//   around a data channel session that may also carry media. The page opens one and uses it for
//   nothing but knowing the connection came up.
// - zix does not renumber payload types. Each browser negotiates its own, and the sender's numbers
//   are what cross, so a sender and a watcher that number a codec differently will not line up.
//   The same browser on both ends always does.
// - One set of ICE credentials serves every browser, which is what accept_any_peer_ice_ufrag is
//   for. Anyone who can reach the signalling endpoint can join, so put the room behind whatever
//   the deployment already uses to say who may post.
//
// Pair it with:
//   webrtc_video_call, the same call as a mesh, where zix relays signalling and is not a peer
//   webrtc_datachannel_chat, the same shape as this one carrying messages instead of media

const std = @import("std");
const zix = @import("zix");

// --------------------------------------------------------- //

// Every interface, because the address a browser reaches this on is the one the page publishes,
// and that is not always the one the page was loaded from.
const BIND_IP: []const u8 = "0.0.0.0";
const SERVER_PORT: u16 = 9087;

// What the answer names when the page published nothing usable.
const FALLBACK_IP: []const u8 = "127.0.0.1";

// Served page. Loaded per request so editing the file shows up on a browser refresh with no
// rebuild. The path is relative, so run this example from the repository root.
const PAGE_PATH: []const u8 = "templates/html/webrtc_sfu_broadcast.html";
const MAX_PAGE_BYTES: usize = 64 * 1024;

// This server's own ICE credentials, published in every answer. The password is the key each
// browser signs its connectivity checks with, so it has to be at least 22 characters
// (RFC 8445 5.3).
const LOCAL_UFRAG: []const u8 = "zixsfu";
const LOCAL_PASSWORD: []const u8 = "zixsfupasswordaaaaaaaa";

const CERT_PATH: []const u8 = "examples/certs/ecdsa_p256_cert.pem";
const KEY_PATH: []const u8 = "examples/certs/ecdsa_p256_key.pem";

const KERNEL_BACKLOG: u31 = 128;

// An offer carrying a camera, a microphone, a data channel, and every codec the browser knows is a
// few kilobytes.
const MAX_RECV_BUF: usize = 16 * 1024;

// One media datagram. A browser sends video in packets around the path MTU, and the peer's receive
// buffer has to hold the largest of them whole.
const MEDIA_RECV_BUF: usize = 1500;

// The query parameter the page publishes its address in.
const ADDRESS_PARAM: []const u8 = "at";

// --------------------------------------------------------- //

/// The hash of the certificate this peer presents, computed once and published in every answer.
/// Filled in main, before either server starts.
var g_fingerprint: zix.Webrtc.sdp_fingerprint.Fingerprint = undefined;

/// What the answer names when the page published nothing usable. Filled in main.
var g_fallback_address: std.Io.net.IpAddress = undefined;

/// The address to publish as this peer's one candidate.
///
/// Note:
/// - The page publishes it, because the address a browser loaded the page from is not always one
///   it can reach this peer on. A sender loads the page over localhost so it can open a camera,
///   and a candidate on localhost is one no browser will pair with.
/// - Getting this wrong is a session that dies in ICE with nothing on the wire and nothing in any
///   log.
fn advertisedAddress(req: *zix.Http1.Request) std.Io.net.IpAddress {
    const published = req.queryParam(ADDRESS_PARAM) orelse return hostAddress(req);

    return std.Io.net.IpAddress.parse(published, SERVER_PORT) catch hostAddress(req);
}

/// The address the page was loaded from, which is what a watcher's tab already has right.
fn hostAddress(req: *zix.Http1.Request) std.Io.net.IpAddress {
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

// Media never reaches a handler. It is forwarded under the application, which is the point of a
// forwarding unit, so what is left here is the data channel every browser opens alongside it.
fn onEvent(event: zix.Webrtc.Event, _: *zix.Webrtc.Context) !void {
    switch (event) {
        .CHANNEL_OPEN => |channel| std.log.info("channel {d} open, a browser is connected", .{channel}),
        .CHANNEL_CLOSED => |channel| std.log.info("channel {d} closed", .{channel}),
        .MESSAGE => {},
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

// POST /offer?at=<address>
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
        // The half that tells the browser to send. The engine's own carry_media is what keys the
        // transport underneath, and turning on one without the other either promises media that is
        // never carried or keys a path nothing uses.
        .carry_media = true,
    }) catch |err| {
        res.setStatus(.BAD_REQUEST);

        std.log.warn("answer refused: {s}", .{@errorName(err)});

        try res.sendJson("{\"error\":\"that offer leaves this peer no role it can take\"}");
        return;
    };

    std.log.info("answered an offer, {d} of {d} sections carry media", .{ answer.carried_media_count, answer.section_count });

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
        .carry_media = true,
        .max_recv_buf = MEDIA_RECV_BUF,
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

    std.log.info("webrtc forwarding peer on udp {s}:{d}, page on http://localhost:{d}/ (the page asks for the address to publish)", .{ BIND_IP, SERVER_PORT, SERVER_PORT });

    try server.run();
}
