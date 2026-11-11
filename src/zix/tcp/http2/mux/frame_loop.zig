//! ZIX Http2 mux frame_loop
//!
//! ### file: src/zix/tcp/http2/mux/frame_loop.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Process every whole frame buffered on a mux connection, one at a time.
//!
//! ### note:
//!
//! - A partial frame stays in the read buffer until the rest arrives.
//! - A body past what a stream can hold is shed with 413, never truncated.
//!   Only the connection window is credited for the dropped bytes, so the
//!   other streams keep flowing.
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
const control = @import("../control.zig");
const flow = @import("flow.zig");
const frame = @import("../frame.zig");
const frame_payload = @import("../frame_payload.zig");
const handler = @import("../handler.zig");
const mux_dispatch = @import("mux_dispatch.zig");
const peer_settings = @import("../peer_settings.zig");
const send_best_effort = @import("../send_best_effort.zig");
const ConnOutcome = @import("conn_outcome.zig").ConnOutcome;
const FrameHeader = @import("../FrameHeader.zig");
const MuxConn = @import("MuxConn.zig");

// --------------------------------------------------------- //
// Private:

/// Bytes in a PING payload.
const PING_LEN: usize = 8;

/// Bytes in a WINDOW_UPDATE payload.
const WINDOW_UPDATE_LEN: usize = 4;

/// The reserved top bit of a window increment.
const INCREMENT_MASK: u32 = 0x7fff_ffff;

/// GOAWAY with the code, then close.
fn fail(conn: *MuxConn, error_code: u32) ConnOutcome {
    send_best_effort.goaway(conn.fd, conn.last_stream_id, error_code);

    return .close;
}

fn onSettings(conn: *MuxConn, header: FrameHeader, payload: []const u8) ConnOutcome {
    if ((header.flags & frame.FLAG_ACK) != 0) return .keep_alive;

    const initial_window = peer_settings.apply(
        payload,
        &conn.hpack_dec,
        &conn.peer_max_frame_size,
    );
    if (initial_window) |value| conn.setPeerInitialWindow(value);

    control.sendSettingsAckFD(conn.fd) catch |err| switch (err) {
        // Best effort: a broken socket shows up on the next read.
        error.ZixHttp2_Control_BrokenPipe,
        error.ZixHttp2_Control_TooManySettings,
        error.ZixHttp2_Control_UnexpectedEOF,
        error.ZixHttp2_Control_Overflow,
        error.ZixHttp2_Control_BufferFull,
        => {},
    };
    send_best_effort.windowUpdate(conn.fd, 0, frame.DEFAULT_INITIAL_WINDOW);

    return .keep_alive;
}

fn onWindowUpdate(conn: *MuxConn, header: FrameHeader, payload: []const u8) ConnOutcome {
    if (payload.len != WINDOW_UPDATE_LEN) return fail(conn, frame.ERR_FRAME_SIZE_ERROR);

    const raw = std.mem.readInt(u32, payload[0..WINDOW_UPDATE_LEN], .big);
    const increment: i64 = raw & INCREMENT_MASK;

    if (header.stream_id == 0) {
        conn.send_window += increment;
        flow.resumeAll(conn);

        return .keep_alive;
    }

    if (conn.findSlot(header.stream_id)) |slot| {
        conn.streams[slot].send_window += increment;
        flow.resumeStream(conn, slot);
    }

    return .keep_alive;
}

fn onPing(conn: *MuxConn, header: FrameHeader, payload: []const u8) ConnOutcome {
    if ((header.flags & frame.FLAG_ACK) != 0) return .keep_alive;

    if (payload.len != PING_LEN) return fail(conn, frame.ERR_FRAME_SIZE_ERROR);

    control.sendPingAckFD(conn.fd, payload[0..PING_LEN].*) catch |err| switch (err) {
        // Best effort: a broken socket shows up on the next read.
        error.ZixHttp2_Control_BrokenPipe,
        error.ZixHttp2_Control_TooManySettings,
        error.ZixHttp2_Control_UnexpectedEOF,
        error.ZixHttp2_Control_Overflow,
        error.ZixHttp2_Control_BufferFull,
        => {},
    };

    return .keep_alive;
}

