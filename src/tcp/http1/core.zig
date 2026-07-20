//! zix http1 core: zero-alloc HTTP/1.x request parsing and response writing.
//! All parsing operates on caller-owned buffers. No std.http dependency.

const std = @import("std");
const cache = @import("../../utils/response_cache.zig");
const compression = @import("../../utils/compression/compression.zig");
const slab_mem = @import("../../multiplexers/slab.zig");
const parser = @import("parser.zig");
const ZIG_SEMVER = @import("../../lib.zig").ZIG_SEMVER;
pub const Request = @import("request.zig").Request;
pub const Response = @import("response.zig").Response;
pub const Context = @import("context.zig").Context;

/// Shared per-connection scratch size: the blocking-loop receive buffer, the
/// chunked-body reader, and the TLS payload buffers all use it.
pub const BUF_SIZE: usize = 16 * 1024;
const GZIP_OUT_SIZE: usize = 256 * 1024;

/// Scratch buffer for building one HTTP status line plus its headers.
pub const HEADER_BUF_SIZE: usize = 256;

/// Inline write fast-path buffer. A response whose status line, headers, and
/// body all fit here is sent in one direct write, skipping the iovec scatter
/// path. The body threshold is this minus HEADER_BUF_SIZE.
const SMALL_BODY_INLINE_BUF: usize = 4096;

/// Body read chunk for the ASYNC serve loop: bytes drained per recv after the head.
const ASYNC_BODY_CHUNK: usize = 8 * 1024;

// Head parsing lives in parser.zig, re-exported here so every dispatch loop
// and call site keeps the same core.* names.
pub const ParseResult = parser.ParseResult;
pub const ParsedHead = parser.ParsedHead;
pub const Range = parser.Range;
pub const HeaderSpan = parser.HeaderSpan;
pub const SPAN_UNSCANNED = parser.SPAN_UNSCANNED;
pub const SPAN_ABSENT = parser.SPAN_ABSENT;
pub const parseHeadAt = parser.parseHeadAt;
pub const parseHead = parser.parseHead;
pub const getHeader = parser.getHeader;
pub const acceptEncoding = parser.acceptEncoding;
pub const queryParam = parser.queryParam;
pub const percentDecode = parser.percentDecode;
pub const parseRange = parser.parseRange;

/// Handler signature: the ergonomic request, response, context trio. All slices
/// the request exposes are valid only for the duration of the call. A returned
/// error is completed by the engine as a 500 when the handler wrote nothing.
pub const HandlerFn = *const fn (
    req: *Request,
    res: *Response,
    ctx: *Context,
) anyerror!void;

/// Build the request, response, and context trio over a parsed request and hand
/// it to the handler. One place builds the trio, so every dispatch model invokes
/// a handler the same way. On an error return the response is completed with a
/// 500, but only when the handler wrote nothing, so a handler that already sent a
/// response and then failed does not corrupt the stream.
///
/// Param:
/// handler_fn - HandlerFn (the route or top-level handler)
/// head - *const ParsedHead (borrows the receive buffer)
/// body - []const u8 (already drained by the engine)
/// fd - std.posix.fd_t (the connection)
/// io - std.Io (the worker io, carried for ctx and an inline driver call)
/// allocator - std.mem.Allocator (per-request scratch, reset by the engine)
///
/// Return:
/// - void
pub inline fn invokeHandler(
    handler_fn: HandlerFn,
    head: *const ParsedHead,
    body: []const u8,
    fd: std.posix.fd_t,
    io: std.Io,
    allocator: std.mem.Allocator,
) void {
    var req = Request.init(head, body, fd);
    var res = Response.init(fd, io, allocator);
    var ctx = Context.init(io, allocator, fd);

    handler_fn(&req, &res, &ctx) catch {
        if (!res.sent) sendSimpleFD(fd, 500, "text/plain", "Internal Server Error") catch {};
    };
}

/// Options for serveConn.
pub const ServeOpts = struct {
    nodelay: bool = true,
    /// Per-handler execution budget in milliseconds. 0 = no deadline armed.
    handler_timeout_ms: u32 = 0,
    /// SO_RCVBUF applied on the large-body path only (a body larger than the read buffer). 0 leaves
    /// the kernel default. Widens the receive window so a large upload drains in fewer cycles.
    large_body_rcvbuf: usize = 0,
};

/// SO_RCVBUF for the large-body path under the event-loop models (.EPOLL / .URING), set once per
/// worker from config.large_body_rcvbuf. The blocking models carry it on ServeOpts instead. The
/// event-loop request functions do not thread config through, so a threadlocal is the carrier. 0
/// leaves the kernel default.
pub threadlocal var tl_large_body_rcvbuf: usize = 0;

/// Install the large-body SO_RCVBUF for this worker (event-loop models).
pub fn setLargeBodyRcvbuf(bytes: usize) void {
    tl_large_body_rcvbuf = bytes;
}

/// Widen the socket receive buffer (SO_RCVBUF) so a large request body drains in fewer cycles.
/// Applied only on the large-body path (a body bigger than the read buffer), so ordinary small
/// requests keep the kernel default and its autotuning. bytes = 0 leaves the socket untouched.
/// Note: an explicit SO_RCVBUF disables receive autotuning for that socket, which is why it is set
/// only when a large body is actually detected, not at accept.
pub fn setRecvBuf(fd: std.posix.fd_t, bytes: usize) void {
    if (bytes == 0) return;
    if (comptime @import("builtin").target.os.tag == .windows) return;

    const val: c_int = @intCast(@min(bytes, std.math.maxInt(c_int)));
    std.posix.setsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.RCVBUF, std.mem.asBytes(&val)) catch {};
}

// --------------------------------------------------------- //

/// Wall-clock nanoseconds since the epoch (CLOCK_REALTIME).
fn wallClockNs() u64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.REALTIME, &ts);

    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

/// Per-handler deadline, thread-local so each worker tracks its own request.
/// 0 means no deadline is active.
threadlocal var tl_deadline_ns: u64 = 0;

/// Arm or clear the per-handler deadline for the current thread.
/// The server calls this before each dispatch with config.handler_timeout_ms.
/// Handlers may call it to shorten their own budget. ms = 0 clears the deadline.
pub fn setTimeout(ms: u32) void {
    tl_deadline_ns = if (ms == 0)
        0
    else
        wallClockNs() + @as(u64, ms) * std.time.ns_per_ms;
}

/// Whether the current handler's deadline has passed.
/// Always false when no deadline is armed.
pub fn isExpired() bool {
    if (tl_deadline_ns == 0) return false;

    return wallClockNs() >= tl_deadline_ns;
}

// --------------------------------------------------------- //

/// Per-frame callback for an engine-owned WebSocket connection.
/// The engine parses each complete client frame and invokes this for text and
/// binary opcodes. opcode is the raw RFC 6455 opcode value (use the
/// WebSocket.Opcode enum to interpret it). Ping is auto-ponged and close is
/// auto-echoed by the engine, so the callback only ever sees data frames.
///
/// Param:
/// fd - std.posix.fd_t (the connection, write replies with WebSocket.send)
/// opcode - u8 (RFC 6455 opcode, .text or .binary in practice)
/// payload - []const u8 (unmasked frame payload, valid only for this call)
pub const WsFrameFn = *const fn (fd: std.posix.fd_t, opcode: u8, payload: []const u8) void;

const WsPending = struct {
    fd: std.posix.fd_t,
    on_frame: WsFrameFn,
};

/// Set by WebSocket.serve during a handler, read by the EPOLL engine right
/// after the handler returns. Thread-local so each worker hands off only its
/// own connection. The handoff is honored under .EPOLL dispatch only.
threadlocal var tl_ws_pending: ?WsPending = null;

/// Request that the connection on fd be promoted to an engine-owned WebSocket
/// after the current handler returns. WebSocket.serve calls this for you.
pub fn requestWebSocket(fd: std.posix.fd_t, on_frame: WsFrameFn) void {
    tl_ws_pending = .{ .fd = fd, .on_frame = on_frame };
}

/// Take and clear any pending WebSocket promotion for the current thread.
/// The engine calls this after every dispatch.
pub fn takeWebSocket() ?WsPending {
    const pending = tl_ws_pending;
    tl_ws_pending = null;

    return pending;
}

// --------------------------------------------------------- //
// Response cache: per-worker, per-key precomputed response (ADR-036).

/// Per-worker response cache. Set once per worker by the EPOLL engine when
/// config.response_cache is on, null otherwise. When null every cache call below
/// degrades to a no-op, so a handler that uses the cache API still works on a
/// server with caching disabled.
pub threadlocal var tl_cache: ?*cache.ResponseCache = null;

/// Configured default TTL in milliseconds, installed alongside tl_cache. A
/// handler may pass its own TTL or this default via cacheTtl().
pub threadlocal var tl_cache_ttl_ms: u32 = 1000;

/// Install or clear the response cache and its default TTL for this worker.
pub fn setCache(resp_cache: ?*cache.ResponseCache, default_ttl_ms: u32) void {
    tl_cache = resp_cache;
    tl_cache_ttl_ms = default_ttl_ms;
}

/// The configured default cache TTL for this worker, for handlers that want it.
pub fn cacheTtl() u32 {
    return tl_cache_ttl_ms;
}

/// Whether response compression is enabled for this worker. Off unless the server
/// installs it from config.compress. When off, sendNegotiateCachedFD always writes
/// uncompressed.
pub threadlocal var tl_compression: bool = false;

/// Body size floor for compression, installed from config.compression_min_size.
pub threadlocal var tl_compression_min_size: usize = compression.min_size_default;

/// Compressed-output cap, installed from config.compression_max_out. A compressed
/// result above this is discarded and the response is sent uncompressed.
pub threadlocal var tl_compression_max_out: usize = GZIP_OUT_SIZE;

/// Install or clear the compression policy for this worker.
pub fn setCompression(enabled: bool, min_size: usize, max_out: usize) void {
    tl_compression = enabled;
    tl_compression_min_size = min_size;
    tl_compression_max_out = max_out;
}

/// Look up a full cached response for this request. Returns the cached bytes
/// when caching is enabled and a fresh entry exists, else null. The key is
/// hash(method, path, query). Write the returned bytes with writeAllFD.
pub fn cacheLookup(head: *const ParsedHead) ?[]const u8 {
    const c = tl_cache orelse return null;
    const key = cache.hashKey(head.method, head.path, head.query);

    return c.lookup(key, cache.nowMillis());
}

/// Store full response bytes as this request's cached response for ttl_ms.
/// No-op when caching is disabled, the bytes exceed the per-slot cap, or the
/// table is full. The bytes must be a complete HTTP response.
pub fn cacheStore(head: *const ParsedHead, bytes: []const u8, ttl_ms: u32) void {
    const c = tl_cache orelse return;
    const key = cache.hashKey(head.method, head.path, head.query);

    _ = c.store(key, bytes, ttl_ms, cache.nowMillis());
}

/// Look up a cached response for this request under a specific content-encoding (the per-(key,
/// encoding) cache). The compressed and identity representations live in distinct slots, so a gzip
/// request never replays the identity body. Returns the full response bytes, or null.
pub fn cacheLookupEncoded(head: *const ParsedHead, encoding: []const u8) ?[]const u8 {
    const c = tl_cache orelse return null;
    const key = cache.hashKeyEncoded(head.method, head.path, head.query, encoding);

    return c.lookup(key, cache.nowMillis());
}

/// Store full response bytes for this request under a specific content-encoding. The bytes must be a
/// complete HTTP response (status line + headers + the encoded body).
pub fn cacheStoreEncoded(head: *const ParsedHead, encoding: []const u8, bytes: []const u8, ttl_ms: u32) void {
    const c = tl_cache orelse return;
    const key = cache.hashKeyEncoded(head.method, head.path, head.query, encoding);

    _ = c.store(key, bytes, ttl_ms, cache.nowMillis());
}

