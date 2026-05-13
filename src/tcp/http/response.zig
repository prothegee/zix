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
/// Any addHeader() call beyond the cap returns error.TooManyHeaders.
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
/// All writes flush immediately so each event reaches the client without buffering.
pub const SseWriter = struct {
    out: *std.Io.Writer,

    /// Sends: data: <data>\n\n
    pub fn writeEvent(self: SseWriter, data: []const u8) !void {
        try self.out.writeAll("data: ");
        try self.out.writeAll(data);
        try self.out.writeAll("\n\n");
        try self.out.flush();
    }

    /// Sends: event: <event>\ndata: <data>\n\n
    pub fn writeNamedEvent(self: SseWriter, event: []const u8, data: []const u8) !void {
        try self.out.print("event: {s}\ndata: {s}\n\n", .{ event, data });
        try self.out.flush();
    }

    /// Sends: : <text>\n  (comment / keepalive heartbeat)
    pub fn comment(self: SseWriter, text: []const u8) !void {
        try self.out.writeAll(": ");
        try self.out.writeAll(text);
        try self.out.writeAll("\n");
        try self.out.flush();
    }
};

pub const Response = struct {
    req: *std.http.Server.Request,
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

    /// Brief:
    /// Initialize a Response for the given request
    ///
    /// Param:
    /// req         - *std.http.Server.Request
    /// io          - std.Io (retained for fallback clock use)
    /// allocator   - std.mem.Allocator (per-request arena)
    /// max_headers - usize (cap from HeaderSize.value(); default .COMMON = 32)
    ///
    /// Return:
    /// Response
    pub fn init(req: *std.http.Server.Request, io: std.Io, allocator: std.mem.Allocator, max_headers: usize) Response {
        return .{
            .req = req,
            .io = io,
            .allocator = allocator,
            .max_headers = max_headers,
        };
    }

    /// Brief:
    /// Set the HTTP response status code
    ///
    /// Param:
    /// s - zix.Tcp.Http.Status.Code
    pub fn setStatus(self: *Response, s: Status.Code) void {
        self.status = s;
    }

    /// Brief:
    /// Set the Content-Type response header
    ///
    /// Param:
    /// ct - zix.HttpContentType
    pub fn setContentType(self: *Response, ct: Content.Type) void {
        self.content_type = ct;
    }

    /// Brief:
    /// Set whether the connection should be kept alive
    ///
    /// Param:
    /// ka - bool
    pub fn setKeepAlive(self: *Response, ka: bool) void {
        self.keep_alive = ka;
    }

    /// Brief:
    /// Append a custom header to the response
    ///
    /// Note:
    /// - Allocates the header buffer on the first call (lazy); subsequent calls reuse it
    /// - Cap is set by HeaderSize in HttpServerConfig (default: 32), returns error.TooManyHeaders if exceeded
    /// - Returns error.InvalidHeaderName if name contains CR or LF (header injection guard)
    /// - Returns error.InvalidHeaderValue if value contains CR or LF (header injection guard)
    ///
    /// Param:
    /// name  - []const u8 (header name)
    /// value - []const u8 (header value)
    ///
    /// Return:
    /// !void
    pub fn addHeader(self: *Response, name: []const u8, value: []const u8) !void {
        for (name) |c| if (c == '\r' or c == '\n') return error.InvalidHeaderName;
        for (value) |c| if (c == '\r' or c == '\n') return error.InvalidHeaderValue;
        if (self.extra_buf == null) {
            const initial = @min(@as(usize, 4), self.max_headers);
            if (initial == 0) return error.TooManyHeaders;
            self.extra_buf = try self.allocator.alloc(HttpHeader, initial);
        } else if (self.extra_len >= self.extra_buf.?.len) {
            if (self.extra_buf.?.len >= self.max_headers) return error.TooManyHeaders;
            const new_cap = @min(self.extra_buf.?.len * 2, self.max_headers);
            const new_buf = try self.allocator.alloc(HttpHeader, new_cap);
            @memcpy(new_buf[0..self.extra_len], self.extra_buf.?[0..self.extra_len]);
            self.extra_buf = new_buf;
        }
        self.extra_buf.?[self.extra_len] = .{ .name = name, .value = value };
        self.extra_len += 1;
    }

    /// Brief:
    /// Write and flush the HTTP response with the given body
    ///
    /// Note:
    /// - Sends status line, Content-Length, Date, and any extra headers
    /// - Content-Type is only sent if explicitly set via setContentType() or sendJson()
    /// - Connection is only sent if explicitly set via setKeepAlive()
    /// - 204 No Content omits Content-Type and Content-Length per RFC 7230
    /// - Status line uses Status.statusLine() lookup for common codes (memcpy);
    ///   uncommon codes fall back to bufPrint
    /// - Fixed headers are staged into a single buffer and flushed in one write
    /// - Date uses the server-cached value (refreshed once per second); proxy-forwarded
    ///   Date header from the request takes priority if present
    ///
    /// Param:
    /// body_data - []const u8
    ///
    /// Return:
    /// !void
    pub fn send(self: *Response, body_data: []const u8) !void {
        const out = self.req.server.out;
        const date_value = self.date_cache orelse "";

        // Stage fixed headers into a 512-byte stack buffer — covers the worst-case
        // fixed header block (~190 bytes) plus most short bodies, single writeAll
        // instead of multiple print() calls reduces vtable dispatch and write overhead.
        var fixed: [512]u8 = undefined;
        var offset: usize = 0;

        // Status line: pre-built lookup for common codes, bufPrint fallback for the rest.
        const sl_const = Status.statusLine(self.status);
        if (sl_const.len > 0) {
            @memcpy(fixed[offset..][0..sl_const.len], sl_const);
            offset += sl_const.len;
        } else {
            const status_text = Status.stringFromEnum(self.status);
            const sl = try std.fmt.bufPrint(fixed[offset..], "HTTP/1.1 {d} {s}\r\n", .{ @intFromEnum(self.status), status_text });
            offset += sl.len;
        }

        // 204 No Content: RFC 7230 forbids Content-Length, Content-Type is also customarily omitted.
        const skip_body_headers = self.status == .NO_CONTENT;
        if (!skip_body_headers) {
            if (self.content_type) |ct_val| {
                const ct = try std.fmt.bufPrint(fixed[offset..], "Content-Type: {s}\r\n", .{ct_val.asString()});
                offset += ct.len;
            }
            // Content-Length: hand-rolled decimal write skips std.fmt machinery.
            const cl_prefix = "Content-Length: ";
            if (offset + cl_prefix.len + 22 > fixed.len) return error.BufferTooSmall;
            @memcpy(fixed[offset..][0..cl_prefix.len], cl_prefix);
            offset += cl_prefix.len;
            offset += writeDecimal(fixed[offset..], body_data.len);
            fixed[offset] = '\r';
            fixed[offset + 1] = '\n';
            offset += 2;
        }
        if (self.keep_alive) |ka| {
            const conn: []const u8 = if (ka and self.req.head.keep_alive) "Connection: keep-alive\r\n" else "Connection: close\r\n";
            if (offset + conn.len > fixed.len) return error.BufferTooSmall;
            @memcpy(fixed[offset..][0..conn.len], conn);
            offset += conn.len;
        }
        const dl = try std.fmt.bufPrint(fixed[offset..], "Date: {s}\r\n", .{date_value});
        offset += dl.len;

        // Fast path: no extra headers + body fits in remaining buffer -> one writeAll + flush.
        // Covers "Hello World", short JSON, and most API responses (body up to ~380 bytes
        // with fixed[512]).
        if (self.extra_len == 0 and offset + 2 + body_data.len <= fixed.len) {
            fixed[offset] = '\r';
            fixed[offset + 1] = '\n';
            offset += 2;
            if (body_data.len > 0) {
                @memcpy(fixed[offset..][0..body_data.len], body_data);
                offset += body_data.len;
            }
            out.writeAll(fixed[0..offset]) catch return;
            out.flush() catch return;
            return;
        }

        // Slow path: extra headers present or body too large for the stack buffer.
        out.writeAll(fixed[0..offset]) catch return;
        if (self.extra_buf) |extra| {
            for (extra[0..self.extra_len]) |h| {
                out.print("{s}: {s}\r\n", .{ h.name, h.value }) catch return;
            }
        }
        out.writeAll("\r\n") catch return;
        if (body_data.len > 0) out.writeAll(body_data) catch return;
        out.flush() catch return;
    }

    /// Brief:
    /// Send response with Content-Type: application/json
    ///
    /// Note:
    /// - Convenience wrapper around send(), sets content_type to application/json
    ///
    /// Param:
    /// body_data - []const u8 (JSON-encoded string)
    ///
    /// Return:
    /// !void
    pub fn sendJson(self: *Response, body_data: []const u8) !void {
        self.content_type = .APPLICATION_JSON;
        return self.send(body_data);
    }

    /// Brief:
    /// Begin an SSE (Server-Sent Events) stream and return an SseWriter
    ///
    /// Note:
    /// - Sends HTTP 200 with Content-Type: text/event-stream, Cache-Control: no-cache —
    ///   no Content-Length, the connection stays open until the handler returns or a write fails
    /// - Sets res.streaming = true so handleConnection closes the connection after the handler exits
    /// - Best used with workers = 1 (Model 1, io.concurrent()); long-lived SSE connections will
    ///   exhaust a blocking pool (Model 2)
    ///
    /// Return:
    /// !SseWriter
    pub fn stream(self: *Response) !SseWriter {
        const out = self.req.server.out;
        const date_value = self.date_cache orelse "";

        var fixed: [256]u8 = undefined;
        var offset: usize = 0;
        const hdr = try std.fmt.bufPrint(fixed[offset..], "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: keep-alive\r\n", .{});
        offset += hdr.len;
        if (date_value.len > 0) {
            const dl = try std.fmt.bufPrint(fixed[offset..], "Date: {s}\r\n", .{date_value});
            offset += dl.len;
        }

        out.writeAll(fixed[0..offset]) catch return error.BrokenPipe;
        if (self.extra_buf) |extra| {
            for (extra[0..self.extra_len]) |h| {
                out.print("{s}: {s}\r\n", .{ h.name, h.value }) catch return error.BrokenPipe;
            }
        }
        out.writeAll("\r\n") catch return error.BrokenPipe;
        out.flush() catch return error.BrokenPipe;

        self.streaming = true;
        return SseWriter{ .out = out };
    }

    /// Brief:
    /// Send a 204 No Content response with an empty body
    ///
    /// Return:
    /// !void
    pub fn noContent(self: *Response) !void {
        self.status = .NO_CONTENT;
        return self.send("");
    }
};

