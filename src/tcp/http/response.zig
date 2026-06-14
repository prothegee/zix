//! zix http response

const std = @import("std");
const Status = @import("status.zig");
const Content = @import("content.zig");
const Request = @import("request.zig").Request;
const rc = @import("../../utils/response_cache.zig");

// --------------------------------------------------------- //

pub const HttpHeader = struct {
    name: []const u8,
    value: []const u8,
};

/// Controls how many custom response headers addHeader() will accept per request.
///
/// max_response_headers in HttpServerConfig sets the cap. The backing buffer is
/// arena-allocated lazily on the first addHeader() call, requests that add no
/// custom headers pay zero allocation cost.
/// Any addHeader() call beyond the cap yields error.TooManyHeaders.
///
/// - MINIMAL (16): simple APIs, constrained environments
/// - COMMON (32): most web applications, single proxy/load balancer (default)
/// - LARGE (64): behind load balancers, CDN + proxy
/// - EXTRA_LARGE (128): k8s, service mesh, many CORS/caching/forwarding headers
/// - CUSTOM (N): explicit non-standard cap
///
/// See docs/headers.md for security guidance and tier selection.
pub const HeaderSize = union(enum) {
    MINIMAL,
    COMMON,
    LARGE,
    EXTRA_LARGE,
    CUSTOM: usize,

    pub fn value(self: HeaderSize) usize {
        return switch (self) {
            .MINIMAL => 16,
            .COMMON => 32,
            .LARGE => 64,
            .EXTRA_LARGE => 128,
            .CUSTOM => |n| n,
        };
    }
};

/// Writer handle returned by Response.stream() for SSE (Server-Sent Events).
/// Writes directly to the raw socket fd, no buffering, no flush needed.
pub const SseWriter = struct {
    fd: std.posix.fd_t,

    /// Sends: data: <data>\n\n
    pub fn writeEvent(self: SseWriter, data: []const u8) !void {
        try fdWriteAll(self.fd, "data: ");
        try fdWriteAll(self.fd, data);
        try fdWriteAll(self.fd, "\n\n");
    }

    /// Sends: event: <event>\ndata: <data>\n\n
    pub fn writeNamedEvent(self: SseWriter, event: []const u8, data: []const u8) !void {
        try fdWriteAll(self.fd, "event: ");
        try fdWriteAll(self.fd, event);
        try fdWriteAll(self.fd, "\ndata: ");
        try fdWriteAll(self.fd, data);
        try fdWriteAll(self.fd, "\n\n");
    }

    /// Sends: : <text>\n  (comment / keepalive heartbeat)
    pub fn comment(self: SseWriter, text: []const u8) !void {
        try fdWriteAll(self.fd, ": ");
        try fdWriteAll(self.fd, text);
        try fdWriteAll(self.fd, "\n");
    }
};

