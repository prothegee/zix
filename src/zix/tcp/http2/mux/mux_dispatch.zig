//! ZIX Http2 mux mux_dispatch
//!
//! ### file: src/zix/tcp/http2/mux/mux_dispatch.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Hand a finished mux stream to its handler, and answer a peer that hangs up.
//!
//! ### note:
//!
//! - A handler runs inline on the worker, so it must stay bounded: every other
//!   connection on the worker waits while it runs.
//! - RFC 9113 section 8.1.1: a body short of (or past) its content-length is a
//!   malformed request. The stream is reset with PROTOCOL_ERROR before the
//!   handler, so a handler never sees a body that is not whole.
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
const cache = @import("../cache.zig");
const frame = @import("../frame.zig");
const handler = @import("../handler.zig");
const send_best_effort = @import("../send_best_effort.zig");
const send_stream = @import("send_stream.zig");
const stream_body = @import("../stream_body.zig");
const stream_invoke = @import("../stream_invoke.zig");
const MuxConn = @import("MuxConn.zig");

// --------------------------------------------------------- //
// Private:

/// Build the request and run the handler. The slot is freed afterwards unless
/// the response body is parked on a window.
fn dispatch(handler_fn: handler.HandlerFn, conn: *MuxConn, slot: usize) void {
    const stream = conn.streams[slot];
    var req = stream_invoke.buildRequest(stream.headerList(), stream.bodyBytes());

    // Only with a cache installed, so the default hot path pays no extra
    // threadlocal writes.
    if (cache.tl_cache != null) {
        cache.tl_req_path = req.path;
        cache.tl_req_body = req.body;
        cache.tl_req_io = conn.io;
    }

    send_stream.active_conn = conn;
    handler.invokeHandler(
        handler_fn,
        &req,
        conn.fd,
        stream.id,
        conn.io,
        conn.opts,
        conn.peer_max_frame_size,
    );
    send_stream.active_conn = null;

    if (!stream.isParked()) conn.releaseSlot(slot);
}

// --------------------------------------------------------- //
// Public:

/// Dispatch a stream whose END_STREAM has arrived, unless its body does not
/// match the content-length it declared. Then the stream is reset instead.
///
/// Param:
/// handler_fn - handler.HandlerFn (the route or top-level handler)
/// conn - *MuxConn (the connection owning the stream)
/// slot - usize (the stream's slot)
///
/// Return:
/// - void
pub fn dispatchWhole(handler_fn: handler.HandlerFn, conn: *MuxConn, slot: usize) void {
    const stream = conn.streams[slot];

    if (!stream_body.isWhole(stream.headerList(), stream.body_len)) {
        send_best_effort.rstStream(conn.fd, stream.id, frame.ERR_PROTOCOL_ERROR);
        conn.releaseSlot(slot);

        return;
    }

    dispatch(handler_fn, conn, slot);
}

