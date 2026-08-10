//! HTTP/2 connection loop: h2c direct (PRI preface) and h2c upgrade (HTTP/1.1 Upgrade: h2c).

const std = @import("std");
const socket_pair = @import("../../utils/socket_pair.zig");
const win_io = @import("../../utils/windows_io.zig");
const frame = @import("frame.zig");
const hpack = @import("hpack.zig");
const rc = @import("../../utils/response_cache.zig");
const router_mod = @import("router.zig");
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;
const Context = @import("context.zig").Context;
const wallClockNs = @import("context.zig").wallClockNs;
const CTX_ARENA_BYTES = @import("context.zig").CTX_ARENA_BYTES;

/// Base64 decode scratch for the HTTP2-Settings header on an h2c upgrade.
const SETTINGS_DECODE_SCRATCH: usize = 256;

/// Request line and header read bound for an h2c upgrade (HeaderTooLarge over this).
const UPGRADE_HEAD_BUF: usize = 8192;

// --------------------------------------------------------- //
// Per-worker response cache (ADR-036), opt-in via config.response_cache. Mirrors the zix.Grpc and
// zix.Http1 response caches: the worker installs a cache, muxDispatch records the request key, and a
// handler serves or stores an unframed response body that is re-framed per stream-id on a hit.

/// Per-worker response cache installed by the EPOLL / URING mux worker. Null on workers without a
/// cache, so the serveCached / sendCachedFD API degrades to a plain send.
pub threadlocal var tl_cache: ?*rc.ResponseCache = null;

/// Default freshness in milliseconds for a stored response, set alongside tl_cache.
pub threadlocal var tl_cache_ttl_ms: u32 = 1000;

/// Path and body of the request currently dispatching on this worker, set by muxDispatch around each
/// handler call so the free-function cache API can compute the request key. The handler does not
/// receive the path, so it is threaded here rather than through HandlerFn.
pub threadlocal var tl_req_path: []const u8 = "";
pub threadlocal var tl_req_body: []const u8 = "";

/// Install the per-worker response cache and its default TTL.
pub fn setCache(cache: ?*rc.ResponseCache, default_ttl_ms: u32) void {
    tl_cache = cache;
    tl_cache_ttl_ms = default_ttl_ms;
}

/// Worker default cache TTL in milliseconds, exposed to handlers.
pub fn cacheTtl() u32 {
    return tl_cache_ttl_ms;
}

/// Hash a request into a cache key from its path and body. A zero digest is bumped to 1 so 0 stays
/// reserved for an empty cache slot.
fn requestKey(path: []const u8, body: []const u8) u64 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(path);
    hasher.update(body);

    const digest = hasher.final();
    return if (digest == 0) 1 else digest;
}

/// Serve the current request from the per-worker cache when present. On a hit the cached (unframed)
/// body is re-framed for this stream and sent, and the handler should return.
///
/// Usage:
/// ```zig
/// fn handler(req: *zix.Http2.Request, res: *zix.Http2.Response, ctx: *zix.Http2.Context) anyerror!void {
///     _ = res;
///     if (zix.Http2.serveCached(ctx.fd, ctx.sid, "application/json")) return;
///     const reply = buildExpensive();
///     zix.Http2.sendCachedFD(ctx.fd, ctx.sid, "application/json", reply);
/// }
/// ```
///
/// Return:
/// - bool (true when served from cache, the handler should return)
pub fn serveCached(fd: std.posix.fd_t, sid: u31, content_type: []const u8) bool {
    const cache = tl_cache orelse return false;
    if (tl_req_path.len == 0) return false;

    const bytes = cache.lookup(requestKey(tl_req_path, tl_req_body), rc.nowMillis()) orelse return false;

    frame.sendResponseFD(fd, sid, 200, content_type, bytes) catch {};

    return true;
}

/// Send a response body and store it under the current request key for later serveCached hits.
/// Storing is skipped when no cache is installed or the path is empty. The body is sent regardless.
pub fn sendCachedFD(fd: std.posix.fd_t, sid: u31, content_type: []const u8, data: []const u8) void {
    frame.sendResponseFD(fd, sid, 200, content_type, data) catch {};

    const cache = tl_cache orelse return;
    if (tl_req_path.len == 0) return;

    _ = cache.store(requestKey(tl_req_path, tl_req_body), data, tl_cache_ttl_ms, rc.nowMillis());
}

