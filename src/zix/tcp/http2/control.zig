//! ZIX Http2 control
//!
//! ### file: src/zix/tcp/http2/control.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Senders for HTTP/2 control frames: SETTINGS, PING ack, GOAWAY, RST_STREAM,
//! and WINDOW_UPDATE.
//!
//! ### note:
//!
//! n/a
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
const frame = @import("frame.zig");
const writer = @import("writer.zig");

// --------------------------------------------------------- //
// Private:

const PING_PAYLOAD_LEN: usize = 8;
const GOAWAY_PAYLOAD_LEN: usize = 8;
/// RST_STREAM and WINDOW_UPDATE both carry one 32-bit value.
const U32_PAYLOAD_LEN: usize = 4;

/// Most SETTINGS parameters that fit the 24-bit frame length.
const MAX_SETTINGS_PARAMS: usize = std.math.maxInt(u24) / frame.SETTINGS_PARAM_LEN;

fn innerError(err: writer.Error) Error {
    @branchHint(.cold);

    return switch (err) {
        error.ZixHttp2_Writer_BrokenPipe => Error.ZixHttp2_Control_BrokenPipe,
        error.ZixHttp2_Writer_UnexpectedEOF => Error.ZixHttp2_Control_UnexpectedEOF,
        error.ZixHttp2_Writer_Overflow => Error.ZixHttp2_Control_Overflow,
        error.ZixHttp2_Writer_BufferFull => Error.ZixHttp2_Control_BufferFull,
    };
}

fn writeFD(fd: std.posix.fd_t, data: []const u8) Error!void {
    writer.writeAllFD(fd, data) catch |err| return innerError(err);
}

/// Send one frame whose payload is a single big-endian u32.
fn sendU32FrameFD(
    fd: std.posix.fd_t,
    frame_type: u8,
    stream_id: u31,
    value: u32,
) Error!void {
    var buf: [frame.FRAME_HEADER_LEN + U32_PAYLOAD_LEN]u8 = undefined;
    frame.encodeFrameHeader(buf[0..frame.FRAME_HEADER_LEN], .{
        .length = U32_PAYLOAD_LEN,
        .frame_type = frame_type,
        .flags = 0,
        .stream_id = stream_id,
    });
    std.mem.writeInt(u32, buf[frame.FRAME_HEADER_LEN..][0..4], value, .big);

    return writeFD(fd, &buf);
}

// --------------------------------------------------------- //
// Public:

/// ZIX Http2 control error
pub const Error = error {
    ZixHttp2_Control_BrokenPipe,
    ZixHttp2_Control_TooManySettings,
    ZixHttp2_Control_UnexpectedEOF,
    ZixHttp2_Control_Overflow,
    ZixHttp2_Control_BufferFull,
};

/// Send a SETTINGS frame with the given parameters.
///
/// Param:
/// fd - std.posix.fd_t (the connection)
/// params - []const [2]u32 (each entry is `{ SETTINGS_* id, value }`)
///
/// Return:
/// - void when the frame was sent
/// - error.ZixHttp2_Control_TooManySettings when params do not fit one frame
/// - error.ZixHttp2_Control_BrokenPipe on a write error
pub fn sendSettingsFD(fd: std.posix.fd_t, params: []const [2]u32) Error!void {
    if (params.len > MAX_SETTINGS_PARAMS) return Error.ZixHttp2_Control_TooManySettings;

    var head: [frame.FRAME_HEADER_LEN]u8 = undefined;
    frame.encodeFrameHeader(&head, .{
        .length = @intCast(params.len * frame.SETTINGS_PARAM_LEN),
        .frame_type = frame.FRAME_TYPE_SETTINGS,
        .flags = 0,
        .stream_id = 0,
    });

    try writeFD(fd, &head);

    var entry: [frame.SETTINGS_PARAM_LEN]u8 = undefined;
    for (params) |param| {
        std.mem.writeInt(u16, entry[0..2], @truncate(param[0]), .big);
        std.mem.writeInt(u32, entry[2..6], param[1], .big);

        try writeFD(fd, &entry);
    }
}

/// Acknowledge the peer SETTINGS frame.
///
/// Param:
/// fd - std.posix.fd_t (the connection)
///
/// Return:
/// - void when the frame was sent
/// - error.ZixHttp2_Control_BrokenPipe on a write error
pub fn sendSettingsAckFD(fd: std.posix.fd_t) Error!void {
    var buf: [frame.FRAME_HEADER_LEN]u8 = undefined;
    frame.encodeFrameHeader(&buf, .{
        .length = 0,
        .frame_type = frame.FRAME_TYPE_SETTINGS,
        .flags = frame.FLAG_ACK,
        .stream_id = 0,
    });

    return writeFD(fd, &buf);
}

