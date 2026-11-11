//! ZIX Http2 serve
//!
//! ### file: src/zix/tcp/http2/serve.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Blocking h2c connection loop: preface or upgrade, then one frame at a time.
//!
//! ### note:
//!
//! - A body past what a stream can hold is shed with 413, never truncated, so
//!   a handler never receives a partial body.
//! - A peer that hangs up with a request unfinished gets GOAWAY PROTOCOL_ERROR.
//!   A peer that hangs up idle gets nothing, that is an ordinary close.
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
const builtin = @import("builtin");
const control = @import("control.zig");
const frame = @import("frame.zig");
const handler = @import("handler.zig");
const reader = @import("reader.zig");
const stream_invoke = @import("stream_invoke.zig");
const stream_slot = @import("stream_slot.zig");
const upgrade = @import("upgrade.zig");
const writer = @import("writer.zig");
const Header = @import("hpack/Header.zig");
const HpackDecoder = @import("hpack/HpackDecoder.zig");
const Request = @import("Request.zig");
const ServeOpts = @import("ServeOpts.zig");
const Stream = @import("Stream.zig");

// --------------------------------------------------------- //
// Private:

const Inner = Error || reader.Error || control.Error || upgrade.Error;

/// Decoded HTTP2-Settings scratch on an h2c upgrade.
const SETTINGS_DECODE_SCRATCH: usize = 256;

/// HTTP/1.1 head bound on an h2c upgrade.
const UPGRADE_HEAD_BUF: usize = 8192;

/// Bytes read before deciding between the preface and an upgrade.
const PEEK_LEN: usize = 3;

/// Bytes a HEADERS PRIORITY block takes: stream dependency plus weight.
const PRIORITY_LEN: usize = 5;

/// Bytes in a PING payload.
const PING_LEN: usize = 8;

/// Send GOAWAY, best effort.
fn goaway(fd: std.posix.fd_t, last_stream_id: u31, error_code: u32) void {
    control.sendGoawayFD(fd, last_stream_id, error_code) catch |err| switch (err) {
        // Best effort: the connection is closing either way.
        error.ZixHttp2_Control_BrokenPipe,
        error.ZixHttp2_Control_TooManySettings,
        error.ZixHttp2_Control_UnexpectedEOF,
        error.ZixHttp2_Control_Overflow,
        error.ZixHttp2_Control_BufferFull,
        => {},
    };
}

/// Send RST_STREAM, best effort.
fn rstStream(fd: std.posix.fd_t, sid: u31, error_code: u32) void {
    control.sendRstStreamFD(fd, sid, error_code) catch |err| switch (err) {
        // Best effort: a broken socket shows up on the next read.
        error.ZixHttp2_Control_BrokenPipe,
        error.ZixHttp2_Control_TooManySettings,
        error.ZixHttp2_Control_UnexpectedEOF,
        error.ZixHttp2_Control_Overflow,
        error.ZixHttp2_Control_BufferFull,
        => {},
    };
}

/// Send WINDOW_UPDATE, best effort.
fn windowUpdate(fd: std.posix.fd_t, sid: u31, increment: usize) void {
    control.sendWindowUpdateFD(fd, sid, @intCast(increment)) catch |err| switch (err) {
        // Best effort: a broken socket shows up on the next read.
        error.ZixHttp2_Control_BrokenPipe,
        error.ZixHttp2_Control_TooManySettings,
        error.ZixHttp2_Control_UnexpectedEOF,
        error.ZixHttp2_Control_Overflow,
        error.ZixHttp2_Control_BufferFull,
        => {},
    };
}

/// Answer a stream with 413 and an empty body, best effort.
fn sendTooLarge(fd: std.posix.fd_t, sid: u31) void {
    writer.sendResponseFD(fd, sid, 413, "text/plain", "") catch |err| switch (err) {
        // Best effort: a broken socket shows up on the next read.
        error.ZixHttp2_Writer_BrokenPipe,
        error.ZixHttp2_Writer_UnexpectedEOF,
        error.ZixHttp2_Writer_Overflow,
        error.ZixHttp2_Writer_BufferFull,
        => {},
    };
}

