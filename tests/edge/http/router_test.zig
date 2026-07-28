//! Edge tests: zix.Http.Router dispatch boundary conditions.
//! Verifies: no-match yields false, and a prefix does NOT match a path that
//! merely starts with the same characters but is a different segment.

const std = @import("std");
const zix = @import("zix");

fn handlerA(req: *zix.Http.Request, res: *zix.Http.Response, ctx: *zix.Http.Context) !void {
    _ = req;
    _ = res;
    _ = ctx;
}

fn socketPair(fds: *[2]i32) !void {
    const linux = std.os.linux;
    try std.testing.expectEqual(@as(usize, 0), linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM, 0, fds));
}

// --------------------------------------------------------- //

test "zix edge: dispatch, no registered route sends 404" {
    if (comptime @import("builtin").target.os.tag != .linux) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const al = arena.allocator();

    var fds: [2]i32 = undefined;
    try socketPair(&fds);
    defer _ = std.os.linux.close(fds[0]);
    defer _ = std.os.linux.close(fds[1]);

    const router = zix.Http.Router(&[_]zix.Http.Route{});

    var req = try zix.Http.Request.fromRaw("GET /missing HTTP/1.1\r\nHost: localhost\r\n\r\n", al);
    var res = zix.Http.Response.init(fds[1], false, undefined, al, 32);
    var ctx = zix.Http.Context{ .io = undefined, .allocator = al };

    try router.dispatch(&req, &res, &ctx);
    try std.testing.expectEqual(zix.Http.Status.Code.NOT_FOUND, res.status);
}

test "zix edge: dispatch, prefix /api does NOT match /apiv2" {
    // A prefix handler for "/api" must only match paths where the next character
    // after the prefix is '/' or end-of-path, not paths that merely start with
    // the same bytes but continue without a separator.
    if (comptime @import("builtin").target.os.tag != .linux) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const al = arena.allocator();

    var fds: [2]i32 = undefined;
    try socketPair(&fds);
    defer _ = std.os.linux.close(fds[0]);
    defer _ = std.os.linux.close(fds[1]);

    const router = zix.Http.Router(&[_]zix.Http.Route{
        .{ .path = "/api", .handler = handlerA, .kind = .PREFIX },
    });

    var req = try zix.Http.Request.fromRaw("GET /apiv2/resource HTTP/1.1\r\nHost: localhost\r\n\r\n", al);
    var res = zix.Http.Response.init(fds[1], false, undefined, al, 32);
    var ctx = zix.Http.Context{ .io = undefined, .allocator = al };

    try router.dispatch(&req, &res, &ctx);
    try std.testing.expectEqual(zix.Http.Status.Code.NOT_FOUND, res.status);
}