/// What a peer gets when it hangs up part way through a request.
///
/// Note:
/// - A stream the peer opened and never ended gets GOAWAY PROTOCOL_ERROR. A
///   bare close would read the same as a crash or a dropped connection.
/// - A connection with no request in flight closes without a byte.
/// - Nothing is dispatched either way.
///
/// Param:
/// conn - *MuxConn (the connection whose peer just hung up)
///
/// Return:
/// - bool (true when a GOAWAY was written)
pub fn hangupGoaway(conn: *MuxConn) bool {
    if (!conn.requestInFlight()) return false;

    send_best_effort.goaway(conn.fd, conn.last_stream_id, frame.ERR_PROTOCOL_ERROR);

    return true;
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const builtin = @import("builtin");
const pair = @import("../../../utils/socket/pair.zig");
const Context = @import("../Context.zig");
const Request = @import("../Request.zig");
const Response = @import("../Response.zig");
const ServeOpts = @import("../ServeOpts.zig");

const TEST_OPTS: ServeOpts = .{
    .max_streams = 4,
    .max_body = 64,
    .max_header_scratch = 64,
};

threadlocal var tl_calls: usize = 0;
threadlocal var tl_saw_active_conn: bool = false;

fn probeHandler(_: *Request, res: *Response, _: *Context) anyerror!void {
    tl_calls += 1;
    tl_saw_active_conn = send_stream.active_conn != null;

    try res.sendText("ok");
}

/// Answers through the flow-controlled sender, so a tiny window parks it.
fn parkHandler(_: *Request, res: *Response, _: *Context) anyerror!void {
    tl_calls += 1;

    send_stream.sendResponseStreamFD(res.fd, res.sid, 200, "text/plain", "", "parked body");
}

fn isLinux() bool {
    if (comptime builtin.target.os.tag == .linux) return true;

    std.log.info("this test drives a Linux socket pair, test skipped", .{});

    return false;
}

/// Open a stream that has received its whole request.
fn openEnded(conn: *MuxConn, content_length: ?[]const u8, body: []const u8) usize {
    const slot = conn.claimSlot(1).?;
    const stream = conn.streams[slot];

    stream.headers[0] = .{
        .name = ":method",
        .value = "POST",
    };
    stream.headers[1] = .{
        .name = ":path",
        .value = "/",
    };
    stream.header_count = 2;
    if (content_length) |value| {
        stream.headers[2] = .{
            .name = "content-length",
            .value = value,
        };
        stream.header_count = 3;
    }

    _ = stream.appendBody(body);
    stream.end_headers = true;
    stream.end_stream = true;

    return slot;
}

/// First RST_STREAM error code on the wire, or null.
fn readRstCode(client_fd: std.posix.fd_t, server_fd: std.posix.fd_t) ?u32 {
    _ = std.os.linux.shutdown(server_fd, std.os.linux.SHUT.WR);

    var buf: [1024]u8 = undefined;
    var total: usize = 0;
    while (total < buf.len) {
        const got = std.posix.read(client_fd, buf[total..]) catch break;
        if (got == 0) break;

        total += got;
    }

    var pos: usize = 0;
    while (pos + frame.FRAME_HEADER_LEN <= total) {
        const header = frame.parseFrameHeader(buf[pos..][0..frame.FRAME_HEADER_LEN]);
        pos += frame.FRAME_HEADER_LEN;

        if (header.frame_type == frame.FRAME_TYPE_RST_STREAM) {
            return std.mem.readInt(u32, buf[pos..][0..4], .big);
        }

        pos += header.length;
    }

    return null;
}

test "zix http2 mux: mux_dispatch, a whole request reaches the handler" {
    if (!isLinux()) return;

    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    const conn = try MuxConn.init(fds[1], TEST_OPTS, std.testing.io);
    defer conn.deinit();

    const slot = openEnded(conn, "4", "abcd");

    tl_calls = 0;
    dispatchWhole(probeHandler, conn, slot);

    try std.testing.expectEqual(@as(usize, 1), tl_calls);
    try std.testing.expect(tl_saw_active_conn);
    try std.testing.expect(send_stream.active_conn == null);
    try std.testing.expect(conn.findSlot(1) == null);
}

test "zix http2 mux: mux_dispatch, a short body is reset before the handler" {
    if (!isLinux()) return;

    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    const conn = try MuxConn.init(fds[1], TEST_OPTS, std.testing.io);
    defer conn.deinit();

    const slot = openEnded(conn, "100", "abcd");

    tl_calls = 0;
    dispatchWhole(probeHandler, conn, slot);

    try std.testing.expectEqual(@as(usize, 0), tl_calls);
    try std.testing.expect(conn.findSlot(1) == null);
    try std.testing.expectEqual(
        @as(?u32, frame.ERR_PROTOCOL_ERROR),
        readRstCode(fds[0], fds[1]),
    );
}

test "zix http2 mux: mux_dispatch, a parked response keeps its slot" {
    if (!isLinux()) return;

    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    const conn = try MuxConn.init(fds[1], TEST_OPTS, std.testing.io);
    defer conn.deinit();

    conn.send_window = 4;
    const slot = openEnded(conn, null, "");

    tl_calls = 0;
    dispatchWhole(parkHandler, conn, slot);

    try std.testing.expectEqual(@as(usize, 1), tl_calls);
    try std.testing.expect(conn.slots[slot]);
    try std.testing.expect(conn.streams[slot].isParked());
}

test "zix http2 mux: mux_dispatch, hangupGoaway with a request in flight sends GOAWAY" {
    if (!isLinux()) return;

    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    const conn = try MuxConn.init(fds[1], TEST_OPTS, std.testing.io);
    defer conn.deinit();

    _ = conn.claimSlot(1).?;

    try std.testing.expect(hangupGoaway(conn));

    var head: [frame.FRAME_HEADER_LEN]u8 = undefined;
    _ = try std.posix.read(fds[0], &head);

    const header = frame.parseFrameHeader(&head);

    try std.testing.expectEqual(frame.FRAME_TYPE_GOAWAY, header.frame_type);
}

test "zix http2 mux: mux_dispatch, hangupGoaway on an idle connection sends nothing" {
    const conn = try MuxConn.init(undefined, TEST_OPTS, std.testing.io);
    defer conn.deinit();

    try std.testing.expect(!hangupGoaway(conn));
}

test "zix http2 mux: mux_dispatch, a parked stream is not a request in flight" {
    const conn = try MuxConn.init(undefined, TEST_OPTS, std.testing.io);
    defer conn.deinit();

    const slot = conn.claimSlot(1).?;
    conn.streams[slot].end_stream = true;
    conn.streams[slot].pending_body = "owed";

    try std.testing.expect(!hangupGoaway(conn));
}

