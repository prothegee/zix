//! ZIX Http2 cache
//!
//! ### file: src/zix/tcp/http2/cache.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Per-worker response cache for HTTP/2: request key and the handler cache API.
//!
//! ### note:
//!
//! - The cache stores the unframed body. A hit is framed again for the
//!   stream that asked, so one entry serves any stream id.
//! - The handler does not pass its request, so the dispatcher records the
//!   request path, body, and io in tl_req_* around each handler call. An empty
//!   path or a null io turns every call into a plain send.
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
const ResponseCache = @import("../../utils/cache/ResponseCache.zig");
const Http1Config = @import("../http1/Config.zig");
const ServeOpts = @import("ServeOpts.zig");
const writer = @import("writer.zig");

// --------------------------------------------------------- //
// Private:

/// Coarse monotonic milliseconds for TTL, read from this worker's clock.
fn nowMillis(io: std.Io) u64 {
    return @intCast(std.Io.Clock.Timestamp.now(io, .awake).raw.toMilliseconds());
}

/// Hash a request into a cache key from its path and body. A zero digest is
/// bumped to 1, since 0 marks an empty cache slot.
fn requestKey(path: []const u8, body: []const u8) u64 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(path);
    hasher.update(body);

    const digest = hasher.final();

    return if (digest == 0) 1 else digest;
}

/// Send a 200 response, best effort.
fn sendBody(fd: std.posix.fd_t, sid: u31, content_type: []const u8, body: []const u8) void {
    writer.sendResponseFD(fd, sid, 200, content_type, body) catch |err| switch (err) {
        // Best effort: the peer went away or the head did not fit. The
        // connection loop sees the broken socket on its next read.
        error.ZixHttp2_Writer_BrokenPipe,
        error.ZixHttp2_Writer_UnexpectedEOF,
        error.ZixHttp2_Writer_Overflow,
        error.ZixHttp2_Writer_BufferFull,
        => {},
    };
}

// --------------------------------------------------------- //
// Public:

/// The calling worker's response cache, or null when caching is off.
pub threadlocal var tl_cache: ?*ResponseCache = null;

/// Default freshness in milliseconds, installed alongside tl_cache.
pub threadlocal var tl_cache_ttl_ms: u32 = 1000;

/// Path of the request dispatching on this worker. Empty skips the cache.
pub threadlocal var tl_req_path: []const u8 = "";

/// Body of the request dispatching on this worker, part of the key.
pub threadlocal var tl_req_body: []const u8 = "";

/// Worker io for the TTL clock. Null skips the cache.
pub threadlocal var tl_req_io: ?std.Io = null;

/// Install or clear the response cache and its default TTL for this worker.
pub fn setCache(resp_cache: ?*ResponseCache, default_ttl_ms: u32) void {
    tl_cache = resp_cache;
    tl_cache_ttl_ms = default_ttl_ms;
}

/// The configured default cache TTL for this worker.
pub fn cacheTtl() u32 {
    return tl_cache_ttl_ms;
}

/// Cache slot count that fits the memory ceiling.
///
/// Note:
/// - The cache rounds the count down to a power of two afterwards, so the
///   slab (slots * value bytes) never goes past the ceiling.
///
/// Param:
/// max_entries - u32 (configured slot count)
/// max_value_bytes - u32 (per-slot cap in bytes, 0 counts as 1)
/// max_total_bytes - usize (memory ceiling in bytes, 0 disables it)
///
/// Return:
/// - u32 (max_entries, or fewer when the ceiling is set, never below 1)
pub fn effectiveCacheEntries(
    max_entries: u32,
    max_value_bytes: u32,
    max_total_bytes: usize,
) u32 {
    if (max_total_bytes == 0) return max_entries;

    const value_bytes: usize = @max(1, max_value_bytes);
    const fit = max_total_bytes / value_bytes;
    const capped = @min(@as(usize, max_entries), fit);

    return @intCast(@max(@as(usize, 1), capped));
}

