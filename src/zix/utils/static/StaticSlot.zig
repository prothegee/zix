//! ZIX utils static slot
//!
//! ### file: src/zix/utils/static/StaticSlot.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! One cached static path: its key, live flag plus pin count, path, and the
//! identity, gzip, and br variants.
//!
//! ### note:
//!
//! Zeroed memory is a valid empty slot: key 0 stops a probe and state 0 means
//! not live.
//! Live flag and pin count share one atomic word, so a pin only succeeds while
//! the slot is live, and reclaim only succeeds while no pin is held.
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
const negotiate = @import("../compression/negotiate.zig").negotiate;
const Encoding = @import("../http/encoding.zig").Encoding;
const StaticHit = @import("StaticHit.zig");
const StaticSibling = @import("StaticSibling.zig");
const StaticVariant = @import("StaticVariant.zig");
const cache_header = @import("cache_header.zig");
const cache_path = @import("cache_path.zig");

// --------------------------------------------------------- //
// Fields:

/// Path hash, 0 when never used.
key: u64,
/// Live flag (STATE_LIVE) plus pin count (low bits).
state: std.atomic.Value(u32),
/// When the entry was inserted, coarse monotonic milliseconds.
insert_tick_ms: u64,
/// Used length of path_buf.
path_len: u16,
/// Resolved path this slot holds.
path_buf: [cache_path.PUBLIC_PATH_MAX]u8,
/// Identity, gzip, and br, indexed by cache_header.variantIndex.
variants: [cache_header.VARIANT_COUNT]StaticVariant,

const Self = @This();

// --------------------------------------------------------- //
// Public:

/// Slot is published and readable.
pub const STATE_LIVE: u32 = 1 << 31;

/// Outstanding pins live in the low bits.
pub const STATE_PIN_MASK: u32 = STATE_LIVE - 1;

/// The resolved path this slot holds.
///
/// Return:
/// - []const u8
pub fn path(self: *const Self) []const u8 {
    return self.path_buf[0..self.path_len];
}

/// Whether the slot is published.
///
/// Return:
/// - bool
pub fn isLive(self: *const Self) bool {
    return self.state.load(.acquire) & STATE_LIVE != 0;
}

/// Outstanding pins on this slot.
///
/// Return:
/// - u32
pub fn pinCount(self: *const Self) u32 {
    return self.state.load(.acquire) & STATE_PIN_MASK;
}

/// Whether the entry is still inside its freshness window.
///
/// Param:
/// ttl_ms - u32 (freshness window)
/// now_ms - u64 (coarse monotonic clock)
///
/// Return:
/// - bool
pub fn isFresh(self: *const Self, ttl_ms: u32, now_ms: u64) bool {
    return now_ms < self.insert_tick_ms + ttl_ms;
}

/// Take a pin. Succeeds only while the slot is live.
///
/// Return:
/// - bool (true when the pin is held and the caller must unpin)
pub fn pin(self: *Self) bool {
    var observed = self.state.load(.acquire);
    while (observed & STATE_LIVE != 0) {
        // A full pin count would wrap into the live flag, so refuse.
        if (observed & STATE_PIN_MASK == STATE_PIN_MASK) return false;

        if (self.state.cmpxchgWeak(observed, observed + 1, .acquire, .acquire)) |seen| {
            observed = seen;
            continue;
        }

        return true;
    }

    return false;
}

/// Drop one pin.
pub fn unpin(self: *Self) void {
    _ = self.state.fetchSub(1, .release);
}

/// Clear the live flag when no pin is held.
///
/// Return:
/// - bool (true when the slot was live and unpinned, and is now dead)
pub fn tryKill(self: *Self) bool {
    return self.state.cmpxchgStrong(STATE_LIVE, 0, .acq_rel, .acquire) == null;
}

