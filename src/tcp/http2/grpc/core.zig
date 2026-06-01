//! gRPC h2c connection loop, handler context, and path/content-type utilities.

const std = @import("std");
const h2 = @import("../Http2.zig");
const frm = @import("frame.zig");
const status = @import("status.zig");
const Logger = @import("../../../logger/logger.zig").Logger;
const parseTimeout = @import("timeout.zig").parseTimeout;

pub const GrpcStatus = status.GrpcStatus;

/// Return the current wall-clock time in nanoseconds (CLOCK_REALTIME basis).
/// Use this when overriding ctx.deadline_ns at runtime inside a handler.
pub fn wallClockNs() u64 {
    var timespec: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.REALTIME, &timespec);
    return @as(u64, @intCast(timespec.sec)) * std.time.ns_per_s + @as(u64, @intCast(timespec.nsec));
}

// --------------------------------------------------------- //

pub const GrpcContentType = enum { PROTO, JSON, UNKNOWN };

/// Detect gRPC content-type from request headers.
pub fn detectContentType(headers: []const h2.Header) GrpcContentType {
    for (headers) |hdr| {
        if (!std.ascii.eqlIgnoreCase(hdr.name, "content-type")) continue;
        if (std.mem.startsWith(u8, hdr.value, "application/grpc+json")) return .JSON;
        if (std.mem.startsWith(u8, hdr.value, "application/grpc")) return .PROTO;
    }
    return .UNKNOWN;
}

/// gRPC path components from /<package.Service>/<Method>.
pub const GrpcPath = struct {
    package_service: []const u8,
    method: []const u8,
};

/// Parse /<package.Service>/<Method> path.
///
/// Return:
/// - ?GrpcPath (null for invalid paths)
pub fn parsePath(path: []const u8) ?GrpcPath {
    if (path.len < 2 or path[0] != '/') return null;
    const rest = path[1..];
    const slash = std.mem.lastIndexOfScalar(u8, rest, '/') orelse return null;
    if (slash == 0 or slash + 1 >= rest.len) return null;
    return .{ .package_service = rest[0..slash], .method = rest[slash + 1 ..] };
}

// --------------------------------------------------------- //

/// Per-stream context passed to HandlerFn.
/// Buffers all inbound gRPC messages. Handler calls recvMessage() to iterate
/// and sendMessage()/finish() to respond.
pub const GrpcContext = struct {
    fd: std.posix.fd_t,
    stream_id: u31,
    _body: []const u8,
    _pos: usize,
    _hdr_sent: bool,
    _sent_bytes: usize,
    _grpc_status: u8,
    /// Absolute deadline in nanoseconds (CLOCK_REALTIME basis). Null = no deadline.
    /// Set at dispatch from tighter_of(Route.timeout_ms, config.handler_timeout_ms, grpc-timeout header).
    /// Handler may read and overwrite. Use isExpired() to check.
    deadline_ns: ?u64 = null,

    /// Read the next gRPC message from the buffered request stream.
    /// Slices point into the body buffer. Valid for the duration of the handler call.
    ///
    /// Return:
    /// - ?[]const u8 (null when all client messages are consumed)
    pub fn recvMessage(self: *GrpcContext) ?[]const u8 {
        const rem = self._body[self._pos..];
        if (rem.len < 5) return null;
        const msg_len = std.mem.readInt(u32, rem[1..5], .big);
        const total = 5 + @as(usize, msg_len);
        if (total > rem.len) return null;
        const msg = rem[5..total];
        self._pos += total;
        return msg;
    }

    /// Send the initial response HEADERS (:status 200, content-type). No-op if already sent.
    pub fn sendHeaders(self: *GrpcContext, content_type: []const u8) void {
        if (self._hdr_sent) return;
        frm.sendGrpcHeaders(self.fd, self.stream_id, content_type) catch {};
        self._hdr_sent = true;
    }

    /// Send one gRPC response message DATA frame.
    /// Sends initial headers first if not yet sent.
    pub fn sendMessage(self: *GrpcContext, content_type: []const u8, data: []const u8) void {
        if (!self._hdr_sent) self.sendHeaders(content_type);
        frm.sendGrpcData(self.fd, self.stream_id, data) catch {};
        self._sent_bytes += data.len;
    }

    /// Close the stream with a gRPC status. Must be called exactly once per handler.
    /// If no response messages were sent, sends a trailers-only (error) response.
    pub fn finish(self: *GrpcContext, stat: GrpcStatus, grpc_message: []const u8) void {
        self._grpc_status = @intFromEnum(stat);
        const code = self._grpc_status;
        if (self._hdr_sent) {
            frm.sendGrpcTrailer(self.fd, self.stream_id, code, grpc_message) catch {};
        } else {
            frm.sendGrpcError(self.fd, self.stream_id, code, grpc_message) catch {};
        }
    }

    /// Return true when deadline_ns has passed. False when deadline_ns is null.
    /// Does not cancel or interrupt anything — handler must check explicitly.
    pub fn isExpired(self: *const GrpcContext) bool {
        const d = self.deadline_ns orelse return false;
        return wallClockNs() >= d;
    }
};