/// Store bytes under this request's key (when cacheable) then write them to fd.
///
/// Note:
/// - Cache the full response only for idempotent methods (GET, HEAD). Dynamic
///   per-request bodies either set a short ttl_ms or skip the cache and write
///   directly.
///
/// Usage:
/// ```zig
/// fn handler(req: *zix.Http1.Request, res: *zix.Http1.Response, ctx: *zix.Http1.Context) !void {
///     if (zix.Http1.cacheLookup(req.head)) |bytes| {
///         try res.sendRaw(bytes);
///         return;
///     }
///
///     const resp = buildResponse(req.head, try req.body());
///     zix.Http1.sendWithCacheFD(req.fd, req.head, resp, zix.Http1.cacheTtl()) catch {};
/// }
/// ```
pub fn sendWithCacheFD(fd: std.posix.fd_t, head: *const ParsedHead, bytes: []const u8, ttl_ms: u32) error{BrokenPipe}!void {
    cacheStore(head, bytes, ttl_ms);

    return writeAllFD(fd, bytes);
}

// --------------------------------------------------------- //

fn statusPhrase(code: u16) []const u8 {
    return switch (code) {
        100 => "Continue",
        200 => "OK",
        201 => "Created",
        204 => "No Content",
        206 => "Partial Content",
        301 => "Moved Permanently",
        302 => "Found",
        304 => "Not Modified",
        400 => "Bad Request",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        405 => "Method Not Allowed",
        406 => "Not Acceptable",
        408 => "Request Timeout",
        416 => "Range Not Satisfiable",
        431 => "Request Header Fields Too Large",
        500 => "Internal Server Error",
        501 => "Not Implemented",
        503 => "Service Unavailable",
        else => "Unknown",
    };
}

/// Comptime-baked "HTTP/1.1 <code> <phrase>\r\n" status line for the known codes,
/// so the response builder emits the whole line in one copy instead of
/// assembling it from five pieces per request. Returns "" for an unknown code,
/// where the caller falls back to the piecewise build. Byte-identical to that
/// build for every known code.
fn statusLine(code: u16) []const u8 {
    return switch (code) {
        100 => "HTTP/1.1 100 Continue\r\n",
        200 => "HTTP/1.1 200 OK\r\n",
        201 => "HTTP/1.1 201 Created\r\n",
        204 => "HTTP/1.1 204 No Content\r\n",
        206 => "HTTP/1.1 206 Partial Content\r\n",
        301 => "HTTP/1.1 301 Moved Permanently\r\n",
        302 => "HTTP/1.1 302 Found\r\n",
        304 => "HTTP/1.1 304 Not Modified\r\n",
        400 => "HTTP/1.1 400 Bad Request\r\n",
        401 => "HTTP/1.1 401 Unauthorized\r\n",
        403 => "HTTP/1.1 403 Forbidden\r\n",
        404 => "HTTP/1.1 404 Not Found\r\n",
        405 => "HTTP/1.1 405 Method Not Allowed\r\n",
        408 => "HTTP/1.1 408 Request Timeout\r\n",
        416 => "HTTP/1.1 416 Range Not Satisfiable\r\n",
        431 => "HTTP/1.1 431 Request Header Fields Too Large\r\n",
        500 => "HTTP/1.1 500 Internal Server Error\r\n",
        501 => "HTTP/1.1 501 Not Implemented\r\n",
        503 => "HTTP/1.1 503 Service Unavailable\r\n",
        else => "",
    };
}

fn formatHttpDate(secs: u64, buf: []u8) []u8 {
    const ep = std.time.epoch;
    const es = ep.EpochSeconds{ .secs = secs };
    const epoch_day = es.getEpochDay();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_secs = es.getDaySeconds();
    const day_names = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
    const month_names = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
    const dow = (@as(u64, epoch_day.day) % 7 + 4) % 7;

    return std.fmt.bufPrint(buf, "{s}, {d:0>2} {s} {d} {d:0>2}:{d:0>2}:{d:0>2} GMT", .{
        day_names[dow],
        @as(u32, month_day.day_index) + 1,
        month_names[@intFromEnum(month_day.month) - 1],
        year_day.year,
        day_secs.getHoursIntoDay(),
        day_secs.getMinutesIntoHour(),
        day_secs.getSecondsIntoMinute(),
    }) catch buf[0..0];
}

const DateCache = struct {
    secs: u64,
    buf: [40]u8,
    len: usize,
};

threadlocal var tl_date: DateCache = .{ .secs = 0, .buf = undefined, .len = 0 };
threadlocal var tl_date_tick: u8 = 0;
threadlocal var tl_send_date: bool = true;

/// Set whether responses include the Date header. Called once per worker thread at startup.
pub fn setDateHeader(enabled: bool) void {
    tl_send_date = enabled;
}

/// Configured static-serve root for the unmatched-route fallback. Empty disables it. The router
/// reads these because the static fallback runs before any handler, so the public_dir and io are
/// threaded down per worker the same way the date / cache / compression switches are.
pub threadlocal var tl_static_dir: []const u8 = "";
pub threadlocal var tl_static_io: ?std.Io = null;

/// Install the static-serve root and io for this worker thread. Called once per worker at startup.
/// An empty public_dir leaves static serving off (the router falls straight through to 404).
pub fn setStatic(public_dir: []const u8, io: std.Io) void {
    tl_static_dir = public_dir;
    tl_static_io = io;
}

/// Response extra-header capacity (Response.addHeader) for this worker, from
/// config.max_response_headers. The backing buffer is allocated lazily per
/// request on the first addHeader call, so requests that add none pay nothing.
pub threadlocal var tl_max_response_headers: usize = 16;

/// Install the Response extra-header capacity for this worker thread. Called once per worker at startup.
pub fn setMaxResponseHeaders(count: usize) void {
    tl_max_response_headers = count;
}

fn cachedDate() []const u8 {
    tl_date_tick +%= 1;
    if (tl_date_tick == 0 or tl_date.len == 0) {
        var ts: std.os.linux.timespec = undefined;
        _ = std.os.linux.clock_gettime(.REALTIME, &ts);
        const secs: u64 = if (ts.sec >= 0) @intCast(ts.sec) else 0;
        if (secs != tl_date.secs or tl_date.len == 0) {
            const d = formatHttpDate(secs, &tl_date.buf);
            tl_date.secs = secs;
            tl_date.len = d.len;
        }
    }

    return tl_date.buf[0..tl_date.len];
}

// --------------------------------------------------------- //

fn appendStatusCode(buf: []u8, pos: usize, code: u16) usize {
    buf[pos] = '0' + @as(u8, @intCast(code / 100));
    buf[pos + 1] = '0' + @as(u8, @intCast((code / 10) % 10));
    buf[pos + 2] = '0' + @as(u8, @intCast(code % 10));
    return pos + 3;
}

fn appendDec(buf: []u8, pos: usize, val: usize) usize {
    if (val == 0) {
        buf[pos] = '0';
        return pos + 1;
    }
    var tmp: [20]u8 = undefined;
    var tmp_len: usize = 0;
    var v = val;
    while (v > 0) {
        tmp[tmp_len] = '0' + @as(u8, @intCast(v % 10));
        tmp_len += 1;
        v /= 10;
    }

    var i: usize = 0;
    while (i < tmp_len) : (i += 1) {
        buf[pos + i] = tmp[tmp_len - 1 - i];
    }

    return pos + tmp_len;
}

fn appendBytes(buf: []u8, pos: usize, str: []const u8) usize {
    @memcpy(buf[pos..][0..str.len], str);
    return pos + str.len;
}

/// Write a simple response header into buf starting at offset 0.
/// buf must be at least 256 bytes. Returns the number of bytes written.
/// The block ends with the final \r\n\r\n, so a caller inserting extra
/// headers (Response.addHeader) splices them in before the last two bytes.
pub fn buildSimpleHeaderInto(buf: []u8, status: u16, content_type: []const u8, body_len: usize) usize {
    var pos: usize = 0;

    const line = statusLine(status);
    if (line.len > 0) {
        pos = appendBytes(buf, pos, line);
    } else {
        pos = appendBytes(buf, pos, "HTTP/1.1 ");
        pos = appendStatusCode(buf, pos, status);
        buf[pos] = ' ';
        pos += 1;
        pos = appendBytes(buf, pos, statusPhrase(status));
        pos = appendBytes(buf, pos, "\r\n");
    }

    if (content_type.len > 0) {
        pos = appendBytes(buf, pos, "Content-Type: ");
        pos = appendBytes(buf, pos, content_type);
        pos = appendBytes(buf, pos, "\r\n");
    }
    pos = appendBytes(buf, pos, "Content-Length: ");
    pos = appendDec(buf, pos, body_len);
    pos = appendBytes(buf, pos, "\r\n");
    if (tl_send_date) {
        pos = appendBytes(buf, pos, "Date: ");
        pos = appendBytes(buf, pos, cachedDate());
        pos = appendBytes(buf, pos, "\r\n");
    }
    pos = appendBytes(buf, pos, "\r\n");

    return pos;
}

fn buildSimpleHeader(buf: *[HEADER_BUF_SIZE]u8, status: u16, content_type: []const u8, body_len: usize) []u8 {
    return buf[0..buildSimpleHeaderInto(buf, status, content_type, body_len)];
}

// --------------------------------------------------------- //