fn onHeaders(
    handler_fn: handler.HandlerFn,
    conn: *MuxConn,
    header: FrameHeader,
    payload: []const u8,
) ConnOutcome {
    const sid = header.stream_id;

    if (sid == 0) return fail(conn, frame.ERR_PROTOCOL_ERROR);

    if (sid <= conn.last_stream_id and sid % 2 == 1) {
        send_best_effort.rstStream(conn.fd, sid, frame.ERR_STREAM_CLOSED);

        return .keep_alive;
    }

    conn.last_stream_id = @max(conn.last_stream_id, sid);

    const slot = conn.claimSlot(sid) orelse {
        send_best_effort.rstStream(conn.fd, sid, frame.ERR_REFUSED_STREAM);

        return .keep_alive;
    };
    const stream = conn.streams[slot];

    const block = frame_payload.headerBlock(header.flags, payload) orelse
        return fail(conn, frame.ERR_PROTOCOL_ERROR);

    stream.header_count = conn.hpack_dec.decode(
        block,
        &stream.headers,
        stream.header_scratch,
    ) catch |err| switch (err) {
        else => {
            send_best_effort.rstStream(conn.fd, sid, frame.ERR_COMPRESSION_ERROR);
            conn.releaseSlot(slot);

            return .keep_alive;
        },
    };
    stream.end_headers = (header.flags & frame.FLAG_END_HEADERS) != 0;
    stream.end_stream = (header.flags & frame.FLAG_END_STREAM) != 0;

    if (stream.end_headers and stream.end_stream) {
        mux_dispatch.dispatchWhole(handler_fn, conn, slot);
    }

    return .keep_alive;
}

fn onContinuation(
    handler_fn: handler.HandlerFn,
    conn: *MuxConn,
    header: FrameHeader,
    payload: []const u8,
) ConnOutcome {
    const sid = header.stream_id;
    const slot = conn.findSlot(sid) orelse return fail(conn, frame.ERR_PROTOCOL_ERROR);
    const stream = conn.streams[slot];

    const count = conn.hpack_dec.decode(
        payload,
        stream.headers[stream.header_count..],
        stream.header_scratch,
    ) catch |err| switch (err) {
        else => {
            send_best_effort.rstStream(conn.fd, sid, frame.ERR_COMPRESSION_ERROR);
            conn.releaseSlot(slot);

            return .keep_alive;
        },
    };
    stream.header_count += count;
    stream.end_headers = (header.flags & frame.FLAG_END_HEADERS) != 0;

    if (stream.end_headers and stream.end_stream) {
        mux_dispatch.dispatchWhole(handler_fn, conn, slot);
    }

    return .keep_alive;
}

fn onData(
    handler_fn: handler.HandlerFn,
    conn: *MuxConn,
    header: FrameHeader,
    payload: []const u8,
) ConnOutcome {
    const sid = header.stream_id;

    if (sid == 0) return fail(conn, frame.ERR_PROTOCOL_ERROR);

    const slot = conn.findSlot(sid) orelse {
        send_best_effort.rstStream(conn.fd, sid, frame.ERR_STREAM_CLOSED);

        return .keep_alive;
    };
    const stream = conn.streams[slot];

    const data = frame_payload.dataBlock(header.flags, payload) orelse
        return fail(conn, frame.ERR_PROTOCOL_ERROR);

    if (!stream.appendBody(data)) {
        if (data.len > 0) send_best_effort.windowUpdate(conn.fd, 0, data.len);
        send_best_effort.sendTooLarge(conn.fd, sid);
        conn.releaseSlot(slot);

        return .keep_alive;
    }

    if (data.len > 0) {
        send_best_effort.windowUpdate(conn.fd, 0, data.len);
        send_best_effort.windowUpdate(conn.fd, sid, data.len);
    }

    stream.end_stream = (header.flags & frame.FLAG_END_STREAM) != 0;
    if (stream.end_stream) mux_dispatch.dispatchWhole(handler_fn, conn, slot);

    return .keep_alive;
}

fn onRstStream(conn: *MuxConn, header: FrameHeader) ConnOutcome {
    if (conn.findSlot(header.stream_id)) |slot| conn.releaseSlot(slot);

    return .keep_alive;
}

/// Route one whole frame to its handler.
fn onFrame(
    handler_fn: handler.HandlerFn,
    conn: *MuxConn,
    header: FrameHeader,
    payload: []const u8,
) ConnOutcome {
    return switch (header.frame_type) {
        frame.FRAME_TYPE_SETTINGS => onSettings(conn, header, payload),
        frame.FRAME_TYPE_WINDOW_UPDATE => onWindowUpdate(conn, header, payload),
        frame.FRAME_TYPE_PING => onPing(conn, header, payload),
        frame.FRAME_TYPE_HEADERS => onHeaders(handler_fn, conn, header, payload),
        frame.FRAME_TYPE_CONTINUATION => onContinuation(handler_fn, conn, header, payload),
        frame.FRAME_TYPE_DATA => onData(handler_fn, conn, header, payload),
        frame.FRAME_TYPE_RST_STREAM => onRstStream(conn, header),
        frame.FRAME_TYPE_GOAWAY => .close,
        else => .keep_alive,
    };
}

// --------------------------------------------------------- //
// Public:

/// Process every whole frame in the read buffer of a connection past its
/// preface.
///
/// Param:
/// handler_fn - handler.HandlerFn (the route or top-level handler)
/// conn - *MuxConn (a connection in the h2 phase)
///
/// Return:
/// - .keep_alive when the buffer holds no whole frame anymore
/// - .close on a protocol error, an oversized frame, or a peer GOAWAY
pub fn run(handler_fn: handler.HandlerFn, conn: *MuxConn) ConnOutcome {
    const max_payload = conn.opts.max_frame_size + frame.FRAME_PAYLOAD_SLACK;

    while (true) {
        const avail = conn.rend - conn.rstart;
        if (avail < frame.FRAME_HEADER_LEN) return .keep_alive;

        const header = frame.parseFrameHeader(
            conn.rbuf[conn.rstart..][0..frame.FRAME_HEADER_LEN],
        );
        if (header.length > max_payload) return fail(conn, frame.ERR_FRAME_SIZE_ERROR);

        if (avail < frame.FRAME_HEADER_LEN + header.length) return .keep_alive;

        const payload_start = conn.rstart + frame.FRAME_HEADER_LEN;
        const payload = conn.rbuf[payload_start..][0..header.length];
        conn.rstart = payload_start + header.length;

        if (onFrame(handler_fn, conn, header, payload) == .close) return .close;
    }
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const builtin = @import("builtin");
const pair = @import("../../../utils/socket/pair.zig");
const send_stream = @import("send_stream.zig");
const Context = @import("../Context.zig");
const Header = @import("../hpack/Header.zig");
const HpackDecoder = @import("../hpack/HpackDecoder.zig");
const HpackEncoder = @import("../hpack/HpackEncoder.zig");
const Request = @import("../Request.zig");
const Response = @import("../Response.zig");
const ServeOpts = @import("../ServeOpts.zig");

/// What the server answered with, read back after it returned.
const WireTally = struct {
    data_bytes: usize = 0,
    data_frames: usize = 0,
    largest_data: usize = 0,
    end_streams: usize = 0,
    conn_credit: usize = 0,
    stream_credit: usize = 0,
    rst_protocol_error: usize = 0,
    rst_refused: usize = 0,
    rst_closed: usize = 0,
    goaway_frame_size: usize = 0,
    settings_ack: usize = 0,
    ping_ack: usize = 0,
    status_200: usize = 0,
    status_413: usize = 0,
};

const TEST_OPTS: ServeOpts = .{
    .max_streams = 4,
    .max_body = 256,
    .max_header_scratch = 1024,
};

threadlocal var tl_calls: usize = 0;
threadlocal var tl_body_len: usize = 0;
threadlocal var tl_accept_encoding: [64]u8 = undefined;
threadlocal var tl_accept_encoding_len: usize = 0;

/// Body served through the flow-controlled sender. Static, so it outlives a
/// parked stream.
var stream_body_bytes: [5000]u8 = @splat('q');

fn okHandler(req: *Request, res: *Response, _: *Context) anyerror!void {
    tl_calls += 1;
    tl_body_len = req.body.len;

    const accept_encoding = req.header("accept-encoding") orelse "";
    tl_accept_encoding_len = @min(accept_encoding.len, tl_accept_encoding.len);
    @memcpy(
        tl_accept_encoding[0..tl_accept_encoding_len],
        accept_encoding[0..tl_accept_encoding_len],
    );

    try res.sendText("ok");
}

fn streamHandler(_: *Request, res: *Response, _: *Context) anyerror!void {
    tl_calls += 1;

    send_stream.sendResponseStreamFD(
        res.fd,
        res.sid,
        200,
        "text/plain",
        "",
        &stream_body_bytes,
    );
}

fn isLinux() bool {
    if (comptime builtin.target.os.tag == .linux) return true;

    std.log.info("this test drives a Linux socket pair, test skipped", .{});

    return false;
}

fn openConn(fd: std.posix.fd_t, opts: ServeOpts) !*MuxConn {
    const conn = try MuxConn.init(fd, opts, std.testing.io);
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

/// Load a request head on sid.
fn feedHead(
    conn: *MuxConn,
    sid: u31,
    method: []const u8,
    content_length: ?[]const u8,
    end_stream: bool,
) !void {
    var block: [256]u8 = undefined;
    var encoder = HpackEncoder.init(&block);
    try encoder.writeHeader(":method", method);
    try encoder.writeHeader(":path", "/");
    if (content_length) |value| try encoder.writeHeader("content-length", value);

    const flags: u8 = if (end_stream)
        frame.FLAG_END_HEADERS | frame.FLAG_END_STREAM
    else
        frame.FLAG_END_HEADERS;

    feedFrame(conn, frame.FRAME_TYPE_HEADERS, flags, sid, encoder.encoded());
}

fn incrementBytes(increment: u32) [4]u8 {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, increment, .big);

    return bytes;
}

/// Read everything the server wrote and count the answers that matter.
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
        if (pos + header.length > total) break;

        const payload = buf[pos..][0..header.length];
        pos += header.length;

        switch (header.frame_type) {
            frame.FRAME_TYPE_DATA => {
                tally.data_bytes += header.length;
                tally.data_frames += 1;
                tally.largest_data = @max(tally.largest_data, header.length);
                if ((header.flags & frame.FLAG_END_STREAM) != 0) tally.end_streams += 1;
            },
            frame.FRAME_TYPE_WINDOW_UPDATE => {
                if (header.stream_id == 0) tally.conn_credit += 1;
                if (header.stream_id != 0) tally.stream_credit += 1;
            },
            frame.FRAME_TYPE_RST_STREAM => {
                const code = std.mem.readInt(u32, payload[0..4], .big);
                if (code == frame.ERR_PROTOCOL_ERROR) tally.rst_protocol_error += 1;
                if (code == frame.ERR_REFUSED_STREAM) tally.rst_refused += 1;
                if (code == frame.ERR_STREAM_CLOSED) tally.rst_closed += 1;
            },
            frame.FRAME_TYPE_GOAWAY => {
                const code = std.mem.readInt(u32, payload[4..8], .big);
                if (code == frame.ERR_FRAME_SIZE_ERROR) tally.goaway_frame_size += 1;
            },
            frame.FRAME_TYPE_SETTINGS => {
                if ((header.flags & frame.FLAG_ACK) != 0) tally.settings_ack += 1;
            },
            frame.FRAME_TYPE_PING => {
                if ((header.flags & frame.FLAG_ACK) != 0) tally.ping_ack += 1;
            },
            frame.FRAME_TYPE_HEADERS => {
                var headers: [frame.MAX_HEADERS]Header = undefined;
                var scratch: [256]u8 = undefined;
                const count = decoder.decode(payload, &headers, &scratch) catch continue;

                for (headers[0..count]) |entry| {
                    if (!std.mem.eql(u8, entry.name, ":status")) continue;

                    if (std.mem.eql(u8, entry.value, "200")) tally.status_200 += 1;
                    if (std.mem.eql(u8, entry.value, "413")) tally.status_413 += 1;
                }
            },
            else => {},
        }
    }

    return tally;
}