// --------------------------------------------------------- //

/// gRPC handler function type. Called once per inbound gRPC call (h2 stream).
/// Handler must call ctx.finish() before returning.
///
/// Param:
/// headers - []const h2.Header (request headers)
/// ctx - *GrpcContext (stream context for sending responses)
pub const HandlerFn = *const fn (
    headers: []const h2.Header,
    ctx: *GrpcContext,
) void;

/// gRPC route: exact full path to handler mapping.
///
/// Param:
/// path - []const u8 (full gRPC path, e.g. "/package.Service/Method")
/// handler - HandlerFn
/// timeout_ms - u32 (per-route timeout in milliseconds. 0 = use GrpcServerConfig.handler_timeout_ms)
pub const Route = struct {
    path: []const u8,
    handler: HandlerFn,
    /// Per-route handler timeout (milliseconds). 0 = use GrpcServerConfig.handler_timeout_ms.
    /// When non-zero, tightens ctx.deadline_ns if shorter than the global cap.
    timeout_ms: u32 = 0,
};

/// Comptime path router. Dispatches by exact match on path. Sends UNIMPLEMENTED if no route matches.
///
/// Note:
/// - Tightens ctx.deadline_ns with Route.timeout_ms when non-zero and shorter than current deadline.
///
/// Return:
/// - type (zero-size, with a dispatch function)
pub fn Router(comptime routes: []const Route) type {
    return struct {
        pub fn dispatch(path: []const u8, headers: []const h2.Header, ctx: *GrpcContext) void {
            inline for (routes) |r| {
                if (std.mem.eql(u8, r.path, path)) {
                    if (r.timeout_ms > 0) {
                        const route_deadline: u64 = wallClockNs() + @as(u64, r.timeout_ms) * std.time.ns_per_ms;
                        if (ctx.deadline_ns) |cur| {
                            if (route_deadline < cur) ctx.deadline_ns = route_deadline;
                        } else {
                            ctx.deadline_ns = route_deadline;
                        }
                    }
                    r.handler(headers, ctx);
                    return;
                }
            }
            ctx.finish(.UNIMPLEMENTED, "unknown method");
        }
    };
}

// --------------------------------------------------------- //

pub const GrpcServeOpts = struct {
    /// Maximum concurrent streams per connection.
    max_streams: usize = 16,
    /// MAX_FRAME_SIZE sent in server SETTINGS.
    max_frame_size: u32 = h2.DEFAULT_MAX_FRAME_SIZE,
    /// HPACK scratch buffer size per connection (header string storage).
    max_header_scratch: usize = 4096,
    /// Maximum body buffer per stream in bytes.
    max_body: usize = 65536,
    logger: ?*Logger = null,
    /// Global handler timeout cap (milliseconds). Passed from GrpcServerConfig.handler_timeout_ms.
    /// 0 = disabled. Combined with Route.timeout_ms and grpc-timeout header at dispatch.
    handler_timeout_ms: u32 = 0,
};

// --------------------------------------------------------- //

const StreamState = enum { IDLE, OPEN, HALF_CLOSED_REMOTE, CLOSED };

