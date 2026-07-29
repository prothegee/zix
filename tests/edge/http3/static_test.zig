//! Edge tests: the boundaries of serving static files on zix.Http3, where the engine has to decline
//! rather than hand its send path a body it cannot safely hold.

const std = @import("std");
const zix = @import("zix");

const static_cache = zix.utils.static_cache;

fn writeFixture(dir: std.Io.Dir, name: []const u8, data: []const u8) void {
    dir.writeFile(std.testing.io, .{ .sub_path = name, .data = data }) catch @panic("fixture write failed");
}

fn fixtureRoot(tmp: *std.testing.TmpDir, buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, ".zig-cache/tmp/{s}", .{tmp.sub_path}) catch unreachable;
}

// --------------------------------------------------------- //

test "zix edge: Http3 static declines a file past the snapshot ceiling" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var root_buf: [64]u8 = undefined;
    const root = fixtureRoot(&tmp, &root_buf);

    var cache = try static_cache.StaticCache.init(8);
    defer cache.deinit(std.testing.io);

    // One byte over the ceiling. The bytes have to be held for the whole response on this engine,
    // so an unbounded file would be an unbounded hold: it is declined instead.
    const oversize: usize = @intCast(static_cache.SNAPSHOT_MAX_BYTES + 1);
    const big = try std.testing.allocator.alloc(u8, oversize);
    defer std.testing.allocator.free(big);
    @memset(big, 'z');

    writeFixture(tmp.dir, "huge.bin", big);

    // The descriptor path still resolves it, so the other engines are unaffected.
    const plain = cache.acquire(std.testing.io, root, "huge.bin", null, 1000, 100).?;
    try std.testing.expectEqual(@as(u64, oversize), plain.size);
    cache.release(plain);

    // The bytes path declines, which is what makes zix.Http3 fall through to 404.
    try std.testing.expect(cache.acquireMapped(std.testing.io, root, "huge.bin", null, 1000, 100) == null);
}

test "zix edge: Http3 static serves a file exactly at the snapshot ceiling" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var root_buf: [64]u8 = undefined;
    const root = fixtureRoot(&tmp, &root_buf);

    var cache = try static_cache.StaticCache.init(8);
    defer cache.deinit(std.testing.io);

    // The ceiling is inclusive, so the boundary itself must serve.
    const at_limit: usize = @intCast(static_cache.SNAPSHOT_MAX_BYTES);
    const body = try std.testing.allocator.alloc(u8, at_limit);
    defer std.testing.allocator.free(body);
    @memset(body, 'q');

    writeFixture(tmp.dir, "limit.bin", body);

    const hit = cache.acquireMapped(std.testing.io, root, "limit.bin", null, 1000, 100).?;
    defer cache.release(hit);

    try std.testing.expectEqual(at_limit, hit.bytes.?.len);
    try std.testing.expectEqual(@as(u8, 'q'), hit.bytes.?[at_limit - 1]);
}

test "zix edge: Http3 static serves a zero-byte file as an empty body" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    writeFixture(tmp.dir, "empty.txt", "");

    var root_buf: [64]u8 = undefined;
    const root = fixtureRoot(&tmp, &root_buf);

    var cache = try static_cache.StaticCache.init(8);
    defer cache.deinit(std.testing.io);

    // An empty slice is already stable, so nothing is snapshotted and it is still a real hit.
    const hit = cache.acquireMapped(std.testing.io, root, "empty.txt", null, 1000, 100).?;
    defer cache.release(hit);

    try std.testing.expectEqual(@as(usize, 0), hit.bytes.?.len);
}

test "zix edge: Http3 static bytes are a snapshot, not a window onto the file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    writeFixture(tmp.dir, "moving.txt", "original content");

    var root_buf: [64]u8 = undefined;
    const root = fixtureRoot(&tmp, &root_buf);

    var cache = try static_cache.StaticCache.init(8);
    defer cache.deinit(std.testing.io);

    const hit = cache.acquireMapped(std.testing.io, root, "moving.txt", null, 1000, 100).?;
    defer cache.release(hit);

    // Rewritten in place, the same inode, which is what copying a new build over a served file
    // does. A mapping of the file would show the new bytes here and a shrunk file would fault.
    writeFixture(tmp.dir, "moving.txt", "different");

    try std.testing.expectEqualStrings("original content", hit.bytes.?);
}

test "zix edge: Http3 static bytes survive a truncation to a shorter file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var original: [64 * 1024]u8 = undefined;
    @memset(&original, 'a');
    writeFixture(tmp.dir, "shrink.bin", &original);

    var root_buf: [64]u8 = undefined;
    const root = fixtureRoot(&tmp, &root_buf);

    var cache = try static_cache.StaticCache.init(8);
    defer cache.deinit(std.testing.io);

    const hit = cache.acquireMapped(std.testing.io, root, "shrink.bin", null, 1000, 100).?;
    defer cache.release(hit);

    // The dangerous shape: the file becomes far shorter than what a response is still sending.
    writeFixture(tmp.dir, "shrink.bin", "tiny");

    try std.testing.expectEqual(@as(usize, original.len), hit.bytes.?.len);
    try std.testing.expectEqual(@as(u8, 'a'), hit.bytes.?[original.len - 1]);
}

test "zix edge: Http3 static declines every unsafe path before touching the disk" {
    var cache = try static_cache.StaticCache.init(8);
    defer cache.deinit(std.testing.io);

    try std.testing.expect(cache.acquireMapped(std.testing.io, "public", "../etc/passwd", null, 1000, 100) == null);
    try std.testing.expect(cache.acquireMapped(std.testing.io, "public", "/etc/passwd", null, 1000, 100) == null);
    try std.testing.expect(cache.acquireMapped(std.testing.io, "public", "", null, 1000, 100) == null);
}

test "zix edge: Http3 static bytes are snapshotted once and reused across requests" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    writeFixture(tmp.dir, "shared.txt", "one snapshot");

    var root_buf: [64]u8 = undefined;
    const root = fixtureRoot(&tmp, &root_buf);

    var cache = try static_cache.StaticCache.init(8);
    defer cache.deinit(std.testing.io);

    const first = cache.acquireMapped(std.testing.io, root, "shared.txt", null, 1000, 100).?;
    const second = cache.acquireMapped(std.testing.io, root, "shared.txt", null, 1000, 200).?;

    // Same backing, so concurrent responses for one file cost one copy, not one each.
    try std.testing.expectEqual(first.bytes.?.ptr, second.bytes.?.ptr);

    // And both hold their own pin, so the entry outlives whichever finishes first.
    try std.testing.expectEqual(@as(u32, 2), cache.pinCount(first.slot));

    cache.release(first);
    try std.testing.expectEqual(@as(u32, 1), cache.pinCount(second.slot));

    cache.release(second);
    try std.testing.expectEqual(@as(u32, 0), cache.pinCount(second.slot));
}
