//! Integration tests: the zix.Http1 router static fallback served through the process static cache.
//!
//! These drive the real dispatch path (Router.dispatch, the static fallback, the engine's own
//! writes) over a socketpair, so what is asserted is the bytes a client would actually receive.

const std = @import("std");
const zix = @import("zix");

const static_cache = zix.utils.static_cache;

fn homeHandler(_: *zix.Http1.Request, res: *zix.Http1.Response, _: *zix.Http1.Context) anyerror!void {
    try res.send("home");
}

const TestRouter = zix.Http1.Router(&[_]zix.Http1.Route{
    .{ .path = "/", .handler = homeHandler },
});

// --------------------------------------------------------- //

fn parsedHead(raw: []const u8) zix.Http1.ParsedHead {
    return (zix.Http1.parseHead(raw) catch unreachable).head;
}

/// Dispatch one raw request over fd through the full router path.
fn dispatchRaw(raw: []const u8, fd: std.posix.fd_t) !void {
    const head = parsedHead(raw);
    var req = zix.Http1.Request.init(&head, "", fd);
    var res = zix.Http1.Response.init(fd, undefined, std.testing.allocator);
    var ctx = zix.Http1.Context.init(undefined, std.testing.allocator, fd);

    try TestRouter.dispatch(&req, &res, &ctx);
}

/// Drain whatever the peer end holds right now.
fn readPeer(peer: std.posix.fd_t, buf: []u8) []const u8 {
    const read_result = std.os.linux.read(peer, buf.ptr, buf.len);
    if (std.posix.errno(read_result) != .SUCCESS) return &.{};

    return buf[0..@intCast(read_result)];
}

fn writeFixture(dir: std.Io.Dir, name: []const u8, data: []const u8) void {
    dir.writeFile(std.testing.io, .{ .sub_path = name, .data = data }) catch @panic("fixture write failed");
}

// --------------------------------------------------------- //

test "zix integration: Http1 router serves an unmatched path from the static cache" {
    if (comptime @import("builtin").target.os.tag != .linux) {
        // The wire is captured through a Linux socketpair.
        std.log.info("this test drives a Linux socket wire, test skipped", .{});
        return;
    }

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    writeFixture(tmp.dir, "doc.html", "<h1>from the cache</h1>");

    var root_buf: [64]u8 = undefined;
    const root = std.fmt.bufPrint(&root_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path}) catch unreachable;

    _ = try static_cache.install(32, 60_000);
    defer static_cache.shutdown(std.testing.io);

    var pair: [2]std.posix.fd_t = undefined;
    try std.testing.expectEqual(@as(usize, 0), std.os.linux.socketpair(std.os.linux.AF.UNIX, std.os.linux.SOCK.STREAM, 0, &pair));
    defer {
        _ = std.os.linux.close(pair[0]);
        _ = std.os.linux.close(pair[1]);
    }

    zix.Http1.setStatic(root, std.testing.io);
    defer zix.Http1.setStatic("", std.testing.io);

    try dispatchRaw("GET /doc.html HTTP/1.1\r\nHost: localhost\r\n\r\n", pair[0]);

    var wire_buf: [1024]u8 = undefined;
    const wire = readPeer(pair[1], &wire_buf);

    try std.testing.expect(std.mem.startsWith(u8, wire, "HTTP/1.1 200 OK\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, wire, "Content-Type: text/html\r\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, wire, "\r\n\r\n<h1>from the cache</h1>"));
}

test "zix integration: Http1 router still 404s an unmatched path with no file behind it" {
    if (comptime @import("builtin").target.os.tag != .linux) {
        std.log.info("this test drives a Linux socket wire, test skipped", .{});
        return;
    }

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var root_buf: [64]u8 = undefined;
    const root = std.fmt.bufPrint(&root_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path}) catch unreachable;

    _ = try static_cache.install(32, 60_000);
    defer static_cache.shutdown(std.testing.io);

    var pair: [2]std.posix.fd_t = undefined;
    try std.testing.expectEqual(@as(usize, 0), std.os.linux.socketpair(std.os.linux.AF.UNIX, std.os.linux.SOCK.STREAM, 0, &pair));
    defer {
        _ = std.os.linux.close(pair[0]);
        _ = std.os.linux.close(pair[1]);
    }

    zix.Http1.setStatic(root, std.testing.io);
    defer zix.Http1.setStatic("", std.testing.io);

    try dispatchRaw("GET /absent.html HTTP/1.1\r\nHost: localhost\r\n\r\n", pair[0]);

    var wire_buf: [1024]u8 = undefined;
    const wire = readPeer(pair[1], &wire_buf);

    try std.testing.expect(std.mem.startsWith(u8, wire, "HTTP/1.1 404 Not Found\r\n"));
}