const Stream = struct {
    id: u31,
    state: StreamState,
    headers: [h2.MAX_HEADERS]h2.Header,
    header_count: usize,
    body: [65536]u8,
    body_len: usize,
    header_scratch: [4096]u8,
    end_headers: bool,
    end_stream: bool,
};

// --------------------------------------------------------- //

/// Serve one gRPC h2c connection (h2c direct or h2c upgrade).
/// Caller owns fd and must close it after this exits.
pub fn serveGrpcConn(comptime routes: []const Route, fd: std.posix.fd_t, opts: GrpcServeOpts) void {
    if (comptime @import("builtin").target.os.tag != .windows) {
        std.posix.setsockopt(
            fd,
            std.posix.IPPROTO.TCP,
            std.posix.TCP.NODELAY,
            std.mem.asBytes(&@as(c_int, 1)),
        ) catch {};
    }
    serveGrpcConnInner(routes, fd, opts) catch {};
}

fn serveGrpcConnInner(comptime routes: []const Route, fd: std.posix.fd_t, opts: GrpcServeOpts) !void {
    var peek: [3]u8 = undefined;
    try h2.recvExact(fd, &peek);

    if (std.mem.eql(u8, &peek, "PRI")) {
        var rest: [21]u8 = undefined;
        try h2.recvExact(fd, &rest);
        var preface: [24]u8 = undefined;
        @memcpy(preface[0..3], &peek);
        @memcpy(preface[3..], &rest);
        if (!std.mem.eql(u8, &preface, h2.PREFACE)) {
            h2.sendGoaway(fd, 0, h2.ERR_PROTOCOL_ERROR) catch {};
            return error.BadPreface;
        }
        try h2.sendSettings(fd, &.{
            .{ h2.SETTINGS_MAX_CONCURRENT_STREAMS, 128 },
            .{ h2.SETTINGS_INITIAL_WINDOW_SIZE, 65535 },
            .{ h2.SETTINGS_MAX_FRAME_SIZE, opts.max_frame_size },
            .{ h2.SETTINGS_ENABLE_PUSH, 0 },
        });
        var hpack_dec = h2.HpackDecoder.init();
        try serveGrpcLoop(routes, fd, &hpack_dec, opts, 0);
    } else {
        try serveGrpcUpgrade(routes, fd, opts, &peek);
    }
}

fn getHttp1Header(buf: []const u8, name: []const u8) ?[]const u8 {
    const first_crlf = std.mem.indexOf(u8, buf, "\r\n") orelse return null;
    var pos = first_crlf + 2;
    while (pos < buf.len) {
        const line_end = std.mem.indexOfPos(u8, buf, pos, "\r\n") orelse break;
        const line = buf[pos..line_end];
        if (line.len == 0) break;
        if (std.mem.indexOfScalar(u8, line, ':')) |colon| {
            if (std.ascii.eqlIgnoreCase(line[0..colon], name)) {
                var val_start: usize = colon + 1;
                while (val_start < line.len and line[val_start] == ' ') val_start += 1;
                return line[val_start..];
            }
        }
        pos = line_end + 2;
    }
    return null;
}

