//! ZIX Http2 Grpc mux stage_frame
//!
//! ### file: src/zix/tcp/http2/grpc/mux/stage_frame.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Append h2 control frames to a mux connection's reply stage.
//!
//! ### note:
//!
//! Nothing here writes to the fd: the stage flushes once per readable event.
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
const ReplyStage = @import("../ReplyStage.zig");

// --------------------------------------------------------- //
// Private:

/// Bytes in a RST_STREAM or WINDOW_UPDATE payload.
const WORD_LEN: usize = 4;

/// Bytes in a GOAWAY payload without debug data.
const GOAWAY_LEN: usize = 8;

// --------------------------------------------------------- //
// Public:

/// Stage one whole frame: the frame header, then the payload.
///
/// Param:
/// stage - *ReplyStage (the connection's reply stage)
/// frame_type - u8 (FRAME_TYPE_*)
/// flags - u8 (FLAG_*)
/// sid - u31 (the stream, 0 for the connection)
/// payload - []const u8 (frame payload, fits in a u24)
///
/// Return:
/// - void
pub fn append(
    stage: *ReplyStage,
    frame_type: u8,
    flags: u8,
    sid: u31,
    payload: []const u8,
) void {
    var head: [frame.FRAME_HEADER_LEN]u8 = undefined;
    frame.encodeFrameHeader(&head, .{
        .length = @intCast(payload.len),
        .frame_type = frame_type,
        .flags = flags,
        .stream_id = sid,
    });

    stage.append(&head);
    if (payload.len > 0) stage.append(payload);
}

/// Stage a WINDOW_UPDATE.
pub fn windowUpdate(stage: *ReplyStage, sid: u31, increment: u31) void {
    var payload: [WORD_LEN]u8 = undefined;
    std.mem.writeInt(u32, &payload, increment, .big);

    append(stage, frame.FRAME_TYPE_WINDOW_UPDATE, 0, sid, &payload);
}

/// Stage a GOAWAY without debug data.
pub fn goaway(stage: *ReplyStage, last_stream_id: u31, error_code: u32) void {
    var payload: [GOAWAY_LEN]u8 = undefined;
    std.mem.writeInt(u32, payload[0..WORD_LEN], last_stream_id, .big);
    std.mem.writeInt(u32, payload[WORD_LEN..GOAWAY_LEN], error_code, .big);

    append(stage, frame.FRAME_TYPE_GOAWAY, 0, 0, &payload);
}

/// Stage a RST_STREAM.
pub fn rstStream(stage: *ReplyStage, sid: u31, error_code: u32) void {
    var payload: [WORD_LEN]u8 = undefined;
    std.mem.writeInt(u32, &payload, error_code, .big);

    append(stage, frame.FRAME_TYPE_RST_STREAM, 0, sid, &payload);
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const builtin = @import("builtin");

/// A descriptor the stage never writes to: every test fits its buffer.
const TEST_FD: std.posix.fd_t = if (builtin.os.tag == .windows)
    std.os.windows.INVALID_HANDLE_VALUE
else
    -1;

fn testStage(backing: []u8) ReplyStage {
    return .{
        .fd = TEST_FD,
        .buf = backing,
    };
}

test "zix http2 grpc mux: stage_frame, append stages header then payload" {
    var backing: [64]u8 = undefined;
    var stage = testStage(&backing);

    append(&stage, frame.FRAME_TYPE_PING, frame.FLAG_ACK, 0, "12345678");

    const header = frame.parseFrameHeader(stage.buf[0..frame.FRAME_HEADER_LEN]);

    try std.testing.expectEqual(frame.FRAME_TYPE_PING, header.frame_type);
    try std.testing.expectEqual(frame.FLAG_ACK, header.flags);
    try std.testing.expectEqual(@as(u24, 8), header.length);
    try std.testing.expectEqualStrings("12345678", stage.buf[frame.FRAME_HEADER_LEN..stage.len]);
}

test "zix http2 grpc mux: stage_frame, append with an empty payload stages the header only" {
    var backing: [64]u8 = undefined;
    var stage = testStage(&backing);

    append(&stage, frame.FRAME_TYPE_SETTINGS, frame.FLAG_ACK, 0, "");

    try std.testing.expectEqual(frame.FRAME_HEADER_LEN, stage.len);
}

test "zix http2 grpc mux: stage_frame, windowUpdate carries the increment" {
    var backing: [64]u8 = undefined;
    var stage = testStage(&backing);

    windowUpdate(&stage, 0, 4096);

    const header = frame.parseFrameHeader(stage.buf[0..frame.FRAME_HEADER_LEN]);
    const increment = std.mem.readInt(u32, stage.buf[frame.FRAME_HEADER_LEN..][0..4], .big);

    try std.testing.expectEqual(frame.FRAME_TYPE_WINDOW_UPDATE, header.frame_type);
    try std.testing.expectEqual(@as(u32, 4096), increment);
}

test "zix http2 grpc mux: stage_frame, goaway carries last stream and code" {
    var backing: [64]u8 = undefined;
    var stage = testStage(&backing);

    goaway(&stage, 7, frame.ERR_PROTOCOL_ERROR);

    const header = frame.parseFrameHeader(stage.buf[0..frame.FRAME_HEADER_LEN]);
    const payload = stage.buf[frame.FRAME_HEADER_LEN..stage.len];

    try std.testing.expectEqual(frame.FRAME_TYPE_GOAWAY, header.frame_type);
    try std.testing.expectEqual(@as(u31, 0), header.stream_id);
    try std.testing.expectEqual(@as(u32, 7), std.mem.readInt(u32, payload[0..4], .big));
    try std.testing.expectEqual(
        frame.ERR_PROTOCOL_ERROR,
        std.mem.readInt(u32, payload[4..8], .big),
    );
}

test "zix http2 grpc mux: stage_frame, rstStream carries the stream and code" {
    var backing: [64]u8 = undefined;
    var stage = testStage(&backing);

    rstStream(&stage, 3, frame.ERR_REFUSED_STREAM);

    const header = frame.parseFrameHeader(stage.buf[0..frame.FRAME_HEADER_LEN]);
    const code = std.mem.readInt(u32, stage.buf[frame.FRAME_HEADER_LEN..][0..4], .big);

    try std.testing.expectEqual(frame.FRAME_TYPE_RST_STREAM, header.frame_type);
    try std.testing.expectEqual(@as(u31, 3), header.stream_id);
    try std.testing.expectEqual(frame.ERR_REFUSED_STREAM, code);
}

