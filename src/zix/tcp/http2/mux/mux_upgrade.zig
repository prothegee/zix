//! ZIX Http2 mux mux_upgrade
//!
//! ### file: src/zix/tcp/http2/mux/mux_upgrade.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! The HTTP/1.1 h2c upgrade on a mux connection: answer 101, await the preface,
//! then answer the upgrade request as stream 1.
//!
//! ### note:
//!
//! - Stream 1 is opened before the 101 (RFC 7540 section 3.2), but answered only
//!   after the preface, since the server SETTINGS frame must go first.
//! - The method and target are copied into the stream scratch: the read buffer
//!   holding the head is reused once it is consumed.
//! - Same request as the blocking serve path: :method, :path, :scheme, no body.
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
const handler = @import("../handler.zig");
const mux_dispatch = @import("mux_dispatch.zig");
const peer_settings = @import("../peer_settings.zig");
const upgrade = @import("../upgrade.zig");
const writer = @import("../writer.zig");
const ConnOutcome = @import("conn_outcome.zig").ConnOutcome;
const MuxConn = @import("MuxConn.zig");
const UpgradeHead = @import("../UpgradeHead.zig");

// --------------------------------------------------------- //
// Private:

/// Decoded HTTP2-Settings scratch on an h2c upgrade.
const SETTINGS_DECODE_SCRATCH: usize = 256;

/// Stream id the upgrade request is answered on (RFC 7540 section 3.2).
const UPGRADE_STREAM_ID: u31 = 1;

/// Write an HTTP/1.1 reply, best effort.
fn reply(fd: std.posix.fd_t, bytes: []const u8) void {
    writer.writeAllFD(fd, bytes) catch |err| switch (err) {
        // Best effort: a broken socket shows up on the next read.
        error.ZixHttp2_Writer_BrokenPipe,
        error.ZixHttp2_Writer_UnexpectedEOF,
        error.ZixHttp2_Writer_Overflow,
        error.ZixHttp2_Writer_BufferFull,
        => {},
    };
}

/// Open stream 1 with the upgrade request, its strings copied into the
/// stream scratch.
///
/// Return:
/// - ?usize (the slot, null when no slot is free or the strings do not fit)
fn openUpgradeStream(conn: *MuxConn, head: UpgradeHead) ?usize {
    const slot = conn.claimSlot(UPGRADE_STREAM_ID) orelse return null;
    const stream = conn.streams[slot];
    const scratch = stream.header_scratch;
    const path_start = head.method.len;
    const path_end = path_start + head.path.len;

    if (path_end > scratch.len) {
        conn.releaseSlot(slot);

        return null;
    }

    @memcpy(scratch[0..path_start], head.method);
    @memcpy(scratch[path_start..path_end], head.path);

    stream.headers[0] = .{
        .name = ":method",
        .value = scratch[0..path_start],
    };
    stream.headers[1] = .{
        .name = ":path",
        .value = scratch[path_start..path_end],
    };
    stream.headers[2] = .{
        .name = ":scheme",
        .value = "http",
    };
    stream.header_count = 3;
    stream.end_headers = true;
    stream.end_stream = true;
    stream.state = .HALF_CLOSED_REMOTE;

    return slot;
}

// --------------------------------------------------------- //
// Public:

/// Read the buffered HTTP/1.1 head and answer it.
///
/// Note:
/// - An h2c head opens stream 1 and applies its HTTP2-Settings before the 101.
///   serveUpgradeStream answers stream 1 once the preface is accepted.
///
/// Param:
/// conn - *MuxConn (a connection in the await_upgrade phase)
///
/// Return:
/// - .keep_alive when the head is not complete yet, or after 101
/// - .close when the head fills the buffer, or after 400 for a non-h2c request
///   or a request line that does not fit the stream scratch
pub fn handleUpgrade(conn: *MuxConn) ConnOutcome {
    const buf = conn.buffered();

    const marker = std.mem.indexOf(u8, buf, upgrade.HEAD_END) orelse {
        if (conn.rend == conn.rbuf.len) return .close;

        return .keep_alive;
    };
    const head_bytes = buf[0 .. marker + upgrade.HEAD_END.len];

    if (!upgrade.isH2cUpgrade(head_bytes)) {
        reply(conn.fd, upgrade.BAD_REQUEST);

        return .close;
    }

    var settings_buf: [SETTINGS_DECODE_SCRATCH]u8 = undefined;
    const head = upgrade.parseHead(head_bytes, &settings_buf);

    const initial_window = peer_settings.apply(
        head.settings,
        &conn.hpack_dec,
        &conn.peer_max_frame_size,
    );
    if (initial_window) |value| conn.setPeerInitialWindow(value);

    const slot = openUpgradeStream(conn, head) orelse {
        reply(conn.fd, upgrade.BAD_REQUEST);

        return .close;
    };

    conn.upgrade_slot = slot;
    conn.last_stream_id = UPGRADE_STREAM_ID;

    reply(conn.fd, upgrade.SWITCHING_PROTOCOLS);

    conn.rstart += head_bytes.len;
    conn.phase = .await_preface2;

    return .keep_alive;
}

