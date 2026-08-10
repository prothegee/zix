const std = @import("std");
const builtin = @import("builtin");
const zix = @import("zix");

const IP: []const u8 = "0.0.0.0";
const PORT: u16 = 9048;
const COMP_ID: []const u8 = "ZIX";
// Pick the model per target at comptime (ADR-065): .URING is the Linux shared-nothing
// completion loop, .ASYNC the portable model. .EPOLL and .URING are Linux-only, and run()
// returns error.ZixDispatchModelUnsupported rather than silently serving a different model.
const DISPATCH_MODEL: zix.Fix.DispatchModel = if (builtin.os.tag == .linux) .URING else .ASYNC;
const WORKERS: usize = 0; // 0 = cpu_count workers under .EPOLL / .URING, ignored by .ASYNC

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
// (it needs an io_uring timeout SQE). Use .EPOLL or .ASYNC when that matters.
//
// .ASYNC serves one session per async task and is the only model available on every
// platform.

// --------------------------------------------------------- //

pub fn main(process: std.process.Init) !void {
    var server = try zix.Fix.Server.init(null, .{
        .io = process.io,
        .ip = IP,
        .port = PORT,
        .comp_id = COMP_ID,
        .dispatch_model = DISPATCH_MODEL,
        .workers = WORKERS,
    });
    defer server.deinit();

    try server.run();
}
