//! zix http1 core: zero-alloc HTTP/1.x request parsing and response writing.
//! All parsing operates on caller-owned buffers. No std.http dependency.

const std = @import("std");
const cache = @import("../../utils/response_cache.zig");
const compression = @import("../../utils/compression/compression.zig");
const ZIG_SEMVER = @import("../../lib.zig").ZIG_SEMVER;

pub const BUF_SIZE: usize = 16 * 1024;
const GZIP_OUT_SIZE: usize = 256 * 1024;

/// Scratch buffer for building one HTTP status line plus its headers.
const HEADER_BUF_SIZE: usize = 256;

/// Inline write fast-path buffer. A response whose status line, headers, and
/// body all fit here is sent in one direct write, skipping the iovec scatter
/// path. The body threshold is this minus HEADER_BUF_SIZE.
const SMALL_BODY_INLINE_BUF: usize = 4096;

/// Body read chunk for the ASYNC serve loop: bytes drained per recv after the head.
const ASYNC_BODY_CHUNK: usize = 8 * 1024;

pub const ParseResult = struct {
    head: ParsedHead,
    body_offset: usize,
};

pub const ParsedHead = struct {
    method: []const u8,
    path: []const u8,
    query: []const u8,
    /// Raw header block from the byte after the request line CRLF up to and
    /// including the final header CRLF. Empty when the request has no headers.
    /// Use getHeader to look up individual headers on demand.
    raw_headers: []const u8,
    version_minor: u8,
    keep_alive: bool,
    content_length: u64,
    chunked_request: bool,
    expect_continue: bool,
};

pub const Range = struct { start: u64, end: u64 };

/// Handler signature. All slices are valid only for the duration of the call.
pub const HandlerFn = *const fn (
    head: *const ParsedHead,
    body: []const u8,
    fd: std.posix.fd_t,
) void;

/// Optional raw-request interceptor for the EPOLL dispatch model.
/// Called after the "\r\n\r\n" header boundary is found, before any parsing.
/// rem is the full request slice (method line through end of headers + body).
/// header_end is the byte offset of the "\r\n\r\n" sequence within rem.
/// fd is the connection file descriptor for writing a response.
///
/// Return:
/// - usize: consumed request length when the interceptor handled the request.
///   The interceptor must write its response (via writeAllFD or tl_resp_sink)
///   before returning. HTTP/1.1 keep-alive is assumed.
/// - null: fall through to the normal parse-and-dispatch path.
pub const RawFn = *const fn (rem: []const u8, header_end: usize, fd: std.posix.fd_t) ?usize;

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
/// fd      - std.posix.fd_t (the connection, write replies with WebSocket.send)
/// opcode  - u8 (RFC 6455 opcode, .text or .binary in practice)
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
/// fn handler(head: *const zix.Http1.ParsedHead, body: []const u8, fd: std.posix.fd_t) void {
///     if (zix.Http1.cacheLookup(head)) |bytes| {
///         zix.Http1.writeAllFD(fd, bytes) catch {};
///         return;
///     }
///
///     const resp = buildResponse(head, body);
///     zix.Http1.sendWithCacheFD(fd, head, resp, zix.Http1.cacheTtl()) catch {};
/// }
/// ```
pub fn sendWithCacheFD(fd: std.posix.fd_t, head: *const ParsedHead, bytes: []const u8, ttl_ms: u32) error{BrokenPipe}!void {
    cacheStore(head, bytes, ttl_ms);

    return writeAllFD(fd, bytes);
}

// --------------------------------------------------------- //