test "zix http2 mux: frame_loop, a GET is served" {
    if (!isLinux()) return;

    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    const conn = try openConn(fds[1], TEST_OPTS);
    defer conn.deinit();

    try feedHead(conn, 1, "GET", null, true);

    tl_calls = 0;
    try std.testing.expectEqual(ConnOutcome.keep_alive, run(okHandler, conn));

    var buf: [4096]u8 = undefined;
    const tally = tallyWire(fds[0], fds[1], &buf);

    try std.testing.expectEqual(@as(usize, 1), tl_calls);
    try std.testing.expectEqual(@as(usize, 1), tally.status_200);
}

test "zix http2 mux: frame_loop, a partial frame waits in the buffer" {
    const conn = try openConn(undefined, TEST_OPTS);
    defer conn.deinit();

    try feedHead(conn, 1, "GET", null, true);
    conn.rend -= 1;

    tl_calls = 0;
    try std.testing.expectEqual(ConnOutcome.keep_alive, run(okHandler, conn));
    try std.testing.expectEqual(@as(usize, 0), tl_calls);
    try std.testing.expectEqual(@as(usize, 0), conn.rstart);
}

test "zix http2 mux: frame_loop, the handler sees accept-encoding" {
    if (!isLinux()) return;

    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    const conn = try openConn(fds[1], TEST_OPTS);
    defer conn.deinit();

    var block: [256]u8 = undefined;
    var encoder = HpackEncoder.init(&block);
    try encoder.writeHeader(":method", "GET");
    try encoder.writeHeader(":path", "/");
    try encoder.writeHeader("accept-encoding", "br;q=1, gzip;q=0.8");
    const flags = frame.FLAG_END_HEADERS | frame.FLAG_END_STREAM;
    feedFrame(conn, frame.FRAME_TYPE_HEADERS, flags, 1, encoder.encoded());

    tl_accept_encoding_len = 0;
    _ = run(okHandler, conn);

    try std.testing.expectEqualStrings(
        "br;q=1, gzip;q=0.8",
        tl_accept_encoding[0..tl_accept_encoding_len],
    );
}

test "zix http2 mux: frame_loop, CONTINUATION completes the header block" {
    if (!isLinux()) return;

    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    const conn = try openConn(fds[1], TEST_OPTS);
    defer conn.deinit();

    var first: [64]u8 = undefined;
    var first_encoder = HpackEncoder.init(&first);
    try first_encoder.writeHeader(":method", "GET");
    var second: [64]u8 = undefined;
    var second_encoder = HpackEncoder.init(&second);
    try second_encoder.writeHeader(":path", "/");

    feedFrame(conn, frame.FRAME_TYPE_HEADERS, frame.FLAG_END_STREAM, 1, first_encoder.encoded());

    tl_calls = 0;
    _ = run(okHandler, conn);
    try std.testing.expectEqual(@as(usize, 0), tl_calls);

    const end_headers = frame.FLAG_END_HEADERS;
    feedFrame(conn, frame.FRAME_TYPE_CONTINUATION, end_headers, 1, second_encoder.encoded());
    _ = run(okHandler, conn);

    try std.testing.expectEqual(@as(usize, 1), tl_calls);
}