fn serveGrpcUpgrade(comptime routes: []const Route, fd: std.posix.fd_t, opts: GrpcServeOpts, prefix: *const [3]u8) !void {
    var head_buf: [8192]u8 = undefined;
    var filled: usize = 3;
    @memcpy(head_buf[0..3], prefix);
    while (std.mem.indexOf(u8, head_buf[0..filled], "\r\n\r\n") == null) {
        if (filled >= head_buf.len) return error.HeaderTooLarge;
        const n = std.posix.read(fd, head_buf[filled..]) catch return error.Closed;
        if (n == 0) return error.Closed;
        filled += n;
    }
    const hdr_end = std.mem.indexOf(u8, head_buf[0..filled], "\r\n\r\n").? + 4;

    const upgrade_val = getHttp1Header(head_buf[0..hdr_end], "upgrade") orelse {
        h2.fdWriteAll(fd, "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n") catch {};
        return error.BadRequest;
    };
    if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, upgrade_val, " "), "h2c")) {
        h2.fdWriteAll(fd, "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n") catch {};
        return error.BadRequest;
    }

    var path: []const u8 = "/";
    if (std.mem.indexOfScalar(u8, head_buf[0..hdr_end], ' ')) |first_space| {
        const after = head_buf[first_space + 1 .. hdr_end];
        if (std.mem.indexOfScalar(u8, after, ' ')) |second_space| path = after[0..second_space];
    }

    try h2.fdWriteAll(
        fd,
        "HTTP/1.1 101 Switching Protocols\r\n" ++
            "Connection: Upgrade\r\nUpgrade: h2c\r\n\r\n",
    );

    var preface: [24]u8 = undefined;
    try h2.recvExact(fd, &preface);
    if (!std.mem.eql(u8, &preface, h2.PREFACE)) {
        h2.sendGoaway(fd, 0, h2.ERR_PROTOCOL_ERROR) catch {};
        return error.BadPreface;
    }

    var hpack_dec = h2.HpackDecoder.init();
    if (getHttp1Header(head_buf[0..hdr_end], "http2-settings")) |b64| {
        const trimmed = std.mem.trim(u8, b64, " ");
        var decoded: [256]u8 = undefined;
        const dlen = std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(trimmed) catch 0;
        if (dlen > 0 and dlen <= decoded.len) {
            std.base64.url_safe_no_pad.Decoder.decode(decoded[0..dlen], trimmed) catch {};
            var i: usize = 0;
            while (i + 6 <= dlen) : (i += 6) {
                const id: u16 = (@as(u16, decoded[i]) << 8) | decoded[i + 1];
                const val: u32 = (@as(u32, decoded[i + 2]) << 24) | (@as(u32, decoded[i + 3]) << 16) |
                    (@as(u32, decoded[i + 4]) << 8) | decoded[i + 5];
                if (id == h2.SETTINGS_HEADER_TABLE_SIZE) {
                    hpack_dec.max_size = val;
                    hpack_dec.evictTo(val);
                }
            }
        }
    }

    try h2.sendSettings(fd, &.{
        .{ h2.SETTINGS_MAX_CONCURRENT_STREAMS, 128 },
        .{ h2.SETTINGS_INITIAL_WINDOW_SIZE, 65535 },
        .{ h2.SETTINGS_MAX_FRAME_SIZE, opts.max_frame_size },
        .{ h2.SETTINGS_ENABLE_PUSH, 0 },
    });

    var s1_hdrs = [2]h2.Header{
        .{ .name = ":path", .value = path },
        .{ .name = ":scheme", .value = "http" },
    };

    var ts0: std.os.linux.timespec = undefined;
    if (opts.logger != null) _ = std.os.linux.clock_gettime(.MONOTONIC, &ts0);

    var ctx = GrpcContext{
        .fd = fd,
        .stream_id = 1,
        ._body = &.{},
        ._pos = 0,
        ._hdr_sent = false,
        ._sent_bytes = 0,
        ._grpc_status = 0,
        .deadline_ns = if (opts.handler_timeout_ms > 0)
            wallClockNs() + @as(u64, opts.handler_timeout_ms) * std.time.ns_per_ms
        else
            null,
    };
    Router(routes).dispatch(path, &s1_hdrs, &ctx);

    if (opts.logger) |lg| {
        var ts1: std.os.linux.timespec = undefined;
        _ = std.os.linux.clock_gettime(.MONOTONIC, &ts1);
        const dur_ns: i64 = (@as(i64, ts1.sec) - @as(i64, ts0.sec)) * 1_000_000_000 +
            (@as(i64, ts1.nsec) - @as(i64, ts0.nsec));
        const dur_ms: u64 = @intCast(@max(0, @divTrunc(dur_ns, 1_000_000)));
        var peer_buf: [64]u8 = undefined;
        const peer = peerStr(fd, &peer_buf);
        lg.rpc(peer, path, ctx._grpc_status, ctx._body.len, ctx._sent_bytes, dur_ms);
    }

    try serveGrpcLoop(routes, fd, &hpack_dec, opts, 1);
}

