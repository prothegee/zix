const std = @import("std");
const zix = @import("zix");

const IP: []const u8 = "127.0.0.1";
const PORT: u16 = 9110;
const DISPATCH_MODEL: zix.Http1.DispatchModel = .POOL;
const KERNEL_BACKLOG: u31 = 1024;
const MAX_RECV_BUF: usize = 16 * 1024;
const MAX_GZIP_OUT: usize = 256 * 1024;
const MAX_HEADERS: u8 = 16;
const WORKERS: usize = 0; // 0 = cpu_count accept threads
const POOL_SIZE: usize = 0; // 0 = max(10, cpu_count * 2) pool threads

// Per-handler execution budget. The server arms a thread-local deadline before
// each dispatch. Handlers opt in by calling zix.Http1.isExpired() between steps
// and responding with 408 early.
const HANDLER_TIMEOUT_MS: u32 = 5_000;

// The Http1 handler signature has no io param, so the simulated work reaches the
// io backend (for sleeping) through this global. Set once in main.
var g_io: std.Io = undefined;

// --------------------------------------------------------- //

// Simulates a slow two-step handler (3s + 3s = 6s total).
// With HANDLER_TIMEOUT_MS = 5s, step 2 trips the deadline check.
//
// curl usage: curl http://localhost:9110/slow
fn slowHandler(head: *const zix.Http1.ParsedHead, body: []const u8, fd: std.posix.fd_t) void {
    _ = head;
    _ = body;

    // Step 1: 3s of simulated work.
    std.Io.sleep(g_io, std.Io.Duration.fromMilliseconds(3_000), .awake) catch {};
    if (zix.Http1.isExpired()) {
        zix.Http1.writeJson(fd, 408, "{\"error\":\"timeout\",\"step\":1}") catch {};
        return;
    }

    // Step 2: 3s more (total 6s > 5s budget).
    std.Io.sleep(g_io, std.Io.Duration.fromMilliseconds(3_000), .awake) catch {};
    if (zix.Http1.isExpired()) {
        zix.Http1.writeJson(fd, 408, "{\"error\":\"timeout\",\"step\":2}") catch {};
        return;
    }

    zix.Http1.writeJson(fd, 200, "{\"result\":\"ok\"}") catch {};
}

// Demonstrates zix.Http1.setTimeout(): the handler overrides the server-wide
// budget to give itself a shorter 2s window regardless of the global 5s.
//
// curl usage: curl http://localhost:9110/custom
fn customTimeoutHandler(head: *const zix.Http1.ParsedHead, body: []const u8, fd: std.posix.fd_t) void {
    _ = head;
    _ = body;

    zix.Http1.setTimeout(2_000);

    std.Io.sleep(g_io, std.Io.Duration.fromMilliseconds(1_500), .awake) catch {};
    if (zix.Http1.isExpired()) {
        zix.Http1.writeJson(fd, 408, "{\"error\":\"timeout\",\"handler\":\"custom\"}") catch {};
        return;
    }

    zix.Http1.writeJson(fd, 200, "{\"result\":\"ok\",\"handler\":\"custom\"}") catch {};
}

// Fast handler to confirm unrelated requests are served normally.
//
// curl usage: curl http://localhost:9110/ping
fn pingHandler(head: *const zix.Http1.ParsedHead, body: []const u8, fd: std.posix.fd_t) void {
    _ = head;
    _ = body;
    zix.Http1.writeJson(fd, 200, "{\"result\":\"pong\"}") catch {};
}

// --------------------------------------------------------- //

const Routes = zix.Http1.Router(&[_]zix.Http1.Route{
    .{ .path = "/slow", .handler = slowHandler },
    .{ .path = "/custom", .handler = customTimeoutHandler },
    .{ .path = "/ping", .handler = pingHandler },
});

pub fn main(process: std.process.Init) !void {
    g_io = process.io;

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
        .handler_timeout_ms = HANDLER_TIMEOUT_MS,
    });
    defer server.deinit();

    try server.run();
}