/// Turn TCP_NODELAY on, best effort.
fn setNoDelay(fd: std.posix.fd_t) void {
    if (comptime builtin.target.os.tag != .windows) {
        // std.posix.TCP is void on the BSDs: TCP_NODELAY is 1 there.
        const nodelay: u32 =
            if (comptime std.posix.TCP != void) std.posix.TCP.NODELAY else 1;

        std.posix.setsockopt(
            fd,
            std.posix.IPPROTO.TCP,
            nodelay,
            std.mem.asBytes(&@as(c_int, 1)),
        ) catch |err| switch (err) {
            // Best effort: a non-TCP socket (a test socket pair) has no NODELAY.
            else => {},
        };
    }
}

/// Apply peer SETTINGS parameters: the HPACK table size and the frame size
/// cap for outbound DATA.
///
/// Note:
/// - RFC 7540 section 6.5.2: a valid SETTINGS_MAX_FRAME_SIZE is 16384 up to
///   16777215. An out-of-range value keeps the last good one.
///
/// Param:
/// params - []const u8 (SETTINGS payload, 6 bytes per parameter)
/// decoder - *HpackDecoder (the connection's decoder)
/// peer_max_frame_size - *u32 (updated in place)
///
/// Return:
/// - void
fn applySettings(params: []const u8, decoder: *HpackDecoder, peer_max_frame_size: *u32) void {
    var pos: usize = 0;

    while (pos + frame.SETTINGS_PARAM_LEN <= params.len) : (pos += frame.SETTINGS_PARAM_LEN) {
        const id = std.mem.readInt(u16, params[pos..][0..2], .big);
        const value = std.mem.readInt(u32, params[pos + 2 ..][0..4], .big);

        if (id == frame.SETTINGS_HEADER_TABLE_SIZE) {
            decoder.max_size = value;
            decoder.evictTo(value);
        }

        const in_range =
            value >= frame.DEFAULT_MAX_FRAME_SIZE and
            value <= frame.MAX_FRAME_SIZE_LIMIT;
        if (id == frame.SETTINGS_MAX_FRAME_SIZE and in_range) {
            peer_max_frame_size.* = value;
        }
    }
}

/// Send this server's SETTINGS frame.
fn sendServerSettings(fd: std.posix.fd_t, opts: ServeOpts) control.Error!void {
    return control.sendSettingsFD(fd, &.{
        .{ frame.SETTINGS_MAX_CONCURRENT_STREAMS, @as(u32, @intCast(opts.max_streams)) },
        .{ frame.SETTINGS_INITIAL_WINDOW_SIZE, frame.DEFAULT_INITIAL_WINDOW },
        .{ frame.SETTINGS_MAX_FRAME_SIZE, opts.max_frame_size },
        .{ frame.SETTINGS_ENABLE_PUSH, 0 },
    });
}

/// Read the rest of the client preface after `have` bytes were read.
fn recvPreface(fd: std.posix.fd_t, have: []const u8) Inner!void {
    var preface: [frame.PREFACE.len]u8 = undefined;
    @memcpy(preface[0..have.len], have);
    try reader.recvExact(fd, preface[have.len..]);

    if (!std.mem.eql(u8, &preface, frame.PREFACE)) {
        goaway(fd, 0, frame.ERR_PROTOCOL_ERROR);

        return Error.ZixHttp2_Serve_BadPreface;
    }
}

/// The header block of a HEADERS frame, with padding and priority removed.
///
/// Return:
/// - ?[]const u8 (null when the padding runs past the payload)
fn headerBlock(flags: u8, payload: []const u8) ?[]const u8 {
    var offset: usize = 0;
    var pad_len: usize = 0;

    if ((flags & frame.FLAG_PADDED) != 0 and payload.len > 0) {
        pad_len = payload[0];
        offset = 1;
    }
    if ((flags & frame.FLAG_PRIORITY) != 0 and offset + PRIORITY_LEN <= payload.len) {
        offset += PRIORITY_LEN;
    }
    if (pad_len + offset > payload.len) return null;

    return payload[offset .. payload.len - pad_len];
}

/// The data of a DATA frame, with padding removed.
///
/// Return:
/// - ?[]const u8 (null when the padding runs past the payload)
fn dataBlock(flags: u8, payload: []const u8) ?[]const u8 {
    var data = payload;
    var pad_len: usize = 0;

    if ((flags & frame.FLAG_PADDED) != 0 and data.len > 0) {
        pad_len = data[0];
        data = data[1..];
    }
    if (pad_len > data.len) return null;

    return data[0 .. data.len - pad_len];
}

