const std = @import("std");
const zix = @import("zix");

const IP: []const u8 = "127.0.0.1";
const PORT: u16 = 9016;
const DISPATCH_MODEL: zix.Http1.DispatchModel = .POOL;
const KERNEL_BACKLOG: u31 = 1024;
const MAX_RECV_BUF: usize = 16 * 1024;
const COMPRESSION_MAX_OUT: usize = 256 * 1024;
const WORKERS: usize = 0; // 0 = cpu_count accept threads
const POOL_SIZE: usize = 0; // 0 = max(10, cpu_count * 2) pool threads

// Logger config, uncomment this section to add logger
// const LOG_DIR: []const u8  = "./logs";
// const LOG_FILE: []const u8 = "app";

// --------------------------------------------------------- //

// Optional global logger for handler-side access logging.
// The engine does not emit a per-request access line, so a handler that wants
// one logs via this global, where res holds the final status and byte count. The
// server itself logs only lifecycle lines (listening) when config.logger is set.
//
// var g_logger: ?*zix.Logger = null;

// Creates the log directory at startup.
// The logger does not create save_path automatically, that is the caller's responsibility.
// Silently ignores "already exists", safe to call on every start.
//
// fn createLogDir(io: std.Io) void {
//     std.Io.Dir.cwd().createDirPath(io, LOG_DIR) catch {};
// }

// --------------------------------------------------------- //

// curl usage: curl -X GET "http://localhost:9016/"
fn homeHandler(req: *zix.Http1.Request, res: *zix.Http1.Response, _: *zix.Http1.Context) !void {
    res.setContentType(.TEXT_PLAIN);
    try res.send("Hello, World!");

    // Handler-side access logging (uncomment with g_logger above):
    // if (g_logger) |lg| {
    //     const forwarded_for = req.header("x-forwarded-for") orelse "";
    //     const client_ip = if (forwarded_for.len > 0) forwarded_for else req.header("x-real-ip") orelse "";
    //     const user_agent = req.header("user-agent") orelse "";
    //     const origin = req.header("origin") orelse "";
    //     lg.access(req.method(), req.path(), res.status, res.bytes_written, client_ip, user_agent, origin);
    // }
    _ = req;
}

// curl usage: curl -X GET "http://localhost:9016/echo"
fn echoHandler(_: *zix.Http1.Request, res: *zix.Http1.Response, _: *zix.Http1.Context) !void {
    try res.sendJson("{\"status\":\"ok\"}");
}

// curl usage: curl -X GET "http://localhost:9016/about"
fn aboutHandler(_: *zix.Http1.Request, res: *zix.Http1.Response, _: *zix.Http1.Context) !void {
    res.setContentType(.TEXT_PLAIN);

    try res.send("zix http1 basic server example");
}

// --------------------------------------------------------- //

const Routes = zix.Http1.Router(&[_]zix.Http1.Route{
    .{ .path = "/", .handler = homeHandler },
    .{ .path = "/echo", .handler = echoHandler },
    .{ .path = "/about", .handler = aboutHandler },
});

pub fn main(process: std.process.Init) !void {
    // Uncomment to add logger (console only, no save_path means no file output):
    // var logger = try zix.Logger.init(std.heap.smp_allocator, .{
    //     .console           = .ALWAYS,
    //     .console_min_level = .INFO,
    // });
    // defer logger.deinit();
    // g_logger = &logger;

    // Uncomment to add logger with file output (createLogDir must run first):
    // createLogDir(process.io);
    // var logger = try zix.Logger.init(std.heap.smp_allocator, .{
    //     .save_path      = LOG_DIR,
    //     .save_file      = LOG_FILE,
    //     .save_min_level = .INFO,
    //     .console        = .ALWAYS,
    // });
    // defer logger.deinit();
    // g_logger = &logger;

    var server = zix.Http1.Server.init(Routes.dispatch, .{
        .io = process.io,
        .ip = IP,
        .port = PORT,
        .dispatch_model = DISPATCH_MODEL,
        .kernel_backlog = KERNEL_BACKLOG,
        .max_recv_buf = MAX_RECV_BUF,
        .compression_max_out = COMPRESSION_MAX_OUT,
        .workers = WORKERS,
        .pool_size = POOL_SIZE,
        // .logger = &logger, // uncomment to wire logger (server lifecycle lines)
    });
    defer server.deinit();

    try server.run();
}
