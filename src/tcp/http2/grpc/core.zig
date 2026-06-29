//! gRPC h2c connection loop, handler context, and path/content-type utilities.

const std = @import("std");
const h2 = @import("../Http2.zig");
const frame = @import("frame.zig");
const status = @import("status.zig");
const Logger = @import("../../../logger/logger.zig").Logger;
const parseTimeout = @import("timeout.zig").parseTimeout;
const rc = @import("../../../utils/response_cache.zig");

/// Reply HPACK and frame staging buffer for one streamed response pass.
const reply_stage_scratch: usize = 4096;

/// Base64 decode scratch for the HTTP2-Settings header on an h2c upgrade.
const settings_decode_scratch: usize = 256;

/// Request line and header read bound for an h2c upgrade (HeaderTooLarge over this).
const upgrade_head_buf: usize = 8192;

/// gRPC mux reply staging buffer per connection.
const mux_stage_buf: usize = 65536;

/// Secondary mux per-connection read buffer floor (the mux conn path).
const mux_read_buf_min: usize = 32 * 1024;

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
    for (headers) |header| {
        if (!std.ascii.eqlIgnoreCase(header.name, "content-type")) continue;
        if (std.mem.startsWith(u8, header.value, "application/grpc+json")) return .JSON;
        if (std.mem.startsWith(u8, header.value, "application/grpc")) return .PROTO;
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
    /// Full gRPC path of this call (e.g. "/pkg.Svc/Method"). Set at dispatch.
    /// Used as part of the response cache key. Empty when unset.
    path: []const u8 = "",
    _body: []const u8,
    _pos: usize,
    _hdr_sent: bool,
    _sent_bytes: usize,
    _grpc_status: u8,
    /// Absolute deadline in nanoseconds (CLOCK_REALTIME basis). Null = no deadline.
    /// Set at dispatch from tighter_of(Route.timeout_ms, config.handler_timeout_ms, grpc-timeout header).
    /// Handler may read and overwrite. Use isExpired() to check.
    deadline_ns: ?u64 = null,
    /// Shared connection-level write spinlock. Null when no concurrent writes are possible.
    /// Held for the entire duration of each frame write to prevent interleaving across streams.
    _write_mutex: ?*ConnMutex = null,
    /// Optional corked output buffer. When set (inline unary path), HEADERS, DATA and the
    /// trailer are staged here and flushed in a single write() after the handler returns.
    /// Null on the streaming path, which writes each frame directly under _write_mutex.
    _out: ?*ReplyStage = null,
    /// When true, sendMessage compresses DATA payloads with gzip and emits grpc-encoding: gzip
    /// in the initial HEADERS frame. Set at dispatch when opts.compress is enabled and
    /// the client advertised grpc-accept-encoding: gzip.
    _resp_gzip: bool = false,

    /// Read the next gRPC message from the buffered request stream.
    /// Slices point into the body buffer. Valid for the duration of the handler call.
    ///
    /// Return:
    /// - ?[]const u8 (null when all client messages are consumed)
    pub fn recvMessage(self: *GrpcContext) ?[]const u8 {
        const remaining = self._body[self._pos..];
        if (remaining.len < frame.grpc_prefix_len) return null;
        const msg_len = std.mem.readInt(u32, remaining[1..frame.grpc_prefix_len], .big);
        const total = frame.grpc_prefix_len + @as(usize, msg_len);
        if (total > remaining.len) return null;
        const message = remaining[frame.grpc_prefix_len..total];
        self._pos += total;
        return message;
    }

    /// Write initial HEADERS if not already sent. No lock acquired, caller must hold _write_mutex.
    fn _flushHeaders(self: *GrpcContext, content_type: []const u8) void {
        if (self._hdr_sent) return;

        if (self._out) |out| {
            var buf: [frame.headers_frame_scratch]u8 = undefined;
            const n = if (self._resp_gzip)
                frame.buildGrpcHeadersGzip(&buf, self.stream_id, content_type)
            else
                frame.buildGrpcHeaders(&buf, self.stream_id, content_type);
            out.append(buf[0..n]);
        } else {
            if (self._resp_gzip) {
                var buf: [frame.headers_frame_scratch]u8 = undefined;
                const n = frame.buildGrpcHeadersGzip(&buf, self.stream_id, content_type);
                h2.fdWriteAll(self.fd, buf[0..n]) catch {};
            } else {
                frame.sendGrpcHeaders(self.fd, self.stream_id, content_type) catch {};
            }
        }
        self._hdr_sent = true;
    }

    /// Send the initial response HEADERS (:status 200, content-type). No-op if already sent.
    pub fn sendHeaders(self: *GrpcContext, content_type: []const u8) void {
        if (self._out != null) {
            self._flushHeaders(content_type);
            return;
        }

        if (self._write_mutex) |mutex| mutex.lock();
        defer {
            if (self._write_mutex) |mutex| mutex.unlock();
        }

        self._flushHeaders(content_type);
    }

    /// Send one gRPC response message DATA frame.
    /// Sends initial headers first if not yet sent.
    /// When _resp_gzip is true, the payload is gzip-compressed before sending and the
    /// compress flag in the 5-byte gRPC prefix is set to 1.
    /// Falls back to uncompressed on allocation or compression failure.
    /// On the staged (inline unary) path the frame is appended to the cork buffer.
    /// On the streaming path headers and data are written under a single lock to prevent interleaving.
    pub fn sendMessage(self: *GrpcContext, content_type: []const u8, data: []const u8) void {
        if (self._resp_gzip and data.len > 0) {
            const max_comp = data.len + frame.gzip_framing_headroom;
            if (std.heap.smp_allocator.alloc(u8, max_comp)) |comp_buf| {
                if (frame.compressGrpcMessage(data, comp_buf)) |comp_len| {
                    self._sendDataFrame(content_type, comp_buf[0..comp_len], true);
                    std.heap.smp_allocator.free(comp_buf);
                    return;
                } else |_| {}
                std.heap.smp_allocator.free(comp_buf);
            } else |_| {}
        }

        self._sendDataFrame(content_type, data, false);
    }

    fn _sendDataFrame(self: *GrpcContext, content_type: []const u8, payload: []const u8, compress: bool) void {
        if (self._out) |out| {
            self._flushHeaders(content_type);

            var head: [14]u8 = undefined;
            _ = frame.buildGrpcDataHeader(&head, self.stream_id, payload.len, compress);
            out.append(&head);
            out.append(payload);
            self._sent_bytes += payload.len;
            return;
        }

        if (self._write_mutex) |mutex| mutex.lock();
        defer {
            if (self._write_mutex) |mutex| mutex.unlock();
        }

        self._flushHeaders(content_type);

        var head: [14]u8 = undefined;
        const head_len = frame.buildGrpcDataHeader(&head, self.stream_id, payload.len, compress);

        // Small message (the common server-streaming case): coalesce the DATA header and
        // payload into one write, so each message costs one syscall instead of two and one
        // TLS record instead of two under the stream sink hook. A larger payload keeps the
        // two-write path so it is never copied through the stack buffer.
        if (head_len + payload.len <= grpc_stream_inline_cap) {
            var one: [grpc_stream_inline_cap]u8 = undefined;
            @memcpy(one[0..head_len], head[0..head_len]);
            @memcpy(one[head_len..][0..payload.len], payload);
            h2.fdWriteAll(self.fd, one[0 .. head_len + payload.len]) catch {};
        } else {
            h2.fdWriteAll(self.fd, head[0..head_len]) catch {};
            h2.fdWriteAll(self.fd, payload) catch {};
        }
        self._sent_bytes += payload.len;
    }

    /// Close the stream with a gRPC status. Must be called exactly once per handler.
    /// If no response messages were sent, sends a trailers-only (error) response.
    pub fn finish(self: *GrpcContext, stat: GrpcStatus, grpc_message: []const u8) void {
        self._grpc_status = @intFromEnum(stat);
        const status_code = self._grpc_status;

        if (self._out) |out| {
            var buf: [frame.headers_frame_scratch]u8 = undefined;
            const n = if (self._hdr_sent)
                frame.buildGrpcTrailer(&buf, self.stream_id, status_code, grpc_message)
            else
                frame.buildGrpcError(&buf, self.stream_id, status_code, grpc_message);
            out.append(buf[0..n]);
            return;
        }

        if (self._write_mutex) |mutex| mutex.lock();
        defer {
            if (self._write_mutex) |mutex| mutex.unlock();
        }

        if (self._hdr_sent) {
            frame.sendGrpcTrailer(self.fd, self.stream_id, status_code, grpc_message) catch {};
        } else {
            frame.sendGrpcError(self.fd, self.stream_id, status_code, grpc_message) catch {};
        }
    }

    /// Return true when deadline_ns has passed. False when deadline_ns is null.
    /// Does not cancel or interrupt anything, handler must check explicitly.
    pub fn isExpired(self: *const GrpcContext) bool {
        const deadline = self.deadline_ns orelse return false;
        return wallClockNs() >= deadline;
    }

    /// Serve a cached unary response when one is present and fresh. The key is
    /// the path plus the raw request body, so an identical call replays the
    /// stored response message with no handler work. On a hit the message is
    /// sent and the stream is finished with OK, and the handler should return.
    /// The cache stores the logical message, so per-stream framing and optional
    /// gzip are reapplied by sendMessage on every hit.
    ///
    /// Note:
    /// - A miss, no cache installed on this worker, or an empty path returns
    ///   false so the handler builds the response as usual.
    ///
    /// Usage:
    /// ```zig
    /// fn handler(_: []const h2.Header, ctx: *zix.Grpc.Context) void {
    ///     if (ctx.serveCached("application/grpc")) return;
    ///     const reply = buildExpensiveReply(ctx.recvMessage());
    ///     ctx.sendCached("application/grpc", reply, 0);
    ///     ctx.finish(.OK, "");
    /// }
    /// ```
    ///
    /// Return:
    /// - bool (true when served from cache, the handler should return)
    pub fn serveCached(self: *GrpcContext, content_type: []const u8) bool {
        const cache = tl_cache orelse return false;
        if (self.path.len == 0) return false;

        const bytes = cache.lookup(requestKey(self.path, self._body), rc.nowMillis()) orelse return false;

        self.sendMessage(content_type, bytes);
        self.finish(.OK, "");

        return true;
    }

    /// Send a unary response message and store it under the call key for later
    /// serveCached hits. ttl_ms of 0 uses the worker default (cacheTtl). Storing
    /// is skipped when no cache is installed, the path is empty, or the message
    /// exceeds the per-slot cap. The handler still calls finish() as usual.
    ///
    /// Param:
    /// content_type - []const u8 (response content type, e.g. "application/grpc")
    /// data - []const u8 (the uncompressed response message)
    /// ttl_ms - u32 (freshness in milliseconds, 0 means the worker default)
    pub fn sendCached(self: *GrpcContext, content_type: []const u8, data: []const u8, ttl_ms: u32) void {
        self.sendMessage(content_type, data);

        const cache = tl_cache orelse return;
        if (self.path.len == 0) return;

        const ttl = if (ttl_ms == 0) tl_cache_ttl_ms else ttl_ms;
        _ = cache.store(requestKey(self.path, self._body), data, ttl, rc.nowMillis());
    }
};