/// GOAWAY for a peer that hangs up part way through a request. A connection
/// with no request in flight closes without a byte.
fn hangupGoaway(
    fd: std.posix.fd_t,
    streams: []const Stream,
    used: []const bool,
    last_stream_id: u31,
) void {
    if (!stream_slot.requestInFlight(streams, used)) return;

    goaway(fd, last_stream_id, frame.ERR_PROTOCOL_ERROR);
}

/// Frame loop for one connection, after the preface and SETTINGS.
///
/// Param:
/// handler_fn - handler.HandlerFn (the route or top-level handler)
/// fd - std.posix.fd_t (the connection)
/// decoder - *HpackDecoder (the connection's decoder)
/// opts - ServeOpts (stream, frame, and body limits)
/// initial_last_stream - u31 (1 after an upgrade, 0 otherwise)
/// io - std.Io (the worker io)
/// initial_peer_max_frame_size - u32 (the peer frame cap known so far)
///
/// Return:
/// - void when the peer sent GOAWAY
/// - an Inner error when the connection ends any other way
fn serveLoop(
    handler_fn: handler.HandlerFn,
    fd: std.posix.fd_t,
    decoder: *HpackDecoder,
    opts: ServeOpts,
    initial_last_stream: u31,
    io: std.Io,
    initial_peer_max_frame_size: u32,
) Inner!void {
    // A peer may raise SETTINGS_MAX_FRAME_SIZE mid-connection, so this is a
    // running value.
    var peer_max_frame_size = initial_peer_max_frame_size;
    var last_stream_id = initial_last_stream;

    const allocator = std.heap.smp_allocator;
    const max_payload = opts.max_frame_size + frame.FRAME_PAYLOAD_SLACK;

    const payload_buf = allocator.alloc(u8, max_payload) catch |err| switch (err) {
        error.OutOfMemory => return Error.ZixHttp2_Serve_OutOfMemory,
    };
    defer allocator.free(payload_buf);
    const streams = allocator.alloc(Stream, opts.max_streams) catch |err| switch (err) {
        error.OutOfMemory => return Error.ZixHttp2_Serve_OutOfMemory,
    };
    defer allocator.free(streams);
    const used = allocator.alloc(bool, opts.max_streams) catch |err| switch (err) {
        error.OutOfMemory => return Error.ZixHttp2_Serve_OutOfMemory,
    };
    defer allocator.free(used);

    @memset(used, false);

    while (true) {
        const header = reader.readFrameHeader(fd) catch |err| {
            hangupGoaway(fd, streams, used, last_stream_id);

            return err;
        };

        if (header.length > max_payload) {
            goaway(fd, last_stream_id, frame.ERR_FRAME_SIZE_ERROR);

            return Error.ZixHttp2_Serve_FrameTooLarge;
        }

        const payload = payload_buf[0..header.length];
        if (header.length > 0) try reader.recvExact(fd, payload);

        const sid = header.stream_id;
        const flags = header.flags;

        switch (header.frame_type) {
            frame.FRAME_TYPE_SETTINGS => {
                if ((flags & frame.FLAG_ACK) != 0) continue;

                applySettings(payload, decoder, &peer_max_frame_size);
                try control.sendSettingsAckFD(fd);
                try control.sendWindowUpdateFD(fd, 0, frame.DEFAULT_INITIAL_WINDOW);
            },
            frame.FRAME_TYPE_PING => {
                if ((flags & frame.FLAG_ACK) != 0) continue;

                if (payload.len != PING_LEN) {
                    goaway(fd, last_stream_id, frame.ERR_FRAME_SIZE_ERROR);

                    return Error.ZixHttp2_Serve_ProtocolError;
                }

                try control.sendPingAckFD(fd, payload[0..PING_LEN].*);
            },
            frame.FRAME_TYPE_HEADERS => {
                if (sid == 0) {
                    goaway(fd, last_stream_id, frame.ERR_PROTOCOL_ERROR);

                    return Error.ZixHttp2_Serve_ProtocolError;
                }
                if (sid <= last_stream_id and sid % 2 == 1) {
                    rstStream(fd, sid, frame.ERR_STREAM_CLOSED);

                    continue;
                }

                last_stream_id = @max(last_stream_id, sid);

                const slot = stream_slot.claim(sid, streams, used) orelse {
                    rstStream(fd, sid, frame.ERR_REFUSED_STREAM);

                    continue;
                };
                const stream = &streams[slot];
                stream.open(sid);

                const block = headerBlock(flags, payload) orelse {
                    goaway(fd, last_stream_id, frame.ERR_PROTOCOL_ERROR);

                    return Error.ZixHttp2_Serve_ProtocolError;
                };

                stream.header_count = decoder.decode(
                    block,
                    &stream.headers,
                    &stream.header_scratch,
                ) catch |err| switch (err) {
                    else => {
                        rstStream(fd, sid, frame.ERR_COMPRESSION_ERROR);
                        used[slot] = false;

                        continue;
                    },
                };
                stream.end_headers = (flags & frame.FLAG_END_HEADERS) != 0;
                stream.end_stream = (flags & frame.FLAG_END_STREAM) != 0;

                if (stream.end_headers and stream.end_stream) {
                    stream_invoke.invokeWhole(
                        handler_fn,
                        stream,
                        fd,
                        opts,
                        io,
                        peer_max_frame_size,
                    );
                    used[slot] = false;
                }
            },
            frame.FRAME_TYPE_CONTINUATION => {
                const slot = stream_slot.find(sid, streams, used) orelse {
                    goaway(fd, last_stream_id, frame.ERR_PROTOCOL_ERROR);

                    return Error.ZixHttp2_Serve_ProtocolError;
                };
                const stream = &streams[slot];

                const count = decoder.decode(
                    payload,
                    stream.headers[stream.header_count..],
                    &stream.header_scratch,
                ) catch |err| switch (err) {
                    else => {
                        rstStream(fd, sid, frame.ERR_COMPRESSION_ERROR);
                        used[slot] = false;

                        continue;
                    },
                };
                stream.header_count += count;
                stream.end_headers = (flags & frame.FLAG_END_HEADERS) != 0;

                if (stream.end_headers and stream.end_stream) {
                    stream_invoke.invokeWhole(
                        handler_fn,
                        stream,
                        fd,
                        opts,
                        io,
                        peer_max_frame_size,
                    );
                    used[slot] = false;
                }
            },
            frame.FRAME_TYPE_DATA => {
                if (sid == 0) {
                    goaway(fd, last_stream_id, frame.ERR_PROTOCOL_ERROR);

                    return Error.ZixHttp2_Serve_ProtocolError;
                }

                const slot = stream_slot.find(sid, streams, used) orelse {
                    rstStream(fd, sid, frame.ERR_STREAM_CLOSED);

                    continue;
                };
                const stream = &streams[slot];

                const data = dataBlock(flags, payload) orelse {
                    goaway(fd, last_stream_id, frame.ERR_PROTOCOL_ERROR);

                    return Error.ZixHttp2_Serve_ProtocolError;
                };

                // Shed instead of truncating: 413 with END_STREAM, slot freed.
                // Only the connection window is credited for the dropped bytes,
                // so the other streams keep flowing.
                if (!stream.appendBody(data)) {
                    if (data.len > 0) windowUpdate(fd, 0, data.len);
                    sendTooLarge(fd, sid);
                    used[slot] = false;

                    continue;
                }

                if (data.len > 0) {
                    windowUpdate(fd, 0, data.len);
                    windowUpdate(fd, sid, data.len);
                }

                stream.end_stream = (flags & frame.FLAG_END_STREAM) != 0;
                if (stream.end_stream) {
                    stream_invoke.invokeWhole(
                        handler_fn,
                        stream,
                        fd,
                        opts,
                        io,
                        peer_max_frame_size,
                    );
                    used[slot] = false;
                }
            },
            frame.FRAME_TYPE_RST_STREAM => {
                if (stream_slot.find(sid, streams, used)) |slot| used[slot] = false;
            },
            frame.FRAME_TYPE_GOAWAY => return,
            else => {},
        }
    }
}

