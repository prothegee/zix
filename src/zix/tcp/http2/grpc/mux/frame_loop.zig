//! ZIX Http2 Grpc mux frame_loop
//!
//! ### file: src/zix/tcp/http2/grpc/mux/frame_loop.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Handle every whole frame buffered on a gRPC mux connection, one frame at
//! a time, staging each answer.
//!
//! ### note:
//!
//! - A partial frame stays in rbuf until the next readable event.
//! - A body past max_body is shed with RESOURCE_EXHAUSTED, never truncated.
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
const builder = @import("../frame/builder.zig");
const frame = @import("../../frame.zig");
const frame_payload = @import("../../frame_payload.zig");
const mux_dispatch = @import("mux_dispatch.zig");
const peer_settings = @import("../../peer_settings.zig");
const stage_frame = @import("stage_frame.zig");
const window = @import("../window.zig");
const ConnOutcome = @import("../../mux/conn_outcome.zig").ConnOutcome;
const GrpcStatus = @import("../status.zig").GrpcStatus;
const MuxConn = @import("MuxConn.zig");

// --------------------------------------------------------- //
// Private:

/// Bytes in a PING payload.
const PING_LEN: usize = 8;

/// grpc-message for a body past max_body.
const BODY_TOO_LARGE_MESSAGE: []const u8 = "request message exceeds max_body";

/// Stage RESOURCE_EXHAUSTED trailers for a stream whose body went past max_body.
fn stageTooLarge(conn: *MuxConn, sid: u31) void {
    var out: [builder.HEADERS_FRAME_SCRATCH]u8 = undefined;
    const status_code = @intFromEnum(GrpcStatus.RESOURCE_EXHAUSTED);

    const len = builder.buildGrpcError(
        &out,
        sid,
        status_code,
        BODY_TOO_LARGE_MESSAGE,
    ) catch |err| switch (err) {
        // The message is fixed and fits the scratch: reset the stream instead.
        error.ZixHttp2_GrpcBuilder_UnexpectedEOF,
        error.ZixHttp2_GrpcBuilder_Overflow,
        error.ZixHttp2_GrpcBuilder_BufferFull,
        => {
            stage_frame.rstStream(&conn.stage, sid, frame.ERR_INTERNAL_ERROR);

            return;
        },
    };

    conn.stage.append(out[0..len]);
}

/// Dispatch the stream in slot once its headers and body are both in.
fn finishIfReady(comptime RouterType: type, conn: *MuxConn, slot: usize) void {
    const stream = conn.streams[slot];
    if (!(stream.end_headers and stream.end_stream)) return;

    mux_dispatch.dispatchWhole(RouterType, conn, stream);
    conn.releaseSlot(slot);
}

fn onSettings(conn: *MuxConn, flags: u8, payload: []const u8) void {
    if ((flags & frame.FLAG_ACK) != 0) return;

    // gRPC replies are small, so the peer frame cap is not read back.
    var peer_max_frame_size: u32 = frame.DEFAULT_MAX_FRAME_SIZE;
    _ = peer_settings.apply(payload, &conn.hpack_dec, &peer_max_frame_size);

    stage_frame.append(&conn.stage, frame.FRAME_TYPE_SETTINGS, frame.FLAG_ACK, 0, "");
    stage_frame.windowUpdate(&conn.stage, 0, window.CONN_WINDOW_BUMP);
}

fn onPing(conn: *MuxConn, flags: u8, payload: []const u8) ConnOutcome {
    if ((flags & frame.FLAG_ACK) != 0) return .keep_alive;

    if (payload.len != PING_LEN) {
        stage_frame.goaway(&conn.stage, conn.last_stream_id, frame.ERR_FRAME_SIZE_ERROR);

        return .close;
    }

    stage_frame.append(&conn.stage, frame.FRAME_TYPE_PING, frame.FLAG_ACK, 0, payload);

    return .keep_alive;
}

