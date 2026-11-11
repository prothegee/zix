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
//! The HTTP/1.1 h2c upgrade on a mux connection: answer 101, then await the preface.
//!
//! ### note:
//!
//! - Minimal on purpose: the request carried on stream 1 is not served here.
//!   Prior-knowledge clients (the common h2c case) are not affected, and the
//!   blocking serve path serves the full upgrade.
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
const upgrade = @import("../upgrade.zig");
const writer = @import("../writer.zig");
const ConnOutcome = @import("conn_outcome.zig").ConnOutcome;
const MuxConn = @import("MuxConn.zig");

// --------------------------------------------------------- //
// Private:

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

// --------------------------------------------------------- //
// Public:

/// Read the buffered HTTP/1.1 head and answer it.
///
/// Param:
/// conn - *MuxConn (a connection in the await_upgrade phase)
///
/// Return:
/// - .keep_alive when the head is not complete yet, or after 101
/// - .close when the head fills the buffer, or after 400 for a non-h2c request
pub fn handleUpgrade(conn: *MuxConn) ConnOutcome {
    const buf = conn.buffered();

    const marker = std.mem.indexOf(u8, buf, upgrade.HEAD_END) orelse {
        if (conn.rend == conn.rbuf.len) return .close;

        return .keep_alive;
    };
    const head = buf[0 .. marker + upgrade.HEAD_END.len];

    if (!upgrade.isH2cUpgrade(head)) {
        reply(conn.fd, upgrade.BAD_REQUEST);

        return .close;
    }

    reply(conn.fd, upgrade.SWITCHING_PROTOCOLS);

    conn.rstart += head.len;
    conn.phase = .await_preface2;

    return .keep_alive;
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const builtin = @import("builtin");
const pair = @import("../../../utils/socket/pair.zig");
const ServeOpts = @import("../ServeOpts.zig");

const TEST_OPTS: ServeOpts = .{
    .max_streams = 2,
    .max_body = 64,
    .max_header_scratch = 64,
    .conn_read_buf_min = 1024,
};

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