// --------------------------------------------------------- //

/// HTTP/2 handler function type. Called once per completed h2 stream via invokeHandler,
/// which builds the trio (Request, Response, Context). Route matching happens in the router the
/// caller builds (Router(routes).dispatch is itself a HandlerFn), not in the engine.
pub const HandlerFn = router_mod.HandlerFn;
pub const RouteKind = router_mod.RouteKind;
pub const Route = router_mod.Route;
pub const Router = router_mod.Router;

/// Build the trio and invoke the handler, mirroring Http1's core.invokeHandler (ADR-062). A handler
/// error is completed as one auto-500, but only when the handler wrote nothing, so a partially sent
/// response is not corrupted.
///
/// Param:
/// handler - HandlerFn (built via Router(&[_]Route{...}).dispatch)
/// req - Request (already built by the caller: method, path, query, headers, body)
/// fd - std.posix.fd_t (connection fd for sending responses)
/// sid - u31 (HTTP/2 stream id)
/// io - std.Io (carried on Context for symmetry with the other engines)
/// deadline_ns - ?u64 (seeded from opts.handler_timeout_ms by the caller)
/// opts - ServeOpts (read for public_dir)
/// peer_max_frame_size - u32 (the peer's advertised SETTINGS_MAX_FRAME_SIZE, NOT opts.max_frame_size,
///   which is this server's own receive-side limit and says nothing about what the peer accepts)
pub inline fn invokeHandler(handler: HandlerFn, req: *Request, fd: std.posix.fd_t, sid: u31, io: std.Io, deadline_ns: ?u64, opts: ServeOpts, peer_max_frame_size: u32) void {
    var res = Response{ .fd = fd, .sid = sid };
    var arena_buf: [CTX_ARENA_BYTES]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&arena_buf);
    var ctx = Context{ .fd = fd, .sid = sid, .deadline_ns = deadline_ns, .io = io, .allocator = fba.allocator(), .public_dir = opts.public_dir, .max_frame_size = peer_max_frame_size };

    handler(req, &res, &ctx) catch {
        if (!res.sent) frame.sendResponseFD(fd, sid, 500, "text/plain", "Internal Server Error") catch {};
    };
}

pub const ServeOpts = struct {
    /// Maximum concurrent streams per connection (advertised SETTINGS_MAX_CONCURRENT_STREAMS). Each
    /// stream's slot is borrowed from a per-worker pool, so this is not reserved per connection.
    max_streams: usize = 128,
    /// MAX_FRAME_SIZE sent in server SETTINGS.
    max_frame_size: u32 = frame.DEFAULT_MAX_FRAME_SIZE,
    /// HPACK scratch buffer size per connection (header string storage).
    max_header_scratch: usize = 4096,
    /// Maximum request body buffered per stream in bytes. A larger request body is truncated to this.
    max_body: usize = 16384,
    /// Per-connection read buffer floor in bytes. The reader is sized to the larger of this and
    /// one max frame, so a larger floor cuts read() and compaction for big frames.
    conn_read_buf_min: usize = 32 * 1024,
    /// Initial capacity in bytes of the per-connection TLS pending-write buffer (it grows on demand).
    /// A larger initial avoids early reallocation under big responses on the TLS path.
    tls_write_buf_initial: usize = 16 * 1024,
    /// Enable the per-worker response cache (ADR-036). When off, serveCached / sendCachedFD degrade to
    /// a plain send. Active under every dispatch model (shared-nothing: one owner per multiplexed
    /// worker, one per io pool thread under .ASYNC).
    response_cache: bool = false,
    /// Response cache slot count, rounded down to a power of two by ResponseCache.init.
    cache_max_entries: u32 = 256,
    /// Per-slot response cap in bytes. A response larger than this bypasses the cache.
    cache_max_value_bytes: u32 = 16 * 1024,
    /// Default freshness in milliseconds, exposed to handlers via cacheTtl().
    cache_ttl_ms: u32 = 1000,
    /// Optional ceiling on per-worker cache memory in bytes. 0 disables the ceiling. When set, the
    /// effective entry count is reduced so entries * value_bytes fits (see effectiveCacheEntries).
    cache_max_total_bytes: usize = 0,
    /// Server-wide default handler processing timeout in milliseconds. 0 = disabled.
    /// Seeds Context.deadline_ns at dispatch. The handler may extend or override via setTimeout/withTimeout.
    handler_timeout_ms: u32 = 0,
    /// Root directory for static file serving, carried onto Context so the router can reach it
    /// without a threadlocal. Empty disables static serving.
    public_dir: []const u8 = "",
};