// --------------------------------------------------------- //

/// Hand-rolled usize -> decimal writer for Content-Length in the hot path.
/// Returns the number of bytes written. usize max in base 10 is 20 digits.
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
    const ep = std.time.epoch;
    const es = ep.EpochSeconds{ .secs = secs };
    const epoch_day = es.getEpochDay();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_secs = es.getDaySeconds();

    // Jan 1 1970 = Thursday = day 0; (day % 7 + 4) % 7 maps to 0=Sun…6=Sat
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
    var res = Response.init(undefined, undefined, arena.allocator(), 32);

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
    const extra_large: HeaderSize = .EXTRA_LARGE;
    const custom: HeaderSize = .{ .CUSTOM = 48 };
    try std.testing.expectEqual(@as(usize, 16), minimal.value());
    try std.testing.expectEqual(@as(usize, 32), common.value());
    try std.testing.expectEqual(@as(usize, 64), large.value());
    try std.testing.expectEqual(@as(usize, 128), extra_large.value());
    try std.testing.expectEqual(@as(usize, 48), custom.value());
}

test "zix test: addHeader injection guard" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var res = Response.init(undefined, undefined, arena.allocator(), 32);
    try std.testing.expectError(error.InvalidHeaderName, res.addHeader("X-Bad\r\nInject", "val"));
    try std.testing.expectError(error.InvalidHeaderValue, res.addHeader("X-Good", "val\r\nInject"));
}

