//! ZIX Http2 Request
//!
//! ### file: src/zix/tcp/http2/Request.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Zero-copy view over one HTTP/2 stream: method, path, query, headers, and body.
//!
//! ### note:
//!
//! Every slice borrows the stream buffers and is valid only for the handler call.
//! Copy a value to keep it.
//!
//! ---------------------------------------------------------
//!
//! ### licenses:
//!
//! - BSD-3-Clause
//!
//! ### copyright:
//!
//! - (c) Prana Ron // @prothegee // prothegee@pm.me
//!
//! ### contributors:
//!
//! - Prana Ron // @prothegee // prothegee@pm.me
//!

const std = @import("std");
const Header = @import("hpack/Header.zig");

// --------------------------------------------------------- //
// Fields:

method: []const u8,
/// Path without the query string.
path: []const u8,
/// Raw query string after the "?", or empty.
query: []const u8,
/// Decoded header block, pseudo-headers included.
headers: []const Header,
body: []const u8,

const Self = @This();

// --------------------------------------------------------- //
// Private:

fn appendParam(
    list: *std.ArrayList(QueryParam),
    allocator: std.mem.Allocator,
    param: QueryParam,
) Error!void {
    list.append(allocator, param) catch |err| switch (err) {
        error.OutOfMemory => return Error.ZixHttp2_Request_OutOfMemory,
    };
}

// --------------------------------------------------------- //
// Public:

/// ZIX Http2 request error
pub const Error = error {
    ZixHttp2_Request_OutOfMemory,
};

/// One query pair. A valueless key carries a null value.
pub const QueryParam = struct {
    key: []const u8,
    value: ?[]const u8,
};

/// A raw ":path" value split at the first "?".
pub const SplitPath = struct {
    path: []const u8,
    query: []const u8,
};

/// Split a raw ":path" value (e.g. "/json/5?m=7") into path and query.
///
/// Param:
/// raw_path - []const u8 (the ":path" pseudo-header value)
///
/// Return:
/// - SplitPath (query is empty when there is no "?")
pub fn splitPath(raw_path: []const u8) SplitPath {
    const query_pos = std.mem.indexOfScalar(u8, raw_path, '?') orelse return .{
        .path = raw_path,
        .query = "",
    };

    return .{
        .path = raw_path[0..query_pos],
        .query = raw_path[query_pos + 1 ..],
    };
}

/// One request header value by name (case-insensitive), or null.
///
/// Note:
/// - Pseudo-headers (":method", ":path", ":scheme", ":authority") are found
///   too, HTTP/2 carries them as regular header entries.
pub fn header(self: Self, name: []const u8) ?[]const u8 {
    for (self.headers) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.name, name)) return entry.value;
    }

    return null;
}

/// One query parameter value, or null. A valueless key (e.g. "?flag") returns "".
pub fn queryParam(self: Self, name: []const u8) ?[]const u8 {
    var pos: usize = 0;

    while (pos < self.query.len) {
        const amp_pos = std.mem.indexOfScalarPos(u8, self.query, pos, '&') orelse
            self.query.len;
        const pair = self.query[pos..amp_pos];

        if (std.mem.indexOfScalar(u8, pair, '=')) |eq_pos| {
            if (std.mem.eql(u8, pair[0..eq_pos], name)) return pair[eq_pos + 1 ..];
        } else if (std.mem.eql(u8, pair, name)) {
            return "";
        }

        if (amp_pos >= self.query.len) break;

        pos = amp_pos + 1;
    }

    return null;
}

/// Get all query parameters. A valueless or empty-valued key gets a null value.
///
/// Param:
/// allocator - std.mem.Allocator (owns the returned slice)
///
/// Return:
/// - []QueryParam (empty when there is no query)
/// - Error.ZixHttp2_Request_OutOfMemory when the list cannot grow
pub fn queryParams(self: Self, allocator: std.mem.Allocator) Error![]QueryParam {
    if (self.query.len == 0) return &.{};

    var list: std.ArrayList(QueryParam) = .empty;
    var pos: usize = 0;

    while (pos < self.query.len) {
        const amp_pos = std.mem.indexOfScalarPos(u8, self.query, pos, '&') orelse
            self.query.len;
        const pair = self.query[pos..amp_pos];

        if (pair.len > 0) {
            if (std.mem.indexOfScalar(u8, pair, '=')) |eq_pos| {
                const value = pair[eq_pos + 1 ..];
                try appendParam(&list, allocator, .{
                    .key = pair[0..eq_pos],
                    .value = if (value.len > 0) value else null,
                });
            } else {
                try appendParam(&list, allocator, .{
                    .key = pair,
                    .value = null,
                });
            }
        }

        if (amp_pos >= self.query.len) break;

        pos = amp_pos + 1;
    }

    return list.items;
}

