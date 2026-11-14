//! ZIX http1 tls mux connection
//!
//! ### file: src/zix/tcp/http1/tls_mux/TlsConn.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! One https/1.1 connection on a multiplexed worker: the TLS transport plus
//! the request buffer and the WebSocket mode.
//!
//! ### note:
//!
//! One worker owns a connection for its whole lifetime (shared-nothing).
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
const tls_conn = @import("../../../multiplexers/tls_conn.zig");
const tls_feed = @import("../tls_feed.zig");
const HandlerFn = @import("../handler.zig").HandlerFn;
const WsFrameFn = @import("../websocket/frame_fn.zig").WsFrameFn;
const TlsPeers = @import("../TlsPeers.zig");

// --------------------------------------------------------- //
// Fields:

/// Session plus staged outbound ciphertext.
transport: tls_conn.Transport,
handler: HandlerFn,
/// Borrowed identity, also checked against the Host header (421).
ctx: *const tlz.Context,
io: std.Io,
/// Declared bodies past this are refused with 413. 0 removes the check.
max_request_body: usize = 0,
/// Set once a handler hands the connection to WebSocket. From then on the
/// decrypted bytes are frames, not requests.
ws: ?WsFrameFn = null,
/// Partial and pipelined request bytes, live in rbuf[0..feed.filled]. Frame
/// bytes use the same buffer after an upgrade.
rbuf: [REQUEST_BUF_SIZE]u8 = undefined,
/// How much is buffered, and whether a body is being counted off the wire.
feed: tls_feed.State = .{},

const Self = @This();

// --------------------------------------------------------- //
// Private:

/// Per-connection request buffer: the largest request head over TLS.
const REQUEST_BUF_SIZE: usize = 17 * 1024;

const allocator = std.heap.smp_allocator;

// --------------------------------------------------------- //
// Public:

/// Allocate a connection for an accepted, non-blocking socket.
///
/// Return:
/// - *Self
/// - null when out of memory
pub fn create(
    io: std.Io,
    fd: std.posix.fd_t,
    handler: HandlerFn,
    ctx: *const tlz.Context,
    max_request_body: usize,
) ?*Self {
    const conn = allocator.create(Self) catch |err| switch (err) {
        error.OutOfMemory => return null,
    };
    // A TLS socket from now on: no write to fd may go out as plaintext.
    TlsPeers.shared.mark(fd);

    conn.* = .{
        .transport = tls_conn.Transport.init(io, fd, ctx),
        .handler = handler,
        .ctx = ctx,
        .io = io,
        .max_request_body = max_request_body,
    };

    return conn;
}

/// Free the staged ciphertext and the connection itself. Does not close fd.
///
/// Note:
/// - Leaves the TLS peer registry first, which waits out a write in progress
///   from another thread.
pub fn destroy(self: *Self) void {
    TlsPeers.shared.unregister(self.transport.fd);
    self.transport.deinit();
    allocator.destroy(self);
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

fn testHandler(
    _: *@import("../Request.zig"),
    _: *@import("../Response.zig"),
    _: *@import("../Context.zig"),
) anyerror!void {}

test "zix http1: TlsConn, create starts with an empty feed" {
    var ctx: tlz.Context = undefined;
    ctx.cert_der = &.{};
    ctx.signing_key = .{ .rsa = .{} };
    ctx.alpn = &.{};

    const conn = create(std.testing.io, 7, testHandler, &ctx, 4096) orelse {
        return error.ZixTest_OutOfMemory;
    };
    defer conn.destroy();

    try std.testing.expectEqual(@as(std.posix.fd_t, 7), conn.transport.fd);
    try std.testing.expectEqual(@as(usize, 0), conn.feed.filled);
    try std.testing.expectEqual(@as(usize, 4096), conn.max_request_body);
    try std.testing.expect(conn.ws == null);
}

test "zix http1: TlsConn, rbuf holds one full TLS record of plaintext" {
    try std.testing.expect(REQUEST_BUF_SIZE >= tlz.MAX_PLAINTEXT);
}