pub const Response = struct {
    /// Raw socket fd: all writes go here directly via posix.write().
    fd: std.posix.fd_t,
    /// keep_alive from the parsed request head (Connection: close = false).
    req_keep_alive: bool,
    io: std.Io,
    allocator: std.mem.Allocator,
    status: Status.Code = .OK,
    content_type: ?Content.Type = null,
    keep_alive: ?bool = null,
    extra_buf: ?[]HttpHeader = null,
    extra_len: usize = 0,
    max_headers: usize,
    date_cache: ?[]const u8 = null,
    /// Set to true by stream() so handleConnection breaks the keep-alive loop after the handler exits.
    streaming: bool = false,
    /// Body bytes set by send(). Read by the server to populate the access log.
    bytes_written: usize = 0,

    pub fn init(fd: std.posix.fd_t, req_keep_alive: bool, io: std.Io, allocator: std.mem.Allocator, max_headers: usize) Response {
        return .{
            .fd = fd,
            .req_keep_alive = req_keep_alive,
            .io = io,
            .allocator = allocator,
            .max_headers = max_headers,
        };
    }

    pub fn setStatus(self: *Response, s: Status.Code) void {
        self.status = s;
    }

    pub fn setContentType(self: *Response, ct: Content.Type) void {
        self.content_type = ct;
    }

    pub fn setKeepAlive(self: *Response, keep_alive: bool) void {
        self.keep_alive = keep_alive;
    }

    /// Append a custom header to the response.
    /// Allocates the full header buffer on the first call (lazy, capacity = max_headers).
    ///
    /// Return:
    /// - error.TooManyHeaders if the header cap is exceeded
    /// - error.InvalidHeaderName or error.InvalidHeaderValue on CR/LF injection
    pub fn addHeader(self: *Response, name: []const u8, value: []const u8) !void {
        for (name) |c| if (c == '\r' or c == '\n') return error.InvalidHeaderName;
        for (value) |c| if (c == '\r' or c == '\n') return error.InvalidHeaderValue;
        if (self.extra_buf == null) {
            if (self.max_headers == 0) return error.TooManyHeaders;
            self.extra_buf = try self.allocator.alloc(HttpHeader, self.max_headers);
        }
        if (self.extra_len >= self.extra_buf.?.len) return error.TooManyHeaders;
        self.extra_buf.?[self.extra_len] = .{ .name = name, .value = value };
        self.extra_len += 1;
    }

    /// Write and flush the HTTP response with the given body.
    /// Fast path (no extra headers, body fits in staging buffer): one posix.write() syscall.
    /// Slow path (extra headers or large body): fixed headers + extra headers + body.
    pub fn send(self: *Response, body_data: []const u8) !void {
        self.bytes_written = body_data.len;
        const fd = self.fd;
        const date_value = self.date_cache orelse "";

        // Stage fixed headers into a 512-byte stack buffer.
        var fixed: [512]u8 = undefined;
        var offset: usize = 0;

        const status_line = Status.statusLine(self.status);
        if (status_line.len > 0) {
            @memcpy(fixed[offset..][0..status_line.len], status_line);
            offset += status_line.len;
        } else {
            const status_str = Status.stringFromEnum(self.status);
            const s = try std.fmt.bufPrint(fixed[offset..], "HTTP/1.1 {d} {s}\r\n", .{ @intFromEnum(self.status), status_str });
            offset += s.len;
        }

        const skip_body_headers = self.status == .NO_CONTENT;
        if (!skip_body_headers) {
            if (self.content_type) |ct| {
                const s = try std.fmt.bufPrint(fixed[offset..], "Content-Type: {s}\r\n", .{ct.asString()});
                offset += s.len;
            }
            const cl_prefix = "Content-Length: ";
            if (offset + cl_prefix.len + 22 > fixed.len) return error.BufferTooSmall;
            @memcpy(fixed[offset..][0..cl_prefix.len], cl_prefix);
            offset += cl_prefix.len;
            offset += writeDecimal(fixed[offset..], body_data.len);
            fixed[offset] = '\r';
            fixed[offset + 1] = '\n';
            offset += 2;
        }
        if (self.keep_alive) |keep_alive| {
            const conn: []const u8 = if (keep_alive and self.req_keep_alive)
                "Connection: keep-alive\r\n"
            else
                "Connection: close\r\n";
            if (offset + conn.len > fixed.len) return error.BufferTooSmall;
            @memcpy(fixed[offset..][0..conn.len], conn);
            offset += conn.len;
        }
        if (date_value.len > 0) {
            const s = try std.fmt.bufPrint(fixed[offset..], "Date: {s}\r\n", .{date_value});
            offset += s.len;
        }

        // Fast path: no extra headers AND body fits in the remaining buffer, one write().
        if (self.extra_len == 0 and offset + 2 + body_data.len <= fixed.len) {
            fixed[offset] = '\r';
            fixed[offset + 1] = '\n';
            offset += 2;
            if (body_data.len > 0) {
                @memcpy(fixed[offset..][0..body_data.len], body_data);
                offset += body_data.len;
            }
            fdWriteAll(fd, fixed[0..offset]) catch return;
            return;
        }

        // Slow path: extra headers present or body too large for the stack buffer.
        // Stage fixed headers + extra headers into a secondary buffer, then write body.
        var slow: [2048]u8 = undefined;
        var slow_off: usize = 0;
        @memcpy(slow[0..offset], fixed[0..offset]);
        slow_off = offset;

        if (self.extra_buf) |extra| {
            for (extra[0..self.extra_len]) |h| {
                const s = std.fmt.bufPrint(slow[slow_off..], "{s}: {s}\r\n", .{ h.name, h.value }) catch {
                    // Extra header too large for staging buffer, write what we have and continue.
                    fdWriteAll(fd, slow[0..slow_off]) catch return;
                    slow_off = 0;
                    const header_str = std.fmt.bufPrint(&slow, "{s}: {s}\r\n", .{ h.name, h.value }) catch continue;
                    fdWriteAll(fd, header_str) catch return;
                    continue;
                };
                slow_off += s.len;
            }
        }
        slow[slow_off] = '\r';
        slow[slow_off + 1] = '\n';
        slow_off += 2;

        if (slow_off + body_data.len <= slow.len) {
            // Body fits in the staging buffer, one write().
            @memcpy(slow[slow_off..][0..body_data.len], body_data);
            slow_off += body_data.len;
            fdWriteAll(fd, slow[0..slow_off]) catch return;
        } else {
            fdWriteAll(fd, slow[0..slow_off]) catch return;
            if (body_data.len > 0) fdWriteAll(fd, body_data) catch return;
        }
    }

    pub fn sendJson(self: *Response, body_data: []const u8) !void {
        self.content_type = .APPLICATION_JSON;
        return self.send(body_data);
    }

    /// Begin an SSE (Server-Sent Events) stream and return an SseWriter.
    /// Sends HTTP 200 with Content-Type: text/event-stream (no Content-Length).
    /// Sets res.streaming = true so handleConnection closes after the handler exits.
    /// Requires workers = 1 (Model 1). Long-lived SSE connections exhaust a blocking pool (Model 2).
    pub fn stream(self: *Response) !SseWriter {
        const fd = self.fd;
        const date_value = self.date_cache orelse "";

        var fixed: [256]u8 = undefined;
        var offset: usize = 0;
        const sse_hdr = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: keep-alive\r\n";
        @memcpy(fixed[0..sse_hdr.len], sse_hdr);
        offset += sse_hdr.len;
        if (date_value.len > 0) {
            if (std.fmt.bufPrint(fixed[offset..], "Date: {s}\r\n", .{date_value})) |written| {
                offset += written.len;
            } else |_| {}
        }
        fdWriteAll(fd, fixed[0..offset]) catch return error.BrokenPipe;

        if (self.extra_buf) |extra| {
            for (extra[0..self.extra_len]) |h| {
                var hbuf: [256]u8 = undefined;
                const s = std.fmt.bufPrint(&hbuf, "{s}: {s}\r\n", .{ h.name, h.value }) catch continue;
                fdWriteAll(fd, s) catch return error.BrokenPipe;
            }
        }
        fdWriteAll(fd, "\r\n") catch return error.BrokenPipe;

        self.streaming = true;
        return SseWriter{ .fd = fd };
    }

    pub fn noContent(self: *Response) !void {
        self.status = .NO_CONTENT;
        return self.send("");
    }

    /// Serialize the full HTTP response (status line, headers, body) into out,
    /// in the same byte order as send(). The result is suitable for both writing
    /// and caching verbatim.
    ///
    /// Return:
    /// - ?usize (total bytes written into out, null when out is too small)
    fn buildResponse(self: *Response, body_data: []const u8, out: []u8) ?usize {
        const date_value = self.date_cache orelse "";
        var offset: usize = 0;

        const status_line = Status.statusLine(self.status);
        if (status_line.len > 0) {
            if (offset + status_line.len > out.len) return null;
            @memcpy(out[offset..][0..status_line.len], status_line);
            offset += status_line.len;
        } else {
            const status_str = Status.stringFromEnum(self.status);
            const s = std.fmt.bufPrint(out[offset..], "HTTP/1.1 {d} {s}\r\n", .{ @intFromEnum(self.status), status_str }) catch return null;
            offset += s.len;
        }

        const skip_body_headers = self.status == .NO_CONTENT;
        if (!skip_body_headers) {
            if (self.content_type) |ct| {
                const s = std.fmt.bufPrint(out[offset..], "Content-Type: {s}\r\n", .{ct.asString()}) catch return null;
                offset += s.len;
            }

            const cl_prefix = "Content-Length: ";
            if (offset + cl_prefix.len + 22 > out.len) return null;
            @memcpy(out[offset..][0..cl_prefix.len], cl_prefix);
            offset += cl_prefix.len;
            offset += writeDecimal(out[offset..], body_data.len);
            out[offset] = '\r';
            out[offset + 1] = '\n';
            offset += 2;
        }

        if (self.keep_alive) |keep_alive| {
            const conn: []const u8 = if (keep_alive and self.req_keep_alive)
                "Connection: keep-alive\r\n"
            else
                "Connection: close\r\n";
            if (offset + conn.len > out.len) return null;
            @memcpy(out[offset..][0..conn.len], conn);
            offset += conn.len;
        }

        if (date_value.len > 0) {
            const s = std.fmt.bufPrint(out[offset..], "Date: {s}\r\n", .{date_value}) catch return null;
            offset += s.len;
        }

        if (self.extra_buf) |extra| {
            for (extra[0..self.extra_len]) |h| {
                const s = std.fmt.bufPrint(out[offset..], "{s}: {s}\r\n", .{ h.name, h.value }) catch return null;
                offset += s.len;
            }
        }

        if (offset + 2 + body_data.len > out.len) return null;
        out[offset] = '\r';
        out[offset + 1] = '\n';
        offset += 2;

        if (body_data.len > 0) {
            @memcpy(out[offset..][0..body_data.len], body_data);
            offset += body_data.len;
        }

        return offset;
    }

    /// Look up a cached full response for req and, on a fresh hit, write it
    /// verbatim with no re-serialization. A miss, an expired entry, or no cache
    /// installed on this worker returns false.
    ///
    /// Usage:
    /// ```zig
    /// if (res.serveCached(&req)) return;
    /// const body = buildExpensiveBody(...);
    /// try res.sendCached(&req, body, 0);
    /// ```
    ///
    /// Return:
    /// - bool (true when served from cache, the handler should return)
    pub fn serveCached(self: *Response, req: *const Request) bool {
        const cache = tl_cache orelse return false;
        const bytes = cache.lookup(requestKey(req), rc.nowMillis()) orelse return false;

        self.bytes_written = bytes.len;
        fdWriteAll(self.fd, bytes) catch return true;

        return true;
    }

    /// Serialize the response once, write it, and store it under the request key
    /// for later serveCached hits. ttl_ms of 0 uses the worker default (cacheTtl).
    /// Falls back to a plain send when no cache is installed or the serialized
    /// response exceeds the per-slot cap.
    ///
    /// Param:
    /// req - *const Request (source of the cache key: method, path, query)
    /// body_data - []const u8 (response body)
    /// ttl_ms - u32 (freshness in milliseconds, 0 means the worker default)
    ///
    /// Return:
    /// - !void
    pub fn sendCached(self: *Response, req: *const Request, body_data: []const u8, ttl_ms: u32) !void {
        const cache = tl_cache orelse return self.send(body_data);

        var extra_bytes: usize = 0;
        if (self.extra_buf) |extra| {
            for (extra[0..self.extra_len]) |h| extra_bytes += h.name.len + h.value.len + 4;
        }

        const total = 512 + extra_bytes + body_data.len;
        const buf = self.allocator.alloc(u8, total) catch return self.send(body_data);

        const len = self.buildResponse(body_data, buf) orelse return self.send(body_data);
        self.bytes_written = body_data.len;

        const ttl = if (ttl_ms == 0) tl_cache_ttl_ms else ttl_ms;
        _ = cache.store(requestKey(req), buf[0..len], ttl, rc.nowMillis());

        return fdWriteAll(self.fd, buf[0..len]);
    }
};

