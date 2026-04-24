//! zix http response

const std = @import("std");
const Status = @import("status.zig");

pub const HttpHeader = struct {
    name: []const u8,
    value: []const u8,
};

pub const Response = struct {
    req: *std.http.Server.Request,
    allocator: std.mem.Allocator,
    status: Status.Code = .OK,
    content_type: []const u8 = "text/plain",
    keep_alive: bool = true,
    extra_buf: [32]HttpHeader = undefined,
    extra_len: usize = 0,

    /// Brief:
    /// Initialize a Response for the given request
    ///
    /// Param:
    /// req       - *std.http.Server.Request
    /// allocator - std.mem.Allocator (per-request arena)
    ///
    /// Return:
    /// Response
    pub fn init(req: *std.http.Server.Request, allocator: std.mem.Allocator) Response {
        return .{ .req = req, .allocator = allocator };
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
    /// ct - []const u8 (MIME type string)
    pub fn setContentType(self: *Response, ct: []const u8) void {
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
    /// - Maximum 32 extra headers; returns error.TooManyHeaders if exceeded
    ///
    /// Param:
    /// name  - []const u8 (header name)
    /// value - []const u8 (header value)
    ///
    /// Return:
    /// !void
    pub fn addHeader(self: *Response, name: []const u8, value: []const u8) !void {
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

        const ct = try std.fmt.bufPrint(buf[offset..], "Content-Type: {s}\r\n", .{self.content_type});
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
    /// - Convenience wrapper around send(); sets content_type to application/json
    ///
    /// Param:
    /// body_data - []const u8 (JSON-encoded string)
    ///
    /// Return:
    /// !void
    pub fn sendJson(self: *Response, body_data: []const u8) !void {
        self.content_type = "application/json";
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
