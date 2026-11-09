//! JZON zon ZonOptions
//!
//! ### file: src/jzon/src/zon/ZonOptions.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! What a caller hands a ZON deserialize or a ZON serialize: string mode, unknown key
//! mode, depth cap, output layout, and which integer fields are written as hex.
//!
//! ### note:
//!
//! One record serves both directions. A deserialize reads `strings`, `unknown` and
//! `max_depth`. A serialize reads `layout` and `hex_fields`. A field the call does not
//! read is ignored.
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
const DeserializeOptions = @import("../deserialize/DeserializeOptions.zig");

// --------------------------------------------------------- //
// Fields:

/// Where a parsed string's bytes live.
strings: Strings = .COPY,
/// What happens to a key the target type does not declare.
unknown: Unknown = .REJECT,
/// How many `.{}` containers a parse follows before it refuses the document.
max_depth: usize = DEFAULT_MAX_DEPTH,
/// How a serialize lays out its text.
layout: Layout = .MULTILINE,
/// Field names a serialize writes as hex (`0x4cc61d74dc93a20b`). A name matches at
/// every depth. A name that is not a field, or names a field that is not an integer
/// or an optional integer, stops the build.
hex_fields: []const []const u8 = &.{},

const Self = @This();

// --------------------------------------------------------- //
// Public:

/// The depth cap a parse runs with unless the caller names another.
pub const DEFAULT_MAX_DEPTH = 256;

/// Where a parsed string's bytes live. Same meaning as the JSON parse option.
///
/// Note:
/// - Under `.BORROW`, a one-line multiline string with no `\r` also points into the
///   document. One with more lines is joined, so it is copied.
pub const Strings = DeserializeOptions.Strings;

/// What happens to a key the target type does not declare. Same meaning as the JSON
/// parse option.
pub const Unknown = DeserializeOptions.Unknown;

/// How a serialize lays out its text.
pub const Layout = enum {
    /// One entry per line, four spaces per level, a trailing comma after every entry.
    /// The shape `build.zig.zon` uses.
    MULTILINE,
    /// Everything on one line: `.{ .id = 1, .tags = .{ "a", "b" } }`.
    COMPACT,
};

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

/// Read the options passed at compile time, the way a call does.
fn pick(comptime options: Self) Self {
    return options;
}

test "jzon zon: ZonOptions, default strings is COPY" {
    const options: Self = .{};

    try std.testing.expectEqual(Strings.COPY, options.strings);
}

test "jzon zon: ZonOptions, default unknown is REJECT" {
    const options: Self = .{};

    try std.testing.expectEqual(Unknown.REJECT, options.unknown);
}

test "jzon zon: ZonOptions, default max_depth is DEFAULT_MAX_DEPTH" {
    const options: Self = .{};

    try std.testing.expectEqual(@as(usize, DEFAULT_MAX_DEPTH), options.max_depth);
}

test "jzon zon: ZonOptions, default layout is MULTILINE" {
    const options: Self = .{};

    try std.testing.expectEqual(Layout.MULTILINE, options.layout);
}

test "jzon zon: ZonOptions, default hex_fields is empty" {
    const options: Self = .{};

    try std.testing.expectEqual(@as(usize, 0), options.hex_fields.len);
}

test "jzon zon: ZonOptions, every field can be set at compile time" {
    const options = comptime pick(.{
        .strings = .BORROW,
        .unknown = .SKIP,
        .max_depth = 4,
        .layout = .COMPACT,
        .hex_fields = &.{
            "fingerprint",
            "mask",
        },
    });

    try std.testing.expectEqual(Strings.BORROW, options.strings);
    try std.testing.expectEqual(Unknown.SKIP, options.unknown);
    try std.testing.expectEqual(@as(usize, 4), options.max_depth);
    try std.testing.expectEqual(Layout.COMPACT, options.layout);
    try std.testing.expectEqualStrings("mask", options.hex_fields[1]);
}

test "jzon zon: ZonOptions, max_depth of zero is allowed" {
    const options = comptime pick(.{ .max_depth = 0 });

    try std.testing.expectEqual(@as(usize, 0), options.max_depth);
}

