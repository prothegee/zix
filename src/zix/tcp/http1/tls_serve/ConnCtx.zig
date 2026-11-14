//! ZIX http1 tls serve connection context
//!
//! ### file: src/zix/tcp/http1/tls_serve/ConnCtx.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! What one https/1.1 connection task needs: the accepted stream, the handler,
//! the TLS context, and the per-request knobs.
//!
//! ### note:
//!
//! The context, handler, and logger are borrowed and must outlive the task.
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
const Logger = @import("../../../logger/Logger.zig");

// --------------------------------------------------------- //
// Fields:

stream: std.Io.net.Stream,
handler: HandlerFn,
ctx: *const tlz.Context,
io: std.Io,
public_dir: []const u8 = "",
max_response_headers: usize = 16,
/// Declared bodies past this are refused with 413 before a byte is read. 0 removes the check.
max_request_body: usize = 0,
send_date_header: bool = true,
/// A failed handshake is logged here at DEBUG, so it is not just a closed socket.
logger: ?*Logger = null,

const Self = @This();

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

fn testHandler(
    _: *@import("../Request.zig"),
    _: *@import("../Response.zig"),
    _: *@import("../Context.zig"),
) anyerror!void {}

test "zix http1: ConnCtx, defaults keep the body limit off" {
    var ctx: tlz.Context = undefined;
    const conn: Self = .{
        .stream = undefined,
        .handler = testHandler,
        .ctx = &ctx,
        .io = std.testing.io,
    };

    try std.testing.expectEqual(@as(usize, 0), conn.max_request_body);
    try std.testing.expect(conn.logger == null);
}

test "zix http1: ConnCtx, keeps the knobs it is given" {
    var ctx: tlz.Context = undefined;
    const conn: Self = .{
        .stream = undefined,
        .handler = testHandler,
        .ctx = &ctx,
        .io = std.testing.io,
        .public_dir = "public",
        .max_request_body = 8192,
        .send_date_header = false,
    };

    try std.testing.expectEqualStrings("public", conn.public_dir);
    try std.testing.expectEqual(@as(usize, 8192), conn.max_request_body);
    try std.testing.expect(!conn.send_date_header);
}