/// Open the identity file and its siblings into the variants.
///
/// Note:
/// - The identity file is required. A missing sibling is only absent.
///
/// Param:
/// io - std.Io (open, stat)
/// full_path - []const u8 (resolved identity path)
///
/// Return:
/// - bool (true when the identity variant opened)
pub fn openVariants(self: *Self, io: std.Io, full_path: []const u8) bool {
    for (&self.variants) |*variant| variant.present = false;

    const identity = &self.variants[cache_header.variantIndex(.IDENTITY)];
    if (!identity.open(io, full_path, full_path, .IDENTITY)) return false;

    var sibling_buf: [cache_path.PUBLIC_PATH_MAX + 8]u8 = undefined;
    for (StaticSibling.ALL) |sibling| {
        const sibling_path = std.fmt.bufPrint(&sibling_buf, "{s}{s}", .{
            full_path,
            sibling.suffix,
        }) catch |err| switch (err) {
            error.NoSpaceLeft => continue,
        };
        const variant = &self.variants[cache_header.variantIndex(sibling.encoding)];

        _ = variant.open(io, sibling_path, full_path, sibling.encoding);
    }

    return true;
}

/// Close every variant.
///
/// Note:
/// - The caller holds the cache lock and the slot is no longer live.
///
/// Param:
/// io - std.Io (close)
pub fn closeVariants(self: *Self, io: std.Io) void {
    for (&self.variants) |*variant| variant.close(io);
}

