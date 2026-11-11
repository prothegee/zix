//! ZIX Http2 Grpc mux mux_upgrade
//!
//! ### file: src/zix/tcp/http2/grpc/mux/mux_upgrade.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Answer the HTTP/1.1 h2c upgrade on the gRPC mux path: 101 for h2c,
//! 400 for anything else.
//!
//! ### note:
//!
//! The request carried on stream 1 by the upgrade is not served: gRPC
//! clients use prior knowledge, this path answers probes.
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
const upgrade = @import("../../upgrade.zig");
const ConnOutcome = @import("../../mux/conn_outcome.zig").ConnOutcome;
const MuxConn = @import("MuxConn.zig");

// --------------------------------------------------------- //
// Public:

/// Read the buffered HTTP/1.1 head and stage the answer.
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
        conn.stage.append(upgrade.BAD_REQUEST);

        return .close;
    }

    conn.stage.append(upgrade.SWITCHING_PROTOCOLS);

    conn.rstart += head.len;
    conn.phase = .await_preface2;

    return .keep_alive;
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const ServeOpts = @import("../ServeOpts.zig");

const TEST_OPTS: ServeOpts = .{
    .max_streams = 2,
    .max_body = 64,
    .max_header_scratch = 64,
    .conn_read_buf_min = 1024,
};

/// A descriptor nothing is written to: every answer fits the stage.
const UNUSED_FD: std.posix.fd_t = undefined;

const H2C_HEAD =
    "POST /svc.Svc/Method HTTP/1.1\r\n" ++
    "Host: localhost\r\n" ++
    "Connection: Upgrade, HTTP2-Settings\r\n" ++
    "Upgrade: h2c\r\n\r\n";

/// Load bytes into the connection's read buffer as if they had arrived.
fn feed(conn: *MuxConn, bytes: []const u8) void {
    @memcpy(conn.rbuf[conn.rend..][0..bytes.len], bytes);
    conn.rend += bytes.len;
}

fn staged(conn: *const MuxConn) []const u8 {
    return conn.stage.buf[0..conn.stage.len];
}

test "zix http2 grpc mux: mux_upgrade, an h2c head stages 101" {
    const conn = try MuxConn.init(UNUSED_FD, TEST_OPTS, std.testing.io);
    defer conn.deinit();

    conn.phase = .await_upgrade;
    feed(conn, H2C_HEAD ++ "PRI");

    try std.testing.expectEqual(ConnOutcome.keep_alive, handleUpgrade(conn));
    try std.testing.expect(std.mem.startsWith(u8, staged(conn), "HTTP/1.1 101"));
}

test "zix http2 grpc mux: mux_upgrade, an h2c head moves to await_preface2" {
    const conn = try MuxConn.init(UNUSED_FD, TEST_OPTS, std.testing.io);
    defer conn.deinit();

    conn.phase = .await_upgrade;
    feed(conn, H2C_HEAD ++ "PRI");
    _ = handleUpgrade(conn);

    try std.testing.expect(conn.phase == .await_preface2);
    try std.testing.expectEqualStrings("PRI", conn.buffered());
}

test "zix http2 grpc mux: mux_upgrade, a non-h2c head stages 400 and closes" {
    const conn = try MuxConn.init(UNUSED_FD, TEST_OPTS, std.testing.io);
    defer conn.deinit();

    feed(conn, "GET / HTTP/1.1\r\nHost: x\r\n\r\n");

    try std.testing.expectEqual(ConnOutcome.close, handleUpgrade(conn));
    try std.testing.expect(std.mem.startsWith(u8, staged(conn), "HTTP/1.1 400"));
}

test "zix http2 grpc mux: mux_upgrade, a partial head waits for more" {
    const conn = try MuxConn.init(UNUSED_FD, TEST_OPTS, std.testing.io);
    defer conn.deinit();

    feed(conn, "GET / HTTP/1.1\r\nUpgrade: h2c\r\n");

    try std.testing.expectEqual(ConnOutcome.keep_alive, handleUpgrade(conn));
    try std.testing.expectEqual(@as(usize, 0), conn.rstart);
    try std.testing.expectEqual(@as(usize, 0), conn.stage.len);
}

test "zix http2 grpc mux: mux_upgrade, a head that fills the buffer closes" {
    const conn = try MuxConn.init(UNUSED_FD, TEST_OPTS, std.testing.io);
    defer conn.deinit();

    @memset(conn.rbuf, 'h');
    conn.rend = conn.rbuf.len;

    try std.testing.expectEqual(ConnOutcome.close, handleUpgrade(conn));
}

