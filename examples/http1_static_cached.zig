//! ZIX example http1 static cached
//!
//! ### file: examples/http1_static_cached.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Http1 server example that serves public_dir through the static cache, with
//! Range and precompressed siblings.
//!
//! ### note:
//!
//! Only "/" is routed. Every other path falls through to the static fallback,
//! which is where the cache lives.
//! The .br and .gz siblings hold plain text on purpose: the example shows which
//! file is picked and which Content-Encoding is sent, not real compression.
//!
//! ---------------------------------------------------------
//!
//! ### licenses:
//!
//! - BSD-3-Clause
//!
//! ### copyright:
//!
//! - (c) Prana Ron // @prothegee // prothegee@pm.me
//!
//! ### contributors:
//!
//! - Prana Ron // @prothegee // prothegee@pm.me
//!

const std = @import("std");
const zix = @import("zix");

const builtin = @import("builtin");

// --------------------------------------------------------- //

const IP:[]const u8 = "127.0.0.1";
const PORT:u16 = 9039;
const WORKERS:usize = 0;
const KERNEL_BACKLOG:u31 = 1024;
const MAX_RECV_BUF:usize = 16 * 1024;
const DISPATCH_MODEL:zix.Http1.DispatchModel =
    if (builtin.os.tag == .linux) .URING else .ASYNC;

const PUBLIC_DIR:[]const u8 = "./public-cached";

/// 0 (the default) re-opens the file on every request. Above 0 the file stays
/// open and its header is prerendered. Past this window an entry is re-opened,
/// so an edited file shows up without a restart.
const PUBLIC_DIR_CACHE_TTL_MS:u32 = 5_000;

/// One entry per file, holding the file and its .br and .gz siblings. Rounded
/// down to a power of two and capped by the descriptor budget. A full table
/// serves uncached, never an error.
const PUBLIC_DIR_CACHE_MAX_ENTRIES:u32 = 64;

// --------------------------------------------------------- //

fn writeDemoFile(io: std.Io, path: []const u8, data: []const u8) void {
    std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = path,
        .data = data,
    }) catch |err| switch (err) {
        else => std.log.warn("could not seed {s}: {s}", .{
            path,
            @errorName(err),
        }),
    };
}

fn seedDemoFiles(io: std.Io) void {
    std.Io.Dir.cwd().createDirPath(io, PUBLIC_DIR) catch |err| switch (err) {
        else => std.log.warn("could not create {s}: {s}", .{
            PUBLIC_DIR,
            @errorName(err),
        }),
    };

    writeDemoFile(io, PUBLIC_DIR ++ "/hello.txt", "served from public_dir, cached open file\n");
    writeDemoFile(io, PUBLIC_DIR ++ "/app.js", "console.log('identity build');\n");
    writeDemoFile(io, PUBLIC_DIR ++ "/app.js.br", "pretend-brotli\n");
    writeDemoFile(io, PUBLIC_DIR ++ "/app.js.gz", "pretend-gzip\n");
}

// GET /
// curl usage: curl "http://localhost:9039/"
fn homeHandler(_: *zix.Http1.Request, res: *zix.Http1.Response, _: *zix.Http1.Context) !void {
    res.setContentType(.TEXT_PLAIN);

    try res.send("try /hello.txt and /app.js\n");
}

// --------------------------------------------------------- //

// curl usage:
// curl -i "http://localhost:9039/hello.txt"                          (200)
// curl -i "http://localhost:9039/hello.txt" -H "Range: bytes=0-6"    (206)
// curl -i "http://localhost:9039/hello.txt" -H "Range: bytes=999-"   (416)
// curl -i "http://localhost:9039/app.js" -H "Accept-Encoding: br"    (Content-Encoding: br)
// curl -i "http://localhost:9039/app.js" -H "Accept-Encoding: gzip"  (Content-Encoding: gzip)
// curl -i "http://localhost:9039/app.js"                             (no Content-Encoding)
// curl -i "http://localhost:9039/absent.txt"                         (404)
const Routes = zix.Http1.Router(&[_]zix.Http1.Route{
    .{
        .path = "/",
        .handler = homeHandler,
    },
});

pub fn main(init: std.process.Init) !void {
    seedDemoFiles(init.io);

    var server = zix.Http1.Server.init(Routes.dispatch, .{
        .io = init.io,
        .ip = IP,
        .port = PORT,
        .workers = WORKERS,
        .kernel_backlog = KERNEL_BACKLOG,
        .max_recv_buf = MAX_RECV_BUF,
        .dispatch_model = DISPATCH_MODEL,
        .public_dir = PUBLIC_DIR,
        .public_dir_cache_ttl_ms = PUBLIC_DIR_CACHE_TTL_MS,
        .public_dir_cache_max_entries = PUBLIC_DIR_CACHE_MAX_ENTRIES,
    });
    defer server.deinit();

    try server.run();
}

