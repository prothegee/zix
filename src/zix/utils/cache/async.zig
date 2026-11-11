//! ZIX utils cache async
//!
//! ### file: src/zix/utils/cache/async.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! One ResponseCache per io pool thread for the .ASYNC dispatch model.
//!
//! ### note:
//!
//! .ASYNC has no worker. Each connection runs on whichever pool thread is
//! free, so the cache is threadlocal: built on the first connection a thread
//! serves and reused by every later one. Every cache is on the heap and in a
//! registry, so reclaim() can free them after a pool thread exits.
//! A connection holds its cache from acquire() to release(). reclaim() never
//! frees a cache while a connection holds one: it waits for the last
//! release(). Each reclaim() starts a new generation, so a thread that serves
//! again builds a new cache instead of reusing a freed one.
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
const CacheRegistry = @import("CacheRegistry.zig");
const CacheSize = @import("CacheSize.zig");
const ResponseCache = @import("ResponseCache.zig");

// --------------------------------------------------------- //
// Private:

var registry: CacheRegistry = .{};

/// Connections holding a cache between acquire() and release().
var active: std.atomic.Value(usize) = .init(0);

/// Current generation. reclaim() moves it forward.
var generation: std.atomic.Value(u64) = .init(0);

/// This pool thread's cache, heap allocated and owned by the registry.
threadlocal var tl_cache: ?*ResponseCache = null;

/// Set after the first build attempt in a generation, so a failed build is
/// not retried on every connection.
threadlocal var tl_tried: bool = false;

/// Generation the two slots above belong to.
threadlocal var tl_generation: u64 = 0;

/// Build this thread's cache for `current` and register it.
fn build(size: CacheSize, current: u64) ?*ResponseCache {
    const allocator = std.heap.smp_allocator;
    const resp_cache = allocator.create(ResponseCache) catch |err| switch (err) {
        error.OutOfMemory => return null,
    };

    resp_cache.* = ResponseCache.init(allocator, size) catch |err| switch (err) {
        error.ZixUtils_ResponseCache_OutOfMemory,
        error.ZixUtils_ResponseCache_MapFailed,
        => {
            allocator.destroy(resp_cache);

            return null;
        },
    };

    registry.lock();
    defer registry.unlock();

    const entry: CacheEntry = .{
        .resp_cache = resp_cache,
        .generation = current,
    };
    registry.items.append(allocator, entry) catch |err| switch (err) {
        error.OutOfMemory => {
            resp_cache.deinit();
            allocator.destroy(resp_cache);

            return null;
        },
    };

    return resp_cache;
}

// --------------------------------------------------------- //
// Public:

/// Hold this pool thread's cache for one connection, building it on first
/// use in the current generation. Pair every call with release(), also when
/// it returns null.
///
/// Note:
/// - Runs once per connection, never per request.
/// - The connection is counted before the generation is read. reclaim()
///   moves the generation before it reads the count. So either reclaim()
///   sees this connection and waits for it, or this call sees the new
///   generation and builds a new cache. A freed cache is never returned.
/// - A build failure is remembered for the generation, so a thread that
///   cannot map its slab serves uncached instead of retrying.
///
/// Param:
/// size - CacheSize (slot count and per-slot byte cap of this thread's cache)
///
/// Return:
/// - *ResponseCache (this thread's cache)
/// - null when the cache could not be built, meaning serve uncached
pub fn acquire(size: CacheSize) ?*ResponseCache {
    _ = active.fetchAdd(1, .seq_cst);

    const current = generation.load(.seq_cst);
    if (tl_generation != current) {
        tl_cache = null;
        tl_tried = false;
        tl_generation = current;
    }

    if (tl_cache) |resp_cache| return resp_cache;
    if (tl_tried) return null;

    tl_tried = true;
    tl_cache = build(size, current);

    return tl_cache;
}

/// End one connection's hold. The last release after a reclaim() frees the
/// caches that reclaim() could not free yet.
///
/// Return:
/// - void
pub fn release() void {
    if (active.fetchSub(1, .seq_cst) != 1) return;

    registry.lock();
    defer registry.unlock();

    const upto = registry.pending orelse return;
    if (active.load(.seq_cst) != 0) return;

    _ = registry.freeUpTo(upto);
    registry.pending = null;
}