/// Coalescing sink for pipelined responses. While installed (tl_resp_sink),
/// writeAllFD appends to buf instead of hitting the socket, so a pipelined
/// burst of N responses costs one write() instead of N. Same pattern as the
/// WebSocket SendSink. Installed by the .EPOLL / .URING request loops
/// (dispatch/) and the TLS capture path (tls_serve.runHandlerToBuffer).
pub const RespSink = struct {
    fd: std.posix.fd_t,
    buf: []u8,
    len: usize = 0,
    failed: bool = false,
    /// When set, an overflowing append grows buf (realloc up to grow_cap)
    /// instead of flushing to the socket. The URING dispatch installs this over
    /// the per-connection send buffer so a response larger than the staged
    /// buffer still goes out as one on-ring send instead of stalling the whole
    /// worker on a blocking off-ring write. null (the EPOLL path) keeps the
    /// flush-on-overflow behavior.
    grow_allocator: ?std.mem.Allocator = null,
    /// Hard ceiling for grow_allocator growth. Past this an oversized response
    /// falls back to a single direct flush rather than unbounded buffering.
    grow_cap: usize = 0,
    /// Whether buf is owned by grow_allocator (realloc-able). false when buf is
    /// a slice of the per-connection slab, which cannot be realloc'd: the first
    /// grow then switches to a fresh heap buffer (copying the staged bytes) and
    /// flips this to true, so the connection's close path knows to free it.
    buf_owned: bool = true,
    /// Zero-copy cache replay (URING only): a whole-response cache hit written
    /// while the sink is empty is borrowed into direct with its slot pinned,
    /// instead of memcpy'd into buf. The ring then sends the slab bytes and
    /// unpins on completion. Off (false) on every other path.
    allow_direct: bool = false,
    direct: []const u8 = &.{},
    direct_slot: u32 = 0,

    /// Fold a captured zero-copy replay back into the staged batch: a later
    /// response in the same batch means the send must carry both in order, so
    /// the borrowed bytes are copied after all and the pin drops. The copy
    /// happens before unpin could matter: this worker owns the cache, so
    /// nothing can overwrite the region between the unpin and the memcpy.
    pub fn materializeDirect(self: *RespSink) void {
        if (self.direct.len == 0) return;

        const bytes = self.direct;
        self.direct = &.{};
        if (tl_cache) |c| c.unpin(self.direct_slot);

        self.append(bytes);
    }

    pub fn append(self: *RespSink, bytes: []const u8) void {
        // Single response larger than the whole buffer: grow to hold it when
        // backed by an allocator, otherwise flush the staged batch and write
        // this payload straight through.
        if (bytes.len > self.buf.len) {
            if (self.grow(self.len + bytes.len)) {
                @memcpy(self.buf[self.len..][0..bytes.len], bytes);
                self.len += bytes.len;

                return;
            }

            self.flush();
            writeAllDirectFD(self.fd, bytes) catch {
                self.failed = true;
            };

            return;
        }

        // Cumulative overflow: the staged batch plus these bytes exceed the
        // buffer. Grow to keep the batch on the ring, otherwise flush it first.
        if (self.len + bytes.len > self.buf.len) {
            if (!self.grow(self.len + bytes.len)) self.flush();
        }

        @memcpy(self.buf[self.len..][0..bytes.len], bytes);
        self.len += bytes.len;
    }

    pub fn flush(self: *RespSink) void {
        if (self.len == 0) return;

        writeAllDirectFD(self.fd, self.buf[0..self.len]) catch {
            self.failed = true;
        };
        self.len = 0;
    }

    /// Grow buf to hold at least need bytes when backed by a growable allocator.
    /// Returns false when growth is unavailable (no allocator) or would exceed
    /// grow_cap, so the caller falls back to a direct flush. Never shrinks, so a
    /// grown per-connection buffer is reused by later requests on that fd.
    fn grow(self: *RespSink, need: usize) bool {
        const gpa = self.grow_allocator orelse return false;
        if (need <= self.buf.len) return true;
        if (need > self.grow_cap) return false;

        var new_len = @max(self.buf.len, 1) * 2;
        while (new_len < need) new_len *= 2;
        if (new_len > self.grow_cap) new_len = self.grow_cap;

        if (!self.buf_owned) {
            const grown = gpa.alloc(u8, new_len) catch return false;
            @memcpy(grown[0..self.len], self.buf[0..self.len]);
            self.buf = grown;
            self.buf_owned = true;

            return true;
        }

        const grown = gpa.realloc(self.buf, new_len) catch return false;
        self.buf = grown;

        return true;
    }
};

/// Coalescing sink for the current worker. null sends every write straight to the fd.
pub threadlocal var tl_resp_sink: ?*RespSink = null;

/// Streaming sink for the thread-per-connection https path (ADR-054). While installed
/// (tl_tls_stream) and the buffered capture sink is detached, writeAllFD encrypts each write as one
/// TLS record and sends it straight to the socket, so an SSE handler streams over TLS instead of
/// buffering a whole response. Type-erased over the live connection (the 1.3 and 1.2 paths share
/// it): writeFn casts ctx back to the concrete per-connection state and encrypts + writes.
pub const TlsStreamSink = struct {
    ctx: *anyopaque,
    writeFn: *const fn (ctx: *anyopaque, plaintext: []const u8) bool,
    failed: bool = false,

    pub fn write(self: *TlsStreamSink, bytes: []const u8) bool {
        if (self.failed) return false;

        if (!self.writeFn(self.ctx, bytes)) {
            self.failed = true;

            return false;
        }

        return true;
    }
};

/// Active streaming sink for the current worker thread (the thread-per-conn https path). null for
/// cleartext and the buffered https path, so writeAllFD never routes through it there.
pub threadlocal var tl_tls_stream: ?*TlsStreamSink = null;

/// Begin a streaming response (SSE) from a handler, so one handler serves cleartext and TLS.
///
/// Detaches any buffered capture / coalescing sink, so each subsequent writeAllFD flushes
/// immediately: over TLS it hands writes to the live-session stream sink (one record per write), in
/// cleartext it writes straight to the socket. An SSE handler never returns, so a buffered sink
/// would never flush. A no-op when no sink is installed (the cleartext .ASYNC SSE path).
///
/// Usage:
/// ```zig
/// fn eventsHandler(req: *zix.Http1.Request, res: *zix.Http1.Response, ctx: *zix.Http1.Context) !void {
///     zix.Http1.beginStream();
///     try res.sendRaw(sse_headers);
///     // ... emit events with res.sendRaw(...) ...
/// }
/// ```
pub fn beginStream() void {
    if (tl_resp_sink) |sink| {
        sink.materializeDirect();
        sink.flush();
        tl_resp_sink = null;
    }
}

/// Flush any response bytes still staged for fd. Handlers that write to the
/// fd directly (sendfile, raw send) must call this first so the wire order
/// matches the request order under pipelining. No-op when nothing is staged.
pub fn flushPending(fd: std.posix.fd_t) void {
    if (tl_resp_sink) |sink| {
        if (sink.fd == fd) {
            sink.materializeDirect();
            sink.flush();
        }
    }
}

/// Write as much of data to fd as possible without blocking.
/// On EAGAIN returns the byte count written so far (caller stages the rest).
/// On a permanent error returns null.
pub fn writeNonBlockFD(fd: std.posix.fd_t, data: []const u8) ?usize {
    var written: usize = 0;
    while (written < data.len) {
        const rc = std.posix.system.write(fd, data[written..].ptr, data.len - written);
        switch (std.posix.errno(rc)) {
            .SUCCESS => {
                const n: usize = @intCast(rc);
                if (n == 0) return null;
                written += n;
            },
            .INTR => continue,
            .AGAIN => return written,
            else => return null,
        }
    }
    return written;
}

/// Write response bytes to fd, the canonical write behind every send helper.
/// Routes through the coalescing sink (tl_resp_sink) or the TLS stream sink
/// when one is installed for this worker, otherwise writes directly.
pub fn writeAllFD(fd: std.posix.fd_t, data: []const u8) error{BrokenPipe}!void {
    if (tl_resp_sink) |sink| {
        if (sink.fd == fd) {
            // Zero-copy cache replay: a whole-response hit written while the
            // batch is empty is borrowed (slot pinned) instead of copied. Only
            // the exact slice the cache lookup returned qualifies.
            if (sink.allow_direct and sink.len == 0 and sink.direct.len == 0) {
                if (tl_cache) |c| {
                    if (c.hitSlot(data)) |slot| {
                        c.pin(slot);
                        sink.direct = data;
                        sink.direct_slot = slot;

                        return;
                    }
                }
            }

            sink.materializeDirect();
            sink.append(data);
            if (sink.failed) return error.BrokenPipe;

            return;
        }
    }

    // Streaming https path (ADR-054): the capture sink was detached by beginStream(), so each write
    // encrypts one TLS record and sends it. null in cleartext, where writes go straight to the fd.
    if (tl_tls_stream) |strm| {
        return if (strm.write(data)) {} else error.BrokenPipe;
    }

    return writeAllDirectFD(fd, data);
}

fn writeAllDirectFD(fd: std.posix.fd_t, data: []const u8) error{BrokenPipe}!void {
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
            // Non-blocking socket with a full send buffer: wait for the peer
            // to drain it, then retry. Blocking sockets never hit this branch.
            .AGAIN => {
                var pfd = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.OUT, .revents = 0 }};
                _ = std.posix.poll(&pfd, -1) catch return error.BrokenPipe;
            },
            else => return error.BrokenPipe,
        }
    }
}

/// Response with Content-Length body.
pub fn sendSimpleFD(
    fd: std.posix.fd_t,
    status: u16,
    content_type: []const u8,
    body: []const u8,
) !void {
    if (tl_resp_sink) |sink| {
        if (sink.fd == fd) {
            // A pending zero-copy replay must land in the batch before this
            // response so the wire order matches the request order.
            sink.materializeDirect();

            // Fast path: build header directly into sink.buf at sink.len, then
            // append body. Eliminates the hdr_buf[256] stack allocation and the
            // hdr_buf-to-sink memcpy on the pipelined hot path.
            if (sink.len + HEADER_BUF_SIZE + body.len <= sink.buf.len) {
                const hdr_len = buildSimpleHeaderInto(sink.buf[sink.len..], status, content_type, body.len);
                sink.len += hdr_len;
                @memcpy(sink.buf[sink.len..][0..body.len], body);
                sink.len += body.len;
            } else {
                var hdr_buf: [HEADER_BUF_SIZE]u8 = undefined;
                const hdr = buildSimpleHeader(&hdr_buf, status, content_type, body.len);
                sink.append(hdr);
                if (!sink.failed) sink.append(body);
            }

            return if (sink.failed) error.BrokenPipe else {};
        }
    }

    var hdr_buf: [HEADER_BUF_SIZE]u8 = undefined;
    const hdr = buildSimpleHeader(&hdr_buf, status, content_type, body.len);

    if (body.len <= SMALL_BODY_INLINE_BUF - HEADER_BUF_SIZE) {
        var buf: [SMALL_BODY_INLINE_BUF]u8 = undefined;
        @memcpy(buf[0..hdr.len], hdr);
        @memcpy(buf[hdr.len..][0..body.len], body);

        // Skips that sink check entirely instead,
        // and write straight to the fd since code only reaches this line.
        return writeAllDirectFD(fd, buf[0 .. hdr.len + body.len]);
    }

    var sent: usize = 0;
    const total = hdr.len + body.len;
    while (sent < total) {
        var iovs: [2]std.posix.iovec_const = undefined;
        var nvec: usize = 0;
        if (sent < hdr.len) {
            iovs[0] = .{ .base = hdr[sent..].ptr, .len = hdr.len - sent };
            iovs[1] = .{ .base = body.ptr, .len = body.len };
            nvec = 2;
        } else {
            const body_sent = sent - hdr.len;
            iovs[0] = .{ .base = body[body_sent..].ptr, .len = body.len - body_sent };
            nvec = 1;
        }
        const rc = std.os.linux.writev(fd, &iovs, nvec);
        switch (std.posix.errno(rc)) {
            .SUCCESS => {
                const n: usize = @intCast(rc);
                if (n == 0) return error.BrokenPipe;
                sent += n;
            },
            .INTR => continue,
            .AGAIN => {
                var pfd = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.OUT, .revents = 0 }};
                _ = std.posix.poll(&pfd, -1) catch return error.BrokenPipe;
            },
            else => return error.BrokenPipe,
        }
    }
}

/// Headers-only response (no body). Used for HEAD method responses.
pub fn sendSimpleNoBodyFD(
    fd: std.posix.fd_t,
    status: u16,
    content_type: []const u8,
    content_length: usize,
) !void {
    var hdr_buf: [HEADER_BUF_SIZE]u8 = undefined;
    const hdr = buildSimpleHeader(&hdr_buf, status, content_type, content_length);

    return writeAllFD(fd, hdr);
}

/// JSON response. Shorthand for sendSimpleFD with "application/json".
pub fn sendJsonFD(fd: std.posix.fd_t, status: u16, body: []const u8) !void {
    return sendSimpleFD(fd, status, "application/json", body);
}

/// Send 100 Continue before reading a large body.
pub fn send100ContinueFD(fd: std.posix.fd_t) !void {
    try writeAllFD(fd, "HTTP/1.1 100 Continue\r\n\r\n");
}