test "zix http2 mux: frame_loop, CONTINUATION on an unknown stream closes" {
    if (!isLinux()) return;

    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    const conn = try openConn(fds[1], TEST_OPTS);
    defer conn.deinit();

    feedFrame(conn, frame.FRAME_TYPE_CONTINUATION, frame.FLAG_END_HEADERS, 7, "");

    try std.testing.expectEqual(ConnOutcome.close, run(okHandler, conn));
}

test "zix http2 mux: frame_loop, interleaved streams are each served" {
    if (!isLinux()) return;

    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    const conn = try openConn(fds[1], TEST_OPTS);
    defer conn.deinit();

    try feedHead(conn, 1, "POST", "3", false);
    try feedHead(conn, 3, "POST", "2", false);
    feedFrame(conn, frame.FRAME_TYPE_DATA, 0, 1, "ab");
    feedFrame(conn, frame.FRAME_TYPE_DATA, frame.FLAG_END_STREAM, 3, "xy");
    feedFrame(conn, frame.FRAME_TYPE_DATA, frame.FLAG_END_STREAM, 1, "c");

    tl_calls = 0;
    try std.testing.expectEqual(ConnOutcome.keep_alive, run(okHandler, conn));

    var buf: [4096]u8 = undefined;
    const tally = tallyWire(fds[0], fds[1], &buf);

    try std.testing.expectEqual(@as(usize, 2), tl_calls);
    try std.testing.expectEqual(@as(usize, 2), tally.status_200);
    try std.testing.expectEqual(@as(usize, 0), tally.rst_protocol_error);
}

test "zix http2 mux: frame_loop, WINDOW_UPDATE resumes a parked body" {
    if (!isLinux()) return;

    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    const conn = try openConn(fds[1], TEST_OPTS);
    defer conn.deinit();

    conn.send_window = 100;
    conn.peer_init_window = 100;
    try feedHead(conn, 1, "GET", null, true);
    _ = run(streamHandler, conn);

    const slot = conn.findSlot(1).?;
    try std.testing.expectEqual(@as(usize, 4900), conn.streams[slot].pending_body.len);

    const increment = incrementBytes(1000);
    feedFrame(conn, frame.FRAME_TYPE_WINDOW_UPDATE, 0, 0, &increment);
    feedFrame(conn, frame.FRAME_TYPE_WINDOW_UPDATE, 0, 1, &increment);
    _ = run(streamHandler, conn);

    try std.testing.expectEqual(@as(usize, 3900), conn.streams[slot].pending_body.len);
}

test "zix http2 mux: frame_loop, a connection grant alone leaves a stream parked" {
    if (!isLinux()) return;

    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    const conn = try openConn(fds[1], TEST_OPTS);
    defer conn.deinit();

    conn.send_window = 1 << 20;
    conn.peer_init_window = 500;
    try feedHead(conn, 1, "GET", null, true);
    _ = run(streamHandler, conn);

    const slot = conn.findSlot(1).?;
    const parked_len = stream_body_bytes.len - 500;
    try std.testing.expectEqual(parked_len, conn.streams[slot].pending_body.len);

    const conn_increment = incrementBytes(10000);
    feedFrame(conn, frame.FRAME_TYPE_WINDOW_UPDATE, 0, 0, &conn_increment);
    _ = run(streamHandler, conn);

    try std.testing.expectEqual(parked_len, conn.streams[slot].pending_body.len);

    const stream_increment = incrementBytes(@intCast(parked_len));
    feedFrame(conn, frame.FRAME_TYPE_WINDOW_UPDATE, 0, 1, &stream_increment);
    _ = run(streamHandler, conn);

    try std.testing.expect(conn.findSlot(1) == null);

    var buf: [16 * 1024]u8 = undefined;
    const tally = tallyWire(fds[0], fds[1], &buf);

    try std.testing.expectEqual(stream_body_bytes.len, tally.data_bytes);
    try std.testing.expectEqual(@as(usize, 1), tally.end_streams);
}

test "zix http2 mux: frame_loop, every parked stream resumes on one connection grant" {
    if (!isLinux()) return;

    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    const conn = try openConn(fds[1], TEST_OPTS);
    defer conn.deinit();

    conn.send_window = 1000;
    conn.peer_init_window = 1 << 20;

    const sids = [_]u31{ 1, 3, 5, 7 };
    for (sids) |sid| try feedHead(conn, sid, "GET", null, true);
    _ = run(streamHandler, conn);

    for (sids) |sid| try std.testing.expect(conn.streams[conn.findSlot(sid).?].isParked());

    const remaining = sids.len * stream_body_bytes.len - 1000;
    const increment = incrementBytes(@intCast(remaining));
    feedFrame(conn, frame.FRAME_TYPE_WINDOW_UPDATE, 0, 0, &increment);
    _ = run(streamHandler, conn);

    for (sids) |sid| try std.testing.expect(conn.findSlot(sid) == null);

    var buf: [64 * 1024]u8 = undefined;
    const tally = tallyWire(fds[0], fds[1], &buf);

    try std.testing.expectEqual(sids.len * stream_body_bytes.len, tally.data_bytes);
    try std.testing.expectEqual(sids.len, tally.end_streams);
}