// --------------------------------------------------------- //

/// Per-worker response cache installed by the EPOLL worker. Null on workers
/// without a cache, so the Response cache API degrades to a plain send.
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

/// Cache key for a request: method name, path, and query string.
fn requestKey(req: *const Request) u64 {
    return rc.hashKey(@tagName(req.method()), req.path(), req.query());
}

// --------------------------------------------------------- //

/// Raw write: loops until all bytes are written or an error occurs.
/// Uses posix.system.write directly, no std.Io.Writer dispatch on the hot path.
///
/// Return:
/// - error.BrokenPipe on any write failure (caller ignores or propagates)
pub fn fdWriteAll(fd: std.posix.fd_t, data: []const u8) error{BrokenPipe}!void {
    var remaining = data;
    while (remaining.len > 0) {
        const write_result = std.posix.system.write(fd, remaining.ptr, remaining.len);
        switch (std.posix.errno(write_result)) {
            .SUCCESS => {
                const n: usize = @intCast(write_result);
                if (n == 0) return error.BrokenPipe;
                remaining = remaining[n..];
            },
            .INTR => continue,
            else => return error.BrokenPipe,
        }
    }
}

// --------------------------------------------------------- //

/// Hand-rolled usize -> decimal writer for Content-Length in the hot path.
fn writeDecimal(buf: []u8, n: usize) usize {
    if (n == 0) {
        buf[0] = '0';
        return 1;
    }
    var tmp: [20]u8 = undefined;
    var i: usize = 0;
    var x = n;
    while (x > 0) : (x /= 10) {
        tmp[i] = @intCast('0' + (x % 10));
        i += 1;
    }
    var j: usize = 0;
    while (i > 0) {
        i -= 1;
        buf[j] = tmp[i];
        j += 1;
    }
    return j;
}

