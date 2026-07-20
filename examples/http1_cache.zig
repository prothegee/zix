const std = @import("std");
const zix = @import("zix");

const IP: []const u8 = "127.0.0.1";
// Unique port (feature examples each own one so a test-runner can spawn them
// without colliding with the basic dispatch-model examples on 9031).
const PORT: u16 = 9031;
// Flip to .EPOLL to compare the cache effect across dispatch models.
const DISPATCH_MODEL: zix.Http1.DispatchModel = .URING;
const WORKERS: usize = 0; // 0 = cpu_count

// --------------------------------------------------------- //

// Note:
// Demonstrates the per-worker response cache (ADR-036) under the .URING (and
// .EPOLL) dispatch model. Two endpoints serve an identical, configurably sized
// JSON body so the only difference is whether the cache is used:
//   GET /cache?kb=N    cache-aware: a hit replays the stored bytes, a miss
//                      builds the response once and stores it.
//   GET /nocache?kb=N  always rebuilds and serializes, never cached.
//   GET /              trivial "Hello, World!".
// A/B /cache vs /nocache at a given kb isolates the cache's effect. The cache
// pays once the build-and-serialize cost passes the crossover (a few KiB).

// Per-worker scratch. Thread-local so each worker owns its own buffers and the
// handlers stay allocation-free.
threadlocal var body_buf: [128 * 1024]u8 = undefined;
threadlocal var resp_buf: [160 * 1024]u8 = undefined;

/// Build an approximately kb-KiB JSON array into body_buf and return the slice.
fn buildBody(kb: usize) []const u8 {
    const target = @min(kb * 1024, body_buf.len - 64);

    var pos: usize = 0;
    body_buf[pos] = '[';
    pos += 1;
    var i: usize = 0;
    while (pos < target) : (i += 1) {
        const chunk = std.fmt.bufPrint(body_buf[pos..], "{{\"id\":{d},\"name\":\"item-{d}\",\"ok\":true}},", .{ i, i }) catch break;
        pos += chunk.len;
    }
    if (pos > 1 and body_buf[pos - 1] == ',') pos -= 1;
    body_buf[pos] = ']';
    pos += 1;

    return body_buf[0..pos];
}

fn kbFromQuery(req: *zix.Http1.Request) usize {
    const value = req.queryParam("kb") orelse return 32;

    return std.fmt.parseInt(usize, value, 10) catch 32;
}

/// Build a full HTTP/1.1 200 response (header + body) into resp_buf.
fn buildResponse(body: []const u8) []const u8 {
    const hdr = std.fmt.bufPrint(&resp_buf, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\n\r\n", .{body.len}) catch return "";
    @memcpy(resp_buf[hdr.len..][0..body.len], body);

    return resp_buf[0 .. hdr.len + body.len];
}

// curl usage: curl "http://localhost:9031/cache?kb=32"
fn cacheHandler(req: *zix.Http1.Request, res: *zix.Http1.Response, _: *zix.Http1.Context) !void {
    if (zix.Http1.cacheLookup(req.head)) |cached| {
        try res.sendRaw(cached);
        return;
    }

    const built = buildBody(kbFromQuery(req));
    const resp = buildResponse(built);
    zix.Http1.sendWithCacheFD(req.fd, req.head, resp, zix.Http1.cacheTtl()) catch {};
}

// curl usage: curl "http://localhost:9031/nocache?kb=32"
fn nocacheHandler(req: *zix.Http1.Request, res: *zix.Http1.Response, _: *zix.Http1.Context) !void {
    const built = buildBody(kbFromQuery(req));
    const resp = buildResponse(built);

    try res.sendRaw(resp);
}

// curl usage: curl "http://localhost:9031/"
fn homeHandler(_: *zix.Http1.Request, res: *zix.Http1.Response, _: *zix.Http1.Context) !void {
    res.setContentType(.TEXT_PLAIN);

    try res.send("Hello, World!");
}

// --------------------------------------------------------- //

const Routes = zix.Http1.Router(&[_]zix.Http1.Route{
    .{ .path = "/", .handler = homeHandler },
    .{ .path = "/cache", .handler = cacheHandler },
    .{ .path = "/nocache", .handler = nocacheHandler },
});

pub fn main(process: std.process.Init) !void {
    var server = zix.Http1.Server.init(Routes.dispatch, .{
        .io = process.io,
        .ip = IP,
        .port = PORT,
        .dispatch_model = DISPATCH_MODEL,
        .workers = WORKERS,
        // Hold responses up to ~128 KiB so the heavy bodies are cacheable
        // (the default cap is lean and would bypass them).
        .response_cache = true,
        .cache_max_entries = 64,
        .cache_max_value_bytes = 128 * 1024,
        .cache_ttl_ms = 60 * 1000,
    });
    defer server.deinit();

    try server.run();
}