test "zix http2 mux: frame_loop, SETTINGS_INITIAL_WINDOW_SIZE moves an open stream" {
    if (!isLinux()) return;

    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    const conn = try openConn(fds[1], TEST_OPTS);
    defer conn.deinit();

    try feedHead(conn, 1, "POST", null, false);
    const settings = [_]u8{ 0x00, 0x04, 0x00, 0x00, 0x00, 0x64 };
    feedFrame(conn, frame.FRAME_TYPE_SETTINGS, 0, 0, &settings);
    _ = run(okHandler, conn);

    const slot = conn.findSlot(1).?;
    try std.testing.expectEqual(@as(i64, 100), conn.streams[slot].send_window);

    var buf: [1024]u8 = undefined;
    const tally = tallyWire(fds[0], fds[1], &buf);

    try std.testing.expectEqual(@as(usize, 1), tally.settings_ack);
}

test "zix http2 mux: frame_loop, SETTINGS_MAX_FRAME_SIZE is recorded" {
    if (!isLinux()) return;

    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    const conn = try openConn(fds[1], TEST_OPTS);
    defer conn.deinit();

    const settings = [_]u8{ 0x00, 0x05, 0x00, 0x00, 0x60, 0x00 };
    feedFrame(conn, frame.FRAME_TYPE_SETTINGS, 0, 0, &settings);
    _ = run(okHandler, conn);

    try std.testing.expectEqual(@as(u32, 24 * 1024), conn.peer_max_frame_size);
}

test "zix http2 mux: frame_loop, DATA respects the peer default max frame size" {
    if (!isLinux()) return;

    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    const opts: ServeOpts = .{
        .max_streams = 4,
        .max_body = 256,
        .max_header_scratch = 1024,
        .max_frame_size = 24 * 1024,
    };
    const conn = try openConn(fds[1], opts);
    defer conn.deinit();

    conn.send_window = 1 << 20;
    conn.peer_init_window = 1 << 20;
    try feedHead(conn, 1, "GET", null, true);
    _ = run(streamHandler, conn);

    var buf: [16 * 1024]u8 = undefined;
    const tally = tallyWire(fds[0], fds[1], &buf);

    try std.testing.expectEqual(stream_body_bytes.len, tally.data_bytes);
    try std.testing.expect(tally.largest_data <= frame.DEFAULT_MAX_FRAME_SIZE);
}

test "zix http2 mux: frame_loop, PING gets an ACK" {
    if (!isLinux()) return;

    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    const conn = try openConn(fds[1], TEST_OPTS);
    defer conn.deinit();

    feedFrame(conn, frame.FRAME_TYPE_PING, 0, 0, "12345678");
    _ = run(okHandler, conn);

    var buf: [256]u8 = undefined;
    const tally = tallyWire(fds[0], fds[1], &buf);

    try std.testing.expectEqual(@as(usize, 1), tally.ping_ack);
}

test "zix http2 mux: frame_loop, PING of the wrong size closes" {
    if (!isLinux()) return;

    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    const conn = try openConn(fds[1], TEST_OPTS);
    defer conn.deinit();

    feedFrame(conn, frame.FRAME_TYPE_PING, 0, 0, "1234");

    try std.testing.expectEqual(ConnOutcome.close, run(okHandler, conn));

    var buf: [256]u8 = undefined;
    const tally = tallyWire(fds[0], fds[1], &buf);

    try std.testing.expectEqual(@as(usize, 1), tally.goaway_frame_size);
}

test "zix http2 mux: frame_loop, WINDOW_UPDATE of the wrong size closes" {
    if (!isLinux()) return;

    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    const conn = try openConn(fds[1], TEST_OPTS);
    defer conn.deinit();

    feedFrame(conn, frame.FRAME_TYPE_WINDOW_UPDATE, 0, 0, "12");

    try std.testing.expectEqual(ConnOutcome.close, run(okHandler, conn));
}

test "zix http2 mux: frame_loop, a frame past the size cap closes" {
    if (!isLinux()) return;

    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    const conn = try openConn(fds[1], TEST_OPTS);
    defer conn.deinit();

    const too_large = TEST_OPTS.max_frame_size + frame.FRAME_PAYLOAD_SLACK + 1;
    frame.encodeFrameHeader(conn.rbuf[0..frame.FRAME_HEADER_LEN], .{
        .length = @intCast(too_large),
        .frame_type = frame.FRAME_TYPE_DATA,
        .flags = 0,
        .stream_id = 1,
    });
    conn.rend = frame.FRAME_HEADER_LEN;

    try std.testing.expectEqual(ConnOutcome.close, run(okHandler, conn));

    var buf: [256]u8 = undefined;
    const tally = tallyWire(fds[0], fds[1], &buf);

    try std.testing.expectEqual(@as(usize, 1), tally.goaway_frame_size);
}