// --------------------------------------------------------- //

pub fn formatHttpDate(secs: u64, buf: []u8) []u8 {
    const epoch = std.time.epoch;
    const epoch_sec = epoch.EpochSeconds{ .secs = secs };
    const epoch_day = epoch_sec.getEpochDay();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_secs = epoch_sec.getDaySeconds();

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

// --------------------------------------------------------- //
// --------------------------------------------------------- //

test "zix test: http response setters" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var res = Response.init(0, true, undefined, arena.allocator(), 32);

    res.setStatus(.CREATED);
    try std.testing.expectEqual(Status.Code.CREATED, res.status);

    res.setContentType(.APPLICATION_JSON);
    try std.testing.expectEqual(Content.Type.APPLICATION_JSON, res.content_type.?);

    res.setKeepAlive(false);
    try std.testing.expectEqual(@as(?bool, false), res.keep_alive);

    try res.addHeader("X-Test", "Value");
    try std.testing.expectEqual(@as(usize, 1), res.extra_len);
    try std.testing.expectEqualStrings("X-Test", res.extra_buf.?[0].name);
    try std.testing.expectEqualStrings("Value", res.extra_buf.?[0].value);
}

test "zix test: HeaderSize value()" {
    const minimal: HeaderSize = .MINIMAL;
    const common: HeaderSize = .COMMON;
    const large: HeaderSize = .LARGE;
    const xl: HeaderSize = .EXTRA_LARGE;
    try std.testing.expectEqual(@as(usize, 16), minimal.value());
    try std.testing.expectEqual(@as(usize, 32), common.value());
    try std.testing.expectEqual(@as(usize, 64), large.value());
    try std.testing.expectEqual(@as(usize, 128), xl.value());
    try std.testing.expectEqual(@as(usize, 48), (HeaderSize{ .CUSTOM = 48 }).value());
}

