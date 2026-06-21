const std = @import("std");
const zix = @import("zix");

const IP: []const u8 = "127.0.0.1";
const PORT: u16 = 9047;
const DISPATCH_MODEL: zix.Tcp.DispatchModel = .URING;
const WORKERS: usize = 0; // 0 = cpu_count ring workers (each owns its own listener + ring)
const POOL_SIZE: usize = 0; // ignored by .URING

// --------------------------------------------------------- //

// Note:
// .URING is Linux-only (ADR-037). It serves a per-FRAME callback (not the
// blocking fn(stream, io) handler): the engine owns the connection, recvs into a
// buffer, parses length-prefixed frames, and calls frameHandler once per frame,
// staging the reply for one coalesced ring send. Shared-nothing: one
// SO_REUSEPORT listener and one io_uring ring per worker. On non-Linux targets
// runFramed wraps the callback in a blocking adapter (.POOL-style) instead.

// --------------------------------------------------------- //

// Per-frame callback. Frame format (matches zix.Tcp.Client): [u32 BE len][payload].
// The engine drives the read/write loop, so this just replies per frame and never
// owns or blocks the connection (which is why it runs on the io_uring ring).
//
// Client usage: zig build example-tcp_client -- --port 9047
fn frameHandler(payload: []const u8, fd: std.posix.fd_t) void {
    _ = payload;

    zix.Tcp.frameRespond(fd, "Hello from zix TCP Server") catch {};
}

// --------------------------------------------------------- //

pub fn main(process: std.process.Init) !void {
    var server = try zix.Tcp.Server.initFramed(frameHandler, .{
        .io = process.io,
        .ip = IP,
        .port = PORT,
        .dispatch_model = DISPATCH_MODEL,
        .workers = WORKERS,
        .pool_size = POOL_SIZE,
    });
    defer server.deinit();

    try server.run();
}
