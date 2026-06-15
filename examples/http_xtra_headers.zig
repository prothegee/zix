const std = @import("std");
const zix = @import("zix");

const IP: []const u8 = "127.0.0.1";
const PORT: u16 = 9009;
const DISPATCH_MODEL: zix.Http.DispatchModel = .POOL;
const KERNEL_BACKLOG: usize = 1024 * 4;
const MAX_RECV_BUF: usize = 1024 * 4;
const MAX_ALLOCATOR_SIZE: usize = 1024 * 4;
const MAX_CLIENT_RESPONSE: usize = 1024 * 4;
const WORKERS: usize = 0; // 0 = auto (cpu_count accept threads)
const POOL_SIZE: usize = 0; // 0 = auto (max(10, cpu_count * 2) pool threads)

// --------------------------------------------------------- //
// This example demonstrates zix.Http.HeaderSize: the configurable
// cap on how many custom response headers addHeader() will accept.
//
// The cap is set once at HttpServer.init() via max_response_headers.
// All handlers share the same cap for the lifetime of the server.
//
// Available tiers (see docs/headers.md for selection guidance):
//
//   .MINIMAL     - 16   simple APIs, constrained environments
//   .COMMON      - 32   default, most web apps, single proxy
//   .LARGE       - 64   CDN + proxy, load balancers
//   .EXTRA_LARGE - 128  k8s, service mesh, heavy CORS/forwarding stacks
//   .CUSTOM(N)   - N    explicit non-standard cap
//
// This server runs with .LARGE (64) so handlers can add up to 64 headers.
// --------------------------------------------------------- //

// GET /info
// Returns a JSON body with several custom headers attached:
// X-Server, X-Version, Cache-Control, Vary, X-Frame-Options, X-Content-Type-Options
pub fn infoHandler(req: *zix.Http.Request, res: *zix.Http.Response, ctx: *zix.Http.Context) !void {
    _ = req;
    _ = ctx;

    try res.addHeader("X-Server", "zix");
    try res.addHeader("X-Version", "0.1.0");
    try res.addHeader("Cache-Control", "no-store");
    try res.addHeader("Vary", "Accept-Encoding");
    try res.addHeader("X-Frame-Options", "DENY");
    try res.addHeader("X-Content-Type-Options", "nosniff");

    try res.sendJson("{\"status\":\"ok\",\"note\":\"6 headers added\"}");
}

// GET /cors
// Demonstrates a CORS preflight-style response with multiple headers.
pub fn corsHandler(req: *zix.Http.Request, res: *zix.Http.Response, ctx: *zix.Http.Context) !void {
    _ = req;
    _ = ctx;

    try res.addHeader("Access-Control-Allow-Origin", "*");
    try res.addHeader("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS");
    try res.addHeader("Access-Control-Allow-Headers", "Content-Type, Authorization, X-Request-ID");
    try res.addHeader("Access-Control-Max-Age", "86400");
    try res.addHeader("Vary", "Origin");

    try res.sendJson("{\"status\":\"ok\",\"note\":\"5 CORS headers added\"}");
}

// GET /overflow
// Intentionally attempts to add more headers than the cap allows.
// With .large (64), this would require > 64 calls to trigger.
// Here we use a small local cap to demonstrate the error path clearly.
//
// In practice, addHeader() returns error.TooManyHeaders when the cap is
// reached. Handlers should propagate or handle it, returning the error
// here surfaces it as a 500 to the client.
pub fn overflowHandler(req: *zix.Http.Request, res: *zix.Http.Response, ctx: *zix.Http.Context) !void {
    _ = req;
    // _ = ctx;

    // We have .large = 64 slots on this server.
    // Add 64 headers to exhaust the cap, then one more to demonstrate the error.
    var i: usize = 0;
    var name_buf: [32]u8 = undefined;
    var val_buf: [32]u8 = undefined;

    while (i < 64) : (i += 1) {
        const name = try std.fmt.bufPrint(&name_buf, "X-Header-{d}", .{i});
        const val = try std.fmt.bufPrint(&val_buf, "{d}", .{i});
        try res.addHeader(name, val);
    }

    // 65th call: returns error.TooManyHeaders
    res.addHeader("X-One-Too-Many", "overflow") catch |err| {
        res.setStatus(.INTERNAL_SERVER_ERROR);
        const msg = try std.fmt.allocPrint(ctx.allocator, "{{\"error\":\"{s}\",\"note\":\"cap is 64\"}}", .{@errorName(err)});
        try res.sendJson(msg);
        return;
    };

    // Unreachable with .large cap and 64 prior addHeader() calls
    try res.sendJson("{\"status\":\"ok\"}");
}

// GET /inject-guard
// Demonstrates the header injection guard: CR or LF in name or value
// is rejected by addHeader() before writing to the wire.
pub fn injectGuardHandler(req: *zix.Http.Request, res: *zix.Http.Response, ctx: *zix.Http.Context) !void {
    _ = req;
    // _ = ctx;

    // Attempt to inject via value, rejected by the \r\n guard
    res.addHeader("X-Safe", "legit\r\nX-Injected: attack") catch |err| {
        const msg = try std.fmt.allocPrint(
            ctx.allocator,
            "{{\"error\":\"{s}\",\"note\":\"CR/LF in header value rejected\"}}",
            .{@errorName(err)},
        );
        try res.sendJson(msg);
        return;
    };

    try res.sendJson("{\"status\":\"ok\"}");
}

// --------------------------------------------------------- //

const Routes = [_]zix.Http.Route{
    .{ .path = "/info", .handler = infoHandler },
    .{ .path = "/cors", .handler = corsHandler },
    .{ .path = "/overflow", .handler = overflowHandler },
    .{ .path = "/inject-guard", .handler = injectGuardHandler },
};

pub fn main(process: std.process.Init) !void {
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
        // .LARGE = 64 custom headers per response.
        // Use .MINIMAL (16) for APIs that never add extra headers.
        // Use .EXTRA_LARGE (128) for k8s / service-mesh deployments.
        // Use .{ .CUSTOM = N } for an explicit non-standard cap.
        .max_response_headers = .LARGE,
    });
    defer server.deinit();

    try server.run();
}