// --------------------------------------------------------- //

const StreamState = enum { IDLE, OPEN, HALF_CLOSED_REMOTE, CLOSED };

/// Per-stream request body buffer size (bytes a single stream can accumulate).
const STREAM_BODY_BUF_SIZE: usize = 64 * 1024;
/// Per-stream scratch buffer for building the HPACK-decoded header block.
const STREAM_HEADER_SCRATCH_SIZE: usize = 4096;

const Stream = struct {
    id: u31,
    state: StreamState,
    headers: [frame.MAX_HEADERS]hpack.Header,
    header_count: usize,
    body: [STREAM_BODY_BUF_SIZE]u8,
    body_len: usize,
    header_scratch: [STREAM_HEADER_SCRATCH_SIZE]u8,
    end_headers: bool,
    end_stream: bool,
};

// --------------------------------------------------------- //

/// Read some bytes from fd: the ntdll shim on Windows, std.posix.read elsewhere.
fn readOnceFD(fd: std.posix.fd_t, buf: []u8) !usize {
    if (comptime @import("builtin").target.os.tag == .windows) return win_io.readOnce(fd, buf);

    return std.posix.read(fd, buf);
}

/// Serve one h2c connection. Takes raw fd extracted by the server dispatch layer.
/// Caller owns the fd and must close it after this exits.
pub fn serveConn(handler: HandlerFn, fd: std.posix.fd_t, opts: ServeOpts, io: std.Io) void {
    if (comptime @import("builtin").target.os.tag != .windows) {
        // std.posix.TCP is void on the BSDs in Zig 0.16: TCP_NODELAY is 1 there.
        const nodelay: u32 = if (comptime std.posix.TCP != void) std.posix.TCP.NODELAY else 1;

        std.posix.setsockopt(
            fd,
            std.posix.IPPROTO.TCP,
            nodelay,
            std.mem.asBytes(&@as(c_int, 1)),
        ) catch {};
    }
    serveConnInner(handler, fd, opts, io) catch {};
}