test "zix test: addHeader TooManyHeaders" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var res = Response.init(undefined, undefined, arena.allocator(), 2);
    try res.addHeader("X-A", "1");
    try res.addHeader("X-B", "2");
    try std.testing.expectError(error.TooManyHeaders, res.addHeader("X-C", "3"));
}

test "zix test: SseWriter writeEvent format" {
    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    const sse = SseWriter{ .out = &w };
    try sse.writeEvent("hello");
    const expected = "data: hello\n\n";
    try std.testing.expectEqualSlices(u8, expected, buf[0..expected.len]);
}

test "zix test: SseWriter writeNamedEvent format" {
    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    const sse = SseWriter{ .out = &w };
    try sse.writeNamedEvent("tick", "42");
    const expected = "event: tick\ndata: 42\n\n";
    try std.testing.expectEqualSlices(u8, expected, buf[0..expected.len]);
}

test "zix test: SseWriter comment format" {
    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    const sse = SseWriter{ .out = &w };
    try sse.comment("heartbeat");
    const expected = ": heartbeat\n";
    try std.testing.expectEqualSlices(u8, expected, buf[0..expected.len]);
}

test "zix test: Response.streaming defaults to false" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const res = Response.init(undefined, undefined, arena.allocator(), 32);
    try std.testing.expect(!res.streaming);
}

