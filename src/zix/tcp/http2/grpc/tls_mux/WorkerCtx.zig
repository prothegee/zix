//! ZIX http2 grpc tls mux worker context
//!
//! ### file: src/zix/tcp/http2/grpc/tls_mux/WorkerCtx.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! One gRPC TLS mux worker setup, passed by value to the spawned thread.
//!
//! ### note:
//!
//! The Router is not a field: it is a comptime type, bound by the worker
//! entry in tls_mux.zig.
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
const ServeOpts = @import("../ServeOpts.zig");

// --------------------------------------------------------- //
// Fields:

io: std.Io,
opts: ServeOpts,
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

test "zix http2 grpc: WorkerCtx, failSetup stops the group" {
    var stop = std.atomic.Value(bool).init(false);
    var failed = std.atomic.Value(bool).init(false);
    var ctx: tlz.Context = undefined;
    const worker: Self = .{
        .io = std.testing.io,
        .opts = .{},
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

test "zix http2 grpc: WorkerCtx, failSetup twice keeps the group stopped" {
    var stop = std.atomic.Value(bool).init(false);
    var failed = std.atomic.Value(bool).init(false);
    var ctx: tlz.Context = undefined;
    const worker: Self = .{
        .io = std.testing.io,
        .opts = .{},
        .ctx = &ctx,
        .listener = undefined,
        .worker_id = 1,
        .stop = &stop,
        .failed = &failed,
    };

    worker.failSetup();
    worker.failSetup();

    try std.testing.expect(stop.load(.acquire));
    try std.testing.expect(failed.load(.acquire));
}

