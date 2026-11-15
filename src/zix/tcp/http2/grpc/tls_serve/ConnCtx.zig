//! ZIX http2 grpc tls serve connection context
//!
//! ### file: src/zix/tcp/http2/grpc/tls_serve/ConnCtx.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Inputs of one gRPC over TLS connection task: the accepted stream, the
//! identity, io, and the serve options.
//!
//! ### note:
//!
//! The Router is not a field: it is a comptime type, bound by the task entry
//! in tls_serve.zig.
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

/// The accepted connection, closed by the task.
stream: std.Io.net.Stream,
/// Borrowed identity, must outlive the task.
ctx: *const tlz.Context,
io: std.Io,
/// Mux limits and the logger of this connection.
opts: ServeOpts,

const Self = @This();

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "zix http2 grpc: ConnCtx, keeps the serve options" {
    var ctx: tlz.Context = undefined;
    const conn_ctx: Self = .{
        .stream = undefined,
        .ctx = &ctx,
        .io = std.testing.io,
        .opts = .{
            .max_streams = 8,
        },
    };

    try std.testing.expectEqual(@as(usize, 8), conn_ctx.opts.max_streams);
    try std.testing.expect(conn_ctx.opts.logger == null);
}

test "zix http2 grpc: ConnCtx, borrows the identity" {
    var ctx: tlz.Context = undefined;
    const conn_ctx: Self = .{
        .stream = undefined,
        .ctx = &ctx,
        .io = std.testing.io,
        .opts = .{},
    };

    try std.testing.expect(conn_ctx.ctx == &ctx);
}

