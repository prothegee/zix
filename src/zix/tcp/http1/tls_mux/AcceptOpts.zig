//! ZIX http1 tls mux accept options
//!
//! ### file: src/zix/tcp/http1/tls_mux/AcceptOpts.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! What every connection accepted on a TLS listener is given: io, handler,
//! identity, body limit, and the epoll data tag.
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
const HandlerFn = @import("../handler.zig").HandlerFn;
const tls_conn = @import("../../../multiplexers/tls_conn.zig");

// --------------------------------------------------------- //
// Fields:

io: std.Io,
handler: HandlerFn,
/// Borrowed identity, must outlive every connection.
ctx: *const tlz.Context,
/// Declared bodies past this are refused with 413. 0 removes the check.
max_request_body: usize,
/// Or-ed into the epoll data word. 0 for a TLS-only worker,
/// tls_conn.TLS_EVENT_TAG for a dual-listener loop.
ev_tag: u64,

const Self = @This();

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "zix http1: AcceptOpts, a dual-listener tag sits above any fd" {
    var ctx: tlz.Context = undefined;
    const opts: Self = .{
        .io = std.testing.io,
        .handler = undefined,
        .ctx = &ctx,
        .max_request_body = 0,
        .ev_tag = tls_conn.TLS_EVENT_TAG,
    };

    try std.testing.expect(opts.ev_tag > std.math.maxInt(u31));
}

test "zix http1: AcceptOpts, a TLS-only worker uses tag 0" {
    var ctx: tlz.Context = undefined;
    const opts: Self = .{
        .io = std.testing.io,
        .handler = undefined,
        .ctx = &ctx,
        .max_request_body = 1024,
        .ev_tag = 0,
    };

    try std.testing.expectEqual(@as(u64, 0), opts.ev_tag);
    try std.testing.expectEqual(@as(usize, 1024), opts.max_request_body);
}

