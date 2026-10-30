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
//! n/a
//! 
//! ### note:
//! n/a
//! 
//! ---------------------------------------------------------
//! 
//! ### copyright:
//! 
//! - (c) 2026 Prana Ron // @prothegee // prothegee@protonmail.com
//! 
//! ### contributors:
//! 
//! - Prana Ron // @prothegee // prothegee@protonmail.com
//!

const std = @import("std");
const builtin = @import("builtin");

// --------------------------------------------------------- //

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
