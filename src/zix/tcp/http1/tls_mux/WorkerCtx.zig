//! ZIX http1 tls mux worker context
//!
//! ### file: src/zix/tcp/http1/tls_mux/WorkerCtx.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! One TLS mux worker setup, passed by value to the spawned thread.
//!
//! ### note:
//!
//! n/a
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
const tlz = @import("tlz");
const Config = @import("../Config.zig");
const HandlerFn = @import("../handler.zig").HandlerFn;

// --------------------------------------------------------- //
// Fields:

config: Config,
handler: HandlerFn,
/// Borrowed identity, must outlive the worker.
ctx: *const tlz.Context,
/// Bound before the spawn, owned by the worker from then on.
listener: std.Io.net.Server,
/// Which core to pin to.
worker_id: usize,
/// Set by any worker to stop the group.
stop: *std.atomic.Value(bool),
/// Set when a worker could not finish its setup.
failed: *std.atomic.Value(bool),

const Self = @This();

// --------------------------------------------------------- //
// Public:

/// Mark the group failed and ask every worker to stop.
pub fn failSetup(self: *const Self) void {
    self.failed.store(true, .release);
    self.stop.store(true, .release);
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "zix http1: WorkerCtx, failSetup stops the group" {
    var stop = std.atomic.Value(bool).init(false);
    var failed = std.atomic.Value(bool).init(false);
    var ctx: tlz.Context = undefined;
    const worker: Self = .{
        .config = undefined,
        .handler = undefined,
        .ctx = &ctx,
        .listener = undefined,
        .worker_id = 0,
        .stop = &stop,
        .failed = &failed,
    };

    worker.failSetup();

    try std.testing.expect(stop.load(.acquire));
    try std.testing.expect(failed.load(.acquire));
}

