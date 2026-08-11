//! localbench: zix-gateway backend
//!
//! The origin behind the zixer edge. Cleartext zix.Http1 (.URING) on a private
//! port, Router-only, one handler module per route (src/handlers/). zixer
//! terminates TLS and h2 on 8443 and re-originates http1 here.
//!
//! Note:
//! - No public_dir. /static is answered by the edge from its own public_dir,
//!   so a static request never reaches this process.
//! - The port is private to the stack and matches upstreams in
//!   sites/gateway.cfg. It sits in the 189xx band, clear of the ephemeral
//!   range a client could otherwise be holding.

const std = @import("std");
const zix = @import("zix");

const baseline = @import("handlers/baseline.zig");
const json = @import("handlers/json.zig");
const asyncdb = @import("handlers/asyncdb.zig");

const dbpg = @import("shared/dbpg.zig");

// --------------------------------------------------------- //

const Routes = zix.Http1.Router(&[_]zix.Http1.Route{
    .{ .path = baseline.PATH, .handler = baseline.RESPONSE },
    .{ .path = asyncdb.PATH, .handler = asyncdb.RESPONSE },
    .{ .path = json.PATH, .handler = json.RESPONSE, .kind = .PREFIX },
});

pub fn main(process: std.process.Init) !void {
    // DB endpoints: lanes open lazily per engine worker once DATABASE_URL is
    // present (non-DB profiles open nothing, DB routes answer 503).
    dbpg.init(process);
    dbpg.start();

    // Park ring sized to peak conns per worker: 16384c is the deepest
    // scenario and workers = 0 spawns one worker per CPU.
    const cpus = std.Thread.getCpuCount() catch 8;
    const park_len = @max(512, 16 * 1024 / cpus);

    var server = zix.Http1.Server.init(Routes.dispatch, .{
        .io = process.io,
        .ip = "127.0.0.1",
        .port = 18962,
        .workers = 0,
        .dispatch_model = .URING,
        //
        .send_date_header = false,
        .max_response_headers = .{ .CUSTOM = 8 },
        //
        .kernel_backlog = 16 * 1024,
        .max_recv_buf = 8 * 1024,
        //
        .uring_send_buf_size = 16 * 1024,
        .uring_idle_pool_floor = 16,
        .uring_idle_pool_ceiling = 1 * 1024,
        .process_queue_len = park_len,
    });
    defer server.deinit();

    try server.run();
}