/// Parse a complete HTTP/1.x request from buf where header_end (the index of
/// \r\n\r\n in buf) is already known. Avoids the redundant indexOf scan when
/// the caller has already located the terminator. buf may extend beyond
/// header_end + 4 (body bytes are ignored).
///
/// Note:
/// - Framing pass: a header line is tokenized only when its first letter is
///   c, t, or e (the only letters that start a framing-relevant header:
///   content-length, connection, transfer-encoding, expect). All other lines
///   skip with one indexOfPos plus one masked compare.
///
/// Return:
/// - !struct{ head: ParsedHead, body_offset: usize }
/// - error.InvalidRequest on a malformed request line
pub fn parseHeadAt(buf: []const u8, header_end: usize) !ParseResult {
    const body_offset = header_end + 4;

    const first_crlf = std.mem.indexOf(u8, buf[0..header_end], "\r\n") orelse header_end;
    const req_line = buf[0..first_crlf];

    const sp1 = std.mem.indexOfScalar(u8, req_line, ' ') orelse return error.InvalidRequest;
    if (sp1 == 0) return error.InvalidRequest;
    const method = req_line[0..sp1];

    const rest = req_line[sp1 + 1 ..];
    const sp2 = std.mem.lastIndexOfScalar(u8, rest, ' ') orelse return error.InvalidRequest;
    const target = rest[0..sp2];
    const version_str = rest[sp2 + 1 ..];

    const version_minor: u8 = if (std.mem.eql(u8, version_str, "HTTP/1.1"))
        1
    else if (std.mem.eql(u8, version_str, "HTTP/1.0"))
        0
    else
        return error.InvalidRequest;

    var path = target;
    var query: []const u8 = "";
    if (std.mem.indexOfScalar(u8, target, '?')) |question_mark| {
        path = target[0..question_mark];
        query = target[question_mark + 1 ..];
    }

    const raw_headers: []const u8 = if (first_crlf >= header_end)
        buf[0..0]
    else
        buf[first_crlf + 2 .. header_end + 2];

    var keep_alive = (version_minor == 1);
    var content_length: u64 = 0;
    var chunked_request = false;
    var expect_continue = false;

    var pos: usize = 0;
    while (pos < raw_headers.len) {
        const line_end = std.mem.indexOfPos(u8, raw_headers, pos, "\r\n") orelse raw_headers.len;
        const line = raw_headers[pos..line_end];
        pos = line_end + 2;
        if (line.len == 0) break;

        const first_lower = line[0] | 0x20;
        if (first_lower != 'c' and first_lower != 't' and first_lower != 'e') continue;

        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = line[0..colon];
        var value_off: usize = colon + 1;
        while (value_off < line.len and line[value_off] == ' ') value_off += 1;
        const value = line[value_off..];

        if (std.ascii.eqlIgnoreCase(name, "content-length")) {
            content_length = std.fmt.parseInt(u64, value, 10) catch 0;
        } else if (std.ascii.eqlIgnoreCase(name, "connection")) {
            if (std.ascii.eqlIgnoreCase(value, "close")) keep_alive = false;
            if (std.ascii.eqlIgnoreCase(value, "keep-alive")) keep_alive = true;
        } else if (std.ascii.eqlIgnoreCase(name, "transfer-encoding")) {
            const chunked_pos = if (comptime ZIG_SEMVER.MINOR == 16)
                std.ascii.indexOfIgnoreCase(value, "chunked")
            else
                std.ascii.findIgnoreCase(value, "chunked");

            if (chunked_pos != null) chunked_request = true;
        } else if (std.ascii.eqlIgnoreCase(name, "expect")) {
            if (std.ascii.eqlIgnoreCase(value, "100-continue")) expect_continue = true;
        }
    }

    return .{ .head = .{
        .method = method,
        .path = path,
        .query = query,
        .raw_headers = raw_headers,
        .version_minor = version_minor,
        .keep_alive = keep_alive,
        .content_length = content_length,
        .chunked_request = chunked_request,
        .expect_continue = expect_continue,
    }, .body_offset = body_offset };
}

/// Parse a complete HTTP/1.x request from buf.
/// buf must contain the full header block ending with \r\n\r\n.
/// All slices in ParsedHead point into buf (zero copy).
///
/// Return:
/// - !struct{ head: ParsedHead, body_offset: usize }
/// - error.IncompleteHeader when \r\n\r\n has not arrived yet
/// - error.InvalidRequest on a malformed request line
pub fn parseHead(buf: []const u8) !ParseResult {
    const header_end = std.mem.indexOf(u8, buf, "\r\n\r\n") orelse return error.IncompleteHeader;
    return parseHeadAt(buf, header_end);
}