/// Split the request path into non-empty segments.
///
/// Param:
/// allocator - std.mem.Allocator (owns the returned slice)
///
/// Return:
/// - [][]const u8 (empty for "/")
/// - Error.ZixHttp2_Request_OutOfMemory when the list cannot grow
pub fn pathSegments(self: Self, allocator: std.mem.Allocator) Error![][]const u8 {
    var list: std.ArrayList([]const u8) = .empty;

    var iter = std.mem.splitScalar(u8, self.path, '/');
    while (iter.next()) |segment| {
        if (segment.len == 0) continue;

        list.append(allocator, segment) catch |err| switch (err) {
            error.OutOfMemory => return Error.ZixHttp2_Request_OutOfMemory,
        };
    }

    return list.items;
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

fn testRequest(path: []const u8, query: []const u8, headers: []const Header) Self {
    return .{
        .method = "GET",
        .path = path,
        .query = query,
        .headers = headers,
        .body = "",
    };
}

test "zix http2: Request, splitPath separates path and query" {
    const split = Self.splitPath("/users/5?role=admin");

    try std.testing.expectEqualStrings("/users/5", split.path);
    try std.testing.expectEqualStrings("role=admin", split.query);
}

test "zix http2: Request, splitPath without a query keeps the path" {
    const split = Self.splitPath("/about");

    try std.testing.expectEqualStrings("/about", split.path);
    try std.testing.expectEqualStrings("", split.query);
}

test "zix http2: Request, splitPath with a trailing question mark gives an empty query" {
    const split = Self.splitPath("/a?");

    try std.testing.expectEqualStrings("/a", split.path);
    try std.testing.expectEqualStrings("", split.query);
}

test "zix http2: Request, header is case-insensitive" {
    const headers = [_]Header{
        .{
            .name = "content-type",
            .value = "application/json",
        },
    };
    const req = testRequest("/", "", &headers);

    try std.testing.expectEqualStrings("application/json", req.header("Content-Type").?);
}

test "zix http2: Request, header finds a pseudo-header" {
    const headers = [_]Header{
        .{
            .name = ":method",
            .value = "GET",
        },
    };
    const req = testRequest("/", "", &headers);

    try std.testing.expectEqualStrings("GET", req.header(":method").?);
}

test "zix http2: Request, header missing returns null" {
    const req = testRequest("/", "", &.{});

    try std.testing.expect(req.header("missing") == null);
}

test "zix http2: Request, queryParam finds a value" {
    const req = testRequest("/p", "name=alice&flag&empty=", &.{});

    try std.testing.expectEqualStrings("alice", req.queryParam("name").?);
}

test "zix http2: Request, queryParam valueless key returns empty" {
    const req = testRequest("/p", "name=alice&flag&empty=", &.{});

    try std.testing.expectEqualStrings("", req.queryParam("flag").?);
    try std.testing.expectEqualStrings("", req.queryParam("empty").?);
}

test "zix http2: Request, queryParam missing returns null" {
    const req = testRequest("/p", "name=alice", &.{});

    try std.testing.expect(req.queryParam("missing") == null);
}

test "zix http2: Request, queryParam on an empty query returns null" {
    const req = testRequest("/p", "", &.{});

    try std.testing.expect(req.queryParam("name") == null);
}

test "zix http2: Request, queryParams returns every pair" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const req = testRequest("/q", "name=alice&flag&empty=", &.{});
    const params = try req.queryParams(arena.allocator());

    try std.testing.expectEqual(@as(usize, 3), params.len);
    try std.testing.expectEqualStrings("name", params[0].key);
    try std.testing.expectEqualStrings("alice", params[0].value.?);
    try std.testing.expectEqualStrings("flag", params[1].key);
    try std.testing.expect(params[1].value == null);
    try std.testing.expectEqualStrings("empty", params[2].key);
    try std.testing.expect(params[2].value == null);
}

test "zix http2: Request, queryParams skips empty pairs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const req = testRequest("/q", "&&a=1&", &.{});
    const params = try req.queryParams(arena.allocator());

    try std.testing.expectEqual(@as(usize, 1), params.len);
    try std.testing.expectEqualStrings("a", params[0].key);
}

test "zix http2: Request, queryParams on an empty query is empty" {
    const req = testRequest("/q", "", &.{});
    const params = try req.queryParams(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), params.len);
}

test "zix http2: Request, queryParams out of memory" {
    var buf: [1]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&buf);

    const req = testRequest("/q", "a=1", &.{});

    try std.testing.expectError(
        Error.ZixHttp2_Request_OutOfMemory,
        req.queryParams(fixed.allocator()),
    );
}

test "zix http2: Request, pathSegments splits non-empty segments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const req = testRequest("/api//users/42/", "", &.{});
    const segments = try req.pathSegments(arena.allocator());

    try std.testing.expectEqual(@as(usize, 3), segments.len);
    try std.testing.expectEqualStrings("api", segments[0]);
    try std.testing.expectEqualStrings("users", segments[1]);
    try std.testing.expectEqualStrings("42", segments[2]);
}

test "zix http2: Request, pathSegments on root is empty" {
    const req = testRequest("/", "", &.{});
    const segments = try req.pathSegments(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), segments.len);
}

test "zix http2: Request, pathSegments out of memory" {
    var buf: [1]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&buf);

    const req = testRequest("/a/b", "", &.{});

    try std.testing.expectError(
        Error.ZixHttp2_Request_OutOfMemory,
        req.pathSegments(fixed.allocator()),
    );
}