/// Pick the variant the client accepts and describe it as a hit.
///
/// Note:
/// - The slot must already be pinned.
/// - Identity is the floor: a client that refuses every coding gets the plain
///   file, not a 406.
///
/// Param:
/// index - u32 (this slot's index in the table)
/// accept_encoding - ?[]const u8 (raw Accept-Encoding value)
///
/// Return:
/// - StaticHit
pub fn hit(self: *Self, index: u32, accept_encoding: ?[]const u8) StaticHit {
    var supported_buf: [StaticSibling.ALL.len]Encoding = undefined;
    var supported_len: usize = 0;
    for (StaticSibling.ALL) |sibling| {
        if (self.variants[cache_header.variantIndex(sibling.encoding)].present) {
            supported_buf[supported_len] = sibling.encoding;
            supported_len += 1;
        }
    }

    const chosen = negotiate(accept_encoding, supported_buf[0..supported_len]) orelse .IDENTITY;
    const wanted = &self.variants[cache_header.variantIndex(chosen)];
    const variant = if (wanted.present) wanted else &self.variants[0];

    return .{
        .slot = index,
        .file = variant.file,
        .size = variant.size,
        .header = variant.header(),
        .content_type = variant.content_type,
        .encoding = if (wanted.present) chosen else .IDENTITY,
    };
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

/// A slot as the zeroed table mapping hands it out.
fn zeroSlot() Self {
    var slot: Self = undefined;
    @memset(std.mem.asBytes(&slot), 0);

    return slot;
}

fn fixtureRoot(tmp: *std.testing.TmpDir, buf: []u8) []const u8 {
    const root = std.fmt.bufPrint(buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    return root catch |err| switch (err) {
        error.NoSpaceLeft => @panic("fixture path too long"),
    };
}

fn writeFixture(tmp: *std.testing.TmpDir, name: []const u8, data: []const u8) void {
    tmp.dir.writeFile(std.testing.io, .{
        .sub_path = name,
        .data = data,
    }) catch |err| switch (err) {
        else => @panic("fixture write failed"),
    };
}

test "zix utils static: StaticSlot, zeroed slot is not live" {
    const slot = zeroSlot();

    try std.testing.expect(!slot.isLive());
    try std.testing.expectEqual(@as(u64, 0), slot.key);
}

test "zix utils static: StaticSlot, pin on a dead slot fails" {
    var slot = zeroSlot();

    try std.testing.expect(!slot.pin());
}

test "zix utils static: StaticSlot, pin on a live slot counts" {
    var slot = zeroSlot();
    slot.state.store(STATE_LIVE, .release);

    try std.testing.expect(slot.pin());
    try std.testing.expectEqual(@as(u32, 1), slot.pinCount());
}

test "zix utils static: StaticSlot, unpin drops the count" {
    var slot = zeroSlot();
    slot.state.store(STATE_LIVE, .release);

    _ = slot.pin();
    slot.unpin();

    try std.testing.expectEqual(@as(u32, 0), slot.pinCount());
}

test "zix utils static: StaticSlot, pin past the cap is refused" {
    var slot = zeroSlot();
    slot.state.store(STATE_LIVE | STATE_PIN_MASK, .release);

    try std.testing.expect(!slot.pin());
    try std.testing.expect(slot.isLive());
}

test "zix utils static: StaticSlot, tryKill on a pinned slot fails" {
    var slot = zeroSlot();
    slot.state.store(STATE_LIVE | 1, .release);

    try std.testing.expect(!slot.tryKill());
    try std.testing.expect(slot.isLive());
}

test "zix utils static: StaticSlot, tryKill on an unpinned slot succeeds" {
    var slot = zeroSlot();
    slot.state.store(STATE_LIVE, .release);

    try std.testing.expect(slot.tryKill());
    try std.testing.expect(!slot.isLive());
}

test "zix utils static: StaticSlot, isFresh inside the window" {
    var slot = zeroSlot();
    slot.insert_tick_ms = 100;

    try std.testing.expect(slot.isFresh(1000, 1099));
}

test "zix utils static: StaticSlot, isFresh at the window end is stale" {
    var slot = zeroSlot();
    slot.insert_tick_ms = 100;

    try std.testing.expect(!slot.isFresh(1000, 1100));
}

test "zix utils static: StaticSlot, openVariants missing identity is false" {
    var slot = zeroSlot();

    try std.testing.expect(!slot.openVariants(std.testing.io, "no/such/file.txt"));
}

test "zix utils static: StaticSlot, openVariants finds the siblings" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    writeFixture(&tmp, "app.js", "plain");
    writeFixture(&tmp, "app.js.br", "br");

    var root_buf: [64]u8 = undefined;
    var path_buf: [128]u8 = undefined;
    const root = fixtureRoot(&tmp, &root_buf);
    const full_path = try std.fmt.bufPrint(&path_buf, "{s}/app.js", .{root});

    var slot = zeroSlot();
    defer slot.closeVariants(std.testing.io);

    try std.testing.expect(slot.openVariants(std.testing.io, full_path));
    try std.testing.expect(slot.variants[cache_header.variantIndex(.BR)].present);
    try std.testing.expect(!slot.variants[cache_header.variantIndex(.GZIP)].present);
}

test "zix utils static: StaticSlot, hit picks br when accepted" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    writeFixture(&tmp, "app.js", "plain");
    writeFixture(&tmp, "app.js.br", "br");

    var root_buf: [64]u8 = undefined;
    var path_buf: [128]u8 = undefined;
    const root = fixtureRoot(&tmp, &root_buf);
    const full_path = try std.fmt.bufPrint(&path_buf, "{s}/app.js", .{root});

    var slot = zeroSlot();
    defer slot.closeVariants(std.testing.io);

    _ = slot.openVariants(std.testing.io, full_path);
    const chosen = slot.hit(4, "br, gzip");

    try std.testing.expectEqual(Encoding.BR, chosen.encoding);
    try std.testing.expectEqual(@as(u64, 2), chosen.size);
    try std.testing.expectEqual(@as(u32, 4), chosen.slot);
}

test "zix utils static: StaticSlot, hit without a sibling falls back to identity" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    writeFixture(&tmp, "solo.css", "body{}");

    var root_buf: [64]u8 = undefined;
    var path_buf: [128]u8 = undefined;
    const root = fixtureRoot(&tmp, &root_buf);
    const full_path = try std.fmt.bufPrint(&path_buf, "{s}/solo.css", .{root});

    var slot = zeroSlot();
    defer slot.closeVariants(std.testing.io);

    _ = slot.openVariants(std.testing.io, full_path);
    const chosen = slot.hit(0, "br, gzip");

    try std.testing.expectEqual(Encoding.IDENTITY, chosen.encoding);
    try std.testing.expectEqualStrings("text/css", chosen.content_type);
}

