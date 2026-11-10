//! ZIX utils static cache
//!
//! ### file: src/zix/utils/static/StaticCache.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Table of resolved public_dir files kept open across requests, shared by
//! every worker of the process.
//!
//! ### note:
//!
//! Reads are lock-free: a reader pins a slot with an atomic compare-and-swap
//! that only succeeds while the slot is live. Insert, reclaim, and snapshot
//! hold one spinlock.
//! The cache never fails a request. A full table, an unreadable file, or an
//! unsafe path returns null, and the caller serves the uncached path.
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
const slab_mem = @import("../../multiplexers/slab.zig");
const StaticHit = @import("StaticHit.zig");
const StaticSlot = @import("StaticSlot.zig");
const cache_descriptor = @import("cache_descriptor.zig");
const cache_header = @import("cache_header.zig");
const cache_path = @import("cache_path.zig");

// --------------------------------------------------------- //
// Fields:

/// Slot table, one demand-paged zeroed mapping.
slots: []StaticSlot,
/// Slot count minus one, the count is a power of two.
mask: usize,
/// Spinlock for insert, reclaim, and snapshot.
lock_flag: std.atomic.Value(bool),

const Self = @This();

// --------------------------------------------------------- //
// Private:

/// Slots examined when an insert finds no room. Bounded so no request pays
/// for a full table scan.
const SWEEP_BUDGET: usize = 8;

fn lock(self: *Self) void {
    while (self.lock_flag.swap(true, .acquire)) std.atomic.spinLoopHint();
}

fn unlock(self: *Self) void {
    self.lock_flag.store(false, .release);
}

/// Probe for a live, fresh slot holding path and pin it.
///
/// Note:
/// - An expired slot is reclaimed here, so clean-up rides on traffic.
///
/// Return:
/// - u32 (pinned slot index)
/// - null on a miss, an expired entry, or a slot being reclaimed
fn lookup(
    self: *Self,
    io: std.Io,
    key: u64,
    full_path: []const u8,
    ttl_ms: u32,
    now_ms: u64,
) ?u32 {
    var index: usize = @intCast(key & self.mask);
    var probes: usize = 0;
    while (probes <= self.mask) : (probes += 1) {
        const slot = &self.slots[index];
        const slot_key = @atomicLoad(u64, &slot.key, .acquire);
        if (slot_key == 0) return null;

        if (slot_key == key) {
            if (!slot.pin()) return null;

            // Re-read under the pin: the slot may have been reused for
            // another path between the key read and the pin.
            const same =
                @atomicLoad(u64, &slot.key, .acquire) == key and
                std.mem.eql(u8, slot.path(), full_path);
            if (!same) {
                slot.unpin();

                return null;
            }

            if (!slot.isFresh(ttl_ms, now_ms)) {
                slot.unpin();
                self.reclaimExpired(io, index);

                return null;
            }

            return @intCast(index);
        }

        index = (index + 1) & self.mask;
    }

    return null;
}

/// Open path and its siblings, publish them into a slot, and pin it.
///
/// Note:
/// - A miss is never cached, so a flood of unknown paths does not evict the
///   entries being served.
///
/// Return:
/// - u32 (pinned slot index)
/// - null when the file is unreadable or the table has no room
fn insert(
    self: *Self,
    io: std.Io,
    key: u64,
    full_path: []const u8,
    ttl_ms: u32,
    now_ms: u64,
) ?u32 {
    self.lock();
    defer self.unlock();

    // Another worker may have published this path while this one waited.
    // A live slot is never rewritten, a reader could be holding it.
    if (self.probeLive(key, full_path)) |live| {
        const slot = &self.slots[live];
        if (slot.isFresh(ttl_ms, now_ms) and slot.pin()) return @intCast(live);

        return null;
    }

    const index = self.findFreeSlot(io, key) orelse return null;
    const slot = &self.slots[index];

    if (!slot.openVariants(io, full_path)) return null;

    slot.insert_tick_ms = now_ms;
    slot.path_len = @intCast(full_path.len);
    @memcpy(slot.path_buf[0..full_path.len], full_path);

    // Key first, then the live flag. A reader reaches the fields only after
    // an acquiring pin, which pairs with this release store.
    @atomicStore(u64, &slot.key, key, .release);
    slot.state.store(StaticSlot.STATE_LIVE | 1, .release);

    return @intCast(index);
}

