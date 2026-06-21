const std = @import("std");
const zix = @import("zix");

const IP: []const u8 = "127.0.0.1";
const PORT: u16 = 9001;
const DISPATCH_MODEL: zix.Tcp.DispatchModel = .POOL;
const KERNEL_BACKLOG: usize = 1024 * 4;
const MAX_RECV_BUF: usize = 1024 * 4;
const MAX_ALLOCATOR_SIZE: usize = 1024 * 4;
const MAX_CLIENT_RESPONSE: usize = 1024 * 4;
const WORKERS: usize = 0; // 0 = auto (cpu_count accept threads)
const POOL_SIZE: usize = 0; // 0 = auto (cpu_count * 20 pool threads)

// Logger config: uncomment this section to add logger
// const LOG_DIR: []const u8  = "./logs";
// const LOG_FILE: []const u8 = "app";

// --------------------------------------------------------- //

// Creates the log directory at startup.
// The logger does not create save_path automatically, that is the caller's responsibility.
// Silently ignores "already exists", safe to call on every start.
// Similar pattern to createInitDirs in http_static.zig.
//
// fn createLogDir(io: std.Io) void {
//     std.Io.Dir.cwd().createDirPath(io, LOG_DIR) catch {};
// }

// --------------------------------------------------------- //

// curl usage: curl -X GET "http://localhost:9001/"
pub fn homeHandler(req: *zix.Http.Request, res: *zix.Http.Response, ctx: *zix.Http.Context) !void {
    _ = req;
    _ = ctx;
    // res.setContentType(.TEXT_PLAIN); // need apple to apple?
    try res.send("Hello, World!");
}

// curl usage: curl -X GET "http://localhost:9001/echo"
pub fn echoHandler(req: *zix.Http.Request, res: *zix.Http.Response, ctx: *zix.Http.Context) !void {
    _ = req;
    _ = ctx;
    res.setContentType(.APPLICATION_JSON);
    res.setKeepAlive(true);
    try res.addHeader("Content-Security-Policy", "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; frame-ancestors 'none'");
    try res.addHeader("X-Content-Type-Options", "nosniff");
    try res.addHeader("X-Frame-Options", "DENY");
    try res.addHeader("Referrer-Policy", "strict-origin-when-cross-origin");
    try res.send("{\"status\":\"ok\"}");
}

// curl usage: curl -X GET "http://localhost:9001/about"
pub fn aboutHandler(req: *zix.Http.Request, res: *zix.Http.Response, ctx: *zix.Http.Context) !void {
    _ = req;
    _ = ctx;
    try res.send("zix basic server example");
}

// --------------------------------------------------------- //

const Routes = [_]zix.Http.Route{
    .{ .path = "/", .handler = homeHandler },
    .{ .path = "/echo", .handler = echoHandler },
    .{ .path = "/about", .handler = aboutHandler },
};

pub fn main(process: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();

    // Uncomment this to add logger (console only, no save_path means no file output):
    // var logger = try zix.Logger.init(arena.allocator(), .{
    //     .console        = .ALWAYS,
    //     .console_min_level = .INFO,
    // });
    // defer logger.deinit();

    // Uncomment this to add logger with file output (createLogDir must run first):
    // createLogDir(process.io);
    // var logger = try zix.Logger.init(arena.allocator(), .{
    //     .save_path      = LOG_DIR,
    //     .save_file      = LOG_FILE,
    //     .save_min_level = .INFO,
    //     .console        = .ALWAYS,
    // });
    // defer logger.deinit();

    var server = try zix.Http.Server.init(4096, &Routes, .{
        .io = process.io,
        .ip = IP,
        .port = PORT,
        .dispatch_model = DISPATCH_MODEL,
        .kernel_backlog = KERNEL_BACKLOG,
        .max_recv_buf = MAX_RECV_BUF,
        .max_allocator_size = MAX_ALLOCATOR_SIZE,
        .max_client_response = MAX_CLIENT_RESPONSE,
        .workers = WORKERS,
        .pool_size = POOL_SIZE,
        // .logger = &logger, // uncomment to wire logger (automatic HTTP access logging)
    });
    defer server.deinit();

    try server.run();
}