/// Case-insensitive header lookup, scanning raw_headers on demand.
/// Cost is paid only by handlers that actually read a header.
pub fn getHeader(head: *const ParsedHead, name: []const u8) ?[]const u8 {
    var pos: usize = 0;
    while (pos < head.raw_headers.len) {
        const line_end = std.mem.indexOfPos(u8, head.raw_headers, pos, "\r\n") orelse head.raw_headers.len;
        const line = head.raw_headers[pos..line_end];
        pos = line_end + 2;
        if (line.len == 0) break;

        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (!std.ascii.eqlIgnoreCase(line[0..colon], name)) continue;

        var value_off: usize = colon + 1;
        while (value_off < line.len and line[value_off] == ' ') value_off += 1;

        return line[value_off..];
    }

    return null;
}

/// Linear scan for a single query parameter by exact name.
/// Does not percent-decode keys or values.
///
/// Return:
/// - ?[]const u8 (raw value slice, or null if not found)
pub fn queryParam(head: *const ParsedHead, name: []const u8) ?[]const u8 {
    if (head.query.len == 0) return null;

    var it = std.mem.splitScalar(u8, head.query, '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (std.mem.eql(u8, pair[0..eq], name)) return pair[eq + 1 ..];
    }

    return null;
}

/// Percent-decode buf in place.
///
/// Return:
/// - []u8 (decoded slice, shorter or equal length)
pub fn percentDecode(buf: []u8) []u8 {
    return std.Uri.percentDecodeInPlace(buf);
}