fn serveConnInner(handler: HandlerFn, fd: std.posix.fd_t, opts: ServeOpts, io: std.Io) !void {
    var peek: [3]u8 = undefined;
    try frame.recvExact(fd, &peek);

    if (std.mem.eql(u8, &peek, "PRI")) {
        var rest: [21]u8 = undefined;
        try frame.recvExact(fd, &rest);
        var preface: [24]u8 = undefined;
        @memcpy(preface[0..3], &peek);
        @memcpy(preface[3..], &rest);
        if (!std.mem.eql(u8, &preface, frame.PREFACE)) {
            frame.sendGoawayFD(fd, 0, frame.ERR_PROTOCOL_ERROR) catch {};
            return error.ZixBadPreface;
        }
        try frame.sendSettingsFD(fd, &.{
            .{ frame.SETTINGS_MAX_CONCURRENT_STREAMS, @as(u32, @intCast(opts.max_streams)) },
            .{ frame.SETTINGS_INITIAL_WINDOW_SIZE, 65535 },
            .{ frame.SETTINGS_MAX_FRAME_SIZE, opts.max_frame_size },
            .{ frame.SETTINGS_ENABLE_PUSH, 0 },
        });
        var hpack_dec = hpack.HpackDecoder.init();
        try serveH2cLoop(handler, fd, &hpack_dec, opts, 0, io, frame.DEFAULT_MAX_FRAME_SIZE);
    } else {
        try serveH2cUpgrade(handler, fd, opts, &peek, io);
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

fn serveH2cUpgrade(handler: HandlerFn, fd: std.posix.fd_t, opts: ServeOpts, prefix: *const [3]u8, io: std.Io) !void {
    var head_buf: [UPGRADE_HEAD_BUF]u8 = undefined;
    var filled: usize = 3;
    @memcpy(head_buf[0..3], prefix);
    while (std.mem.indexOf(u8, head_buf[0..filled], "\r\n\r\n") == null) {
        if (filled >= head_buf.len) return error.ZixHeaderTooLarge;
        const n = readOnceFD(fd, head_buf[filled..]) catch return error.ZixClosed;
        if (n == 0) return error.ZixClosed;
        filled += n;
    }
    const hdr_end = std.mem.indexOf(u8, head_buf[0..filled], "\r\n\r\n").? + 4;

    const upgrade = getHttp1Header(head_buf[0..hdr_end], "upgrade") orelse {
        frame.writeAllFD(fd, "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n") catch {};
        return error.ZixBadRequest;
    };
    if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, upgrade, " "), "h2c")) {
        frame.writeAllFD(fd, "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n") catch {};
        return error.ZixBadRequest;
    }

    var method: []const u8 = "GET";
    var path: []const u8 = "/";
    if (std.mem.indexOfScalar(u8, head_buf[0..hdr_end], ' ')) |sp1| {
        method = head_buf[0..sp1];
        const after = head_buf[sp1 + 1 .. hdr_end];
        if (std.mem.indexOfScalar(u8, after, ' ')) |sp2| path = after[0..sp2];
    }

    try frame.writeAllFD(
        fd,
        "HTTP/1.1 101 Switching Protocols\r\n" ++
            "Connection: Upgrade\r\nUpgrade: h2c\r\n\r\n",
    );

    var preface: [24]u8 = undefined;
    try frame.recvExact(fd, &preface);
    if (!std.mem.eql(u8, &preface, frame.PREFACE)) {
        frame.sendGoawayFD(fd, 0, frame.ERR_PROTOCOL_ERROR) catch {};
        return error.ZixBadPreface;
    }

    var hpack_dec = hpack.HpackDecoder.init();
    var peer_max_frame_size: u32 = frame.DEFAULT_MAX_FRAME_SIZE;
    if (getHttp1Header(head_buf[0..hdr_end], "http2-settings")) |b64| {
        const trimmed = std.mem.trim(u8, b64, " ");
        var decoded: [SETTINGS_DECODE_SCRATCH]u8 = undefined;
        const dlen = std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(trimmed) catch 0;
        if (dlen > 0 and dlen <= decoded.len) {
            std.base64.url_safe_no_pad.Decoder.decode(decoded[0..dlen], trimmed) catch {};
            var i: usize = 0;
            while (i + 6 <= dlen) : (i += 6) {
                const id: u16 = (@as(u16, decoded[i]) << 8) | decoded[i + 1];
                const val: u32 = (@as(u32, decoded[i + 2]) << 24) | (@as(u32, decoded[i + 3]) << 16) |
                    (@as(u32, decoded[i + 4]) << 8) | decoded[i + 5];
                if (id == frame.SETTINGS_HEADER_TABLE_SIZE) {
                    hpack_dec.max_size = val;
                    hpack_dec.evictTo(val);
                }
                // The upgrade header carries the client's SETTINGS, so the frame ceiling for the
                // carried stream-1 response is known before a single frame is exchanged.
                if (id == frame.SETTINGS_MAX_FRAME_SIZE and val >= frame.DEFAULT_MAX_FRAME_SIZE and val <= 16_777_215) {
                    peer_max_frame_size = val;
                }
            }
        }
    }

    try frame.sendSettingsFD(fd, &.{
        .{ frame.SETTINGS_MAX_CONCURRENT_STREAMS, @as(u32, @intCast(opts.max_streams)) },
        .{ frame.SETTINGS_INITIAL_WINDOW_SIZE, 65535 },
        .{ frame.SETTINGS_MAX_FRAME_SIZE, opts.max_frame_size },
        .{ frame.SETTINGS_ENABLE_PUSH, 0 },
    });

    var s1_hdrs = [3]hpack.Header{
        .{ .name = ":method", .value = method },
        .{ .name = ":path", .value = path },
        .{ .name = ":scheme", .value = "http" },
    };
    const split = Request.splitPath(path);
    var req = Request{ .method = method, .path = split.path, .query = split.query, .headers = &s1_hdrs, .body = &.{} };
    const deadline_ns: ?u64 = if (opts.handler_timeout_ms > 0) wallClockNs() + @as(u64, opts.handler_timeout_ms) * std.time.ns_per_ms else null;
    invokeHandler(handler, &req, fd, 1, io, deadline_ns, opts, peer_max_frame_size);

    try serveH2cLoop(handler, fd, &hpack_dec, opts, 1, io, peer_max_frame_size);
}

