//! ZIX Http2 Grpc mux process
//!
//! ### file: src/zix/tcp/http2/grpc/mux/process.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Drive one gRPC mux connection: the preface or an h2c upgrade first, then
//! the frames, for the .EPOLL and .URING workers.
//!
//! ### note:
//!
//! onReadable reads and flushes the reply stage itself. processRing does
//! neither: the .URING worker fills rbuf and sends the stage.
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
const frame = @import("../../frame.zig");
const frame_loop = @import("frame_loop.zig");
const mux_dispatch = @import("mux_dispatch.zig");
const mux_upgrade = @import("mux_upgrade.zig");
const stage_frame = @import("stage_frame.zig");
const ConnOutcome = @import("../../mux/conn_outcome.zig").ConnOutcome;
const MuxConn = @import("MuxConn.zig");

// --------------------------------------------------------- //
// Private:

/// Bytes read before deciding between the preface and an upgrade.
const PEEK_LEN: usize = 3;

/// Accept the client preface and stage this server's SETTINGS.
///
/// Return:
/// - .keep_alive when the preface was accepted or is not complete yet
/// - .close after GOAWAY when the bytes are not the preface
fn acceptPreface(conn: *MuxConn) ConnOutcome {
    const buf = conn.buffered();
    if (buf.len < frame.PREFACE.len) return .keep_alive;

    if (!std.mem.eql(u8, buf[0..frame.PREFACE.len], frame.PREFACE)) {
        stage_frame.goaway(&conn.stage, 0, frame.ERR_PROTOCOL_ERROR);

        return .close;
    }

    conn.rstart += frame.PREFACE.len;
    conn.stage.append(&conn.settings);
    conn.phase = .h2;

    return .keep_alive;
}

/// Move the connection through its handshake phases, then run the frames.
///
/// Note:
/// - The phases fall through, so a preface read together with the upgrade
///   head (or frames read together with the preface) are handled at once.
fn process(comptime RouterType: type, conn: *MuxConn) ConnOutcome {
    if (conn.phase == .await_preface) {
        const buf = conn.buffered();
        if (buf.len < PEEK_LEN) return .keep_alive;

        if (std.mem.eql(u8, buf[0..PEEK_LEN], frame.PREFACE[0..PEEK_LEN])) {
            if (acceptPreface(conn) == .close) return .close;
        } else {
            conn.phase = .await_upgrade;
        }
    }

    if (conn.phase == .await_upgrade) {
        if (mux_upgrade.handleUpgrade(conn) == .close) return .close;
    }

    if (conn.phase == .await_preface2) {
        if (acceptPreface(conn) == .close) return .close;
    }

    if (conn.phase != .h2) return .keep_alive;

    return frame_loop.run(RouterType, conn);
}

// --------------------------------------------------------- //
// Public:

/// Process the bytes a ring recv just placed in the read buffer.
///
/// Note:
/// - No read and no flush: the .URING worker sends
///   conn.stage.buf[0..conn.stage.len] after this returns. A reply past the
///   stage already went straight to the fd.
///
/// Param:
/// RouterType - type (a Router, carrying route_slice and dispatch)
/// conn - *MuxConn (the connection the recv filled)
///
/// Return:
/// - .keep_alive when the connection waits for more bytes
/// - .close on a protocol error or a rejected handshake
pub fn processRing(comptime RouterType: type, conn: *MuxConn) ConnOutcome {
    conn.stage.len = 0;

    return process(RouterType, conn);
}