fn onHeaders(
    comptime RouterType: type,
    conn: *MuxConn,
    sid: u31,
    flags: u8,
    payload: []const u8,
) ConnOutcome {
    if (sid == 0) {
        stage_frame.goaway(&conn.stage, conn.last_stream_id, frame.ERR_PROTOCOL_ERROR);

        return .close;
    }

    if (sid <= conn.last_stream_id and sid % 2 == 1) {
        stage_frame.rstStream(&conn.stage, sid, frame.ERR_STREAM_CLOSED);

        return .keep_alive;
    }

    conn.last_stream_id = @max(conn.last_stream_id, sid);

    const slot = conn.claimSlot(sid) orelse {
        stage_frame.rstStream(&conn.stage, sid, frame.ERR_REFUSED_STREAM);

        return .keep_alive;
    };
    const stream = conn.streams[slot];

    const block = frame_payload.headerBlock(flags, payload) orelse {
        stage_frame.goaway(&conn.stage, conn.last_stream_id, frame.ERR_PROTOCOL_ERROR);

        return .close;
    };

    stream.header_count = conn.hpack_dec.decode(
        block,
        &stream.headers,
        stream.header_scratch,
    ) catch |err| switch (err) {
        else => {
            stage_frame.rstStream(&conn.stage, sid, frame.ERR_COMPRESSION_ERROR);
            conn.releaseSlot(slot);

            return .keep_alive;
        },
    };
    stream.end_headers = (flags & frame.FLAG_END_HEADERS) != 0;
    stream.end_stream = (flags & frame.FLAG_END_STREAM) != 0;

    finishIfReady(RouterType, conn, slot);

    return .keep_alive;
}

fn onContinuation(
    comptime RouterType: type,
    conn: *MuxConn,
    sid: u31,
    flags: u8,
    payload: []const u8,
) ConnOutcome {
    const slot = conn.findSlot(sid) orelse {
        stage_frame.goaway(&conn.stage, conn.last_stream_id, frame.ERR_PROTOCOL_ERROR);

        return .close;
    };
    const stream = conn.streams[slot];

    const count = conn.hpack_dec.decode(
        payload,
        stream.headers[stream.header_count..],
        stream.header_scratch,
    ) catch |err| switch (err) {
        else => {
            stage_frame.rstStream(&conn.stage, sid, frame.ERR_COMPRESSION_ERROR);
            conn.releaseSlot(slot);

            return .keep_alive;
        },
    };
    stream.header_count += count;
    stream.end_headers = (flags & frame.FLAG_END_HEADERS) != 0;

    finishIfReady(RouterType, conn, slot);

    return .keep_alive;
}

fn onData(
    comptime RouterType: type,
    conn: *MuxConn,
    sid: u31,
    flags: u8,
    payload: []const u8,
) ConnOutcome {
    if (sid == 0) {
        stage_frame.goaway(&conn.stage, conn.last_stream_id, frame.ERR_PROTOCOL_ERROR);

        return .close;
    }

    const slot = conn.findSlot(sid) orelse {
        stage_frame.rstStream(&conn.stage, sid, frame.ERR_STREAM_CLOSED);

        return .keep_alive;
    };
    const stream = conn.streams[slot];

    const data = frame_payload.dataBlock(flags, payload) orelse {
        stage_frame.goaway(&conn.stage, conn.last_stream_id, frame.ERR_PROTOCOL_ERROR);

        return .close;
    };

    // The stream window is large, so only the connection window is
    // replenished, in bulk.
    conn.conn_window_consumed += data.len;
    if (conn.conn_window_consumed >= window.CONN_REPLENISH_THRESHOLD) {
        stage_frame.windowUpdate(&conn.stage, 0, @intCast(conn.conn_window_consumed));
        conn.conn_window_consumed = 0;
    }

    // Shed instead of truncating: a cut message would reach the handler as a
    // corrupt one. Later DATA for this stream gets RST_STREAM(STREAM_CLOSED).
    // The cap is max_body, not the buffer: a pooled buffer can be larger.
    const too_large = stream.body_len + data.len > conn.opts.max_body;
    if (too_large or !stream.appendBody(data)) {
        stageTooLarge(conn, sid);
        conn.releaseSlot(slot);

        return .keep_alive;
    }

    stream.end_stream = (flags & frame.FLAG_END_STREAM) != 0;
    finishIfReady(RouterType, conn, slot);

    return .keep_alive;
}

// --------------------------------------------------------- //
// Public:

