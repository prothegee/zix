//! zix http1 request: a zero-copy view over the connection receive buffer for
//! the ergonomic req, res, ctx handler shape. Every slice it returns borrows
//! the receive buffer and is valid only for the handler call. The body is
//! already drained by the engine before the handler runs, so body() returns a
//! slice without touching the socket.

const std = @import("std");
const core = @import("core.zig");
const router = @import("router.zig");
const Method = @import("method.zig");

pub const Request = struct {
    /// Parsed request head. Every slice in it borrows the receive buffer.
    head: *const core.ParsedHead,
    /// Request body bytes, already drained by the engine. Empty when there is
    /// none. Handlers read it through body().
    body_bytes: []const u8,
    /// Connection fd, the raw escape hatch.
    fd: std.posix.fd_t,
    /// Path parameters captured by a PARAM route. The async lane copies them in
    /// at handoff, because the router threadlocal is not valid once a fiber
    /// resumes. The sync path leaves this empty and pathParam() reads the router
    /// threadlocal directly.
    path_params: []const router.PathParam = &.{},
    /// Body bytes consumed off the socket for this request, counted by the
    /// engine. Equals body().len when the body fit the receive buffer. For a
    /// body larger than the buffer the .URING dispatch counts the drained
    /// remainder here as well. Handlers read it through bodyReceived().
    body_received: u64 = 0,

    /// Build a request view over a parsed head, body, and fd.
    ///
    /// Param:
    /// head - *const core.ParsedHead (borrows the receive buffer)
    /// body_data - []const u8 (already drained by the engine, empty when none)
    /// fd - std.posix.fd_t (the connection)
    ///
    /// Return:
    /// - Request
    pub fn init(head: *const core.ParsedHead, body_data: []const u8, fd: std.posix.fd_t) Request {
        return .{ .head = head, .body_bytes = body_data, .fd = fd, .body_received = body_data.len };
    }

    /// The HTTP method as the typed code. An unknown or oversized method token
    /// maps to GET (the Method.enumFromString contract).
    pub fn method(self: Request) Method.Code {
        if (self.head.method.len > 8) return .GET;

        return Method.enumFromString(self.head.method);
    }

    /// The path without the query string.
    pub fn path(self: Request) []const u8 {
        return self.head.path;
    }

    /// The raw query string after the "?", or empty.
    pub fn query(self: Request) []const u8 {
        return self.head.query;
    }

    /// One query parameter value, or null.
    pub fn queryParam(self: Request, name: []const u8) ?[]const u8 {
        return core.queryParam(self.head, name);
    }

    /// One request header value by name (case-insensitive), or null.
    pub fn header(self: Request, name: []const u8) ?[]const u8 {
        return core.getHeader(self.head, name);
    }

    /// A path parameter captured by a PARAM route, or null. Reads the request's
    /// own captured set first (async lane), then falls back to the router
    /// threadlocal (sync path).
    pub fn pathParam(self: Request, name: []const u8) ?[]const u8 {
        for (self.path_params) |path_param| {
            if (std.mem.eql(u8, path_param.name, name)) return path_param.value;
        }

        return router.pathParam(name);
    }

    /// The request body. Identical call shape to zix.Http. The engine drained
    /// the body before the handler ran, so this never reads the socket.
    ///
    /// Return:
    /// - []const u8 (the engine-delivered body slice, empty when none)
    pub fn body(self: *Request) ![]const u8 {
        return self.body_bytes;
    }

    /// Bytes of this request's body consumed off the socket, counted by the
    /// engine from the reads that received it, never taken from the
    /// Content-Length header.
    ///
    /// Note:
    /// - Equals body().len when the body fit the receive buffer.
    /// - For a body larger than the buffer the .URING dispatch counts the
    ///   drained remainder too. Other dispatch models report only the
    ///   delivered slice length there.
    ///
    /// Return:
    /// - u64 (counted received body bytes)
    pub fn bodyReceived(self: Request) u64 {
        return self.body_received;
    }

    /// Whether the connection is keep-alive.
    pub fn keepAlive(self: Request) bool {
        return self.head.keep_alive;
    }

    /// Split the request path into non-empty segments.
    pub fn pathSegments(self: Request, allocator: std.mem.Allocator) ![][]const u8 {
        var list: std.ArrayList([]const u8) = .empty;

        var iter = std.mem.splitScalar(u8, self.path(), '/');
        while (iter.next()) |segment| {
            if (segment.len > 0) try list.append(allocator, segment);
        }

        return list.items;
    }

    pub const QueryParam = struct {
        key: []const u8,
        value: ?[]const u8,
    };

    /// Get all query parameters as a slice of QueryParam.
    pub fn queryParams(self: Request, allocator: std.mem.Allocator) ![]QueryParam {
        const query_str = self.query();
        if (query_str.len == 0) return &.{};

        var list: std.ArrayList(QueryParam) = .empty;
        var pos: usize = 0;
        while (pos < query_str.len) {
            const amp_pos = std.mem.indexOfScalarPos(u8, query_str, pos, '&') orelse query_str.len;
            const pair = query_str[pos..amp_pos];
            if (pair.len > 0) {
                if (std.mem.indexOfScalar(u8, pair, '=')) |eq_pos| {
                    const value = pair[eq_pos + 1 ..];
                    try list.append(allocator, .{
                        .key = pair[0..eq_pos],
                        .value = if (value.len > 0) value else null,
                    });
                } else {
                    try list.append(allocator, .{ .key = pair, .value = null });
                }
            }
            if (amp_pos >= query_str.len) break;
            pos = amp_pos + 1;
        }

        return list.items;
    }

    /// Parse a complete raw HTTP/1.x head buffer into a Request.
    /// Useful for tests and offline parsing. buf must contain a full head
    /// (\r\n\r\n) and must outlive the Request (every slice borrows it). The
    /// parsed head is one small allocation from allocator.
    pub fn fromRaw(buf: []const u8, allocator: std.mem.Allocator) !Request {
        const result = try core.parseHead(buf);

        const head = try allocator.create(core.ParsedHead);
        head.* = result.head;

        const body_start = @min(result.body_offset, buf.len);
        return .{ .head = head, .body_bytes = buf[body_start..], .fd = -1, .body_received = buf.len - body_start };
    }
};

