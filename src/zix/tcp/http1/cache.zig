//! ZIX Http1 cache
//!
//! ### file: src/zix/tcp/http1/cache.zig
//! 
//! ### author: Prana Ron
//! 
//! ---------------------------------------------------------
//! 
//! ### brief:
//! 
//! Per-worker response cache: request key and glue to utils/cache/ResponseCache.
//! 
//! ### note:
//! 
//! n/a
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
const Config = @import("Config.zig");
const ResponseCache = @import("../../utils/cache/ResponseCache.zig");
const ParsedHead = @import("ParsedHead.zig");

// --------------------------------------------------------- //
// Private:

/// Coarse monotonic milliseconds for TTL, read from this worker's clock.
fn nowMillis(io: std.Io) u64 {
    return @intCast(std.Io.Clock.Timestamp.now(io, .awake).raw.toMilliseconds());
}

/// Hash the cache key parts into a non-zero u64 (0 is the empty sentinel). The
/// query is part of the key, so two requests on the same path with different
/// query strings hash to distinct entries.
fn hashKey(method: []const u8, path: []const u8, query: []const u8) u64 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(method);
    hasher.update(path);
    hasher.update(query);

    const digest = hasher.final();

    return if (digest == 0) 1 else digest;
}

/// Whether a response to this request may be stored under its request key.
///
/// Note:
/// - The key is hash(method, path, query) and carries no request content. Two
///   QUERY requests to one path with different bodies would therefore share a
///   key, and one query's answer could be served for another.
/// - Refusing to store is the conformant answer for a key this shape. Nothing
///   is ever written under a QUERY key, so the lookup path keeps its cost.
fn storableUnderRequestKey(head: *const ParsedHead) bool {
    return !std.mem.eql(u8, head.method, "QUERY");
}

// --------------------------------------------------------- //
// Public:

/// The calling thread's response cache when config.response_cache is on, null
/// otherwise. When null every cache call below degrades to a no-op, so a
/// handler that uses the cache API still works on a server with caching
/// disabled.
pub threadlocal var tl_cache: ?*ResponseCache = null;

/// Configured default TTL in milliseconds, installed alongside tl_cache.
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

/// Build a worker's response cache into slot and install it for the calling
/// thread. Used by the .EPOLL and .URING workers, which own one cache each.
///
/// Note:
/// - Runs once per worker at start, never per request.
/// - slot must outlive the worker loop, since the installed pointer points
///   into it. Pair every call with uninstallWorker.
/// - Best effort: a cache that cannot be built leaves the worker uncached.
///
/// Param:
/// slot - *?ResponseCache (worker-owned storage, filled when the cache is on)
/// allocator - std.mem.Allocator (backs the cache arena)
/// config - Config (response_cache, cache_ttl_ms, and the cache size knobs)
///
/// Return:
/// - void
pub fn installWorker(
    slot: *?ResponseCache,
    allocator: std.mem.Allocator,
    config: Config,
) void {
    slot.* = null;

    if (config.response_cache) {
        slot.* = ResponseCache.init(allocator, config) catch |err| switch (err) {
            error.ZixUtils_ResponseCache_OutOfMemory,
            error.ZixUtils_ResponseCache_MapFailed,
            => null,
        };
    }

    if (slot.*) |*built| {
        setCache(built, config.cache_ttl_ms);
    } else {
        setCache(null, 0);
    }
}

/// Clear the calling thread's cache and free the one installWorker built.
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

/// Look up a full cached response for this request. Returns the cached bytes
/// when caching is enabled and a fresh entry exists, else null.
///
/// Param:
/// io - std.Io (the worker io used for the TTL clock)
/// head - *const ParsedHead (source of the cache key)
///
/// Return:
/// - ?[]const u8 (the full response bytes, or null)
pub fn cacheLookup(io: std.Io, head: *const ParsedHead) ?[]const u8 {
    const resp_cache = tl_cache orelse return null;
    const key = hashKey(head.method, head.path, head.query);

    return resp_cache.lookup(key, nowMillis(io));
}

