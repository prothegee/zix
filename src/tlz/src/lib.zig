//! TLZ
//! TLS, DTLS, and certificates on pure std.crypto.
//!
//! ### file: src/tlz/src/lib.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! TLZ library entry: the version truth and the public exports.
//!
//! ### note:
//!
//! Tests run through `test.zig`, not through this file. Add a new source file there,
//! or its in-file tests never run.
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
const tlz_options = @import("tlz_options");

// --------------------------------------------------------- //
// Private:

fn getVersionString() []const u8 {
    return std.fmt.comptimePrint("{d}.{d}.{d}", .{
        VERSION.MAJOR,
        VERSION.MINOR,
        VERSION.PATCH,
    });
}

// --------------------------------------------------------- //
// Public:

/// THE ONLY SOURCE OF TRUTH for TLZ SEMVER.
///
/// Note:
/// - The values come from `src/tlz/build.zig.zon` through the build options.
/// - Do not create in other place
pub const VERSION = struct {
    pub const MAJOR: usize = tlz_options.version_major;
    pub const MINOR: usize = tlz_options.version_minor;
    pub const PATCH: usize = tlz_options.version_patch;
};

/// THE ONLY SOURCE OF TRUTH for TLZ string version, for example `0.1.0`.
///
/// Note:
/// - Do not create in other place
pub const VERSION_STRING = getVersionString();

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "tlz: VERSION_STRING, matches the semver fields" {
    var buf: [64]u8 = undefined;
    const expected = try std.fmt.bufPrint(&buf, "{d}.{d}.{d}", .{
        VERSION.MAJOR,
        VERSION.MINOR,
        VERSION.PATCH,
    });

    try std.testing.expectEqualStrings(expected, VERSION_STRING);
}

test "tlz: VERSION_STRING, has exactly two dots" {
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, VERSION_STRING, "."));
}

test "tlz: VERSION_STRING, has no release candidate suffix" {
    try std.testing.expect(std.mem.findScalar(u8, VERSION_STRING, '-') == null);
}

test "tlz: VERSION, is not all zero" {
    const total = VERSION.MAJOR + VERSION.MINOR + VERSION.PATCH;

    try std.testing.expect(total > 0);
}

