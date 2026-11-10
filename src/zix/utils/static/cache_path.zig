//! ZIX utils static cache path
//!
//! ### file: src/zix/utils/static/cache_path.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Join public_dir with a request path, reject unsafe paths, and hash the
//! result into a cache key.
//!
//! ### note:
//!
//! PUBLIC_PATH_MAX is the one path limit for static serving. The cache slot
//! and the uncached path both size by it, so a path never resolves on one side
//! and fails on the other.
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

// --------------------------------------------------------- //
// Public:

/// Longest joined path (root, separator, request path) static serving
/// touches.
pub const PUBLIC_PATH_MAX: usize = 512;

/// Join public_dir and req_path into buf.
///
/// Note:
/// - `..` is rejected, not normalized.
/// - An absolute req_path is rejected.
///
/// Param:
/// buf - []u8 (output, PUBLIC_PATH_MAX bytes is enough)
/// public_dir - []const u8 (static root)
/// req_path - []const u8 (request path with the leading slash stripped)
///
/// Return:
/// - []const u8 (the joined path inside buf)
/// - null when the path is empty, unsafe, or does not fit
pub fn resolve(buf: []u8, public_dir: []const u8, req_path: []const u8) ?[]const u8 {
    if (req_path.len == 0) return null;
    if (std.mem.indexOf(u8, req_path, "..") != null) return null;
    if (req_path[0] == '/') return null;
    if (public_dir.len + 1 + req_path.len > buf.len) return null;

    @memcpy(buf[0..public_dir.len], public_dir);
    buf[public_dir.len] = '/';
    @memcpy(buf[public_dir.len + 1 ..][0..req_path.len], req_path);

    return buf[0 .. public_dir.len + 1 + req_path.len];
}

/// Hash a resolved path into a non-zero key. 0 marks a never used slot.
///
/// Param:
/// path - []const u8 (resolved path)
///
/// Return:
/// - u64 (never 0)
pub fn hash(path: []const u8) u64 {
    const digest = std.hash.Wyhash.hash(0, path);

    return if (digest == 0) 1 else digest;
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "zix utils static: cache_path, resolve joins root and path" {
    var buf: [PUBLIC_PATH_MAX]u8 = undefined;

    try std.testing.expectEqualStrings("public/a.txt", resolve(&buf, "public", "a.txt").?);
}

test "zix utils static: cache_path, resolve keeps a nested path" {
    var buf: [PUBLIC_PATH_MAX]u8 = undefined;

    try std.testing.expectEqualStrings(
        "./public/dir/a.txt",
        resolve(&buf, "./public", "dir/a.txt").?,
    );
}

test "zix utils static: cache_path, resolve empty path is null" {
    var buf: [PUBLIC_PATH_MAX]u8 = undefined;

    try std.testing.expect(resolve(&buf, "public", "") == null);
}

test "zix utils static: cache_path, resolve leading traversal is null" {
    var buf: [PUBLIC_PATH_MAX]u8 = undefined;

    try std.testing.expect(resolve(&buf, "public", "../etc/passwd") == null);
}

test "zix utils static: cache_path, resolve inner traversal is null" {
    var buf: [PUBLIC_PATH_MAX]u8 = undefined;

    try std.testing.expect(resolve(&buf, "public", "a/../b") == null);
}

test "zix utils static: cache_path, resolve absolute path is null" {
    var buf: [PUBLIC_PATH_MAX]u8 = undefined;

    try std.testing.expect(resolve(&buf, "public", "/absolute") == null);
}

test "zix utils static: cache_path, resolve past PUBLIC_PATH_MAX is null" {
    var buf: [PUBLIC_PATH_MAX]u8 = undefined;
    const long: [PUBLIC_PATH_MAX]u8 = @splat('a');

    try std.testing.expect(resolve(&buf, "public", &long) == null);
}

test "zix utils static: cache_path, hash is stable" {
    try std.testing.expectEqual(hash("public/a.txt"), hash("public/a.txt"));
}

test "zix utils static: cache_path, hash differs per path" {
    try std.testing.expect(hash("public/a.txt") != hash("public/b.txt"));
}

test "zix utils static: cache_path, hash is never zero" {
    try std.testing.expect(hash("") != 0);
}

