//! ZIX utils response cache
//!
//! ### file: src/zix/utils/ResponseCache.zig
//! 
//! ### author: Prana Ron
//! 
//! ---------------------------------------------------------
//! 
//! ### brief:
//! 
//! Per-worker response cache. Not thread-safe by design:
//! one instance per worker, never shared, so no lock is needed.
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
const Config = @import("../tcp/http1/Config.zig");
const slab_mem = @import("../multiplexers/slab.zig");

// --------------------------------------------------------- //
// Fields:

keys: []u64,
meta: []Meta,
slab: []u8,
pins: []u32,
cursor: usize,
value_bytes: usize,
mask: usize,
arena: std.heap.ArenaAllocator,
last_hit: ?[]const u8 = null,
last_hit_slot: u32 = 0,

const Self = @This();

// --------------------------------------------------------- //
// Private:

/// Granularity of a slot's slab region. Values pack at this rounding, so the
/// hot entries of a worker sit within a few pages of each other instead of one
/// full per-slot stride apart.
const REGION_ALIGN: usize = 64;

/// Slab prefix made resident at init, so the hot region's residency (and its
/// page placement) is a startup property instead of first-store faults.
const PRETOUCH_BYTES: usize = 64 * 1024;

// --------------------------------------------------------- //
// Public:

/// Per-slot bookkeeping, kept separate from the payload bytes so the hot
/// metadata stays dense and the cold payload lives in the slab.
pub const Meta = struct {
    insert_tick_ms: u64,
    len: u32,
    ttl_ms: u32,
    off: u32,
    cap: u32,
};

/// Allocate the keys and meta from one arena and the payload slab from its
/// own anonymous mapping (kernel-zeroed, demand-paged), so the slab's
/// placement never depends on allocator history and untouched capacity
/// costs no physical memory.
///
/// Note:
/// - max_entries is rounded down to a power of two, so the configured entry
///   count is an upper bound and the slab never exceeds
///   max_entries * max_value_bytes.
/// - The first PRETOUCH_BYTES of the slab are made resident up front, so
///   the hot region is a startup property instead of ramp-time faults.
///
/// Param:
/// backing - std.mem.Allocator (owns the arena's backing memory)
/// config - Config (slot count and per-slot byte cap)
///
/// Return:
/// - !ResponseCache
pub fn init(backing: std.mem.Allocator, config: Config) !Self {
    const entries: usize = std.math.floorPowerOfTwo(u32, @max(1, config.max_entries));
    const value_bytes: usize = @max(1, config.max_value_bytes);

    var arena = std.heap.ArenaAllocator.init(backing);
    errdefer arena.deinit();
    const allocator = arena.allocator();

    const keys = try allocator.alloc(u64, entries);
    @memset(keys, 0);

    const meta = try allocator.alloc(Meta, entries);
    const pins = try allocator.alloc(u32, entries);
    @memset(pins, 0);

    // THP opted out: under an "always" policy the first store would
    // materialize a whole 2 MiB extent of this compact slab, holding far
    // more resident than the packed values need.
    const slab = try slab_mem.mapZeroedSlots(u8, entries * value_bytes);
    slab_mem.adviseNoHugePages(slab);
    slab_mem.pretouch(slab[0..@min(slab.len, PRETOUCH_BYTES)]);

    return .{
        .keys = keys,
        .meta = meta,
        .pins = pins,
        .slab = slab,
        .cursor = 0,
        .value_bytes = value_bytes,
        .mask = entries - 1,
        .arena = arena,
    };
}