test "zix test: addHeader injection guard" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var res = Response.init(0, true, undefined, arena.allocator(), 32);
    try std.testing.expectError(error.InvalidHeaderName, res.addHeader("X-Bad\r\nInject", "val"));
    try std.testing.expectError(error.InvalidHeaderValue, res.addHeader("X-Good", "val\r\nInject"));
}

test "zix test: addHeader TooManyHeaders" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var res = Response.init(0, true, undefined, arena.allocator(), 2);
    try res.addHeader("X-A", "1");
    try res.addHeader("X-B", "2");
    try std.testing.expectError(error.TooManyHeaders, res.addHeader("X-C", "3"));
}

test "zix test: Response.streaming defaults to false" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const res = Response.init(0, true, undefined, arena.allocator(), 32);
    try std.testing.expect(!res.streaming);
}

test "zix test: writeDecimal" {
    var buf: [24]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 1), writeDecimal(&buf, 0));
    try std.testing.expectEqualStrings("0", buf[0..1]);
    try std.testing.expectEqual(@as(usize, 1), writeDecimal(&buf, 7));
    try std.testing.expectEqualStrings("7", buf[0..1]);
    try std.testing.expectEqual(@as(usize, 3), writeDecimal(&buf, 456));
    try std.testing.expectEqualStrings("456", buf[0..3]);
    try std.testing.expectEqual(@as(usize, 4), writeDecimal(&buf, 1024));
    try std.testing.expectEqualStrings("1024", buf[0..4]);
    try std.testing.expectEqual(@as(usize, 10), writeDecimal(&buf, 4294967295));
    try std.testing.expectEqualStrings("4294967295", buf[0..10]);
}

