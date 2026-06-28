//! zix response cache: per-worker, per-key precomputed response slab.
//!
//! A handler builds a full response once, stores it under a key derived from
//! the request, and on later matching requests the engine writes the cached
//! bytes directly with no re-serialization. The structure is data oriented
//! (structure of arrays plus one flat payload slab) and lock-free by ownership:
//! one instance per worker, never shared. Shared by the Http1, Http and gRPC
//! engines. See ADR-036.

const std = @import("std");

/// Per-slot bookkeeping, kept separate from the payload bytes so the hot
/// metadata stays dense and the cold payload lives in the slab.
pub const Meta = struct {
    insert_tick_ms: u64,
    len: u32,
    ttl_ms: u32,
};

/// Geometry for one cache instance.
///
/// Note:
/// - max_entries is rounded down to a power of two in init, so the slot index
///   is a mask rather than a modulo. A value of 0 yields a single slot.
pub const Config = struct {
    max_entries: u32,
    max_value_bytes: u32,
};

/// Per-worker response cache. Not thread-safe by design: one instance per
/// worker, never shared, so no lock is needed.
pub const ResponseCache = struct {
    keys: []u64,
    meta: []Meta,
    slab: []u8,
    value_bytes: usize,
    mask: usize,
    arena: std.heap.ArenaAllocator,

    /// Allocate the whole cache from one arena.
    ///
    /// Note:
    /// - max_entries is rounded down to a power of two, so the configured entry
    ///   count is an upper bound and the slab never exceeds it.
    ///
    /// Param:
    /// backing - std.mem.Allocator (owns the arena's backing memory)
    /// config - Config (slot count and per-slot byte cap)
    ///
    /// Return:
    /// - !ResponseCache
    pub fn init(backing: std.mem.Allocator, config: Config) !ResponseCache {
        const entries: usize = std.math.floorPowerOfTwo(u32, @max(1, config.max_entries));
        const value_bytes: usize = @max(1, config.max_value_bytes);

        var arena = std.heap.ArenaAllocator.init(backing);
        errdefer arena.deinit();
        const allocator = arena.allocator();

        const keys = try allocator.alloc(u64, entries);
        @memset(keys, 0);

        const meta = try allocator.alloc(Meta, entries);
        const slab = try allocator.alloc(u8, entries * value_bytes);

        return .{
            .keys = keys,
            .meta = meta,
            .slab = slab,
            .value_bytes = value_bytes,
            .mask = entries - 1,
            .arena = arena,
        };
    }

    /// Free the slab, keys, and meta in one shot.
    pub fn deinit(self: *ResponseCache) void {
        self.arena.deinit();
    }

    /// Return the cached bytes for key when present and still fresh.
    /// A miss or an expired entry returns null. now_ms is supplied by the caller
    /// so lookup itself does no clock read on the hot path.
    ///
    /// Note:
    /// - An entry expires exactly at insert_tick_ms + ttl_ms, so a ttl_ms of 0
    ///   is always treated as expired (a per-store way to skip the cache).
    ///
    /// Return:
    /// - ?[]const u8
    pub fn lookup(self: *ResponseCache, key: u64, now_ms: u64) ?[]const u8 {
        var index: usize = @intCast(key & self.mask);
        var probes: usize = 0;
        while (probes <= self.mask) : (probes += 1) {
            const slot_key = self.keys[index];
            if (slot_key == 0) return null;

            if (slot_key == key) {
                const entry = self.meta[index];
                if (now_ms >= entry.insert_tick_ms + entry.ttl_ms) return null;

                const base = index * self.value_bytes;
                return self.slab[base .. base + entry.len];
            }

            index = (index + 1) & self.mask;
        }

        return null;
    }

    /// Copy bytes into the slot for key, evicting an expired neighbour if the
    /// probe reaches one. Expired slots are reused in place rather than zeroed,
    /// since zeroing would truncate an open-addressing probe chain.
    ///
    /// Return:
    /// - bool (true when stored, false when bytes exceed the per-slot cap or the
    ///   table is full of live distinct keys)
    pub fn store(self: *ResponseCache, key: u64, bytes: []const u8, ttl_ms: u32, now_ms: u64) bool {
        if (bytes.len > self.value_bytes) return false;

        var index: usize = @intCast(key & self.mask);
        var probes: usize = 0;
        while (probes <= self.mask) : (probes += 1) {
            const slot_key = self.keys[index];
            const expired = slot_key != 0 and now_ms >= self.meta[index].insert_tick_ms + self.meta[index].ttl_ms;

            if (slot_key == 0 or slot_key == key or expired) {
                const base = index * self.value_bytes;
                @memcpy(self.slab[base .. base + bytes.len], bytes);

                self.keys[index] = key;
                self.meta[index] = .{
                    .insert_tick_ms = now_ms,
                    .len = @intCast(bytes.len),
                    .ttl_ms = ttl_ms,
                };

                return true;
            }

            index = (index + 1) & self.mask;
        }

        return false;
    }
};