/// Per-worker compression scratch, one lazily mapped block per worker thread instead of ~1 MiB of
/// cold threadlocal (.tbss) buffers. The flate state is about 225 KB, its window 64 KB, plus the
/// two response assembly buffers. A per-request heap alloc of these would overflow SmpAllocator's
/// 32 KB size class and fall to mmap / munmap, whose process mmap_lock + TLB-shootdown serializes
/// every worker (the json-comp low-CPU stall). One mapping per worker keeps the hot path free of
/// allocation syscalls, keeps the hot threadlocals (sink, cache, date) packed instead of spread
/// across cold TLS blobs, and gives the scratch its own mapping so a non-compressing worker pays
/// nothing. The compressor is held as an error-union slot and built in place (sret), never as a
/// 225 KB stack temporary.
const EncodeScratch = struct {
    /// flate history window.
    window: [std.compress.flate.max_window_len]u8,
    /// flate state, built in place per response.
    comp: std.Io.Writer.Error!std.compress.flate.Compress,
    /// Full gzip response: the body compresses straight into [HEADER_BUF_SIZE..]
    /// and the header renders right-aligned before it (reserve-prefix assembly),
    /// so header and body are contiguous with zero body copies.
    resp: [HEADER_BUF_SIZE + GZIP_OUT_SIZE]u8,
    /// Same reserve-prefix assembly buffer for the negotiated
    /// (gzip / deflate / brotli) response path.
    neg_resp: [HEADER_BUF_SIZE + GZIP_OUT_SIZE]u8,
};

threadlocal var tl_encode_scratch: ?*EncodeScratch = null;

/// The worker's compression scratch, mapped on the first compressed response.
fn encodeScratch() !*EncodeScratch {
    if (tl_encode_scratch == null) {
        const raw = try slab_mem.mapZeroedSlots(u8, @sizeOf(EncodeScratch));
        tl_encode_scratch = @ptrCast(@alignCast(raw.ptr));
    }

    return tl_encode_scratch.?;
}

/// Build a complete gzip HTTP response (header + compressed body) into the per-worker buffer and
/// return the slice. Reuses the per-worker compressor, so it allocates nothing. The body compresses
/// directly into the response buffer past the header reserve, then the header renders right-aligned
/// so it ends exactly where the body starts: no pass over the compressed bytes. Shared by sendGzipFD
/// and sendGzipCachedFD.
fn buildGzipResponse(status: u16, content_type: []const u8, body: []const u8) ![]const u8 {
    const scratch = try encodeScratch();

    var out_w: std.Io.Writer = .fixed(scratch.resp[HEADER_BUF_SIZE..]);
    scratch.comp = std.compress.flate.Compress.init(
        &out_w,
        &scratch.window,
        .gzip,
        std.compress.flate.Compress.Options.default,
    );

    const comp: *std.compress.flate.Compress = if (scratch.comp) |*payload| payload else |_| return error.CompressFailed;
    try comp.writer.writeAll(body);
    try comp.finish();

    const compressed = out_w.buffered();
    var hdr_buf: [HEADER_BUF_SIZE]u8 = undefined;
    const header = try std.fmt.bufPrint(
        &hdr_buf,
        "HTTP/1.1 {d} {s}\r\nContent-Type: {s}\r\nContent-Encoding: gzip\r\nContent-Length: {d}\r\n\r\n",
        .{ status, statusPhrase(status), content_type, compressed.len },
    );
    const start = HEADER_BUF_SIZE - header.len;

    @memcpy(scratch.resp[start..HEADER_BUF_SIZE], header);

    return scratch.resp[start .. HEADER_BUF_SIZE + compressed.len];
}

/// gzip-compressed response via std.compress.flate, reusing the per-worker compressor.
pub fn sendGzipFD(fd: std.posix.fd_t, status: u16, content_type: []const u8, body: []const u8) !void {
    try writeAllFD(fd, try buildGzipResponse(status, content_type, body));
}

/// gzip response with the per-(key, encoding) cache: on a hit replay the cached compressed response
/// with zero compression work, on a miss compress once, store, and write. Deterministic bodies (the
/// /json family) become a cache replay after the first request, the json-comp ceiling-raiser.
pub fn sendGzipCachedFD(fd: std.posix.fd_t, head: *const ParsedHead, status: u16, content_type: []const u8, body: []const u8, ttl_ms: u32) !void {
    if (cacheLookupEncoded(head, "gzip")) |cached| return writeAllFD(fd, cached);

    const resp = try buildGzipResponse(status, content_type, body);
    cacheStoreEncoded(head, "gzip", resp, ttl_ms);

    try writeAllFD(fd, resp);
}

/// Build a complete brotli HTTP response (header + brotli body) into the per-worker negotiated buffer
/// and return the slice. Brotli's encoder needs heap scratch (input-sized hash and Huffman tables),
/// so it routes through the shared compression facade on the per-worker encode arena rather than the
/// flate-style compressor. The encoded body lands past the header reserve and the header renders
/// right-aligned before it (reserve-prefix assembly). Shared by sendBrotliFD and sendBrotliCachedFD.
fn buildBrotliResponse(status: u16, content_type: []const u8, body: []const u8) ![]const u8 {
    const scratch = try encodeScratch();
    const arena = encodeArena();
    defer _ = arena.reset(.retain_capacity);

    const encoded_len = try compression.encodeInto(arena.allocator(), .BR, body, scratch.neg_resp[HEADER_BUF_SIZE..], .DEFAULT);

    var hdr_buf: [HEADER_BUF_SIZE]u8 = undefined;
    const header = try std.fmt.bufPrint(
        &hdr_buf,
        "HTTP/1.1 {d} {s}\r\nContent-Type: {s}\r\nContent-Encoding: br\r\nContent-Length: {d}\r\n\r\n",
        .{ status, statusPhrase(status), content_type, encoded_len },
    );
    const start = HEADER_BUF_SIZE - header.len;

    @memcpy(scratch.neg_resp[start..HEADER_BUF_SIZE], header);

    return scratch.neg_resp[start .. HEADER_BUF_SIZE + encoded_len];
}

/// brotli-compressed response via the shared compression facade on the per-worker encode arena. The
/// forced-brotli sibling of sendGzipFD, for a caller that has already decided on brotli.
pub fn sendBrotliFD(fd: std.posix.fd_t, status: u16, content_type: []const u8, body: []const u8) !void {
    try writeAllFD(fd, try buildBrotliResponse(status, content_type, body));
}

/// brotli response with the per-(key, encoding) cache: a hit replays the cached compressed response
/// with zero compression work, a miss compresses once, stores, and writes. The forced-brotli sibling
/// of sendGzipCachedFD.
pub fn sendBrotliCachedFD(fd: std.posix.fd_t, head: *const ParsedHead, status: u16, content_type: []const u8, body: []const u8, ttl_ms: u32) !void {
    if (cacheLookupEncoded(head, "br")) |cached| return writeAllFD(fd, cached);

    const resp = try buildBrotliResponse(status, content_type, body);
    cacheStoreEncoded(head, "br", resp, ttl_ms);

    try writeAllFD(fd, resp);
}

/// Per-worker arena for negotiated-compression codec scratch (gzip / deflate / brotli), reset with
/// retained capacity after each response so the codecs reuse one backing allocation per worker
/// instead of allocating per request. Lazily initialized on first use.
threadlocal var tl_encode_arena: ?std.heap.ArenaAllocator = null;

fn encodeArena() *std.heap.ArenaAllocator {
    if (tl_encode_arena == null) {
        tl_encode_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    }

    return &tl_encode_arena.?;
}

/// Response with Accept-Encoding negotiation: the body is compressed only when the
/// worker has compression enabled, the client accepts a producible coding, the body
/// clears the size floor and is not an already-compressed media type, and the
/// compressed result is both smaller than the original and within the cap. In every
/// other case the body is sent uncompressed, byte-identical to sendSimpleFD.
///
/// Note:
/// - This is the negotiating replacement for a hand-called sendGzipFD. It uses the per-(key,
///   encoding) response cache: a hit replays the full compressed response with no compression
///   work, a miss compresses once then stores the assembled response under (key, encoding).
/// - The compressed response sets Content-Encoding and Vary: Accept-Encoding.
///
/// Param:
/// fd - std.posix.fd_t (connection)
/// head - *const ParsedHead (for the Accept-Encoding header)
/// status - u16 (response status)
/// content_type - []const u8 (response Content-Type)
/// body - []const u8 (uncompressed body)
///
/// Return:
/// - void
/// - error.BrokenPipe on a failed write
pub fn sendNegotiateCachedFD(
    fd: std.posix.fd_t,
    head: *const ParsedHead,
    status: u16,
    content_type: []const u8,
    body: []const u8,
) !void {
    if (!tl_compression) return sendSimpleFD(fd, status, content_type, body);

    const accept = acceptEncoding(head);
    const encoding = compression.negotiate(accept, &compression.supported_default) orelse {
        return sendSimpleNoBodyFD(fd, 406, content_type, 0);
    };

    if (encoding == .IDENTITY or !compression.shouldCompress(body.len, content_type, tl_compression_min_size)) {
        return sendSimpleFD(fd, status, content_type, body);
    }

    const token = encoding.contentEncoding().?;

    // Per-(key, encoding) cache hit: replay the full compressed response, no compression work.
    if (cacheLookupEncoded(head, token)) |cached| return writeAllFD(fd, cached);

    const scratch = encodeScratch() catch {
        return sendSimpleFD(fd, status, content_type, body);
    };

    // Per-worker arena for the codec scratch. gzip / deflate / brotli each allocate transient
    // buffers (brotli especially: input-sized hash tables, Huffman tables, command lists). A
    // per-request smp_allocator would mmap the larger ones over the 32 KiB size class and serialize
    // workers in the kernel. The arena is retained across requests, so after warmup the codec path
    // issues no allocation syscalls. The reset(.retain_capacity) call reclaims every codec buffer
    // after the response is written.
    const arena = encodeArena();
    defer _ = arena.reset(.retain_capacity);

    // Reserve-prefix assembly: the body encodes straight into the assembly buffer past the header
    // reserve, so the response never repeats a pass over the encoded bytes. An encoded result too
    // large for the buffer streams in two parts instead (the rare oversized path).
    const encoded_len = compression.encodeInto(arena.allocator(), encoding, body, scratch.neg_resp[HEADER_BUF_SIZE..], .DEFAULT) catch |err| switch (err) {
        error.BufferTooSmall => return sendNegotiateOversized(fd, head, encoding, token, status, content_type, body),
        else => return sendSimpleFD(fd, status, content_type, body),
    };

    if (encoded_len > tl_compression_max_out or encoded_len >= body.len) {
        return sendSimpleFD(fd, status, content_type, body);
    }

    // The header renders right-aligned so it ends exactly where the encoded body starts, then the
    // contiguous response is cached and replayed on later requests with the same (key, encoding).
    var hdr_buf: [HEADER_BUF_SIZE]u8 = undefined;
    const header = try std.fmt.bufPrint(
        &hdr_buf,
        "HTTP/1.1 {d} {s}\r\nContent-Type: {s}\r\nContent-Encoding: {s}\r\nVary: Accept-Encoding\r\nContent-Length: {d}\r\n\r\n",
        .{ status, statusPhrase(status), content_type, token, encoded_len },
    );
    const start = HEADER_BUF_SIZE - header.len;

    @memcpy(scratch.neg_resp[start..HEADER_BUF_SIZE], header);
    const full = scratch.neg_resp[start .. HEADER_BUF_SIZE + encoded_len];
    cacheStoreEncoded(head, token, full, cacheTtl());

    return writeAllFD(fd, full);
}