/// Free every cache built so far, now or once the last connection ends.
/// Call when the accept loop ends.
///
/// Note:
/// - Starts a new generation, so a thread that serves again builds a new
///   cache.
/// - Safe from a thread that never built a cache, and safe to call twice.
///
/// Return:
/// - usize (how many caches were freed now, 0 when the free waits for the
///   last release)
pub fn reclaim() usize {
    registry.lock();
    defer registry.unlock();

    const ended = generation.fetchAdd(1, .seq_cst);

    if (active.load(.seq_cst) != 0) {
        registry.pending = ended;

        return 0;
    }

    registry.pending = null;

    return registry.freeUpTo(ended);
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

fn testSize(entries: u32, value_bytes: u32) CacheSize {
    return .{
        .max_entries = entries,
        .max_value_bytes = value_bytes,
    };
}

/// Registered caches, read under the lock.
fn registeredCount() usize {
    registry.lock();
    defer registry.unlock();

    return registry.items.items.len;
}

const Probe = struct {
    fn touch(seen: *std.atomic.Value(usize)) void {
        defer release();

        if (acquire(testSize(4, 512)) != null) _ = seen.fetchAdd(1, .acq_rel);
    }
};

/// Acquires on a fresh thread, so it builds in the current generation.
const NewerProbe = struct {
    fn run(out: *?*ResponseCache) void {
        out.* = acquire(testSize(8, 1024));
        release();
    }
};

test "zix utils cache: async, acquire reuses one cache per thread" {
    const first = acquire(testSize(8, 1024)).?;
    release();

    const second = acquire(testSize(8, 1024)).?;
    release();

    try std.testing.expectEqual(first, second);
    try std.testing.expectEqual(@as(usize, 1), reclaim());
}

test "zix utils cache: async, acquired cache stores and hits" {
    const resp_cache = acquire(testSize(8, 1024)).?;
    defer _ = reclaim();
    defer release();

    try std.testing.expect(resp_cache.store(7, "hello", 1000, 10));
    try std.testing.expectEqualStrings("hello", resp_cache.lookup(7, 20).?);
}

test "zix utils cache: async, failed build is not retried in a generation" {
    _ = reclaim();
    defer _ = reclaim();

    tl_cache = null;
    tl_tried = true;
    tl_generation = generation.load(.seq_cst);

    try std.testing.expect(acquire(testSize(8, 1024)) == null);
    release();

    try std.testing.expectEqual(@as(usize, 0), registeredCount());
    try std.testing.expectEqual(@as(usize, 0), active.load(.seq_cst));
}

test "zix utils cache: async, reclaim frees now without an active connection" {
    _ = acquire(testSize(8, 1024)).?;
    release();

    try std.testing.expectEqual(@as(usize, 1), reclaim());
    try std.testing.expectEqual(@as(usize, 0), registeredCount());
}

test "zix utils cache: async, reclaim twice frees nothing the second time" {
    _ = acquire(testSize(8, 1024)).?;
    release();

    try std.testing.expectEqual(@as(usize, 1), reclaim());
    try std.testing.expectEqual(@as(usize, 0), reclaim());
}

test "zix utils cache: async, reclaim waits for an active connection" {
    const resp_cache = acquire(testSize(8, 1024)).?;

    try std.testing.expectEqual(@as(usize, 0), reclaim());
    try std.testing.expectEqual(@as(usize, 1), registeredCount());

    // Still mapped: the held cache keeps working after reclaim().
    try std.testing.expect(resp_cache.store(7, "hello", 1000, 10));
    try std.testing.expectEqualStrings("hello", resp_cache.lookup(7, 20).?);

    release();

    try std.testing.expectEqual(@as(usize, 0), registeredCount());
}

test "zix utils cache: async, last release frees only after every hold ends" {
    _ = acquire(testSize(8, 1024)).?;
    _ = acquire(testSize(8, 1024)).?;

    try std.testing.expectEqual(@as(usize, 0), reclaim());

    release();
    try std.testing.expectEqual(@as(usize, 1), registeredCount());

    release();
    try std.testing.expectEqual(@as(usize, 0), registeredCount());
}

test "zix utils cache: async, acquire after reclaim builds a new generation" {
    _ = acquire(testSize(8, 1024)).?;
    release();
    _ = reclaim();

    const before = generation.load(.seq_cst);

    _ = acquire(testSize(8, 1024)).?;
    defer _ = reclaim();
    defer release();

    try std.testing.expectEqual(before, tl_generation);
    try std.testing.expectEqual(@as(usize, 1), registeredCount());
}

test "zix utils cache: async, failed build is retried in a new generation" {
    _ = reclaim();
    tl_cache = null;
    tl_tried = true;
    tl_generation = generation.load(.seq_cst);

    try std.testing.expect(acquire(testSize(8, 1024)) == null);
    release();
    _ = reclaim();

    try std.testing.expect(acquire(testSize(8, 1024)) != null);
    release();
    try std.testing.expectEqual(@as(usize, 1), reclaim());
}

test "zix utils cache: async, reclaim keeps a newer generation" {
    const held = acquire(testSize(8, 1024)).?;

    try std.testing.expectEqual(@as(usize, 0), reclaim());

    var built_after: ?*ResponseCache = null;

    const thread = try std.Thread.spawn(.{}, NewerProbe.run, .{&built_after});
    thread.join();

    try std.testing.expect(built_after != null);
    try std.testing.expect(built_after.? != held);

    // The last hold ends: only the old generation is freed.
    release();
    try std.testing.expectEqual(@as(usize, 1), registeredCount());
    try std.testing.expectEqual(@as(usize, 1), reclaim());
}

test "zix utils cache: async, builds one cache per thread not per call" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();

    const io = threaded.io();
    var seen: std.atomic.Value(usize) = .init(0);

    var futures: [64]std.Io.Future(void) = undefined;
    for (&futures) |*future| future.* = io.async(Probe.touch, .{&seen});
    for (&futures) |*future| future.await(io);

    try std.testing.expectEqual(@as(usize, 64), seen.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), active.load(.seq_cst));

    const built = reclaim();

    try std.testing.expect(built >= 1);
    try std.testing.expect(built < 64);
}