test "zix test: formatHttpDate known timestamps" {
    var buf: [40]u8 = undefined;
    try std.testing.expectEqualStrings("Thu, 01 Jan 1970 00:00:00 GMT", formatHttpDate(0, &buf));
    try std.testing.expectEqualStrings("Sat, 03 Jan 1970 00:00:00 GMT", formatHttpDate(2 * 86400, &buf));
    try std.testing.expectEqualStrings("Thu, 01 Jan 1970 01:01:01 GMT", formatHttpDate(3661, &buf));
    try std.testing.expectEqualStrings("Mon, 28 Feb 2000 12:30:45 GMT", formatHttpDate(951_741_045, &buf));
}

test "zix http response cache: serveCached is a no-op when no cache is installed" {
    setCache(null, 0);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var req = try Request.fromRaw("GET /x HTTP/1.1\r\nHost: x\r\n\r\n", arena.allocator());
    var res = Response.init(0, true, undefined, arena.allocator(), 16);

    try std.testing.expect(!res.serveCached(&req));
}

test "zix http response cache: sendCached stores then serveCached writes identical bytes" {
    var cache = try rc.ResponseCache.init(std.testing.allocator, .{ .max_entries = 16, .max_value_bytes = 512 });
    defer cache.deinit();

    setCache(&cache, 1000);
    defer setCache(null, 0);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var req = try Request.fromRaw("GET /thing HTTP/1.1\r\nHost: x\r\n\r\n", arena.allocator());

    var fds: [2]i32 = undefined;
    try std.testing.expectEqual(@as(usize, 0), std.os.linux.socketpair(std.os.linux.AF.UNIX, std.os.linux.SOCK.STREAM, 0, &fds));
    defer _ = std.os.linux.close(fds[0]);
    defer _ = std.os.linux.close(fds[1]);

    // first request: miss, then build + store + write
    var res = Response.init(fds[1], true, undefined, arena.allocator(), 16);
    try std.testing.expect(!res.serveCached(&req));
    try res.sendCached(&req, "hello", 0);

    var first: [256]u8 = undefined;
    const n1 = try std.posix.read(fds[0], &first);
    try std.testing.expect(std.mem.endsWith(u8, first[0..n1], "\r\n\r\nhello"));

    // second request: hit returns the identical cached bytes
    var res2 = Response.init(fds[1], true, undefined, arena.allocator(), 16);
    try std.testing.expect(res2.serveCached(&req));

    var second: [256]u8 = undefined;
    const n2 = try std.posix.read(fds[0], &second);
    try std.testing.expectEqualStrings(first[0..n1], second[0..n2]);
}

