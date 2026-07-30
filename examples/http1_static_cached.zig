const std = @import("std");
const builtin = @import("builtin");
const zix = @import("zix");

const IP: []const u8 = "127.0.0.1";
const PORT: u16 = 9077;
// Pick the model per target at comptime (ADR-065): .URING is the Linux shared-nothing
// completion loop, .ASYNC the portable model. .EPOLL and .URING are Linux-only, and run()
// returns error.DispatchModelUnsupported rather than silently serving a different model.
const DISPATCH_MODEL: zix.Http1.DispatchModel = if (builtin.os.tag == .linux) .URING else .ASYNC;
const KERNEL_BACKLOG: u31 = 1024;
const MAX_RECV_BUF: usize = 16 * 1024;
const WORKERS: usize = 0; // 0 = one worker per cpu

const PUBLIC_DIR = "./public-cached";

// The two knobs this example is about.
//
// public_dir_cache_ttl_ms: 0 (the default) keeps the original behaviour, where every request
// re-opens and re-reads the file. Above 0 the resolved file is kept open and its response header
// prerendered, so a repeat request costs a hash lookup instead of an open plus a stat.
//
// The same value is also the staleness window: an entry past it becomes a miss, and the miss
// re-opens and re-stats, so a file edited on disk shows up within one window with no restart.
const PUBLIC_DIR_CACHE_TTL_MS: u32 = 5_000;

// One slot per file, holding the plain file and its .br / .gz siblings. Rounded down to a power of
// two and clamped against the process descriptor budget, so an over-generous value cannot starve
// the server of descriptors for its sockets. A full table serves the request uncached, never an error.
const PUBLIC_DIR_CACHE_MAX_ENTRIES: u32 = 64;

// --------------------------------------------------------- //

fn seedDemoFiles(io: std.Io) void {
    std.Io.Dir.cwd().createDirPath(io, PUBLIC_DIR) catch {};

    writeFile(io, PUBLIC_DIR ++ "/hello.txt", "served from public_dir, cached open file\n");

    // A precompressed sibling pair. The engine picks one from Accept-Encoding, resolved once when
    // the entry is built, so no per-request probing happens for either name.
    //
    // These stand in for real brotli and gzip output: this example is about which file gets picked
    // and which Content-Encoding is emitted, so the bytes themselves are plain text on purpose.
    writeFile(io, PUBLIC_DIR ++ "/app.js", "console.log('identity build');\n");
    writeFile(io, PUBLIC_DIR ++ "/app.js.br", "pretend-brotli\n");
    writeFile(io, PUBLIC_DIR ++ "/app.js.gz", "pretend-gzip\n");
}

fn writeFile(io: std.Io, path: []const u8, data: []const u8) void {
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data }) catch {};
}

// --------------------------------------------------------- //

// GET /
// curl usage: curl -X GET "http://localhost:9077/"
fn homeHandler(_: *zix.Http1.Request, res: *zix.Http1.Response, _: *zix.Http1.Context) !void {
    res.setContentType(.TEXT_PLAIN);

    try res.send("try /hello.txt and /app.js\n");
}

// --------------------------------------------------------- //

// Only "/" is routed. Everything else falls through to the engine static fallback, which is where
// the cache lives.
//
// curl usage:
// curl -i "http://localhost:9077/hello.txt"                              (200, plain)
// curl -i "http://localhost:9077/hello.txt" -H "Range: bytes=0-6"        (206, from the same open file)
// curl -i "http://localhost:9077/app.js" -H "Accept-Encoding: br"        (200, Content-Encoding: br)
// curl -i "http://localhost:9077/app.js" -H "Accept-Encoding: gzip"      (200, Content-Encoding: gzip)
// curl -i "http://localhost:9077/app.js"                                 (200, no Content-Encoding)
// curl -i "http://localhost:9077/absent.txt"                             (404)
const Router = zix.Http1.Router(&[_]zix.Http1.Route{
    .{ .path = "/", .handler = homeHandler },
});

pub fn main(process: std.process.Init) !void {
    seedDemoFiles(process.io);

    var server = zix.Http1.Server.init(Router.dispatch, .{
        .io = process.io,
        .ip = IP,
        .port = PORT,
        .dispatch_model = DISPATCH_MODEL,
        .kernel_backlog = KERNEL_BACKLOG,
        .max_recv_buf = MAX_RECV_BUF,
        .workers = WORKERS,
        .public_dir = PUBLIC_DIR,
        .public_dir_cache_ttl_ms = PUBLIC_DIR_CACHE_TTL_MS,
        .public_dir_cache_max_entries = PUBLIC_DIR_CACHE_MAX_ENTRIES,
    });
    defer server.deinit();

    try server.run();
}