/// Find a slot this insert may write, sweeping when the probe finds none.
/// Caller holds the lock.
fn findFreeSlot(self: *Self, io: std.Io, key: u64) ?usize {
    if (self.probeFreeSlot(key)) |index| return index;

    self.sweep(io, key);

    return self.probeFreeSlot(key);
}

/// Walk the probe chain for a slot that is not live. Caller holds the lock.
fn probeFreeSlot(self: *Self, key: u64) ?usize {
    var index: usize = @intCast(key & self.mask);
    var probes: usize = 0;
    while (probes <= self.mask) : (probes += 1) {
        if (!self.slots[index].isLive()) return index;

        index = (index + 1) & self.mask;
    }

    return null;
}

/// Walk the probe chain for the live slot holding this path. Caller holds the
/// lock.
fn probeLive(self: *Self, key: u64, full_path: []const u8) ?usize {
    var index: usize = @intCast(key & self.mask);
    var probes: usize = 0;
    while (probes <= self.mask) : (probes += 1) {
        const slot = &self.slots[index];
        const slot_key = @atomicLoad(u64, &slot.key, .acquire);
        if (slot_key == 0) return null;

        const match =
            slot.isLive() and
            slot_key == key and
            std.mem.eql(u8, slot.path(), full_path);
        if (match) return index;

        index = (index + 1) & self.mask;
    }

    return null;
}

/// Reclaim up to SWEEP_BUDGET unpinned slots from the probe home. Caller holds
/// the lock.
///
/// Note:
/// - Freshness is not checked. A full table values room for the request in
///   hand over a cached entry, which is re-opened on its next request.
fn sweep(self: *Self, io: std.Io, key: u64) void {
    var index: usize = @intCast(key & self.mask);
    var swept: usize = 0;
    while (swept < SWEEP_BUDGET and swept <= self.mask) : (swept += 1) {
        const slot = &self.slots[index];
        if (slot.tryKill()) slot.closeVariants(io);

        index = (index + 1) & self.mask;
    }
}

/// Close an expired slot. A pinned slot is left for the next expired lookup.
fn reclaimExpired(self: *Self, io: std.Io, index: usize) void {
    self.lock();
    defer self.unlock();

    const slot = &self.slots[index];
    if (!slot.tryKill()) return;

    slot.closeVariants(io);
}

// --------------------------------------------------------- //
// Public:

/// ZIX utils static cache error
pub const Error = error {
    ZixUtils_StaticCache_OutOfMemory,
    ZixUtils_StaticCache_MapFailed,
};

/// Map the slot table.
///
/// Note:
/// - max_entries is clamped to the descriptor budget, then rounded down to a
///   power of two.
///
/// Param:
/// max_entries - u32 (requested slot count)
///
/// Return:
/// - Self
/// - Error when the table cannot be mapped
pub fn init(max_entries: u32) Error!Self {
    const clamped = @min(@max(1, max_entries), cache_descriptor.ceiling());
    const entries: usize = std.math.floorPowerOfTwo(u32, clamped);

    const slots = slab_mem.mapZeroedSlots(StaticSlot, entries) catch |err| switch (err) {
        error.ZixUtils_Slab_OutOfMemory => return Error.ZixUtils_StaticCache_OutOfMemory,
        error.ZixUtils_Slab_MapFailed => return Error.ZixUtils_StaticCache_MapFailed,
    };

    // A huge page policy would make the first insert resident for 2 MiB.
    slab_mem.adviseNoHugePages(std.mem.sliceAsBytes(slots));

    return .{
        .slots = slots,
        .mask = entries - 1,
        .lock_flag = .init(false),
    };
}

/// Close every open file and unmap the table.
///
/// Note:
/// - Call only after every worker has stopped.
///
/// Param:
/// io - std.Io (close)
pub fn deinit(self: *Self, io: std.Io) void {
    for (self.slots) |*slot| {
        if (!slot.isLive()) continue;

        slot.closeVariants(io);
        slot.state.store(0, .release);
    }

    slab_mem.unmapSlots(self.slots);
}

