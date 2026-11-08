//! JZON DeserializeOptions
//!
//! ### file: src/jzon/src/deserialize/DeserializeOptions.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! What a caller hands a parse: which read path runs (`Strategy`), where a parsed
//! string's bytes live (`Strings`), and what an unknown key does (`Unknown`).
//!
//! ### note:
//!
//! Every path reads the same options, so one can be swapped for another without a line
//! changing around the call. The default `.STD` parses every shape std parses. A
//! generated strategy is opt-in, and asking for one on a shape it has no JSON form for
//! is a compile error naming the type.
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
// Fields:

/// Which read path a parse runs.
strategy: Strategy = .STD,
/// Where a parsed string's bytes live.
strings: Strings = .COPY,
/// What happens to a key the target type does not declare.
unknown: Unknown = .REJECT,

const Self = @This();

// --------------------------------------------------------- //
// Public:

/// Which read path a parse runs.
///
/// Note:
/// - Read by the entry point that picks a path. The path under it is handed what it
///   needs and never sees which strategy named it.
pub const Strategy = enum {
    /// `std.json` reflection, which parses anything std parses.
    STD,
    /// Tokens from `std.json.Scanner`, with the field dispatch generated from the
    /// type. std still decides what a valid document is.
    SCANNER,
    /// Generated from the type, over jzon's own read cursor, one byte at a time.
    GENERATED,
    /// As GENERATED, one vector lane at a time. It pays on documents laid out with
    /// whitespace or carrying long strings.
    GENERATED_VECTOR,
};

/// Where a parsed string's bytes live.
pub const Strings = enum {
    /// Every string is copied into the allocator, so the value outlives the document.
    COPY,
    /// A string with no escape points into the document instead of being copied. A
    /// string with an escape is still copied, because its decoded bytes are not in
    /// the document. The document has to outlive the value.
    BORROW,
};

/// What happens to a key the target type does not declare.
pub const Unknown = enum {
    /// The document is wrong for this type, so the parse fails.
    REJECT,
    /// The key and its whole value are stepped over, however deep they nest.
    SKIP,
};

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

/// Read the options passed at compile time, the way a parse does.
fn pick(comptime options: Self) Self {
    return options;
}

test "jzon deserialize: DeserializeOptions, default strategy is STD" {
    const options: Self = .{};

    try std.testing.expectEqual(Strategy.STD, options.strategy);
}

test "jzon deserialize: DeserializeOptions, default strings mode is COPY" {
    const options: Self = .{};

    try std.testing.expectEqual(Strings.COPY, options.strings);
}

test "jzon deserialize: DeserializeOptions, default unknown rule is REJECT" {
    const options: Self = .{};

    try std.testing.expectEqual(Unknown.REJECT, options.unknown);
}

test "jzon deserialize: DeserializeOptions, Strategy keeps its four public names" {
    const names = @typeInfo(Strategy).@"enum".field_names;

    try std.testing.expectEqual(@as(usize, 4), names.len);
    try std.testing.expectEqualStrings("STD", names[0]);
    try std.testing.expectEqualStrings("SCANNER", names[1]);
    try std.testing.expectEqualStrings("GENERATED", names[2]);
    try std.testing.expectEqualStrings("GENERATED_VECTOR", names[3]);
}

test "jzon deserialize: DeserializeOptions, Strings keeps its two public names" {
    const names = @typeInfo(Strings).@"enum".field_names;

    try std.testing.expectEqual(@as(usize, 2), names.len);
    try std.testing.expectEqualStrings("COPY", names[0]);
    try std.testing.expectEqualStrings("BORROW", names[1]);
}

test "jzon deserialize: DeserializeOptions, Unknown keeps its two public names" {
    const names = @typeInfo(Unknown).@"enum".field_names;

    try std.testing.expectEqual(@as(usize, 2), names.len);
    try std.testing.expectEqualStrings("REJECT", names[0]);
    try std.testing.expectEqualStrings("SKIP", names[1]);
}

test "jzon deserialize: DeserializeOptions, one field set keeps the others at default" {
    const options: Self = .{
        .strings = .BORROW,
    };

    try std.testing.expectEqual(Strategy.STD, options.strategy);
    try std.testing.expectEqual(Strings.BORROW, options.strings);
    try std.testing.expectEqual(Unknown.REJECT, options.unknown);
}

test "jzon deserialize: DeserializeOptions, works as a comptime argument" {
    const options = comptime pick(.{
        .strategy = .GENERATED_VECTOR,
        .strings = .BORROW,
        .unknown = .SKIP,
    });

    try std.testing.expectEqual(Strategy.GENERATED_VECTOR, options.strategy);
    try std.testing.expectEqual(Strings.BORROW, options.strings);
    try std.testing.expectEqual(Unknown.SKIP, options.unknown);
}

