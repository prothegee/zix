//! ZIX Http2 Grpc serve
//!
//! ### file: src/zix/tcp/http2/grpc/serve.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Serve one gRPC h2c connection: prior knowledge or an HTTP/1.1 upgrade,
//! then one frame at a time.
//!
//! ### note:
//!
//! Server-streaming calls write from their own task, so every write on the
//! connection goes through the ConnMutex. On an upgrade, stream 1 runs
//! inline before the frame loop starts.
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
const control = @import("../control.zig");
const deadline = @import("deadline.zig");
const frame = @import("../frame.zig");
const frame_payload = @import("../frame_payload.zig");
const handler = @import("handler.zig");
const peer_settings = @import("../peer_settings.zig");
const reader = @import("../reader.zig");
const send = @import("frame/send.zig");
const send_best_effort = @import("../send_best_effort.zig");
const stream_dispatch = @import("stream_dispatch.zig");
const stream_slot = @import("stream_slot.zig");
const upgrade = @import("../upgrade.zig");
const window = @import("window.zig");
const ConnMutex = @import("ConnMutex.zig");
const ConnReader = @import("ConnReader.zig");
const Context = @import("Context.zig");
const GrpcStatus = @import("status.zig").GrpcStatus;
const Header = @import("../hpack/Header.zig");
const HpackDecoder = @import("../hpack/HpackDecoder.zig");
const Request = @import("Request.zig");
const ServeOpts = @import("ServeOpts.zig");
const Stream = @import("Stream.zig");

// --------------------------------------------------------- //
// Private:

const Inner =
    Error ||
    reader.Error ||
    control.Error ||
    upgrade.Error ||
    ConnReader.Error ||
    ConnMutex.Error;

/// Decoded HTTP2-Settings scratch on an h2c upgrade.
const SETTINGS_DECODE_SCRATCH: usize = 256;

/// HTTP/1.1 head bound on an h2c upgrade.
const UPGRADE_HEAD_BUF: usize = 8192;

/// Bytes read before deciding between the preface and an upgrade.
const PEEK_LEN: usize = 3;

/// Bytes in a PING payload.
const PING_LEN: usize = 8;

/// grpc-message for a body past max_body.
const BODY_TOO_LARGE_MESSAGE: []const u8 = "request message exceeds max_body";

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

/// Read the rest of the client preface after `have` bytes were read.
fn recvPreface(fd: std.posix.fd_t, have: []const u8) Inner!void {
    var preface: [frame.PREFACE.len]u8 = undefined;
    @memcpy(preface[0..have.len], have);
    try reader.recvExact(fd, preface[have.len..]);

    if (!std.mem.eql(u8, &preface, frame.PREFACE)) {
        send_best_effort.goaway(fd, 0, frame.ERR_PROTOCOL_ERROR);

        return Error.ZixHttp2_GrpcServe_BadPreface;
    }
}

/// Send this server's SETTINGS, with the large gRPC stream window.
fn sendServerSettings(fd: std.posix.fd_t, opts: ServeOpts) Inner!void {
    try control.sendSettingsFD(fd, &.{
        .{ frame.SETTINGS_MAX_CONCURRENT_STREAMS, @as(u32, @intCast(opts.max_streams)) },
        .{ frame.SETTINGS_INITIAL_WINDOW_SIZE, window.STREAM_WINDOW_SIZE },
        .{ frame.SETTINGS_MAX_FRAME_SIZE, opts.max_frame_size },
        .{ frame.SETTINGS_ENABLE_PUSH, 0 },
    });
}

fn lockedGoaway(
    conn_mutex: *ConnMutex,
    fd: std.posix.fd_t,
    last_stream_id: u31,
    error_code: u32,
) void {
    conn_mutex.lock();
    defer conn_mutex.unlock();

    send_best_effort.goaway(fd, last_stream_id, error_code);
}

