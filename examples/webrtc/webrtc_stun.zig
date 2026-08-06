// Usage:
// zig build example-webrtc_stun
// ./zig-out/bin/zix-example-webrtc_stun
// browser: http://<this machine's address>:9082/, not localhost, see the note below
// use `ip -4 -o addr show` to check machine address.
//
// A STUN binding server (RFC 8489 11) and the page that asks a browser to use it. One question,
// one answer: a peer sends a binding request and gets back the transport address the request
// arrived from, which is the address the outermost NAT gave it. That is the whole of STUN, and it
// is the first thing every WebRTC peer does.
//
// Two servers in one process, on the same port number: the binding server on UDP 9082, and the
// page on TCP 9082. Different protocols, so they never collide.
//
// This runs on the raw UDP surface, not the WebRTC engine. A binding request carries no session
// and needs no reply state, so it wants a handler over datagrams and nothing else.
//
// Note:
// - Both halves bind 0.0.0.0, and the page has to be loaded by this machine's network address
//   rather than by localhost. Measured with Firefox: over localhost the page gathers host
//   candidates only, because the browser will not send a binding request to a loopback server.
//   Loaded by the machine's own address it answers with the reflexive candidate straight away.
// - The checks a WebRTC session sends later are STUN too, but they are authenticated and go to
//   the peer rather than here (RFC 8445 7.1.1). This server answers the unauthenticated kind.

const std = @import("std");
const zix = @import("zix");

// --------------------------------------------------------- //

// 0.0.0.0 on purpose, see the note above.
const IP: []const u8 = "0.0.0.0";
const PORT: u16 = 9082;

// Served page. Loaded per request so editing the file shows up on a browser refresh with no
// rebuild. The path is relative, so run this example from the repository root.
const PAGE_PATH: []const u8 = "templates/html/webrtc_stun.html";
const MAX_PAGE_BYTES: usize = 64 * 1024;

const KERNEL_BACKLOG: u31 = 128;
const MAX_RECV_BUF: usize = 4 * 1024;

// --------------------------------------------------------- //

// One datagram, one answer. Anything that is not a binding request this server can read leaves
// with no reply at all, which is what RFC 8489 6.3 asks for.
fn onDatagram(datagram: []const u8, peer: *const std.Io.net.IpAddress, sink: *zix.Udp.Sink) void {
    var out: [zix.Webrtc.stun_binding.MAX_RESPONSE_BYTES]u8 = undefined;
    const reply = zix.Webrtc.stun_binding.respond(datagram, peer, &out) orelse return;

    sink.reply(reply);
}

const BindingServer = zix.Udp.Raw(onDatagram);

// --------------------------------------------------------- //

// GET /
// The page that points a browser's ICE agent at the server above.
fn pageHandler(_: *zix.Http1.Request, res: *zix.Http1.Response, ctx: *zix.Http1.Context) !void {
    const page = try zix.utils.file.load(ctx.io, ctx.allocator, PAGE_PATH, MAX_PAGE_BYTES);
    defer ctx.allocator.free(page);

    res.setContentType(.TEXT_HTML);

    try res.send(page);
}

const PageRoutes = zix.Http1.Router(&[_]zix.Http1.Route{
    .{ .path = "/", .handler = pageHandler },
});

/// What the page server needs to start, passed by value so it can be copied into the task.
const PageCap = struct {
    io: std.Io,
};

// The page server runs alongside the binding server for the process lifetime. It is here only to
// hand a browser the page, so it gets its own task and the binding loop keeps the main thread.
fn pageTask(cap: PageCap) void {
    var server = zix.Http1.Server.init(PageRoutes.dispatch, .{
        .io = cap.io,
        .ip = IP,
        .port = PORT,
        .dispatch_model = .ASYNC,
        .kernel_backlog = KERNEL_BACKLOG,
        .max_recv_buf = MAX_RECV_BUF,
    });
    defer server.deinit();

    server.run() catch |err| std.log.err("page server stopped: {s}", .{@errorName(err)});
}

pub fn main(process: std.process.Init) !void {
    const io = process.io;

    if (io.concurrent(pageTask, .{PageCap{ .io = io }})) |_| {} else |err| {
        std.log.err("page server did not start: {s}", .{@errorName(err)});
    }

    var server = try BindingServer.init(.{
        .io = io,
        .allocator = std.heap.smp_allocator,
        .ip = IP,
        .port = PORT,
        .allow_args = false,
        .dispatch_model = .ASYNC,
        .max_recv_buf = 1500,
    }, process.minimal.args);
    defer server.deinit();

    std.log.info("stun binding on udp {s}:{d}, page on http://{s}:{d}/", .{ IP, PORT, IP, PORT });

    try server.run();
}