test "zix http2 mux: frame_loop, HEADERS on stream 0 closes" {
    if (!isLinux()) return;

    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    const conn = try openConn(fds[1], TEST_OPTS);
    defer conn.deinit();

    try feedHead(conn, 0, "GET", null, true);

    try std.testing.expectEqual(ConnOutcome.close, run(okHandler, conn));
}

test "zix http2 mux: frame_loop, HEADERS on a reused stream id is STREAM_CLOSED" {
    if (!isLinux()) return;

    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    const conn = try openConn(fds[1], TEST_OPTS);
    defer conn.deinit();

    try feedHead(conn, 3, "GET", null, true);
    try feedHead(conn, 1, "GET", null, true);

    tl_calls = 0;
    _ = run(okHandler, conn);

    var buf: [4096]u8 = undefined;
    const tally = tallyWire(fds[0], fds[1], &buf);

    try std.testing.expectEqual(@as(usize, 1), tl_calls);
    try std.testing.expectEqual(@as(usize, 1), tally.rst_closed);
}

test "zix http2 mux: frame_loop, HEADERS past max_streams is refused" {
    if (!isLinux()) return;

    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    const opts: ServeOpts = .{
        .max_streams = 1,
        .max_body = 64,
        .max_header_scratch = 1024,
    };
    const conn = try openConn(fds[1], opts);
    defer conn.deinit();

    try feedHead(conn, 1, "POST", null, false);
    try feedHead(conn, 3, "POST", null, false);

    try std.testing.expectEqual(ConnOutcome.keep_alive, run(okHandler, conn));
    try std.testing.expect(conn.findSlot(1) != null);
    try std.testing.expect(conn.findSlot(3) == null);

    var buf: [1024]u8 = undefined;
    const tally = tallyWire(fds[0], fds[1], &buf);

    try std.testing.expectEqual(@as(usize, 1), tally.rst_refused);
}

test "zix http2 mux: frame_loop, DATA past the body buffer is shed with 413" {
    if (!isLinux()) return;

    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    const conn = try openConn(fds[1], TEST_OPTS);
    defer conn.deinit();

    try feedHead(conn, 1, "POST", null, false);
    _ = run(okHandler, conn);

    const slot = conn.findSlot(1).?;
    conn.streams[slot].body_len = conn.streams[slot].body.len - 8;

    const oversized: [32]u8 = @splat(0xaa);
    feedFrame(conn, frame.FRAME_TYPE_DATA, frame.FLAG_END_STREAM, 1, &oversized);
    feedFrame(conn, frame.FRAME_TYPE_DATA, 0, 1, oversized[0..8]);

    tl_calls = 0;
    try std.testing.expectEqual(ConnOutcome.keep_alive, run(okHandler, conn));
    try std.testing.expect(conn.findSlot(1) == null);

    var buf: [4096]u8 = undefined;
    const tally = tallyWire(fds[0], fds[1], &buf);

    try std.testing.expectEqual(@as(usize, 0), tl_calls);
    try std.testing.expectEqual(@as(usize, 1), tally.status_413);
    try std.testing.expectEqual(@as(usize, 1), tally.conn_credit);
    try std.testing.expectEqual(@as(usize, 0), tally.stream_credit);
    try std.testing.expectEqual(@as(usize, 1), tally.rst_closed);
}

test "zix http2 mux: frame_loop, DATA exactly filling the body buffer is served" {
    if (!isLinux()) return;

    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    const conn = try openConn(fds[1], TEST_OPTS);
    defer conn.deinit();

    try feedHead(conn, 1, "POST", null, false);
    _ = run(okHandler, conn);

    const slot = conn.findSlot(1).?;
    const full_len = conn.streams[slot].body.len;
    conn.streams[slot].body_len = full_len - 16;

    const exact: [16]u8 = @splat(0xbb);
    feedFrame(conn, frame.FRAME_TYPE_DATA, frame.FLAG_END_STREAM, 1, &exact);

    tl_body_len = 0;
    _ = run(okHandler, conn);

    try std.testing.expectEqual(full_len, tl_body_len);
    try std.testing.expect(conn.findSlot(1) == null);
}

