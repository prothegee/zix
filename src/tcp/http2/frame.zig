//! HTTP/2 frame codec: constants, FrameHeader, read/write, control frame senders.

const std = @import("std");

// --------------------------------------------------------- //

pub const PREFACE = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n";

/// HTTP/2 frame header length in octets (RFC 7540 section 4.1): 3 length + 1 type + 1 flags + 4 stream id.
pub const FRAME_HEADER_LEN: usize = 9;

/// Slack added over the negotiated SETTINGS_MAX_FRAME_SIZE when sizing a read or
/// staging buffer: covers the frame header plus small HPACK and control overhead.
pub const FRAME_PAYLOAD_SLACK: usize = 256;

/// Default initial flow-control window (RFC 7540 6.9.2). Also the per-step
/// connection-level WINDOW_UPDATE increment (grant one default window of credit).
pub const DEFAULT_WINDOW_SIZE: u32 = 65535;

/// HPACK encode scratch for one response HEADERS block.
pub const HPACK_ENCODE_SCRATCH: usize = 512;

pub const FRAME_TYPE_DATA: u8 = 0x00;
pub const FRAME_TYPE_HEADERS: u8 = 0x01;
pub const FRAME_TYPE_PRIORITY: u8 = 0x02;
pub const FRAME_TYPE_RST_STREAM: u8 = 0x03;
pub const FRAME_TYPE_SETTINGS: u8 = 0x04;
pub const FRAME_TYPE_PUSH_PROMISE: u8 = 0x05;
pub const FRAME_TYPE_PING: u8 = 0x06;
pub const FRAME_TYPE_GOAWAY: u8 = 0x07;
pub const FRAME_TYPE_WINDOW_UPDATE: u8 = 0x08;
pub const FRAME_TYPE_CONTINUATION: u8 = 0x09;

pub const FLAG_END_STREAM: u8 = 0x01;
pub const FLAG_END_HEADERS: u8 = 0x04;
pub const FLAG_PADDED: u8 = 0x08;
pub const FLAG_PRIORITY: u8 = 0x20;
pub const FLAG_ACK: u8 = 0x01;

pub const ERR_NO_ERROR: u32 = 0x00;
pub const ERR_PROTOCOL_ERROR: u32 = 0x01;
pub const ERR_INTERNAL_ERROR: u32 = 0x02;
pub const ERR_FLOW_CONTROL_ERROR: u32 = 0x03;
pub const ERR_SETTINGS_TIMEOUT: u32 = 0x04;
pub const ERR_STREAM_CLOSED: u32 = 0x05;
pub const ERR_FRAME_SIZE_ERROR: u32 = 0x06;
pub const ERR_REFUSED_STREAM: u32 = 0x07;
pub const ERR_CANCEL: u32 = 0x08;
pub const ERR_COMPRESSION_ERROR: u32 = 0x09;
pub const ERR_CONNECT_ERROR: u32 = 0x0a;
pub const ERR_ENHANCE_YOUR_CALM: u32 = 0x0b;
pub const ERR_INADEQUATE_SECURITY: u32 = 0x0c;
pub const ERR_HTTP_1_1_REQUIRED: u32 = 0x0d;

pub const SETTINGS_HEADER_TABLE_SIZE: u16 = 0x01;
pub const SETTINGS_ENABLE_PUSH: u16 = 0x02;
pub const SETTINGS_MAX_CONCURRENT_STREAMS: u16 = 0x03;
pub const SETTINGS_INITIAL_WINDOW_SIZE: u16 = 0x04;
pub const SETTINGS_MAX_FRAME_SIZE: u16 = 0x05;
pub const SETTINGS_MAX_HEADER_LIST_SIZE: u16 = 0x06;

pub const DEFAULT_INITIAL_WINDOW: u32 = 65535;
pub const DEFAULT_MAX_FRAME_SIZE: u32 = 16384;
pub const MAX_HEADERS: usize = 64;
pub const MAX_PAYLOAD: usize = 16384;

// --------------------------------------------------------- //

pub const FrameHeader = struct {
    length: u24,
    frame_type: u8,
    flags: u8,
    stream_id: u31,
};

/// Parse a 9-byte frame header from buf (len >= 9). No I/O. Use with a buffered reader.
pub fn parseFrameHeader(buf: []const u8) FrameHeader {
    const length: u24 = (@as(u24, buf[0]) << 16) | (@as(u24, buf[1]) << 8) | buf[2];
    const stream_id: u31 = @intCast(
        ((@as(u32, buf[5]) << 24) | (@as(u32, buf[6]) << 16) | (@as(u32, buf[7]) << 8) | buf[8]) & 0x7FFF_FFFF,
    );
    return .{
        .length = length,
        .frame_type = buf[3],
        .flags = buf[4],
        .stream_id = stream_id,
    };
}

