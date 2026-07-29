//! Integration tests: the zix.Http3 router static fallback, driven through the real dispatch path.
//!
//! These build the trio the engine builds and call Router.dispatch, so what is asserted is the
//! response the engine would go on to frame, including the cache pin it hands back.

const std = @import("std");
const zix = @import("zix");

const static_cache = zix.utils.static_cache;

fn homeHandler(_: *const zix.Http3.Request, res: *zix.Http3.Response, _: *zix.Http3.Context) anyerror!void {
    res.send("home");
}

const TestRouter = zix.Http3.Router(&[_]zix.Http3.Route{
    .{ .path = "/", .handler = homeHandler },
});

// --------------------------------------------------------- //

fn writeFixture(dir: std.Io.Dir, name: []const u8, data: []const u8) void {
    dir.writeFile(std.testing.io, .{ .sub_path = name, .data = data }) catch @panic("fixture write failed");
}

/// Build the Context the engine hands a handler.
fn context(public_dir: []const u8) zix.Http3.Context {
    return .{
        .stream_id = 0,
        .io = std.testing.io,
        .allocator = std.testing.allocator,
        .public_dir = public_dir,
    };
}

fn dispatch(path: []const u8, res: *zix.Http3.Response, ctx: *zix.Http3.Context) !void {
    const req = zix.Http3.Request{ .method = "GET", .path = path, .accept_encoding = "" };

    try TestRouter.dispatch(&req, res, ctx);
}

/// Give back a pin a dispatched static response is holding.
fn releasePin(ctx: *zix.Http3.Context) void {
    const slot = ctx.static_slot orelse return;
    const cache = static_cache.instance() orelse return;

    cache.releaseSlot(slot);
}

// --------------------------------------------------------- //

test "zix integration: Http3 router serves an unmatched path from the static cache" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    writeFixture(tmp.dir, "doc.html", "<h1>h3 from cache</h1>");

    var root_buf: [64]u8 = undefined;
    const root = std.fmt.bufPrint(&root_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path}) catch unreachable;

    _ = try static_cache.install(32, 60_000);
    defer static_cache.shutdown(std.testing.io);

    var res = zix.Http3.Response{};
    var ctx = context(root);

    try dispatch("/doc.html", &res, &ctx);

    try std.testing.expectEqual(@as(u16, 200), res.status);
    try std.testing.expectEqualStrings("<h1>h3 from cache</h1>", res.body);
    try std.testing.expectEqualStrings("text/html", res.content_type);

    // The pin is handed back to the engine, which owns releasing it after the send.
    try std.testing.expect(ctx.static_slot != null);
    releasePin(&ctx);
}

test "zix integration: Http3 router 404s an unmatched path with no file behind it" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var root_buf: [64]u8 = undefined;
    const root = std.fmt.bufPrint(&root_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path}) catch unreachable;

    _ = try static_cache.install(32, 60_000);
    defer static_cache.shutdown(std.testing.io);

    var res = zix.Http3.Response{};
    var ctx = context(root);

    try dispatch("/absent.html", &res, &ctx);

    try std.testing.expectEqual(@as(u16, 404), res.status);
    try std.testing.expect(ctx.static_slot == null);
}

test "zix integration: Http3 router keeps routed paths ahead of the static fallback" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // A file that would shadow the routed "/" if the fallback ran first.
    writeFixture(tmp.dir, "index.html", "the static file");

    var root_buf: [64]u8 = undefined;
    const root = std.fmt.bufPrint(&root_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path}) catch unreachable;

    _ = try static_cache.install(32, 60_000);
    defer static_cache.shutdown(std.testing.io);

    var res = zix.Http3.Response{};
    var ctx = context(root);

    try dispatch("/", &res, &ctx);

    try std.testing.expectEqualStrings("home", res.body);
    try std.testing.expect(ctx.static_slot == null);
}

test "zix integration: Http3 router 404s static paths when caching is off" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    writeFixture(tmp.dir, "present.txt", "this file exists");

    var root_buf: [64]u8 = undefined;
    const root = std.fmt.bufPrint(&root_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path}) catch unreachable;

    // No cache installed, which is what a ttl of 0 leaves behind. The file exists, but this engine
    // has nowhere safe to serve it from, so a 404 is the correct and deliberate answer.
    try std.testing.expect(static_cache.instance() == null);

    var res = zix.Http3.Response{};
    var ctx = context(root);

    try dispatch("/present.txt", &res, &ctx);

    try std.testing.expectEqual(@as(u16, 404), res.status);
    try std.testing.expect(ctx.static_slot == null);
}

test "zix integration: Http3 router serves a multi-packet body that outlives the dispatch call" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Far past one datagram, so the engine would park this in a send-stream slot and read it again
    // for every packet and every retransmission.
    var payload: [64 * 1024]u8 = undefined;
    for (&payload, 0..) |*byte, index| byte.* = @intCast('a' + index % 26);

    writeFixture(tmp.dir, "big.bin", &payload);

    var root_buf: [64]u8 = undefined;
    const root = std.fmt.bufPrint(&root_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path}) catch unreachable;

    _ = try static_cache.install(32, 60_000);
    defer static_cache.shutdown(std.testing.io);

    var res = zix.Http3.Response{};
    var slot: ?u32 = null;

    // The Context lives and dies in this block, like the engine's per-call one.
    {
        var ctx = context(root);
        try dispatch("/big.bin", &res, &ctx);
        slot = ctx.static_slot;
    }

    try std.testing.expectEqual(@as(usize, payload.len), res.body.len);
    try std.testing.expectEqualSlices(u8, &payload, res.body);

    if (slot) |pinned| static_cache.instance().?.releaseSlot(pinned);
}
