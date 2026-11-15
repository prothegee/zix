//! ZIX http2 grpc tls mux accept options
//!
//! ### file: src/zix/tcp/http2/grpc/tls_mux/AcceptOpts.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! What every connection accepted on a gRPC TLS listener is given: io,
//! identity, mux limits, and the epoll data tag.
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
const ServeOpts = @import("../ServeOpts.zig");
const tls_conn = @import("../../../../multiplexers/tls_conn.zig");

// --------------------------------------------------------- //
// Fields:

io: std.Io,
/// Borrowed identity, must outlive every connection.
ctx: *const tlz.Context,
/// Mux limits of every accepted connection.
opts: ServeOpts,
/// Or-ed into the epoll data word. 0 for a TLS-only worker,
/// tls_conn.TLS_EVENT_TAG for a dual-listener loop.
ev_tag: u64,

const Self = @This();

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "zix http2 grpc: AcceptOpts, a dual-listener tag sits above any fd" {
    var ctx: tlz.Context = undefined;
    const opts: Self = .{
        .io = std.testing.io,
        .ctx = &ctx,
        .opts = .{},
        .ev_tag = tls_conn.TLS_EVENT_TAG,
    };

    try std.testing.expect(opts.ev_tag > std.math.maxInt(u31));
}

test "zix http2 grpc: AcceptOpts, a TLS-only worker uses tag 0" {
    var ctx: tlz.Context = undefined;
    const opts: Self = .{
        .io = std.testing.io,
        .ctx = &ctx,
        .opts = .{
            .max_streams = 16,
        },
        .ev_tag = 0,
    };

    try std.testing.expectEqual(@as(u64, 0), opts.ev_tag);
    try std.testing.expectEqual(@as(usize, 16), opts.opts.max_streams);
}