/// Look up the request path, inserting it on a miss, and return a pinned hit.
///
/// Note:
/// - The hit must go back through release once the response is written.
/// - null is never an error: the caller serves the uncached path.
///
/// Param:
/// io - std.Io (open, stat, close)
/// public_dir - []const u8 (static root)
/// req_path - []const u8 (request path with the leading slash stripped)
/// accept_encoding - ?[]const u8 (raw Accept-Encoding value)
/// ttl_ms - u32 (freshness window, 0 disables)
/// now_ms - u64 (coarse monotonic clock)
///
/// Return:
/// - StaticHit (pinned)
/// - null when the path is unsafe, the file is unreadable, or the table is full
pub fn acquire(
    self: *Self,
    io: std.Io,
    public_dir: []const u8,
    req_path: []const u8,
    accept_encoding: ?[]const u8,
    ttl_ms: u32,
    now_ms: u64,
) ?StaticHit {
    if (ttl_ms == 0) return null;

    var path_buf: [cache_path.PUBLIC_PATH_MAX]u8 = undefined;
    const full_path = cache_path.resolve(&path_buf, public_dir, req_path) orelse return null;
    const key = cache_path.hash(full_path);

    if (self.lookup(io, key, full_path, ttl_ms, now_ms)) |pinned| {
        return self.slots[pinned].hit(pinned, accept_encoding);
    }

    const inserted = self.insert(io, key, full_path, ttl_ms, now_ms) orelse return null;

    return self.slots[inserted].hit(inserted, accept_encoding);
}

/// Like acquire, but the hit also carries resident bytes.
///
/// Note:
/// - For a response that cannot use sendfile (a non-Linux target).
/// - The snapshot is made once per variant, by the first request that needs it.
///
/// Return:
/// - StaticHit with bytes set (pinned)
/// - null on the same terms as acquire, or when no snapshot can be made
pub fn acquireMapped(
    self: *Self,
    io: std.Io,
    public_dir: []const u8,
    req_path: []const u8,
    accept_encoding: ?[]const u8,
    ttl_ms: u32,
    now_ms: u64,
) ?StaticHit {
    var pinned = self.acquire(
        io,
        public_dir,
        req_path,
        accept_encoding,
        ttl_ms,
        now_ms,
    ) orelse return null;
    const index = cache_header.variantIndex(pinned.encoding);
    const variant = &self.slots[pinned.slot].variants[index];

    if (!variant.mapped.load(.acquire)) {
        self.lock();
        defer self.unlock();

        if (!variant.map(io)) {
            self.release(pinned);

            return null;
        }
    }

    pinned.bytes = variant.bytes();

    return pinned;
}

/// Drop the pin taken by acquire.
///
/// Param:
/// pinned - StaticHit (from acquire or acquireMapped)
pub fn release(self: *Self, pinned: StaticHit) void {
    self.slots[pinned.slot].unpin();
}