/// Negotiated response for a body too large for the into-buffer bound check: compress through the
/// arena, then assemble + cache when the result fits the per-worker buffer (the copy is paid only
/// on this oversized-input branch), else stream in two parts and skip the cache. Off the hot path.
fn sendNegotiateOversized(
    fd: std.posix.fd_t,
    head: *const ParsedHead,
    encoding: compression.Encoding,
    token: []const u8,
    status: u16,
    content_type: []const u8,
    body: []const u8,
) !void {
    const arena = encodeArena();
    defer _ = arena.reset(.retain_capacity);

    const encoded = compression.encode(arena.allocator(), encoding, body, .DEFAULT) catch {
        return sendSimpleFD(fd, status, content_type, body);
    };

    if (encoded.len > tl_compression_max_out or encoded.len >= body.len) {
        return sendSimpleFD(fd, status, content_type, body);
    }

    var hdr_buf: [HEADER_BUF_SIZE]u8 = undefined;
    const header = try std.fmt.bufPrint(
        &hdr_buf,
        "HTTP/1.1 {d} {s}\r\nContent-Type: {s}\r\nContent-Encoding: {s}\r\nVary: Accept-Encoding\r\nContent-Length: {d}\r\n\r\n",
        .{ status, statusPhrase(status), content_type, token, encoded.len },
    );

    if (encodeScratch()) |scratch| {
        const total = header.len + encoded.len;
        if (total <= scratch.neg_resp.len) {
            @memcpy(scratch.neg_resp[0..header.len], header);
            @memcpy(scratch.neg_resp[header.len..total], encoded);
            const full = scratch.neg_resp[0..total];
            cacheStoreEncoded(head, token, full, cacheTtl());

            return writeAllFD(fd, full);
        }
    } else |_| {}

    try writeAllFD(fd, header);
    try writeAllFD(fd, encoded);
}

/// Response with Accept-Encoding negotiation, uncached sibling of sendNegotiateCachedFD: it compresses
/// on every request and never stores or replays. Suits a body that is not deterministic (a per-(key,
/// encoding) cache would only grow memory with no replay hit) or a lean, cache-free memory profile.
/// Same negotiation, size floor, and identity fall-through as the cached variant.
///
/// Note:
/// - The compressed response sets Content-Encoding and Vary: Accept-Encoding.
/// - No response cache: each call runs the codec on the per-worker encode arena, then reclaims it.
///
/// Param:
/// fd - std.posix.fd_t (connection)
/// head - *const ParsedHead (for the Accept-Encoding header)
/// status - u16 (response status)
/// content_type - []const u8 (response Content-Type)
/// body - []const u8 (uncompressed body)
///
/// Return:
/// - void
/// - error.BrokenPipe on a failed write
pub fn sendNegotiateFD(
    fd: std.posix.fd_t,
    head: *const ParsedHead,
    status: u16,
    content_type: []const u8,
    body: []const u8,
) !void {
    if (!tl_compression) return sendSimpleFD(fd, status, content_type, body);

    const accept = acceptEncoding(head);
    const encoding = compression.negotiate(accept, &compression.supported_default) orelse {
        return sendSimpleNoBodyFD(fd, 406, content_type, 0);
    };

    if (encoding == .IDENTITY or !compression.shouldCompress(body.len, content_type, tl_compression_min_size)) {
        return sendSimpleFD(fd, status, content_type, body);
    }

    const token = encoding.contentEncoding().?;

    const arena = encodeArena();
    defer _ = arena.reset(.retain_capacity);

    const encoded = compression.encode(arena.allocator(), encoding, body, .DEFAULT) catch {
        return sendSimpleFD(fd, status, content_type, body);
    };

    if (encoded.len > tl_compression_max_out or encoded.len >= body.len) {
        return sendSimpleFD(fd, status, content_type, body);
    }

    var hdr_buf: [HEADER_BUF_SIZE]u8 = undefined;
    const header = try std.fmt.bufPrint(
        &hdr_buf,
        "HTTP/1.1 {d} {s}\r\nContent-Type: {s}\r\nContent-Encoding: {s}\r\nVary: Accept-Encoding\r\nContent-Length: {d}\r\n\r\n",
        .{ status, statusPhrase(status), content_type, token, encoded.len },
    );

    try writeAllFD(fd, header);
    try writeAllFD(fd, encoded);
}

/// Start a chunked response. Call sendChunkFD for each chunk, then sendChunkedEndFD.
pub fn sendChunkedStartFD(fd: std.posix.fd_t, status: u16, content_type: []const u8) !void {
    var hdr: [HEADER_BUF_SIZE]u8 = undefined;
    const s = try std.fmt.bufPrint(
        &hdr,
        "HTTP/1.1 {d} {s}\r\nContent-Type: {s}\r\nTransfer-Encoding: chunked\r\n\r\n",
        .{ status, statusPhrase(status), content_type },
    );
    try writeAllFD(fd, s);
}

/// Write one chunk: hex_len CRLF data CRLF.
pub fn sendChunkFD(fd: std.posix.fd_t, data: []const u8) !void {
    if (data.len == 0) return;
    var sz: [32]u8 = undefined;
    const s = try std.fmt.bufPrint(&sz, "{x}\r\n", .{data.len});
    try writeAllFD(fd, s);
    try writeAllFD(fd, data);
    try writeAllFD(fd, "\r\n");
}

/// Terminate the chunked body with the final zero-length chunk.
pub fn sendChunkedEndFD(fd: std.posix.fd_t) !void {
    try writeAllFD(fd, "0\r\n\r\n");
}

/// 206 Partial Content or 416 Range Not Satisfiable based on parseRange result.
pub fn sendRangeFD(
    fd: std.posix.fd_t,
    content_type: []const u8,
    full_body: []const u8,
    range_val: []const u8,
) !void {
    const total: u64 = full_body.len;
    const range = parseRange(range_val, total) orelse {
        var hdr: [HEADER_BUF_SIZE]u8 = undefined;
        const s = try std.fmt.bufPrint(
            &hdr,
            "HTTP/1.1 416 Range Not Satisfiable\r\nContent-Range: bytes */{d}\r\nContent-Length: 0\r\n\r\n",
            .{total},
        );
        return writeAllFD(fd, s);
    };

    const slice = full_body[range.start .. range.end + 1];
    var hdr: [HEADER_BUF_SIZE]u8 = undefined;
    const s = try std.fmt.bufPrint(
        &hdr,
        "HTTP/1.1 206 Partial Content\r\nContent-Type: {s}\r\nContent-Range: bytes {d}-{d}/{d}\r\nContent-Length: {d}\r\n\r\n",
        .{ content_type, range.start, range.end, total, slice.len },
    );
    try writeAllFD(fd, s);
    try writeAllFD(fd, slice);
}

// --------------------------------------------------------- //

const RecvHeadResult = struct {
    body_offset: usize,
    filled: usize,
};

/// Bulk-read into buf until \r\n\r\n is found.
/// pre_filled bytes are already in buf from a previous iteration (keep-alive leftover).
///
/// Return:
/// - !RecvHeadResult
fn recvHead(fd: std.posix.fd_t, buf: []u8, pre_filled: usize) !RecvHeadResult {
    var filled = pre_filled;

    if (filled >= 4) {
        if (std.mem.indexOf(u8, buf[0..filled], "\r\n\r\n")) |pos| {
            return .{ .body_offset = pos + 4, .filled = filled };
        }
    }

    while (true) {
        if (filled >= buf.len) return error.HeaderTooLarge;
        const n = std.posix.read(fd, buf[filled..]) catch return error.Closed;
        if (n == 0) return error.Closed;
        const search_from = if (filled > 3) filled - 3 else 0;
        filled += n;
        if (std.mem.indexOfPos(u8, buf[0..filled], search_from, "\r\n\r\n")) |pos| {
            return .{ .body_offset = pos + 4, .filled = filled };
        }
    }
}

/// Decode a chunked request body (RFC 9112 7.1).
/// peeked contains bytes already read past the header.
/// Ignores chunk extensions. Skips trailer section.
///
/// Return:
/// - !usize (decoded bytes written into out)
pub fn readChunkedBody(fd: std.posix.fd_t, peeked: []const u8, out: []u8) !usize {
    const Rd = struct {
        fd: std.posix.fd_t,
        buf: [BUF_SIZE]u8 = undefined,
        pos: usize = 0,
        len: usize = 0,

        fn refill(reader: *@This()) !void {
            const rem = reader.len - reader.pos;
            if (rem > 0) std.mem.copyForwards(u8, &reader.buf, reader.buf[reader.pos..reader.len]);
            reader.pos = 0;
            reader.len = rem;
            const n = std.posix.read(reader.fd, reader.buf[reader.len..]) catch return error.Closed;
            if (n == 0) return error.Closed;
            reader.len += n;
        }

        fn next(reader: *@This()) !u8 {
            if (reader.pos >= reader.len) try reader.refill();
            const b = reader.buf[reader.pos];
            reader.pos += 1;
            return b;
        }
    };

    var rd: Rd = .{ .fd = fd };
    const seed = @min(peeked.len, rd.buf.len);
    @memcpy(rd.buf[0..seed], peeked[0..seed]);
    rd.len = seed;

    var out_pos: usize = 0;

    while (true) {
        var line: [64]u8 = undefined;
        var line_len: usize = 0;
        while (true) {
            const b = try rd.next();
            if (b == '\r') {
                _ = try rd.next();
                break;
            }
            if (b == '\n') break;
            if (line_len < line.len) {
                line[line_len] = b;
                line_len += 1;
            }
        }

        var hex_end: usize = line_len;
        for (line[0..line_len], 0..) |c, i| {
            if (c == ';') {
                hex_end = i;
                break;
            }
        }
        const chunk_size = std.fmt.parseInt(
            usize,
            std.mem.trimEnd(u8, line[0..hex_end], " "),
            16,
        ) catch return error.InvalidChunkSize;

        if (chunk_size == 0) {
            while (true) {
                var blank = true;
                while (true) {
                    const b = try rd.next();
                    if (b == '\r') {
                        _ = try rd.next();
                        break;
                    }
                    if (b == '\n') break;
                    blank = false;
                }
                if (blank) break;
            }
            break;
        }

        var left = chunk_size;
        while (left > 0) {
            if (rd.pos >= rd.len) try rd.refill();
            const avail = rd.len - rd.pos;
            const take = @min(avail, left);
            const copy = @min(take, out.len - out_pos);
            if (copy > 0) {
                @memcpy(out[out_pos..][0..copy], rd.buf[rd.pos..][0..copy]);
                out_pos += copy;
            }
            rd.pos += take;
            left -= take;
        }

        _ = try rd.next();
        _ = try rd.next();
    }

    return out_pos;
}

/// Per-request verdict from a dispatch: keep the connection open or close it.
pub const ConnOutcome = enum { keep_alive, close };

