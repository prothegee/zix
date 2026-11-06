//! ZIX
//! Zero sIX; 06;
//! A network backend library written in zig.
//!
//! ### file: src/zix/lib.zig
//! 
//! ### author: Prana Ron
//! 
//! ---------------------------------------------------------
//! 
//! ### brief:
//! 
//! ZIX library entry: the version truth and the public module exports.
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
const builtin = @import("builtin");

// --------------------------------------------------------- //
// Private:

fn getVersionString() []const u8 {
    return std.fmt.comptimePrint("{d}.{d}.{d}{s}", .{
        VERSION.MAJOR,
        VERSION.MINOR,
        VERSION.PATCH,
        if (VERSION.RELEASE_CANDIDATE) |rc|
            std.fmt.comptimePrint("-rc{d}", .{rc})
        else
            "",
    });
}

// --------------------------------------------------------- //
// Public:

/// THE ONLY SOURCE OF TRUTH for Zig SEMVER for zix source code.
///
/// Note:
/// - Do not create in other place
pub const ZIG_SEMVER = struct {
    pub const MAJOR: usize = builtin.zig_version.major;
    pub const MINOR: usize = builtin.zig_version.minor;
    pub const PATCH: usize = builtin.zig_version.patch;
};

/// THE ONLY SOURCE OF TRUTH for ZIX SEMVER.
///
/// Note:
/// - Do not create in other place
pub const VERSION = struct {
    pub const MAJOR
        = @import("zix_options").zix_version_info.major;
    pub const MINOR
        = @import("zix_options").zix_version_info.minor;
    pub const PATCH
        = @import("zix_options").zix_version_info.patch;
    pub const RELEASE_CANDIDATE: ?usize
        = @import("zix_options").zix_version_info.release_candidate;
};

/// THE ONLY SOURCE OF TRUTH for ZIX string version.
///
/// Note:
/// - Do not create in other place
pub const VERSION_STRING = getVersionString();

// --------------------------------------------------------- //

// ZIX Http1
pub const Http1 = @import("tcp/http1/Http1.zig");

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "zix: version, semver fields follow the compiler" {
    try std.testing.expectEqual(builtin.zig_version.major, ZIG_SEMVER.MAJOR);
    try std.testing.expectEqual(builtin.zig_version.minor, ZIG_SEMVER.MINOR);
    try std.testing.expectEqual(builtin.zig_version.patch, ZIG_SEMVER.PATCH);
}

test "zix: version, string is not empty" {
    try std.testing.expect(VERSION_STRING.len > 0);
}

