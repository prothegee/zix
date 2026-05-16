//! Behaviour tests: zix.Http.Request API contracts.
//! Verifies what callers can rely on: path/query parsing and method resolution.

const std = @import("std");
const zix = @import("zix");

// --------------------------------------------------------- //

test "zix behaviour: path(), strips query string from target" {
    const req = try zix.Http.Request.fromRaw(
        "GET /api/users?limit=10&offset=5 HTTP/1.1\r\nHost: localhost\r\n\r\n",
        std.testing.allocator,
    );
    try std.testing.expectEqualStrings("/api/users", req.path());
}

test "zix behaviour: path(), returns full target when no query string" {
    const req = try zix.Http.Request.fromRaw(
        "GET /api/users/alice HTTP/1.1\r\nHost: localhost\r\n\r\n",
        std.testing.allocator,
    );
    try std.testing.expectEqualStrings("/api/users/alice", req.path());
}

test "zix behaviour: path(), root path returns /" {
    const req = try zix.Http.Request.fromRaw(
        "GET / HTTP/1.1\r\nHost: localhost\r\n\r\n",
        std.testing.allocator,
    );
    try std.testing.expectEqualStrings("/", req.path());
}

test "zix behaviour: query(), returns portion after ?" {
    const req = try zix.Http.Request.fromRaw(
        "GET /search?q=hello&lang=zig HTTP/1.1\r\nHost: localhost\r\n\r\n",
        std.testing.allocator,
    );
    try std.testing.expectEqualStrings("q=hello&lang=zig", req.query());
}

test "zix behaviour: query(), returns empty string when no ? in target" {
    const req = try zix.Http.Request.fromRaw(
        "GET /api/users HTTP/1.1\r\nHost: localhost\r\n\r\n",
        std.testing.allocator,
    );
    try std.testing.expectEqualStrings("", req.query());
}

test "zix behaviour: body(), chunked produces same payload as equivalent Content-Length" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var chunked_req = try zix.Http.Request.fromRaw(
        "POST / HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\n\r\n" ++
        "5\r\nworld\r\n0\r\n\r\n",
        arena.allocator(),
    );
    const chunked_body = try chunked_req.body();

    var cl_req = try zix.Http.Request.fromRaw(
        "POST / HTTP/1.1\r\nHost: localhost\r\nContent-Length: 5\r\n\r\nworld",
        arena.allocator(),
    );
    cl_req.body_cache = "world";
    const cl_body = try cl_req.body();

    try std.testing.expectEqualStrings(cl_body, chunked_body);
}

test "zix behaviour: body(), chunked second call returns cached result" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var req = try zix.Http.Request.fromRaw(
        "POST / HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\n\r\n" ++
        "4\r\ntest\r\n0\r\n\r\n",
        arena.allocator(),
    );
    const b1 = try req.body();
    const b2 = try req.body();
    try std.testing.expect(b1.ptr == b2.ptr);
}

test "zix behaviour: method(), resolves each method" {
    const cases = .{
        .{ "DELETE / HTTP/1.1\r\nHost: x\r\n\r\n", "DELETE" },
        .{ "PATCH / HTTP/1.1\r\nHost: x\r\n\r\n",  "PATCH"  },
        .{ "PUT / HTTP/1.1\r\nHost: x\r\n\r\n",    "PUT"    },
        .{ "OPTIONS / HTTP/1.1\r\nHost: x\r\n\r\n","OPTIONS" },
        .{ "HEAD / HTTP/1.1\r\nHost: x\r\n\r\n",   "HEAD"   },
        .{ "GET / HTTP/1.1\r\nHost: x\r\n\r\n",    "GET"    },
        .{ "POST / HTTP/1.1\r\nHost: x\r\n\r\n",   "POST"   },
    };
    inline for (cases) |c| {
        const req = try zix.Http.Request.fromRaw(c[0], std.testing.allocator);
        const M = @TypeOf(req.method());
        try std.testing.expectEqual(@field(M, c[1]), req.method());
    }
}