/// Keep-alive connection loop. The caller owns closing the fd. Pass raw fd extracted
/// from the accepted stream.
pub fn serveConn(fd: std.posix.fd_t, handler: HandlerFn, opts: ServeOpts, io: std.Io) void {
    if (opts.nodelay) {
        if (comptime @import("builtin").target.os.tag != .windows) {
            std.posix.setsockopt(
                fd,
                std.posix.IPPROTO.TCP,
                std.posix.TCP.NODELAY,
                std.mem.asBytes(&@as(c_int, 1)),
            ) catch {};
        }
    }

    // Per-connection scratch for the handler trio, reset before each request so a
    // long keep-alive connection never grows without bound.
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();

    var recv_buf: [BUF_SIZE]u8 = undefined;
    var body_buf: [ASYNC_BODY_CHUNK]u8 = undefined;
    var leftover: usize = 0;

    while (true) {
        const hdr = recvHead(fd, &recv_buf, leftover) catch |err| {
            if (err == error.HeaderTooLarge) {
                writeAllFD(fd, "HTTP/1.1 431 Request Header Fields Too Large\r\nContent-Length: 0\r\n\r\n") catch {};
            }
            return;
        };

        const result = parseHead(recv_buf[0..hdr.filled]) catch {
            writeAllFD(fd, "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n") catch {};
            return;
        };
        const head = result.head;

        if (head.expect_continue and (head.content_length > 0 or head.chunked_request)) {
            send100ContinueFD(fd) catch return;
        }

        var body_len: usize = 0;
        var drained_large = false;
        if (head.chunked_request) {
            const peeked = recv_buf[hdr.body_offset..hdr.filled];
            body_len = readChunkedBody(fd, peeked, &body_buf) catch 0;
        } else if (head.content_length > 0) {
            const content_length: usize = @intCast(head.content_length);
            const to_read: usize = @min(content_length, body_buf.len);
            const peeked = hdr.filled - hdr.body_offset;
            const from_peek = @min(peeked, to_read);
            if (from_peek > 0) {
                @memcpy(body_buf[0..from_peek], recv_buf[hdr.body_offset..][0..from_peek]);
            }
            body_len = from_peek;
            while (body_len < to_read) {
                const n = std.posix.read(fd, body_buf[body_len..to_read]) catch break;
                if (n == 0) break;
                body_len += n;
            }

            // Body larger than the handler buffer: drain the remainder off the socket so the
            // connection stays usable for keep-alive (the leftover would otherwise be misparsed as
            // the next request). Large-body endpoints use content_length, not the bytes, so the
            // discard is safe. A wider SO_RCVBUF (opts.large_body_rcvbuf) speeds this on uploads.
            if (content_length > peeked) {
                setRecvBuf(fd, opts.large_body_rcvbuf);

                var remaining = content_length - peeked;
                while (remaining > 0) {
                    const want = @min(remaining, body_buf.len);
                    const n = std.posix.read(fd, body_buf[0..want]) catch break;
                    if (n == 0) break;
                    remaining -= n;
                }
                drained_large = true;
            }
        }

        setTimeout(opts.handler_timeout_ms);
        _ = arena.reset(.retain_capacity);
        invokeHandler(handler, &head, body_buf[0..body_len], fd, io, arena.allocator());

        // Engine-owned WebSocket promotion is honored by the EPOLL loop only.
        // On this path clear the handoff and end the connection so it never leaks.
        if (takeWebSocket() != null) return;

        if (!head.keep_alive) return;

        if (head.chunked_request or drained_large) {
            // drained_large: the whole body was consumed off the socket, and a large body has no
            // pipelined request after it, so nothing is left to carry.
            leftover = 0;
        } else {
            const body_consumed: usize = @intCast(@min(head.content_length, @as(u64, body_buf.len)));
            const request_end = hdr.body_offset + body_consumed;
            if (hdr.filled > request_end) {
                leftover = hdr.filled - request_end;
                std.mem.copyForwards(u8, recv_buf[0..leftover], recv_buf[request_end..hdr.filled]);
            } else {
                leftover = 0;
            }
        }
    }
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //

test "zix http1: buildSimpleHeaderInto writes status, content-type, content-length" {
    var buf: [HEADER_BUF_SIZE]u8 = undefined;
    const len = buildSimpleHeaderInto(&buf, 200, "text/plain", 3);
    const hdr = buf[0..len];
    try std.testing.expect(std.mem.startsWith(u8, hdr, "HTTP/1.1 200 OK\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, hdr, "Content-Length: 3\r\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, hdr, "\r\n\r\n"));
}

test "zix http1: buildSimpleHeaderInto omits Content-Type when empty" {
    var buf: [HEADER_BUF_SIZE]u8 = undefined;
    const len = buildSimpleHeaderInto(&buf, 204, "", 0);
    const hdr = buf[0..len];
    try std.testing.expect(std.mem.indexOf(u8, hdr, "Content-Type") == null);
    try std.testing.expect(std.mem.indexOf(u8, hdr, "Content-Length: 0\r\n") != null);
}

test "zix http1: buildSimpleHeaderInto baked status line is byte-identical across paths" {
    const saved = tl_send_date;
    tl_send_date = false;
    defer tl_send_date = saved;

    var buf: [HEADER_BUF_SIZE]u8 = undefined;

    // Known code: baked one-copy status line.
    const a = buildSimpleHeaderInto(&buf, 200, "text/plain", 2);
    try std.testing.expectEqualStrings("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 2\r\n\r\n", buf[0..a]);

    // Another known code, non-200.
    const b = buildSimpleHeaderInto(&buf, 404, "text/plain", 9);
    try std.testing.expectEqualStrings("HTTP/1.1 404 Not Found\r\nContent-Type: text/plain\r\nContent-Length: 9\r\n\r\n", buf[0..b]);

    // Unknown code: piecewise fallback must match the legacy bytes exactly.
    const c = buildSimpleHeaderInto(&buf, 599, "text/plain", 0);
    try std.testing.expectEqualStrings("HTTP/1.1 599 Unknown\r\nContent-Type: text/plain\r\nContent-Length: 0\r\n\r\n", buf[0..c]);
}

test "zix http1: sendSimpleFD builds header directly into active sink without hdr_buf bounce" {
    var fds: [2]i32 = undefined;
    try std.testing.expectEqual(@as(usize, 0), std.os.linux.socketpair(std.os.linux.AF.UNIX, std.os.linux.SOCK.STREAM, 0, &fds));
    defer _ = std.os.linux.close(fds[0]);
    defer _ = std.os.linux.close(fds[1]);

    var stage: [4096]u8 = undefined;
    var sink = RespSink{ .fd = fds[1], .buf = &stage };
    tl_resp_sink = &sink;
    defer tl_resp_sink = null;

    const before = sink.len;
    try sendSimpleFD(fds[1], 200, "text/plain", "hi");

    // Header was written directly into the sink: len advanced, nothing flushed yet.
    try std.testing.expect(sink.len > before);
    try std.testing.expect(!sink.failed);

    sink.flush();

    var recv: [512]u8 = undefined;
    const n = try std.posix.read(fds[0], &recv);
    const resp = recv[0..n];
    try std.testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 200 OK\r\n"));
    try std.testing.expect(std.mem.endsWith(u8, resp, "\r\n\r\nhi"));
}

test "zix http1: RespSink stages writeAllFD bytes until flush" {
    var fds: [2]i32 = undefined;
    try std.testing.expectEqual(@as(usize, 0), std.os.linux.socketpair(std.os.linux.AF.UNIX, std.os.linux.SOCK.STREAM, 0, &fds));
    defer _ = std.os.linux.close(fds[0]);
    defer _ = std.os.linux.close(fds[1]);

    var stage: [64]u8 = undefined;
    var sink = RespSink{ .fd = fds[1], .buf = &stage };
    tl_resp_sink = &sink;
    defer tl_resp_sink = null;

    try writeAllFD(fds[1], "alpha");
    try writeAllFD(fds[1], "beta");

    // Both writes are staged, nothing has hit the socket yet.
    try std.testing.expectEqual(@as(usize, 9), sink.len);

    sink.flush();
    try std.testing.expect(!sink.failed);

    var recv: [64]u8 = undefined;
    const n = try std.posix.read(fds[0], &recv);
    try std.testing.expectEqualStrings("alphabeta", recv[0..n]);
}

test "zix http1: sendSimpleFD writes directly into active sink without buf[4096] bounce" {
    var fds: [2]i32 = undefined;
    try std.testing.expectEqual(@as(usize, 0), std.os.linux.socketpair(std.os.linux.AF.UNIX, std.os.linux.SOCK.STREAM, 0, &fds));
    defer _ = std.os.linux.close(fds[0]);
    defer _ = std.os.linux.close(fds[1]);

    var stage: [4096]u8 = undefined;
    var sink = RespSink{ .fd = fds[1], .buf = &stage };
    tl_resp_sink = &sink;
    defer tl_resp_sink = null;

    try sendSimpleFD(fds[1], 200, "text/plain", "ok");

    // Bytes are staged in the sink, nothing sent to the socket yet.
    try std.testing.expect(sink.len > 0);
    try std.testing.expect(!sink.failed);

    sink.flush();

    var recv: [512]u8 = undefined;
    const n = try std.posix.read(fds[0], &recv);
    const resp = recv[0..n];
    try std.testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 200 OK\r\n"));
    try std.testing.expect(std.mem.endsWith(u8, resp, "\r\n\r\nok"));
}

test "zix http1: sendSimpleFD with no active sink writes directly to fd" {
    var fds: [2]i32 = undefined;
    try std.testing.expectEqual(@as(usize, 0), std.os.linux.socketpair(std.os.linux.AF.UNIX, std.os.linux.SOCK.STREAM, 0, &fds));
    defer _ = std.os.linux.close(fds[0]);
    defer _ = std.os.linux.close(fds[1]);

    try sendSimpleFD(fds[1], 404, "text/plain", "not found");

    var recv: [512]u8 = undefined;
    const n = try std.posix.read(fds[0], &recv);
    const resp = recv[0..n];
    try std.testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 404 Not Found\r\n"));
    try std.testing.expect(std.mem.endsWith(u8, resp, "\r\n\r\nnot found"));
}

test "zix http1: cache API is a no-op when no cache is installed" {
    setCache(null, 0);

    const parsed = try parseHead("GET /x HTTP/1.1\r\n\r\n");

    try std.testing.expect(cacheLookup(&parsed.head) == null);

    // store with no cache installed must not crash
    cacheStore(&parsed.head, "whatever", 1000);
    try std.testing.expect(cacheLookup(&parsed.head) == null);
}

test "zix http1: sendWithCacheFD stores then a later lookup hits with identical bytes" {
    var rc = try cache.ResponseCache.init(std.testing.allocator, .{ .max_entries = 16, .max_value_bytes = 256 });
    defer rc.deinit();

    setCache(&rc, 1000);
    defer setCache(null, 0);

    const parsed = try parseHead("GET /thing HTTP/1.1\r\nHost: x\r\n\r\n");
    const head = parsed.head;

    // first request: miss
    try std.testing.expect(cacheLookup(&head) == null);

    var fds: [2]i32 = undefined;
    try std.testing.expectEqual(@as(usize, 0), std.os.linux.socketpair(std.os.linux.AF.UNIX, std.os.linux.SOCK.STREAM, 0, &fds));
    defer _ = std.os.linux.close(fds[0]);
    defer _ = std.os.linux.close(fds[1]);

    const resp = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nhi";
    try sendWithCacheFD(fds[1], &head, resp, cacheTtl());

    var recv: [128]u8 = undefined;
    const n = try std.posix.read(fds[0], &recv);
    try std.testing.expectEqualStrings(resp, recv[0..n]);

    // second request: hit returns the identical cached bytes
    try std.testing.expectEqualStrings(resp, cacheLookup(&head).?);
}

fn negotiatedRoundtrip(req: []const u8, content_type: []const u8, body: []const u8, out: []u8) !usize {
    const parsed = try parseHead(req);

    var fds: [2]i32 = undefined;
    try std.testing.expectEqual(@as(usize, 0), std.os.linux.socketpair(std.os.linux.AF.UNIX, std.os.linux.SOCK.STREAM, 0, &fds));
    defer _ = std.os.linux.close(fds[0]);
    defer _ = std.os.linux.close(fds[1]);

    try sendNegotiateCachedFD(fds[1], &parsed.head, 200, content_type, body);

    return std.posix.read(fds[0], out);
}

test "zix http1: sendNegotiateCachedFD compresses when gzip is accepted" {
    setCompression(true, 256, GZIP_OUT_SIZE);
    defer setCompression(false, 0, 0);

    var body: [512]u8 = undefined;
    for (&body, 0..) |*byte, index| byte.* = @intCast('a' + (index % 16));

    var recv: [1024]u8 = undefined;
    const n = try negotiatedRoundtrip("GET /x HTTP/1.1\r\nAccept-Encoding: gzip\r\n\r\n", "text/plain", &body, &recv);
    const resp = recv[0..n];

    try std.testing.expect(std.mem.indexOf(u8, resp, "Content-Encoding: gzip") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "Vary: Accept-Encoding") != null);

    const sep = std.mem.indexOf(u8, resp, "\r\n\r\n").?;
    const restored = try compression.flate.decompressGzipAlloc(std.testing.allocator, resp[sep + 4 ..], 2048);
    defer std.testing.allocator.free(restored);

    try std.testing.expectEqualSlices(u8, &body, restored);
}