/// Handle every whole frame in the read buffer.
///
/// Param:
/// RouterType - type (a Router, carrying route_slice and dispatch)
/// conn - *MuxConn (a connection in the h2 phase)
///
/// Return:
/// - .keep_alive when the buffer is drained or holds only a partial frame
/// - .close on a protocol error or a peer GOAWAY (a GOAWAY is staged first
///   when the server ends it)
pub fn run(comptime RouterType: type, conn: *MuxConn) ConnOutcome {
    const max_payload = conn.opts.max_frame_size + frame.FRAME_PAYLOAD_SLACK;

    while (true) {
        const buf = conn.buffered();
        if (buf.len < frame.FRAME_HEADER_LEN) return .keep_alive;

        const header = frame.parseFrameHeader(buf[0..frame.FRAME_HEADER_LEN]);

        if (header.length > max_payload) {
            stage_frame.goaway(&conn.stage, conn.last_stream_id, frame.ERR_FRAME_SIZE_ERROR);

            return .close;
        }

        if (buf.len < frame.FRAME_HEADER_LEN + header.length) return .keep_alive;

        const payload = buf[frame.FRAME_HEADER_LEN..][0..header.length];
        conn.rstart += frame.FRAME_HEADER_LEN + header.length;

        const sid = header.stream_id;
        const flags = header.flags;

        const outcome: ConnOutcome = switch (header.frame_type) {
            frame.FRAME_TYPE_SETTINGS => blk: {
                onSettings(conn, flags, payload);

                break :blk .keep_alive;
            },
            frame.FRAME_TYPE_PING => onPing(conn, flags, payload),
            frame.FRAME_TYPE_HEADERS => onHeaders(RouterType, conn, sid, flags, payload),
            frame.FRAME_TYPE_CONTINUATION => onContinuation(
                RouterType,
                conn,
                sid,
                flags,
                payload,
            ),
            frame.FRAME_TYPE_DATA => onData(RouterType, conn, sid, flags, payload),
            frame.FRAME_TYPE_RST_STREAM => blk: {
                if (conn.findSlot(sid)) |slot| conn.releaseSlot(slot);

                break :blk .keep_alive;
            },
            frame.FRAME_TYPE_GOAWAY => .close,
            else => .keep_alive,
        };

        if (outcome == .close) return .close;
    }
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const Context = @import("../Context.zig");
const FrameHeader = @import("../../FrameHeader.zig");
const Header = @import("../../hpack/Header.zig");
const HpackDecoder = @import("../../hpack/HpackDecoder.zig");
const HpackEncoder = @import("../../hpack/HpackEncoder.zig");
const Request = @import("../Request.zig");
const Response = @import("../Response.zig");
const ServeOpts = @import("../ServeOpts.zig");
const router = @import("../router.zig");

const TEST_OPTS: ServeOpts = .{
    .max_streams = 4,
    .max_body = 1024,
    .max_header_scratch = 256,
};

/// A descriptor nothing is written to: every answer fits the stage.
const UNUSED_FD: std.posix.fd_t = undefined;

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

const EmptyRouter = router.Router(&[_]router.Route{});

fn newConn(opts: ServeOpts) !*MuxConn {
    const conn = try MuxConn.init(UNUSED_FD, opts, std.testing.io);
    conn.phase = .h2;

    return conn;
}

/// Load one frame into the read buffer as if it had arrived.
fn feedFrame(conn: *MuxConn, frame_type: u8, flags: u8, sid: u31, payload: []const u8) void {
    frame.encodeFrameHeader(conn.rbuf[conn.rend..][0..frame.FRAME_HEADER_LEN], .{
        .length = @intCast(payload.len),
        .frame_type = frame_type,
        .flags = flags,
        .stream_id = sid,
    });
    conn.rend += frame.FRAME_HEADER_LEN;

    @memcpy(conn.rbuf[conn.rend..][0..payload.len], payload);
    conn.rend += payload.len;
}

/// Load a HEADERS for a POST on sid, with an optional content-length.
fn feedHeaders(conn: *MuxConn, sid: u31, flags: u8, content_length: ?[]const u8) !void {
    var scratch: [256]u8 = undefined;
    var encoder = HpackEncoder.init(&scratch);
    try encoder.writeHeader(":method", "POST");
    try encoder.writeHeader(":path", "/svc.Svc/Method");
    if (content_length) |value| try encoder.writeHeader("content-length", value);

    feedFrame(conn, frame.FRAME_TYPE_HEADERS, flags, sid, encoder.encoded());
}

/// The nth staged frame header and its payload.
fn stagedFrame(conn: *const MuxConn, nth: usize) ?struct { FrameHeader, []const u8 } {
    const staged = conn.stage.buf[0..conn.stage.len];

    var pos: usize = 0;
    var index: usize = 0;
    while (pos + frame.FRAME_HEADER_LEN <= staged.len) : (index += 1) {
        const header = frame.parseFrameHeader(staged[pos..][0..frame.FRAME_HEADER_LEN]);
        const payload = staged[pos + frame.FRAME_HEADER_LEN ..][0..header.length];
        pos += frame.FRAME_HEADER_LEN + header.length;

        if (index == nth) return .{ header, payload };
    }

    return null;
}

/// Count the staged frames of one type.
fn stagedCount(conn: *const MuxConn, frame_type: u8) usize {
    var seen: usize = 0;
    var index: usize = 0;
    while (stagedFrame(conn, index)) |found| : (index += 1) {
        if (found[0].frame_type == frame_type) seen += 1;
    }

    return seen;
}

test "zix http2 grpc mux: frame_loop, SETTINGS stages an ACK and a window bump" {
    const conn = try newConn(TEST_OPTS);
    defer conn.deinit();

    feedFrame(conn, frame.FRAME_TYPE_SETTINGS, 0, 0, "");

    try std.testing.expectEqual(ConnOutcome.keep_alive, run(EmptyRouter, conn));

    const ack = stagedFrame(conn, 0).?;
    const bump = stagedFrame(conn, 1).?;

    try std.testing.expectEqual(frame.FRAME_TYPE_SETTINGS, ack[0].frame_type);
    try std.testing.expectEqual(frame.FLAG_ACK, ack[0].flags);
    try std.testing.expectEqual(frame.FRAME_TYPE_WINDOW_UPDATE, bump[0].frame_type);
}

test "zix http2 grpc mux: frame_loop, a SETTINGS ACK stages nothing" {
    const conn = try newConn(TEST_OPTS);
    defer conn.deinit();

    feedFrame(conn, frame.FRAME_TYPE_SETTINGS, frame.FLAG_ACK, 0, "");

    try std.testing.expectEqual(ConnOutcome.keep_alive, run(EmptyRouter, conn));
    try std.testing.expectEqual(@as(usize, 0), conn.stage.len);
}

test "zix http2 grpc mux: frame_loop, PING stages a PING ACK" {
    const conn = try newConn(TEST_OPTS);
    defer conn.deinit();

    feedFrame(conn, frame.FRAME_TYPE_PING, 0, 0, "12345678");

    try std.testing.expectEqual(ConnOutcome.keep_alive, run(EmptyRouter, conn));

    const pong = stagedFrame(conn, 0).?;

    try std.testing.expectEqual(frame.FLAG_ACK, pong[0].flags);
    try std.testing.expectEqualStrings("12345678", pong[1]);
}

test "zix http2 grpc mux: frame_loop, a short PING is FRAME_SIZE_ERROR" {
    const conn = try newConn(TEST_OPTS);
    defer conn.deinit();

    feedFrame(conn, frame.FRAME_TYPE_PING, 0, 0, "1234");

    try std.testing.expectEqual(ConnOutcome.close, run(EmptyRouter, conn));

    const goaway = stagedFrame(conn, 0).?;
    const code = std.mem.readInt(u32, goaway[1][4..8], .big);

    try std.testing.expectEqual(frame.FRAME_TYPE_GOAWAY, goaway[0].frame_type);
    try std.testing.expectEqual(frame.ERR_FRAME_SIZE_ERROR, code);
}

test "zix http2 grpc mux: frame_loop, a frame past max_frame_size is FRAME_SIZE_ERROR" {
    const conn = try newConn(TEST_OPTS);
    defer conn.deinit();

    frame.encodeFrameHeader(conn.rbuf[0..frame.FRAME_HEADER_LEN], .{
        .length = @intCast(TEST_OPTS.max_frame_size + frame.FRAME_PAYLOAD_SLACK + 1),
        .frame_type = frame.FRAME_TYPE_DATA,
        .flags = 0,
        .stream_id = 1,
    });
    conn.rend = frame.FRAME_HEADER_LEN;

    try std.testing.expectEqual(ConnOutcome.close, run(EmptyRouter, conn));
    try std.testing.expectEqual(@as(usize, 1), stagedCount(conn, frame.FRAME_TYPE_GOAWAY));
}

test "zix http2 grpc mux: frame_loop, a partial frame waits for more" {
    const conn = try newConn(TEST_OPTS);
    defer conn.deinit();

    feedFrame(conn, frame.FRAME_TYPE_PING, 0, 0, "12345678");
    conn.rend -= 3;

    try std.testing.expectEqual(ConnOutcome.keep_alive, run(EmptyRouter, conn));
    try std.testing.expectEqual(@as(usize, 0), conn.rstart);
    try std.testing.expectEqual(@as(usize, 0), conn.stage.len);
}

test "zix http2 grpc mux: frame_loop, HEADERS on stream 0 is PROTOCOL_ERROR" {
    const conn = try newConn(TEST_OPTS);
    defer conn.deinit();

    try feedHeaders(conn, 0, frame.FLAG_END_HEADERS, null);

    try std.testing.expectEqual(ConnOutcome.close, run(EmptyRouter, conn));
    try std.testing.expectEqual(@as(usize, 1), stagedCount(conn, frame.FRAME_TYPE_GOAWAY));
}

test "zix http2 grpc mux: frame_loop, a whole call is dispatched and its slot freed" {
    const conn = try newConn(TEST_OPTS);
    defer conn.deinit();

    const whole = [_]u8{ 0, 0, 0, 0, 0 };
    try feedHeaders(conn, 1, frame.FLAG_END_HEADERS, "5");
    feedFrame(conn, frame.FRAME_TYPE_DATA, frame.FLAG_END_STREAM, 1, &whole);

    tl_calls = 0;
    try std.testing.expectEqual(ConnOutcome.keep_alive, run(TestRouter, conn));

    try std.testing.expectEqual(@as(usize, 1), tl_calls);
    for (conn.slots) |in_use| try std.testing.expect(!in_use);
}

test "zix http2 grpc mux: frame_loop, CONTINUATION completes the headers" {
    const conn = try newConn(TEST_OPTS);
    defer conn.deinit();

    var scratch: [256]u8 = undefined;
    var encoder = HpackEncoder.init(&scratch);
    try encoder.writeHeader(":method", "POST");
    feedFrame(conn, frame.FRAME_TYPE_HEADERS, frame.FLAG_END_STREAM, 1, encoder.encoded());

    var rest_scratch: [256]u8 = undefined;
    var rest = HpackEncoder.init(&rest_scratch);
    try rest.writeHeader(":path", "/svc.Svc/Method");
    feedFrame(conn, frame.FRAME_TYPE_CONTINUATION, frame.FLAG_END_HEADERS, 1, rest.encoded());

    tl_calls = 0;
    try std.testing.expectEqual(ConnOutcome.keep_alive, run(TestRouter, conn));
    try std.testing.expectEqual(@as(usize, 1), tl_calls);
}

test "zix http2 grpc mux: frame_loop, CONTINUATION for an unknown stream is PROTOCOL_ERROR" {
    const conn = try newConn(TEST_OPTS);
    defer conn.deinit();

    feedFrame(conn, frame.FRAME_TYPE_CONTINUATION, frame.FLAG_END_HEADERS, 5, "");

    try std.testing.expectEqual(ConnOutcome.close, run(EmptyRouter, conn));
    try std.testing.expectEqual(@as(usize, 1), stagedCount(conn, frame.FRAME_TYPE_GOAWAY));
}

test "zix http2 grpc mux: frame_loop, a reused stream id is STREAM_CLOSED" {
    const conn = try newConn(TEST_OPTS);
    defer conn.deinit();

    conn.last_stream_id = 5;
    try feedHeaders(conn, 3, frame.FLAG_END_HEADERS, null);

    try std.testing.expectEqual(ConnOutcome.keep_alive, run(EmptyRouter, conn));

    const rst = stagedFrame(conn, 0).?;
    const code = std.mem.readInt(u32, rst[1][0..4], .big);

    try std.testing.expectEqual(frame.FRAME_TYPE_RST_STREAM, rst[0].frame_type);
    try std.testing.expectEqual(frame.ERR_STREAM_CLOSED, code);
}

test "zix http2 grpc mux: frame_loop, HEADERS past max_streams is REFUSED_STREAM" {
    var opts = TEST_OPTS;
    opts.max_streams = 1;

    const conn = try newConn(opts);
    defer conn.deinit();

    try feedHeaders(conn, 1, frame.FLAG_END_HEADERS, null);
    try feedHeaders(conn, 3, frame.FLAG_END_HEADERS, null);

    try std.testing.expectEqual(ConnOutcome.keep_alive, run(EmptyRouter, conn));

    const rst = stagedFrame(conn, 0).?;
    const code = std.mem.readInt(u32, rst[1][0..4], .big);

    try std.testing.expect(conn.slots[0]);
    try std.testing.expectEqual(@as(u31, 1), conn.streams[0].id);
    try std.testing.expectEqual(@as(u31, 3), rst[0].stream_id);
    try std.testing.expectEqual(frame.ERR_REFUSED_STREAM, code);
}

test "zix http2 grpc mux: frame_loop, DATA past max_body sheds with RESOURCE_EXHAUSTED" {
    var opts = TEST_OPTS;
    opts.max_body = 16;

    const conn = try newConn(opts);
    defer conn.deinit();

    const big: [32]u8 = @splat(0xaa);
    try feedHeaders(conn, 1, frame.FLAG_END_HEADERS, null);
    feedFrame(conn, frame.FRAME_TYPE_DATA, 0, 1, &big);

    try std.testing.expectEqual(ConnOutcome.keep_alive, run(EmptyRouter, conn));
    for (conn.slots) |in_use| try std.testing.expect(!in_use);

    const trailer = stagedFrame(conn, 0).?;
    const end_flags = frame.FLAG_END_HEADERS | frame.FLAG_END_STREAM;

    var decoder = HpackDecoder.init();
    var headers: [8]Header = undefined;
    var scratch: [512]u8 = undefined;
    const count = try decoder.decode(trailer[1], &headers, &scratch);

    var saw_status = false;
    for (headers[0..count]) |entry| {
        const is_status =
            std.mem.eql(u8, entry.name, "grpc-status") and
            std.mem.eql(u8, entry.value, "8");
        if (is_status) saw_status = true;
    }

    try std.testing.expectEqual(frame.FRAME_TYPE_HEADERS, trailer[0].frame_type);
    try std.testing.expectEqual(end_flags, trailer[0].flags);
    try std.testing.expect(saw_status);
}

test "zix http2 grpc mux: frame_loop, DATA after a shed stream is STREAM_CLOSED" {
    var opts = TEST_OPTS;
    opts.max_body = 16;

    const conn = try newConn(opts);
    defer conn.deinit();

    const big: [32]u8 = @splat(0xaa);
    try feedHeaders(conn, 1, frame.FLAG_END_HEADERS, null);
    feedFrame(conn, frame.FRAME_TYPE_DATA, 0, 1, &big);
    feedFrame(conn, frame.FRAME_TYPE_DATA, 0, 1, big[0..4]);

    try std.testing.expectEqual(ConnOutcome.keep_alive, run(EmptyRouter, conn));

    const rst = stagedFrame(conn, 1).?;
    const code = std.mem.readInt(u32, rst[1][0..4], .big);

    try std.testing.expectEqual(frame.FRAME_TYPE_RST_STREAM, rst[0].frame_type);
    try std.testing.expectEqual(@as(u31, 1), rst[0].stream_id);
    try std.testing.expectEqual(frame.ERR_STREAM_CLOSED, code);
}

test "zix http2 grpc mux: frame_loop, a body short of its content-length is reset" {
    const conn = try newConn(TEST_OPTS);
    defer conn.deinit();

    const short: [40]u8 = @splat('x');
    try feedHeaders(conn, 1, frame.FLAG_END_HEADERS, "100");
    feedFrame(conn, frame.FRAME_TYPE_DATA, frame.FLAG_END_STREAM, 1, &short);

    tl_calls = 0;
    try std.testing.expectEqual(ConnOutcome.keep_alive, run(TestRouter, conn));

    try std.testing.expectEqual(@as(usize, 0), tl_calls);
    try std.testing.expectEqual(@as(usize, 1), stagedCount(conn, frame.FRAME_TYPE_RST_STREAM));
    for (conn.slots) |in_use| try std.testing.expect(!in_use);
}

test "zix http2 grpc mux: frame_loop, RST_STREAM frees the slot" {
    const conn = try newConn(TEST_OPTS);
    defer conn.deinit();

    try feedHeaders(conn, 1, frame.FLAG_END_HEADERS, null);
    feedFrame(conn, frame.FRAME_TYPE_RST_STREAM, 0, 1, &.{ 0, 0, 0, 8 });

    try std.testing.expectEqual(ConnOutcome.keep_alive, run(EmptyRouter, conn));
    for (conn.slots) |in_use| try std.testing.expect(!in_use);
}

test "zix http2 grpc mux: frame_loop, a peer GOAWAY closes" {
    const conn = try newConn(TEST_OPTS);
    defer conn.deinit();

    feedFrame(conn, frame.FRAME_TYPE_GOAWAY, 0, 0, &.{ 0, 0, 0, 0, 0, 0, 0, 0 });

    try std.testing.expectEqual(ConnOutcome.close, run(EmptyRouter, conn));
    try std.testing.expectEqual(@as(usize, 0), conn.stage.len);
}

