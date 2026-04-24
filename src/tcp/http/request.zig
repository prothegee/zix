//! zix http request

const std = @import("std");
const Method = @import("method.zig");

pub const PathParam = struct {
    name: []const u8,
    value: []const u8,
};

pub const Request = struct {
    inner: *std.http.Server.Request,
    reader: *std.Io.Reader,
    allocator: std.mem.Allocator,
    body_cache: ?[]const u8 = null,
    path_params: []const PathParam = &.{},

    /// Brief:
    /// Get HTTP method of the request
    ///
    /// Return:
    /// zix.Tcp.Http.Method.Code
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

    /// Brief:
    /// Get the URL path without query string
    ///
    /// Return:
    /// []const u8
    pub fn path(self: Request) []const u8 {
        const target = self.inner.head.target;
        if (std.mem.indexOfScalar(u8, target, '?')) |qpos| return target[0..qpos];
        return target;
    }

    /// Brief:
    /// Get the raw query string (after '?'), or empty string if none
    ///
    /// Return:
    /// []const u8
    pub fn query(self: Request) []const u8 {
        const target = self.inner.head.target;
        if (std.mem.indexOfScalar(u8, target, '?')) |qpos| return target[qpos + 1 ..];
        return "";
    }

    /// Brief:
    /// Get a request header value by name (case-insensitive)
    ///
    /// Note:
    /// - Returns null if the header is not present
    ///
    /// Param:
    /// name - []const u8 (header name, case-insensitive)
    ///
    /// Return:
    /// ?[]const u8
    pub fn header(self: Request, name: []const u8) ?[]const u8 {
        var it = self.inner.iterateHeaders();
        while (it.next()) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
        }
        return null;
    }

    /// Brief:
    /// Read and return the request body
    ///
    /// Note:
    /// - Cached after first read; subsequent calls return the same slice
    /// - Returns empty string if Content-Length is missing or zero
    ///
    /// Return:
    /// ![]const u8
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

    /// Brief:
    /// Get a single named query parameter value
    ///
    /// Note:
    /// - Returns null if the key is not present
    ///
    /// Param:
    /// key - []const u8 (parameter name)
    ///
    /// Return:
    /// ?[]const u8
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

    /// Brief:
    /// Split the request path into non-empty segments
    ///
    /// Note:
    /// - Leading/trailing slashes produce no empty segments
    /// - "/a/b/c" → ["a", "b", "c"]
    ///
    /// Param:
    /// allocator - std.mem.Allocator
    ///
    /// Return:
    /// ![][]const u8
    pub fn pathSegments(self: Request, allocator: std.mem.Allocator) ![][]const u8 {
        var list: std.ArrayList([]const u8) = .empty;
        var it = std.mem.splitScalar(u8, self.path(), '/');
        while (it.next()) |seg| {
            if (seg.len > 0) try list.append(allocator, seg);
        }
        return list.items;
    }

    /// Brief:
    /// Get a named path parameter captured from a parameterized route
    ///
    /// Note:
    /// - Returns null if the name was not captured for this request
    /// - Only populated when the request was matched by registerParamHandler
    ///
    /// Param:
    /// name - []const u8 (the parameter name without the leading colon)
    ///
    /// Return:
    /// ?[]const u8
    pub fn pathParam(self: Request, name: []const u8) ?[]const u8 {
        for (self.path_params) |p| {
            if (std.mem.eql(u8, p.name, name)) return p.value;
        }
        return null;
    }

    pub const QueryParam = struct {
        key: []const u8,
        value: ?[]const u8,
    };

    /// Brief:
    /// Get all query parameters as a slice of QueryParam
    ///
    /// Note:
    /// - Returns empty slice if there are no query params
    /// - Value is null for bare keys (e.g. ?flag) or empty-value keys (e.g. ?k=)
    ///
    /// Param:
    /// allocator - std.mem.Allocator (used to build the result slice)
    ///
    /// Return:
    /// ![]QueryParam
    pub fn queryParams(self: Request, allocator: std.mem.Allocator) ![]QueryParam {
        const q = self.query();
        if (q.len == 0) return &.{};
        var list: std.ArrayList(QueryParam) = .empty;
        var pos: usize = 0;
        while (pos < q.len) {
            const amp = std.mem.indexOfScalarPos(u8, q, pos, '&') orelse q.len;
            const pair = q[pos..amp];
            if (pair.len > 0) {
                if (std.mem.indexOfScalar(u8, pair, '=')) |eq| {
                    const val = pair[eq + 1 ..];
                    try list.append(allocator, .{
                        .key = pair[0..eq],
                        .value = if (val.len > 0) val else null,
                    });
                } else {
                    try list.append(allocator, .{ .key = pair, .value = null });
                }
            }
            if (amp >= q.len) break;
            pos = amp + 1;
        }
        return list.items;
    }
};