pub fn readFrameHeader(fd: std.posix.fd_t) !FrameHeader {
    var buf: [FRAME_HEADER_LEN]u8 = undefined;
    try recvExact(fd, &buf);
    return parseFrameHeader(&buf);
}

/// Encode a 9-byte frame header into buf. No I/O. Use for staged/coalesced writes.
pub fn encodeFrameHeader(buf: *[FRAME_HEADER_LEN]u8, fh: FrameHeader) void {
    buf[0] = @intCast((fh.length >> 16) & 0xFF);
    buf[1] = @intCast((fh.length >> 8) & 0xFF);
    buf[2] = @intCast(fh.length & 0xFF);
    buf[3] = fh.frame_type;
    buf[4] = fh.flags;
    const sid: u32 = fh.stream_id;
    buf[5] = @intCast((sid >> 24) & 0xFF);
    buf[6] = @intCast((sid >> 16) & 0xFF);
    buf[7] = @intCast((sid >> 8) & 0xFF);
    buf[8] = @intCast(sid & 0xFF);
}

pub fn writeFrameHeader(fd: std.posix.fd_t, fh: FrameHeader) !void {
    var buf: [FRAME_HEADER_LEN]u8 = undefined;
    encodeFrameHeader(&buf, fh);
    try fdWriteAll(fd, &buf);
}

// --------------------------------------------------------- //

/// Thread-local output redirect. When set, `fdWriteAll` hands the plaintext to the hook instead of
/// writing it to the fd. The h2-over-TLS path uses this to encrypt the engine's frames before they
/// reach the socket, so the resumable mux runs unchanged over a TLS connection (no socketpair, no
/// second thread). Null on the cleartext path, where writes go straight to the fd.
pub threadlocal var write_hook: ?*const fn (ctx: *anyopaque, bytes: []const u8) void = null;
pub threadlocal var write_hook_ctx: ?*anyopaque = null;

pub fn fdWriteAll(fd: std.posix.fd_t, data: []const u8) error{BrokenPipe}!void {
    if (write_hook) |hook| {
        hook(write_hook_ctx.?, data);
        return;
    }

    return fdWriteAllRaw(fd, data);
}

/// Hook-bypassing blocking write-all. A coalescing sink installed as the write hook flushes its
/// staged bytes through this so the flush does not re-enter the hook (which would recurse). Polls on
/// EAGAIN for a non-blocking socket. Identical to fdWriteAll minus the hook check.
pub fn fdWriteAllRaw(fd: std.posix.fd_t, data: []const u8) error{BrokenPipe}!void {
    var rem = data;
    while (rem.len > 0) {
        const rc = std.posix.system.write(fd, rem.ptr, rem.len);
        switch (std.posix.errno(rc)) {
            .SUCCESS => {
                const n: usize = @intCast(rc);
                if (n == 0) return error.BrokenPipe;
                rem = rem[n..];
            },
            .INTR => continue,
            // Non-blocking EPOLL socket with a full send buffer: poll until
            // writable then retry. Blocking sockets never hit this branch.
            .AGAIN => {
                var pfd = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.OUT, .revents = 0 }};
                _ = std.posix.poll(&pfd, -1) catch return error.BrokenPipe;
            },
            else => return error.BrokenPipe,
        }
    }
}

pub fn recvExact(fd: std.posix.fd_t, buf: []u8) !void {
    var filled: usize = 0;
    while (filled < buf.len) {
        const n = std.posix.read(fd, buf[filled..]) catch return error.Closed;
        if (n == 0) return error.Closed;
        filled += n;
    }
}

// --------------------------------------------------------- //

pub fn sendSettings(fd: std.posix.fd_t, params: []const [2]u32) !void {
    const payload_len: usize = params.len * 6;
    try writeFrameHeader(fd, .{
        .length = @intCast(payload_len),
        .frame_type = FRAME_TYPE_SETTINGS,
        .flags = 0,
        .stream_id = 0,
    });
    var buf: [6]u8 = undefined;
    for (params) |p| {
        const id: u16 = @intCast(p[0]);
        const val: u32 = p[1];
        buf[0] = @intCast((id >> 8) & 0xFF);
        buf[1] = @intCast(id & 0xFF);
        buf[2] = @intCast((val >> 24) & 0xFF);
        buf[3] = @intCast((val >> 16) & 0xFF);
        buf[4] = @intCast((val >> 8) & 0xFF);
        buf[5] = @intCast(val & 0xFF);
        try fdWriteAll(fd, &buf);
    }
}

pub fn sendSettingsAck(fd: std.posix.fd_t) !void {
    try writeFrameHeader(fd, .{
        .length = 0,
        .frame_type = FRAME_TYPE_SETTINGS,
        .flags = FLAG_ACK,
        .stream_id = 0,
    });
}