/// Answer the HTTP/1.1 upgrade request as stream 1, then run the frame loop.
fn serveUpgrade(
    handler_fn: handler.HandlerFn,
    fd: std.posix.fd_t,
    opts: ServeOpts,
    prefix: []const u8,
    io: std.Io,
) Inner!void {
    var head_buf: [UPGRADE_HEAD_BUF]u8 = undefined;
    var settings_buf: [SETTINGS_DECODE_SCRATCH]u8 = undefined;
    const head = try upgrade.accept(fd, prefix, &head_buf, &settings_buf);

    try recvPreface(fd, "");

    // The upgrade header carries the client SETTINGS, so the frame cap for
    // the stream 1 response is known before any frame is exchanged.
    var decoder = HpackDecoder.init();
    var peer_max_frame_size: u32 = frame.DEFAULT_MAX_FRAME_SIZE;
    applySettings(head.settings, &decoder, &peer_max_frame_size);

    try sendServerSettings(fd, opts);

    const headers = [_]Header{
        .{
            .name = ":method",
            .value = head.method,
        },
        .{
            .name = ":path",
            .value = head.path,
        },
        .{
            .name = ":scheme",
            .value = "http",
        },
    };
    const split = Request.splitPath(head.path);
    var req: Request = .{
        .method = head.method,
        .path = split.path,
        .query = split.query,
        .headers = &headers,
        .body = &.{},
    };

    handler.invokeHandler(handler_fn, &req, fd, 1, io, opts, peer_max_frame_size);

    try serveLoop(handler_fn, fd, &decoder, opts, 1, io, peer_max_frame_size);
}

