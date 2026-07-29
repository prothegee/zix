//! Edge tests: zix.utils.static_cache boundaries, where the cache has to decline rather than
//! misbehave. Every case here ends in a null hit, which the engines treat as "serve it uncached".

const std = @import("std");
const zix = @import("zix");

const static_cache = zix.utils.static_cache;

// --------------------------------------------------------- //

/// Build a public_dir under the test cache directory and return its path inside buf.
fn fixtureRoot(tmp: *std.testing.TmpDir, buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, ".zig-cache/tmp/{s}", .{tmp.sub_path}) catch unreachable;
}

fn writeFixture(dir: std.Io.Dir, name: []const u8, data: []const u8) void {
    dir.writeFile(std.testing.io, .{ .sub_path = name, .data = data }) catch @panic("fixture write failed");
}

// --------------------------------------------------------- //

test "zix edge: static cache declines a path that escapes public_dir" {
    var cache = try static_cache.StaticCache.init(8);
    defer cache.deinit(std.testing.io);

    // Traversal, absolute, and empty are all refused before any file is opened.
    try std.testing.expect(cache.acquire(std.testing.io, "public", "../secret", null, 1000, 100) == null);
    try std.testing.expect(cache.acquire(std.testing.io, "public", "a/../../b", null, 1000, 100) == null);
    try std.testing.expect(cache.acquire(std.testing.io, "public", "/etc/hosts", null, 1000, 100) == null);
    try std.testing.expect(cache.acquire(std.testing.io, "public", "", null, 1000, 100) == null);
}

test "zix edge: static cache declines a resolved path longer than its buffer" {
    var cache = try static_cache.StaticCache.init(8);
    defer cache.deinit(std.testing.io);

    var long: [static_cache.RESOLVED_PATH_MAX]u8 = @splat('n');

    try std.testing.expect(cache.acquire(std.testing.io, "public", &long, null, 1000, 100) == null);
}

test "zix edge: static cache with ttl 0 never stores anything" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    writeFixture(tmp.dir, "off.txt", "never cached");

    var root_buf: [64]u8 = undefined;
    const root = fixtureRoot(&tmp, &root_buf);

    var cache = try static_cache.StaticCache.init(8);
    defer cache.deinit(std.testing.io);

    // The disabled default must not consume a slot, so switching it on later starts clean.
    try std.testing.expect(cache.acquire(std.testing.io, root, "off.txt", null, 0, 100) == null);
    try std.testing.expect(cache.acquire(std.testing.io, root, "off.txt", null, 1000, 100) != null);
}

test "zix edge: static cache declines a directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    tmp.dir.createDirPath(std.testing.io, "subdir") catch @panic("fixture dir failed");

    var root_buf: [64]u8 = undefined;
    const root = fixtureRoot(&tmp, &root_buf);

    var cache = try static_cache.StaticCache.init(8);
    defer cache.deinit(std.testing.io);

    // A directory opens but is not servable, so it must not be published as an entry.
    try std.testing.expect(cache.acquire(std.testing.io, root, "subdir", null, 1000, 100) == null);
}

test "zix edge: static cache serves a zero-byte file as a real hit" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    writeFixture(tmp.dir, "empty.txt", "");

    var root_buf: [64]u8 = undefined;
    const root = fixtureRoot(&tmp, &root_buf);

    var cache = try static_cache.StaticCache.init(8);
    defer cache.deinit(std.testing.io);

    const hit = cache.acquire(std.testing.io, root, "empty.txt", null, 1000, 100).?;
    defer cache.release(hit);

    try std.testing.expectEqual(@as(u64, 0), hit.size);
    try std.testing.expect(std.mem.indexOf(u8, hit.header, "Content-Length: 0\r\n") != null);
}

test "zix edge: static cache expiry is exact at the window boundary" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    writeFixture(tmp.dir, "edge.txt", "boundary");

    var root_buf: [64]u8 = undefined;
    const root = fixtureRoot(&tmp, &root_buf);

    var cache = try static_cache.StaticCache.init(8);
    defer cache.deinit(std.testing.io);

    const first = cache.acquire(std.testing.io, root, "edge.txt", null, 1000, 100).?;
    try std.testing.expectEqual(@as(u64, 8), first.size);
    cache.release(first);

    // The file grows on disk. Freshness is what decides whether that is visible yet, so the size
    // the cache reports is the observable difference between a hit and a re-resolve.
    writeFixture(tmp.dir, "edge.txt", "boundary-now-longer");

    // One millisecond before insert + ttl the entry is still fresh, so the old size answers.
    const inside = cache.acquire(std.testing.io, root, "edge.txt", null, 1000, 1099).?;
    try std.testing.expectEqual(@as(u64, 8), inside.size);
    cache.release(inside);

    // Exactly at insert + ttl the entry is expired, so the file is re-opened and re-stat'd.
    const outside = cache.acquire(std.testing.io, root, "edge.txt", null, 1000, 1100).?;
    try std.testing.expectEqual(@as(u64, "boundary-now-longer".len), outside.size);
    cache.release(outside);
}

test "zix edge: static cache keeps serving after the table fills with pinned entries" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    writeFixture(tmp.dir, "one.txt", "1");
    writeFixture(tmp.dir, "two.txt", "22");
    writeFixture(tmp.dir, "three.txt", "333");

    var root_buf: [64]u8 = undefined;
    const root = fixtureRoot(&tmp, &root_buf);

    // Two slots, both held, so the third request has nowhere to go.
    var cache = try static_cache.StaticCache.init(2);
    defer cache.deinit(std.testing.io);

    const one = cache.acquire(std.testing.io, root, "one.txt", null, 1000, 100).?;
    const two = cache.acquire(std.testing.io, root, "two.txt", null, 1000, 100).?;

    // Declined, not an error: the engine falls back to its own uncached path.
    try std.testing.expect(cache.acquire(std.testing.io, root, "three.txt", null, 1000, 100) == null);

    // The held entries are untouched by the failed insert.
    try std.testing.expectEqual(@as(u64, 1), one.size);
    try std.testing.expectEqual(@as(u64, 2), two.size);

    cache.release(one);
    cache.release(two);
}

test "zix edge: static cache negotiation falls back to identity when a client rejects everything" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    writeFixture(tmp.dir, "only.txt", "plain only");

    var root_buf: [64]u8 = undefined;
    const root = fixtureRoot(&tmp, &root_buf);

    var cache = try static_cache.StaticCache.init(8);
    defer cache.deinit(std.testing.io);

    // No sibling exists, and the client asked for codings the file does not have. Serving the
    // plain file beats refusing it, and it is what the uncached path does too.
    const hit = cache.acquire(std.testing.io, root, "only.txt", "br;q=1.0, gzip;q=0.9", 1000, 100).?;
    defer cache.release(hit);

    try std.testing.expectEqual(static_cache.Encoding.IDENTITY, hit.encoding);
    try std.testing.expect(std.mem.indexOf(u8, hit.header, "Content-Encoding") == null);
}

test "zix edge: static cache init survives an absurd entry request" {
    // Clamped against the descriptor budget rather than trusted, so this allocates a sane table
    // instead of trying to map one slot per requested entry.
    var cache = try static_cache.StaticCache.init(std.math.maxInt(u32));
    defer cache.deinit(std.testing.io);

    try std.testing.expect(cache.slots.len >= 32);
    try std.testing.expect(std.math.isPowerOfTwo(cache.slots.len));
}
