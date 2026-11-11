//! ZIX Http2 mux process
//!
//! ### file: src/zix/tcp/http2/mux/process.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Drive one mux connection per event: read, pass the handshake, run the frames.
//!
//! ### note:
//!
//! - Responses and connection frames are written straight to the fd while the
//!   buffered bytes are processed. A non-blocking fd waits on a full send
//!   buffer inside the writer.
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
const frame = @import("../frame.zig");
const frame_loop = @import("frame_loop.zig");
const handler = @import("../handler.zig");
const mux_dispatch = @import("mux_dispatch.zig");
const mux_upgrade = @import("mux_upgrade.zig");
const peer_settings = @import("../peer_settings.zig");
const send_best_effort = @import("../send_best_effort.zig");
const ConnOutcome = @import("conn_outcome.zig").ConnOutcome;
const MuxConn = @import("MuxConn.zig");

// --------------------------------------------------------- //
// Private:

/// Bytes read before deciding between the preface and an upgrade.
const PEEK_LEN: usize = 3;

/// Accept the client preface and answer with this server's SETTINGS.
///
/// Return:
/// - .keep_alive when the preface was accepted or is not complete yet
/// - .close after GOAWAY when the bytes are not the preface
fn acceptPreface(conn: *MuxConn) ConnOutcome {
    const buf = conn.buffered();
    if (buf.len < frame.PREFACE.len) return .keep_alive;

    if (!std.mem.eql(u8, buf[0..frame.PREFACE.len], frame.PREFACE)) {
        send_best_effort.goaway(conn.fd, 0, frame.ERR_PROTOCOL_ERROR);

        return .close;
    }

    conn.rstart += frame.PREFACE.len;

    peer_settings.sendServerSettings(conn.fd, conn.opts) catch |err| switch (err) {
        // Best effort: a broken socket shows up on the next read.
        error.ZixHttp2_PeerSettings_BrokenPipe,
        error.ZixHttp2_PeerSettings_TooManySettings,
        error.ZixHttp2_PeerSettings_UnexpectedEOF,
        error.ZixHttp2_PeerSettings_Overflow,
        error.ZixHttp2_PeerSettings_BufferFull,
        => {},
    };
    conn.phase = .h2;

    return .keep_alive;
}

/// Move the connection through its handshake phases, then run the frames.
fn process(handler_fn: handler.HandlerFn, conn: *MuxConn) ConnOutcome {
    switch (conn.phase) {
        .await_preface => {
            const buf = conn.buffered();
            if (buf.len < PEEK_LEN) return .keep_alive;

            if (!std.mem.eql(u8, buf[0..PEEK_LEN], frame.PREFACE[0..PEEK_LEN])) {
                conn.phase = .await_upgrade;

                return mux_upgrade.handleUpgrade(conn);
            }

            if (acceptPreface(conn) == .close) return .close;
        },
        .await_upgrade => return mux_upgrade.handleUpgrade(conn),
        .await_preface2 => {
            if (acceptPreface(conn) == .close) return .close;
        },
        .h2 => {},
    }

    if (conn.phase != .h2) return .keep_alive;

    return frame_loop.run(handler_fn, conn);
}

// --------------------------------------------------------- //
// Public:

/// Process the bytes a ring recv just placed in the read buffer.
///
/// Note:
/// - No read and no loop: the .URING worker owns the recv and re-arms it
///   after this returns.
///
/// Param:
/// handler_fn - handler.HandlerFn (the route or top-level handler)
/// conn - *MuxConn (the connection the recv filled)
///
/// Return:
/// - .keep_alive when the connection waits for more bytes
/// - .close on a protocol error or a rejected handshake
pub fn processRing(handler_fn: handler.HandlerFn, conn: *MuxConn) ConnOutcome {
    return process(handler_fn, conn);
}

