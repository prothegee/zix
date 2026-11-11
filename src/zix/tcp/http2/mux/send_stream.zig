//! ZIX Http2 mux send_stream
//!
//! ### file: src/zix/tcp/http2/mux/send_stream.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Flow-controlled response send for a handler running on a mux worker.
//!
//! ### note:
//!
//! - The body is referenced, not copied, so it must outlive the stream (a
//!   process lifetime cache, not a per-request buffer). For a small transient
//!   body use writer.sendResponseFD.
//! - Off a mux worker (the blocking serve path) the send falls back to an
//!   immediate write with no window metering.
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
const flow = @import("flow.zig");
const frame = @import("../frame.zig");
const response_block = @import("../hpack/response_block.zig");
const send_best_effort = @import("../send_best_effort.zig");
const writer = @import("../writer.zig");
const MuxConn = @import("MuxConn.zig");

// --------------------------------------------------------- //
// Private:

const Inner = writer.Error || response_block.Error;

/// Write the response HEADERS frame. content-length always rides it.
fn sendHeaders(
    fd: std.posix.fd_t,
    sid: u31,
    status: u16,
    content_type: []const u8,
    content_encoding: []const u8,
    content_length: usize,
) Inner!void {
    var block_buf: [frame.HPACK_ENCODE_SCRATCH]u8 = undefined;
    const block_len = try response_block.respHeaderBlock(
        &block_buf,
        status,
        content_type,
        content_encoding,
        content_length,
    );
    const flags: u8 = if (content_length == 0)
        frame.FLAG_END_HEADERS | frame.FLAG_END_STREAM
    else
        frame.FLAG_END_HEADERS;

    try writer.writeFrameHeaderFD(fd, .{
        .length = @intCast(block_len),
        .frame_type = frame.FRAME_TYPE_HEADERS,
        .flags = flags,
        .stream_id = sid,
    });

    try writer.writeAllFD(fd, block_buf[0..block_len]);
}