/// Unmap the slab and free the keys and meta in one shot.
pub fn deinit(self: *Self) void {
    slab_mem.unmapSlots(self.slab);
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
pub fn lookup(self: *Self, key: u64, now_ms: u64) ?[]const u8 {
    var index: usize = @intCast(key & self.mask);
    var probes: usize = 0;
    while (probes <= self.mask) : (probes += 1) {
        const slot_key = self.keys[index];
        if (slot_key == 0) return null;

        if (slot_key == key) {
            const entry = self.meta[index];
            if (now_ms >= entry.insert_tick_ms + entry.ttl_ms) return null;

            const bytes = self.slab[entry.off..][0..entry.len];
            self.last_hit = bytes;
            self.last_hit_slot = @intCast(index);

            return bytes;
        }

        index = (index + 1) & self.mask;
    }

    return null;
}

/// Copy bytes into the slot for key, evicting an expired neighbour if the
/// probe reaches one. Expired slots are reused in place rather than zeroed,
/// since zeroing would truncate an open-addressing probe chain.
///
/// Note:
/// - A slot whose existing region already fits the bytes keeps its region
///   (steady-state TTL refreshes never move or grow the slab). A first
///   store, or a larger value, draws a fresh region from the bump cursor.
///   The region a larger value abandons is not reclaimed: the slab bounds
///   the total at max_entries * max_value_bytes and a full slab fails the
///   store, which callers already treat as uncached.
///
/// Return:
/// - bool (true when stored, false when bytes exceed the per-slot cap, the
///   table is full of live distinct keys, or the slab has no region left)
pub fn store(self: *Self, key: u64, bytes: []const u8, ttl_ms: u32, now_ms: u64) bool {
    if (bytes.len > self.value_bytes) return false;

    var index: usize = @intCast(key & self.mask);
    var probes: usize = 0;
    while (probes <= self.mask) : (probes += 1) {
        const slot_key = self.keys[index];
        const expired = slot_key != 0 and now_ms >= self.meta[index].insert_tick_ms + self.meta[index].ttl_ms;

        if (slot_key == 0 or slot_key == key or expired) {
            // A pinned slot backs an in-flight zero-copy send: its bytes
            // must stay stable, so the slot's own key skips this store
            // (the next miss retries) and a reusable neighbour is probed
            // past like an occupied slot.
            if (self.pins[index] != 0) {
                if (slot_key == key) return false;

                index = (index + 1) & self.mask;
                continue;
            }

            var off: usize = self.meta[index].off;
            var cap: usize = if (slot_key == 0) 0 else self.meta[index].cap;
            if (cap < bytes.len) {
                const need = std.mem.alignForward(usize, bytes.len, REGION_ALIGN);
                if (self.cursor + need > self.slab.len) return false;

                off = self.cursor;
                cap = need;
                self.cursor += need;
            }

            std.debug.assert(self.pins[index] == 0);
            @memcpy(self.slab[off..][0..bytes.len], bytes);

            self.keys[index] = key;
            self.meta[index] = .{
                .insert_tick_ms = now_ms,
                .len = @intCast(bytes.len),
                .ttl_ms = ttl_ms,
                .off = @intCast(off),
                .cap = @intCast(cap),
            };

            return true;
        }

        index = (index + 1) & self.mask;
    }

    return false;
}

/// Resolve a slice returned by lookup back to its slot for the zero-copy
/// replay pin. Only the exact slice of the most recent hit resolves, so a
/// caller that rewrote or re-sliced the bytes falls back to the copy path.
///
/// Return:
/// - ?u32 (the slot, or null when bytes is not the last hit's slice)
pub fn hitSlot(self: *const Self, bytes: []const u8) ?u32 {
    const hit = self.last_hit orelse return null;
    if (hit.ptr != bytes.ptr or hit.len != bytes.len) return null;

    return self.last_hit_slot;
}

/// Pin slot's value region while an in-flight send references it. Balanced
/// by unpin from the send completion (or the connection teardown).
pub fn pin(self: *Self, slot: u32) void {
    self.pins[slot] += 1;
}

pub fn unpin(self: *Self, slot: u32) void {
    std.debug.assert(self.pins[slot] > 0);
    self.pins[slot] -= 1;
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

// TODO: zix.utils.ResponseCache.zig unit test