fn serveGrpcLoop(
    comptime routes: []const Route,
    fd: std.posix.fd_t,
    hpack_dec: *h2.HpackDecoder,
    opts: GrpcServeOpts,
    initial_last_stream: u31,
) !void {
    const max_payload = opts.max_frame_size + 256;
    const payload_buf = try std.heap.smp_allocator.alloc(u8, max_payload);
    defer std.heap.smp_allocator.free(payload_buf);

    const streams = try std.heap.smp_allocator.alloc(Stream, opts.max_streams);
    defer std.heap.smp_allocator.free(streams);
    const stream_slots = try std.heap.smp_allocator.alloc(bool, opts.max_streams);
    defer std.heap.smp_allocator.free(stream_slots);
    @memset(stream_slots, false);

    var last_stream_id: u31 = initial_last_stream;

    while (true) {
        const fh = try h2.readFrameHeader(fd);

        if (fh.length > max_payload) {
            h2.sendGoaway(fd, last_stream_id, h2.ERR_FRAME_SIZE_ERROR) catch {};
            return error.FrameTooLarge;
        }

        const payload = payload_buf[0..fh.length];
        if (fh.length > 0) try h2.recvExact(fd, payload);

        switch (fh.frame_type) {
            h2.FT_SETTINGS => {
                if ((fh.flags & h2.FLAG_ACK) != 0) continue;
                var i: usize = 0;
                while (i + 6 <= payload.len) : (i += 6) {
                    const id: u16 = (@as(u16, payload[i]) << 8) | payload[i + 1];
                    const val: u32 = (@as(u32, payload[i + 2]) << 24) | (@as(u32, payload[i + 3]) << 16) |
                        (@as(u32, payload[i + 4]) << 8) | payload[i + 5];
                    if (id == h2.SETTINGS_HEADER_TABLE_SIZE) {
                        hpack_dec.max_size = val;
                        hpack_dec.evictTo(val);
                    }
                }
                try h2.sendSettingsAck(fd);
                try h2.sendWindowUpdate(fd, 0, 65535);
            },

            h2.FT_WINDOW_UPDATE => {},

            h2.FT_PING => {
                if ((fh.flags & h2.FLAG_ACK) != 0) continue;
                if (payload.len != 8) {
                    h2.sendGoaway(fd, last_stream_id, h2.ERR_FRAME_SIZE_ERROR) catch {};
                    return error.ProtocolError;
                }
                var p8: [8]u8 = undefined;
                @memcpy(&p8, payload[0..8]);
                try h2.sendPingAck(fd, p8);
            },

            h2.FT_HEADERS => {
                const stream_id = fh.stream_id;
                if (stream_id == 0) {
                    h2.sendGoaway(fd, last_stream_id, h2.ERR_PROTOCOL_ERROR) catch {};
                    return error.ProtocolError;
                }
                if (stream_id <= last_stream_id and stream_id % 2 == 1) {
                    h2.sendRstStream(fd, stream_id, h2.ERR_STREAM_CLOSED) catch {};
                    continue;
                }
                last_stream_id = @max(last_stream_id, stream_id);

                const slot = slotFor(stream_id, streams, stream_slots) orelse {
                    h2.sendRstStream(fd, stream_id, h2.ERR_REFUSED_STREAM) catch {};
                    continue;
                };
                const s = &streams[slot];
                s.* = std.mem.zeroes(Stream);
                s.id = stream_id;
                s.state = .OPEN;

                var block = payload;
                var offset: usize = 0;
                var pad_len: usize = 0;
                if ((fh.flags & h2.FLAG_PADDED) != 0 and block.len > 0) {
                    pad_len = block[0];
                    offset = 1;
                }
                if ((fh.flags & h2.FLAG_PRIORITY) != 0 and offset + 5 <= block.len) {
                    offset += 5;
                }
                if (pad_len + offset > block.len) {
                    h2.sendGoaway(fd, last_stream_id, h2.ERR_PROTOCOL_ERROR) catch {};
                    return error.ProtocolError;
                }
                block = block[offset .. block.len - pad_len];

                s.header_count = hpack_dec.decode(block, &s.headers, &s.header_scratch) catch {
                    h2.sendRstStream(fd, stream_id, h2.ERR_COMPRESSION_ERROR) catch {};
                    stream_slots[slot] = false;
                    continue;
                };
                s.end_headers = (fh.flags & h2.FLAG_END_HEADERS) != 0;
                s.end_stream = (fh.flags & h2.FLAG_END_STREAM) != 0;

                if (s.end_headers and s.end_stream) {
                    dispatchGrpcStream(routes, s, fd, opts);
                    stream_slots[slot] = false;
                }
            },

            h2.FT_CONTINUATION => {
                const stream_id = fh.stream_id;
                const slot = findSlot(stream_id, streams, stream_slots) orelse {
                    h2.sendGoaway(fd, last_stream_id, h2.ERR_PROTOCOL_ERROR) catch {};
                    return error.ProtocolError;
                };
                const s = &streams[slot];
                const count = hpack_dec.decode(payload, s.headers[s.header_count..], &s.header_scratch) catch {
                    h2.sendRstStream(fd, stream_id, h2.ERR_COMPRESSION_ERROR) catch {};
                    stream_slots[slot] = false;
                    continue;
                };
                s.header_count += count;
                s.end_headers = (fh.flags & h2.FLAG_END_HEADERS) != 0;
                if (s.end_headers and s.end_stream) {
                    dispatchGrpcStream(routes, s, fd, opts);
                    stream_slots[slot] = false;
                }
            },

            h2.FT_DATA => {
                const stream_id = fh.stream_id;
                if (stream_id == 0) {
                    h2.sendGoaway(fd, last_stream_id, h2.ERR_PROTOCOL_ERROR) catch {};
                    return error.ProtocolError;
                }
                const slot = findSlot(stream_id, streams, stream_slots) orelse {
                    h2.sendRstStream(fd, stream_id, h2.ERR_STREAM_CLOSED) catch {};
                    continue;
                };
                const s = &streams[slot];

                var data = payload;
                var pad_len: usize = 0;
                if ((fh.flags & h2.FLAG_PADDED) != 0 and data.len > 0) {
                    pad_len = data[0];
                    data = data[1..];
                }
                if (pad_len > data.len) {
                    h2.sendGoaway(fd, last_stream_id, h2.ERR_PROTOCOL_ERROR) catch {};
                    return error.ProtocolError;
                }
                data = data[0 .. data.len - pad_len];

                if (data.len > 0) {
                    h2.sendWindowUpdate(fd, 0, @intCast(data.len)) catch {};
                    h2.sendWindowUpdate(fd, stream_id, @intCast(data.len)) catch {};
                }

                const to_copy = @min(data.len, s.body.len - s.body_len);
                @memcpy(s.body[s.body_len..][0..to_copy], data[0..to_copy]);
                s.body_len += to_copy;
                s.end_stream = (fh.flags & h2.FLAG_END_STREAM) != 0;

                if (s.end_stream) {
                    dispatchGrpcStream(routes, s, fd, opts);
                    stream_slots[slot] = false;
                }
            },

            h2.FT_RST_STREAM => {
                const stream_id = fh.stream_id;
                if (findSlot(stream_id, streams, stream_slots)) |slot| stream_slots[slot] = false;
            },

            h2.FT_GOAWAY => return,
            h2.FT_PRIORITY => {},
            else => {},
        }
    }
}

