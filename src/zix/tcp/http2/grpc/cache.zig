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
const ResponseCache = @import("../../../utils/cache/ResponseCache.zig");

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