/// Drive one readable event: read what is available, process every whole
/// frame, and flush the staged reply, until the socket has nothing more.
///
/// Param:
/// RouterType - type (a Router, carrying route_slice and dispatch)
/// conn - *MuxConn (a connection on a non-blocking fd)
///
/// Return:
/// - .keep_alive when the socket would block
/// - .close when the peer closed, a read failed, or the protocol broke
pub fn onReadable(comptime RouterType: type, conn: *MuxConn) ConnOutcome {
    conn.stage.len = 0;
    defer conn.stage.flush();

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

        if (process(RouterType, conn) == .close) return .close;
    }
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const builtin = @import("builtin");
const pair = @import("../../../../utils/socket/pair.zig");
const router = @import("../router.zig");
const writer = @import("../../writer.zig");
const Context = @import("../Context.zig");
const Header = @import("../../hpack/Header.zig");
const HpackDecoder = @import("../../hpack/HpackDecoder.zig");
const HpackEncoder = @import("../../hpack/HpackEncoder.zig");
const MuxPhase = @import("../../mux/mux_phase.zig").MuxPhase;
const Request = @import("../Request.zig");
const Response = @import("../Response.zig");
const ServeOpts = @import("../ServeOpts.zig");

/// What the server answered with, read back after it returned.
const WireTally = struct {
    settings: usize = 0,
    goaway_protocol_error: usize = 0,
    status_ok: usize = 0,
};

const TEST_OPTS: ServeOpts = .{
    .max_streams = 4,
    .max_body = 256,
    .max_header_scratch = 1024,
};

/// A descriptor nothing is read from or written to in the staged tests.
const UNUSED_FD: std.posix.fd_t = undefined;

const UPGRADE_REQUEST =
    "POST /svc.Svc/Method HTTP/1.1\r\n" ++
    "Host: localhost\r\n" ++
    "Connection: Upgrade, HTTP2-Settings\r\n" ++
    "Upgrade: h2c\r\n" ++
    "HTTP2-Settings: AAMAAABkAAQAAP__\r\n\r\n";

threadlocal var tl_calls: usize = 0;

fn okHandler(_: *Request, res: *Response, _: *Context) anyerror!void {
    tl_calls += 1;

    try res.finish(.OK, "");
}

const TestRouter = router.Router(&[_]router.Route{
    .{
        .path = "/svc.Svc/Method",
        .handler = okHandler,
    },
});

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

/// Write a whole unary call on sid: HEADERS, then a DATA with an empty message.
fn writeCall(fd: std.posix.fd_t, sid: u31) !void {
    var block: [128]u8 = undefined;
    var encoder = HpackEncoder.init(&block);
    try encoder.writeHeader(":method", "POST");
    try encoder.writeHeader(":path", "/svc.Svc/Method");

    const empty_message = [_]u8{ 0, 0, 0, 0, 0 };
    const block_flags = frame.FLAG_END_HEADERS;

    try writeFrameTo(fd, frame.FRAME_TYPE_HEADERS, block_flags, sid, encoder.encoded());
    try writeFrameTo(fd, frame.FRAME_TYPE_DATA, frame.FLAG_END_STREAM, sid, &empty_message);
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
                        std.mem.eql(u8, entry.name, "grpc-status") and
                        std.mem.eql(u8, entry.value, "0");
                    if (is_ok) tally.status_ok += 1;
                }
            },
            else => {},
        }
    }

    return tally;
}

test "zix http2 grpc mux: process, onReadable serves a prior-knowledge call" {
    if (!isLinux()) return;

    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    const conn = try MuxConn.init(fds[1], TEST_OPTS, std.testing.io);
    defer conn.deinit();

    try writer.writeAllDirectFD(fds[0], frame.PREFACE);
    try writeFrameTo(fds[0], frame.FRAME_TYPE_SETTINGS, 0, 0, "");
    try writeCall(fds[0], 1);
    shutdownWrite(fds[0]);

    tl_calls = 0;
    try std.testing.expectEqual(ConnOutcome.close, onReadable(TestRouter, conn));

    const tally = try tallyWire(fds[0], fds[1], 0);

    try std.testing.expectEqual(@as(usize, 1), tl_calls);
    try std.testing.expectEqual(@as(usize, 1), tally.settings);
    try std.testing.expectEqual(@as(usize, 1), tally.status_ok);
    try std.testing.expectEqual(@as(usize, 0), tally.goaway_protocol_error);
}