/// Build this worker's response cache into slot and install it, or clear the
/// cache when caching is off or the build failed.
///
/// Note:
/// - ResponseCache is sized from an Http1 Config. Only its cache size fields
///   are read, so the address fields are left empty.
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
        const sizing: Http1Config = .{
            .io = undefined,
            .ip = "",
            .port = 0,
            .dispatch_model = .ASYNC,
            .cache_max_entries = effectiveCacheEntries(
                opts.cache_max_entries,
                opts.cache_max_value_bytes,
                opts.cache_max_total_bytes,
            ),
            .cache_max_value_bytes = opts.cache_max_value_bytes,
        };

        slot.* = ResponseCache.init(allocator, sizing) catch |err| switch (err) {
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

/// Serve the current request from the cache when a fresh entry exists.
///
/// Usage:
/// ```zig
/// fn handler(req: *Http2.Request, res: *Http2.Response, ctx: *Http2.Context) anyerror!void {
///     if (Http2.serveCached(ctx.fd, ctx.sid, "application/json")) return;
///
///     const reply = buildReply();
///     Http2.sendCachedFD(ctx.fd, ctx.sid, "application/json", reply);
/// }
/// ```
///
/// Param:
/// fd - std.posix.fd_t (the connection)
/// sid - u31 (the stream to answer)
/// content_type - []const u8 (Content-Type of the cached body)
///
/// Return:
/// - true when the response was served from cache, the handler should return
/// - false on a miss, the handler builds the response itself
pub fn serveCached(fd: std.posix.fd_t, sid: u31, content_type: []const u8) bool {
    const resp_cache = tl_cache orelse return false;
    const io = tl_req_io orelse return false;
    if (tl_req_path.len == 0) return false;

    const key = requestKey(tl_req_path, tl_req_body);
    const bytes = resp_cache.lookup(key, nowMillis(io)) orelse return false;

    sendBody(fd, sid, content_type, bytes);

    return true;
}

/// Send a 200 body and store it under the current request key.
///
/// Note:
/// - The body is sent even when nothing is stored: no cache, no io, an empty
///   path, or a body past the per-slot cap.
///
/// Param:
/// fd - std.posix.fd_t (the connection)
/// sid - u31 (the stream to answer)
/// content_type - []const u8 (Content-Type of the body)
/// data - []const u8 (the unframed response body)
///
/// Return:
/// - void
pub fn sendCachedFD(
    fd: std.posix.fd_t,
    sid: u31,
    content_type: []const u8,
    data: []const u8,
) void {
    sendBody(fd, sid, content_type, data);

    const resp_cache = tl_cache orelse return;
    const io = tl_req_io orelse return;
    if (tl_req_path.len == 0) return;

    const key = requestKey(tl_req_path, tl_req_body);

    _ = resp_cache.store(key, data, tl_cache_ttl_ms, nowMillis(io));
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const builtin = @import("builtin");
const pair = @import("../../utils/socket/pair.zig");

const TEST_FD: std.posix.fd_t = if (builtin.os.tag == .windows)
    std.os.windows.INVALID_HANDLE_VALUE
else
    -1;

fn testCacheConfig() Http1Config {
    return .{
        .io = std.testing.io,
        .ip = "127.0.0.1",
        .port = 0,
        .dispatch_model = .ASYNC,
        .cache_max_entries = 16,
        .cache_max_value_bytes = 1024,
    };
}

fn setTestRequest(path: []const u8) void {
    tl_req_path = path;
    tl_req_body = "";
    tl_req_io = std.testing.io;
}

fn clearTestRequest() void {
    tl_req_path = "";
    tl_req_body = "";
    tl_req_io = null;
}

test "zix http2: cache, ttl defaults" {
    setCache(null, 2500);
    defer setCache(null, 1000);

    try std.testing.expectEqual(@as(u32, 2500), cacheTtl());
}

test "zix http2: cache, effectiveCacheEntries without a ceiling keeps the count" {
    try std.testing.expectEqual(@as(u32, 1024), effectiveCacheEntries(1024, 16 * 1024, 0));
}

test "zix http2: cache, effectiveCacheEntries caps the count to the ceiling" {
    const entries = effectiveCacheEntries(1024, 16 * 1024, 256 * 1024);

    try std.testing.expectEqual(@as(u32, 16), entries);
}

test "zix http2: cache, effectiveCacheEntries keeps the count under a loose ceiling" {
    const entries = effectiveCacheEntries(8, 1024, 1024 * 1024);

    try std.testing.expectEqual(@as(u32, 8), entries);
}

test "zix http2: cache, effectiveCacheEntries tiny ceiling falls back to 1" {
    try std.testing.expectEqual(@as(u32, 1), effectiveCacheEntries(1024, 16 * 1024, 1));
}

test "zix http2: cache, effectiveCacheEntries zero value bytes counts as 1" {
    try std.testing.expectEqual(@as(u32, 64), effectiveCacheEntries(1024, 0, 64));
}

test "zix http2: cache, key is never zero" {
    try std.testing.expect(requestKey("", "") != 0);
    try std.testing.expect(requestKey("/a", "") != 0);
}

test "zix http2: cache, key separates bodies on one path" {
    const first = requestKey("/rpc", "a=1");
    const second = requestKey("/rpc", "a=2");

    try std.testing.expect(first != second);
    try std.testing.expectEqual(first, requestKey("/rpc", "a=1"));
}

test "zix http2: cache, serveCached misses without a cache" {
    setCache(null, 0);
    defer setCache(null, 1000);

    setTestRequest("/cached");
    defer clearTestRequest();

    try std.testing.expect(!serveCached(TEST_FD, 1, "text/plain"));
}

test "zix http2: cache, sendCachedFD then serveCached hits" {
    var resp_cache = try ResponseCache.init(std.testing.allocator, testCacheConfig());
    defer resp_cache.deinit();

    setCache(&resp_cache, 1000);
    defer setCache(null, 1000);

    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    setTestRequest("/cached");
    defer clearTestRequest();

    try std.testing.expect(!serveCached(fds[1], 1, "text/plain"));

    sendCachedFD(fds[1], 1, "text/plain", "hello-cached");

    try std.testing.expect(serveCached(fds[1], 3, "text/plain"));
}

test "zix http2: cache, another path misses" {
    var resp_cache = try ResponseCache.init(std.testing.allocator, testCacheConfig());
    defer resp_cache.deinit();

    setCache(&resp_cache, 1000);
    defer setCache(null, 1000);

    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    setTestRequest("/cached");
    defer clearTestRequest();

    sendCachedFD(fds[1], 1, "text/plain", "hello-cached");
    tl_req_path = "/other";

    try std.testing.expect(!serveCached(fds[1], 5, "text/plain"));
}

test "zix http2: cache, empty path stores nothing" {
    var resp_cache = try ResponseCache.init(std.testing.allocator, testCacheConfig());
    defer resp_cache.deinit();

    setCache(&resp_cache, 1000);
    defer setCache(null, 1000);

    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    setTestRequest("");
    defer clearTestRequest();

    sendCachedFD(fds[1], 1, "text/plain", "x");

    try std.testing.expect(!serveCached(fds[1], 3, "text/plain"));
}

test "zix http2: cache, without an io misses" {
    var resp_cache = try ResponseCache.init(std.testing.allocator, testCacheConfig());
    defer resp_cache.deinit();

    setCache(&resp_cache, 1000);
    defer setCache(null, 1000);

    setTestRequest("/cached");
    defer clearTestRequest();

    tl_req_io = null;

    try std.testing.expect(!serveCached(TEST_FD, 1, "text/plain"));
}

test "zix http2: cache, installWorker off clears the cache" {
    var slot: ?ResponseCache = null;
    installWorker(&slot, std.testing.allocator, .{});
    defer uninstallWorker(&slot);

    try std.testing.expect(slot == null);
    try std.testing.expect(tl_cache == null);
}

test "zix http2: cache, installWorker on installs the slot" {
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

test "zix http2: cache, uninstallWorker clears the slot" {
    var slot: ?ResponseCache = null;
    installWorker(&slot, std.testing.allocator, .{
        .response_cache = true,
        .cache_max_entries = 16,
    });

    uninstallWorker(&slot);

    try std.testing.expect(slot == null);
    try std.testing.expect(tl_cache == null);
}