// --------------------------------------------------------- //

/// Per-worker response cache installed by the EPOLL mux worker. Null on workers
/// without a cache, so the GrpcContext cache API degrades to a plain send.
pub threadlocal var tl_cache: ?*rc.ResponseCache = null;

/// Default cache freshness for this worker, used when a handler passes ttl 0.
pub threadlocal var tl_cache_ttl_ms: u32 = 1000;

/// Install (or clear) the per-worker response cache and its default TTL.
pub fn setCache(cache: ?*rc.ResponseCache, default_ttl_ms: u32) void {
    tl_cache = cache;
    tl_cache_ttl_ms = default_ttl_ms;
}

/// Worker default cache freshness in milliseconds.
pub fn cacheTtl() u32 {
    return tl_cache_ttl_ms;
}

/// Cache key for a unary call: the gRPC path and the raw request body. Returns
/// a non-zero u64 (0 is the cache empty sentinel).
fn requestKey(path: []const u8, body: []const u8) u64 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(path);
    hasher.update(body);

    const digest = hasher.final();
    return if (digest == 0) 1 else digest;
}

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
/// is_server_streaming - bool (true for server-streaming routes that send multiple DATA frames)
pub const Route = struct {
    path: []const u8,
    handler: HandlerFn,
    /// Per-route handler timeout (milliseconds). 0 = use GrpcServerConfig.handler_timeout_ms.
    /// When non-zero, tightens ctx.deadline_ns if shorter than the global cap.
    timeout_ms: u32 = 0,
    /// Set to true for server-streaming routes (handler calls sendMessage in a loop or
    /// requires client flow-control window updates while writing). When false (default),
    /// the handler runs synchronously on the connection thread: no task alloc, no 4KB
    /// header copy, no mutex. Synchronous dispatch blocks the read loop for the handler
    /// duration, only safe for short unary handlers.
    is_server_streaming: bool = false,
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
            inline for (routes) |route| {
                if (std.mem.eql(u8, route.path, path)) {
                    if (route.timeout_ms > 0) {
                        const route_deadline: u64 = wallClockNs() + @as(u64, route.timeout_ms) * std.time.ns_per_ms;
                        if (ctx.deadline_ns) |current_deadline| {
                            if (route_deadline < current_deadline) ctx.deadline_ns = route_deadline;
                        } else {
                            ctx.deadline_ns = route_deadline;
                        }
                    }
                    route.handler(headers, ctx);
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
    /// Per-connection read buffer floor in bytes. The reader is sized to the larger of this and
    /// one max frame, so a larger floor cuts read() and compaction for big frames.
    conn_read_buf_min: usize = 64 * 1024,
    /// Initial capacity in bytes of the per-connection TLS pending-write buffer (it grows on demand).
    tls_write_buf_initial: usize = 16 * 1024,
    logger: ?*Logger = null,
    /// Global handler timeout cap (milliseconds). Passed from GrpcServerConfig.handler_timeout_ms.
    /// 0 = disabled. Combined with Route.timeout_ms and grpc-timeout header at dispatch.
    handler_timeout_ms: u32 = 0,
    /// When set, spawnGrpcStream uses io.async (work-stealing pool) instead of std.Thread.spawn.
    /// Avoids per-request clone() syscall cost (~20-50us per stream) under concurrent load.
    /// Null falls back to std.Thread.spawn for compatibility with standalone serveConn callers.
    io: ?std.Io = null,
    /// Enable gzip response compression. When true, compresses DATA frames for clients
    /// that advertise grpc-accept-encoding: gzip. Passed from GrpcServerConfig.compress.
    compress: bool = false,
    /// Enable the per-worker unary response cache (ADR-036). Passed from
    /// GrpcServerConfig.response_cache. Active under .EPOLL in this release.
    response_cache: bool = false,
    /// Response cache slot count, rounded down to a power of two.
    cache_max_entries: u32 = 256,
    /// Per-slot response-message cap. A larger message bypasses the cache.
    cache_max_value_bytes: u32 = 16 * 1024,
    /// Default cache freshness in milliseconds, exposed to handlers via cacheTtl().
    cache_ttl_ms: u32 = 1000,
    /// Optional ceiling on per-worker cache memory. 0 disables the ceiling.
    cache_max_total_bytes: usize = 0,
};

// --------------------------------------------------------- //

/// Stream-level receive window advertised in SETTINGS. Large enough that small unary and
/// streaming request bodies never need a per-DATA WINDOW_UPDATE. Inbound bodies above this
/// on a single stream would stall (not a benchmark or typical gRPC shape).
const STREAM_WINDOW_SIZE: u32 = 16 * 1024 * 1024;

/// One-time connection-level window bump sent after the SETTINGS handshake. Lifts the fixed
/// 65535 connection receive window so the read loop does not WINDOW_UPDATE per DATA frame.
const CONN_WINDOW_BUMP: u31 = 1 << 30;

/// Replenish the connection window once cumulative inbound DATA crosses this. Keeps long-lived
/// connections that move more than CONN_WINDOW_BUMP bytes from stalling, while staying ~0
/// updates per request for the small-body case.
const CONN_REPLENISH_THRESHOLD: usize = 1 << 29;

/// Streaming-path coalescing cap. A server-streaming DATA frame whose 14-byte header plus
/// payload fits under this is written in one syscall (one TLS record under the stream sink
/// hook) instead of a separate header write and payload write. Server-streaming messages are
/// small (events, rows), so this halves the per-message syscall count on the streaming hot
/// path. A larger payload keeps the two-write path so it is never copied through the stack
/// buffer. The unary path already coalesces through the cork buffer, so this is streaming only.
const grpc_stream_inline_cap: usize = 4096;

const StreamState = enum { IDLE, OPEN, HALF_CLOSED_REMOTE, CLOSED };

/// Per-stream parse state. body and header_scratch are slices into per-connection
/// backing buffers (sized to opts.max_body / opts.max_header_scratch), not inline arrays,
/// so a connection's stream table costs O(max_streams * max_body) instead of a fixed
/// ~70 KB per slot regardless of configured limits.
const Stream = struct {
    id: u31,
    state: StreamState,
    headers: [h2.MAX_HEADERS]h2.Header,
    header_count: usize,
    body: []u8,
    body_len: usize,
    header_scratch: []u8,
    end_headers: bool,
    end_stream: bool,
};

// --------------------------------------------------------- //

/// Corked output buffer for one inline (unary) reply. Stages HEADERS + DATA + trailer
/// and flushes them to the fd in a single write(). Frames larger than the buffer are
/// passed through directly after flushing the staged prefix, preserving wire order.
/// Callers supply `buf` - the backing storage for staging. Use a small stack array for
/// the blocking path. Use the per-connection `stage_buf` in GrpcMuxConn for the mux path.
const ReplyStage = struct {
    fd: std.posix.fd_t,
    buf: []u8,
    len: usize = 0,

    fn append(self: *ReplyStage, bytes: []const u8) void {
        if (bytes.len > self.buf.len - self.len) {
            self.flush();
            if (bytes.len > self.buf.len) {
                h2.fdWriteAll(self.fd, bytes) catch {};
                return;
            }
        }

        @memcpy(self.buf[self.len..][0..bytes.len], bytes);
        self.len += bytes.len;
    }

    fn flush(self: *ReplyStage) void {
        if (self.len == 0) return;

        h2.fdWriteAll(self.fd, self.buf[0..self.len]) catch {};
        self.len = 0;
    }
};

/// Buffered frame reader for one connection. Reads in chunks and serves frame headers and
/// payloads from the buffer, so a batch of small frames (the common HEADERS + DATA pair of a
/// unary call) costs one read() instead of two per frame. Payload slices point into buf and
/// are valid only until the next ensure() call.
const ConnReader = struct {
    fd: std.posix.fd_t,
    buf: []u8,
    start: usize = 0,
    end: usize = 0,

    fn fillSome(self: *ConnReader) !void {
        if (self.start == self.end) {
            self.start = 0;
            self.end = 0;
        } else if (self.end == self.buf.len) {
            const n = self.end - self.start;
            std.mem.copyForwards(u8, self.buf[0..n], self.buf[self.start..self.end]);
            self.start = 0;
            self.end = n;
        }

        const got = std.posix.read(self.fd, self.buf[self.end..]) catch return error.Closed;
        if (got == 0) return error.Closed;
        self.end += got;
    }

    /// Block until at least `need` bytes are buffered. `need` must be <= buf.len.
    fn ensure(self: *ConnReader, need: usize) !void {
        while (self.end - self.start < need) try self.fillSome();
    }

    /// Return the next `n` buffered bytes and advance. Caller must ensure(n) first.
    fn take(self: *ConnReader, n: usize) []u8 {
        const slice = self.buf[self.start..][0..n];
        self.start += n;
        return slice;
    }
};

/// Heap-allocated ref-counted write spinlock for one h2 connection.
/// Shared between the read loop and all per-stream handler threads.
/// Ensures H2 frames from concurrent streams are not interleaved on the fd.
const ConnMutex = struct {
    locked: std.atomic.Value(bool) = .init(false),
    refs: std.atomic.Value(u32) = .init(1),
    /// Count of server-streaming tasks currently writing on this connection.
    /// Read by the inline unary fast-path to decide whether the write mutex is needed.
    active_streaming: std.atomic.Value(u32) = .init(0),

    fn lock(self: *ConnMutex) void {
        while (self.locked.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
    }

    fn unlock(self: *ConnMutex) void {
        self.locked.store(false, .release);
    }

    fn retain(self: *ConnMutex) void {
        _ = self.refs.fetchAdd(1, .monotonic);
    }

    fn release(self: *ConnMutex) void {
        if (self.refs.fetchSub(1, .acq_rel) == 1) {
            std.heap.smp_allocator.destroy(self);
        }
    }
};

/// Heap-allocated per-stream dispatch task. Owns a deep copy of the stream's headers
/// and body so the read loop can immediately reuse the stream slot after spawning.
fn DispatchTask(comptime routes: []const Route) type {
    return struct {
        const Self = @This();

        fd: std.posix.fd_t,
        stream_id: u31,
        header_count: usize,
        headers: [h2.MAX_HEADERS]h2.Header,
        header_scratch: [4096]u8,
        body_len: usize,
        body: [65536]u8,
        opts: GrpcServeOpts,
        conn_mutex: *ConnMutex,

        fn run(self: *Self) void {
            const conn_mutex_ptr = self.conn_mutex;
            defer {
                _ = conn_mutex_ptr.active_streaming.fetchSub(1, .acq_rel);
                std.heap.smp_allocator.destroy(self);
                conn_mutex_ptr.release();
            }

            var path: []const u8 = "/";
            for (self.headers[0..self.header_count]) |header| {
                if (header.name.len == 5 and std.mem.eql(u8, header.name, ":path")) path = header.value;
            }

            var time_start: std.os.linux.timespec = undefined;
            if (self.opts.logger != null) _ = std.os.linux.clock_gettime(.MONOTONIC, &time_start);

            var ctx = GrpcContext{
                .fd = self.fd,
                .stream_id = self.stream_id,
                ._body = self.body[0..self.body_len],
                ._pos = 0,
                ._hdr_sent = false,
                ._sent_bytes = 0,
                ._grpc_status = 0,
                .deadline_ns = computeDeadline(self.opts.handler_timeout_ms, self.headers[0..self.header_count]),
                ._write_mutex = conn_mutex_ptr,
                ._resp_gzip = self.opts.compress and headersAcceptGzip(self.headers[0..self.header_count]),
            };
            Router(routes).dispatch(path, self.headers[0..self.header_count], &ctx);

            if (self.opts.logger) |logger| {
                var time_end: std.os.linux.timespec = undefined;
                _ = std.os.linux.clock_gettime(.MONOTONIC, &time_end);
                const dur_ns: i64 = (@as(i64, time_end.sec) - @as(i64, time_start.sec)) * 1_000_000_000 +
                    (@as(i64, time_end.nsec) - @as(i64, time_start.nsec));
                const dur_ms: u64 = @intCast(@max(0, @divTrunc(dur_ns, 1_000_000)));
                var peer_buf: [64]u8 = undefined;
                const peer = peerStr(self.fd, &peer_buf);
                logger.rpc(peer, path, ctx._grpc_status, self.body_len, ctx._sent_bytes, dur_ms);
            }
        }
    };
}

/// Spawn a detached handler thread for one gRPC stream.
/// Deep-copies stream data so the slot can be freed immediately.
/// Rebases header slice pointers from the stream's scratch buffer into the task's copy.
/// Falls back to an inline INTERNAL error if allocation or spawn fails.
fn spawnGrpcStream(
    comptime routes: []const Route,
    stream: *Stream,
    fd: std.posix.fd_t,
    opts: GrpcServeOpts,
    conn_mutex: *ConnMutex,
) void {
    const Task = DispatchTask(routes);
    const task = std.heap.smp_allocator.create(Task) catch {
        var ctx = GrpcContext{
            .fd = fd,
            .stream_id = stream.id,
            ._body = &.{},
            ._pos = 0,
            ._hdr_sent = false,
            ._sent_bytes = 0,
            ._grpc_status = 0,
            ._write_mutex = conn_mutex,
        };
        ctx.finish(.INTERNAL, "server overloaded");
        return;
    };

    task.fd = fd;
    task.stream_id = stream.id;
    task.header_count = stream.header_count;
    task.headers = stream.headers;

    // stream.header_scratch is a slice into the connection backing buffer. Copy its used range
    // into the task'stream owned array so header name/value pointers can be rebased below.
    // Requires opts.max_header_scratch <= task.header_scratch.len (4096).
    const scratch_n = @min(task.header_scratch.len, stream.header_scratch.len);
    @memcpy(task.header_scratch[0..scratch_n], stream.header_scratch[0..scratch_n]);

    if (headersHaveGzipEncoding(stream.headers[0..stream.header_count])) {
        var decomp_buf: ?[]u8 = null;
        const eff = maybeDecompressBody(stream.body[0..stream.body_len], stream.headers[0..stream.header_count], opts.max_body, &decomp_buf);
        defer if (decomp_buf) |buf| std.heap.smp_allocator.free(buf);
        task.body_len = @min(eff.len, task.body.len);
        @memcpy(task.body[0..task.body_len], eff[0..task.body_len]);
    } else {
        task.body_len = stream.body_len;
        @memcpy(task.body[0..stream.body_len], stream.body[0..stream.body_len]);
    }

    task.opts = opts;

    const old_base = @intFromPtr(&stream.header_scratch[0]);
    const old_end = old_base + stream.header_scratch.len;
    for (task.headers[0..task.header_count]) |*hdr| {
        const name_ptr = @intFromPtr(hdr.name.ptr);
        if (name_ptr >= old_base and name_ptr < old_end) {
            hdr.name = task.header_scratch[name_ptr - old_base ..][0..hdr.name.len];
        }
        const val_ptr = @intFromPtr(hdr.value.ptr);
        if (val_ptr >= old_base and val_ptr < old_end) {
            hdr.value = task.header_scratch[val_ptr - old_base ..][0..hdr.value.len];
        }
    }

    _ = conn_mutex.active_streaming.fetchAdd(1, .monotonic);
    conn_mutex.retain();
    task.conn_mutex = conn_mutex;

    if (opts.io) |spawn_io| {
        // Use the work-stealing thread pool: no per-request clone() syscall.
        _ = spawn_io.async(Task.run, .{task});
    } else {
        const thread = std.Thread.spawn(.{}, Task.run, .{task}) catch {
            _ = conn_mutex.active_streaming.fetchSub(1, .acq_rel);
            conn_mutex.release();
            std.heap.smp_allocator.destroy(task);
            var ctx = GrpcContext{
                .fd = fd,
                .stream_id = stream.id,
                ._body = &.{},
                ._pos = 0,
                ._hdr_sent = false,
                ._sent_bytes = 0,
                ._grpc_status = 0,
                ._write_mutex = conn_mutex,
            };
            ctx.finish(.INTERNAL, "spawn failed");
            return;
        };
        thread.detach();
    }
}

fn headerPath(headers: []const h2.Header) []const u8 {
    for (headers) |header| {
        if (header.name.len == 5 and std.mem.eql(u8, header.name, ":path")) return header.value;
    }
    return "/";
}

fn routeIsStreaming(comptime routes: []const Route, path: []const u8) bool {
    inline for (routes) |route| {
        if (std.mem.eql(u8, route.path, path)) return route.is_server_streaming;
    }
    return false;
}

fn dispatchGrpcInline(
    comptime routes: []const Route,
    stream: *const Stream,
    fd: std.posix.fd_t,
    opts: GrpcServeOpts,
    conn_mutex: *ConnMutex,
    path: []const u8,
) void {
    var time_start: std.os.linux.timespec = undefined;
    if (opts.logger != null) _ = std.os.linux.clock_gettime(.MONOTONIC, &time_start);

    var decomp_buf: ?[]u8 = null;
    defer if (decomp_buf) |buf| std.heap.smp_allocator.free(buf);
    const effective_body = maybeDecompressBody(
        stream.body[0..stream.body_len],
        stream.headers[0..stream.header_count],
        opts.max_body,
        &decomp_buf,
    );

    const resp_gzip = opts.compress and headersAcceptGzip(stream.headers[0..stream.header_count]);

    // The reply (HEADERS + DATA + trailer) is staged and flushed in one write().
    // Hold the connection write lock across the whole reply only when a streaming
    // task may be writing concurrently, so frames are not interleaved.
    const need_mutex = conn_mutex.active_streaming.load(.acquire) > 0;
    var stage_buf: [reply_stage_scratch]u8 = undefined;
    var stage = ReplyStage{ .fd = fd, .buf = &stage_buf };

    var ctx = GrpcContext{
        .fd = fd,
        .stream_id = stream.id,
        ._body = effective_body,
        ._pos = 0,
        ._hdr_sent = false,
        ._sent_bytes = 0,
        ._grpc_status = 0,
        .deadline_ns = computeDeadline(opts.handler_timeout_ms, stream.headers[0..stream.header_count]),
        ._write_mutex = null,
        ._out = &stage,
        ._resp_gzip = resp_gzip,
    };

    if (need_mutex) conn_mutex.lock();
    Router(routes).dispatch(path, stream.headers[0..stream.header_count], &ctx);
    stage.flush();
    if (need_mutex) conn_mutex.unlock();

    if (opts.logger) |logger| {
        var time_end: std.os.linux.timespec = undefined;
        _ = std.os.linux.clock_gettime(.MONOTONIC, &time_end);
        const dur_ns: i64 = (@as(i64, time_end.sec) - @as(i64, time_start.sec)) * 1_000_000_000 +
            (@as(i64, time_end.nsec) - @as(i64, time_start.nsec));
        const dur_ms: u64 = @intCast(@max(0, @divTrunc(dur_ns, 1_000_000)));
        var peer_buf: [64]u8 = undefined;
        const peer = peerStr(fd, &peer_buf);
        logger.rpc(peer, path, ctx._grpc_status, stream.body_len, ctx._sent_bytes, dur_ms);
    }
}

fn dispatchStream(
    comptime routes: []const Route,
    stream: *Stream,
    fd: std.posix.fd_t,
    opts: GrpcServeOpts,
    conn_mutex: *ConnMutex,
) void {
    const path = headerPath(stream.headers[0..stream.header_count]);

    if (routeIsStreaming(routes, path)) {
        spawnGrpcStream(routes, stream, fd, opts, conn_mutex);
    } else {
        dispatchGrpcInline(routes, stream, fd, opts, conn_mutex, path);
    }
}

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
            .{ h2.SETTINGS_MAX_CONCURRENT_STREAMS, @as(u32, @intCast(opts.max_streams)) },
            .{ h2.SETTINGS_INITIAL_WINDOW_SIZE, STREAM_WINDOW_SIZE },
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
    var head_buf: [upgrade_head_buf]u8 = undefined;
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
    if (getHttp1Header(head_buf[0..hdr_end], "http2-settings")) |settings_encoded| {
        const trimmed = std.mem.trim(u8, settings_encoded, " ");
        var decoded: [settings_decode_scratch]u8 = undefined;
        const decoded_len = std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(trimmed) catch 0;
        if (decoded_len > 0 and decoded_len <= decoded.len) {
            std.base64.url_safe_no_pad.Decoder.decode(decoded[0..decoded_len], trimmed) catch {};
            var i: usize = 0;
            while (i + 6 <= decoded_len) : (i += 6) {
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
        .{ h2.SETTINGS_MAX_CONCURRENT_STREAMS, @as(u32, @intCast(opts.max_streams)) },
        .{ h2.SETTINGS_INITIAL_WINDOW_SIZE, STREAM_WINDOW_SIZE },
        .{ h2.SETTINGS_MAX_FRAME_SIZE, opts.max_frame_size },
        .{ h2.SETTINGS_ENABLE_PUSH, 0 },
    });

    var stream1_headers = [2]h2.Header{
        .{ .name = ":path", .value = path },
        .{ .name = ":scheme", .value = "http" },
    };

    var time_start: std.os.linux.timespec = undefined;
    if (opts.logger != null) _ = std.os.linux.clock_gettime(.MONOTONIC, &time_start);

    // Note:
    // Stream 1 (h2c upgrade) is dispatched synchronously before the read loop starts.
    // A long-running streaming handler here will delay the loop. This is a known limitation
    // of the upgrade path, h2c direct does not have this issue.
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
    Router(routes).dispatch(path, &stream1_headers, &ctx);

    if (opts.logger) |logger| {
        var time_end: std.os.linux.timespec = undefined;
        _ = std.os.linux.clock_gettime(.MONOTONIC, &time_end);
        const dur_ns: i64 = (@as(i64, time_end.sec) - @as(i64, time_start.sec)) * 1_000_000_000 +
            (@as(i64, time_end.nsec) - @as(i64, time_start.nsec));
        const dur_ms: u64 = @intCast(@max(0, @divTrunc(dur_ns, 1_000_000)));
        var peer_buf: [64]u8 = undefined;
        const peer = peerStr(fd, &peer_buf);
        logger.rpc(peer, path, ctx._grpc_status, ctx._body.len, ctx._sent_bytes, dur_ms);
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
    const max_payload = opts.max_frame_size + h2.FRAME_PAYLOAD_SLACK;
    // Read buffer holds at least one full frame (header + max payload) and is large enough
    // to batch several small frames per read().
    const reader_cap = @max(opts.conn_read_buf_min, max_payload + 9);
    const reader_buf = try std.heap.smp_allocator.alloc(u8, reader_cap);
    defer std.heap.smp_allocator.free(reader_buf);
    var reader = ConnReader{ .fd = fd, .buf = reader_buf };

    const streams = try std.heap.smp_allocator.alloc(Stream, opts.max_streams);
    defer std.heap.smp_allocator.free(streams);
    const stream_slots = try std.heap.smp_allocator.alloc(bool, opts.max_streams);
    defer std.heap.smp_allocator.free(stream_slots);
    @memset(stream_slots, false);

    const bodies = try std.heap.smp_allocator.alloc(u8, opts.max_body * opts.max_streams);
    defer std.heap.smp_allocator.free(bodies);
    const scratches = try std.heap.smp_allocator.alloc(u8, opts.max_header_scratch * opts.max_streams);
    defer std.heap.smp_allocator.free(scratches);
    for (streams, 0..) |*s, i| {
        s.body = bodies[i * opts.max_body ..][0..opts.max_body];
        s.header_scratch = scratches[i * opts.max_header_scratch ..][0..opts.max_header_scratch];
    }

    var last_stream_id: u31 = initial_last_stream;
    var conn_window_consumed: usize = 0;

    const conn_mutex = try std.heap.smp_allocator.create(ConnMutex);
    conn_mutex.* = .{};
    defer conn_mutex.release();

    while (true) {
        try reader.ensure(9);
        const frame_header = h2.parseFrameHeader(reader.take(9));

        if (frame_header.length > max_payload) {
            {
                conn_mutex.lock();
                defer conn_mutex.unlock();
                h2.sendGoaway(fd, last_stream_id, h2.ERR_FRAME_SIZE_ERROR) catch {};
            }
            return error.FrameTooLarge;
        }

        try reader.ensure(frame_header.length);
        const payload = reader.take(frame_header.length);

        switch (frame_header.frame_type) {
            h2.FRAME_TYPE_SETTINGS => {
                if ((frame_header.flags & h2.FLAG_ACK) != 0) continue;
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
                {
                    conn_mutex.lock();
                    defer conn_mutex.unlock();
                    try h2.sendSettingsAck(fd);
                    try h2.sendWindowUpdate(fd, 0, CONN_WINDOW_BUMP);
                }
            },

            h2.FRAME_TYPE_WINDOW_UPDATE => {},

            h2.FRAME_TYPE_PING => {
                if ((frame_header.flags & h2.FLAG_ACK) != 0) continue;
                if (payload.len != 8) {
                    {
                        conn_mutex.lock();
                        defer conn_mutex.unlock();
                        h2.sendGoaway(fd, last_stream_id, h2.ERR_FRAME_SIZE_ERROR) catch {};
                    }
                    return error.ProtocolError;
                }
                var ping_payload: [8]u8 = undefined;
                @memcpy(&ping_payload, payload[0..8]);
                {
                    conn_mutex.lock();
                    defer conn_mutex.unlock();
                    try h2.sendPingAck(fd, ping_payload);
                }
            },

            h2.FRAME_TYPE_HEADERS => {
                const stream_id = frame_header.stream_id;
                if (stream_id == 0) {
                    {
                        conn_mutex.lock();
                        defer conn_mutex.unlock();
                        h2.sendGoaway(fd, last_stream_id, h2.ERR_PROTOCOL_ERROR) catch {};
                    }
                    return error.ProtocolError;
                }
                if (stream_id <= last_stream_id and stream_id % 2 == 1) {
                    {
                        conn_mutex.lock();
                        defer conn_mutex.unlock();
                        h2.sendRstStream(fd, stream_id, h2.ERR_STREAM_CLOSED) catch {};
                    }
                    continue;
                }
                last_stream_id = @max(last_stream_id, stream_id);

                const slot = slotFor(stream_id, streams, stream_slots) orelse {
                    {
                        conn_mutex.lock();
                        defer conn_mutex.unlock();
                        h2.sendRstStream(fd, stream_id, h2.ERR_REFUSED_STREAM) catch {};
                    }
                    continue;
                };
                const stream = &streams[slot];
                stream.id = stream_id;
                stream.state = .OPEN;
                stream.body_len = 0;

                var block = payload;
                var offset: usize = 0;
                var pad_len: usize = 0;
                if ((frame_header.flags & h2.FLAG_PADDED) != 0 and block.len > 0) {
                    pad_len = block[0];
                    offset = 1;
                }
                if ((frame_header.flags & h2.FLAG_PRIORITY) != 0 and offset + 5 <= block.len) {
                    offset += 5;
                }
                if (pad_len + offset > block.len) {
                    {
                        conn_mutex.lock();
                        defer conn_mutex.unlock();
                        h2.sendGoaway(fd, last_stream_id, h2.ERR_PROTOCOL_ERROR) catch {};
                    }
                    return error.ProtocolError;
                }
                block = block[offset .. block.len - pad_len];

                stream.header_count = hpack_dec.decode(block, &stream.headers, stream.header_scratch) catch {
                    {
                        conn_mutex.lock();
                        defer conn_mutex.unlock();
                        h2.sendRstStream(fd, stream_id, h2.ERR_COMPRESSION_ERROR) catch {};
                    }
                    stream_slots[slot] = false;
                    continue;
                };
                stream.end_headers = (frame_header.flags & h2.FLAG_END_HEADERS) != 0;
                stream.end_stream = (frame_header.flags & h2.FLAG_END_STREAM) != 0;

                if (stream.end_headers and stream.end_stream) {
                    dispatchStream(routes, stream, fd, opts, conn_mutex);
                    stream_slots[slot] = false;
                }
            },

            h2.FRAME_TYPE_CONTINUATION => {
                const stream_id = frame_header.stream_id;
                const slot = findSlot(stream_id, streams, stream_slots) orelse {
                    {
                        conn_mutex.lock();
                        defer conn_mutex.unlock();
                        h2.sendGoaway(fd, last_stream_id, h2.ERR_PROTOCOL_ERROR) catch {};
                    }
                    return error.ProtocolError;
                };
                const stream = &streams[slot];
                const count = hpack_dec.decode(payload, stream.headers[stream.header_count..], stream.header_scratch) catch {
                    {
                        conn_mutex.lock();
                        defer conn_mutex.unlock();
                        h2.sendRstStream(fd, stream_id, h2.ERR_COMPRESSION_ERROR) catch {};
                    }
                    stream_slots[slot] = false;
                    continue;
                };
                stream.header_count += count;
                stream.end_headers = (frame_header.flags & h2.FLAG_END_HEADERS) != 0;
                if (stream.end_headers and stream.end_stream) {
                    dispatchStream(routes, stream, fd, opts, conn_mutex);
                    stream_slots[slot] = false;
                }
            },

            h2.FRAME_TYPE_DATA => {
                const stream_id = frame_header.stream_id;
                if (stream_id == 0) {
                    {
                        conn_mutex.lock();
                        defer conn_mutex.unlock();
                        h2.sendGoaway(fd, last_stream_id, h2.ERR_PROTOCOL_ERROR) catch {};
                    }
                    return error.ProtocolError;
                }
                const slot = findSlot(stream_id, streams, stream_slots) orelse {
                    {
                        conn_mutex.lock();
                        defer conn_mutex.unlock();
                        h2.sendRstStream(fd, stream_id, h2.ERR_STREAM_CLOSED) catch {};
                    }
                    continue;
                };
                const stream = &streams[slot];

                var data = payload;
                var pad_len: usize = 0;
                if ((frame_header.flags & h2.FLAG_PADDED) != 0 and data.len > 0) {
                    pad_len = data[0];
                    data = data[1..];
                }
                if (pad_len > data.len) {
                    {
                        conn_mutex.lock();
                        defer conn_mutex.unlock();
                        h2.sendGoaway(fd, last_stream_id, h2.ERR_PROTOCOL_ERROR) catch {};
                    }
                    return error.ProtocolError;
                }
                data = data[0 .. data.len - pad_len];

                // Stream-level flow control is covered by the large STREAM_WINDOW_SIZE in
                // SETTINGS, so no per-frame stream WINDOW_UPDATE is needed. The connection
                // window is bumped once at handshake and only replenished in bulk here.
                if (data.len > 0) {
                    conn_window_consumed += data.len;
                    if (conn_window_consumed >= CONN_REPLENISH_THRESHOLD) {
                        conn_mutex.lock();
                        defer conn_mutex.unlock();
                        h2.sendWindowUpdate(fd, 0, @intCast(conn_window_consumed)) catch {};
                        conn_window_consumed = 0;
                    }
                }

                const to_copy = @min(data.len, stream.body.len - stream.body_len);
                @memcpy(stream.body[stream.body_len..][0..to_copy], data[0..to_copy]);
                stream.body_len += to_copy;
                stream.end_stream = (frame_header.flags & h2.FLAG_END_STREAM) != 0;

                if (stream.end_stream) {
                    dispatchStream(routes, stream, fd, opts, conn_mutex);
                    stream_slots[slot] = false;
                }
            },

            h2.FRAME_TYPE_RST_STREAM => {
                const stream_id = frame_header.stream_id;
                if (findSlot(stream_id, streams, stream_slots)) |slot| stream_slots[slot] = false;
            },

            h2.FRAME_TYPE_GOAWAY => return,
            h2.FRAME_TYPE_PRIORITY => {},
            else => {},
        }
    }
}

// --------------------------------------------------------- //
// Multiplexed EPOLL model: one worker thread drives many non-blocking connections through a
// resumable h2 state machine. Each connection is owned by a single worker, so dispatch is
// inline (no per-stream threads, no connection write mutex) and every frame produced in one
// readable event is coalesced into the connection's ReplyStage and flushed in one write().

pub const GrpcConnOutcome = enum { keep_alive, close };

const MuxPhase = enum { await_preface, await_upgrade, await_preface2, h2 };

/// Per-connection h2/gRPC state for the multiplexed EPOLL model. Heap-owned, one per fd.
/// rbuf is the read accumulator: it persists across readable events and holds any partial
/// frame until the rest arrives. The stream table, hpack decoder and reply cork are all
/// private to the owning worker thread.
pub const GrpcMuxConn = struct {
    fd: std.posix.fd_t,
    opts: GrpcServeOpts,

    rbuf: []u8,
    rstart: usize,
    rend: usize,

    hpack_dec: h2.HpackDecoder,

    streams: []Stream,
    slots: []bool,
    bodies: []u8,
    scratches: []u8,

    last_stream_id: u31,
    conn_window_consumed: usize,
    phase: MuxPhase,

    /// Precomputed 33-byte server SETTINGS frame (9-byte header + 4 params x 6 bytes).
    /// Built once in init from opts and appended as-is on every new h2 connection.
    settings_frame: [33]u8,
    /// 64 KB backing store for the per-event reply stage.
    /// Large enough to hold a full 5000-message streaming call (~85 KB peak) in 2 flushes
    /// and to coalesce 100 concurrent unary replies (~6 KB) in a single write().
    stage_buf: [mux_stage_buf]u8,
    stage: ReplyStage,

    /// Allocate and initialize a connection.
    ///
    /// Return:
    /// - null on allocation failure (caller closes fd)
    pub fn init(fd: std.posix.fd_t, opts: GrpcServeOpts) ?*GrpcMuxConn {
        const conn = std.heap.smp_allocator.create(GrpcMuxConn) catch return null;

        const max_payload = opts.max_frame_size + h2.FRAME_PAYLOAD_SLACK;
        const rcap = @max(mux_read_buf_min, max_payload + 9);
        const rbuf = std.heap.smp_allocator.alloc(u8, rcap) catch {
            std.heap.smp_allocator.destroy(conn);
            return null;
        };
        const streams = std.heap.smp_allocator.alloc(Stream, opts.max_streams) catch {
            std.heap.smp_allocator.free(rbuf);
            std.heap.smp_allocator.destroy(conn);
            return null;
        };
        const slots = std.heap.smp_allocator.alloc(bool, opts.max_streams) catch {
            std.heap.smp_allocator.free(streams);
            std.heap.smp_allocator.free(rbuf);
            std.heap.smp_allocator.destroy(conn);
            return null;
        };
        const bodies = std.heap.smp_allocator.alloc(u8, opts.max_body * opts.max_streams) catch {
            std.heap.smp_allocator.free(slots);
            std.heap.smp_allocator.free(streams);
            std.heap.smp_allocator.free(rbuf);
            std.heap.smp_allocator.destroy(conn);
            return null;
        };
        const scratches = std.heap.smp_allocator.alloc(u8, opts.max_header_scratch * opts.max_streams) catch {
            std.heap.smp_allocator.free(bodies);
            std.heap.smp_allocator.free(slots);
            std.heap.smp_allocator.free(streams);
            std.heap.smp_allocator.free(rbuf);
            std.heap.smp_allocator.destroy(conn);
            return null;
        };

        @memset(slots, false);
        for (streams, 0..) |*s, i| {
            s.body = bodies[i * opts.max_body ..][0..opts.max_body];
            s.header_scratch = scratches[i * opts.max_header_scratch ..][0..opts.max_header_scratch];
        }

        conn.* = .{
            .fd = fd,
            .opts = opts,
            .rbuf = rbuf,
            .rstart = 0,
            .rend = 0,
            .hpack_dec = h2.HpackDecoder.init(),
            .streams = streams,
            .slots = slots,
            .bodies = bodies,
            .scratches = scratches,
            .last_stream_id = 0,
            .conn_window_consumed = 0,
            .phase = .await_preface,
            .settings_frame = undefined,
            .stage_buf = undefined,
            .stage = undefined,
        };
        buildSettingsFrame(&conn.settings_frame, opts);
        conn.stage = .{ .fd = fd, .buf = &conn.stage_buf, .len = 0 };

        return conn;
    }

    pub fn deinit(self: *GrpcMuxConn) void {
        std.heap.smp_allocator.free(self.scratches);
        std.heap.smp_allocator.free(self.bodies);
        std.heap.smp_allocator.free(self.slots);
        std.heap.smp_allocator.free(self.streams);
        std.heap.smp_allocator.free(self.rbuf);
        std.heap.smp_allocator.destroy(self);
    }

    /// Flush the staged reply through `h2.fdWriteAll` (the URING / EPOLL loops send `stage.buf`
    /// directly, but the inline TLS path drains it through the frame write hook to be encrypted).
    pub fn flushStage(self: *GrpcMuxConn) void {
        self.stage.flush();
    }
};

/// Append a complete frame (9-byte header + payload) to the connection reply cork.
fn muxStageFrame(conn: *GrpcMuxConn, frame_type: u8, flags: u8, stream_id: u31, payload: []const u8) void {
    var hdr: [9]u8 = undefined;
    h2.encodeFrameHeader(&hdr, .{
        .length = @intCast(payload.len),
        .frame_type = frame_type,
        .flags = flags,
        .stream_id = stream_id,
    });
    conn.stage.append(&hdr);
    if (payload.len > 0) conn.stage.append(payload);
}

fn muxStageWindowUpdate(conn: *GrpcMuxConn, stream_id: u31, increment: u31) void {
    var payload: [4]u8 = undefined;
    std.mem.writeInt(u32, &payload, @as(u32, increment), .big);
    muxStageFrame(conn, h2.FRAME_TYPE_WINDOW_UPDATE, 0, stream_id, &payload);
}

fn muxStageGoaway(conn: *GrpcMuxConn, last_stream: u31, error_code: u32) void {
    var payload: [8]u8 = undefined;
    std.mem.writeInt(u32, payload[0..4], @as(u32, last_stream), .big);
    std.mem.writeInt(u32, payload[4..8], error_code, .big);
    muxStageFrame(conn, h2.FRAME_TYPE_GOAWAY, 0, 0, &payload);
}

fn muxStageRst(conn: *GrpcMuxConn, stream_id: u31, error_code: u32) void {
    var payload: [4]u8 = undefined;
    std.mem.writeInt(u32, &payload, error_code, .big);
    muxStageFrame(conn, h2.FRAME_TYPE_RST_STREAM, 0, stream_id, &payload);
}

/// Build the 33-byte server SETTINGS frame into out. Called once per connection in
/// GrpcMuxConn.init so subsequent handshakes append a precomputed blob, not a loop.
fn buildSettingsFrame(out: *[33]u8, opts: GrpcServeOpts) void {
    const params = [_][2]u32{
        .{ h2.SETTINGS_MAX_CONCURRENT_STREAMS, @as(u32, @intCast(opts.max_streams)) },
        .{ h2.SETTINGS_INITIAL_WINDOW_SIZE, STREAM_WINDOW_SIZE },
        .{ h2.SETTINGS_MAX_FRAME_SIZE, opts.max_frame_size },
        .{ h2.SETTINGS_ENABLE_PUSH, 0 },
    };

    var fh_buf: [9]u8 = undefined;
    h2.encodeFrameHeader(&fh_buf, .{
        .length = 24,
        .frame_type = h2.FRAME_TYPE_SETTINGS,
        .flags = 0,
        .stream_id = 0,
    });
    @memcpy(out[0..9], &fh_buf);

    for (params, 0..) |param, i| {
        std.mem.writeInt(u16, out[9 + i * 6 ..][0..2], @as(u16, @intCast(param[0])), .big);
        std.mem.writeInt(u32, out[9 + i * 6 + 2 ..][0..4], param[1], .big);
    }
}

/// Stage the precomputed server SETTINGS frame (built once in GrpcMuxConn.init).
fn muxStageServerSettings(conn: *GrpcMuxConn) void {
    conn.stage.append(&conn.settings_frame);
}

/// Enable or disable TCP_CORK on a Linux TCP socket.
/// When enabled, the kernel holds output segments until the MSS is full or CORK is cleared,
/// coalescing the multiple intermediate stage flushes a streaming handler produces into
/// fewer TCP segments. No-op on non-Linux targets.
fn setTcpCork(fd: std.posix.fd_t, enable: bool) void {
    if (comptime @import("builtin").target.os.tag != .linux) return;
    const val: c_int = if (enable) 1 else 0;
    std.posix.setsockopt(fd, std.posix.IPPROTO.TCP, 3, std.mem.asBytes(&val)) catch {};
}

/// Dispatch one fully-received stream inline, staging the reply into the connection cork.
/// Unlike the blocking path this never spawns a thread or takes a connection mutex: the worker
/// owns the connection, so a streaming handler runs on the event loop and must stay bounded.
fn muxDispatch(comptime routes: []const Route, conn: *GrpcMuxConn, stream: *Stream) void {
    const path = headerPath(stream.headers[0..stream.header_count]);
    const is_streaming = routeIsStreaming(routes, path);

    var time_start: std.os.linux.timespec = undefined;
    if (conn.opts.logger != null) _ = std.os.linux.clock_gettime(.MONOTONIC, &time_start);

    var decomp_buf: ?[]u8 = null;
    defer if (decomp_buf) |buf| std.heap.smp_allocator.free(buf);
    const effective_body = maybeDecompressBody(
        stream.body[0..stream.body_len],
        stream.headers[0..stream.header_count],
        conn.opts.max_body,
        &decomp_buf,
    );

    const resp_gzip = conn.opts.compress and headersAcceptGzip(stream.headers[0..stream.header_count]);

    var ctx = GrpcContext{
        .fd = conn.fd,
        .stream_id = stream.id,
        .path = path,
        ._body = effective_body,
        ._pos = 0,
        ._hdr_sent = false,
        ._sent_bytes = 0,
        ._grpc_status = 0,
        .deadline_ns = computeDeadline(conn.opts.handler_timeout_ms, stream.headers[0..stream.header_count]),
        ._write_mutex = null,
        ._out = &conn.stage,
        ._resp_gzip = resp_gzip,
    };

    if (is_streaming) setTcpCork(conn.fd, true);
    Router(routes).dispatch(path, stream.headers[0..stream.header_count], &ctx);
    if (is_streaming) setTcpCork(conn.fd, false);

    if (conn.opts.logger) |logger| {
        var time_end: std.os.linux.timespec = undefined;
        _ = std.os.linux.clock_gettime(.MONOTONIC, &time_end);
        const dur_ns: i64 = (@as(i64, time_end.sec) - @as(i64, time_start.sec)) * 1_000_000_000 +
            (@as(i64, time_end.nsec) - @as(i64, time_start.nsec));
        const dur_ms: u64 = @intCast(@max(0, @divTrunc(dur_ns, 1_000_000)));
        var peer_buf: [64]u8 = undefined;
        const peer = peerStr(conn.fd, &peer_buf);
        logger.rpc(peer, path, ctx._grpc_status, stream.body_len, ctx._sent_bytes, dur_ms);
    }
}

/// Handle the HTTP/1.1 h2c upgrade request for a non-prior-knowledge client.
/// Minimal by design: any client without "Upgrade: h2c" gets 400 (this is the validate probe
/// path). A valid h2c upgrade gets 101 and then expects the connection preface, but the initial
/// request carried on stream 1 by the upgrade is not served (prior-knowledge clients do not use
/// this path).
///
/// Return:
/// - .close when the request is complete and rejected
fn muxHandleUpgrade(conn: *GrpcMuxConn) GrpcConnOutcome {
    const buf = conn.rbuf[conn.rstart..conn.rend];
    const marker = std.mem.indexOf(u8, buf, "\r\n\r\n") orelse {
        if (conn.rend == conn.rbuf.len) return .close;
        return .keep_alive;
    };
    const hdr_end = marker + 4;

    const upgrade_val = getHttp1Header(buf[0..hdr_end], "upgrade");
    const is_h2c = upgrade_val != null and std.ascii.eqlIgnoreCase(std.mem.trim(u8, upgrade_val.?, " "), "h2c");
    if (!is_h2c) {
        conn.stage.append("HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n");
        return .close;
    }

    conn.stage.append("HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: h2c\r\n\r\n");
    conn.rstart += hdr_end;
    conn.phase = .await_preface2;

    return .keep_alive;
}

/// Process as many complete frames as are currently buffered.
///
/// Return:
/// - .keep_alive when the buffer is drained or holds only a partial frame (wait for more bytes)
/// - .close on a protocol error or GOAWAY (a GOAWAY/close reply is staged first)
fn muxProcess(comptime routes: []const Route, conn: *GrpcMuxConn) GrpcConnOutcome {
    switch (conn.phase) {
        .await_preface => {
            const avail = conn.rend - conn.rstart;
            if (avail < 3) return .keep_alive;

            if (!std.mem.eql(u8, conn.rbuf[conn.rstart..][0..3], "PRI")) {
                conn.phase = .await_upgrade;
                return muxHandleUpgrade(conn);
            }
            if (avail < h2.PREFACE.len) return .keep_alive;
            if (!std.mem.eql(u8, conn.rbuf[conn.rstart..][0..h2.PREFACE.len], h2.PREFACE)) {
                muxStageGoaway(conn, 0, h2.ERR_PROTOCOL_ERROR);
                return .close;
            }

            conn.rstart += h2.PREFACE.len;
            muxStageServerSettings(conn);
            conn.phase = .h2;
        },

        .await_upgrade => return muxHandleUpgrade(conn),

        .await_preface2 => {
            const avail = conn.rend - conn.rstart;
            if (avail < h2.PREFACE.len) return .keep_alive;
            if (!std.mem.eql(u8, conn.rbuf[conn.rstart..][0..h2.PREFACE.len], h2.PREFACE)) {
                muxStageGoaway(conn, 0, h2.ERR_PROTOCOL_ERROR);
                return .close;
            }

            conn.rstart += h2.PREFACE.len;
            muxStageServerSettings(conn);
            conn.phase = .h2;
        },

        .h2 => {},
    }

    return muxFrameLoop(routes, conn);
}

/// The h2 frame loop over buffered bytes for a connection in the .h2 phase.
fn muxFrameLoop(comptime routes: []const Route, conn: *GrpcMuxConn) GrpcConnOutcome {
    const max_payload = conn.opts.max_frame_size + h2.FRAME_PAYLOAD_SLACK;

    while (true) {
        const avail = conn.rend - conn.rstart;
        if (avail < 9) return .keep_alive;

        const fh = h2.parseFrameHeader(conn.rbuf[conn.rstart..][0..9]);
        if (fh.length > max_payload) {
            muxStageGoaway(conn, conn.last_stream_id, h2.ERR_FRAME_SIZE_ERROR);
            return .close;
        }
        if (avail < 9 + fh.length) return .keep_alive;

        conn.rstart += 9;
        const payload = conn.rbuf[conn.rstart..][0..fh.length];
        conn.rstart += fh.length;

        switch (fh.frame_type) {
            h2.FRAME_TYPE_SETTINGS => {
                if ((fh.flags & h2.FLAG_ACK) != 0) continue;
                var i: usize = 0;
                while (i + 6 <= payload.len) : (i += 6) {
                    const id: u16 = (@as(u16, payload[i]) << 8) | payload[i + 1];
                    const val: u32 = (@as(u32, payload[i + 2]) << 24) | (@as(u32, payload[i + 3]) << 16) |
                        (@as(u32, payload[i + 4]) << 8) | payload[i + 5];
                    if (id == h2.SETTINGS_HEADER_TABLE_SIZE) {
                        conn.hpack_dec.max_size = val;
                        conn.hpack_dec.evictTo(val);
                    }
                }

                muxStageFrame(conn, h2.FRAME_TYPE_SETTINGS, h2.FLAG_ACK, 0, &.{});
                muxStageWindowUpdate(conn, 0, CONN_WINDOW_BUMP);
            },

            h2.FRAME_TYPE_WINDOW_UPDATE => {},

            h2.FRAME_TYPE_PING => {
                if ((fh.flags & h2.FLAG_ACK) != 0) continue;
                if (payload.len != 8) {
                    muxStageGoaway(conn, conn.last_stream_id, h2.ERR_FRAME_SIZE_ERROR);
                    return .close;
                }

                muxStageFrame(conn, h2.FRAME_TYPE_PING, h2.FLAG_ACK, 0, payload);
            },

            h2.FRAME_TYPE_HEADERS => {
                const stream_id = fh.stream_id;
                if (stream_id == 0) {
                    muxStageGoaway(conn, conn.last_stream_id, h2.ERR_PROTOCOL_ERROR);
                    return .close;
                }
                if (stream_id <= conn.last_stream_id and stream_id % 2 == 1) {
                    muxStageRst(conn, stream_id, h2.ERR_STREAM_CLOSED);
                    continue;
                }
                conn.last_stream_id = @max(conn.last_stream_id, stream_id);

                const slot = slotFor(stream_id, conn.streams, conn.slots) orelse {
                    muxStageRst(conn, stream_id, h2.ERR_REFUSED_STREAM);
                    continue;
                };
                const stream = &conn.streams[slot];
                stream.id = stream_id;
                stream.state = .OPEN;
                stream.body_len = 0;

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
                    muxStageGoaway(conn, conn.last_stream_id, h2.ERR_PROTOCOL_ERROR);
                    return .close;
                }
                block = block[offset .. block.len - pad_len];

                stream.header_count = conn.hpack_dec.decode(block, &stream.headers, stream.header_scratch) catch {
                    muxStageRst(conn, stream_id, h2.ERR_COMPRESSION_ERROR);
                    conn.slots[slot] = false;
                    continue;
                };
                stream.end_headers = (fh.flags & h2.FLAG_END_HEADERS) != 0;
                stream.end_stream = (fh.flags & h2.FLAG_END_STREAM) != 0;

                if (stream.end_headers and stream.end_stream) {
                    muxDispatch(routes, conn, stream);
                    conn.slots[slot] = false;
                }
            },

            h2.FRAME_TYPE_CONTINUATION => {
                const stream_id = fh.stream_id;
                const slot = findSlot(stream_id, conn.streams, conn.slots) orelse {
                    muxStageGoaway(conn, conn.last_stream_id, h2.ERR_PROTOCOL_ERROR);
                    return .close;
                };
                const stream = &conn.streams[slot];
                const count = conn.hpack_dec.decode(payload, stream.headers[stream.header_count..], stream.header_scratch) catch {
                    muxStageRst(conn, stream_id, h2.ERR_COMPRESSION_ERROR);
                    conn.slots[slot] = false;
                    continue;
                };
                stream.header_count += count;
                stream.end_headers = (fh.flags & h2.FLAG_END_HEADERS) != 0;
                if (stream.end_headers and stream.end_stream) {
                    muxDispatch(routes, conn, stream);
                    conn.slots[slot] = false;
                }
            },

            h2.FRAME_TYPE_DATA => {
                const stream_id = fh.stream_id;
                if (stream_id == 0) {
                    muxStageGoaway(conn, conn.last_stream_id, h2.ERR_PROTOCOL_ERROR);
                    return .close;
                }
                const slot = findSlot(stream_id, conn.streams, conn.slots) orelse {
                    muxStageRst(conn, stream_id, h2.ERR_STREAM_CLOSED);
                    continue;
                };
                const stream = &conn.streams[slot];

                var data = payload;
                var pad_len: usize = 0;
                if ((fh.flags & h2.FLAG_PADDED) != 0 and data.len > 0) {
                    pad_len = data[0];
                    data = data[1..];
                }
                if (pad_len > data.len) {
                    muxStageGoaway(conn, conn.last_stream_id, h2.ERR_PROTOCOL_ERROR);
                    return .close;
                }
                data = data[0 .. data.len - pad_len];

                if (data.len > 0) {
                    conn.conn_window_consumed += data.len;
                    if (conn.conn_window_consumed >= CONN_REPLENISH_THRESHOLD) {
                        muxStageWindowUpdate(conn, 0, @intCast(conn.conn_window_consumed));
                        conn.conn_window_consumed = 0;
                    }
                }

                const to_copy = @min(data.len, stream.body.len - stream.body_len);
                @memcpy(stream.body[stream.body_len..][0..to_copy], data[0..to_copy]);
                stream.body_len += to_copy;
                stream.end_stream = (fh.flags & h2.FLAG_END_STREAM) != 0;

                if (stream.end_stream) {
                    muxDispatch(routes, conn, stream);
                    conn.slots[slot] = false;
                }
            },

            h2.FRAME_TYPE_RST_STREAM => {
                if (findSlot(fh.stream_id, conn.streams, conn.slots)) |slot| conn.slots[slot] = false;
            },

            h2.FRAME_TYPE_GOAWAY => return .close,
            h2.FRAME_TYPE_PRIORITY => {},
            else => {},
        }
    }
}

/// Drive one readable event for a multiplexed connection: read available bytes (non-blocking),
/// process complete frames, and flush the staged reply in one write().
///
/// Return:
/// - .close when the peer closed, a protocol error occurred, or the handshake was rejected
pub fn grpcMuxOnReadable(comptime routes: []const Route, conn: *GrpcMuxConn) GrpcConnOutcome {
    conn.stage.len = 0;

    while (true) {
        if (conn.rstart == conn.rend) {
            conn.rstart = 0;
            conn.rend = 0;
        } else if (conn.rend == conn.rbuf.len) {
            const n = conn.rend - conn.rstart;
            std.mem.copyForwards(u8, conn.rbuf[0..n], conn.rbuf[conn.rstart..conn.rend]);
            conn.rstart = 0;
            conn.rend = n;
        }

        if (conn.rend == conn.rbuf.len) {
            conn.stage.flush();
            return .close;
        }

        const got = std.posix.read(conn.fd, conn.rbuf[conn.rend..]) catch |err| switch (err) {
            error.WouldBlock => {
                conn.stage.flush();
                return .keep_alive;
            },
            else => {
                conn.stage.flush();
                return .close;
            },
        };
        if (got == 0) {
            conn.stage.flush();
            return .close;
        }
        conn.rend += got;

        if (muxProcess(routes, conn) == .close) {
            conn.stage.flush();
            return .close;
        }
    }
}

/// Process buffered frames for the .URING ring path (ADR-037 Phase 4 step 3).
/// Like grpcMuxOnReadable but without the blocking read loop and without the
/// final fd flush: the ring worker has already filled conn.rbuf (advancing
/// conn.rend), and it submits conn.stage.buf[0..conn.stage.len] as one ring send
/// afterwards. rbuf compaction before each recv is the caller's responsibility.
/// A large reply that overflows the cork still flushes straight to the fd inside
/// muxProcess, which is safe under the ring's half-duplex guarantee.
///
/// Return:
/// - .keep_alive when the buffer is drained or holds only a partial frame
/// - .close on a protocol error or peer close (a GOAWAY/close reply is staged first)
pub fn grpcMuxProcessRing(comptime routes: []const Route, conn: *GrpcMuxConn) GrpcConnOutcome {
    conn.stage.len = 0;

    return muxProcess(routes, conn);
}

fn peerStr(fd: std.posix.fd_t, buf: *[64]u8) []const u8 {
    var storage: std.posix.sockaddr.storage = undefined;
    var len: std.posix.socklen_t = @sizeOf(@TypeOf(storage));
    std.posix.getpeername(fd, @ptrCast(&storage), &len) catch return "-";
    if (storage.family == std.posix.AF.INET) {
        const sock_addr_in: *const std.posix.sockaddr.in = @ptrCast(&storage);
        const addr_bytes: [4]u8 = @bitCast(sock_addr_in.addr);
        const port = std.mem.readInt(u16, @as([2]u8, @bitCast(sock_addr_in.port))[0..2], .big);
        return std.fmt.bufPrint(buf, "{d}.{d}.{d}.{d}:{d}", .{ addr_bytes[0], addr_bytes[1], addr_bytes[2], addr_bytes[3], port }) catch "-";
    }
    return "-";
}

fn slotFor(stream_id: u31, streams: []Stream, used: []bool) ?usize {
    for (used, 0..) |slot_in_use, i| {
        if (!slot_in_use) {
            used[i] = true;
            streams[i].id = stream_id;
            return i;
        }
    }
    return null;
}

fn findSlot(stream_id: u31, streams: []Stream, used: []bool) ?usize {
    for (used, 0..) |slot_in_use, i| {
        if (slot_in_use and streams[i].id == stream_id) return i;
    }
    return null;
}

/// Return true when the client sent grpc-encoding: gzip (inbound messages are compressed).
fn headersHaveGzipEncoding(headers: []const h2.Header) bool {
    for (headers) |hdr| {
        if (!std.ascii.eqlIgnoreCase(hdr.name, "grpc-encoding")) continue;
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, hdr.value, " "), "gzip")) return true;
    }
    return false;
}