/// Outstanding pins on one slot. A slot that never returns to 0 is a leaked
/// pin and can never expire.
///
/// Param:
/// index - u32 (slot index)
///
/// Return:
/// - u32
pub fn pinCount(self: *Self, index: u32) u32 {
    return self.slots[index].pinCount();
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

fn writeFixture(tmp: *std.testing.TmpDir, name: []const u8, data: []const u8) void {
    tmp.dir.writeFile(std.testing.io, .{
        .sub_path = name,
        .data = data,
    }) catch |err| switch (err) {
        else => @panic("fixture write failed"),
    };
}

fn fixtureRoot(tmp: *std.testing.TmpDir, buf: []u8) []const u8 {
    const root = std.fmt.bufPrint(buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    return root catch |err| switch (err) {
        error.NoSpaceLeft => @panic("fixture path too long"),
    };
}

test "zix utils static: StaticCache, init rounds down to a power of two" {
    var cache = try Self.init(100);
    defer cache.deinit(std.testing.io);

    try std.testing.expectEqual(@as(usize, 64), cache.slots.len);
    try std.testing.expectEqual(@as(usize, 63), cache.mask);
}

test "zix utils static: StaticCache, init zero entries still gives one slot" {
    var cache = try Self.init(0);
    defer cache.deinit(std.testing.io);

    try std.testing.expectEqual(@as(usize, 1), cache.slots.len);
}

test "zix utils static: StaticCache, acquire caches the file once" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    writeFixture(&tmp, "hello.txt", "hello static");

    var root_buf: [64]u8 = undefined;
    const root = fixtureRoot(&tmp, &root_buf);

    var cache = try Self.init(16);
    defer cache.deinit(std.testing.io);

    const first = cache.acquire(std.testing.io, root, "hello.txt", null, 1000, 100).?;
    cache.release(first);

    const second = cache.acquire(std.testing.io, root, "hello.txt", null, 1000, 200).?;
    defer cache.release(second);

    try std.testing.expectEqual(first.file.handle, second.file.handle);
    try std.testing.expectEqual(@as(u64, 12), second.size);
}

test "zix utils static: StaticCache, acquire hit reads the file bytes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    writeFixture(&tmp, "hello.txt", "hello static");

    var root_buf: [64]u8 = undefined;
    const root = fixtureRoot(&tmp, &root_buf);

    var cache = try Self.init(16);
    defer cache.deinit(std.testing.io);

    const pinned = cache.acquire(std.testing.io, root, "hello.txt", null, 1000, 100).?;
    defer cache.release(pinned);

    var read_buf: [32]u8 = undefined;
    const read = try pinned.file.readPositionalAll(
        std.testing.io,
        read_buf[0..@intCast(pinned.size)],
        0,
    );

    try std.testing.expectEqualStrings("hello static", read_buf[0..read]);
}

test "zix utils static: StaticCache, acquire missing file caches nothing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var root_buf: [64]u8 = undefined;
    const root = fixtureRoot(&tmp, &root_buf);

    var cache = try Self.init(16);
    defer cache.deinit(std.testing.io);

    const missing = cache.acquire(std.testing.io, root, "absent.txt", null, 1000, 1);

    try std.testing.expect(missing == null);
    for (cache.slots) |*slot| try std.testing.expectEqual(@as(u64, 0), slot.key);
}

test "zix utils static: StaticCache, acquire with ttl 0 never touches the table" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    writeFixture(&tmp, "off.txt", "not cached");

    var root_buf: [64]u8 = undefined;
    const root = fixtureRoot(&tmp, &root_buf);

    var cache = try Self.init(16);
    defer cache.deinit(std.testing.io);

    try std.testing.expect(cache.acquire(std.testing.io, root, "off.txt", null, 0, 1) == null);
    for (cache.slots) |*slot| try std.testing.expectEqual(@as(u64, 0), slot.key);
}

test "zix utils static: StaticCache, acquire traversal is null" {
    var cache = try Self.init(16);
    defer cache.deinit(std.testing.io);

    const unsafe = cache.acquire(std.testing.io, "public", "../x", null, 1000, 1);

    try std.testing.expect(unsafe == null);
}

test "zix utils static: StaticCache, acquire negotiates a precompressed sibling" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    writeFixture(&tmp, "app.js", "plain-body-bytes");
    writeFixture(&tmp, "app.js.gz", "gz-body-x");

    var root_buf: [64]u8 = undefined;
    const root = fixtureRoot(&tmp, &root_buf);

    var cache = try Self.init(16);
    defer cache.deinit(std.testing.io);

    const gzip = cache.acquire(std.testing.io, root, "app.js", "gzip", 1000, 1).?;
    defer cache.release(gzip);

    try std.testing.expectEqual(@as(u64, 9), gzip.size);
    const coding = "Content-Encoding: gzip\r\n";

    try std.testing.expect(std.mem.indexOf(u8, gzip.header, coding) != null);
}

test "zix utils static: StaticCache, an expired entry is re-opened" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    writeFixture(&tmp, "stale.txt", "first");

    var root_buf: [64]u8 = undefined;
    const root = fixtureRoot(&tmp, &root_buf);

    var cache = try Self.init(16);
    defer cache.deinit(std.testing.io);

    cache.release(cache.acquire(std.testing.io, root, "stale.txt", null, 1000, 100).?);
    writeFixture(&tmp, "stale.txt", "second-longer");

    const refreshed = cache.acquire(std.testing.io, root, "stale.txt", null, 1000, 5000).?;
    defer cache.release(refreshed);

    try std.testing.expectEqual(@as(u64, 13), refreshed.size);
}

