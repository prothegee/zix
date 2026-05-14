//! Behaviour tests: zix.Http.Request API contracts.
//! Verifies what callers can rely on: path/query parsing and method resolution.

const std = @import("std");
const zix = @import("zix");

fn makeInner(method_: std.http.Method, target_: []const u8) std.http.Server.Request {
    return .{
        .server = undefined,
        .head = .{
            .method = method_,
            .target = target_,
            .version = .@"HTTP/1.1",
            .expect = null,
            .content_type = null,
            .content_length = null,
            .transfer_encoding = .none,
            .transfer_compression = .identity,
            .keep_alive = true,
        },
        .head_buffer = undefined,
        .respond_err = null,
    };
}

// --------------------------------------------------------- //

test "zix behaviour: path(), strips query string from target" {
    var inner = makeInner(.GET, "/api/users?limit=10&offset=5");
    const req = zix.Http.Request{ .inner = &inner, .reader = undefined, .allocator = std.testing.allocator };
    try std.testing.expectEqualStrings("/api/users", req.path());
}

test "zix behaviour: path(), returns full target when no query string" {
    var inner = makeInner(.GET, "/api/users/alice");
    const req = zix.Http.Request{ .inner = &inner, .reader = undefined, .allocator = std.testing.allocator };
    try std.testing.expectEqualStrings("/api/users/alice", req.path());
}

test "zix behaviour: path(), root path returns /" {
    var inner = makeInner(.GET, "/");
    const req = zix.Http.Request{ .inner = &inner, .reader = undefined, .allocator = std.testing.allocator };
    try std.testing.expectEqualStrings("/", req.path());
}

test "zix behaviour: query(), returns portion after ?" {
    var inner = makeInner(.GET, "/search?q=hello&lang=zig");
    const req = zix.Http.Request{ .inner = &inner, .reader = undefined, .allocator = std.testing.allocator };
    try std.testing.expectEqualStrings("q=hello&lang=zig", req.query());
}

test "zix behaviour: query(), returns empty string when no ? in target" {
    var inner = makeInner(.GET, "/api/users");
    const req = zix.Http.Request{ .inner = &inner, .reader = undefined, .allocator = std.testing.allocator };
    try std.testing.expectEqualStrings("", req.query());
}

test "zix behaviour: method(), returns method_cache when set" {
    // inner says GET but cache says POST, method() must return the cached value.
    var inner = makeInner(.GET, "/");
    const req = zix.Http.Request{
        .inner = &inner,
        .reader = undefined,
        .allocator = std.testing.allocator,
        .method_cache = .POST,
    };
    const M = @TypeOf(req.method());
    try std.testing.expectEqual(M.POST, req.method());
}

test "zix behaviour: method(), resolves each method from inner when cache is null" {
    const cases = .{
        .{ std.http.Method.DELETE, "DELETE" },
        .{ std.http.Method.PATCH, "PATCH" },
        .{ std.http.Method.PUT, "PUT" },
        .{ std.http.Method.OPTIONS, "OPTIONS" },
        .{ std.http.Method.HEAD, "HEAD" },
    };
    inline for (cases) |c| {
        var inner = makeInner(c[0], "/");
        const req = zix.Http.Request{ .inner = &inner, .reader = undefined, .allocator = std.testing.allocator };
        const M = @TypeOf(req.method());
        try std.testing.expectEqual(@field(M, c[1]), req.method());
    }
}
