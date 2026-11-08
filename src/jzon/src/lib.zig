//! JZON
//! JSON, in both directions.
//!
//! ### file: src/jzon/src/lib.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! JZON library entry: the version truth and the public exports.
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
const jzon_options = @import("jzon_options");

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

/// THE ONLY SOURCE OF TRUTH for JZON SEMVER.
///
/// Note:
/// - The values come from `src/jzon/build.zig.zon` through the build options.
/// - Do not create in other place
pub const VERSION = struct {
    pub const MAJOR: usize = jzon_options.version_major;
    pub const MINOR: usize = jzon_options.version_minor;
    pub const PATCH: usize = jzon_options.version_patch;
};

/// THE ONLY SOURCE OF TRUTH for JZON string version, for example `0.1.0`.
///
/// Note:
/// - Do not create in other place
pub const VERSION_STRING = getVersionString();

/// A bounds-checked write cursor over a caller-owned buffer.
pub const Sink = @import("Sink.zig");

/// A bounds-checked read cursor over a caller-owned document.
pub const Cursor = @import("Cursor.zig");

/// A located string token: the bytes between the quotes, plus whether they hold
/// an escape.
pub const StringSpan = @import("StringSpan.zig");

/// What the last failed parse on this thread was about: the field, the byte, or both.
///
/// Note:
/// - Read it right after a parse returned an error, before another parse on the
///   same thread replaces it.
pub const lastFailure = @import("deserialize/Failure.zig").lastFailure;

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "jzon: VERSION_STRING, matches the semver fields" {
    var buf: [64]u8 = undefined;
    const expected = try std.fmt.bufPrint(&buf, "{d}.{d}.{d}", .{
        VERSION.MAJOR,
        VERSION.MINOR,
        VERSION.PATCH,
    });

    try std.testing.expectEqualStrings(expected, VERSION_STRING);
}

test "jzon: VERSION_STRING, has exactly two dots" {
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, VERSION_STRING, "."));
}

test "jzon: VERSION_STRING, has no release candidate suffix" {
    try std.testing.expect(std.mem.findScalar(u8, VERSION_STRING, '-') == null);
}

test "jzon: VERSION, is not all zero" {
    const total = VERSION.MAJOR + VERSION.MINOR + VERSION.PATCH;

    try std.testing.expect(total > 0);
}