fn lockedRst(conn_mutex: *ConnMutex, fd: std.posix.fd_t, sid: u31, error_code: u32) void {
    conn_mutex.lock();
    defer conn_mutex.unlock();

    send_best_effort.rstStream(fd, sid, error_code);
}

/// Close a stream whose body went past max_body with RESOURCE_EXHAUSTED.
fn lockedTooLarge(conn_mutex: *ConnMutex, fd: std.posix.fd_t, sid: u31) void {
    conn_mutex.lock();
    defer conn_mutex.unlock();

    const status_code = @intFromEnum(GrpcStatus.RESOURCE_EXHAUSTED);

    send.sendGrpcErrorFD(fd, sid, status_code, BODY_TOO_LARGE_MESSAGE) catch |err| switch (err) {
        // Best effort: the peer went away. The loop sees it on its next read.
        error.ZixHttp2_GrpcSend_BrokenPipe,
        error.ZixHttp2_GrpcSend_UnexpectedEOF,
        error.ZixHttp2_GrpcSend_Overflow,
        error.ZixHttp2_GrpcSend_BufferFull,
        => {},
    };
}

/// GOAWAY for a peer that hangs up part way through a request. A connection
/// with no request in flight closes without a byte.
fn hangupGoaway(
    conn_mutex: *ConnMutex,
    fd: std.posix.fd_t,
    streams: []const Stream,
    used: []const bool,
    last_stream_id: u31,
) void {
    if (!stream_slot.requestInFlight(streams, used)) return;

    lockedGoaway(conn_mutex, fd, last_stream_id, frame.ERR_PROTOCOL_ERROR);
}

fn allocOrOom(comptime T: type, len: usize) Inner![]T {
    return std.heap.smp_allocator.alloc(T, len) catch |err| switch (err) {
        error.OutOfMemory => Error.ZixHttp2_GrpcServe_OutOfMemory,
    };
}