fn serveH2cLoop(
    handler: HandlerFn,
    fd: std.posix.fd_t,
    hpack_dec: *hpack.HpackDecoder,
    opts: ServeOpts,
    initial_last_stream: u31,
    io: std.Io,
    initial_peer_max_frame_size: u32,
) !void {
    // Tracks the peer's SETTINGS_MAX_FRAME_SIZE for the life of the connection. A peer may raise it
    // mid-connection, so this is a running value rather than a constant read once at the preface.
    var peer_max_frame_size: u32 = initial_peer_max_frame_size;

    const max_payload = opts.max_frame_size + frame.FRAME_PAYLOAD_SLACK;
    const payload_buf = try std.heap.smp_allocator.alloc(u8, max_payload);
    defer std.heap.smp_allocator.free(payload_buf);

    const streams = try std.heap.smp_allocator.alloc(Stream, opts.max_streams);
    defer std.heap.smp_allocator.free(streams);
    const stream_slots = try std.heap.smp_allocator.alloc(bool, opts.max_streams);
    defer std.heap.smp_allocator.free(stream_slots);
    @memset(stream_slots, false);

    var last_stream_id: u31 = initial_last_stream;

    while (true) {
        const fh = try frame.readFrameHeader(fd);

        if (fh.length > max_payload) {
            frame.sendGoawayFD(fd, last_stream_id, frame.ERR_FRAME_SIZE_ERROR) catch {};
            return error.ZixFrameTooLarge;
        }

        const payload = payload_buf[0..fh.length];
        if (fh.length > 0) try frame.recvExact(fd, payload);

        switch (fh.frame_type) {
            frame.FRAME_TYPE_SETTINGS => {
                if ((fh.flags & frame.FLAG_ACK) != 0) continue;
                var i: usize = 0;
                while (i + 6 <= payload.len) : (i += 6) {
                    const id: u16 = (@as(u16, payload[i]) << 8) | payload[i + 1];
                    const val: u32 = (@as(u32, payload[i + 2]) << 24) | (@as(u32, payload[i + 3]) << 16) |
                        (@as(u32, payload[i + 4]) << 8) | payload[i + 5];
                    if (id == frame.SETTINGS_HEADER_TABLE_SIZE) {
                        hpack_dec.max_size = val;
                        hpack_dec.evictTo(val);
                    }
                    // RFC 7540 6.5.2: a valid SETTINGS_MAX_FRAME_SIZE is 16384..16777215. Outbound
                    // DATA is capped to it so no frame the peer would reject with FRAME_SIZE_ERROR
                    // is ever emitted. An out-of-range value keeps the last good one.
                    if (id == frame.SETTINGS_MAX_FRAME_SIZE and val >= frame.DEFAULT_MAX_FRAME_SIZE and val <= 16_777_215) {
                        peer_max_frame_size = val;
                    }
                }
                try frame.sendSettingsAckFD(fd);
                try frame.sendWindowUpdateFD(fd, 0, frame.DEFAULT_WINDOW_SIZE);
            },

            frame.FRAME_TYPE_WINDOW_UPDATE => {},

            frame.FRAME_TYPE_PING => {
                if ((fh.flags & frame.FLAG_ACK) != 0) continue;
                if (payload.len != 8) {
                    frame.sendGoawayFD(fd, last_stream_id, frame.ERR_FRAME_SIZE_ERROR) catch {};
                    return error.ZixProtocolError;
                }
                var p8: [8]u8 = undefined;
                @memcpy(&p8, payload[0..8]);
                try frame.sendPingAckFD(fd, p8);
            },

            frame.FRAME_TYPE_HEADERS => {
                const sid = fh.stream_id;
                if (sid == 0) {
                    frame.sendGoawayFD(fd, last_stream_id, frame.ERR_PROTOCOL_ERROR) catch {};
                    return error.ZixProtocolError;
                }
                if (sid <= last_stream_id and sid % 2 == 1) {
                    frame.sendRstStreamFD(fd, sid, frame.ERR_STREAM_CLOSED) catch {};
                    continue;
                }
                last_stream_id = @max(last_stream_id, sid);

                const slot = slotFor(sid, streams, stream_slots) orelse {
                    frame.sendRstStreamFD(fd, sid, frame.ERR_REFUSED_STREAM) catch {};
                    continue;
                };
                const s = &streams[slot];
                s.* = std.mem.zeroes(Stream);
                s.id = sid;
                s.state = .OPEN;

                var block = payload;
                var offset: usize = 0;
                var pad_len: usize = 0;
                if ((fh.flags & frame.FLAG_PADDED) != 0 and block.len > 0) {
                    pad_len = block[0];
                    offset = 1;
                }
                if ((fh.flags & frame.FLAG_PRIORITY) != 0 and offset + 5 <= block.len) {
                    offset += 5;
                }
                if (pad_len + offset > block.len) {
                    frame.sendGoawayFD(fd, last_stream_id, frame.ERR_PROTOCOL_ERROR) catch {};
                    return error.ZixProtocolError;
                }
                block = block[offset .. block.len - pad_len];

                s.header_count = hpack_dec.decode(block, &s.headers, &s.header_scratch) catch {
                    frame.sendRstStreamFD(fd, sid, frame.ERR_COMPRESSION_ERROR) catch {};
                    stream_slots[slot] = false;
                    continue;
                };
                s.end_headers = (fh.flags & frame.FLAG_END_HEADERS) != 0;
                s.end_stream = (fh.flags & frame.FLAG_END_STREAM) != 0;

                if (s.end_headers and s.end_stream) {
                    dispatchStream(handler, s, fd, opts, io, peer_max_frame_size);
                    stream_slots[slot] = false;
                }
            },

            frame.FRAME_TYPE_CONTINUATION => {
                const sid = fh.stream_id;
                const slot = findSlot(sid, streams, stream_slots) orelse {
                    frame.sendGoawayFD(fd, last_stream_id, frame.ERR_PROTOCOL_ERROR) catch {};
                    return error.ZixProtocolError;
                };
                const s = &streams[slot];
                const count = hpack_dec.decode(payload, s.headers[s.header_count..], &s.header_scratch) catch {
                    frame.sendRstStreamFD(fd, sid, frame.ERR_COMPRESSION_ERROR) catch {};
                    stream_slots[slot] = false;
                    continue;
                };
                s.header_count += count;
                s.end_headers = (fh.flags & frame.FLAG_END_HEADERS) != 0;
                if (s.end_headers and s.end_stream) {
                    dispatchStream(handler, s, fd, opts, io, peer_max_frame_size);
                    stream_slots[slot] = false;
                }
            },

            frame.FRAME_TYPE_DATA => {
                const sid = fh.stream_id;
                if (sid == 0) {
                    frame.sendGoawayFD(fd, last_stream_id, frame.ERR_PROTOCOL_ERROR) catch {};
                    return error.ZixProtocolError;
                }
                const slot = findSlot(sid, streams, stream_slots) orelse {
                    frame.sendRstStreamFD(fd, sid, frame.ERR_STREAM_CLOSED) catch {};
                    continue;
                };
                const s = &streams[slot];

                var data = payload;
                var pad_len: usize = 0;
                if ((fh.flags & frame.FLAG_PADDED) != 0 and data.len > 0) {
                    pad_len = data[0];
                    data = data[1..];
                }
                if (pad_len > data.len) {
                    frame.sendGoawayFD(fd, last_stream_id, frame.ERR_PROTOCOL_ERROR) catch {};
                    return error.ZixProtocolError;
                }
                data = data[0 .. data.len - pad_len];

                if (data.len > 0) {
                    frame.sendWindowUpdateFD(fd, 0, @intCast(data.len)) catch {};
                    frame.sendWindowUpdateFD(fd, sid, @intCast(data.len)) catch {};
                }

                const to_copy = @min(data.len, s.body.len - s.body_len);
                @memcpy(s.body[s.body_len..][0..to_copy], data[0..to_copy]);
                s.body_len += to_copy;

                s.end_stream = (fh.flags & frame.FLAG_END_STREAM) != 0;
                if (s.end_stream) {
                    dispatchStream(handler, s, fd, opts, io, peer_max_frame_size);
                    stream_slots[slot] = false;
                }
            },

            frame.FRAME_TYPE_RST_STREAM => {
                const sid = fh.stream_id;
                if (findSlot(sid, streams, stream_slots)) |slot| {
                    stream_slots[slot] = false;
                }
            },

            frame.FRAME_TYPE_GOAWAY => return,

            frame.FRAME_TYPE_PRIORITY => {},

            else => {},
        }
    }
}