test "zix http1: sendNegotiateCachedFD sends uncompressed when compression is off" {
    setCompression(false, 0, 0);

    var body: [512]u8 = undefined;
    for (&body, 0..) |*byte, index| byte.* = @intCast('a' + (index % 16));

    var recv: [1024]u8 = undefined;
    const n = try negotiatedRoundtrip("GET /x HTTP/1.1\r\nAccept-Encoding: gzip\r\n\r\n", "text/plain", &body, &recv);
    const resp = recv[0..n];

    try std.testing.expect(std.mem.indexOf(u8, resp, "Content-Encoding") == null);

    const sep = std.mem.indexOf(u8, resp, "\r\n\r\n").?;
    try std.testing.expectEqualSlices(u8, &body, resp[sep + 4 ..]);
}

test "zix http1: sendNegotiateCachedFD does not compress without Accept-Encoding" {
    setCompression(true, 256, GZIP_OUT_SIZE);
    defer setCompression(false, 0, 0);

    var body: [512]u8 = undefined;
    for (&body, 0..) |*byte, index| byte.* = @intCast('a' + (index % 16));

    var recv: [1024]u8 = undefined;
    const n = try negotiatedRoundtrip("GET /x HTTP/1.1\r\n\r\n", "text/plain", &body, &recv);
    const resp = recv[0..n];

    try std.testing.expect(std.mem.indexOf(u8, resp, "Content-Encoding") == null);
}

test "zix http1: sendNegotiateCachedFD skips bodies under the size floor" {
    setCompression(true, 256, GZIP_OUT_SIZE);
    defer setCompression(false, 0, 0);

    var recv: [256]u8 = undefined;
    const n = try negotiatedRoundtrip("GET /x HTTP/1.1\r\nAccept-Encoding: gzip\r\n\r\n", "text/plain", "hi", &recv);
    const resp = recv[0..n];

    try std.testing.expect(std.mem.indexOf(u8, resp, "Content-Encoding") == null);
    try std.testing.expect(std.mem.endsWith(u8, resp, "hi"));
}

test "zix http1: sendNegotiateCachedFD skips already-compressed media types" {
    setCompression(true, 256, GZIP_OUT_SIZE);
    defer setCompression(false, 0, 0);

    var body: [512]u8 = undefined;
    for (&body, 0..) |*byte, index| byte.* = @intCast('a' + (index % 16));

    var recv: [1024]u8 = undefined;
    const n = try negotiatedRoundtrip("GET /x HTTP/1.1\r\nAccept-Encoding: gzip\r\n\r\n", "image/jpeg", &body, &recv);
    const resp = recv[0..n];

    try std.testing.expect(std.mem.indexOf(u8, resp, "Content-Encoding") == null);
}

test "zix http1: cache keys separate distinct paths and queries" {
    var rc = try cache.ResponseCache.init(std.testing.allocator, .{ .max_entries = 16, .max_value_bytes = 64 });
    defer rc.deinit();

    setCache(&rc, 1000);
    defer setCache(null, 0);

    const a = try parseHead("GET /a HTTP/1.1\r\n\r\n");
    const b = try parseHead("GET /b HTTP/1.1\r\n\r\n");
    const q = try parseHead("GET /a?v=2 HTTP/1.1\r\n\r\n");

    cacheStore(&a.head, "alpha-resp", 1000);

    // a different path and a different query are both misses
    try std.testing.expect(cacheLookup(&b.head) == null);
    try std.testing.expect(cacheLookup(&q.head) == null);
    try std.testing.expectEqualStrings("alpha-resp", cacheLookup(&a.head).?);
}

test "zix http1: RespSink oversized payload writes through in order" {
    var fds: [2]i32 = undefined;
    try std.testing.expectEqual(@as(usize, 0), std.os.linux.socketpair(std.os.linux.AF.UNIX, std.os.linux.SOCK.STREAM, 0, &fds));
    defer _ = std.os.linux.close(fds[0]);
    defer _ = std.os.linux.close(fds[1]);

    var stage: [8]u8 = undefined;
    var sink = RespSink{ .fd = fds[1], .buf = &stage };
    tl_resp_sink = &sink;
    defer tl_resp_sink = null;

    // "abc" stages, the oversized payload flushes it first then writes
    // through directly, so wire order matches call order.
    try writeAllFD(fds[1], "abc");
    try writeAllFD(fds[1], "0123456789");
    sink.flush();
    try std.testing.expect(!sink.failed);

    var recv: [64]u8 = undefined;
    const n = try std.posix.read(fds[0], &recv);
    try std.testing.expectEqualStrings("abc0123456789", recv[0..n]);
}

test "zix http1: RespSink grows in place instead of flushing when backed by an allocator" {
    const gpa = std.testing.allocator;

    // 8-byte initial buffer, fd -1 so any accidental flush would error and trip
    // failed: the grow path must never touch the socket.
    const buf = try gpa.alloc(u8, 8);
    var sink = RespSink{ .fd = -1, .buf = buf, .grow_allocator = gpa, .grow_cap = 1024 };
    defer gpa.free(sink.buf);

    sink.append("0123456789ABCDEF");

    // Buffer grew to fit, the bytes are staged, nothing was flushed.
    try std.testing.expect(!sink.failed);
    try std.testing.expect(sink.buf.len >= 16);
    try std.testing.expectEqual(@as(usize, 16), sink.len);
    try std.testing.expectEqualStrings("0123456789ABCDEF", sink.buf[0..sink.len]);
}

test "zix http1: RespSink grow refuses past grow_cap" {
    const gpa = std.testing.allocator;

    const buf = try gpa.alloc(u8, 8);
    var sink = RespSink{ .fd = -1, .buf = buf, .grow_allocator = gpa, .grow_cap = 32 };
    defer gpa.free(sink.buf);

    // Past the cap: refuses and leaves buf untouched.
    try std.testing.expect(!sink.grow(64));
    try std.testing.expectEqual(@as(usize, 8), sink.buf.len);

    // Within the cap: grows to a power-of-two that covers need, clamped to cap.
    try std.testing.expect(sink.grow(20));
    try std.testing.expect(sink.buf.len >= 20 and sink.buf.len <= 32);
}

test "zix http1: RespSink grow switches a slab-backed buf to a heap buffer" {
    const gpa = std.testing.allocator;

    // A borrowed (slab-slice) buffer must never be realloc'd: the first grow
    // allocates fresh, copies the staged bytes, and marks the buffer owned.
    var slab_slice: [8]u8 = undefined;
    var sink = RespSink{ .fd = -1, .buf = &slab_slice, .grow_allocator = gpa, .grow_cap = 1024, .buf_owned = false };
    defer if (sink.buf_owned) gpa.free(sink.buf);

    sink.append("01234");
    sink.append("56789ABCDEF");

    try std.testing.expect(!sink.failed);
    try std.testing.expect(sink.buf_owned);
    try std.testing.expect(sink.buf.ptr != @as([*]u8, &slab_slice));
    try std.testing.expectEqualStrings("0123456789ABCDEF", sink.buf[0..sink.len]);
}

test "zix http1: RespSink captures a cache-hit replay zero-copy and materializes it for a batch" {
    var rc = try cache.ResponseCache.init(std.testing.allocator, .{ .max_entries = 16, .max_value_bytes = 256 });
    defer rc.deinit();
    setCache(&rc, 60_000);
    defer setCache(null, 1000);

    const key = cache.hashKey("GET", "/hit", "");
    const stored = "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello";
    try std.testing.expect(rc.store(key, stored, 60_000, 100));
    const cached = rc.lookup(key, 200).?;
    const slot = rc.hitSlot(cached).?;

    var stage: [256]u8 = undefined;
    var sink = RespSink{ .fd = -1, .buf = &stage, .allow_direct = true };
    tl_resp_sink = &sink;
    defer tl_resp_sink = null;

    // First response of the batch is the exact cached slice: borrowed with the
    // slot pinned, nothing copied into the stage buffer.
    try writeAllFD(-1, cached);
    try std.testing.expectEqual(@as(usize, 0), sink.len);
    try std.testing.expectEqual(@intFromPtr(cached.ptr), @intFromPtr(sink.direct.ptr));
    try std.testing.expectEqual(@as(u32, 1), rc.pins[slot]);

    // A second response joins the batch: the borrowed bytes fold back into the
    // stage in request order and the pin drops.
    try writeAllFD(-1, "SECOND");
    try std.testing.expectEqual(@as(usize, 0), sink.direct.len);
    try std.testing.expectEqual(@as(u32, 0), rc.pins[slot]);
    try std.testing.expectEqualStrings(stored ++ "SECOND", sink.buf[0..sink.len]);

    // A plain (non-cache) first write on an empty batch never captures.
    sink.len = 0;
    try writeAllFD(-1, "plain");
    try std.testing.expectEqual(@as(usize, 0), sink.direct.len);
    try std.testing.expectEqualStrings("plain", sink.buf[0..sink.len]);
}

test "zix http1: RespSink without a grow allocator does not grow" {
    var stage: [8]u8 = undefined;
    var sink = RespSink{ .fd = -1, .buf = &stage };

    // EPOLL path (null allocator): grow is a no-op, so a stack or static buffer
    // is never reallocated and overflow stays on the flush path.
    try std.testing.expect(!sink.grow(64));
    try std.testing.expectEqual(@as(usize, 8), sink.buf.len);
}

test "zix http1: sendGzipFD reuses the threadlocal compressor across calls, valid gzip, no leak" {
    const flate = @import("../../utils/compression/flate.zig");
    const linux = std.os.linux;

    var pipe_fds: [2]i32 = undefined;
    try std.testing.expect(std.posix.errno(linux.pipe2(&pipe_fds, .{})) == .SUCCESS);
    defer _ = linux.close(pipe_fds[0]);
    defer _ = linux.close(pipe_fds[1]);

    // two different bodies back to back: the second must NOT carry state from the first.
    const bodies = [_][]const u8{
        "{\"a\":1,\"b\":2,\"msg\":\"world world world world world\"}",
        "{\"different\":true,\"xs\":[1,2,3,4,5,6,7,8,9,10,11,12]}",
    };

    for (bodies) |body| {
        try sendGzipFD(pipe_fds[1], 200, "application/json", body);

        var resp: [4096]u8 = undefined;
        const n = try std.posix.read(pipe_fds[0], &resp);
        const sep = std.mem.indexOf(u8, resp[0..n], "\r\n\r\n").?;
        const gz = resp[sep + 4 .. n];

        var out: [4096]u8 = undefined;
        const dlen = try flate.decompressGzip(gz, &out);
        try std.testing.expectEqualStrings(body, out[0..dlen]);
    }
}

