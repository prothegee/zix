//! zix http request

const std = @import("std");
const Method = @import("method.zig");
const parser = @import("parser.zig");

pub const PathParam = struct {
    name: []const u8,
    value: []const u8,
};

pub const Request = struct {
    /// Read buffer slice for this connection. All path/query/header slices point into it.
    buf: []const u8,
    /// Parsed offsets into buf. No data was copied during parsing.
    head: parser.ParsedHead,
    /// Raw socket fd — used by body() for any bytes not yet in buf.
    fd: std.posix.fd_t,
    /// How many bytes in buf are valid (filled by the recv loop in handleConnection).
    buf_filled: usize,
    allocator: std.mem.Allocator,
    body_cache: ?[]const u8 = null,
    path_params: []const PathParam = &.{},
    /// Lazy lowercase-keyed header index built on first header() call.
    header_index: ?std.StringHashMapUnmanaged([]const u8) = null,

    /// Get HTTP method.
    pub fn method(self: Request) Method.Code {
        return self.head.method;
    }

    /// Get the URL path without query string.
    pub fn path(self: Request) []const u8 {
        return self.buf[self.head.path_start..][0..self.head.path_len];
    }

    /// Get the raw query string (after '?'), or empty string if none.
    pub fn query(self: Request) []const u8 {
        if (self.head.query_len == 0) return "";
        return self.buf[self.head.query_start..][0..self.head.query_len];
    }

    /// Get a request header value by name (case-insensitive).
    /// First call builds a lowercase-keyed index from the arena.
    /// Subsequent calls are O(1) hash lookups.
    /// Falls back to a linear scan if index build fails.
    pub fn header(self: *Request, name: []const u8) ?[]const u8 {
        if (self.header_index == null) {
            var map: std.StringHashMapUnmanaged([]const u8) = .empty;
            var ok = true;
            for (self.head.headers[0..self.head.header_count]) |h| {
                const n = self.buf[h.name_start..][0..h.name_len];
                const v = self.buf[h.value_start..][0..h.value_len];
                const lower = self.allocator.alloc(u8, n.len) catch { ok = false; break; };
                _ = std.ascii.lowerString(lower, n);
                map.put(self.allocator, lower, v) catch { ok = false; break; };
            }
            if (ok) self.header_index = map;
        }

        var lower_buf: [128]u8 = undefined;
        if (self.header_index != null and name.len <= lower_buf.len) {
            const lower_name = std.ascii.lowerString(lower_buf[0..name.len], name);
            return self.header_index.?.get(lower_name);
        }

        // Fallback: linear scan.
        for (self.head.headers[0..self.head.header_count]) |h| {
            const n = self.buf[h.name_start..][0..h.name_len];
            if (std.ascii.eqlIgnoreCase(n, name)) {
                return self.buf[h.value_start..][0..h.value_len];
            }
        }
        return null;
    }

    /// Read and return the full request body.
    /// Cached after first call. Handles both Content-Length and Transfer-Encoding: chunked.
    /// Returns empty string when Content-Length is absent/zero and not chunked.
    /// Bytes already in the read buffer are used directly; remaining bytes are recv'd from fd.
    pub fn body(self: *Request) ![]const u8 {
        if (self.body_cache) |b| return b;

        if (self.head.chunked) return self.readChunkedBody();

        const cl = self.head.content_length;
        if (cl == 0) {
            self.body_cache = "";
            return "";
        }

        // Bytes already pulled into buf during the header read loop.
        const in_buf_end = @min(self.buf_filled, self.buf.len);
        const already_slice = self.buf[@min(self.head.body_offset, in_buf_end)..in_buf_end];
        const already_len = @min(already_slice.len, cl);

        const out = try self.allocator.alloc(u8, cl);
        @memcpy(out[0..already_len], already_slice[0..already_len]);

        var total: usize = already_len;
        while (total < cl) {
            const n = std.posix.read(self.fd, out[total..cl]) catch break;
            if (n == 0) break;
            total += n;
        }
        self.body_cache = out[0..total];
        return self.body_cache.?;
    }

    fn readChunkedBody(self: *Request) ![]const u8 {
        const max_raw = self.buf.len;
        const raw_buf = try self.allocator.alloc(u8, max_raw);

        const in_buf_end = @min(self.buf_filled, self.buf.len);
        const already_slice = self.buf[@min(self.head.body_offset, in_buf_end)..in_buf_end];
        @memcpy(raw_buf[0..already_slice.len], already_slice);
        var raw_total: usize = already_slice.len;

        // Read from fd until terminal chunk found or buffer full.
        // Note: "0\r\n\r\n" pattern match is a heuristic — the dechunker handles correctness.
        while (raw_total < max_raw) {
            if (std.mem.indexOf(u8, raw_buf[0..raw_total], "0\r\n\r\n") != null) break;
            const n = std.posix.read(self.fd, raw_buf[raw_total..max_raw]) catch break;
            if (n == 0) break;
            raw_total += n;
        }

        const decoded = try self.allocator.alloc(u8, raw_total);
        const decoded_len = parser.dechunk(raw_buf[0..raw_total], decoded) catch 0;
        self.body_cache = decoded[0..decoded_len];
        return self.body_cache.?;
    }

    /// Get a single named query parameter value.
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

    /// Split the request path into non-empty segments.
    pub fn pathSegments(self: Request, allocator: std.mem.Allocator) ![][]const u8 {
        var list: std.ArrayList([]const u8) = .empty;
        var it = std.mem.splitScalar(u8, self.path(), '/');
        while (it.next()) |seg| {
            if (seg.len > 0) try list.append(allocator, seg);
        }
        return list.items;
    }

    /// Parse a complete raw HTTP/1.1 head buffer into a Request.
    /// Useful for tests and offline parsing. buf must contain a full head (\r\n\r\n).
    pub fn fromRaw(buf: []const u8, allocator: std.mem.Allocator) !Request {
        const head = (try parser.parse(buf, parser.MAX_HEADERS_U8)) orelse return error.Incomplete;
        return .{
            .buf        = buf,
            .head       = head,
            .fd         = undefined,
            .buf_filled = buf.len,
            .allocator  = allocator,
        };
    }

    /// Get a named path parameter captured from a parameterized route.
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

    /// Get all query parameters as a slice of QueryParam.
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
                        .key   = pair[0..eq],
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

// --------------------------------------------------------- //
// --------------------------------------------------------- //

test "zix test: http request path and query" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const raw = "GET /api/users/123?name=alice&flag HTTP/1.1\r\nHost: localhost\r\n\r\n";
    const head = (try parser.parse(raw, parser.MAX_HEADERS_U8)).?;
    var req = Request{
        .buf        = raw,
        .head       = head,
        .fd         = undefined,
        .buf_filled = raw.len,
        .allocator  = allocator,
    };

    try std.testing.expectEqual(Method.Code.GET, req.method());
    try std.testing.expectEqualStrings("/api/users/123", req.path());
    try std.testing.expectEqualStrings("name=alice&flag", req.query());

    try std.testing.expectEqualStrings("alice", req.queryParam("name").?);
    try std.testing.expect(req.queryParam("flag") == null);
    try std.testing.expect(req.queryParam("missing") == null);

    const segs = try req.pathSegments(allocator);
    try std.testing.expectEqual(@as(usize, 3), segs.len);
    try std.testing.expectEqualStrings("api", segs[0]);
    try std.testing.expectEqualStrings("users", segs[1]);
    try std.testing.expectEqualStrings("123", segs[2]);

    const params = try req.queryParams(allocator);
    try std.testing.expectEqual(@as(usize, 2), params.len);
    try std.testing.expectEqualStrings("name", params[0].key);
    try std.testing.expectEqualStrings("alice", params[0].value.?);
    try std.testing.expectEqualStrings("flag", params[1].key);
    try std.testing.expect(params[1].value == null);
}

test "zix test: http request header lookup" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const raw = "GET / HTTP/1.1\r\nHost: example.com\r\nContent-Type: application/json\r\n\r\n";
    const head = (try parser.parse(raw, parser.MAX_HEADERS_U8)).?;
    var req = Request{
        .buf        = raw,
        .head       = head,
        .fd         = undefined,
        .buf_filled = raw.len,
        .allocator  = arena.allocator(),
    };
    try std.testing.expectEqualStrings("example.com", req.header("host").?);
    try std.testing.expectEqualStrings("example.com", req.header("Host").?);
    try std.testing.expectEqualStrings("application/json", req.header("content-type").?);
    try std.testing.expect(req.header("x-missing") == null);
}