fn slotFor(sid: u31, streams: []Stream, used: []bool) ?usize {
    for (used, 0..) |u, i| {
        if (!u) {
            used[i] = true;
            streams[i].id = sid;
            return i;
        }
    }
    return null;
}

fn findSlot(sid: u31, streams: []Stream, used: []bool) ?usize {
    for (used, 0..) |u, i| {
        if (u and streams[i].id == sid) return i;
    }
    return null;
}

fn dispatchStream(handler: HandlerFn, stream: *Stream, fd: std.posix.fd_t, opts: ServeOpts, io: std.Io, peer_max_frame_size: u32) void {
    var method: []const u8 = "GET";
    var raw_path: []const u8 = "/";
    for (stream.headers[0..stream.header_count]) |h| {
        // The two pseudo-headers have distinct lengths (":path" 5, ":method" 7),
        // so dispatch on length first and do at most one compare per header.
        switch (h.name.len) {
            5 => if (std.mem.eql(u8, h.name, ":path")) {
                raw_path = h.value;
            },
            7 => if (std.mem.eql(u8, h.name, ":method")) {
                method = h.value;
            },
            else => {},
        }
    }

    const split = Request.splitPath(raw_path);
    var req = Request{
        .method = method,
        .path = split.path,
        .query = split.query,
        .headers = stream.headers[0..stream.header_count],
        .body = stream.body[0..stream.body_len],
    };
    const deadline_ns: ?u64 = if (opts.handler_timeout_ms > 0) wallClockNs() + @as(u64, opts.handler_timeout_ms) * std.time.ns_per_ms else null;
    invokeHandler(handler, &req, fd, stream.id, io, deadline_ns, opts, peer_max_frame_size);
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //

test "zix http2: ServeOpts defaults" {
    const opts = ServeOpts{};
    try std.testing.expectEqual(@as(usize, 128), opts.max_streams);
    try std.testing.expectEqual(frame.DEFAULT_MAX_FRAME_SIZE, opts.max_frame_size);
}

test "zix http2: response cache round-trips via sendCachedFD then serveCached" {
    var cache = try rc.ResponseCache.init(std.testing.allocator, .{ .max_entries = 16, .max_value_bytes = 1024 });
    defer cache.deinit();
    setCache(&cache, 1000);
    defer setCache(null, 0);

    var pair = try socket_pair.Pair.open(std.testing.allocator);
    defer pair.deinit();
    const fds = pair.fds;

    tl_req_path = "/cached";
    tl_req_body = "";
    defer {
        tl_req_path = "";
        tl_req_body = "";
    }

    // a miss before anything is stored: the handler should build the response itself
    try std.testing.expect(!serveCached(fds[1], 1, "text/plain"));

    // store under the current request key, then a later request with the same key hits and is
    // re-framed for its own stream id
    sendCachedFD(fds[1], 1, "text/plain", "hello-cached");
    try std.testing.expect(serveCached(fds[1], 3, "text/plain"));

    // a different request key still misses
    tl_req_path = "/other";
    try std.testing.expect(!serveCached(fds[1], 5, "text/plain"));
}
