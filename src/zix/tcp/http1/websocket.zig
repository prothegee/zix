//! ZIX http1 websocket
//!
//! ### file: src/zix/tcp/http1/websocket.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Public WebSocket namespace, exported as zix.Http1.WebSocket. Holds serve,
//! which completes the handshake and hands the connection to the engine.
//!
//! ### note:
//!
//! serve only asks for the promotion. The engine runs the frame loop after
//! the handler returns: .EPOLL and .URING from their event loop, .ASYNC with
//! the blocking loop.
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
const frame = @import("websocket/frame.zig");
const upgrade_mod = @import("websocket/upgrade.zig");
const pending = @import("websocket/pending.zig");
const send = @import("websocket/send.zig");
const pump_mod = @import("websocket/pump.zig");
const writer = @import("writer.zig");

// --------------------------------------------------------- //
// Private:

fn upgradeError(err: upgrade_mod.Error) Error {
    @branchHint(.cold);

    return switch (err) {
        error.ZixHttp1_WebSocketUpgrade_NoSpaceLeft => Error.ZixHttp1_WebSocket_NoSpaceLeft,
        error.ZixHttp1_WebSocketUpgrade_BrokenPipe => Error.ZixHttp1_WebSocket_BrokenPipe,
        error.ZixHttp1_WebSocketUpgrade_HeadBuild => Error.ZixHttp1_WebSocket_HeadBuild,
    };
}

// --------------------------------------------------------- //
// Public:

/// ZIX Http1 WebSocket error
pub const Error = error {
    ZixHttp1_WebSocket_KeyTooLong,
    ZixHttp1_WebSocket_NoSpaceLeft,
    ZixHttp1_WebSocket_BrokenPipe,
    ZixHttp1_WebSocket_HeadBuild,
};

pub const Opcode = @import("websocket/opcode.zig").Opcode;
pub const WsFrameFn = @import("websocket/frame_fn.zig").WsFrameFn;
pub const Frame = @import("websocket/WsFrame.zig");
pub const ParseResult = @import("websocket/WsParseResult.zig");
pub const PumpResult = @import("websocket/WsPumpResult.zig");
pub const RingPumpResult = @import("websocket/WsRingPumpResult.zig");

pub const parseFrame = frame.parseFrame;
pub const buildHeader = frame.buildHeader;
pub const buildFrame = frame.buildFrame;
pub const acceptKey = frame.acceptKey;
pub const upgrade = upgrade_mod.upgrade;
pub const sendFD = send.sendFD;
pub const broadcast = send.broadcast;
pub const pump = pump_mod.pump;
pub const pumpRing = pump_mod.pumpRing;
pub const serveBlocking = pump_mod.serveBlocking;

/// Complete the handshake, then hand the connection to the engine. After the
/// handler returns, the engine calls on_frame for each text or binary frame.
/// Ping is auto-ponged and close is auto-echoed.
///
/// Note:
/// - Read every path and query param before this call. After the handler
///   returns, the connection is a raw WebSocket stream.
/// - Works on .ASYNC, .EPOLL, and .URING.
///
/// Param:
/// fd - std.posix.fd_t (req.fd)
/// key - []const u8 (the Sec-WebSocket-Key request header value)
/// on_frame - WsFrameFn
///
/// Return:
/// - void
/// - error.ZixHttp1_WebSocket_KeyTooLong when the key does not fit
/// - error.ZixHttp1_WebSocket_BrokenPipe when the 101 write fails
pub fn serve(fd: std.posix.fd_t, key: []const u8, on_frame: WsFrameFn) Error!void {
    var accept_buf: [64]u8 = undefined;
    const accept = frame.acceptKey(key, &accept_buf) catch |err| switch (err) {
        error.ZixHttp1_WebSocketFrame_KeyTooLong => {
            return Error.ZixHttp1_WebSocket_KeyTooLong;
        },
    };

    upgrade_mod.upgrade(fd, accept) catch |err| return upgradeError(err);

    pending.request(fd, on_frame);
}