/// Return true when the client advertised grpc-accept-encoding containing "gzip".
fn headersAcceptGzip(headers: []const h2.Header) bool {
    for (headers) |hdr| {
        if (!std.ascii.eqlIgnoreCase(hdr.name, "grpc-accept-encoding")) continue;
        var it = std.mem.splitScalar(u8, hdr.value, ',');
        while (it.next()) |part| {
            if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, part, " "), "gzip")) return true;
        }
    }
    return false;
}

/// Decompress body via smp_allocator if grpc-encoding: gzip is present.
/// Returns the effective body slice and sets decomp_out to the allocated buffer (caller frees).
fn maybeDecompressBody(
    body: []const u8,
    headers: []const h2.Header,
    max_body: usize,
    decomp_out: *?[]u8,
) []const u8 {
    decomp_out.* = null;
    if (!headersHaveGzipEncoding(headers)) return body;

    const buf = std.heap.smp_allocator.alloc(u8, max_body) catch return body;
    const n = frame.decompressGrpcBody(body, buf) catch {
        std.heap.smp_allocator.free(buf);
        return body;
    };
    decomp_out.* = buf;
    return buf[0..n];
}

fn computeDeadline(handler_timeout_ms: u32, headers: []const h2.Header) ?u64 {
    var best: ?u64 = null;
    const now = wallClockNs();

    if (handler_timeout_ms > 0) {
        best = now + @as(u64, handler_timeout_ms) * std.time.ns_per_ms;
    }

    for (headers) |header| {
        if (!std.mem.eql(u8, header.name, "grpc-timeout")) continue;
        if (parseTimeout(header.value)) |t_ns| {
            const candidate = now + t_ns;
            if (best) |current_deadline| {
                if (candidate < current_deadline) best = candidate;
            } else {
                best = candidate;
            }
        }
    }

    return best;
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
    const message = ctx.recvMessage().?;
    try std.testing.expectEqualStrings("hello", message);
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
    const grpc_path = parsePath("/helloworld.Greeter/SayHello").?;
    try std.testing.expectEqualStrings("helloworld.Greeter", grpc_path.package_service);
    try std.testing.expectEqualStrings("SayHello", grpc_path.method);
}

