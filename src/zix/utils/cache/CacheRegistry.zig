//! ZIX utils cache registry
//!
//! ### file: src/zix/utils/cache/CacheRegistry.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Every response cache built so far, behind a spinlock, with a generation
//! based free.
//!
//! ### note:
//!
//! A spinlock rather than a mutex: it is taken when a thread builds its
//! cache, by reclaim(), and by the release() that ends the last connection.
//! Never per request. Every cache is allocated and freed with
//! std.heap.smp_allocator.
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
const CacheEntry = @import("CacheEntry.zig");
const ResponseCache = @import("ResponseCache.zig");

// --------------------------------------------------------- //
// Fields:

/// Spinlock flag, true while held.
flag: std.atomic.Value(bool) = .init(false),
/// Registered caches, in no particular order.
items: std.ArrayList(CacheEntry) = .empty,
/// Free entries up to this generation once no connection holds a cache.
pending: ?u64 = null,

const Self = @This();

// --------------------------------------------------------- //
// Public:

/// Take the spinlock, spinning until it is free.
pub fn lock(self: *Self) void {
    while (self.flag.cmpxchgWeak(false, true, .acq_rel, .acquire) != null) {
        std.atomic.spinLoopHint();
    }
}

/// Release the spinlock.
pub fn unlock(self: *Self) void {
    self.flag.store(false, .release);
}

/// Free every entry built in `upto` or before.
///
/// Note:
/// - The caller holds the lock.
/// - The list memory is released once the registry is empty.
///
/// Param:
/// upto - u64 (the newest generation to free)
///
/// Return:
/// - usize (how many entries were freed)
pub fn freeUpTo(self: *Self, upto: u64) usize {
    var freed: usize = 0;
    var index: usize = 0;
    while (index < self.items.items.len) {
        const entry = self.items.items[index];
        if (entry.generation > upto) {
            index += 1;
            continue;
        }

        entry.resp_cache.deinit();
        std.heap.smp_allocator.destroy(entry.resp_cache);
        _ = self.items.swapRemove(index);
        freed += 1;
    }

    if (self.items.items.len == 0) self.items.clearAndFree(std.heap.smp_allocator);

    return freed;
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const Config = @import("../../tcp/http1/Config.zig");

fn testConfig() Config {
    return .{
        .io = std.testing.io,
        .ip = "127.0.0.1",
        .port = 0,
        .dispatch_model = .ASYNC,
        .cache_max_entries = 4,
        .cache_max_value_bytes = 512,
    };
}

/// Build one cache with smp_allocator and register it for `generation`.
fn register(registry: *Self, generation: u64) !*ResponseCache {
    const allocator = std.heap.smp_allocator;
    const resp_cache = try allocator.create(ResponseCache);
    errdefer allocator.destroy(resp_cache);

    resp_cache.* = try ResponseCache.init(allocator, testConfig());
    errdefer resp_cache.deinit();

    try registry.items.append(allocator, .{
        .resp_cache = resp_cache,
        .generation = generation,
    });

    return resp_cache;
}

test "zix utils cache: CacheRegistry, starts empty and unlocked" {
    const registry: Self = .{};

    try std.testing.expect(!registry.flag.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), registry.items.items.len);
    try std.testing.expect(registry.pending == null);
}

test "zix utils cache: CacheRegistry, lock sets the flag" {
    var registry: Self = .{};

    registry.lock();

    try std.testing.expect(registry.flag.load(.acquire));
}

test "zix utils cache: CacheRegistry, unlock clears the flag" {
    var registry: Self = .{};

    registry.lock();
    registry.unlock();

    try std.testing.expect(!registry.flag.load(.acquire));
}

test "zix utils cache: CacheRegistry, lock is taken again after unlock" {
    var registry: Self = .{};

    registry.lock();
    registry.unlock();
    registry.lock();
    defer registry.unlock();

    try std.testing.expect(registry.flag.load(.acquire));
}

test "zix utils cache: CacheRegistry, lock excludes another thread" {
    const Worker = struct {
        fn run(registry: *Self, counter: *usize) void {
            for (0..1000) |_| {
                registry.lock();
                defer registry.unlock();

                counter.* += 1;
            }
        }
    };

    var registry: Self = .{};
    var counter: usize = 0;

    var threads: [4]std.Thread = undefined;
    for (&threads) |*thread| thread.* = try std.Thread.spawn(.{}, Worker.run, .{
        &registry,
        &counter,
    });
    for (threads) |thread| thread.join();

    try std.testing.expectEqual(@as(usize, 4000), counter);
}

test "zix utils cache: CacheRegistry, freeUpTo on empty frees nothing" {
    var registry: Self = .{};

    try std.testing.expectEqual(@as(usize, 0), registry.freeUpTo(std.math.maxInt(u64)));
    try std.testing.expectEqual(@as(usize, 0), registry.items.capacity);
}

test "zix utils cache: CacheRegistry, freeUpTo frees the older generations" {
    var registry: Self = .{};
    defer _ = registry.freeUpTo(std.math.maxInt(u64));

    _ = try register(&registry, 0);
    _ = try register(&registry, 1);
    _ = try register(&registry, 2);

    try std.testing.expectEqual(@as(usize, 2), registry.freeUpTo(1));
}

test "zix utils cache: CacheRegistry, freeUpTo keeps a newer generation" {
    var registry: Self = .{};
    defer _ = registry.freeUpTo(std.math.maxInt(u64));

    _ = try register(&registry, 0);
    const newer = try register(&registry, 5);

    _ = registry.freeUpTo(4);

    try std.testing.expectEqual(@as(usize, 1), registry.items.items.len);
    try std.testing.expectEqual(newer, registry.items.items[0].resp_cache);
    try std.testing.expectEqual(@as(u64, 5), registry.items.items[0].generation);
}

test "zix utils cache: CacheRegistry, freeUpTo includes the exact generation" {
    var registry: Self = .{};

    _ = try register(&registry, 7);

    try std.testing.expectEqual(@as(usize, 1), registry.freeUpTo(7));
}

test "zix utils cache: CacheRegistry, freeUpTo below every generation frees nothing" {
    var registry: Self = .{};
    defer _ = registry.freeUpTo(std.math.maxInt(u64));

    _ = try register(&registry, 3);
    _ = try register(&registry, 4);

    try std.testing.expectEqual(@as(usize, 0), registry.freeUpTo(2));
    try std.testing.expectEqual(@as(usize, 2), registry.items.items.len);
}

test "zix utils cache: CacheRegistry, freeUpTo releases the list when empty" {
    var registry: Self = .{};

    _ = try register(&registry, 0);
    _ = try register(&registry, 0);
    _ = registry.freeUpTo(0);

    try std.testing.expectEqual(@as(usize, 0), registry.items.capacity);
}

test "zix utils cache: CacheRegistry, freeUpTo keeps the list while not empty" {
    var registry: Self = .{};
    defer _ = registry.freeUpTo(std.math.maxInt(u64));

    _ = try register(&registry, 0);
    _ = try register(&registry, 1);
    _ = registry.freeUpTo(0);

    try std.testing.expect(registry.items.capacity > 0);
}