test "zix http1: buildGzipResponse reserve-prefix bytes equal header plus the facade gzip stream" {
    const linux = std.os.linux;

    var pipe_fds: [2]i32 = undefined;
    try std.testing.expect(std.posix.errno(linux.pipe2(&pipe_fds, .{})) == .SUCCESS);
    defer _ = linux.close(pipe_fds[0]);
    defer _ = linux.close(pipe_fds[1]);

    const body = "{\"identity\":\"check check check check check check check\"}";

    try sendGzipFD(pipe_fds[1], 200, "application/json", body);

    var resp: [4096]u8 = undefined;
    const n = try std.posix.read(pipe_fds[0], &resp);

    // The reserve-prefix assembly (compress in place, header right-aligned)
    // must be byte-identical to the plain header + gzip-stream concatenation.
    const stream = try compression.encode(std.testing.allocator, .GZIP, body, .DEFAULT);
    defer std.testing.allocator.free(stream);

    var expect_buf: [4096]u8 = undefined;
    const expect_hdr = try std.fmt.bufPrint(
        &expect_buf,
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Encoding: gzip\r\nContent-Length: {d}\r\n\r\n",
        .{stream.len},
    );
    @memcpy(expect_buf[expect_hdr.len..][0..stream.len], stream);

    try std.testing.expectEqualSlices(u8, expect_buf[0 .. expect_hdr.len + stream.len], resp[0..n]);
}

test "zix http1: sendGzipCachedFD stores per-(key,encoding) and replays the same bytes on a hit" {
    const flate = @import("../../utils/compression/flate.zig");
    const linux = std.os.linux;

    var rc = try cache.ResponseCache.init(std.testing.allocator, .{ .max_entries = 16, .max_value_bytes = 4096 });
    defer rc.deinit();
    setCache(&rc, 60_000);
    defer setCache(null, 1000);

    var pipe_fds: [2]i32 = undefined;
    try std.testing.expect(std.posix.errno(linux.pipe2(&pipe_fds, .{})) == .SUCCESS);
    defer _ = linux.close(pipe_fds[0]);
    defer _ = linux.close(pipe_fds[1]);

    const parsed = try parseHead("GET /json HTTP/1.1\r\nHost: x\r\n\r\n");
    const head = parsed.head;
    const body = "{\"msg\":\"hello hello hello hello hello hello hello\"}";

    // miss: compress + store, the response decompresses back to the body.
    try std.testing.expect(cacheLookupEncoded(&head, "gzip") == null);
    try sendGzipCachedFD(pipe_fds[1], &head, 200, "application/json", body, 60_000);
    try std.testing.expect(cacheLookupEncoded(&head, "gzip") != null);

    var resp1: [4096]u8 = undefined;
    const n1 = try std.posix.read(pipe_fds[0], &resp1);
    const sep1 = std.mem.indexOf(u8, resp1[0..n1], "\r\n\r\n").?;
    var out1: [4096]u8 = undefined;
    const d1 = try flate.decompressGzip(resp1[sep1 + 4 .. n1], &out1);
    try std.testing.expectEqualStrings(body, out1[0..d1]);

    // hit: replay the cached response, byte-identical to the first.
    try sendGzipCachedFD(pipe_fds[1], &head, 200, "application/json", body, 60_000);
    var resp2: [4096]u8 = undefined;
    const n2 = try std.posix.read(pipe_fds[0], &resp2);
    try std.testing.expectEqualSlices(u8, resp1[0..n1], resp2[0..n2]);
}

test "zix http1: sendBrotliFD emits Content-Encoding br and decodes back to the body, no leak" {
    const linux = std.os.linux;

    var pipe_fds: [2]i32 = undefined;
    try std.testing.expect(std.posix.errno(linux.pipe2(&pipe_fds, .{})) == .SUCCESS);
    defer _ = linux.close(pipe_fds[0]);
    defer _ = linux.close(pipe_fds[1]);

    // two different bodies back to back: the arena reset must clear codec state between calls.
    const bodies = [_][]const u8{
        "{\"a\":1,\"b\":2,\"msg\":\"world world world world world\"}",
        "{\"different\":true,\"xs\":[1,2,3,4,5,6,7,8,9,10,11,12]}",
    };

    for (bodies) |body| {
        try sendBrotliFD(pipe_fds[1], 200, "application/json", body);

        var resp: [4096]u8 = undefined;
        const n = try std.posix.read(pipe_fds[0], &resp);
        try std.testing.expect(std.mem.indexOf(u8, resp[0..n], "Content-Encoding: br") != null);

        const sep = std.mem.indexOf(u8, resp[0..n], "\r\n\r\n").?;
        const restored = try compression.decode(std.testing.allocator, .BR, resp[sep + 4 .. n], 4096);
        defer std.testing.allocator.free(restored);

        try std.testing.expectEqualStrings(body, restored);
    }
}

test "zix http1: sendBrotliCachedFD stores under br and replays the same bytes on a hit" {
    const linux = std.os.linux;

    var rc = try cache.ResponseCache.init(std.testing.allocator, .{ .max_entries = 16, .max_value_bytes = 4096 });
    defer rc.deinit();
    setCache(&rc, 60_000);
    defer setCache(null, 1000);

    var pipe_fds: [2]i32 = undefined;
    try std.testing.expect(std.posix.errno(linux.pipe2(&pipe_fds, .{})) == .SUCCESS);
    defer _ = linux.close(pipe_fds[0]);
    defer _ = linux.close(pipe_fds[1]);

    const parsed = try parseHead("GET /json HTTP/1.1\r\nHost: x\r\n\r\n");
    const head = parsed.head;
    const body = "{\"msg\":\"hello hello hello hello hello hello hello\"}";

    // miss: compress + store under the br key, the response decodes back to the body.
    try std.testing.expect(cacheLookupEncoded(&head, "br") == null);
    try sendBrotliCachedFD(pipe_fds[1], &head, 200, "application/json", body, 60_000);
    try std.testing.expect(cacheLookupEncoded(&head, "br") != null);

    var resp1: [4096]u8 = undefined;
    const n1 = try std.posix.read(pipe_fds[0], &resp1);
    const sep1 = std.mem.indexOf(u8, resp1[0..n1], "\r\n\r\n").?;
    const restored = try compression.decode(std.testing.allocator, .BR, resp1[sep1 + 4 .. n1], 4096);
    defer std.testing.allocator.free(restored);
    try std.testing.expectEqualStrings(body, restored);

    // hit: replay the cached response, byte-identical to the first.
    try sendBrotliCachedFD(pipe_fds[1], &head, 200, "application/json", body, 60_000);
    var resp2: [4096]u8 = undefined;
    const n2 = try std.posix.read(pipe_fds[0], &resp2);
    try std.testing.expectEqualSlices(u8, resp1[0..n1], resp2[0..n2]);
}

test "zix http1: sendNegotiateFD compresses without touching the cache" {
    setCompression(true, 256, GZIP_OUT_SIZE);
    defer setCompression(false, 0, 0);

    var rc = try cache.ResponseCache.init(std.testing.allocator, .{ .max_entries = 16, .max_value_bytes = 4096 });
    defer rc.deinit();
    setCache(&rc, 60_000);
    defer setCache(null, 1000);

    const linux = std.os.linux;
    var pipe_fds: [2]i32 = undefined;
    try std.testing.expect(std.posix.errno(linux.pipe2(&pipe_fds, .{})) == .SUCCESS);
    defer _ = linux.close(pipe_fds[0]);
    defer _ = linux.close(pipe_fds[1]);

    const parsed = try parseHead("GET /x HTTP/1.1\r\nAccept-Encoding: gzip\r\n\r\n");
    const head = parsed.head;

    var body: [512]u8 = undefined;
    for (&body, 0..) |*byte, index| byte.* = @intCast('a' + (index % 16));

    try sendNegotiateFD(pipe_fds[1], &head, 200, "text/plain", &body);

    var resp: [1024]u8 = undefined;
    const n = try std.posix.read(pipe_fds[0], &resp);
    try std.testing.expect(std.mem.indexOf(u8, resp[0..n], "Content-Encoding: gzip") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp[0..n], "Vary: Accept-Encoding") != null);

    // uncached: nothing was stored under the negotiated encoding.
    try std.testing.expect(cacheLookupEncoded(&head, "gzip") == null);

    const sep = std.mem.indexOf(u8, resp[0..n], "\r\n\r\n").?;
    const restored = try compression.decode(std.testing.allocator, .GZIP, resp[sep + 4 .. n], 2048);
    defer std.testing.allocator.free(restored);
    try std.testing.expectEqualSlices(u8, &body, restored);
}

test "zix http1: sendNegotiateFD sends uncompressed when no coding is accepted" {
    setCompression(true, 256, GZIP_OUT_SIZE);
    defer setCompression(false, 0, 0);

    const linux = std.os.linux;
    var pipe_fds: [2]i32 = undefined;
    try std.testing.expect(std.posix.errno(linux.pipe2(&pipe_fds, .{})) == .SUCCESS);
    defer _ = linux.close(pipe_fds[0]);
    defer _ = linux.close(pipe_fds[1]);

    const parsed = try parseHead("GET /x HTTP/1.1\r\n\r\n");
    const head = parsed.head;

    var body: [512]u8 = undefined;
    for (&body, 0..) |*byte, index| byte.* = @intCast('a' + (index % 16));

    try sendNegotiateFD(pipe_fds[1], &head, 200, "text/plain", &body);

    var resp: [1024]u8 = undefined;
    const n = try std.posix.read(pipe_fds[0], &resp);
    try std.testing.expect(std.mem.indexOf(u8, resp[0..n], "Content-Encoding") == null);

    const sep = std.mem.indexOf(u8, resp[0..n], "\r\n\r\n").?;
    try std.testing.expectEqualSlices(u8, &body, resp[sep + 4 .. n]);
}

test "zix http1: serveConn drains an over-large body so the keep-alive connection survives" {
    const linux = std.os.linux;

    var pair: [2]std.posix.fd_t = undefined;
    try std.testing.expect(std.posix.errno(linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM, 0, &pair)) == .SUCCESS);
    const client_fd = pair[0];
    const server_fd = pair[1];
    defer _ = linux.close(client_fd);

    const Handler = struct {
        fn h(_: *Request, res: *Response, _: *Context) anyerror!void {
            try res.sendRaw("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok");
        }
    };
    const Srv = struct {
        fn run(fd: std.posix.fd_t) void {
            serveConn(fd, Handler.h, .{ .large_body_rcvbuf = 1 << 20 }, undefined);

            _ = linux.close(fd);
        }
    };
    const t = try std.Thread.spawn(.{}, Srv.run, .{server_fd});
    defer t.join();

    // request 1: a 64 KiB body, well past ASYNC_BODY_CHUNK (8 KiB), so the engine must drain the rest.
    const big: usize = 64 * 1024;
    var head_buf: [128]u8 = undefined;
    const h1 = try std.fmt.bufPrint(&head_buf, "POST /upload HTTP/1.1\r\nHost: x\r\nContent-Length: {d}\r\n\r\n", .{big});
    try writeAllFD(client_fd, h1);

    var chunk: [4096]u8 = @splat(0xAB);
    var body_sent: usize = 0;
    while (body_sent < big) {
        const n = @min(chunk.len, big - body_sent);
        try writeAllFD(client_fd, chunk[0..n]);
        body_sent += n;
    }

    var resp1: [256]u8 = undefined;
    const n1 = try std.posix.read(client_fd, &resp1);
    try std.testing.expect(std.mem.indexOf(u8, resp1[0..n1], "200 OK") != null);

    // request 2 on the SAME connection (Connection: close so the server returns after it): served
    // cleanly only if the first body was fully drained, else the leftover bytes misparse as this one.
    try writeAllFD(client_fd, "GET /ping HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n");

    var resp2: [256]u8 = undefined;
    const n2 = try std.posix.read(client_fd, &resp2);
    try std.testing.expect(std.mem.indexOf(u8, resp2[0..n2], "200 OK") != null);
}