/// Hash the cache key parts into a non-zero u64 (0 is the empty sentinel). The
/// query is part of the key, so two requests on the same path with different
/// query strings hash to distinct entries.
pub fn hashKey(method: []const u8, path: []const u8, query: []const u8) u64 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(method);
    hasher.update(path);
    hasher.update(query);

    const digest = hasher.final();
    return if (digest == 0) 1 else digest;
}

/// Like hashKey, but folds the content-encoding token into the key so the compressed and identity
/// representations of one resource occupy distinct cache slots (the per-(key, encoding) cache). A
/// NUL separator keeps the encoding from colliding across the path / query boundary.
pub fn hashKeyEncoded(method: []const u8, path: []const u8, query: []const u8, encoding: []const u8) u64 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(method);
    hasher.update(path);
    hasher.update(query);
    hasher.update("\x00");
    hasher.update(encoding);

    const digest = hasher.final();
    return if (digest == 0) 1 else digest;
}

/// Coarse monotonic milliseconds for TTL. CLOCK_MONOTONIC_COARSE is served from
/// the vDSO without a syscall, and millisecond resolution is enough for TTL.
pub fn nowMillis() u64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC_COARSE, &ts);

    return @as(u64, @intCast(ts.sec)) * 1000 + @as(u64, @intCast(ts.nsec)) / std.time.ns_per_ms;
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //

test "zix response cache: store then lookup returns identical bytes" {
    var cache = try ResponseCache.init(std.testing.allocator, .{ .max_entries = 16, .max_value_bytes = 256 });
    defer cache.deinit();

    const key = hashKey("GET", "/cache", "");
    const payload = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nhi";

    try std.testing.expect(cache.store(key, payload, 1000, 100));
    try std.testing.expectEqualStrings(payload, cache.lookup(key, 200).?);
}

test "zix response cache: miss on absent key" {
    var cache = try ResponseCache.init(std.testing.allocator, .{ .max_entries = 16, .max_value_bytes = 256 });
    defer cache.deinit();

    try std.testing.expect(cache.lookup(hashKey("GET", "/absent", ""), 100) == null);
}

test "zix response cache: expired entry returns null then refetches" {
    var cache = try ResponseCache.init(std.testing.allocator, .{ .max_entries = 16, .max_value_bytes = 256 });
    defer cache.deinit();

    const key = hashKey("GET", "/cache", "");
    try std.testing.expect(cache.store(key, "first", 1000, 100));

    // now is past insert(100) + ttl(1000)
    try std.testing.expect(cache.lookup(key, 1100) == null);

    // store overwrites the same slot, fresh again
    try std.testing.expect(cache.store(key, "second", 1000, 1200));
    try std.testing.expectEqualStrings("second", cache.lookup(key, 1300).?);
}

test "zix response cache: oversize value bypasses store" {
    var cache = try ResponseCache.init(std.testing.allocator, .{ .max_entries = 16, .max_value_bytes = 8 });
    defer cache.deinit();

    try std.testing.expect(!cache.store(hashKey("GET", "/big", ""), "this is longer than eight", 1000, 100));
}

test "zix response cache: ttl 0 means never fresh" {
    var cache = try ResponseCache.init(std.testing.allocator, .{ .max_entries = 16, .max_value_bytes = 256 });
    defer cache.deinit();

    const key = hashKey("GET", "/cache", "");
    try std.testing.expect(cache.store(key, "x", 0, 100));
    try std.testing.expect(cache.lookup(key, 100) == null);
}

test "zix response cache: distinct keys coexist via probing" {
    var cache = try ResponseCache.init(std.testing.allocator, .{ .max_entries = 16, .max_value_bytes = 64 });
    defer cache.deinit();

    const key_a = hashKey("GET", "/a", "");
    const key_b = hashKey("GET", "/b", "");
    try std.testing.expect(cache.store(key_a, "alpha", 1000, 100));
    try std.testing.expect(cache.store(key_b, "bravo", 1000, 100));

    try std.testing.expectEqualStrings("alpha", cache.lookup(key_a, 200).?);
    try std.testing.expectEqualStrings("bravo", cache.lookup(key_b, 200).?);
}

test "zix response cache: max_entries rounded down to power of two" {
    var cache = try ResponseCache.init(std.testing.allocator, .{ .max_entries = 100, .max_value_bytes = 32 });
    defer cache.deinit();

    // 100 floors to 64, mask = 63
    try std.testing.expectEqual(@as(usize, 63), cache.mask);
    try std.testing.expectEqual(@as(usize, 64), cache.keys.len);
}

test "zix response cache: hashKey separates by query" {
    try std.testing.expect(hashKey("GET", "/p", "a=1") != hashKey("GET", "/p", "a=2"));
    try std.testing.expect(hashKey("GET", "/p", "") != hashKey("POST", "/p", ""));
}

test "zix response cache: hashKeyEncoded separates by encoding and from identity" {
    const gz = hashKeyEncoded("GET", "/json", "", "gzip");
    const br = hashKeyEncoded("GET", "/json", "", "br");
    const ident = hashKey("GET", "/json", "");

    try std.testing.expect(gz != br);
    try std.testing.expect(gz != ident);
    try std.testing.expect(hashKeyEncoded("GET", "/json", "", "gzip") == gz); // stable
}