pub fn sendPingAck(fd: std.posix.fd_t, payload: [8]u8) !void {
    try writeFrameHeader(fd, .{
        .length = 8,
        .frame_type = FRAME_TYPE_PING,
        .flags = FLAG_ACK,
        .stream_id = 0,
    });
    try fdWriteAll(fd, &payload);
}

pub fn sendGoaway(fd: std.posix.fd_t, last_stream: u31, error_code: u32) !void {
    try writeFrameHeader(fd, .{
        .length = 8,
        .frame_type = FRAME_TYPE_GOAWAY,
        .flags = 0,
        .stream_id = 0,
    });
    var buf: [8]u8 = undefined;
    const ls: u32 = last_stream;
    buf[0] = @intCast((ls >> 24) & 0xFF);
    buf[1] = @intCast((ls >> 16) & 0xFF);
    buf[2] = @intCast((ls >> 8) & 0xFF);
    buf[3] = @intCast(ls & 0xFF);
    buf[4] = @intCast((error_code >> 24) & 0xFF);
    buf[5] = @intCast((error_code >> 16) & 0xFF);
    buf[6] = @intCast((error_code >> 8) & 0xFF);
    buf[7] = @intCast(error_code & 0xFF);
    try fdWriteAll(fd, &buf);
}

pub fn sendRstStream(fd: std.posix.fd_t, stream_id: u31, error_code: u32) !void {
    try writeFrameHeader(fd, .{
        .length = 4,
        .frame_type = FRAME_TYPE_RST_STREAM,
        .flags = 0,
        .stream_id = stream_id,
    });
    var buf: [4]u8 = undefined;
    buf[0] = @intCast((error_code >> 24) & 0xFF);
    buf[1] = @intCast((error_code >> 16) & 0xFF);
    buf[2] = @intCast((error_code >> 8) & 0xFF);
    buf[3] = @intCast(error_code & 0xFF);
    try fdWriteAll(fd, &buf);
}

pub fn sendWindowUpdate(fd: std.posix.fd_t, stream_id: u31, increment: u31) !void {
    try writeFrameHeader(fd, .{
        .length = 4,
        .frame_type = FRAME_TYPE_WINDOW_UPDATE,
        .flags = 0,
        .stream_id = stream_id,
    });
    var buf: [4]u8 = undefined;
    const inc: u32 = increment;
    buf[0] = @intCast((inc >> 24) & 0xFF);
    buf[1] = @intCast((inc >> 16) & 0xFF);
    buf[2] = @intCast((inc >> 8) & 0xFF);
    buf[3] = @intCast(inc & 0xFF);
    try fdWriteAll(fd, &buf);
}

/// Send HEADERS + optional DATA for a complete response. Sets END_STREAM on DATA (or HEADERS when body is empty).
/// Not suitable for multi-step responses (e.g. gRPC trailers). Use writeFrameHeader + fdWriteAll directly for those.
pub fn sendResponse(
    fd: std.posix.fd_t,
    stream_id: u31,
    status: u16,
    content_type: []const u8,
    body: []const u8,
) !void {
    return sendResponseEncoded(fd, stream_id, status, content_type, "", body);
}

/// sendResponse plus an optional content-encoding header (for serving a precompressed body). An empty
/// content_encoding omits the header. The body is framed in <= DEFAULT_MAX_FRAME_SIZE DATA chunks.
/// This is the immediate, unmetered send (no flow control). For large bodies that may exceed the
/// peer's window use the multiplexed `mux.sendResponseStream`, which paces by WINDOW_UPDATE.
pub fn sendResponseEncoded(
    fd: std.posix.fd_t,
    stream_id: u31,
    status: u16,
    content_type: []const u8,
    content_encoding: []const u8,
    body: []const u8,
) !void {
    const hpack = @import("hpack.zig");
    var hdr_buf: [HPACK_ENCODE_SCRATCH]u8 = undefined;
    var enc = hpack.HpackEncoder.init(&hdr_buf);

    var status_str: [4]u8 = undefined;
    const status_s = std.fmt.bufPrint(&status_str, "{d}", .{status}) catch "200";
    try enc.writeHeader(":status", status_s);
    if (content_type.len > 0)
        try enc.writeHeader("content-type", content_type);
    if (content_encoding.len > 0)
        try enc.writeHeader("content-encoding", content_encoding);
    if (body.len > 0) {
        var cl_buf: [20]u8 = undefined;
        const cl_s = std.fmt.bufPrint(&cl_buf, "{d}", .{body.len}) catch "0";
        try enc.writeHeader("content-length", cl_s);
    }

    const hblock = enc.encoded();
    const end_stream_flag: u8 = if (body.len == 0) FLAG_END_STREAM | FLAG_END_HEADERS else FLAG_END_HEADERS;

    try writeFrameHeader(fd, .{
        .length = @intCast(hblock.len),
        .frame_type = FRAME_TYPE_HEADERS,
        .flags = end_stream_flag,
        .stream_id = stream_id,
    });
    try fdWriteAll(fd, hblock);

    if (body.len > 0) {
        // Frame the body in <= DEFAULT_MAX_FRAME_SIZE chunks: a single DATA frame larger than the
        // peer's max frame size (16384 by default) is a FRAME_SIZE_ERROR. The last chunk carries
        // END_STREAM.
        var off: usize = 0;
        while (off < body.len) {
            const chunk = @min(body.len - off, DEFAULT_MAX_FRAME_SIZE);
            const last = off + chunk == body.len;

            try writeFrameHeader(fd, .{
                .length = @intCast(chunk),
                .frame_type = FRAME_TYPE_DATA,
                .flags = if (last) FLAG_END_STREAM else 0,
                .stream_id = stream_id,
            });
            try fdWriteAll(fd, body[off..][0..chunk]);

            off += chunk;
        }
    }
}

