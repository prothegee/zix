//! ZIX Http2 Grpc cache
//!
//! ### file: src/zix/tcp/http2/grpc/cache.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Per-worker unary response cache: the installed cache, its default TTL,
//! and the call key.
//!
//! ### note:
//!
//! The cache holds the logical reply message, not wire bytes, so framing and
//! gzip are applied again on every hit.
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
const h2_cache = @import("../cache.zig");
const CacheSize = @import("../../../utils/cache/CacheSize.zig");
const ResponseCache = @import("../../../utils/cache/ResponseCache.zig");
const ServeOpts = @import("ServeOpts.zig");

// --------------------------------------------------------- //
// Public:

/// The calling worker's response cache, or null when caching is off.
pub threadlocal var tl_cache: ?*ResponseCache = null;

/// Default freshness in milliseconds, installed alongside tl_cache.
pub threadlocal var tl_cache_ttl_ms: u32 = 1000;

/// Install or clear the response cache and its default TTL for this worker.
pub fn setCache(resp_cache: ?*ResponseCache, default_ttl_ms: u32) void {
    tl_cache = resp_cache;
    tl_cache_ttl_ms = default_ttl_ms;
}

/// The configured default cache TTL for this worker.
pub fn cacheTtl() u32 {
    return tl_cache_ttl_ms;
}

/// Coarse monotonic milliseconds for TTL, read from this worker's clock.
pub fn nowMillis(io: std.Io) u64 {
    return @intCast(std.Io.Clock.Timestamp.now(io, .awake).raw.toMilliseconds());
}

/// Cache key for a unary call.
///
/// Param:
/// path - []const u8 (the gRPC path)
/// body - []const u8 (the raw request body)
///
/// Return:
/// - u64 (never 0, since 0 marks an empty cache slot)
pub fn requestKey(path: []const u8, body: []const u8) u64 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(path);
    hasher.update(body);

    const digest = hasher.final();

    return if (digest == 0) 1 else digest;
}

/// Build this worker's response cache into slot and install it, or clear the
/// cache when caching is off or the build failed.
///
/// Note:
/// - slot must outlive the worker loop, since the installed pointer points
///   into it.
///
/// Param:
/// slot - *?ResponseCache (worker-owned storage, set to null when off)
/// allocator - std.mem.Allocator (backs the cache slab)
/// opts - ServeOpts (cache knobs)
///
/// Return:
/// - void
pub fn installWorker(
    slot: *?ResponseCache,
    allocator: std.mem.Allocator,
    opts: ServeOpts,
) void {
    slot.* = null;

    if (opts.response_cache) {
        const size: CacheSize = .{
            .max_entries = h2_cache.effectiveCacheEntries(
                opts.cache_max_entries,
                opts.cache_max_value_bytes,
                opts.cache_max_total_bytes,
            ),
            .max_value_bytes = opts.cache_max_value_bytes,
        };

        slot.* = ResponseCache.init(allocator, size) catch |err| switch (err) {
            error.ZixUtils_ResponseCache_OutOfMemory,
            error.ZixUtils_ResponseCache_MapFailed,
            => null,
        };
    }

    if (slot.*) |*built| {
        setCache(built, opts.cache_ttl_ms);
    } else {
        setCache(null, 0);
    }
}

/// Clear this worker's cache and free the one installWorker built.
///
/// Param:
/// slot - *?ResponseCache (the slot passed to installWorker)
///
/// Return:
/// - void
pub fn uninstallWorker(slot: *?ResponseCache) void {
    setCache(null, 0);

    if (slot.*) |*built| built.deinit();

    slot.* = null;
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "zix http2 grpc: cache, starts without a cache" {
    try std.testing.expect(tl_cache == null);
}

test "zix http2 grpc: cache, setCache keeps the ttl" {
    setCache(null, 2500);
    defer setCache(null, 1000);

    try std.testing.expectEqual(@as(u32, 2500), cacheTtl());
}

test "zix http2 grpc: cache, key is never zero" {
    try std.testing.expect(requestKey("", "") != 0);
    try std.testing.expect(requestKey("/svc.Svc/A", "") != 0);
}

test "zix http2 grpc: cache, key separates distinct paths" {
    const key_a = requestKey("/svc.Svc/A", "body");
    const key_b = requestKey("/svc.Svc/B", "body");

    try std.testing.expect(key_a != key_b);
}

test "zix http2 grpc: cache, key separates distinct bodies" {
    const key_body = requestKey("/svc.Svc/A", "body");
    const key_other = requestKey("/svc.Svc/A", "other");

    try std.testing.expect(key_body != key_other);
}

test "zix http2 grpc: cache, key is stable" {
    try std.testing.expectEqual(requestKey("/svc.Svc/A", "x"), requestKey("/svc.Svc/A", "x"));
}

test "zix http2 grpc: cache, nowMillis does not go back" {
    const first = nowMillis(std.testing.io);
    const second = nowMillis(std.testing.io);

    try std.testing.expect(second >= first);
}

test "zix http2 grpc: cache, installWorker off clears the cache" {
    var slot: ?ResponseCache = null;
    installWorker(&slot, std.testing.allocator, .{});
    defer uninstallWorker(&slot);

    try std.testing.expect(slot == null);
    try std.testing.expect(tl_cache == null);
}

test "zix http2 grpc: cache, installWorker on installs the slot" {
    var slot: ?ResponseCache = null;
    installWorker(&slot, std.testing.allocator, .{
        .response_cache = true,
        .cache_max_entries = 16,
        .cache_ttl_ms = 2500,
    });
    defer uninstallWorker(&slot);

    try std.testing.expect(slot != null);
    try std.testing.expect(tl_cache == &slot.?);
    try std.testing.expectEqual(@as(u32, 2500), cacheTtl());
}

test "zix http2 grpc: cache, installWorker honors the memory ceiling" {
    var slot: ?ResponseCache = null;
    installWorker(&slot, std.testing.allocator, .{
        .response_cache = true,
        .cache_max_entries = 1024,
        .cache_max_value_bytes = 1024,
        .cache_max_total_bytes = 4 * 1024,
    });
    defer uninstallWorker(&slot);

    try std.testing.expect(slot.?.keys.len <= 4);
}

test "zix http2 grpc: cache, uninstallWorker clears the slot" {
    var slot: ?ResponseCache = null;
    installWorker(&slot, std.testing.allocator, .{
        .response_cache = true,
        .cache_max_entries = 16,
    });

    uninstallWorker(&slot);

    try std.testing.expect(slot == null);
    try std.testing.expect(tl_cache == null);
}