/// Drive one readable event: read what is available, then process every
/// whole frame, until the socket has nothing more.
///
/// Param:
/// handler_fn - handler.HandlerFn (the route or top-level handler)
/// conn - *MuxConn (a connection on a non-blocking fd)
///
/// Return:
/// - .keep_alive when the socket would block
/// - .close when the peer closed, a read failed, or the protocol broke
pub fn onReadable(handler_fn: handler.HandlerFn, conn: *MuxConn) ConnOutcome {
    while (true) {
        conn.compact();

        // A full buffer even after compaction holds a frame larger than this
        // connection can read.
        if (conn.rend == conn.rbuf.len) return .close;

        const got = std.posix.read(conn.fd, conn.rbuf[conn.rend..]) catch |err| switch (err) {
            error.WouldBlock => return .keep_alive,
            else => return .close,
        };

        if (got == 0) {
            _ = mux_dispatch.hangupGoaway(conn);

            return .close;
        }

        conn.rend += got;

        if (process(handler_fn, conn) == .close) return .close;
    }
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const builtin = @import("builtin");
const pair = @import("../../../utils/socket/pair.zig");
const writer = @import("../writer.zig");
const Context = @import("../Context.zig");
const Header = @import("../hpack/Header.zig");
const HpackDecoder = @import("../hpack/HpackDecoder.zig");
const HpackEncoder = @import("../hpack/HpackEncoder.zig");
const MuxPhase = @import("mux_phase.zig").MuxPhase;
const Request = @import("../Request.zig");
const Response = @import("../Response.zig");
const ServeOpts = @import("../ServeOpts.zig");

/// What the server answered with, read back after it returned.
const WireTally = struct {
    settings: usize = 0,
    goaway_protocol_error: usize = 0,
    status_200: usize = 0,
};

const TEST_OPTS: ServeOpts = .{
    .max_streams = 4,
    .max_body = 256,
    .max_header_scratch = 1024,
};

const UPGRADE_REQUEST =
    "GET / HTTP/1.1\r\n" ++
    "Host: localhost\r\n" ++
    "Connection: Upgrade, HTTP2-Settings\r\n" ++
    "Upgrade: h2c\r\n" ++
    "HTTP2-Settings: AAMAAABkAAQAAP__\r\n\r\n";

threadlocal var tl_calls: usize = 0;

fn okHandler(_: *Request, res: *Response, _: *Context) anyerror!void {
    tl_calls += 1;

    try res.sendText("ok");
}

fn isLinux() bool {
    if (comptime builtin.target.os.tag == .linux) return true;

    std.log.info("this test drives a Linux socket pair, test skipped", .{});

    return false;
}

fn shutdownWrite(fd: std.posix.fd_t) void {
    _ = std.os.linux.shutdown(fd, std.os.linux.SHUT.WR);
}

/// Write one complete frame the way a client would.
fn writeFrameTo(
    fd: std.posix.fd_t,
    frame_type: u8,
    flags: u8,
    sid: u31,
    payload: []const u8,
) !void {
    var head: [frame.FRAME_HEADER_LEN]u8 = undefined;
    frame.encodeFrameHeader(&head, .{
        .length = @intCast(payload.len),
        .frame_type = frame_type,
        .flags = flags,
        .stream_id = sid,
    });

    try writer.writeAllDirectFD(fd, &head);
    if (payload.len > 0) try writer.writeAllDirectFD(fd, payload);
}

/// Write a GET on sid that ends its stream.
fn writeGet(fd: std.posix.fd_t, sid: u31, method: []const u8) !void {
    var block: [128]u8 = undefined;
    var encoder = HpackEncoder.init(&block);
    try encoder.writeHeader(":method", method);
    try encoder.writeHeader(":path", "/");

    const flags = frame.FLAG_END_HEADERS | frame.FLAG_END_STREAM;
    try writeFrameTo(fd, frame.FRAME_TYPE_HEADERS, flags, sid, encoder.encoded());
}

/// Load bytes into the connection's read buffer as if they had arrived.
fn feed(conn: *MuxConn, bytes: []const u8) void {
    @memcpy(conn.rbuf[conn.rend..][0..bytes.len], bytes);
    conn.rend += bytes.len;
}

/// Read everything the server wrote and count the answers that matter.
fn tallyWire(client_fd: std.posix.fd_t, server_fd: std.posix.fd_t, skip: usize) !WireTally {
    shutdownWrite(server_fd);

    var buf: [8192]u8 = undefined;
    var total: usize = 0;
    while (total < buf.len) {
        const got = std.posix.read(client_fd, buf[total..]) catch break;
        if (got == 0) break;

        total += got;
    }

    var tally: WireTally = .{};
    var decoder = HpackDecoder.init();
    var pos: usize = skip;

    while (pos + frame.FRAME_HEADER_LEN <= total) {
        const header = frame.parseFrameHeader(buf[pos..][0..frame.FRAME_HEADER_LEN]);
        pos += frame.FRAME_HEADER_LEN;
        if (pos + header.length > total) break;

        const payload = buf[pos..][0..header.length];
        pos += header.length;

        switch (header.frame_type) {
            frame.FRAME_TYPE_SETTINGS => {
                if ((header.flags & frame.FLAG_ACK) == 0) tally.settings += 1;
            },
            frame.FRAME_TYPE_GOAWAY => {
                const code = std.mem.readInt(u32, payload[4..8], .big);
                if (code == frame.ERR_PROTOCOL_ERROR) tally.goaway_protocol_error += 1;
            },
            frame.FRAME_TYPE_HEADERS => {
                var headers: [frame.MAX_HEADERS]Header = undefined;
                var scratch: [256]u8 = undefined;
                const count = decoder.decode(payload, &headers, &scratch) catch continue;

                for (headers[0..count]) |entry| {
                    const is_ok =
                        std.mem.eql(u8, entry.name, ":status") and
                        std.mem.eql(u8, entry.value, "200");
                    if (is_ok) tally.status_200 += 1;
                }
            },
            else => {},
        }
    }

    return tally;
}

test "zix http2 mux: process, onReadable serves a prior-knowledge request" {
    if (!isLinux()) return;

    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    const conn = try MuxConn.init(fds[1], TEST_OPTS, std.testing.io);
    defer conn.deinit();

    try writer.writeAllDirectFD(fds[0], frame.PREFACE);
    try writeFrameTo(fds[0], frame.FRAME_TYPE_SETTINGS, 0, 0, "");
    try writeGet(fds[0], 1, "GET");
    shutdownWrite(fds[0]);

    tl_calls = 0;
    try std.testing.expectEqual(ConnOutcome.close, onReadable(okHandler, conn));

    const tally = try tallyWire(fds[0], fds[1], 0);

    try std.testing.expectEqual(@as(usize, 1), tl_calls);
    try std.testing.expectEqual(@as(usize, 1), tally.settings);
    try std.testing.expectEqual(@as(usize, 1), tally.status_200);
    try std.testing.expectEqual(@as(usize, 0), tally.goaway_protocol_error);
}

test "zix http2 mux: process, onReadable hang-up mid-request gets GOAWAY" {
    if (!isLinux()) return;

    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    const conn = try MuxConn.init(fds[1], TEST_OPTS, std.testing.io);
    defer conn.deinit();

    var block: [128]u8 = undefined;
    var encoder = HpackEncoder.init(&block);
    try encoder.writeHeader(":method", "POST");
    try encoder.writeHeader(":path", "/");

    try writer.writeAllDirectFD(fds[0], frame.PREFACE);
    const head_flags = frame.FLAG_END_HEADERS;
    try writeFrameTo(fds[0], frame.FRAME_TYPE_HEADERS, head_flags, 1, encoder.encoded());
    shutdownWrite(fds[0]);

    tl_calls = 0;
    try std.testing.expectEqual(ConnOutcome.close, onReadable(okHandler, conn));

    const tally = try tallyWire(fds[0], fds[1], 0);

    try std.testing.expectEqual(@as(usize, 0), tl_calls);
    try std.testing.expectEqual(@as(usize, 1), tally.goaway_protocol_error);
}

test "zix http2 mux: process, onReadable on a non-blocking idle socket keeps alive" {
    if (!isLinux()) return;

    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    const flags = std.os.linux.fcntl(fds[1], std.os.linux.F.GETFL, 0);
    const nonblock: usize = @as(u32, @bitCast(std.os.linux.O{ .NONBLOCK = true }));
    _ = std.os.linux.fcntl(fds[1], std.os.linux.F.SETFL, flags | nonblock);

    const conn = try MuxConn.init(fds[1], TEST_OPTS, std.testing.io);
    defer conn.deinit();

    try writer.writeAllDirectFD(fds[0], frame.PREFACE);

    try std.testing.expectEqual(ConnOutcome.keep_alive, onReadable(okHandler, conn));
    try std.testing.expectEqual(MuxPhase.h2, conn.phase);
}

test "zix http2 mux: process, a bad preface gets GOAWAY and closes" {
    if (!isLinux()) return;

    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    const conn = try MuxConn.init(fds[1], TEST_OPTS, std.testing.io);
    defer conn.deinit();

    feed(conn, "PRI * HTTP/9.9\r\n\r\nXX\r\n\r\n");

    try std.testing.expectEqual(ConnOutcome.close, processRing(okHandler, conn));

    const tally = try tallyWire(fds[0], fds[1], 0);

    try std.testing.expectEqual(@as(usize, 1), tally.goaway_protocol_error);
}

test "zix http2 mux: process, a partial preface waits" {
    const conn = try MuxConn.init(undefined, TEST_OPTS, std.testing.io);
    defer conn.deinit();

    feed(conn, frame.PREFACE[0..10]);

    try std.testing.expectEqual(ConnOutcome.keep_alive, processRing(okHandler, conn));
    try std.testing.expectEqual(MuxPhase.await_preface, conn.phase);
}

test "zix http2 mux: process, fewer bytes than the peek wait" {
    const conn = try MuxConn.init(undefined, TEST_OPTS, std.testing.io);
    defer conn.deinit();

    feed(conn, "PR");

    try std.testing.expectEqual(ConnOutcome.keep_alive, processRing(okHandler, conn));
    try std.testing.expectEqual(MuxPhase.await_preface, conn.phase);
}

test "zix http2 mux: process, processRing runs frames after the preface" {
    if (!isLinux()) return;

    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    const conn = try MuxConn.init(fds[1], TEST_OPTS, std.testing.io);
    defer conn.deinit();

    var block: [128]u8 = undefined;
    var encoder = HpackEncoder.init(&block);
    try encoder.writeHeader(":method", "GET");
    try encoder.writeHeader(":path", "/");

    var head: [frame.FRAME_HEADER_LEN]u8 = undefined;
    frame.encodeFrameHeader(&head, .{
        .length = @intCast(encoder.encoded().len),
        .frame_type = frame.FRAME_TYPE_HEADERS,
        .flags = frame.FLAG_END_HEADERS | frame.FLAG_END_STREAM,
        .stream_id = 1,
    });
    feed(conn, frame.PREFACE);
    feed(conn, &head);
    feed(conn, encoder.encoded());

    tl_calls = 0;
    try std.testing.expectEqual(ConnOutcome.keep_alive, processRing(okHandler, conn));

    const tally = try tallyWire(fds[0], fds[1], 0);

    try std.testing.expectEqual(@as(usize, 1), tl_calls);
    try std.testing.expectEqual(@as(usize, 1), tally.status_200);
}

test "zix http2 mux: process, an h2c upgrade then the preface reaches h2" {
    if (!isLinux()) return;

    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    const conn = try MuxConn.init(fds[1], TEST_OPTS, std.testing.io);
    defer conn.deinit();

    feed(conn, UPGRADE_REQUEST);
    try std.testing.expectEqual(ConnOutcome.keep_alive, processRing(okHandler, conn));
    try std.testing.expectEqual(MuxPhase.await_preface2, conn.phase);

    feed(conn, frame.PREFACE);
    try std.testing.expectEqual(ConnOutcome.keep_alive, processRing(okHandler, conn));
    try std.testing.expectEqual(MuxPhase.h2, conn.phase);

    const reply_len =
        "HTTP/1.1 101 Switching Protocols\r\n".len +
        "Connection: Upgrade\r\nUpgrade: h2c\r\n\r\n".len;
    const tally = try tallyWire(fds[0], fds[1], reply_len);

    try std.testing.expectEqual(@as(usize, 1), tally.settings);
}

test "zix http2 mux: process, a bad preface after the upgrade closes" {
    if (!isLinux()) return;

    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    const conn = try MuxConn.init(fds[1], TEST_OPTS, std.testing.io);
    defer conn.deinit();

    conn.phase = .await_preface2;
    feed(conn, "XXXXXXXXXXXXXXXXXXXXXXXXXXXX");

    try std.testing.expectEqual(ConnOutcome.close, processRing(okHandler, conn));
}