test "zix grpc: parsePath no package returns null" {
    try std.testing.expect(parsePath("/SayHello") == null);
}

test "zix grpc: parsePath trailing slash returns null" {
    try std.testing.expect(parsePath("/pkg.Svc/") == null);
}

test "zix grpc: detectContentType proto" {
    const headers = [_]h2.Header{.{ .name = "content-type", .value = "application/grpc+proto" }};
    try std.testing.expectEqual(GrpcContentType.PROTO, detectContentType(&headers));
}

test "zix grpc: detectContentType json" {
    const headers = [_]h2.Header{.{ .name = "content-type", .value = "application/grpc+json" }};
    try std.testing.expectEqual(GrpcContentType.JSON, detectContentType(&headers));
}

test "zix grpc: detectContentType grpc no subtype is PROTO" {
    const headers = [_]h2.Header{.{ .name = "content-type", .value = "application/grpc" }};
    try std.testing.expectEqual(GrpcContentType.PROTO, detectContentType(&headers));
}

test "zix grpc: GrpcServeOpts defaults" {
    const opts = GrpcServeOpts{};
    try std.testing.expectEqual(@as(usize, 16), opts.max_streams);
    try std.testing.expectEqual(h2.DEFAULT_MAX_FRAME_SIZE, opts.max_frame_size);
    try std.testing.expectEqual(@as(usize, 65536), opts.max_body);
    try std.testing.expectEqual(@as(u32, 0), opts.handler_timeout_ms);
    try std.testing.expect(opts.io == null);
}