test "zix utils static: StaticCache, a pinned slot survives an expired lookup" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    writeFixture(&tmp, "pinned.txt", "in flight");

    var root_buf: [64]u8 = undefined;
    const root = fixtureRoot(&tmp, &root_buf);

    var cache = try Self.init(16);
    defer cache.deinit(std.testing.io);

    const held = cache.acquire(std.testing.io, root, "pinned.txt", null, 1000, 100).?;
    defer cache.release(held);

    const expired = cache.acquire(std.testing.io, root, "pinned.txt", null, 1000, 9000);

    try std.testing.expect(expired == null);
    try std.testing.expect(cache.slots[held.slot].isLive());
}

test "zix utils static: StaticCache, a full pinned table is null" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    writeFixture(&tmp, "a.txt", "a");
    writeFixture(&tmp, "b.txt", "b");
    writeFixture(&tmp, "c.txt", "c");

    var root_buf: [64]u8 = undefined;
    const root = fixtureRoot(&tmp, &root_buf);

    var cache = try Self.init(2);
    defer cache.deinit(std.testing.io);

    const first = cache.acquire(std.testing.io, root, "a.txt", null, 1000, 1).?;
    defer cache.release(first);
    const second = cache.acquire(std.testing.io, root, "b.txt", null, 1000, 1).?;
    defer cache.release(second);

    try std.testing.expect(cache.acquire(std.testing.io, root, "c.txt", null, 1000, 1) == null);
}

test "zix utils static: StaticCache, a full table sweeps unpinned entries" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    writeFixture(&tmp, "a.txt", "a");
    writeFixture(&tmp, "b.txt", "bb");
    writeFixture(&tmp, "c.txt", "ccc");

    var root_buf: [64]u8 = undefined;
    const root = fixtureRoot(&tmp, &root_buf);

    var cache = try Self.init(2);
    defer cache.deinit(std.testing.io);

    cache.release(cache.acquire(std.testing.io, root, "a.txt", null, 1000, 1).?);
    cache.release(cache.acquire(std.testing.io, root, "b.txt", null, 1000, 1).?);

    const third = cache.acquire(std.testing.io, root, "c.txt", null, 1000, 1).?;
    defer cache.release(third);

    try std.testing.expectEqual(@as(u64, 3), third.size);
}

test "zix utils static: StaticCache, release drops the pin" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    writeFixture(&tmp, "p.txt", "p");

    var root_buf: [64]u8 = undefined;
    const root = fixtureRoot(&tmp, &root_buf);

    var cache = try Self.init(4);
    defer cache.deinit(std.testing.io);

    const pinned = cache.acquire(std.testing.io, root, "p.txt", null, 1000, 1).?;
    try std.testing.expectEqual(@as(u32, 1), cache.pinCount(pinned.slot));

    cache.release(pinned);

    try std.testing.expectEqual(@as(u32, 0), cache.pinCount(pinned.slot));
}

test "zix utils static: StaticCache, acquireMapped carries resident bytes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    writeFixture(&tmp, "page.html", "<h1>resident</h1>");

    var root_buf: [64]u8 = undefined;
    const root = fixtureRoot(&tmp, &root_buf);

    var cache = try Self.init(4);
    defer cache.deinit(std.testing.io);

    const pinned = cache.acquireMapped(std.testing.io, root, "page.html", null, 1000, 1).?;
    defer cache.release(pinned);

    try std.testing.expectEqualStrings("<h1>resident</h1>", pinned.bytes.?);
}

test "zix utils static: StaticCache, acquireMapped maps the chosen sibling" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    writeFixture(&tmp, "vendor.js", "the plain vendor bundle");
    writeFixture(&tmp, "vendor.js.br", "squeezed");

    var root_buf: [64]u8 = undefined;
    const root = fixtureRoot(&tmp, &root_buf);

    var cache = try Self.init(4);
    defer cache.deinit(std.testing.io);

    const pinned = cache.acquireMapped(std.testing.io, root, "vendor.js", "br", 1000, 1).?;
    defer cache.release(pinned);

    try std.testing.expectEqualStrings("squeezed", pinned.bytes.?);
}

