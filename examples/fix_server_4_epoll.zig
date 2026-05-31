const std = @import("std");
const zix = @import("zix");

const IP: []const u8 = "0.0.0.0";
const PORT: u16 = 9500;
const COMP_ID: []const u8 = "ZIX";
const DISPATCH_MODEL: zix.Fix.DispatchModel = .EPOLL;
const WORKERS: usize = 0; // ignored by EPOLL (single event loop thread handles accept)
const POOL_SIZE: usize = 0; // 0 = auto (max(10, cpu_count * 2) pool threads)

// Logger config — uncomment this section to add logger
// const LOG_DIR: []const u8  = "./logs";
// const LOG_FILE: []const u8 = "fix";

// fn createLogDir(io: std.Io) void {
//     std.Io.Dir.cwd().createDirPath(io, LOG_DIR) catch {};
// }

// --------------------------------------------------------- //

// Note:
// On Linux, .EPOLL runs natively: a single epoll accept loop pushes accepted
// fds to an FdQueue. Pool workers pop and hold each connection for its full
// lifetime (same pattern as zix.Grpc EPOLL). FIX sessions are long-lived and
// stateful — one-thread-per-connection maps naturally to this model.
// On non-Linux targets, .EPOLL falls back to .POOL automatically (with a
// debug print). Use fix_server_2_pool.zig to set POOL explicitly instead.

// --------------------------------------------------------- //

pub fn main(process: std.process.Init) !void {
    // Uncomment this to add logger (console only — no save_path means no file output):
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

    var server = try zix.Fix.Server.init(&.{}, .{
        .io = process.io,
        .ip = IP,
        .port = PORT,
        .comp_id = COMP_ID,
        .dispatch_model = DISPATCH_MODEL,
        .workers = WORKERS,
        .pool_size = POOL_SIZE,
        // .logger = &logger, // uncomment to wire logger (FIX lifecycle + session logging)
    });
    defer server.deinit();

    try server.run();
}
