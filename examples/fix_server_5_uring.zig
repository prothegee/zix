const std = @import("std");
const zix = @import("zix");

const IP: []const u8 = "0.0.0.0";
const PORT: u16 = 9501;
const COMP_ID: []const u8 = "ZIX";
const DISPATCH_MODEL: zix.Fix.DispatchModel = .URING;
const WORKERS: usize = 0; // 0 = cpu_count ring workers (each owns its own listener + ring)
const POOL_SIZE: usize = 0; // ignored by URING

// --------------------------------------------------------- //

// Note:
// .URING is Linux-only (ADR-037 Phase 4 extension). It drives many FIX sessions
// on one io_uring completion loop per worker: recv into a buffer, run the
// resumable FIX session processor (core.processFixRing) over the buffered
// messages, and send one coalesced reply per readable batch. Shared-nothing: one
// SO_REUSEPORT listener and one ring per worker.
//
// Reactive session only: Logon, application routing/echo, Heartbeat/TestRequest
// replies, and Logout are served on the ring. The proactive idle-heartbeat timer
// (server-initiated TestRequest/Logout on silence) is not driven on the ring yet
// (it needs an io_uring timeout SQE); use .EPOLL/.POOL/.ASYNC when that matters.
// On non-Linux targets .URING falls back to .POOL automatically.

// --------------------------------------------------------- //

pub fn main(process: std.process.Init) !void {
    var server = try zix.Fix.Server.init(&.{}, .{
        .io = process.io,
        .ip = IP,
        .port = PORT,
        .comp_id = COMP_ID,
        .dispatch_model = DISPATCH_MODEL,
        .workers = WORKERS,
        .pool_size = POOL_SIZE,
    });
    defer server.deinit();

    try server.run();
}