/// Answer a PING, echoing its 8-byte payload.
///
/// Param:
/// fd - std.posix.fd_t (the connection)
/// payload - [8]u8 (the payload of the PING being answered)
///
/// Return:
/// - void when the frame was sent
/// - error.ZixHttp2_Control_BrokenPipe on a write error
pub fn sendPingAckFD(fd: std.posix.fd_t, payload: [PING_PAYLOAD_LEN]u8) Error!void {
    var buf: [frame.FRAME_HEADER_LEN + PING_PAYLOAD_LEN]u8 = undefined;
    frame.encodeFrameHeader(buf[0..frame.FRAME_HEADER_LEN], .{
        .length = PING_PAYLOAD_LEN,
        .frame_type = frame.FRAME_TYPE_PING,
        .flags = frame.FLAG_ACK,
        .stream_id = 0,
    });
    buf[frame.FRAME_HEADER_LEN..].* = payload;

    return writeFD(fd, &buf);
}

/// Tell the peer the connection is closing.
///
/// Param:
/// fd - std.posix.fd_t (the connection)
/// last_stream - u31 (highest stream id this side processed)
/// error_code - u32 (one of the ERR_* values in frame.zig)
///
/// Return:
/// - void when the frame was sent
/// - error.ZixHttp2_Control_BrokenPipe on a write error
pub fn sendGoawayFD(fd: std.posix.fd_t, last_stream: u31, error_code: u32) Error!void {
    var buf: [frame.FRAME_HEADER_LEN + GOAWAY_PAYLOAD_LEN]u8 = undefined;
    frame.encodeFrameHeader(buf[0..frame.FRAME_HEADER_LEN], .{
        .length = GOAWAY_PAYLOAD_LEN,
        .frame_type = frame.FRAME_TYPE_GOAWAY,
        .flags = 0,
        .stream_id = 0,
    });
    std.mem.writeInt(u32, buf[frame.FRAME_HEADER_LEN..][0..4], last_stream, .big);
    std.mem.writeInt(u32, buf[frame.FRAME_HEADER_LEN + 4 ..][0..4], error_code, .big);

    return writeFD(fd, &buf);
}

/// Abort one stream.
///
/// Param:
/// fd - std.posix.fd_t (the connection)
/// stream_id - u31 (the stream to abort)
/// error_code - u32 (one of the ERR_* values in frame.zig)
///
/// Return:
/// - void when the frame was sent
/// - error.ZixHttp2_Control_BrokenPipe on a write error
pub fn sendRstStreamFD(fd: std.posix.fd_t, stream_id: u31, error_code: u32) Error!void {
    return sendU32FrameFD(fd, frame.FRAME_TYPE_RST_STREAM, stream_id, error_code);
}