/// Frame loop for one connection, after the preface and SETTINGS.
///
/// Param:
/// RouterType - type (a Router, carrying route_slice and dispatch)
/// fd - std.posix.fd_t (the connection)
/// decoder - *HpackDecoder (the connection's decoder)
/// opts - ServeOpts (stream, frame, and body limits)
/// initial_last_stream - u31 (1 after an upgrade, 0 otherwise)
/// io - std.Io (the worker io)
///
/// Return:
/// - void when the peer sent GOAWAY
/// - an Inner error when the connection ends any other way
fn serveLoop(
    comptime RouterType: type,
    fd: std.posix.fd_t,
    decoder: *HpackDecoder,
    opts: ServeOpts,
    initial_last_stream: u31,
    io: std.Io,
) Inner!void {
    const allocator = std.heap.smp_allocator;
    const max_payload = opts.max_frame_size + frame.FRAME_PAYLOAD_SLACK;
    // Room for one whole frame, and enough to batch small frames per read.
    const reader_cap = @max(opts.conn_read_buf_min, max_payload + frame.FRAME_HEADER_LEN);

    const reader_buf = try allocOrOom(u8, reader_cap);
    defer allocator.free(reader_buf);
    const streams = try allocOrOom(Stream, opts.max_streams);
    defer allocator.free(streams);
    const used = try allocOrOom(bool, opts.max_streams);
    defer allocator.free(used);
    const bodies = try allocOrOom(u8, opts.max_body * opts.max_streams);
    defer allocator.free(bodies);
    const scratches = try allocOrOom(u8, opts.max_header_scratch * opts.max_streams);
    defer allocator.free(scratches);
    const conn_mutex = try ConnMutex.create();
    defer conn_mutex.release();

    @memset(used, false);
    for (streams, 0..) |*stream, index| {
        const scratch_at = index * opts.max_header_scratch;

        stream.* = .{
            .body = bodies[index * opts.max_body ..][0..opts.max_body],
            .header_scratch = scratches[scratch_at..][0..opts.max_header_scratch],
        };
    }

    var conn_reader: ConnReader = .{
        .fd = fd,
        .buf = reader_buf,
    };
    var last_stream_id = initial_last_stream;
    var conn_window_consumed: usize = 0;
    // gRPC replies are small, so the peer frame cap is not read back.
    var peer_max_frame_size: u32 = frame.DEFAULT_MAX_FRAME_SIZE;

    while (true) {
        conn_reader.ensure(frame.FRAME_HEADER_LEN) catch |err| {
            hangupGoaway(conn_mutex, fd, streams, used, last_stream_id);

            return err;
        };
        const head_bytes = conn_reader.take(frame.FRAME_HEADER_LEN);
        const header = frame.parseFrameHeader(head_bytes[0..frame.FRAME_HEADER_LEN]);

        if (header.length > max_payload) {
            lockedGoaway(conn_mutex, fd, last_stream_id, frame.ERR_FRAME_SIZE_ERROR);

            return Error.ZixHttp2_GrpcServe_FrameTooLarge;
        }

        try conn_reader.ensure(header.length);
        const payload = conn_reader.take(header.length);

        const sid = header.stream_id;
        const flags = header.flags;

        switch (header.frame_type) {
            frame.FRAME_TYPE_SETTINGS => {
                if ((flags & frame.FLAG_ACK) != 0) continue;

                _ = peer_settings.apply(payload, decoder, &peer_max_frame_size);

                conn_mutex.lock();
                defer conn_mutex.unlock();

                try control.sendSettingsAckFD(fd);
                try control.sendWindowUpdateFD(fd, 0, window.CONN_WINDOW_BUMP);
            },
            frame.FRAME_TYPE_PING => {
                if ((flags & frame.FLAG_ACK) != 0) continue;

                if (payload.len != PING_LEN) {
                    lockedGoaway(conn_mutex, fd, last_stream_id, frame.ERR_FRAME_SIZE_ERROR);

                    return Error.ZixHttp2_GrpcServe_ProtocolError;
                }

                conn_mutex.lock();
                defer conn_mutex.unlock();

                try control.sendPingAckFD(fd, payload[0..PING_LEN].*);
            },
            frame.FRAME_TYPE_HEADERS => {
                if (sid == 0) {
                    lockedGoaway(conn_mutex, fd, last_stream_id, frame.ERR_PROTOCOL_ERROR);

                    return Error.ZixHttp2_GrpcServe_ProtocolError;
                }
                if (sid <= last_stream_id and sid % 2 == 1) {
                    lockedRst(conn_mutex, fd, sid, frame.ERR_STREAM_CLOSED);

                    continue;
                }

                last_stream_id = @max(last_stream_id, sid);

                const slot = stream_slot.claim(sid, streams, used) orelse {
                    lockedRst(conn_mutex, fd, sid, frame.ERR_REFUSED_STREAM);

                    continue;
                };
                const stream = &streams[slot];
                stream.open(sid);

                const block = frame_payload.headerBlock(flags, payload) orelse {
                    lockedGoaway(conn_mutex, fd, last_stream_id, frame.ERR_PROTOCOL_ERROR);

                    return Error.ZixHttp2_GrpcServe_ProtocolError;
                };

                stream.header_count = decoder.decode(
                    block,
                    &stream.headers,
                    stream.header_scratch,
                ) catch |err| switch (err) {
                    else => {
                        lockedRst(conn_mutex, fd, sid, frame.ERR_COMPRESSION_ERROR);
                        used[slot] = false;

                        continue;
                    },
                };
                stream.end_headers = (flags & frame.FLAG_END_HEADERS) != 0;
                stream.end_stream = (flags & frame.FLAG_END_STREAM) != 0;

                if (stream.end_headers and stream.end_stream) {
                    stream_dispatch.dispatchWhole(RouterType, stream, fd, opts, conn_mutex, io);
                    used[slot] = false;
                }
            },
            frame.FRAME_TYPE_CONTINUATION => {
                const slot = stream_slot.find(sid, streams, used) orelse {
                    lockedGoaway(conn_mutex, fd, last_stream_id, frame.ERR_PROTOCOL_ERROR);

                    return Error.ZixHttp2_GrpcServe_ProtocolError;
                };
                const stream = &streams[slot];

                const count = decoder.decode(
                    payload,
                    stream.headers[stream.header_count..],
                    stream.header_scratch,
                ) catch |err| switch (err) {
                    else => {
                        lockedRst(conn_mutex, fd, sid, frame.ERR_COMPRESSION_ERROR);
                        used[slot] = false;

                        continue;
                    },
                };
                stream.header_count += count;
                stream.end_headers = (flags & frame.FLAG_END_HEADERS) != 0;

                if (stream.end_headers and stream.end_stream) {
                    stream_dispatch.dispatchWhole(RouterType, stream, fd, opts, conn_mutex, io);
                    used[slot] = false;
                }
            },
            frame.FRAME_TYPE_DATA => {
                if (sid == 0) {
                    lockedGoaway(conn_mutex, fd, last_stream_id, frame.ERR_PROTOCOL_ERROR);

                    return Error.ZixHttp2_GrpcServe_ProtocolError;
                }

                const slot = stream_slot.find(sid, streams, used) orelse {
                    lockedRst(conn_mutex, fd, sid, frame.ERR_STREAM_CLOSED);

                    continue;
                };
                const stream = &streams[slot];

                const data = frame_payload.dataBlock(flags, payload) orelse {
                    lockedGoaway(conn_mutex, fd, last_stream_id, frame.ERR_PROTOCOL_ERROR);

                    return Error.ZixHttp2_GrpcServe_ProtocolError;
                };

                // The stream window is large, so only the connection window
                // is replenished, in bulk.
                conn_window_consumed += data.len;
                if (conn_window_consumed >= window.CONN_REPLENISH_THRESHOLD) {
                    conn_mutex.lock();
                    defer conn_mutex.unlock();

                    send_best_effort.windowUpdate(fd, 0, conn_window_consumed);
                    conn_window_consumed = 0;
                }

                // Shed instead of truncating: a cut message would reach the
                // handler as a corrupt one.
                if (!stream.appendBody(data)) {
                    lockedTooLarge(conn_mutex, fd, sid);
                    used[slot] = false;

                    continue;
                }

                stream.end_stream = (flags & frame.FLAG_END_STREAM) != 0;
                if (stream.end_stream) {
                    stream_dispatch.dispatchWhole(RouterType, stream, fd, opts, conn_mutex, io);
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
    comptime RouterType: type,
    fd: std.posix.fd_t,
    opts: ServeOpts,
    prefix: []const u8,
    io: std.Io,
) Inner!void {
    var head_buf: [UPGRADE_HEAD_BUF]u8 = undefined;
    var settings_buf: [SETTINGS_DECODE_SCRATCH]u8 = undefined;
    const head = try upgrade.accept(fd, prefix, &head_buf, &settings_buf);

    try recvPreface(fd, "");

    var decoder = HpackDecoder.init();
    var peer_max_frame_size: u32 = frame.DEFAULT_MAX_FRAME_SIZE;
    _ = peer_settings.apply(head.settings, &decoder, &peer_max_frame_size);

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
    const started = handler.rpcStart(io, opts.logger);

    var arena_buf: [Context.CTX_ARENA_BYTES]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&arena_buf);

    // No task runs yet, so stream 1 writes straight to the fd.
    var ctx = Context.init(io, fba.allocator(), fd, 1, &.{});
    ctx.path = head.path;
    ctx.deadline = deadline.computeDeadline(io, opts.handler_timeout_ms, &headers);

    var req: Request = .{
        .path = head.path,
        .headers = &headers,
        ._ctx = &ctx,
    };

    handler.invoke(RouterType.dispatch, &req, &ctx);
    handler.writeRpcRecord(opts.logger, started, &ctx, head.path, 0);

    try serveLoop(RouterType, fd, &decoder, opts, 1, io);
}

fn serveInner(
    comptime RouterType: type,
    fd: std.posix.fd_t,
    opts: ServeOpts,
    io: std.Io,
) Inner!void {
    var peek: [PEEK_LEN]u8 = undefined;
    try reader.recvExact(fd, &peek);

    if (!std.mem.eql(u8, &peek, frame.PREFACE[0..PEEK_LEN])) {
        return serveUpgrade(RouterType, fd, opts, &peek, io);
    }

    try recvPreface(fd, &peek);
    try sendServerSettings(fd, opts);

    var decoder = HpackDecoder.init();

    try serveLoop(RouterType, fd, &decoder, opts, 0, io);
}

// --------------------------------------------------------- //
// Public:

/// ZIX Http2 Grpc serve error
pub const Error = error {
    ZixHttp2_GrpcServe_BadPreface,
    ZixHttp2_GrpcServe_FrameTooLarge,
    ZixHttp2_GrpcServe_ProtocolError,
    ZixHttp2_GrpcServe_OutOfMemory,
};

/// Serve one gRPC h2c connection: prior knowledge or an HTTP/1.1 upgrade.
/// The caller owns the fd and closes it after this returns.
///
/// Param:
/// RouterType - type (a Router, carrying route_slice and dispatch)
/// fd - std.posix.fd_t (the connection)
/// opts - ServeOpts (per-connection serve knobs)
/// io - std.Io (the worker io)
///
/// Return:
/// - void
pub fn serveConn(
    comptime RouterType: type,
    fd: std.posix.fd_t,
    opts: ServeOpts,
    io: std.Io,
) void {
    setNoDelay(fd);

    serveInner(RouterType, fd, opts, io) catch |err| switch (err) {
        // The connection is over either way: the peer closed, broke the
        // protocol, or a write failed. Whatever the peer was owed was sent
        // before the error returned.
        else => {},
    };
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const pair = @import("../../../utils/socket/pair.zig");
const prefix_mod = @import("frame/prefix.zig");
const router = @import("router.zig");
const writer = @import("../writer.zig");
const HpackEncoder = @import("../hpack/HpackEncoder.zig");
const Response = @import("Response.zig");

/// What the server answered with, read back after it returned.
const WireTally = struct {
    settings: usize = 0,
    data_frames: usize = 0,
    rst_protocol_error: usize = 0,
    goaway_protocol_error: usize = 0,
    goaway_frame_size_error: usize = 0,
    status_ok: usize = 0,
    status_resource_exhausted: usize = 0,
    status_unimplemented: usize = 0,
};

const UPGRADE_REQUEST =
    "POST /svc.Svc/Unary HTTP/1.1\r\n" ++
    "Host: localhost\r\n" ++
    "Connection: Upgrade, HTTP2-Settings\r\n" ++
    "Upgrade: h2c\r\n" ++
    "HTTP2-Settings: AAMAAABkAAQAAP__\r\n\r\n";

/// Bytes of the 101 reply, read whole so the frames after it stay aligned.
const SWITCHING_PROTOCOLS_LEN: usize = upgrade.SWITCHING_PROTOCOLS.len;

var tl_calls: std.atomic.Value(usize) = .init(0);
var tl_body_len: usize = 0;

fn unaryHandler(req: *Request, res: *Response, _: *Context) anyerror!void {
    _ = tl_calls.fetchAdd(1, .monotonic);

    const msg = req.recvMessage() orelse "";
    tl_body_len = msg.len;

    try res.sendMessage("application/grpc", msg);
    try res.finish(.OK, "");
}

const TestRouter = router.Router(&[_]router.Route{
    .{
        .path = "/svc.Svc/Unary",
        .handler = unaryHandler,
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

/// Encode a call head, with an optional content-length.
fn encodeHead(block: []u8, call_path: []const u8, content_length: ?[]const u8) ![]const u8 {
    var encoder = HpackEncoder.init(block);
    try encoder.writeHeader(":method", "POST");
    try encoder.writeHeader(":path", call_path);
    try encoder.writeHeader("content-type", "application/grpc");
    if (content_length) |value| try encoder.writeHeader("content-length", value);

    return encoder.encoded();
}

fn countStatus(tally: *WireTally, value: []const u8) void {
    if (std.mem.eql(u8, value, "0")) tally.status_ok += 1;
    if (std.mem.eql(u8, value, "8")) tally.status_resource_exhausted += 1;
    if (std.mem.eql(u8, value, "12")) tally.status_unimplemented += 1;
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
            frame.FRAME_TYPE_DATA => tally.data_frames += 1,
            frame.FRAME_TYPE_RST_STREAM => {
                const code = std.mem.readInt(u32, payload[0..4], .big);
                if (code == frame.ERR_PROTOCOL_ERROR) tally.rst_protocol_error += 1;
            },
            frame.FRAME_TYPE_GOAWAY => {
                const code = std.mem.readInt(u32, payload[4..8], .big);
                if (code == frame.ERR_PROTOCOL_ERROR) tally.goaway_protocol_error += 1;
                if (code == frame.ERR_FRAME_SIZE_ERROR) tally.goaway_frame_size_error += 1;
            },
            frame.FRAME_TYPE_HEADERS => {
                var headers: [frame.MAX_HEADERS]Header = undefined;
                var scratch: [256]u8 = undefined;
                const count = decoder.decode(payload, &headers, &scratch) catch continue;

                for (headers[0..count]) |entry| {
                    if (!std.mem.eql(u8, entry.name, "grpc-status")) continue;

                    countStatus(&tally, entry.value);
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
    const io = std.testing.io;

    serveLoop(TestRouter, server_fd, &decoder, opts, 0, io) catch |err| switch (err) {
        // The loop ends on EOF by design here.
        else => {},
    };
}

fn serveUpgradeProbe(fd: std.posix.fd_t) void {
    serveConn(TestRouter, fd, .{}, std.testing.io);
}

/// A gRPC body: one message behind its prefix.
fn grpcBody(buf: []u8, msg: []const u8) []const u8 {
    prefix_mod.writeGrpcPrefix(buf[0..prefix_mod.PREFIX_LEN], false, @intCast(msg.len));
    @memcpy(buf[prefix_mod.PREFIX_LEN..][0..msg.len], msg);

    return buf[0 .. prefix_mod.PREFIX_LEN + msg.len];
}

test "zix http2 grpc: serve, serveConn prior knowledge answers one call" {
    if (!isLinux()) return;

    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    var block: [128]u8 = undefined;
    const head = try encodeHead(&block, "/svc.Svc/Unary", null);
    var body_buf: [16]u8 = undefined;
    const body = grpcBody(&body_buf, "ping");

    try writeAllTo(fds[0], frame.PREFACE);
    try writeFrameTo(fds[0], frame.FRAME_TYPE_SETTINGS, 0, 0, "");
    try writeFrameTo(fds[0], frame.FRAME_TYPE_HEADERS, frame.FLAG_END_HEADERS, 1, head);
    try writeFrameTo(fds[0], frame.FRAME_TYPE_DATA, frame.FLAG_END_STREAM, 1, body);
    shutdownWrite(fds[0]);

    tl_calls.store(0, .monotonic);
    serveConn(TestRouter, fds[1], .{}, std.testing.io);

    var buf: [8192]u8 = undefined;
    const tally = tallyWire(fds[0], fds[1], &buf);

    try std.testing.expectEqual(@as(usize, 1), tl_calls.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 1), tally.settings);
    try std.testing.expectEqual(@as(usize, 1), tally.data_frames);
    try std.testing.expectEqual(@as(usize, 1), tally.status_ok);
}

test "zix http2 grpc: serve, serveConn bad preface gets GOAWAY" {
    if (!isLinux()) return;

    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    try writeAllTo(fds[0], "PRI * HTTP/9.9\r\n\r\nXX\r\n\r\n");
    shutdownWrite(fds[0]);

    tl_calls.store(0, .monotonic);
    serveConn(TestRouter, fds[1], .{}, std.testing.io);

    var buf: [1024]u8 = undefined;
    const tally = tallyWire(fds[0], fds[1], &buf);

    try std.testing.expectEqual(@as(usize, 0), tl_calls.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 1), tally.goaway_protocol_error);
}

test "zix http2 grpc: serve, serveConn h2c upgrade answers stream 1" {
    if (!isLinux()) return;

    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    tl_calls.store(0, .monotonic);
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
    try std.testing.expectEqual(@as(usize, 1), tl_calls.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 1), tally.settings);
    try std.testing.expectEqual(@as(usize, 1), tally.status_ok);
}

test "zix http2 grpc: serve, unknown method is UNIMPLEMENTED" {
    if (!isLinux()) return;

    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    var block: [128]u8 = undefined;
    const head = try encodeHead(&block, "/svc.Svc/Missing", null);
    const flags = frame.FLAG_END_HEADERS | frame.FLAG_END_STREAM;
    try writeFrameTo(fds[0], frame.FRAME_TYPE_HEADERS, flags, 1, head);

    tl_calls.store(0, .monotonic);
    runLoopToEof(fds[0], fds[1], .{});

    var buf: [8192]u8 = undefined;
    const tally = tallyWire(fds[0], fds[1], &buf);

    try std.testing.expectEqual(@as(usize, 0), tl_calls.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 1), tally.status_unimplemented);
}

test "zix http2 grpc: serve, short body is reset" {
    if (!isLinux()) return;

    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    var block: [128]u8 = undefined;
    const head = try encodeHead(&block, "/svc.Svc/Unary", "100");
    const short: [40]u8 = @splat('x');

    try writeFrameTo(fds[0], frame.FRAME_TYPE_HEADERS, frame.FLAG_END_HEADERS, 1, head);
    try writeFrameTo(fds[0], frame.FRAME_TYPE_DATA, frame.FLAG_END_STREAM, 1, &short);

    tl_calls.store(0, .monotonic);
    runLoopToEof(fds[0], fds[1], .{});

    var buf: [8192]u8 = undefined;
    const tally = tallyWire(fds[0], fds[1], &buf);

    try std.testing.expectEqual(@as(usize, 0), tl_calls.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 1), tally.rst_protocol_error);
}

test "zix http2 grpc: serve, matching body is served" {
    if (!isLinux()) return;

    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    var block: [128]u8 = undefined;
    const head = try encodeHead(&block, "/svc.Svc/Unary", "9");
    var body_buf: [16]u8 = undefined;
    const body = grpcBody(&body_buf, "ping");

    try writeFrameTo(fds[0], frame.FRAME_TYPE_HEADERS, frame.FLAG_END_HEADERS, 1, head);
    try writeFrameTo(fds[0], frame.FRAME_TYPE_DATA, frame.FLAG_END_STREAM, 1, body);

    tl_calls.store(0, .monotonic);
    tl_body_len = 0;
    runLoopToEof(fds[0], fds[1], .{});

    var buf: [8192]u8 = undefined;
    const tally = tallyWire(fds[0], fds[1], &buf);

    try std.testing.expectEqual(@as(usize, 1), tl_calls.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 4), tl_body_len);
    try std.testing.expectEqual(@as(usize, 0), tally.rst_protocol_error);
}

test "zix http2 grpc: serve, body past max_body is RESOURCE_EXHAUSTED" {
    if (!isLinux()) return;

    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    var block: [128]u8 = undefined;
    const head = try encodeHead(&block, "/svc.Svc/Unary", null);
    const big: [64]u8 = @splat('y');

    try writeFrameTo(fds[0], frame.FRAME_TYPE_HEADERS, frame.FLAG_END_HEADERS, 1, head);
    try writeFrameTo(fds[0], frame.FRAME_TYPE_DATA, frame.FLAG_END_STREAM, 1, &big);

    tl_calls.store(0, .monotonic);
    runLoopToEof(fds[0], fds[1], .{
        .max_body = 32,
    });

    var buf: [8192]u8 = undefined;
    const tally = tallyWire(fds[0], fds[1], &buf);

    try std.testing.expectEqual(@as(usize, 0), tl_calls.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 1), tally.status_resource_exhausted);
}

test "zix http2 grpc: serve, frame past max_frame_size gets GOAWAY" {
    if (!isLinux()) return;

    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    var head: [frame.FRAME_HEADER_LEN]u8 = undefined;
    frame.encodeFrameHeader(&head, .{
        .length = frame.DEFAULT_MAX_FRAME_SIZE + frame.FRAME_PAYLOAD_SLACK + 1,
        .frame_type = frame.FRAME_TYPE_DATA,
        .flags = 0,
        .stream_id = 1,
    });
    try writeAllTo(fds[0], &head);

    runLoopToEof(fds[0], fds[1], .{});

    var buf: [1024]u8 = undefined;
    const tally = tallyWire(fds[0], fds[1], &buf);

    try std.testing.expectEqual(@as(usize, 1), tally.goaway_frame_size_error);
}

test "zix http2 grpc: serve, hang-up with a call unfinished gets GOAWAY" {
    if (!isLinux()) return;

    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    var block: [128]u8 = undefined;
    const head = try encodeHead(&block, "/svc.Svc/Unary", "100");
    try writeFrameTo(fds[0], frame.FRAME_TYPE_HEADERS, frame.FLAG_END_HEADERS, 1, head);

    tl_calls.store(0, .monotonic);
    runLoopToEof(fds[0], fds[1], .{});

    var buf: [8192]u8 = undefined;
    const tally = tallyWire(fds[0], fds[1], &buf);

    try std.testing.expectEqual(@as(usize, 0), tl_calls.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 1), tally.goaway_protocol_error);
}

test "zix http2 grpc: serve, idle hang-up closes without GOAWAY" {
    if (!isLinux()) return;

    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    var block: [128]u8 = undefined;
    const head = try encodeHead(&block, "/svc.Svc/Unary", "5");
    var body_buf: [8]u8 = undefined;
    const body = grpcBody(&body_buf, "");

    try writeFrameTo(fds[0], frame.FRAME_TYPE_HEADERS, frame.FLAG_END_HEADERS, 1, head);
    try writeFrameTo(fds[0], frame.FRAME_TYPE_DATA, frame.FLAG_END_STREAM, 1, body);

    tl_calls.store(0, .monotonic);
    runLoopToEof(fds[0], fds[1], .{});

    var buf: [8192]u8 = undefined;
    const tally = tallyWire(fds[0], fds[1], &buf);

    try std.testing.expectEqual(@as(usize, 1), tl_calls.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 0), tally.goaway_protocol_error);
}

test "zix http2 grpc: serve, PING gets an ACK with the same payload" {
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

    try std.testing.expect(got >= frame.FRAME_HEADER_LEN + PING_LEN);
    try std.testing.expectEqual(frame.FRAME_TYPE_PING, header.frame_type);
    try std.testing.expectEqual(frame.FLAG_ACK, header.flags);
    try std.testing.expectEqualStrings("12345678", buf[frame.FRAME_HEADER_LEN..][0..PING_LEN]);
}

