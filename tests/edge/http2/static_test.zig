//! Edge tests: the resident-body contract zix.Http2 static serving depends on.
//!
//! HTTP/2 cannot hand a DATA frame to sendfile while the mux is coalescing a batch, and that hook is
//! installed for the whole of one, so the engine asks the cache for bytes it can address instead.
//! These cases cover the boundaries of that request: what happens when the cache refuses to hold a
//! body, when there is no body to hold, and whether the pin that keeps those bytes alive is returned.

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

test "zix edge: static cache refuses to hold a body past the snapshot cap but still serves it" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // One byte over the cap is the whole point: at the cap it is still holdable.
    const oversized = try std.testing.allocator.alloc(u8, static_cache.SNAPSHOT_MAX_BYTES + 1);
    defer std.testing.allocator.free(oversized);
    @memset(oversized, 'z');

    writeFixture(tmp.dir, "huge.bin", oversized);

    var root_buf: [64]u8 = undefined;
    const root = fixtureRoot(&tmp, &root_buf);

    var cache = try static_cache.StaticCache.init(8);
    defer cache.deinit(std.testing.io);

    // No resident bytes for this one.
    try std.testing.expect(cache.acquireMapped(std.testing.io, root, "huge.bin", null, 1000, 100) == null);

    // The fallback is what keeps it servable: the descriptor is still cached, so the engine reads
    // through it rather than dropping the request to an open plus stat per request.
    const hit = cache.acquire(std.testing.io, root, "huge.bin", null, 1000, 100).?;
    defer cache.release(hit);

    try std.testing.expectEqual(@as(u64, static_cache.SNAPSHOT_MAX_BYTES + 1), hit.size);
    try std.testing.expect(hit.bytes == null);
}

test "zix edge: a declined snapshot leaves no pin behind" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const oversized = try std.testing.allocator.alloc(u8, static_cache.SNAPSHOT_MAX_BYTES + 1);
    defer std.testing.allocator.free(oversized);
    @memset(oversized, 'q');

    writeFixture(tmp.dir, "big.bin", oversized);

    var root_buf: [64]u8 = undefined;
    const root = fixtureRoot(&tmp, &root_buf);

    var cache = try static_cache.StaticCache.init(8);
    defer cache.deinit(std.testing.io);

    // acquireMapped pins before it discovers it cannot hold the body. A pin it never hands back
    // would make the entry permanently unreclaimable, so it has to release its own.
    try std.testing.expect(cache.acquireMapped(std.testing.io, root, "big.bin", null, 1000, 100) == null);

    const hit = cache.acquire(std.testing.io, root, "big.bin", null, 1000, 100).?;
    const slot = hit.slot;
    cache.release(hit);

    try std.testing.expectEqual(@as(u32, 0), cache.pinCount(slot));
}

test "zix edge: a zero-byte file yields resident bytes that are empty, not absent" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    writeFixture(tmp.dir, "empty.css", "");

    var root_buf: [64]u8 = undefined;
    const root = fixtureRoot(&tmp, &root_buf);

    var cache = try static_cache.StaticCache.init(8);
    defer cache.deinit(std.testing.io);

    const hit = cache.acquireMapped(std.testing.io, root, "empty.css", null, 1000, 100).?;
    defer cache.release(hit);

    // An empty slice is already stable, so no snapshot is made, but the caller must still see a
    // body it can frame rather than a null it would read as "cache declined".
    try std.testing.expect(hit.bytes != null);
    try std.testing.expectEqual(@as(usize, 0), hit.bytes.?.len);
    try std.testing.expectEqual(@as(u64, 0), hit.size);
}

test "zix edge: resident bytes stay at one address across repeated requests" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    writeFixture(tmp.dir, "app.js", "export const version = 1;");

    var root_buf: [64]u8 = undefined;
    const root = fixtureRoot(&tmp, &root_buf);

    var cache = try static_cache.StaticCache.init(8);
    defer cache.deinit(std.testing.io);

    const first = cache.acquireMapped(std.testing.io, root, "app.js", null, 1000, 100).?;
    const address = first.bytes.?.ptr;
    cache.release(first);

    // The snapshot is charged to the first request that needs it and reused after, which is what
    // makes the second request a table read instead of a file read.
    var round: usize = 0;
    while (round < 16) : (round += 1) {
        const repeat = cache.acquireMapped(std.testing.io, root, "app.js", null, 1000, 100 + round).?;
        try std.testing.expectEqual(address, repeat.bytes.?.ptr);
        try std.testing.expectEqualStrings("export const version = 1;", repeat.bytes.?);
        cache.release(repeat);
    }

    const settled = cache.acquire(std.testing.io, root, "app.js", null, 1000, 200).?;
    const slot = settled.slot;
    cache.release(settled);

    try std.testing.expectEqual(@as(u32, 0), cache.pinCount(slot));
}

test "zix edge: each encoding variant gets its own resident bytes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    writeFixture(tmp.dir, "vendor.js", "the plain vendor bundle");
    writeFixture(tmp.dir, "vendor.js.br", "squeezed");
    writeFixture(tmp.dir, "vendor.js.gz", "zipped-x");

    var root_buf: [64]u8 = undefined;
    const root = fixtureRoot(&tmp, &root_buf);

    var cache = try static_cache.StaticCache.init(8);
    defer cache.deinit(std.testing.io);

    // Three variants share one slot, so a snapshot taken for one must not be handed to another.
    const brotli = cache.acquireMapped(std.testing.io, root, "vendor.js", "br", 1000, 100).?;
    try std.testing.expectEqualStrings("squeezed", brotli.bytes.?);
    cache.release(brotli);

    const gzip = cache.acquireMapped(std.testing.io, root, "vendor.js", "gzip", 1000, 100).?;
    try std.testing.expectEqualStrings("zipped-x", gzip.bytes.?);
    cache.release(gzip);

    const plain = cache.acquireMapped(std.testing.io, root, "vendor.js", null, 1000, 100).?;
    try std.testing.expectEqualStrings("the plain vendor bundle", plain.bytes.?);
    cache.release(plain);
}

test "zix edge: resident bytes survive an expiry sweep while a response still holds them" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    writeFixture(tmp.dir, "inflight.css", "body{color:red}");

    var root_buf: [64]u8 = undefined;
    const root = fixtureRoot(&tmp, &root_buf);

    var cache = try static_cache.StaticCache.init(8);
    defer cache.deinit(std.testing.io);

    const held = cache.acquireMapped(std.testing.io, root, "inflight.css", null, 1000, 100).?;

    // A body parked mid-response is exactly what the pin protects: an expired lookup must not
    // unmap bytes the send path is still reading.
    try std.testing.expect(cache.acquire(std.testing.io, root, "inflight.css", null, 1000, 9000) == null);
    try std.testing.expectEqualStrings("body{color:red}", held.bytes.?);

    cache.release(held);
}