/// Send the whole response at once, best effort.
fn sendUnmetered(
    fd: std.posix.fd_t,
    sid: u31,
    status: u16,
    content_type: []const u8,
    content_encoding: []const u8,
    body: []const u8,
) void {
    writer.sendResponseEncodedFD(
        fd,
        sid,
        status,
        content_type,
        content_encoding,
        body,
    ) catch |err| switch (err) {
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

/// The connection whose handler runs on this worker right now. Set around each
/// mux dispatch, null everywhere else.
pub threadlocal var active_conn: ?*MuxConn = null;

/// Send a response with HTTP/2 send-side flow control: HEADERS, then DATA up
/// to the peer's windows, the rest parked until WINDOW_UPDATE.
///
/// Note:
/// - A header block that does not fit resets the stream with INTERNAL_ERROR
///   and sends no DATA.
///
/// Param:
/// fd - std.posix.fd_t (the connection)
/// sid - u31 (the stream to answer)
/// status - u16 (response status)
/// content_type - []const u8 (empty omits the header)
/// content_encoding - []const u8 (empty omits the header)
/// body - []const u8 (must outlive the stream, see the file note)
///
/// Return:
/// - void
pub fn sendResponseStreamFD(
    fd: std.posix.fd_t,
    sid: u31,
    status: u16,
    content_type: []const u8,
    content_encoding: []const u8,
    body: []const u8,
) void {
    const conn = active_conn orelse
        return sendUnmetered(fd, sid, status, content_type, content_encoding, body);
    const slot = (if (conn.fd == fd) conn.findSlot(sid) else null) orelse
        return sendUnmetered(fd, sid, status, content_type, content_encoding, body);

    sendHeaders(fd, sid, status, content_type, content_encoding, body.len) catch |err| {
        switch (err) {
            // The block can not be sent whole: reset rather than send a body
            // the peer can not frame.
            error.ZixHttp2_ResponseBlock_UnexpectedEOF,
            error.ZixHttp2_ResponseBlock_Overflow,
            error.ZixHttp2_ResponseBlock_BufferFull,
            => send_best_effort.rstStream(fd, sid, frame.ERR_INTERNAL_ERROR),
            // Best effort: a broken socket shows up on the next read.
            error.ZixHttp2_Writer_BrokenPipe,
            error.ZixHttp2_Writer_UnexpectedEOF,
            error.ZixHttp2_Writer_Overflow,
            error.ZixHttp2_Writer_BufferFull,
            => {},
        }

        return;
    };

    if (body.len == 0) return;

    flow.pumpBody(conn, conn.streams[slot], body, true);
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const builtin = @import("builtin");
const pair = @import("../../../utils/socket/pair.zig");
const Header = @import("../hpack/Header.zig");
const HpackDecoder = @import("../hpack/HpackDecoder.zig");
const ServeOpts = @import("../ServeOpts.zig");

/// What the wire carried, read back after the send.
const WireTally = struct {
    data_bytes: usize = 0,
    headers_frames: usize = 0,
    headers_end_stream: bool = false,
    rst_internal: usize = 0,
    content_length: [16]u8 = undefined,
    content_length_len: usize = 0,
};

const TEST_OPTS: ServeOpts = .{
    .max_streams = 4,
    .max_body = 64,
    .max_header_scratch = 64,
};

fn isLinux() bool {
    if (comptime builtin.target.os.tag == .linux) return true;

    std.log.info("this test drives a Linux socket pair, test skipped", .{});

    return false;
}

fn tallyWire(client_fd: std.posix.fd_t, server_fd: std.posix.fd_t, buf: []u8) WireTally {
    _ = std.os.linux.shutdown(server_fd, std.os.linux.SHUT.WR);

    var total: usize = 0;
    while (total < buf.len) {
        const got = std.posix.read(client_fd, buf[total..]) catch break;
        if (got == 0) break;

        total += got;
    }

    var tally: WireTally = .{};
    var decoder = HpackDecoder.init();
    var pos: usize = 0;

    while (pos + frame.FRAME_HEADER_LEN <= total) {
        const header = frame.parseFrameHeader(buf[pos..][0..frame.FRAME_HEADER_LEN]);
        pos += frame.FRAME_HEADER_LEN;
        const payload = buf[pos..][0..header.length];
        pos += header.length;

        switch (header.frame_type) {
            frame.FRAME_TYPE_DATA => tally.data_bytes += header.length,
            frame.FRAME_TYPE_RST_STREAM => {
                const code = std.mem.readInt(u32, payload[0..4], .big);
                if (code == frame.ERR_INTERNAL_ERROR) tally.rst_internal += 1;
            },
            frame.FRAME_TYPE_HEADERS => {
                tally.headers_frames += 1;
                tally.headers_end_stream = (header.flags & frame.FLAG_END_STREAM) != 0;

                var headers: [frame.MAX_HEADERS]Header = undefined;
                var scratch: [256]u8 = undefined;
                const count = decoder.decode(payload, &headers, &scratch) catch continue;

                for (headers[0..count]) |entry| {
                    if (!std.mem.eql(u8, entry.name, "content-length")) continue;

                    tally.content_length_len = entry.value.len;
                    @memcpy(tally.content_length[0..entry.value.len], entry.value);
                }
            },
            else => {},
        }
    }

    return tally;
}

test "zix http2 mux: send_stream, without a mux connection sends unmetered" {
    if (!isLinux()) return;

    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    active_conn = null;
    const body: [5000]u8 = @splat('u');
    sendResponseStreamFD(fds[1], 1, 200, "text/plain", "", &body);

    var buf: [8192]u8 = undefined;
    const tally = tallyWire(fds[0], fds[1], &buf);

    try std.testing.expectEqual(@as(usize, 5000), tally.data_bytes);
}

test "zix http2 mux: send_stream, parks the body past the send window" {
    if (!isLinux()) return;

    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    const conn = try MuxConn.init(fds[1], TEST_OPTS, std.testing.io);
    defer conn.deinit();

    conn.send_window = 100;
    const slot = conn.claimSlot(1).?;

    const body: [250]u8 = @splat('w');
    active_conn = conn;
    sendResponseStreamFD(fds[1], 1, 200, "text/plain", "", &body);
    active_conn = null;

    try std.testing.expectEqual(@as(usize, 150), conn.streams[slot].pending_body.len);

    var buf: [4096]u8 = undefined;
    const tally = tallyWire(fds[0], fds[1], &buf);

    try std.testing.expectEqual(@as(usize, 100), tally.data_bytes);
    try std.testing.expectEqualStrings(
        "250",
        tally.content_length[0..tally.content_length_len],
    );
}

test "zix http2 mux: send_stream, an empty body ends the stream on HEADERS" {
    if (!isLinux()) return;

    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    const conn = try MuxConn.init(fds[1], TEST_OPTS, std.testing.io);
    defer conn.deinit();

    _ = conn.claimSlot(1).?;

    active_conn = conn;
    sendResponseStreamFD(fds[1], 1, 204, "", "", "");
    active_conn = null;

    var buf: [1024]u8 = undefined;
    const tally = tallyWire(fds[0], fds[1], &buf);

    try std.testing.expectEqual(@as(usize, 1), tally.headers_frames);
    try std.testing.expect(tally.headers_end_stream);
    try std.testing.expectEqual(@as(usize, 0), tally.data_bytes);
}

test "zix http2 mux: send_stream, an unknown stream falls back to unmetered" {
    if (!isLinux()) return;

    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    const conn = try MuxConn.init(fds[1], TEST_OPTS, std.testing.io);
    defer conn.deinit();

    conn.send_window = 10;

    const body: [300]u8 = @splat('k');
    active_conn = conn;
    sendResponseStreamFD(fds[1], 9, 200, "text/plain", "", &body);
    active_conn = null;

    var buf: [4096]u8 = undefined;
    const tally = tallyWire(fds[0], fds[1], &buf);

    try std.testing.expectEqual(@as(usize, 300), tally.data_bytes);
}

test "zix http2 mux: send_stream, a header block too large resets the stream" {
    if (!isLinux()) return;

    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    const conn = try MuxConn.init(fds[1], TEST_OPTS, std.testing.io);
    defer conn.deinit();

    const slot = conn.claimSlot(1).?;

    const content_type: [frame.HPACK_ENCODE_SCRATCH]u8 = @splat('t');
    active_conn = conn;
    sendResponseStreamFD(fds[1], 1, 200, &content_type, "", "body");
    active_conn = null;

    try std.testing.expect(!conn.streams[slot].isParked());

    var buf: [1024]u8 = undefined;
    const tally = tallyWire(fds[0], fds[1], &buf);

    try std.testing.expectEqual(@as(usize, 1), tally.rst_internal);
    try std.testing.expectEqual(@as(usize, 0), tally.data_bytes);
}