test "zix integration: Http1 router keeps routed paths ahead of the static cache" {
    if (comptime @import("builtin").target.os.tag != .linux) {
        std.log.info("this test drives a Linux socket wire, test skipped", .{});
        return;
    }

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // A file that would shadow the routed "/" if the fallback ran first.
    writeFixture(tmp.dir, "index.html", "the static file");

    var root_buf: [64]u8 = undefined;
    const root = std.fmt.bufPrint(&root_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path}) catch unreachable;

    _ = try static_cache.install(32, 60_000);
    defer static_cache.shutdown(std.testing.io);

    var pair: [2]std.posix.fd_t = undefined;
    try std.testing.expectEqual(@as(usize, 0), std.os.linux.socketpair(std.os.linux.AF.UNIX, std.os.linux.SOCK.STREAM, 0, &pair));
    defer {
        _ = std.os.linux.close(pair[0]);
        _ = std.os.linux.close(pair[1]);
    }

    zix.Http1.setStatic(root, std.testing.io);
    defer zix.Http1.setStatic("", std.testing.io);

    try dispatchRaw("GET / HTTP/1.1\r\nHost: localhost\r\n\r\n", pair[0]);

    var wire_buf: [1024]u8 = undefined;
    const wire = readPeer(pair[1], &wire_buf);

    try std.testing.expect(std.mem.endsWith(u8, wire, "home"));
}

test "zix integration: Http1 router repeats a cached file byte for byte across requests" {
    if (comptime @import("builtin").target.os.tag != .linux) {
        std.log.info("this test drives a Linux socket wire, test skipped", .{});
        return;
    }

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    writeFixture(tmp.dir, "repeat.txt", "same every time");

    var root_buf: [64]u8 = undefined;
    const root = std.fmt.bufPrint(&root_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path}) catch unreachable;

    _ = try static_cache.install(32, 60_000);
    defer static_cache.shutdown(std.testing.io);

    var pair: [2]std.posix.fd_t = undefined;
    try std.testing.expectEqual(@as(usize, 0), std.os.linux.socketpair(std.os.linux.AF.UNIX, std.os.linux.SOCK.STREAM, 0, &pair));
    defer {
        _ = std.os.linux.close(pair[0]);
        _ = std.os.linux.close(pair[1]);
    }

    zix.Http1.setStatic(root, std.testing.io);
    defer zix.Http1.setStatic("", std.testing.io);

    var first_buf: [1024]u8 = undefined;
    try dispatchRaw("GET /repeat.txt HTTP/1.1\r\nHost: localhost\r\n\r\n", pair[0]);
    const first = readPeer(pair[1], &first_buf);

    // The second request replays the prerendered header and the same open file, so the wire bytes
    // must be identical to the first, cold, response.
    var second_buf: [1024]u8 = undefined;
    try dispatchRaw("GET /repeat.txt HTTP/1.1\r\nHost: localhost\r\n\r\n", pair[0]);
    const second = readPeer(pair[1], &second_buf);

    try std.testing.expectEqualStrings(first, second);
}

test "zix integration: Http1 router serves the same file uncached when no cache is installed" {
    if (comptime @import("builtin").target.os.tag != .linux) {
        std.log.info("this test drives a Linux socket wire, test skipped", .{});
        return;
    }

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    writeFixture(tmp.dir, "plain.txt", "no cache here");

    var root_buf: [64]u8 = undefined;
    const root = std.fmt.bufPrint(&root_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path}) catch unreachable;

    // The shipped default installs nothing, so the original path has to keep working.
    try std.testing.expect(static_cache.instance() == null);

    var pair: [2]std.posix.fd_t = undefined;
    try std.testing.expectEqual(@as(usize, 0), std.os.linux.socketpair(std.os.linux.AF.UNIX, std.os.linux.SOCK.STREAM, 0, &pair));
    defer {
        _ = std.os.linux.close(pair[0]);
        _ = std.os.linux.close(pair[1]);
    }

    zix.Http1.setStatic(root, std.testing.io);
    defer zix.Http1.setStatic("", std.testing.io);

    try dispatchRaw("GET /plain.txt HTTP/1.1\r\nHost: localhost\r\n\r\n", pair[0]);

    var wire_buf: [1024]u8 = undefined;
    const wire = readPeer(pair[1], &wire_buf);

    try std.testing.expect(std.mem.startsWith(u8, wire, "HTTP/1.1 200 OK\r\n"));
    try std.testing.expect(std.mem.endsWith(u8, wire, "\r\n\r\nno cache here"));
}
