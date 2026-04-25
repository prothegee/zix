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
/// max_response_headers in HttpServerConfig sets the cap, the backing buffer is
/// arena-allocated per request to exactly that size — no waste, no false ceiling.
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

pub const Response = struct {
    req: *std.http.Server.Request,
    allocator: std.mem.Allocator,
    status: Status.Code = .OK,
    content_type: Content.Type = .TEXT_PLAIN,
    keep_alive: bool = true,
    extra_buf: []HttpHeader,
    extra_len: usize = 0,

    /// Brief:
    /// Initialize a Response for the given request
    ///
    /// Param:
    /// req         - *std.http.Server.Request
    /// allocator   - std.mem.Allocator (per-request arena)
    /// max_headers - usize (cap from HeaderSize.value(); default .COMMON = 32)
    ///
    /// Return:
    /// !Response
    pub fn init(req: *std.http.Server.Request, allocator: std.mem.Allocator, max_headers: usize) !Response {
        return .{
            .req = req,
            .allocator = allocator,
            .extra_buf = try allocator.alloc(HttpHeader, max_headers),
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
        if (self.extra_len >= self.extra_buf.len) return error.TooManyHeaders;
        self.extra_buf[self.extra_len] = .{ .name = name, .value = value };
        self.extra_len += 1;
    }

    /// Brief:
    /// Write and flush the HTTP response with the given body
    ///
    /// Note:
    /// - Sends status line, Content-Type, Content-Length, Connection, and any extra headers
    ///
    /// Param:
    /// body_data - []const u8
    ///
    /// Return:
    /// !void
    pub fn send(self: *Response, body_data: []const u8) !void {
        var buf: [4096]u8 = undefined;
        var offset: usize = 0;

        const status_text = Status.stringFromEnum(self.status);
        const status_line = try std.fmt.bufPrint(
            buf[offset..],
            "HTTP/1.1 {d} {s}\r\n",
            .{ @intFromEnum(self.status), status_text },
        );
        offset += status_line.len;

        const ct = try std.fmt.bufPrint(buf[offset..], "Content-Type: {s}\r\n", .{self.content_type.asString()});
        offset += ct.len;

        const cl = try std.fmt.bufPrint(buf[offset..], "Content-Length: {d}\r\n", .{body_data.len});
        offset += cl.len;

        const conn = if (self.keep_alive) "Connection: keep-alive\r\n" else "Connection: close\r\n";
        if (offset + conn.len > buf.len) return error.BufferTooSmall;
        @memcpy(buf[offset..][0..conn.len], conn);
        offset += conn.len;

        for (self.extra_buf[0..self.extra_len]) |h| {
            const hline = try std.fmt.bufPrint(buf[offset..], "{s}: {s}\r\n", .{ h.name, h.value });
            offset += hline.len;
        }

        if (offset + 2 > buf.len) return error.BufferTooSmall;
        buf[offset] = '\r';
        buf[offset + 1] = '\n';
        offset += 2;

        self.req.server.out.writeAll(buf[0..offset]) catch return;
        if (body_data.len > 0) self.req.server.out.writeAll(body_data) catch return;
        self.req.server.out.flush() catch return;
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
// --------------------------------------------------------- //

test "zix test: http response setters" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var res = try Response.init(undefined, arena.allocator(), 32);

    res.setStatus(.CREATED);
    try std.testing.expectEqual(Status.Code.CREATED, res.status);

    res.setContentType(.APPLICATION_JSON);
    try std.testing.expectEqual(Content.Type.APPLICATION_JSON, res.content_type);

    res.setKeepAlive(false);
    try std.testing.expect(!res.keep_alive);

    try res.addHeader("X-Test", "Value");
    try std.testing.expectEqual(@as(usize, 1), res.extra_len);
    try std.testing.expectEqualStrings("X-Test", res.extra_buf[0].name);
    try std.testing.expectEqualStrings("Value", res.extra_buf[0].value);
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
    var res = try Response.init(undefined, arena.allocator(), 32);
    try std.testing.expectError(error.InvalidHeaderName, res.addHeader("X-Bad\r\nInject", "val"));
    try std.testing.expectError(error.InvalidHeaderValue, res.addHeader("X-Good", "val\r\nInject"));
}

test "zix test: addHeader TooManyHeaders" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var res = try Response.init(undefined, arena.allocator(), 2);
    try res.addHeader("X-A", "1");
    try res.addHeader("X-B", "2");
    try std.testing.expectError(error.TooManyHeaders, res.addHeader("X-C", "3"));
}