/// Grant the peer more flow-control window.
///
/// Param:
/// fd - std.posix.fd_t (the connection)
/// stream_id - u31 (the stream, 0 for the whole connection)
/// increment - u31 (octets of window to add)
///
/// Return:
/// - void when the frame was sent
/// - error.ZixHttp2_Control_BrokenPipe on a write error
pub fn sendWindowUpdateFD(fd: std.posix.fd_t, stream_id: u31, increment: u31) Error!void {
    return sendU32FrameFD(fd, frame.FRAME_TYPE_WINDOW_UPDATE, stream_id, increment);
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const pair = @import("../../utils/socket/pair.zig");
const reader = @import("reader.zig");

fn testReadPayload(fd: std.posix.fd_t, buf: []u8) ![]u8 {
    try reader.recvExact(fd, buf);

    return buf;
}

test "zix http2: control, sendSettingsFD with no params is an empty SETTINGS frame" {
    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    try sendSettingsFD(fds[1], &.{});

    const header = try reader.readFrameHeader(fds[0]);

    try std.testing.expectEqual(frame.FRAME_TYPE_SETTINGS, header.frame_type);
    try std.testing.expectEqual(@as(u24, 0), header.length);
    try std.testing.expectEqual(@as(u31, 0), header.stream_id);
}

test "zix http2: control, sendSettingsFD encodes each param" {
    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    try sendSettingsFD(fds[1], &.{
        .{ frame.SETTINGS_MAX_CONCURRENT_STREAMS, 100 },
        .{ frame.SETTINGS_INITIAL_WINDOW_SIZE, 0x01020304 },
    });

    const header = try reader.readFrameHeader(fds[0]);
    try std.testing.expectEqual(@as(u24, 12), header.length);

    var buf: [12]u8 = undefined;
    const payload = try testReadPayload(fds[0], &buf);

    const want = [_]u8{
        0x00, 0x03, 0x00, 0x00, 0x00, 0x64,
        0x00, 0x04, 0x01, 0x02, 0x03, 0x04,
    };
    try std.testing.expectEqualSlices(u8, &want, payload);
}

test "zix http2: control, sendSettingsFD past the 24-bit length is TooManySettings" {
    const too_many = try std.testing.allocator.alloc([2]u32, MAX_SETTINGS_PARAMS + 1);
    defer std.testing.allocator.free(too_many);

    const result = sendSettingsFD(-1, too_many);

    try std.testing.expectError(Error.ZixHttp2_Control_TooManySettings, result);
}

test "zix http2: control, sendSettingsAckFD sets ACK with no payload" {
    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    try sendSettingsAckFD(fds[1]);

    const header = try reader.readFrameHeader(fds[0]);

    try std.testing.expectEqual(frame.FRAME_TYPE_SETTINGS, header.frame_type);
    try std.testing.expectEqual(frame.FLAG_ACK, header.flags);
    try std.testing.expectEqual(@as(u24, 0), header.length);
}

test "zix http2: control, sendPingAckFD echoes the payload" {
    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    const ping = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };
    try sendPingAckFD(fds[1], ping);

    const header = try reader.readFrameHeader(fds[0]);
    try std.testing.expectEqual(frame.FRAME_TYPE_PING, header.frame_type);
    try std.testing.expectEqual(frame.FLAG_ACK, header.flags);

    var buf: [8]u8 = undefined;

    try std.testing.expectEqualSlices(u8, &ping, try testReadPayload(fds[0], &buf));
}

test "zix http2: control, sendGoawayFD carries last stream and error code" {
    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    try sendGoawayFD(fds[1], 7, frame.ERR_PROTOCOL_ERROR);

    const header = try reader.readFrameHeader(fds[0]);
    try std.testing.expectEqual(frame.FRAME_TYPE_GOAWAY, header.frame_type);
    try std.testing.expectEqual(@as(u31, 0), header.stream_id);

    var buf: [8]u8 = undefined;
    const payload = try testReadPayload(fds[0], &buf);

    try std.testing.expectEqual(@as(u32, 7), std.mem.readInt(u32, payload[0..4], .big));
    try std.testing.expectEqual(
        frame.ERR_PROTOCOL_ERROR,
        std.mem.readInt(u32, payload[4..8], .big),
    );
}

test "zix http2: control, sendRstStreamFD targets the stream" {
    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    try sendRstStreamFD(fds[1], 5, frame.ERR_CANCEL);

    const header = try reader.readFrameHeader(fds[0]);
    try std.testing.expectEqual(frame.FRAME_TYPE_RST_STREAM, header.frame_type);
    try std.testing.expectEqual(@as(u31, 5), header.stream_id);

    var buf: [4]u8 = undefined;
    const payload = try testReadPayload(fds[0], &buf);

    try std.testing.expectEqual(frame.ERR_CANCEL, std.mem.readInt(u32, payload[0..4], .big));
}

test "zix http2: control, sendWindowUpdateFD carries the increment" {
    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    try sendWindowUpdateFD(fds[1], 0, frame.DEFAULT_INITIAL_WINDOW);

    const header = try reader.readFrameHeader(fds[0]);
    try std.testing.expectEqual(frame.FRAME_TYPE_WINDOW_UPDATE, header.frame_type);
    try std.testing.expectEqual(@as(u24, 4), header.length);

    var buf: [4]u8 = undefined;
    const payload = try testReadPayload(fds[0], &buf);

    try std.testing.expectEqual(
        frame.DEFAULT_INITIAL_WINDOW,
        std.mem.readInt(u32, payload[0..4], .big),
    );
}

test "zix http2: control, sendWindowUpdateFD largest increment keeps the top bit clear" {
    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    try sendWindowUpdateFD(fds[1], 1, std.math.maxInt(u31));

    _ = try reader.readFrameHeader(fds[0]);

    var buf: [4]u8 = undefined;
    const payload = try testReadPayload(fds[0], &buf);

    try std.testing.expectEqual(
        @as(u32, 0x7FFF_FFFF),
        std.mem.readInt(u32, payload[0..4], .big),
    );
}

test "zix http2: control, send to a closed peer is BrokenPipe" {
    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    try std.testing.expectError(Error.ZixHttp2_Control_BrokenPipe, sendSettingsAckFD(fds[1]));
}