// --------------------------------------------------------- //

test "zix test: fdWriteAll delivers data on a blocking fd" {
    const fds = try std.Io.Threaded.pipe2(.{});
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    try fdWriteAll(fds[1], "frame");
    _ = std.posix.system.close(fds[1]);

    var buf: [8]u8 = undefined;
    const n = try std.posix.read(fds[0], &buf);
    try std.testing.expectEqualStrings("frame", buf[0..n]);
}

test "zix test: sendResponse chunks a body past the max frame size, END_STREAM on the last" {
    const fds = try std.Io.Threaded.pipe2(.{});
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    var body: [40000]u8 = undefined;
    @memset(&body, 'a');
    try sendResponse(fds[1], 1, 200, "text/plain", &body);
    _ = std.posix.system.close(fds[1]);

    var buf: [64 * 1024]u8 = undefined;
    var total: usize = 0;
    while (total < buf.len) {
        const got = std.posix.read(fds[0], buf[total..]) catch break;
        if (got == 0) break;
        total += got;
    }

    var off: usize = 0;
    var data_bytes: usize = 0;
    var last_data_flags: u8 = 0;
    while (off + FRAME_HEADER_LEN <= total) {
        const fh = parseFrameHeader(buf[off..][0..FRAME_HEADER_LEN]);
        off += FRAME_HEADER_LEN;

        if (fh.frame_type == FRAME_TYPE_DATA) {
            try std.testing.expect(fh.length <= DEFAULT_MAX_FRAME_SIZE);
            data_bytes += fh.length;
            last_data_flags = fh.flags;
        }

        off += fh.length;
    }

    try std.testing.expectEqual(@as(usize, 40000), data_bytes);
    try std.testing.expect((last_data_flags & FLAG_END_STREAM) != 0);
}

test "zix test: frame constants, FRAME_TYPE_HEADERS is 0x01" {
    try std.testing.expectEqual(@as(u8, 0x01), FRAME_TYPE_HEADERS);
}

test "zix test: frame constants, FLAG_END_STREAM is 0x01" {
    try std.testing.expectEqual(@as(u8, 0x01), FLAG_END_STREAM);
}

test "zix test: frame constants, ERR_NO_ERROR is 0" {
    try std.testing.expectEqual(@as(u32, 0), ERR_NO_ERROR);
}

test "zix test: writeFrameHeader and readFrameHeader roundtrip via pipe" {
    const fds = try std.Io.Threaded.pipe2(.{});
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    const fh = FrameHeader{
        .length = 42,
        .frame_type = FRAME_TYPE_HEADERS,
        .flags = FLAG_END_HEADERS,
        .stream_id = 3,
    };
    try writeFrameHeader(fds[1], fh);
    _ = std.posix.system.close(fds[1]);

    const got = try readFrameHeader(fds[0]);
    try std.testing.expectEqual(fh.length, got.length);
    try std.testing.expectEqual(fh.frame_type, got.frame_type);
    try std.testing.expectEqual(fh.flags, got.flags);
    try std.testing.expectEqual(fh.stream_id, got.stream_id);
}

test "zix test: PREFACE starts with PRI" {
    try std.testing.expect(std.mem.startsWith(u8, PREFACE, "PRI"));
    try std.testing.expectEqual(@as(usize, 24), PREFACE.len);
}

test "zix test: sendSettings empty params writes 9-byte SETTINGS frame via pipe" {
    const fds = try std.Io.Threaded.pipe2(.{});
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    try sendSettings(fds[1], &.{});
    _ = std.posix.system.close(fds[1]);

    const fh = try readFrameHeader(fds[0]);
    try std.testing.expectEqual(@as(u8, FRAME_TYPE_SETTINGS), fh.frame_type);
    try std.testing.expectEqual(@as(u24, 0), fh.length);
    try std.testing.expectEqual(@as(u31, 0), fh.stream_id);
}
