//! uuidz: uuid (zix internal implementation)

const std = @import("std");
const builtin = @import("builtin");

/// THE ONLY SOURCE OF TRUTH for Zig SEMVER for zix source code.
///
/// Note:
/// - Do not create in other place!
pub const ZIG_SEMVER = struct {
    pub const MAJOR: usize = builtin.zig_version.major;
    pub const MINOR: usize = builtin.zig_version.minor;
    pub const PATCH: usize = builtin.zig_version.patch;
};

/// THE ONLY SOURCE OF TRUTH for the zix package version, taken from
/// build.zig.zon at build time.
///
/// Note:
/// - Anything shipped from this repository reports this string, so a binary
///   never carries a version of its own to drift from the package.
pub const VERSION: []const u8 = @import("zon_options").version;

// --------------------------------------------------------- //

pub const v1 = @import("v1.zig");
pub const v4 = @import("v4.zig");
pub const v7 = @import("v7.zig");

// --------------------------------------------------------- //
// --------------------------------------------------------- //

test "uuidz: unit test" {
    std.testing.refAllDecls(@import("hex.zig"));

    std.testing.refAllDecls(@import("v1.zig"));
    std.testing.refAllDecls(@import("v4.zig"));
    std.testing.refAllDecls(@import("v7.zig"));
}
