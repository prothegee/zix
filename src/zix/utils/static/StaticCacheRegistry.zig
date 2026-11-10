//! ZIX utils static cache registry
//!
//! ### file: src/zix/utils/static/StaticCacheRegistry.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! The one static cache of the process, with the settings it was built with.
//!
//! ### note:
//!
//! The first server that enables static caching fixes the size and TTL for
//! the whole process. A later server asking for other values gets MISMATCHED
//! and runs under the installed policy, since two tables would double the
//! descriptor cost.
//! `shared` is the process instance. Tests build their own.
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
const StaticCache = @import("StaticCache.zig");
const InstallResult = @import("install_result.zig").InstallResult;

// --------------------------------------------------------- //
// Fields:

/// The installed table, null when static caching is off.
cache: ?StaticCache = null,
/// Entry count the table was installed with.
max_entries: u32 = 0,
/// Freshness window the table was installed with, 0 when none.
ttl_ms: u32 = 0,
/// Spinlock for install and shutdown.
lock_flag: std.atomic.Value(bool) = .init(false),

const Self = @This();

// --------------------------------------------------------- //
// Private:

fn lock(self: *Self) void {
    while (self.lock_flag.swap(true, .acquire)) std.atomic.spinLoopHint();
}

fn unlock(self: *Self) void {
    self.lock_flag.store(false, .release);
}

// --------------------------------------------------------- //
// Public:

/// ZIX utils static cache registry error
pub const Error = error {
    ZixUtils_StaticCacheRegistry_OutOfMemory,
    ZixUtils_StaticCacheRegistry_MapFailed,
};

/// The process wide registry every server shares.
pub var shared: Self = .{};

/// Build the table, or report why not.
///
/// Param:
/// max_entries - u32 (requested slot count)
/// ttl_ms - u32 (freshness window, 0 disables)
///
/// Return:
/// - InstallResult
/// - Error when the table cannot be mapped, the caller serves uncached
pub fn install(self: *Self, max_entries: u32, ttl_ms: u32) Error!InstallResult {
    if (ttl_ms == 0) return .DISABLED;

    self.lock();
    defer self.unlock();

    if (self.cache != null) {
        if (self.max_entries != max_entries or self.ttl_ms != ttl_ms) return .MISMATCHED;

        return .ALREADY_INSTALLED;
    }

    self.cache = StaticCache.init(max_entries) catch |err| switch (err) {
        error.ZixUtils_StaticCache_OutOfMemory,
        => return Error.ZixUtils_StaticCacheRegistry_OutOfMemory,
        error.ZixUtils_StaticCache_MapFailed,
        => return Error.ZixUtils_StaticCacheRegistry_MapFailed,
    };
    self.max_entries = max_entries;
    self.ttl_ms = ttl_ms;

    return .INSTALLED;
}

/// The installed table.
///
/// Return:
/// - *StaticCache
/// - null when static caching is off
pub fn instance(self: *Self) ?*StaticCache {
    if (self.cache) |*cache| return cache;

    return null;
}

/// Close every cached file and drop the table.
///
/// Note:
/// - Call only after every server in the process has stopped.
///
/// Param:
/// io - std.Io (close)
pub fn shutdown(self: *Self, io: std.Io) void {
    self.lock();
    defer self.unlock();

    if (self.cache) |*cache| cache.deinit(io);

    self.cache = null;
    self.max_entries = 0;
    self.ttl_ms = 0;
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "zix utils static: StaticCacheRegistry, starts without a table" {
    var registry: Self = .{};

    try std.testing.expect(registry.instance() == null);
    try std.testing.expectEqual(@as(u32, 0), registry.ttl_ms);
}

test "zix utils static: StaticCacheRegistry, ttl 0 is disabled" {
    var registry: Self = .{};

    try std.testing.expectEqual(InstallResult.DISABLED, try registry.install(64, 0));
    try std.testing.expect(registry.instance() == null);
}

test "zix utils static: StaticCacheRegistry, install builds the table" {
    var registry: Self = .{};
    defer registry.shutdown(std.testing.io);

    try std.testing.expectEqual(InstallResult.INSTALLED, try registry.install(64, 2000));
    try std.testing.expect(registry.instance() != null);
    try std.testing.expectEqual(@as(u32, 2000), registry.ttl_ms);
}

test "zix utils static: StaticCacheRegistry, same settings share the table" {
    var registry: Self = .{};
    defer registry.shutdown(std.testing.io);

    _ = try registry.install(64, 2000);

    try std.testing.expectEqual(InstallResult.ALREADY_INSTALLED, try registry.install(64, 2000));
}

test "zix utils static: StaticCacheRegistry, other settings are MISMATCHED" {
    var registry: Self = .{};
    defer registry.shutdown(std.testing.io);

    _ = try registry.install(64, 2000);
    const first = registry.instance().?;

    try std.testing.expectEqual(InstallResult.MISMATCHED, try registry.install(128, 5000));
    try std.testing.expectEqual(first, registry.instance().?);
    try std.testing.expectEqual(@as(u32, 2000), registry.ttl_ms);
}

test "zix utils static: StaticCacheRegistry, shutdown clears the table" {
    var registry: Self = .{};

    _ = try registry.install(64, 2000);
    registry.shutdown(std.testing.io);

    try std.testing.expect(registry.instance() == null);
    try std.testing.expectEqual(@as(u32, 0), registry.ttl_ms);
}

test "zix utils static: StaticCacheRegistry, shutdown without a table is a no-op" {
    var registry: Self = .{};

    registry.shutdown(std.testing.io);

    try std.testing.expect(registry.instance() == null);
}