test "zix http2 mux: frame_loop, a body short of its content-length is reset" {
    if (!isLinux()) return;

    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    const conn = try openConn(fds[1], TEST_OPTS);
    defer conn.deinit();

    const short: [40]u8 = @splat('x');
    try feedHead(conn, 1, "POST", "100", false);
    feedFrame(conn, frame.FRAME_TYPE_DATA, frame.FLAG_END_STREAM, 1, &short);

    tl_calls = 0;
    try std.testing.expectEqual(ConnOutcome.keep_alive, run(okHandler, conn));
    try std.testing.expect(conn.findSlot(1) == null);

    var buf: [4096]u8 = undefined;
    const tally = tallyWire(fds[0], fds[1], &buf);

    try std.testing.expectEqual(@as(usize, 0), tl_calls);
    try std.testing.expectEqual(@as(usize, 1), tally.rst_protocol_error);
    try std.testing.expectEqual(@as(usize, 0), tally.status_200);
}

test "zix http2 mux: frame_loop, a body past its content-length is reset" {
    if (!isLinux()) return;

    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    const conn = try openConn(fds[1], TEST_OPTS);
    defer conn.deinit();

    const overlong: [40]u8 = @splat('x');
    try feedHead(conn, 1, "POST", "10", false);
    feedFrame(conn, frame.FRAME_TYPE_DATA, frame.FLAG_END_STREAM, 1, &overlong);

    tl_calls = 0;
    _ = run(okHandler, conn);

    var buf: [4096]u8 = undefined;
    const tally = tallyWire(fds[0], fds[1], &buf);

    try std.testing.expectEqual(@as(usize, 0), tl_calls);
    try std.testing.expectEqual(@as(usize, 1), tally.rst_protocol_error);
}

test "zix http2 mux: frame_loop, a declared body that never arrives is reset" {
    if (!isLinux()) return;

    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    const conn = try openConn(fds[1], TEST_OPTS);
    defer conn.deinit();

    try feedHead(conn, 1, "POST", "5", true);

    tl_calls = 0;
    _ = run(okHandler, conn);

    var buf: [4096]u8 = undefined;
    const tally = tallyWire(fds[0], fds[1], &buf);

    try std.testing.expectEqual(@as(usize, 0), tl_calls);
    try std.testing.expectEqual(@as(usize, 1), tally.rst_protocol_error);
}

test "zix http2 mux: frame_loop, a body matching its content-length is served" {
    if (!isLinux()) return;

    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    const conn = try openConn(fds[1], TEST_OPTS);
    defer conn.deinit();

    const whole: [40]u8 = @splat('x');
    try feedHead(conn, 1, "POST", "40", false);
    feedFrame(conn, frame.FRAME_TYPE_DATA, frame.FLAG_END_STREAM, 1, &whole);

    tl_calls = 0;
    tl_body_len = 0;
    _ = run(okHandler, conn);

    var buf: [4096]u8 = undefined;
    const tally = tallyWire(fds[0], fds[1], &buf);

    try std.testing.expectEqual(@as(usize, 1), tl_calls);
    try std.testing.expectEqual(@as(usize, 40), tl_body_len);
    try std.testing.expectEqual(@as(usize, 1), tally.status_200);
}

test "zix http2 mux: frame_loop, DATA on an unknown stream is STREAM_CLOSED" {
    if (!isLinux()) return;

    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    const conn = try openConn(fds[1], TEST_OPTS);
    defer conn.deinit();

    feedFrame(conn, frame.FRAME_TYPE_DATA, 0, 9, "x");
    _ = run(okHandler, conn);

    var buf: [256]u8 = undefined;
    const tally = tallyWire(fds[0], fds[1], &buf);

    try std.testing.expectEqual(@as(usize, 1), tally.rst_closed);
}

test "zix http2 mux: frame_loop, RST_STREAM reaps a parked slot" {
    if (!isLinux()) return;

    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    const conn = try openConn(fds[1], TEST_OPTS);
    defer conn.deinit();

    conn.send_window = 100;
    conn.peer_init_window = 100;
    try feedHead(conn, 1, "GET", null, true);
    _ = run(streamHandler, conn);

    try std.testing.expect(conn.findSlot(1) != null);

    const cancel = [_]u8{ 0, 0, 0, 8 };
    feedFrame(conn, frame.FRAME_TYPE_RST_STREAM, 0, 1, &cancel);
    _ = run(streamHandler, conn);

    try std.testing.expect(conn.findSlot(1) == null);
}

test "zix http2 mux: frame_loop, GOAWAY from the peer closes" {
    const conn = try openConn(undefined, TEST_OPTS);
    defer conn.deinit();

    const payload = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0 };
    feedFrame(conn, frame.FRAME_TYPE_GOAWAY, 0, 0, &payload);

    try std.testing.expectEqual(ConnOutcome.close, run(okHandler, conn));
}

test "zix http2 mux: frame_loop, an unknown frame type is ignored" {
    const conn = try openConn(undefined, TEST_OPTS);
    defer conn.deinit();

    feedFrame(conn, 0xfe, 0, 0, "abc");

    try std.testing.expectEqual(ConnOutcome.keep_alive, run(okHandler, conn));
    try std.testing.expectEqual(conn.rend, conn.rstart);
}

