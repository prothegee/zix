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

    pub fn init(req: *std.http.Server.Request, allocator: std.mem.Allocator) Response {
        return .{ .req = req, .allocator = allocator };
    }

    pub fn setStatus(self: *Response, s: Status.Code) void {
        self.status = s;
    }

    pub fn setContentType(self: *Response, ct: []const u8) void {
        self.content_type = ct;
    }

    pub fn setKeepAlive(self: *Response, ka: bool) void {
        self.keep_alive = ka;
    }

    pub fn addHeader(self: *Response, name: []const u8, value: []const u8) !void {
        if (self.extra_len >= self.extra_buf.len) return error.TooManyHeaders;
        self.extra_buf[self.extra_len] = .{ .name = name, .value = value };
        self.extra_len += 1;
    }

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

    pub fn sendJson(self: *Response, body_data: []const u8) !void {
        self.content_type = "application/json";
        return self.send(body_data);
    }

    pub fn noContent(self: *Response) !void {
        self.status = .NO_CONTENT;
        return self.send("");
    }
};
