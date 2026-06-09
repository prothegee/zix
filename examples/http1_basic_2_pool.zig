const std = @import("std");
const zix = @import("zix");

const IP: []const u8 = "127.0.0.1";
const PORT: u16 = 9100;
const DISPATCH_MODEL: zix.Http1.DispatchModel = .POOL;
const KERNEL_BACKLOG: u31 = 1024;
const MAX_RECV_BUF: usize = 16 * 1024;
const MAX_GZIP_OUT: usize = 256 * 1024;
const MAX_HEADERS: u8 = 16;
const WORKERS: usize = 0; // 0 = cpu_count accept threads
const POOL_SIZE: usize = 0; // 0 = max(10, cpu_count * 2) pool threads

// Logger config, uncomment this section to add logger
// const LOG_DIR: []const u8  = "./logs";
// const LOG_FILE: []const u8 = "app";

// --------------------------------------------------------- //

// Optional global logger for handler-side access logging.
// The Http1 handler writes to the fd directly and returns void, so the server
// cannot observe response status or bytes. Handlers log via this global, where
// the final status and byte count are known. The server itself logs only
// lifecycle lines (listening) when config.logger is set.
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

// curl usage: curl -X GET "http://localhost:9100/"
fn homeHandler(head: *const zix.Http1.ParsedHead, body: []const u8, fd: std.posix.fd_t) void {
    _ = head;
    _ = body;
    zix.Http1.writeSimple(fd, 200, "text/plain", "Hello, World!") catch {};

    // Handler-side access logging (uncomment with g_logger above):
    // if (g_logger) |lg| {
    //     const ua = zix.Http1.getHeader(head, "user-agent") orelse "";
    //     const origin = zix.Http1.getHeader(head, "origin") orelse "";
    //     lg.access(head.method, head.path, 200, 0, ua, origin);
    // }
}

// curl usage: curl -X GET "http://localhost:9100/echo"
fn echoHandler(head: *const zix.Http1.ParsedHead, body: []const u8, fd: std.posix.fd_t) void {
    _ = head;
    _ = body;
    zix.Http1.writeJson(fd, 200, "{\"status\":\"ok\"}") catch {};
}

// curl usage: curl -X GET "http://localhost:9100/about"
fn aboutHandler(head: *const zix.Http1.ParsedHead, body: []const u8, fd: std.posix.fd_t) void {
    _ = head;
    _ = body;
    zix.Http1.writeSimple(fd, 200, "text/plain", "zix http1 basic server example") catch {};
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
        .max_gzip_out = MAX_GZIP_OUT,
        .max_headers = MAX_HEADERS,
        .workers = WORKERS,
        .pool_size = POOL_SIZE,
        // .logger = &logger, // uncomment to wire logger (server lifecycle lines)
    });
    defer server.deinit();

    try server.run();
}