// --------------------------------------------------------- //
// --------------------------------------------------------- //

test "zix http1: Request view exposes method, path, query" {
    const parsed = try core.parseHead("GET /users?active=1 HTTP/1.1\r\nHost: x\r\n\r\n");
    const req = Request.init(&parsed.head, "", 3);

    try std.testing.expect(req.method() == .GET);
    try std.testing.expectEqualStrings("/users", req.path());
    try std.testing.expectEqualStrings("active=1", req.query());
    try std.testing.expectEqual(@as(std.posix.fd_t, 3), req.fd);
    try std.testing.expect(req.keepAlive());
}

test "zix http1: Request method maps unknown or oversized tokens to GET" {
    const parsed = try core.parseHead("BREW /pot HTTP/1.1\r\n\r\n");
    const req = Request.init(&parsed.head, "", -1);
    try std.testing.expect(req.method() == .GET);

    const long = try core.parseHead("VERYLONGMETHOD /x HTTP/1.1\r\n\r\n");
    const long_req = Request.init(&long.head, "", -1);
    try std.testing.expect(long_req.method() == .GET);

    const post = try core.parseHead("POST /x HTTP/1.1\r\n\r\n");
    const post_req = Request.init(&post.head, "", -1);
    try std.testing.expect(post_req.method() == .POST);
}

test "zix http1: Request queryParam and header lookups" {
    const parsed = try core.parseHead("GET /p?name=alice&age=30 HTTP/1.1\r\nContent-Type: text/plain\r\n\r\n");
    const req = Request.init(&parsed.head, "", -1);

    try std.testing.expectEqualStrings("alice", req.queryParam("name").?);
    try std.testing.expectEqualStrings("30", req.queryParam("age").?);
    try std.testing.expect(req.queryParam("missing") == null);
    try std.testing.expectEqualStrings("text/plain", req.header("content-type").?);
}

test "zix http1: Request pathParam reads its own captured set first" {
    const parsed = try core.parseHead("GET /users/alice HTTP/1.1\r\n\r\n");
    const captured = [_]router.PathParam{.{ .name = "id", .value = "alice" }};
    const req = Request{ .head = &parsed.head, .body_bytes = "", .fd = -1, .path_params = &captured };

    try std.testing.expectEqualStrings("alice", req.pathParam("id").?);
    try std.testing.expect(req.pathParam("missing") == null);
}

test "zix http1: Request body returns the engine-delivered slice" {
    const parsed = try core.parseHead("POST /submit HTTP/1.1\r\nContent-Length: 5\r\n\r\n");
    var req = Request.init(&parsed.head, "hello", -1);

    try std.testing.expectEqualStrings("hello", try req.body());
    try std.testing.expect(req.method() == .POST);
}

test "zix http1: Request bodyReceived defaults to the body length and takes an engine override" {
    const parsed = try core.parseHead("POST /u HTTP/1.1\r\nContent-Length: 5\r\n\r\n");

    var req = Request.init(&parsed.head, "hello", -1);
    try std.testing.expectEqual(@as(u64, 5), req.bodyReceived());

    // A dispatch path that drained a larger body overrides the count.
    req.body_received = 100000;
    try std.testing.expectEqual(@as(u64, 100000), req.bodyReceived());

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const raw = try Request.fromRaw("POST /u HTTP/1.1\r\nContent-Length: 3\r\n\r\nabc", arena.allocator());
    try std.testing.expectEqual(@as(u64, 3), raw.bodyReceived());
}

test "zix http1: Request pathSegments splits non-empty segments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const parsed = try core.parseHead("GET /api//users/42/ HTTP/1.1\r\n\r\n");
    const req = Request.init(&parsed.head, "", -1);

    const segments = try req.pathSegments(arena.allocator());
    try std.testing.expectEqual(@as(usize, 3), segments.len);
    try std.testing.expectEqualStrings("api", segments[0]);
    try std.testing.expectEqualStrings("users", segments[1]);
    try std.testing.expectEqualStrings("42", segments[2]);
}

test "zix http1: Request queryParams returns every pair, valueless keys null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const parsed = try core.parseHead("GET /q?name=alice&flag&empty= HTTP/1.1\r\n\r\n");
    const req = Request.init(&parsed.head, "", -1);

    const params = try req.queryParams(arena.allocator());
    try std.testing.expectEqual(@as(usize, 3), params.len);
    try std.testing.expectEqualStrings("name", params[0].key);
    try std.testing.expectEqualStrings("alice", params[0].value.?);
    try std.testing.expectEqualStrings("flag", params[1].key);
    try std.testing.expect(params[1].value == null);
    try std.testing.expectEqualStrings("empty", params[2].key);
    try std.testing.expect(params[2].value == null);
}

test "zix http1: Request fromRaw parses a raw buffer with body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const raw = "POST /submit?src=test HTTP/1.1\r\nContent-Length: 5\r\n\r\nhello";
    var req = try Request.fromRaw(raw, arena.allocator());

    try std.testing.expect(req.method() == .POST);
    try std.testing.expectEqualStrings("/submit", req.path());
    try std.testing.expectEqualStrings("test", req.queryParam("src").?);
    try std.testing.expectEqualStrings("hello", try req.body());
}