/// Store full response bytes as this request's cached response for ttl_ms.
/// No-op when caching is disabled, the request is a QUERY, the bytes exceed
/// the per-slot cap, or the table is full.
///
/// Note:
/// - The bytes must be a complete HTTP response.
///
/// Param:
/// io - std.Io (the worker io used for the TTL clock)
/// head - *const ParsedHead (source of the cache key)
/// bytes - []const u8 (the full response bytes)
/// ttl_ms - u32 (freshness in milliseconds)
pub fn cacheStore(io: std.Io, head: *const ParsedHead, bytes: []const u8, ttl_ms: u32) void {
    const resp_cache = tl_cache orelse return;
    if (!storableUnderRequestKey(head)) return;

    const key = hashKey(head.method, head.path, head.query);

    _ = resp_cache.store(key, bytes, ttl_ms, nowMillis(io));
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

fn testHead(method: []const u8) ParsedHead {
    return .{
        .path = "/",
        .query = "",
        .method = method,
        .keep_alive = true,
        .raw_headers = "",
        .version_minor = 1,
        .content_length = 0,
        .chunked_request = false,
        .expect_continue = false,
    };
}

fn testCacheConfig() Config {
    return .{
        .io = std.testing.io,
        .ip = "127.0.0.1",
        .port = 0,
        .dispatch_model = .ASYNC,
        .cache_max_entries = 8,
        .cache_max_value_bytes = 256,
    };
}

test "zix http1: cache, key excludes QUERY from store" {
    const get = testHead("GET");
    const query = testHead("QUERY");

    try std.testing.expect(storableUnderRequestKey(&get));
    try std.testing.expect(!storableUnderRequestKey(&query));
}

test "zix http1: cache, lookup is a no-op without a cache" {
    setCache(null, 0);
    defer setCache(null, 1000);

    const head = testHead("GET");

    try std.testing.expect(cacheLookup(std.testing.io, &head) == null);
}

test "zix http1: cache, ttl defaults" {
    setCache(null, 2500);
    defer setCache(null, 1000);

    try std.testing.expectEqual(@as(u32, 2500), cacheTtl());
}

test "zix http1: cache, keys separate queries" {
    const first = hashKey("GET", "/x", "a=1");
    const second = hashKey("GET", "/x", "a=2");

    try std.testing.expect(first != 0);
    try std.testing.expect(first != second);
    try std.testing.expectEqual(first, hashKey("GET", "/x", "a=1"));
}

test "zix http1: cache, store then lookup hits with an installed cache" {
    var resp_cache = try ResponseCache.init(std.testing.allocator, testCacheConfig());
    defer resp_cache.deinit();

    setCache(&resp_cache, 1000);
    defer setCache(null, 1000);

    const head = testHead("GET");
    cacheStore(std.testing.io, &head, "HTTP/1.1 200 OK\r\n\r\n", 60_000);

    try std.testing.expectEqualStrings(
        "HTTP/1.1 200 OK\r\n\r\n",
        cacheLookup(std.testing.io, &head).?,
    );
}

test "zix http1: cache, lookup misses an unstored request" {
    var resp_cache = try ResponseCache.init(std.testing.allocator, testCacheConfig());
    defer resp_cache.deinit();

    setCache(&resp_cache, 1000);
    defer setCache(null, 1000);

    const stored = testHead("GET");
    const other = testHead("POST");
    cacheStore(std.testing.io, &stored, "cached", 60_000);

    try std.testing.expect(cacheLookup(std.testing.io, &other) == null);
}

test "zix http1: cache, zero ttl entry is expired" {
    var resp_cache = try ResponseCache.init(std.testing.allocator, testCacheConfig());
    defer resp_cache.deinit();

    setCache(&resp_cache, 1000);
    defer setCache(null, 1000);

    const head = testHead("GET");
    cacheStore(std.testing.io, &head, "cached", 0);

    try std.testing.expect(cacheLookup(std.testing.io, &head) == null);
}

test "zix http1: cache, QUERY request is not stored" {
    var resp_cache = try ResponseCache.init(std.testing.allocator, testCacheConfig());
    defer resp_cache.deinit();

    setCache(&resp_cache, 1000);
    defer setCache(null, 1000);

    const head = testHead("QUERY");
    cacheStore(std.testing.io, &head, "cached", 60_000);

    try std.testing.expect(cacheLookup(std.testing.io, &head) == null);
}

test "zix http1: cache, store is a no-op without a cache" {
    setCache(null, 1000);

    const head = testHead("GET");
    cacheStore(std.testing.io, &head, "cached", 60_000);

    try std.testing.expect(cacheLookup(std.testing.io, &head) == null);
}

test "zix http1: cache, installWorker installs the cache when on" {
    var config = testCacheConfig();
    config.response_cache = true;
    config.cache_ttl_ms = 2500;

    var slot: ?ResponseCache = null;
    installWorker(&slot, std.testing.allocator, config);
    defer uninstallWorker(&slot);

    try std.testing.expect(slot != null);
    try std.testing.expect(tl_cache == &slot.?);
    try std.testing.expectEqual(@as(u32, 2500), cacheTtl());
}

test "zix http1: cache, installWorker leaves the cache off when off" {
    var slot: ?ResponseCache = null;
    installWorker(&slot, std.testing.allocator, testCacheConfig());
    defer uninstallWorker(&slot);

    try std.testing.expect(slot == null);
    try std.testing.expect(tl_cache == null);
}

test "zix http1: cache, installWorker falls back to uncached on a failed build" {
    var config = testCacheConfig();
    config.response_cache = true;

    var slot: ?ResponseCache = null;
    installWorker(&slot, std.testing.failing_allocator, config);
    defer uninstallWorker(&slot);

    try std.testing.expect(slot == null);
    try std.testing.expect(tl_cache == null);
}

test "zix http1: cache, uninstallWorker clears the thread cache" {
    var config = testCacheConfig();
    config.response_cache = true;

    var slot: ?ResponseCache = null;
    installWorker(&slot, std.testing.allocator, config);
    uninstallWorker(&slot);

    try std.testing.expect(slot == null);
    try std.testing.expect(tl_cache == null);
}

