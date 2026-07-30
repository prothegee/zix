const std = @import("std");
const builtin = @import("builtin");
const zix = @import("zix");

const IP: []const u8 = "127.0.0.1";
const PORT: u16 = 9043;
// Pick the model per target at comptime (ADR-065): .URING is the Linux shared-nothing
// completion loop, .ASYNC the portable model. .EPOLL and .URING are Linux-only, and run()
// returns error.DispatchModelUnsupported rather than silently serving a different model.
const DISPATCH_MODEL: zix.Tcp.DispatchModel = if (builtin.os.tag == .linux) .URING else .ASYNC;
const WORKERS: usize = 0; // 0 = cpu_count workers under .EPOLL / .URING, ignored by .ASYNC

// Logger config: uncomment this section to add logger
// const LOG_DIR: []const u8  = "./logs";
// const LOG_FILE: []const u8 = "tcp";

// fn createLogDir(io: std.Io) void {
//     std.Io.Dir.cwd().createDirPath(io, LOG_DIR) catch {};
// }

// --------------------------------------------------------- //

// Note:
// initFramed serves a per-FRAME callback (not the blocking fn(stream, io) handler). Under
// .URING (Linux, ADR-037) the engine owns the connection, recvs into a buffer, parses
// length-prefixed frames, and calls frameHandler once per frame, staging the reply for one
// coalesced ring send. Shared-nothing: one SO_REUSEPORT listener and one io_uring ring per
// worker. Under .ASYNC the same callback runs through a blocking per-connection adapter, so
// the frame protocol is identical on every platform.

// --------------------------------------------------------- //

// Per-frame callback. Frame format (matches zix.Tcp.Client): [u32 BE len][payload].
// The engine drives the read/write loop, so this just replies per frame and never
// owns or blocks the connection (which is why it runs on the io_uring ring).
//
// Client usage: zig build example-tcp_client -- --port 9043
fn frameHandler(payload: []const u8, fd: std.posix.fd_t) void {
    _ = payload;

    zix.Tcp.frameRespond(fd, "Hello from zix TCP Server") catch {};
}

// --------------------------------------------------------- //

pub fn main(process: std.process.Init) !void {
    // Uncomment this to add logger (console only, no save_path means no file output):
    // var logger = try zix.Logger.init(std.heap.smp_allocator, .{
    //     .console           = .ALWAYS,
    //     .console_min_level = .INFO,
    // });
    // defer logger.deinit();

    // Uncomment this to add logger with file output (createLogDir must run first):
    // createLogDir(process.io);
    // var logger = try zix.Logger.init(std.heap.smp_allocator, .{
    //     .save_path      = LOG_DIR,
    //     .save_file      = LOG_FILE,
    //     .save_min_level = .INFO,
    //     .console        = .ALWAYS,
    // });
    // defer logger.deinit();

    var server = try zix.Tcp.Server.initFramed(frameHandler, .{
        .io = process.io,
        .ip = IP,
        .port = PORT,
        .dispatch_model = DISPATCH_MODEL,
        .workers = WORKERS,
        // .logger = &logger, // uncomment to wire logger (TCP lifecycle + conn logging)
    });
    defer server.deinit();

    try server.run();
}
