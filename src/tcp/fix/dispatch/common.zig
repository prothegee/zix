//! zix fix dispatch: helpers shared across the dispatch models (ADR-043).
//! dispatchConn / ConnTask are the route-agnostic per-connection primitive used
//! by every model (routes ride inside the runtime FixServeOpts).

const std = @import("std");
const builtin = @import("builtin");
const core = @import("../core.zig");
const FixServerConfig = @import("../config.zig").FixServerConfig;
const FixServeOpts = core.FixServeOpts;

/// Emit a server lifecycle line. Routes through cfg.logger when present.
/// Without a logger it prints to stderr only in Debug builds (silent in release).
pub fn logSystem(cfg: FixServerConfig, comptime fmt: []const u8, args: anytype) void {
    if (cfg.logger) |lg| {
        lg.system(.INFO, "fix", fmt, args);
        return;
    }

    if (comptime builtin.mode == .Debug) std.debug.print("zix fix: " ++ fmt ++ "\n", args);
}

/// Max epoll events drained per epoll_wait call. 512 lets a worker clear its
/// ready-fd set in one syscall at high connection counts.
pub const EPOLL_MAX_EVENTS: usize = 512;

// --------------------------------------------------------- //

pub const ConnTask = struct {
    stream: std.Io.net.Stream,
    io: std.Io,
    comp_id: []const u8,
    opts: FixServeOpts,
};

pub fn dispatchConn(task: ConnTask) void {
    core.serveConn(task.stream, task.io, task.comp_id, task.opts) catch {};
}