test "zix test: writeDecimal" {
    var buf: [24]u8 = undefined;

    // zero
    try std.testing.expectEqual(@as(usize, 1), writeDecimal(&buf, 0));
    try std.testing.expectEqualStrings("0", buf[0..1]);

    // single digit
    try std.testing.expectEqual(@as(usize, 1), writeDecimal(&buf, 7));
    try std.testing.expectEqualStrings("7", buf[0..1]);

    // multi-digit
    try std.testing.expectEqual(@as(usize, 3), writeDecimal(&buf, 456));
    try std.testing.expectEqualStrings("456", buf[0..3]);

    // typical Content-Length values
    try std.testing.expectEqual(@as(usize, 2), writeDecimal(&buf, 64));
    try std.testing.expectEqualStrings("64", buf[0..2]);
    try std.testing.expectEqual(@as(usize, 4), writeDecimal(&buf, 1024));
    try std.testing.expectEqualStrings("1024", buf[0..4]);
    try std.testing.expectEqual(@as(usize, 5), writeDecimal(&buf, 65535));
    try std.testing.expectEqualStrings("65535", buf[0..5]);

    // large value (u32 max)
    try std.testing.expectEqual(@as(usize, 10), writeDecimal(&buf, 4294967295));
    try std.testing.expectEqualStrings("4294967295", buf[0..10]);
}

test "zix test: formatHttpDate known timestamps" {
    var buf: [40]u8 = undefined;

    // Unix epoch origin: Thu Jan 1 1970 00:00:00 GMT
    try std.testing.expectEqualStrings("Thu, 01 Jan 1970 00:00:00 GMT", formatHttpDate(0, &buf));

    // Jan 3 1970 (Saturday) 00:00:00 GMT — 2 days after epoch
    try std.testing.expectEqualStrings("Sat, 03 Jan 1970 00:00:00 GMT", formatHttpDate(2 * 86400, &buf));

    // Jan 1 1970 01:01:01 GMT — time components
    try std.testing.expectEqualStrings("Thu, 01 Jan 1970 01:01:01 GMT", formatHttpDate(3661, &buf));

    // Feb 28 2000 12:30:45 GMT — leap year boundary
    // 11015 days * 86400 + 45045 secs (12*3600 + 30*60 + 45)
    try std.testing.expectEqualStrings("Mon, 28 Feb 2000 12:30:45 GMT", formatHttpDate(951_741_045, &buf));
}