fn serveInner(
    handler_fn: handler.HandlerFn,
    fd: std.posix.fd_t,
    opts: ServeOpts,
    io: std.Io,
) Inner!void {
    var peek: [PEEK_LEN]u8 = undefined;
    try reader.recvExact(fd, &peek);

    if (!std.mem.eql(u8, &peek, frame.PREFACE[0..PEEK_LEN])) {
        return serveUpgrade(handler_fn, fd, opts, &peek, io);
    }

    try recvPreface(fd, &peek);
    try sendServerSettings(fd, opts);

    var decoder = HpackDecoder.init();

    try serveLoop(handler_fn, fd, &decoder, opts, 0, io, frame.DEFAULT_MAX_FRAME_SIZE);
}

// --------------------------------------------------------- //
// Public:

/// ZIX Http2 serve error
pub const Error = error {
    ZixHttp2_Serve_BadPreface,
    ZixHttp2_Serve_FrameTooLarge,
    ZixHttp2_Serve_ProtocolError,
    ZixHttp2_Serve_OutOfMemory,
};

/// Serve one h2c connection: prior knowledge or an HTTP/1.1 upgrade. The
/// caller owns the fd and closes it after this returns.
///
/// Param:
/// handler_fn - handler.HandlerFn (the route or top-level handler)
/// fd - std.posix.fd_t (the connection)
/// opts - ServeOpts (per-connection serve knobs)
/// io - std.Io (the worker io)
///
/// Return:
/// - void
pub fn serveConn(
    handler_fn: handler.HandlerFn,
    fd: std.posix.fd_t,
    opts: ServeOpts,
    io: std.Io,
) void {
    setNoDelay(fd);

    serveInner(handler_fn, fd, opts, io) catch |err| switch (err) {
        // The connection is over either way: the peer closed, broke the
        // protocol, or a write failed. Whatever the peer was owed was sent
        // before the error returned.
        else => {},
    };
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const pair = @import("../../utils/socket/pair.zig");
const Context = @import("Context.zig");
const HpackEncoder = @import("hpack/HpackEncoder.zig");
const Response = @import("Response.zig");

/// What the server answered with, read back after it returned.
const WireTally = struct {
    settings: usize = 0,
    rst_protocol_error: usize = 0,
    goaway_protocol_error: usize = 0,
    status_200: usize = 0,
    status_413: usize = 0,
};

threadlocal var tl_calls: usize = 0;
threadlocal var tl_body_len: usize = 0;

fn bodyHandler(req: *Request, res: *Response, _: *Context) anyerror!void {
    tl_calls += 1;
    tl_body_len = req.body.len;

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

fn writeAllTo(fd: std.posix.fd_t, data: []const u8) !void {
    try writer.writeAllDirectFD(fd, data);
}

/// Write one complete frame the way a client would.
fn writeFrameTo(
    fd: std.posix.fd_t,
    frame_type: u8,
    flags: u8,
    sid: u31,
    payload: []const u8,
) !void {
    var buf: [frame.FRAME_HEADER_LEN]u8 = undefined;
    frame.encodeFrameHeader(&buf, .{
        .length = @intCast(payload.len),
        .frame_type = frame_type,
        .flags = flags,
        .stream_id = sid,
    });

    try writeAllTo(fd, &buf);
    if (payload.len > 0) try writeAllTo(fd, payload);
}

/// Encode a request head, ending the headers but not the stream.
fn encodeHead(block: []u8, method: []const u8, content_length: ?[]const u8) ![]const u8 {
    var encoder = HpackEncoder.init(block);
    try encoder.writeHeader(":method", method);
    try encoder.writeHeader(":path", "/");
    if (content_length) |value| try encoder.writeHeader("content-length", value);

    return encoder.encoded();
}

/// Read everything the server wrote and count the answers that matter.
fn tallyWire(client_fd: std.posix.fd_t, server_fd: std.posix.fd_t, buf: []u8) WireTally {
    shutdownWrite(server_fd);

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
            frame.FRAME_TYPE_SETTINGS => {
                if ((header.flags & frame.FLAG_ACK) == 0) tally.settings += 1;
            },
            frame.FRAME_TYPE_RST_STREAM => {
                const code = std.mem.readInt(u32, payload[0..4], .big);
                if (code == frame.ERR_PROTOCOL_ERROR) tally.rst_protocol_error += 1;
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

/// Run the frame loop over everything already written, until EOF.
fn runLoopToEof(client_fd: std.posix.fd_t, server_fd: std.posix.fd_t, opts: ServeOpts) void {
    shutdownWrite(client_fd);

    var decoder = HpackDecoder.init();
    serveLoop(
        bodyHandler,
        server_fd,
        &decoder,
        opts,
        0,
        std.testing.io,
        frame.DEFAULT_MAX_FRAME_SIZE,
    ) catch |err| switch (err) {
        // The loop ends on EOF by design here.
        else => {},
    };
}

const UPGRADE_REQUEST =
    "GET / HTTP/1.1\r\n" ++
    "Host: localhost\r\n" ++
    "Connection: Upgrade, HTTP2-Settings\r\n" ++
    "Upgrade: h2c\r\n" ++
    "HTTP2-Settings: AAMAAABkAAQAAP__\r\n\r\n";

/// Bytes of the 101 reply, read whole so the frames after it stay aligned.
const SWITCHING_PROTOCOLS_LEN: usize =
    "HTTP/1.1 101 Switching Protocols\r\n".len +
    "Connection: Upgrade\r\nUpgrade: h2c\r\n\r\n".len;

/// Handler calls seen by the upgrade server thread.
var upgrade_calls: usize = 0;

fn upgradeHandler(_: *Request, res: *Response, _: *Context) anyerror!void {
    upgrade_calls += 1;

    try res.sendText("ok");
}

fn serveUpgradeProbe(fd: std.posix.fd_t) void {
    upgrade_calls = 0;

    serveConn(upgradeHandler, fd, .{}, std.testing.io);
}

test "zix http2: serve, headerBlock strips padding and priority" {
    const payload = [_]u8{ 2, 0, 0, 0, 1, 16, 'a', 'b', 0, 0 };
    const flags = frame.FLAG_PADDED | frame.FLAG_PRIORITY;

    try std.testing.expectEqualStrings("ab", headerBlock(flags, &payload).?);
}

test "zix http2: serve, headerBlock padding past the payload is malformed" {
    const payload = [_]u8{ 9, 'a' };

    try std.testing.expect(headerBlock(frame.FLAG_PADDED, &payload) == null);
}

test "zix http2: serve, dataBlock strips padding" {
    const payload = [_]u8{ 1, 'x', 'y', 0 };

    try std.testing.expectEqualStrings("xy", dataBlock(frame.FLAG_PADDED, &payload).?);
}

test "zix http2: serve, dataBlock padding past the payload is malformed" {
    const payload = [_]u8{ 5, 'x' };

    try std.testing.expect(dataBlock(frame.FLAG_PADDED, &payload) == null);
}

test "zix http2: serve, applySettings takes a valid max frame size" {
    var decoder = HpackDecoder.init();
    var peer_max: u32 = frame.DEFAULT_MAX_FRAME_SIZE;
    const params = [_]u8{ 0x00, 0x05, 0x00, 0x00, 0x80, 0x00 };

    applySettings(&params, &decoder, &peer_max);

    try std.testing.expectEqual(@as(u32, 32 * 1024), peer_max);
}

test "zix http2: serve, applySettings out of range keeps the last value" {
    var decoder = HpackDecoder.init();
    var peer_max: u32 = frame.DEFAULT_MAX_FRAME_SIZE;
    const params = [_]u8{ 0x00, 0x05, 0x00, 0x00, 0x00, 0x10 };

    applySettings(&params, &decoder, &peer_max);

    try std.testing.expectEqual(frame.DEFAULT_MAX_FRAME_SIZE, peer_max);
}

test "zix http2: serve, applySettings sets the HPACK table size" {
    var decoder = HpackDecoder.init();
    var peer_max: u32 = frame.DEFAULT_MAX_FRAME_SIZE;
    const params = [_]u8{ 0x00, 0x01, 0x00, 0x00, 0x00, 0x80 };

    applySettings(&params, &decoder, &peer_max);

    try std.testing.expectEqual(@as(usize, 128), decoder.max_size);
}

test "zix http2: serve, serveConn prior knowledge answers one request" {
    if (!isLinux()) return;

    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    var block: [128]u8 = undefined;
    const head = try encodeHead(&block, "GET", null);
    const flags = frame.FLAG_END_HEADERS | frame.FLAG_END_STREAM;

    try writeAllTo(fds[0], frame.PREFACE);
    try writeFrameTo(fds[0], frame.FRAME_TYPE_SETTINGS, 0, 0, "");
    try writeFrameTo(fds[0], frame.FRAME_TYPE_HEADERS, flags, 1, head);
    shutdownWrite(fds[0]);

    tl_calls = 0;
    serveConn(bodyHandler, fds[1], .{}, std.testing.io);

    var buf: [8192]u8 = undefined;
    const tally = tallyWire(fds[0], fds[1], &buf);

    try std.testing.expectEqual(@as(usize, 1), tl_calls);
    try std.testing.expectEqual(@as(usize, 1), tally.settings);
    try std.testing.expectEqual(@as(usize, 1), tally.status_200);
}

test "zix http2: serve, serveConn bad preface gets GOAWAY" {
    if (!isLinux()) return;

    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    try writeAllTo(fds[0], "PRI * HTTP/9.9\r\n\r\nXX\r\n\r\n");
    shutdownWrite(fds[0]);

    tl_calls = 0;
    serveConn(bodyHandler, fds[1], .{}, std.testing.io);

    var buf: [1024]u8 = undefined;
    const tally = tallyWire(fds[0], fds[1], &buf);

    try std.testing.expectEqual(@as(usize, 0), tl_calls);
    try std.testing.expectEqual(@as(usize, 1), tally.goaway_protocol_error);
}

test "zix http2: serve, serveConn h2c upgrade answers stream 1" {
    if (!isLinux()) return;

    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    tl_calls = 0;
    const server = try std.Thread.spawn(.{}, serveUpgradeProbe, .{fds[1]});

    try writeAllTo(fds[0], UPGRADE_REQUEST);

    var reply: [SWITCHING_PROTOCOLS_LEN]u8 = undefined;
    try reader.recvExact(fds[0], &reply);

    try writeAllTo(fds[0], frame.PREFACE);
    shutdownWrite(fds[0]);
    server.join();

    var buf: [8192]u8 = undefined;
    const tally = tallyWire(fds[0], fds[1], &buf);

    try std.testing.expect(std.mem.startsWith(u8, &reply, "HTTP/1.1 101"));
    try std.testing.expectEqual(@as(usize, 1), upgrade_calls);
    try std.testing.expectEqual(@as(usize, 1), tally.settings);
    try std.testing.expectEqual(@as(usize, 1), tally.status_200);
}

test "zix http2: serve, short body is reset" {
    if (!isLinux()) return;

    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    var block: [128]u8 = undefined;
    const head = try encodeHead(&block, "POST", "100");
    const short: [40]u8 = @splat('x');

    try writeFrameTo(fds[0], frame.FRAME_TYPE_HEADERS, frame.FLAG_END_HEADERS, 1, head);
    try writeFrameTo(fds[0], frame.FRAME_TYPE_DATA, frame.FLAG_END_STREAM, 1, &short);

    tl_calls = 0;
    runLoopToEof(fds[0], fds[1], .{});

    var buf: [8192]u8 = undefined;
    const tally = tallyWire(fds[0], fds[1], &buf);

    try std.testing.expectEqual(@as(usize, 0), tl_calls);
    try std.testing.expectEqual(@as(usize, 1), tally.rst_protocol_error);
    try std.testing.expectEqual(@as(usize, 0), tally.status_200);
}

test "zix http2: serve, matching body is served" {
    if (!isLinux()) return;

    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    var block: [128]u8 = undefined;
    const head = try encodeHead(&block, "POST", "40");
    const whole: [40]u8 = @splat('x');

    try writeFrameTo(fds[0], frame.FRAME_TYPE_HEADERS, frame.FLAG_END_HEADERS, 1, head);
    try writeFrameTo(fds[0], frame.FRAME_TYPE_DATA, frame.FLAG_END_STREAM, 1, &whole);

    tl_calls = 0;
    tl_body_len = 0;
    runLoopToEof(fds[0], fds[1], .{});

    var buf: [8192]u8 = undefined;
    const tally = tallyWire(fds[0], fds[1], &buf);

    try std.testing.expectEqual(@as(usize, 1), tl_calls);
    try std.testing.expectEqual(@as(usize, 40), tl_body_len);
    try std.testing.expectEqual(@as(usize, 0), tally.rst_protocol_error);
    try std.testing.expectEqual(@as(usize, 1), tally.status_200);
}

test "zix http2: serve, body past the stream buffer is shed with 413" {
    if (!isLinux()) return;

    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    var block: [128]u8 = undefined;
    const head = try encodeHead(&block, "POST", "70000");
    try writeFrameTo(fds[0], frame.FRAME_TYPE_HEADERS, frame.FLAG_END_HEADERS, 1, head);

    const chunk = try std.testing.allocator.alloc(u8, frame.DEFAULT_MAX_FRAME_SIZE);
    defer std.testing.allocator.free(chunk);
    @memset(chunk, 'y');

    const frames = Stream.BODY_BUF_SIZE / frame.DEFAULT_MAX_FRAME_SIZE;
    for (0..frames) |_| try writeFrameTo(fds[0], frame.FRAME_TYPE_DATA, 0, 1, chunk);
    try writeFrameTo(fds[0], frame.FRAME_TYPE_DATA, frame.FLAG_END_STREAM, 1, chunk[0..1]);

    tl_calls = 0;
    runLoopToEof(fds[0], fds[1], .{});

    var buf: [32 * 1024]u8 = undefined;
    const tally = tallyWire(fds[0], fds[1], &buf);

    try std.testing.expectEqual(@as(usize, 0), tl_calls);
    try std.testing.expectEqual(@as(usize, 1), tally.status_413);
    try std.testing.expectEqual(@as(usize, 0), tally.status_200);
}

test "zix http2: serve, hang-up with a request unfinished gets GOAWAY" {
    if (!isLinux()) return;

    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    var block: [128]u8 = undefined;
    const head = try encodeHead(&block, "POST", "100");
    try writeFrameTo(fds[0], frame.FRAME_TYPE_HEADERS, frame.FLAG_END_HEADERS, 1, head);

    tl_calls = 0;
    runLoopToEof(fds[0], fds[1], .{});

    var buf: [8192]u8 = undefined;
    const tally = tallyWire(fds[0], fds[1], &buf);

    try std.testing.expectEqual(@as(usize, 0), tl_calls);
    try std.testing.expectEqual(@as(usize, 1), tally.goaway_protocol_error);
}

test "zix http2: serve, idle hang-up closes without GOAWAY" {
    if (!isLinux()) return;

    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    var block: [128]u8 = undefined;
    const head = try encodeHead(&block, "GET", null);
    const flags = frame.FLAG_END_HEADERS | frame.FLAG_END_STREAM;
    try writeFrameTo(fds[0], frame.FRAME_TYPE_HEADERS, flags, 1, head);

    tl_calls = 0;
    runLoopToEof(fds[0], fds[1], .{});

    var buf: [8192]u8 = undefined;
    const tally = tallyWire(fds[0], fds[1], &buf);

    try std.testing.expectEqual(@as(usize, 1), tl_calls);
    try std.testing.expectEqual(@as(usize, 0), tally.goaway_protocol_error);
    try std.testing.expectEqual(@as(usize, 1), tally.status_200);
}

test "zix http2: serve, PING gets an ACK with the same payload" {
    if (!isLinux()) return;

    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    try writeFrameTo(fds[0], frame.FRAME_TYPE_PING, 0, 0, "12345678");
    runLoopToEof(fds[0], fds[1], .{});

    shutdownWrite(fds[1]);
    var buf: [64]u8 = undefined;
    const got = try std.posix.read(fds[0], &buf);
    const header = frame.parseFrameHeader(buf[0..frame.FRAME_HEADER_LEN]);

    try std.testing.expect(got >= frame.FRAME_HEADER_LEN + 8);
    try std.testing.expectEqual(frame.FRAME_TYPE_PING, header.frame_type);
    try std.testing.expectEqual(frame.FLAG_ACK, header.flags);
    try std.testing.expectEqualStrings("12345678", buf[frame.FRAME_HEADER_LEN..][0..8]);
}

