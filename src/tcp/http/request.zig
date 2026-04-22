const std = @import("std");
const Method = @import("method.zig");

pub const Request = struct {
    inner: *std.http.Server.Request,
    reader: *std.Io.Reader,
    allocator: std.mem.Allocator,
    body_cache: ?[]const u8 = null,

    pub fn method(self: Request) Method.Code {
        return switch (self.inner.head.method) {
            .GET => .GET,
            .HEAD => .HEAD,
            .POST => .POST,
            .PUT => .PUT,
            .DELETE => .DELETE,
            .PATCH => .PATCH,
            .OPTIONS => .OPTIONS,
            .TRACE => .TRACE,
            .CONNECT => .CONNECT,
        };
    }

    pub fn path(self: Request) []const u8 {
        const target = self.inner.head.target;
        if (std.mem.indexOfScalar(u8, target, '?')) |qpos| return target[0..qpos];
        return target;
    }

    pub fn query(self: Request) []const u8 {
        const target = self.inner.head.target;
        if (std.mem.indexOfScalar(u8, target, '?')) |qpos| return target[qpos + 1 ..];
        return "";
    }

    pub fn header(self: Request, name: []const u8) ?[]const u8 {
        var it = self.inner.iterateHeaders();
        while (it.next()) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
        }
        return null;
    }

    pub fn body(self: *Request) ![]const u8 {
        if (self.body_cache) |b| return b;

        const cl = self.header("content-length") orelse {
            self.body_cache = "";
            return "";
        };
        const content_length = std.fmt.parseInt(usize, cl, 10) catch {
            self.body_cache = "";
            return "";
        };
        if (content_length == 0) {
            self.body_cache = "";
            return "";
        }

        const buf = try self.allocator.alloc(u8, content_length);
        var total: usize = 0;
        while (total < content_length) {
            const n = self.reader.readSliceShort(buf[total..content_length]) catch break;
            if (n == 0) break;
            total += n;
        }
        self.body_cache = buf[0..total];
        return self.body_cache.?;
    }

    pub fn queryParam(self: Request, key: []const u8) ?[]const u8 {
        const q = self.query();
        if (q.len == 0) return null;
        var pos: usize = 0;
        while (pos < q.len) {
            const amp = std.mem.indexOfScalarPos(u8, q, pos, '&') orelse q.len;
            const pair = q[pos..amp];
            if (std.mem.indexOfScalar(u8, pair, '=')) |eq| {
                if (std.mem.eql(u8, pair[0..eq], key)) return pair[eq + 1 ..];
            }
            pos = amp + 1;
        }
        return null;
    }
};