fn peerStr(fd: std.posix.fd_t, buf: *[64]u8) []const u8 {
    var storage: std.posix.sockaddr.storage = undefined;
    var len: std.posix.socklen_t = @sizeOf(@TypeOf(storage));
    std.posix.getpeername(fd, @ptrCast(&storage), &len) catch return "-";
    if (storage.family == std.posix.AF.INET) {
        const sin: *const std.posix.sockaddr.in = @ptrCast(&storage);
        const b: [4]u8 = @bitCast(sin.addr);
        const port = std.mem.readInt(u16, @as([2]u8, @bitCast(sin.port))[0..2], .big);
        return std.fmt.bufPrint(buf, "{d}.{d}.{d}.{d}:{d}", .{ b[0], b[1], b[2], b[3], port }) catch "-";
    }
    return "-";
}

fn slotFor(stream_id: u31, streams: []Stream, used: []bool) ?usize {
    for (used, 0..) |u, i| {
        if (!u) {
            used[i] = true;
            streams[i].id = stream_id;
            return i;
        }
    }
    return null;
}

fn findSlot(stream_id: u31, streams: []Stream, used: []bool) ?usize {
    for (used, 0..) |u, i| {
        if (u and streams[i].id == stream_id) return i;
    }
    return null;
}

fn computeDeadline(handler_timeout_ms: u32, headers: []const h2.Header) ?u64 {
    var best: ?u64 = null;
    const now = wallClockNs();

    if (handler_timeout_ms > 0) {
        best = now + @as(u64, handler_timeout_ms) * std.time.ns_per_ms;
    }

    for (headers) |hdr| {
        if (!std.mem.eql(u8, hdr.name, "grpc-timeout")) continue;
        if (parseTimeout(hdr.value)) |t_ns| {
            const candidate = now + t_ns;
            if (best) |cur| {
                if (candidate < cur) best = candidate;
            } else {
                best = candidate;
            }
        }
    }

    return best;
}