/// Parse "bytes=start-end" or "bytes=start-" (open-ended).
///
/// Return:
/// - ?Range (null for invalid or unsatisfiable range)
pub fn parseRange(val: []const u8, total: u64) ?Range {
    if (!std.mem.startsWith(u8, val, "bytes=")) return null;
    const spec = val[6..];
    const dash = std.mem.indexOfScalar(u8, spec, '-') orelse return null;
    if (total == 0) return null;

    const start_str = spec[0..dash];
    const end_str = spec[dash + 1 ..];

    const start = std.fmt.parseInt(u64, start_str, 10) catch return null;
    if (start >= total) return null;

    const end: u64 = if (end_str.len == 0)
        total - 1
    else blk: {
        const e = std.fmt.parseInt(u64, end_str, 10) catch return null;
        break :blk if (e >= total) total - 1 else e;
    };

    if (start > end) return null;
    return .{ .start = start, .end = end };
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
/// reads these because the HandlerFn carries only (head, body, fd), never io, so the public_dir and
/// io are threaded down per worker the same way the date / cache / compression switches are.
pub threadlocal var tl_static_dir: []const u8 = "";
pub threadlocal var tl_static_io: ?std.Io = null;

/// Install the static-serve root and io for this worker thread. Called once per worker at startup.
/// An empty public_dir leaves static serving off (the router falls straight through to 404).
pub fn setStatic(public_dir: []const u8, io: std.Io) void {
    tl_static_dir = public_dir;
    tl_static_io = io;
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
fn buildSimpleHeaderInto(buf: []u8, status: u16, content_type: []const u8, body_len: usize) usize {
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
/// WebSocket SendSink, owned by the EPOLL request loop in server.zig.
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

        const grown = gpa.realloc(self.buf, new_len) catch return false;
        self.buf = grown;

        return true;
    }
};

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

/// Begin a streaming response (SSE) from an fd-handler, so one handler serves cleartext and TLS.
///
/// Detaches any buffered capture / coalescing sink, so each subsequent writeAllFD flushes
/// immediately: over TLS it hands writes to the live-session stream sink (one record per write), in
/// cleartext it writes straight to the socket. An SSE handler never returns, so a buffered sink
/// would never flush. A no-op when no sink is installed (the cleartext .ASYNC SSE path).
///
/// Usage:
/// ```zig
/// fn eventsHandler(head: *const ParsedHead, body: []const u8, fd: std.posix.fd_t) void {
///     zix.Http1.beginStream();
///     zix.Http1.writeAllFD(fd, sse_headers) catch return;
///     // ... emit events with writeAllFD(fd, ...) ...
/// }
/// ```
pub fn beginStream() void {
    if (tl_resp_sink) |sink| {
        sink.flush();
        tl_resp_sink = null;
    }
}

/// Flush any response bytes still staged for fd. Handlers that write to the
/// fd directly (sendfile, raw send) must call this first so the wire order
/// matches the request order under pipelining. No-op when nothing is staged.
pub fn flushPending(fd: std.posix.fd_t) void {
    if (tl_resp_sink) |sink| {
        if (sink.fd == fd) sink.flush();
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

pub fn writeAllFD(fd: std.posix.fd_t, data: []const u8) error{BrokenPipe}!void {
    if (tl_resp_sink) |sink| {
        if (sink.fd == fd) {
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

/// Per-worker (threadlocal) gzip scratch, reused across requests so the response path never
/// allocates. The Compress state is about 225 KB, the window 64 KB, the output 64 KB. A
/// per-request heap alloc of these would overflow SmpAllocator's 32 KB size class and fall to
/// mmap / munmap, whose process mmap_lock + TLB-shootdown serializes every worker (the json-comp
/// low-CPU stall). Threadlocal storage is mapped once per worker thread and reused, so the hot
/// path issues zero allocation syscalls. The compressor is held as an error-union slot and built
/// in place (sret), never as a 225 KB stack temporary.
threadlocal var tl_gzip_out: [GZIP_OUT_SIZE]u8 = undefined;
threadlocal var tl_gzip_window: [std.compress.flate.max_window_len]u8 = undefined;
threadlocal var tl_gzip_comp: std.Io.Writer.Error!std.compress.flate.Compress = undefined;
/// Full gzip response (header + compressed body) assembled contiguously, so it writes in one call
/// and can be stored in the response cache as a single replayable blob.
threadlocal var tl_gzip_resp: [HEADER_BUF_SIZE + GZIP_OUT_SIZE]u8 = undefined;

/// Build a complete gzip HTTP response (header + compressed body) into the per-worker buffer and
/// return the slice. Reuses the threadlocal compressor, so it allocates nothing. Shared by sendGzipFD
/// and sendGzipCachedFD.
fn buildGzipResponse(status: u16, content_type: []const u8, body: []const u8) ![]const u8 {
    var out_w: std.Io.Writer = .fixed(&tl_gzip_out);
    tl_gzip_comp = std.compress.flate.Compress.init(
        &out_w,
        &tl_gzip_window,
        .gzip,
        std.compress.flate.Compress.Options.default,
    );

    const comp: *std.compress.flate.Compress = if (tl_gzip_comp) |*payload| payload else |_| return error.CompressFailed;
    try comp.writer.writeAll(body);
    try comp.finish();

    const compressed = out_w.buffered();
    const header = try std.fmt.bufPrint(
        &tl_gzip_resp,
        "HTTP/1.1 {d} {s}\r\nContent-Type: {s}\r\nContent-Encoding: gzip\r\nContent-Length: {d}\r\n\r\n",
        .{ status, statusPhrase(status), content_type, compressed.len },
    );
    const total = header.len + compressed.len;

    @memcpy(tl_gzip_resp[header.len..total], compressed);

    return tl_gzip_resp[0..total];
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
/// so it routes through the shared compression facade on the per-worker encode arena rather than a
/// flate-style threadlocal compressor. Shared by sendBrotliFD and sendBrotliCachedFD.
fn buildBrotliResponse(status: u16, content_type: []const u8, body: []const u8) ![]const u8 {
    const arena = encodeArena();
    defer _ = arena.reset(.retain_capacity);

    const encoded = try compression.encode(arena.allocator(), .BR, body, .DEFAULT);

    const header = try std.fmt.bufPrint(
        &tl_neg_resp,
        "HTTP/1.1 {d} {s}\r\nContent-Type: {s}\r\nContent-Encoding: br\r\nContent-Length: {d}\r\n\r\n",
        .{ status, statusPhrase(status), content_type, encoded.len },
    );
    const total = header.len + encoded.len;

    if (total > tl_neg_resp.len) return error.ResponseTooLarge;

    @memcpy(tl_neg_resp[header.len..total], encoded);

    return tl_neg_resp[0..total];
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

/// Full negotiated response (header + encoded body) assembled contiguously so it writes in one call
/// and stores in the per-(key, encoding) cache as a single replayable blob. Sized for the default
/// compressed-output cap. A larger response streams in two parts and skips the cache.
threadlocal var tl_neg_resp: [HEADER_BUF_SIZE + GZIP_OUT_SIZE]u8 = undefined;

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

    const accept = getHeader(head, "accept-encoding");
    const encoding = compression.negotiate(accept, &compression.supported_default) orelse {
        return sendSimpleNoBodyFD(fd, 406, content_type, 0);
    };

    if (encoding == .IDENTITY or !compression.shouldCompress(body.len, content_type, tl_compression_min_size)) {
        return sendSimpleFD(fd, status, content_type, body);
    }

    const token = encoding.contentEncoding().?;

    // Per-(key, encoding) cache hit: replay the full compressed response, no compression work.
    if (cacheLookupEncoded(head, token)) |cached| return writeAllFD(fd, cached);

    // Per-worker arena for the codec scratch. gzip / deflate / brotli each allocate transient
    // buffers (brotli especially: input-sized hash tables, Huffman tables, command lists). A
    // per-request smp_allocator would mmap the larger ones over the 32 KiB size class and serialize
    // workers in the kernel. The arena is retained across requests, so after warmup the codec path
    // issues no allocation syscalls. The reset(.retain_capacity) call reclaims every codec buffer
    // after the response is written.
    const arena = encodeArena();
    defer _ = arena.reset(.retain_capacity);

    const encoded = compression.encode(arena.allocator(), encoding, body, .DEFAULT) catch {
        return sendSimpleFD(fd, status, content_type, body);
    };

    if (encoded.len > tl_compression_max_out or encoded.len >= body.len) {
        return sendSimpleFD(fd, status, content_type, body);
    }

    // Assemble the full response (header + encoded body) contiguously so it can be cached and
    // replayed on the next request with the same (key, encoding).
    const header = try std.fmt.bufPrint(
        &tl_neg_resp,
        "HTTP/1.1 {d} {s}\r\nContent-Type: {s}\r\nContent-Encoding: {s}\r\nVary: Accept-Encoding\r\nContent-Length: {d}\r\n\r\n",
        .{ status, statusPhrase(status), content_type, token, encoded.len },
    );
    const total = header.len + encoded.len;

    if (total <= tl_neg_resp.len) {
        @memcpy(tl_neg_resp[header.len..total], encoded);
        const full = tl_neg_resp[0..total];
        cacheStoreEncoded(head, token, full, cacheTtl());

        return writeAllFD(fd, full);
    }

    // Too large to assemble in the buffer: stream in two parts, skip the cache.
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

    const accept = getHeader(head, "accept-encoding");
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

pub const ConnOutcome = enum { keep_alive, close };

/// Keep-alive connection loop. The caller owns closing the fd. Pass raw fd extracted
/// from the accepted stream.
pub fn serveConn(fd: std.posix.fd_t, handler: HandlerFn, opts: ServeOpts) void {
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
        handler(&head, body_buf[0..body_len], fd);

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

test "zix http1: parseHead, GET request fields" {
    const result = try parseHead("GET /ping HTTP/1.1\r\nHost: localhost\r\n\r\n");
    try std.testing.expectEqualStrings("GET", result.head.method);
    try std.testing.expectEqualStrings("/ping", result.head.path);
    try std.testing.expectEqualStrings("", result.head.query);
    try std.testing.expectEqual(@as(u8, 1), result.head.version_minor);
    try std.testing.expect(result.head.keep_alive);
}

test "zix http1: parseHead, query string split from path" {
    const result = try parseHead("GET /search?q=zig&page=2 HTTP/1.1\r\n\r\n");
    try std.testing.expectEqualStrings("/search", result.head.path);
    try std.testing.expectEqualStrings("q=zig&page=2", result.head.query);
}

test "zix http1: parseHead, POST with Content-Length" {
    const result = try parseHead("POST /api HTTP/1.1\r\nContent-Length: 13\r\n\r\n");
    try std.testing.expectEqualStrings("POST", result.head.method);
    try std.testing.expectEqual(@as(u64, 13), result.head.content_length);
}

test "zix http1: parseHead, HTTP/1.0 defaults keep_alive to false" {
    const result = try parseHead("GET / HTTP/1.0\r\nHost: localhost\r\n\r\n");
    try std.testing.expectEqual(@as(u8, 0), result.head.version_minor);
    try std.testing.expect(!result.head.keep_alive);
}

test "zix http1: parseHead, Connection keep-alive overrides HTTP/1.0 default" {
    const result = try parseHead("GET / HTTP/1.0\r\nConnection: keep-alive\r\n\r\n");
    try std.testing.expect(result.head.keep_alive);
}

test "zix http1: parseHead, Expect: 100-continue sets flag" {
    const result = try parseHead("POST /up HTTP/1.1\r\nContent-Length: 512\r\nExpect: 100-continue\r\n\r\n");
    try std.testing.expect(result.head.expect_continue);
}

test "zix http1: getHeader, case-insensitive lookup" {
    const result = try parseHead("GET / HTTP/1.1\r\nContent-Type: text/plain\r\n\r\n");
    try std.testing.expectEqualStrings("text/plain", getHeader(&result.head, "content-type").?);
    try std.testing.expectEqualStrings("text/plain", getHeader(&result.head, "CONTENT-TYPE").?);
    try std.testing.expect(getHeader(&result.head, "x-missing") == null);
}

test "zix http1: queryParam, single and multiple params" {
    const result = try parseHead("GET /p?name=alice&age=30 HTTP/1.1\r\n\r\n");
    try std.testing.expectEqualStrings("alice", queryParam(&result.head, "name").?);
    try std.testing.expectEqualStrings("30", queryParam(&result.head, "age").?);
    try std.testing.expect(queryParam(&result.head, "missing") == null);
}

test "zix http1: parseRange, valid and boundary cases" {
    try std.testing.expectEqual(Range{ .start = 0, .end = 99 }, parseRange("bytes=0-99", 200).?);
    try std.testing.expectEqual(Range{ .start = 100, .end = 199 }, parseRange("bytes=100-", 200).?);
    try std.testing.expectEqual(Range{ .start = 0, .end = 199 }, parseRange("bytes=0-999", 200).?);
    try std.testing.expect(parseRange("bytes=200-", 200) == null);
    try std.testing.expect(parseRange("notbytes=0-99", 200) == null);
}

test "zix http1: percentDecode, encoded chars decoded in place" {
    var buf = [_]u8{ 'a', '%', '2', '0', 'b' };
    const decoded = percentDecode(&buf);
    try std.testing.expectEqualStrings("a b", decoded);
}

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
        fn h(head: *const ParsedHead, body: []const u8, fd: std.posix.fd_t) void {
            _ = head;
            _ = body;
            writeAllFD(fd, "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok") catch {};
        }
    };
    const Srv = struct {
        fn run(fd: std.posix.fd_t) void {
            serveConn(fd, Handler.h, .{ .large_body_rcvbuf = 1 << 20 });

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