test "zix http response cache: cached bytes match a plain send" {
    var cache = try rc.ResponseCache.init(std.testing.allocator, .{ .max_entries = 16, .max_value_bytes = 512 });
    defer cache.deinit();

    setCache(&cache, 1000);
    defer setCache(null, 0);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var req = try Request.fromRaw("GET /thing HTTP/1.1\r\nHost: x\r\n\r\n", arena.allocator());

    var pair_a: [2]i32 = undefined;
    var pair_b: [2]i32 = undefined;
    try std.testing.expectEqual(@as(usize, 0), std.os.linux.socketpair(std.os.linux.AF.UNIX, std.os.linux.SOCK.STREAM, 0, &pair_a));
    try std.testing.expectEqual(@as(usize, 0), std.os.linux.socketpair(std.os.linux.AF.UNIX, std.os.linux.SOCK.STREAM, 0, &pair_b));
    defer for ([_]i32{ pair_a[0], pair_a[1], pair_b[0], pair_b[1] }) |fd| {
        _ = std.os.linux.close(fd);
    };

    // plain send
    var res_plain = Response.init(pair_a[1], true, undefined, arena.allocator(), 16);
    res_plain.setContentType(.APPLICATION_JSON);
    try res_plain.send("{\"ok\":true}");

    var plain: [256]u8 = undefined;
    const np = try std.posix.read(pair_a[0], &plain);

    // cached send with the same response shape
    var res_cached = Response.init(pair_b[1], true, undefined, arena.allocator(), 16);
    res_cached.setContentType(.APPLICATION_JSON);
    try res_cached.sendCached(&req, "{\"ok\":true}", 0);

    var cached: [256]u8 = undefined;
    const nc = try std.posix.read(pair_b[0], &cached);

    try std.testing.expectEqualStrings(plain[0..np], cached[0..nc]);
}

test "zix http response cache: sendCached without a cache falls back to a plain send" {
    setCache(null, 0);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var req = try Request.fromRaw("GET /x HTTP/1.1\r\nHost: x\r\n\r\n", arena.allocator());

    var fds: [2]i32 = undefined;
    try std.testing.expectEqual(@as(usize, 0), std.os.linux.socketpair(std.os.linux.AF.UNIX, std.os.linux.SOCK.STREAM, 0, &fds));
    defer _ = std.os.linux.close(fds[0]);
    defer _ = std.os.linux.close(fds[1]);

    var res = Response.init(fds[1], true, undefined, arena.allocator(), 16);
    try res.sendCached(&req, "data", 0);

    var recv: [128]u8 = undefined;
    const n = try std.posix.read(fds[0], &recv);
    try std.testing.expect(std.mem.startsWith(u8, recv[0..n], "HTTP/1.1 200 Ok"));
    try std.testing.expect(std.mem.endsWith(u8, recv[0..n], "\r\n\r\ndata"));
}

test "zix http response cache: distinct paths and queries are separate keys" {
    var cache = try rc.ResponseCache.init(std.testing.allocator, .{ .max_entries = 16, .max_value_bytes = 256 });
    defer cache.deinit();

    setCache(&cache, 1000);
    defer setCache(null, 0);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var req_a = try Request.fromRaw("GET /a HTTP/1.1\r\n\r\n", allocator);
    var req_b = try Request.fromRaw("GET /b HTTP/1.1\r\n\r\n", allocator);
    var req_q = try Request.fromRaw("GET /a?v=2 HTTP/1.1\r\n\r\n", allocator);

    var fds: [2]i32 = undefined;
    try std.testing.expectEqual(@as(usize, 0), std.os.linux.socketpair(std.os.linux.AF.UNIX, std.os.linux.SOCK.STREAM, 0, &fds));
    defer _ = std.os.linux.close(fds[0]);
    defer _ = std.os.linux.close(fds[1]);

    var res_a = Response.init(fds[1], true, undefined, allocator, 16);
    try res_a.sendCached(&req_a, "alpha", 0);

    var drain: [128]u8 = undefined;
    _ = try std.posix.read(fds[0], &drain);

    // a different path and a different query are both misses
    var res_b = Response.init(fds[1], true, undefined, allocator, 16);
    var res_q = Response.init(fds[1], true, undefined, allocator, 16);
    try std.testing.expect(!res_b.serveCached(&req_b));
    try std.testing.expect(!res_q.serveCached(&req_q));

    // the original path and query hits
    var res_a2 = Response.init(fds[1], true, undefined, allocator, 16);
    try std.testing.expect(res_a2.serveCached(&req_a));
}
