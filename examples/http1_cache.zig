//! ZIX example http1 cache
//!
//! ### file: examples/http1_cache.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Http1 server example that serves a JSON body through the response cache.
//!
//! ### note:
//!
//! The cache is per worker (.URING, .EPOLL) or per io pool thread (.ASYNC).
//! /cache and /nocache build the same body, so the only difference is the
//! cache. A request on another worker or thread can miss once.
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
const PORT:u16 = 9031;
const WORKERS:usize = 0;
const DISPATCH_MODEL:zix.Http1.DispatchModel =
    if (builtin.os.tag == .linux) .URING else .ASYNC;
const CACHE_MAX_ENTRIES:u32 = 64;
const CACHE_MAX_VALUE_BYTES:u32 = 128 * 1024;
const CACHE_TTL_MS:u32 = 60 * 1000;
const DEFAULT_KB:usize = 32;

// --------------------------------------------------------- //

/// Per thread scratch, so the handlers do not allocate.
threadlocal var body_buf: [128 * 1024]u8 = undefined;

/// Build a JSON array of about kb KiB into body_buf.
fn buildBody(kb: usize) []const u8 {
    const target = @min(kb * 1024, body_buf.len - 64);

    var pos: usize = 0;
    body_buf[pos] = '[';
    pos += 1;

    var index: usize = 0;
    while (pos < target) : (index += 1) {
        const item = std.fmt.bufPrint(
            body_buf[pos..],
            "{{\"id\":{d},\"name\":\"item-{d}\",\"ok\":true}},",
            .{
                index,
                index,
            },
        ) catch |err| switch (err) {
            // The scratch is full, close the array with what fits.
            else => break,
        };
        pos += item.len;
    }

    if (pos > 1 and body_buf[pos - 1] == ',') pos -= 1;

    body_buf[pos] = ']';
    pos += 1;

    return body_buf[0..pos];
}

/// Read ?kb=N, or DEFAULT_KB when it is missing or not a number.
fn kbFromQuery(req: *zix.Http1.Request) usize {
    const value = req.queryParam("kb") orelse return DEFAULT_KB;

    return std.fmt.parseInt(usize, value, 10) catch |err| switch (err) {
        else => DEFAULT_KB,
    };
}

// GET /cache?kb=N
// A hit replays the stored bytes. A miss builds the body once and stores it.
// curl usage: curl "http://localhost:9031/cache?kb=32"
fn cacheHandler(req: *zix.Http1.Request, res: *zix.Http1.Response, _: *zix.Http1.Context) !void {
    if (try res.sendFromCache(req)) return;

    const body = buildBody(kbFromQuery(req));
    res.setContentType(.APPLICATION_JSON);

    try res.sendCached(req, body, CACHE_TTL_MS);
}

// GET /nocache?kb=N
// Always builds the body, never cached.
// curl usage: curl "http://localhost:9031/nocache?kb=32"
fn nocacheHandler(
    req: *zix.Http1.Request,
    res: *zix.Http1.Response,
    _: *zix.Http1.Context,
) !void {
    const body = buildBody(kbFromQuery(req));

    try res.sendJson(body);
}

// GET /
// curl usage: curl "http://localhost:9031/"
fn homeHandler(_: *zix.Http1.Request, res: *zix.Http1.Response, _: *zix.Http1.Context) !void {
    res.setContentType(.TEXT_PLAIN);

    try res.send("Hello, World!");
}

// --------------------------------------------------------- //

const Routes = zix.Http1.Router(&[_]zix.Http1.Route{
    .{
        .path = "/",
        .handler = homeHandler,
    },
    .{
        .path = "/cache",
        .handler = cacheHandler,
    },
    .{
        .path = "/nocache",
        .handler = nocacheHandler,
    },
});

pub fn main(init: std.process.Init) !void {
    var server = zix.Http1.Server.init(Routes.dispatch, .{
        .io = init.io,
        .ip = IP,
        .port = PORT,
        .workers = WORKERS,
        .dispatch_model = DISPATCH_MODEL,
        .response_cache = true,
        .cache_max_entries = CACHE_MAX_ENTRIES,
        .cache_max_value_bytes = CACHE_MAX_VALUE_BYTES,
        .cache_ttl_ms = CACHE_TTL_MS,
    });
    defer server.deinit();

    try server.run();
}