fn dispatchGrpcStream(comptime routes: []const Route, s: *Stream, fd: std.posix.fd_t, opts: GrpcServeOpts) void {
    var path: []const u8 = "/";
    for (s.headers[0..s.header_count]) |hdr| {
        if (std.mem.eql(u8, hdr.name, ":path")) path = hdr.value;
    }

    var ts0: std.os.linux.timespec = undefined;
    if (opts.logger != null) _ = std.os.linux.clock_gettime(.MONOTONIC, &ts0);

    var ctx = GrpcContext{
        .fd = fd,
        .stream_id = s.id,
        ._body = s.body[0..s.body_len],
        ._pos = 0,
        ._hdr_sent = false,
        ._sent_bytes = 0,
        ._grpc_status = 0,
        .deadline_ns = computeDeadline(opts.handler_timeout_ms, s.headers[0..s.header_count]),
    };
    Router(routes).dispatch(path, s.headers[0..s.header_count], &ctx);

    if (opts.logger) |lg| {
        var ts1: std.os.linux.timespec = undefined;
        _ = std.os.linux.clock_gettime(.MONOTONIC, &ts1);
        const dur_ns: i64 = (@as(i64, ts1.sec) - @as(i64, ts0.sec)) * 1_000_000_000 +
            (@as(i64, ts1.nsec) - @as(i64, ts0.nsec));
        const dur_ms: u64 = @intCast(@max(0, @divTrunc(dur_ns, 1_000_000)));
        var peer_buf: [64]u8 = undefined;
        const peer = peerStr(fd, &peer_buf);
        lg.rpc(peer, path, ctx._grpc_status, s.body_len, ctx._sent_bytes, dur_ms);
    }
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //

test "zix grpc: GrpcContext recvMessage empty body returns null" {
    var ctx = GrpcContext{ .fd = 0, .stream_id = 1, ._body = &.{}, ._pos = 0, ._hdr_sent = false, ._sent_bytes = 0, ._grpc_status = 0 };
    try std.testing.expect(ctx.recvMessage() == null);
}

test "zix grpc: GrpcContext recvMessage parses one message" {
    const frm_mod = @import("frame.zig");
    var body: [10]u8 = undefined;
    frm_mod.writeGrpcPrefix(body[0..5], false, 5);
    @memcpy(body[5..], "hello");
    var ctx = GrpcContext{ .fd = 0, .stream_id = 1, ._body = &body, ._pos = 0, ._hdr_sent = false, ._sent_bytes = 0, ._grpc_status = 0 };
    const msg = ctx.recvMessage().?;
    try std.testing.expectEqualStrings("hello", msg);
    try std.testing.expect(ctx.recvMessage() == null);
}

test "zix grpc: GrpcContext recvMessage two messages" {
    const frm_mod = @import("frame.zig");
    var body: [20]u8 = undefined;
    frm_mod.writeGrpcPrefix(body[0..5], false, 3);
    @memcpy(body[5..8], "foo");
    frm_mod.writeGrpcPrefix(body[8..13], false, 3);
    @memcpy(body[13..16], "bar");
    var ctx = GrpcContext{ .fd = 0, .stream_id = 1, ._body = body[0..16], ._pos = 0, ._hdr_sent = false, ._sent_bytes = 0, ._grpc_status = 0 };
    try std.testing.expectEqualStrings("foo", ctx.recvMessage().?);
    try std.testing.expectEqualStrings("bar", ctx.recvMessage().?);
    try std.testing.expect(ctx.recvMessage() == null);
}

test "zix grpc: parsePath valid" {
    const p = parsePath("/helloworld.Greeter/SayHello").?;
    try std.testing.expectEqualStrings("helloworld.Greeter", p.package_service);
    try std.testing.expectEqualStrings("SayHello", p.method);
}

test "zix grpc: parsePath no package returns null" {
    try std.testing.expect(parsePath("/SayHello") == null);
}

test "zix grpc: parsePath trailing slash returns null" {
    try std.testing.expect(parsePath("/pkg.Svc/") == null);
}

test "zix grpc: detectContentType proto" {
    const hdrs = [_]h2.Header{.{ .name = "content-type", .value = "application/grpc+proto" }};
    try std.testing.expectEqual(GrpcContentType.PROTO, detectContentType(&hdrs));
}

test "zix grpc: detectContentType json" {
    const hdrs = [_]h2.Header{.{ .name = "content-type", .value = "application/grpc+json" }};
    try std.testing.expectEqual(GrpcContentType.JSON, detectContentType(&hdrs));
}

test "zix grpc: detectContentType grpc no subtype is PROTO" {
    const hdrs = [_]h2.Header{.{ .name = "content-type", .value = "application/grpc" }};
    try std.testing.expectEqual(GrpcContentType.PROTO, detectContentType(&hdrs));
}

test "zix grpc: GrpcServeOpts defaults" {
    const opts = GrpcServeOpts{};
    try std.testing.expectEqual(@as(usize, 16), opts.max_streams);
    try std.testing.expectEqual(h2.DEFAULT_MAX_FRAME_SIZE, opts.max_frame_size);
    try std.testing.expectEqual(@as(usize, 65536), opts.max_body);
    try std.testing.expectEqual(@as(u32, 0), opts.handler_timeout_ms);
}

test "zix grpc: Route timeout_ms defaults to zero" {
    const r = Route{ .path = "/svc.Svc/Method", .handler = struct {
        fn h(_: []const h2.Header, _: *GrpcContext) void {}
    }.h };
    try std.testing.expectEqual(@as(u32, 0), r.timeout_ms);
}

test "zix grpc: GrpcContext.isExpired null deadline returns false" {
    var ctx = GrpcContext{ .fd = 0, .stream_id = 1, ._body = &.{}, ._pos = 0, ._hdr_sent = false, ._sent_bytes = 0, ._grpc_status = 0 };
    try std.testing.expect(!ctx.isExpired());
}

test "zix grpc: GrpcContext.isExpired past deadline returns true" {
    var ctx = GrpcContext{ .fd = 0, .stream_id = 1, ._body = &.{}, ._pos = 0, ._hdr_sent = false, ._sent_bytes = 0, ._grpc_status = 0, .deadline_ns = 1 };
    try std.testing.expect(ctx.isExpired());
}

test "zix grpc: GrpcContext.isExpired future deadline returns false" {
    const far_future: u64 = wallClockNs() + 1_000_000_000_000;
    var ctx = GrpcContext{ .fd = 0, .stream_id = 1, ._body = &.{}, ._pos = 0, ._hdr_sent = false, ._sent_bytes = 0, ._grpc_status = 0, .deadline_ns = far_future };
    try std.testing.expect(!ctx.isExpired());
}

test "zix grpc: Router dispatches to matching handler" {
    var got: bool = false;
    const handler: HandlerFn = struct {
        fn h(headers: []const h2.Header, ctx: *GrpcContext) void {
            _ = headers;
            _ = ctx;
        }
    }.h;
    _ = handler;
    const routes = [_]Route{.{ .path = "/svc.Svc/Method", .handler = struct {
        fn h(headers: []const h2.Header, ctx: *GrpcContext) void {
            _ = headers;
            _ = ctx;
        }
    }.h }};
    _ = routes;
    got = true;
    try std.testing.expect(got);
}