test "zix http2 grpc mux: process, onReadable sends GOAWAY on a mid-request hang-up" {
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
    try encoder.writeHeader(":path", "/svc.Svc/Method");

    const block_flags = frame.FLAG_END_HEADERS;

    try writer.writeAllDirectFD(fds[0], frame.PREFACE);
    try writeFrameTo(fds[0], frame.FRAME_TYPE_HEADERS, block_flags, 1, encoder.encoded());
    shutdownWrite(fds[0]);

    try std.testing.expectEqual(ConnOutcome.close, onReadable(TestRouter, conn));

    const tally = try tallyWire(fds[0], fds[1], 0);

    try std.testing.expectEqual(@as(usize, 1), tally.goaway_protocol_error);
}

test "zix http2 grpc mux: process, onReadable closes an idle hang-up without a GOAWAY" {
    if (!isLinux()) return;

    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    const conn = try MuxConn.init(fds[1], TEST_OPTS, std.testing.io);
    defer conn.deinit();

    try writer.writeAllDirectFD(fds[0], frame.PREFACE);
    shutdownWrite(fds[0]);

    try std.testing.expectEqual(ConnOutcome.close, onReadable(TestRouter, conn));

    const tally = try tallyWire(fds[0], fds[1], 0);

    try std.testing.expectEqual(@as(usize, 1), tally.settings);
    try std.testing.expectEqual(@as(usize, 0), tally.goaway_protocol_error);
}

test "zix http2 grpc mux: process, onReadable answers an h2c upgrade then the preface" {
    if (!isLinux()) return;

    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    const conn = try MuxConn.init(fds[1], TEST_OPTS, std.testing.io);
    defer conn.deinit();

    try writer.writeAllDirectFD(fds[0], UPGRADE_REQUEST);
    try writer.writeAllDirectFD(fds[0], frame.PREFACE);
    shutdownWrite(fds[0]);

    try std.testing.expectEqual(ConnOutcome.close, onReadable(TestRouter, conn));
    try std.testing.expect(conn.phase == .h2);

    var head: [128]u8 = undefined;
    const got = try std.posix.read(fds[0], &head);

    try std.testing.expect(std.mem.startsWith(u8, head[0..got], "HTTP/1.1 101"));
}

test "zix http2 grpc mux: process, processRing stages without writing" {
    const conn = try MuxConn.init(UNUSED_FD, TEST_OPTS, std.testing.io);
    defer conn.deinit();

    feed(conn, frame.PREFACE);

    try std.testing.expectEqual(ConnOutcome.keep_alive, processRing(TestRouter, conn));
    try std.testing.expect(conn.phase == .h2);
    try std.testing.expectEqualSlices(u8, &conn.settings, conn.stage.buf[0..conn.stage.len]);
}

test "zix http2 grpc mux: process, processRing waits for the rest of the preface" {
    const conn = try MuxConn.init(UNUSED_FD, TEST_OPTS, std.testing.io);
    defer conn.deinit();

    feed(conn, frame.PREFACE[0..10]);

    try std.testing.expectEqual(ConnOutcome.keep_alive, processRing(TestRouter, conn));
    try std.testing.expectEqual(MuxPhase.await_preface, conn.phase);
    try std.testing.expectEqual(@as(usize, 0), conn.stage.len);
}

test "zix http2 grpc mux: process, processRing stages GOAWAY for a bad preface" {
    const conn = try MuxConn.init(UNUSED_FD, TEST_OPTS, std.testing.io);
    defer conn.deinit();

    var bad: [frame.PREFACE.len]u8 = undefined;
    @memcpy(&bad, frame.PREFACE);
    bad[bad.len - 1] = 'x';
    feed(conn, &bad);

    try std.testing.expectEqual(ConnOutcome.close, processRing(TestRouter, conn));

    const header = frame.parseFrameHeader(conn.stage.buf[0..frame.FRAME_HEADER_LEN]);

    try std.testing.expectEqual(frame.FRAME_TYPE_GOAWAY, header.frame_type);
}