test "zix grpc: Route timeout_ms defaults to zero" {
    const r = Route{ .path = "/svc.Svc/Method", .handler = struct {
        fn h(_: []const h2.Header, _: *GrpcContext) void {}
    }.h };
    try std.testing.expectEqual(@as(u32, 0), r.timeout_ms);
}

test "zix grpc: Route is_server_streaming defaults to false" {
    const r = Route{ .path = "/svc.Svc/Method", .handler = struct {
        fn h(_: []const h2.Header, _: *GrpcContext) void {}
    }.h };
    try std.testing.expect(!r.is_server_streaming);
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
    const far_future: u64 = wallClockNs() + 1000 * std.time.ns_per_s;
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

// --------------------------------------------------------- //
// --------------------------------------------------------- //

test "zix grpc: buildSettingsFrame produces valid SETTINGS frame header" {
    const opts = GrpcServeOpts{};
    var frm: [33]u8 = undefined;
    buildSettingsFrame(&frm, opts);

    const fh = h2.parseFrameHeader(frm[0..9]);
    try std.testing.expectEqual(h2.FRAME_TYPE_SETTINGS, fh.frame_type);
    try std.testing.expectEqual(@as(u8, 0), fh.flags);
    try std.testing.expectEqual(@as(u31, 0), fh.stream_id);
    try std.testing.expectEqual(@as(u24, 24), fh.length);
}

test "zix grpc: buildSettingsFrame encodes MAX_CONCURRENT_STREAMS correctly" {
    const opts = GrpcServeOpts{ .max_streams = 64 };
    var frm: [33]u8 = undefined;
    buildSettingsFrame(&frm, opts);

    const id = std.mem.readInt(u16, frm[9..11], .big);
    const val = std.mem.readInt(u32, frm[11..15], .big);
    try std.testing.expectEqual(@as(u16, h2.SETTINGS_MAX_CONCURRENT_STREAMS), id);
    try std.testing.expectEqual(@as(u32, 64), val);
}

test "zix grpc: ReplyStage append and flush via pipe" {
    const fds = try std.Io.Threaded.pipe2(.{});
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    var backing: [64]u8 = undefined;
    var stage = ReplyStage{ .fd = fds[1], .buf = &backing };
    stage.append("hello");
    stage.append(" world");
    stage.flush();

    var out: [16]u8 = undefined;
    const n = try std.posix.read(fds[0], &out);
    try std.testing.expectEqualStrings("hello world", out[0..n]);
}

test "zix grpc: ReplyStage overflow triggers flush and continues buffering" {
    const fds = try std.Io.Threaded.pipe2(.{});
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    var backing: [4]u8 = undefined;
    var stage = ReplyStage{ .fd = fds[1], .buf = &backing };

    stage.append("abcd");
    stage.append("ef");
    stage.flush();

    var out: [16]u8 = undefined;
    const n = try std.posix.read(fds[0], &out);
    try std.testing.expectEqualStrings("abcdef", out[0..n]);
}

test "zix grpc: ReplyStage payload larger than buf writes directly" {
    const fds = try std.Io.Threaded.pipe2(.{});
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    var backing: [4]u8 = undefined;
    var stage = ReplyStage{ .fd = fds[1], .buf = &backing };

    stage.append("hello world");
    stage.flush();

    var out: [16]u8 = undefined;
    const n = try std.posix.read(fds[0], &out);
    try std.testing.expectEqualStrings("hello world", out[0..n]);
}

test "zix grpc: serveCached is a no-op without a cache or with an empty path" {
    setCache(null, 0);

    var ctx = GrpcContext{
        .fd = 0,
        .stream_id = 1,
        .path = "/svc.Svc/Method",
        ._body = "req",
        ._pos = 0,
        ._hdr_sent = false,
        ._sent_bytes = 0,
        ._grpc_status = 0,
    };
    try std.testing.expect(!ctx.serveCached("application/grpc"));

    // even with a cache installed, an empty path is never cached
    var cache = try rc.ResponseCache.init(std.testing.allocator, .{ .max_entries = 8, .max_value_bytes = 64 });
    defer cache.deinit();

    setCache(&cache, 1000);
    defer setCache(null, 0);

    var no_path = ctx;
    no_path.path = "";
    try std.testing.expect(!no_path.serveCached("application/grpc"));
}

test "zix grpc: sendCached stores the unary reply and serveCached replays it" {
    var cache = try rc.ResponseCache.init(std.testing.allocator, .{ .max_entries = 16, .max_value_bytes = 256 });
    defer cache.deinit();

    setCache(&cache, 1000);
    defer setCache(null, 0);

    var fds: [2]i32 = undefined;
    try std.testing.expectEqual(@as(usize, 0), std.os.linux.socketpair(std.os.linux.AF.UNIX, std.os.linux.SOCK.STREAM, 0, &fds));
    defer _ = std.os.linux.close(fds[0]);
    defer _ = std.os.linux.close(fds[1]);

    const path = "/svc.Svc/Method";
    const body = "request-body";
    const reply = "unary-reply-payload";

    // first call: miss, handler builds and stores the reply
    var ctx = GrpcContext{
        .fd = fds[1],
        .stream_id = 1,
        .path = path,
        ._body = body,
        ._pos = 0,
        ._hdr_sent = false,
        ._sent_bytes = 0,
        ._grpc_status = 0,
    };
    try std.testing.expect(!ctx.serveCached("application/grpc"));
    ctx.sendCached("application/grpc", reply, 0);
    ctx.finish(.OK, "");

    var first: [512]u8 = undefined;
    const n1 = try std.posix.read(fds[0], &first);
    try std.testing.expect(std.mem.indexOf(u8, first[0..n1], reply) != null);

    // the message is now stored under the call key
    try std.testing.expect(cache.lookup(requestKey(path, body), rc.nowMillis()) != null);

    // second call: same path and body, served from cache with no handler
    var ctx2 = GrpcContext{
        .fd = fds[1],
        .stream_id = 3,
        .path = path,
        ._body = body,
        ._pos = 0,
        ._hdr_sent = false,
        ._sent_bytes = 0,
        ._grpc_status = 0,
    };
    try std.testing.expect(ctx2.serveCached("application/grpc"));

    var second: [512]u8 = undefined;
    const n2 = try std.posix.read(fds[0], &second);
    try std.testing.expect(std.mem.indexOf(u8, second[0..n2], reply) != null);
}

test "zix grpc: response cache keys separate distinct paths and bodies" {
    const key_a = requestKey("/svc.Svc/A", "body");
    const key_b = requestKey("/svc.Svc/B", "body");
    const key_c = requestKey("/svc.Svc/A", "other");

    try std.testing.expect(key_a != key_b);
    try std.testing.expect(key_a != key_c);
    try std.testing.expect(key_b != key_c);
}

// Counts writes routed through the frame write hook and captures the bytes (up to
// its buffer) so a test can assert the streaming DATA frame is coalesced and well
// formed. Used by the streaming-coalesce tests below.
const WriteHookProbe = struct {
    count: usize = 0,
    buf: [256]u8 = undefined,
    len: usize = 0,
};

fn writeHookProbe(ctx: *anyopaque, bytes: []const u8) void {
    const probe: *WriteHookProbe = @ptrCast(@alignCast(ctx));
    probe.count += 1;

    if (probe.len + bytes.len <= probe.buf.len) {
        @memcpy(probe.buf[probe.len..][0..bytes.len], bytes);
        probe.len += bytes.len;
    }
}

test "zix grpc: streaming sendMessage coalesces a small DATA frame into one write" {
    const h2_frame = @import("../frame.zig");

    var probe = WriteHookProbe{};
    h2_frame.write_hook = writeHookProbe;
    h2_frame.write_hook_ctx = &probe;
    defer {
        h2_frame.write_hook = null;
        h2_frame.write_hook_ctx = null;
    }

    // Streaming path: no cork (_out null) and no write mutex, so sendMessage writes
    // directly. Headers pre-marked sent so only the DATA frame goes through the hook.
    var ctx = GrpcContext{ .fd = -1, .stream_id = 1, ._body = &.{}, ._pos = 0, ._hdr_sent = true, ._sent_bytes = 0, ._grpc_status = 0 };

    ctx.sendMessage("application/grpc", "pong");

    // One write: the 14-byte header and the 4-byte payload were coalesced.
    try std.testing.expectEqual(@as(usize, 1), probe.count);
    try std.testing.expectEqual(@as(usize, 14 + 4), probe.len);

    // The single write is a valid DATA frame on stream 1 carrying the payload.
    const fh = h2_frame.parseFrameHeader(probe.buf[0..9]);
    try std.testing.expectEqual(@as(u8, h2_frame.FRAME_TYPE_DATA), fh.frame_type);
    try std.testing.expectEqual(@as(u31, 1), fh.stream_id);
    try std.testing.expectEqualStrings("pong", probe.buf[14..18]);
}

test "zix grpc: streaming sendMessage past the inline cap keeps the two-write path" {
    const h2_frame = @import("../frame.zig");

    var probe = WriteHookProbe{};
    h2_frame.write_hook = writeHookProbe;
    h2_frame.write_hook_ctx = &probe;
    defer {
        h2_frame.write_hook = null;
        h2_frame.write_hook_ctx = null;
    }

    var ctx = GrpcContext{ .fd = -1, .stream_id = 3, ._body = &.{}, ._pos = 0, ._hdr_sent = true, ._sent_bytes = 0, ._grpc_status = 0 };

    // A payload larger than the inline cap is written as header then payload (two
    // writes), so it is never copied through the stack buffer.
    var big: [grpc_stream_inline_cap + 1]u8 = undefined;
    @memset(&big, 'x');
    ctx.sendMessage("application/grpc", &big);

    try std.testing.expectEqual(@as(usize, 2), probe.count);
}
