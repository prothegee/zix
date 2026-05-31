//! zix http response

const std = @import("std");
const Status = @import("status.zig");
const Content = @import("content.zig");

pub const HttpHeader = struct {
    name: []const u8,
    value: []const u8,
};

/// Controls how many custom response headers addHeader() will accept per request.
///
/// max_response_headers in HttpServerConfig sets the cap. The backing buffer is
/// arena-allocated lazily on the first addHeader() call — requests that add no
/// custom headers pay zero allocation cost.
/// Any addHeader() call beyond the cap yields error.TooManyHeaders.
///
/// - MINIMAL     (16)  — simple APIs, constrained environments
/// - COMMON      (32)  — most web applications, single proxy/load balancer (default)
/// - LARGE       (64)  — behind load balancers, CDN + proxy
/// - EXTRA_LARGE (128) — k8s, service mesh, many CORS/caching/forwarding headers
/// - CUSTOM      (N)   — explicit non-standard cap
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
/// Writes directly to the raw socket fd — no buffering, no flush needed.
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
    /// Raw socket fd — all writes go here directly via posix.write().
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

        // Fast path: no extra headers AND body fits in the remaining buffer — one write().
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
                    // Extra header too large for staging buffer — write what we have and continue.
                    fdWriteAll(fd, slow[0..slow_off]) catch return;
                    slow_off = 0;
                    const s2 = std.fmt.bufPrint(&slow, "{s}: {s}\r\n", .{ h.name, h.value }) catch continue;
                    fdWriteAll(fd, s2) catch return;
                    continue;
                };
                slow_off += s.len;
            }
        }
        slow[slow_off] = '\r';
        slow[slow_off + 1] = '\n';
        slow_off += 2;

        if (slow_off + body_data.len <= slow.len) {
            // Body fits in the staging buffer — one write().
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
};

// --------------------------------------------------------- //

/// Raw write: loops until all bytes are written or an error occurs.
/// Uses posix.system.write directly — no std.Io.Writer dispatch on the hot path.
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