/// Complete the handshake over TLS, then hand the connection to the https
/// serve loop. Streaming variant of serve for a handler served over TLS
/// (config.tls). serve works over TLS too, this one sends the 101 right away.
///
/// Note:
/// - Detaches the buffered response capture first, so the 101 and every frame
///   leave sealed through the TLS stream sink.
/// - broadcast works over TLS: each member frame is sealed with that member
///   session, under its lock.
///
/// Param:
/// fd - std.posix.fd_t (req.fd)
/// key - []const u8 (the Sec-WebSocket-Key request header value)
/// on_frame - WsFrameFn
///
/// Return:
/// - void
/// - error.ZixHttp1_WebSocket_KeyTooLong when the key does not fit
/// - error.ZixHttp1_WebSocket_BrokenPipe when the 101 write fails
pub fn serveTls(fd: std.posix.fd_t, key: []const u8, on_frame: WsFrameFn) Error!void {
    var accept_buf: [64]u8 = undefined;
    const accept = frame.acceptKey(key, &accept_buf) catch |err| switch (err) {
        error.ZixHttp1_WebSocketFrame_KeyTooLong => {
            return Error.ZixHttp1_WebSocket_KeyTooLong;
        },
    };

    writer.beginStream();
    upgrade_mod.upgrade(fd, accept) catch |err| return upgradeError(err);

    pending.request(fd, on_frame);
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const pair = @import("../../utils/socket/pair.zig");
const reader = @import("reader.zig");

fn testOnFrame(_: std.posix.fd_t, _: u8, _: []const u8) void {}

const TlsStreamSink = @import("TlsStreamSink.zig");

const CaptureStream = struct {
    buf: [512]u8 = undefined,
    len: usize = 0,

    fn write(ctx: *anyopaque, plaintext: []const u8) bool {
        const self: *CaptureStream = @ptrCast(@alignCast(ctx));
        if (self.len + plaintext.len > self.buf.len) return false;

        @memcpy(self.buf[self.len..][0..plaintext.len], plaintext);
        self.len += plaintext.len;

        return true;
    }

    fn refuse(_: *anyopaque, _: []const u8) bool {
        return false;
    }
};

test "zix http1: websocket, serve writes 101 and asks for the promotion" {
    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    _ = pending.take();
    try serve(fds[0], "dGhlIHNhbXBsZSBub25jZQ==", testOnFrame);

    var out: [256]u8 = undefined;
    const len = try reader.readOnceFD(fds[1], &out);
    const taken = pending.take().?;

    try std.testing.expect(std.mem.startsWith(u8, out[0..len], "HTTP/1.1 101"));
    try std.testing.expect(
        std.mem.indexOf(u8, out[0..len], "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=") != null,
    );
    try std.testing.expectEqual(fds[0], taken.fd);
}

test "zix http1: websocket, serve rejects a key too long" {
    const key: [128]u8 = @splat('k');

    _ = pending.take();

    try std.testing.expectError(
        Error.ZixHttp1_WebSocket_KeyTooLong,
        serve(-1, &key, testOnFrame),
    );
    try std.testing.expect(pending.take() == null);
}

test "zix http1: websocket, serve does not promote after a failed write" {
    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    _ = std.posix.system.close(fds[1]);

    _ = pending.take();

    try std.testing.expectError(
        Error.ZixHttp1_WebSocket_BrokenPipe,
        serve(fds[0], "dGhlIHNhbXBsZSBub25jZQ==", testOnFrame),
    );
    try std.testing.expect(pending.take() == null);
}

test "zix http1: websocket, serveTls sends the 101 through the TLS stream" {
    var capture: CaptureStream = .{};
    var stream: TlsStreamSink = .{
        .ctx = &capture,
        .writeFn = CaptureStream.write,
        .fd = -1,
    };
    writer.tl_tls_stream = &stream;
    defer writer.tl_tls_stream = null;

    _ = pending.take();
    try serveTls(-1, "dGhlIHNhbXBsZSBub25jZQ==", testOnFrame);

    const wire = capture.buf[0..capture.len];
    try std.testing.expect(std.mem.indexOf(u8, wire, "101 Switching Protocols") != null);
    try std.testing.expect(std.mem.indexOf(u8, wire, "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=") != null);
    try std.testing.expect(pending.take() != null);
}

test "zix http1: websocket, serveTls does not promote after a refused write" {
    var capture: CaptureStream = .{};
    var stream: TlsStreamSink = .{
        .ctx = &capture,
        .writeFn = CaptureStream.refuse,
        .fd = -1,
    };
    writer.tl_tls_stream = &stream;
    defer writer.tl_tls_stream = null;

    _ = pending.take();

    try std.testing.expectError(
        Error.ZixHttp1_WebSocket_BrokenPipe,
        serveTls(-1, "dGhlIHNhbXBsZSBub25jZQ==", testOnFrame),
    );
    try std.testing.expect(pending.take() == null);
}

test "zix http1: websocket, serveTls rejects a key too long" {
    const key: [128]u8 = @splat('k');

    _ = pending.take();

    try std.testing.expectError(
        Error.ZixHttp1_WebSocket_KeyTooLong,
        serveTls(-1, &key, testOnFrame),
    );
}