/// Answer the stream 1 an h2c upgrade opened, once. Does nothing without one.
///
/// Note:
/// - Call after the preface is accepted and the server SETTINGS are sent.
///
/// Param:
/// handler_fn - handler.HandlerFn (the route or top-level handler)
/// conn - *MuxConn (the connection, in the h2 phase)
///
/// Return:
/// - void
pub fn serveUpgradeStream(handler_fn: handler.HandlerFn, conn: *MuxConn) void {
    const slot = conn.upgrade_slot orelse return;

    conn.upgrade_slot = null;

    mux_dispatch.dispatchWhole(handler_fn, conn, slot);
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const builtin = @import("builtin");
const pair = @import("../../../utils/socket/pair.zig");
const ServeOpts = @import("../ServeOpts.zig");

const Context = @import("../Context.zig");
const Request = @import("../Request.zig");
const Response = @import("../Response.zig");

const TEST_OPTS: ServeOpts = .{
    .max_streams = 2,
    .max_body = 64,
    .max_header_scratch = 64,
    .conn_read_buf_min = 1024,
};

/// HTTP2-Settings: SETTINGS_INITIAL_WINDOW_SIZE 1000, SETTINGS_MAX_FRAME_SIZE 20000.
const H2C_HEAD_SETTINGS =
    "GET /items?page=2 HTTP/1.1\r\n" ++
    "Host: localhost\r\n" ++
    "Connection: Upgrade, HTTP2-Settings\r\n" ++
    "Upgrade: h2c\r\n" ++
    "HTTP2-Settings: AAQAAAPoAAUAAE4g\r\n\r\n";

threadlocal var tl_calls: usize = 0;
threadlocal var tl_seen_method: [8]u8 = undefined;
threadlocal var tl_seen_method_len: usize = 0;
threadlocal var tl_seen_path: [32]u8 = undefined;
threadlocal var tl_seen_path_len: usize = 0;
threadlocal var tl_seen_query: [32]u8 = undefined;
threadlocal var tl_seen_query_len: usize = 0;
threadlocal var tl_seen_sid: u31 = 0;

fn recordHandler(req: *Request, res: *Response, ctx: *Context) anyerror!void {
    tl_calls += 1;
    tl_seen_sid = ctx.sid;

    tl_seen_method_len = req.method.len;
    @memcpy(tl_seen_method[0..req.method.len], req.method);
    tl_seen_path_len = req.path.len;
    @memcpy(tl_seen_path[0..req.path.len], req.path);
    tl_seen_query_len = req.query.len;
    @memcpy(tl_seen_query[0..req.query.len], req.query);

    try res.sendText("ok");
}

const H2C_HEAD =
    "GET / HTTP/1.1\r\n" ++
    "Host: localhost\r\n" ++
    "Connection: Upgrade, HTTP2-Settings\r\n" ++
    "Upgrade: h2c\r\n\r\n";

fn isLinux() bool {
    if (comptime builtin.target.os.tag == .linux) return true;

    std.log.info("this test drives a Linux socket pair, test skipped", .{});

    return false;
}

/// Load bytes into the connection's read buffer as if they had arrived.
fn feed(conn: *MuxConn, bytes: []const u8) void {
    @memcpy(conn.rbuf[conn.rend..][0..bytes.len], bytes);
    conn.rend += bytes.len;
}

fn readReply(fd: std.posix.fd_t, buf: []u8) ![]u8 {
    const got = try std.posix.read(fd, buf);

    return buf[0..got];
}

test "zix http2 mux: mux_upgrade, an h2c head gets 101" {
    if (!isLinux()) return;

    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    const conn = try MuxConn.init(fds[1], TEST_OPTS, std.testing.io);
    defer conn.deinit();

    conn.phase = .await_upgrade;
    feed(conn, H2C_HEAD ++ "PRI");

    try std.testing.expectEqual(ConnOutcome.keep_alive, handleUpgrade(conn));
    try std.testing.expect(conn.phase == .await_preface2);
    try std.testing.expectEqualStrings("PRI", conn.buffered());

    var buf: [256]u8 = undefined;
    const got = try readReply(fds[0], &buf);

    try std.testing.expect(std.mem.startsWith(u8, got, "HTTP/1.1 101"));
}

test "zix http2 mux: mux_upgrade, an h2c head opens stream 1" {
    if (!isLinux()) return;

    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    const conn = try MuxConn.init(fds[1], TEST_OPTS, std.testing.io);
    defer conn.deinit();

    conn.phase = .await_upgrade;
    feed(conn, H2C_HEAD);

    try std.testing.expectEqual(ConnOutcome.keep_alive, handleUpgrade(conn));

    const slot = conn.upgrade_slot.?;
    const stream = conn.streams[slot];

    try std.testing.expectEqual(@as(u31, 1), stream.id);
    try std.testing.expectEqual(@as(u31, 1), conn.last_stream_id);
    try std.testing.expect(stream.end_stream);
    try std.testing.expectEqualStrings(":method", stream.headerList()[0].name);
    try std.testing.expectEqualStrings("GET", stream.headerList()[0].value);
    try std.testing.expectEqualStrings("/", stream.headerList()[1].value);
}

test "zix http2 mux: mux_upgrade, an h2c head applies HTTP2-Settings" {
    if (!isLinux()) return;

    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    const conn = try MuxConn.init(fds[1], TEST_OPTS, std.testing.io);
    defer conn.deinit();

    conn.phase = .await_upgrade;
    feed(conn, H2C_HEAD_SETTINGS);

    try std.testing.expectEqual(ConnOutcome.keep_alive, handleUpgrade(conn));
    try std.testing.expectEqual(@as(u32, 20000), conn.peer_max_frame_size);
    try std.testing.expectEqual(@as(i64, 1000), conn.peer_init_window);
    try std.testing.expectEqual(@as(i64, 1000), conn.streams[conn.upgrade_slot.?].send_window);
}

test "zix http2 mux: mux_upgrade, a target past the stream scratch gets 400" {
    if (!isLinux()) return;

    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    const conn = try MuxConn.init(fds[1], TEST_OPTS, std.testing.io);
    defer conn.deinit();

    // A pooled stream may hold a larger scratch than TEST_OPTS asks for, so
    // the target is sized from the stream the upgrade will borrow.
    const probe = conn.claimSlot(1).?;
    const scratch_len = conn.streams[probe].header_scratch.len;
    conn.releaseSlot(probe);

    feed(conn, "GET /");
    @memset(conn.rbuf[conn.rend..][0..scratch_len], 'a');
    conn.rend += scratch_len;
    feed(conn, " HTTP/1.1\r\nUpgrade: h2c\r\n\r\n");

    try std.testing.expectEqual(ConnOutcome.close, handleUpgrade(conn));
    try std.testing.expectEqual(@as(?usize, null), conn.upgrade_slot);
    try std.testing.expect(!conn.requestInFlight());

    var buf: [256]u8 = undefined;
    const got = try readReply(fds[0], &buf);

    try std.testing.expect(std.mem.startsWith(u8, got, "HTTP/1.1 400"));
}

test "zix http2 mux: mux_upgrade, serveUpgradeStream answers stream 1 once" {
    if (!isLinux()) return;

    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    const conn = try MuxConn.init(fds[1], TEST_OPTS, std.testing.io);
    defer conn.deinit();

    conn.phase = .await_upgrade;
    feed(conn, H2C_HEAD_SETTINGS);
    _ = handleUpgrade(conn);

    // The head bytes are gone, so stream 1 must not borrow them.
    @memset(conn.rbuf, 'x');

    tl_calls = 0;
    serveUpgradeStream(recordHandler, conn);
    serveUpgradeStream(recordHandler, conn);

    try std.testing.expectEqual(@as(usize, 1), tl_calls);
    try std.testing.expectEqual(@as(u31, 1), tl_seen_sid);
    try std.testing.expectEqualStrings("GET", tl_seen_method[0..tl_seen_method_len]);
    try std.testing.expectEqualStrings("/items", tl_seen_path[0..tl_seen_path_len]);
    try std.testing.expectEqualStrings("page=2", tl_seen_query[0..tl_seen_query_len]);
    try std.testing.expectEqual(@as(?usize, null), conn.upgrade_slot);
    try std.testing.expect(conn.findSlot(1) == null);
}

test "zix http2 mux: mux_upgrade, serveUpgradeStream without an upgrade does nothing" {
    const conn = try MuxConn.init(undefined, TEST_OPTS, std.testing.io);
    defer conn.deinit();

    tl_calls = 0;
    serveUpgradeStream(recordHandler, conn);

    try std.testing.expectEqual(@as(usize, 0), tl_calls);
}

test "zix http2 mux: mux_upgrade, a non-h2c head gets 400 and closes" {
    if (!isLinux()) return;

    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    const conn = try MuxConn.init(fds[1], TEST_OPTS, std.testing.io);
    defer conn.deinit();

    feed(conn, "GET / HTTP/1.1\r\nHost: x\r\n\r\n");

    try std.testing.expectEqual(ConnOutcome.close, handleUpgrade(conn));

    var buf: [256]u8 = undefined;
    const got = try readReply(fds[0], &buf);

    try std.testing.expect(std.mem.startsWith(u8, got, "HTTP/1.1 400"));
}

test "zix http2 mux: mux_upgrade, a partial head waits for more" {
    const conn = try MuxConn.init(undefined, TEST_OPTS, std.testing.io);
    defer conn.deinit();

    feed(conn, "GET / HTTP/1.1\r\nUpgrade: h2c\r\n");

    try std.testing.expectEqual(ConnOutcome.keep_alive, handleUpgrade(conn));
    try std.testing.expectEqual(@as(usize, 0), conn.rstart);
}

test "zix http2 mux: mux_upgrade, a head that fills the buffer closes" {
    const conn = try MuxConn.init(undefined, TEST_OPTS, std.testing.io);
    defer conn.deinit();

    @memset(conn.rbuf, 'h');
    conn.rend = conn.rbuf.len;

    try std.testing.expectEqual(ConnOutcome.close, handleUpgrade(conn));
}

