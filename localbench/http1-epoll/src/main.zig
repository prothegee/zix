//! localbench: zix
//!
//! zix.Http1 (.EPOLL), Router-only: every request goes through the engine's
//! parser and the comptime Router, one handler module per route
//! (src/handlers/). TLS rides tls_port (dual listener, one worker fleet).
//! /static is served by the engine from public_dir. async-db and crud run
//! over engine-worker lanes (dbpg.zig): each worker owns a pipelined postgres
//! connection it pumps itself. crud reads also check the in-process cache
//! (crudcache.zig).

const std = @import("std");
const zix = @import("zix");

const baseline = @import("handlers/baseline.zig");
const pipeline = @import("handlers/pipeline.zig");
const upload = @import("handlers/upload.zig");
const json = @import("handlers/json.zig");
const asyncdb = @import("handlers/asyncdb.zig");
const crud = @import("handlers/crud.zig");

const dbpg = @import("shared/dbpg.zig");
const paths = @import("shared/paths.zig");

// --------------------------------------------------------- //

const Routes = zix.Http1.Router(&[_]zix.Http1.Route{
    .{ .path = baseline.PATH, .handler = baseline.RESPONSE },
    .{ .path = pipeline.PATH, .handler = pipeline.RESPONSE },
    .{ .path = upload.PATH, .handler = upload.RESPONSE },
    .{ .path = asyncdb.PATH, .handler = asyncdb.RESPONSE },
    .{ .path = json.PATH, .handler = json.RESPONSE, .kind = .PREFIX },
    .{ .path = crud.PATH, .handler = crud.RESPONSE, .kind = .PREFIX },
});

pub fn main(process: std.process.Init) !void {
    var tls_alloc = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer tls_alloc.deinit();

    // Fixture root, the HttpArena data dir. /static resolves under it through
    // public_dir below.
    // DB endpoints: lanes open lazily per engine worker once DATABASE_URL is
    // present (non-DB profiles open nothing, DB routes answer 503).
    dbpg.init(process);
    dbpg.start();

    var tls = zix.Tls.Context.init(tls_alloc.allocator(), process.io, .{
        .cert_path = paths.TLS_CERT,
        .key_path = paths.TLS_KEY,
        .alpn = &.{.HTTP_1_1},
        .min_version = .TLS_1_3,
    }) catch |e| {
        return e;
    };

    var server = zix.Http1.Server.init(Routes.dispatch, .{
        .io = process.io,
        .ip = "::",
        .port = 8080,
        .workers = 0,
        .dispatch_model = .EPOLL,
        .tls = &tls,
        .tls_port = 8081,
        //
        .send_date_header = false,
        .max_response_headers = .{ .CUSTOM = 8 },
        //
        .compress = true,
        //
        .public_dir = paths.DATA_DIR,
        .public_dir_cache_ttl_ms = 30 * 1000,
        //
        .kernel_backlog = 16 * 1024,
        .max_recv_buf = 8 * 1024,
        .max_request_body = 24 * 1024 * 1024,
    });
    defer server.deinit();

    try server.run();
}
