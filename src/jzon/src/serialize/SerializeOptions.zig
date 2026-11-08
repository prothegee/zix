//! JZON SerializeOptions
//!
//! ### file: src/jzon/src/serialize/SerializeOptions.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! What a caller hands a render: which write path runs (`Strategy`).
//!
//! ### note:
//!
//! Every strategy writes the same bytes for the same value, so picking one is a cost
//! decision, never a correctness one. The default `.STD` renders every shape std
//! renders. A generated strategy is opt-in, and asking for one on a shape it has no
//! JSON form for is a compile error naming the type.
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

/// Which write path a render runs.
strategy: Strategy = .STD,

const Self = @This();

// --------------------------------------------------------- //
// Public:

/// Which write path a render runs.
///
/// Note:
/// - Read by the entry point that picks a path. The path under it is handed what it
///   needs and never sees which strategy named it.
pub const Strategy = enum {
    /// `std.json.Stringify`, which renders anything std renders.
    STD,
    /// Generated from the type, integers through `std.fmt`.
    GENERATED_FMT,
    /// Generated from the type, integer digits written straight into the buffer.
    GENERATED,
    /// As GENERATED, with strings scanned for escapes one vector lane at a time.
    /// It pays on long strings and costs on short ones.
    GENERATED_VECTOR,
};

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

/// Read the strategy out of options passed at compile time, the way a render does.
fn pick(comptime options: Self) Strategy {
    return options.strategy;
}

test "jzon serialize: SerializeOptions, default strategy is STD" {
    const options: Self = .{};

    try std.testing.expectEqual(Strategy.STD, options.strategy);
}

test "jzon serialize: SerializeOptions, every strategy can be chosen" {
    inline for (@typeInfo(Strategy).@"enum".field_names) |name| {
        const options: Self = .{
            .strategy = @field(Strategy, name),
        };

        try std.testing.expectEqualStrings(name, @tagName(options.strategy));
    }
}

test "jzon serialize: SerializeOptions, Strategy keeps its four public names" {
    const names = @typeInfo(Strategy).@"enum".field_names;

    try std.testing.expectEqual(@as(usize, 4), names.len);
    try std.testing.expectEqualStrings("STD", names[0]);
    try std.testing.expectEqualStrings("GENERATED_FMT", names[1]);
    try std.testing.expectEqualStrings("GENERATED", names[2]);
    try std.testing.expectEqualStrings("GENERATED_VECTOR", names[3]);
}

test "jzon serialize: SerializeOptions, works as a comptime argument" {
    const picked = comptime pick(.{
        .strategy = .GENERATED_VECTOR,
    });

    try std.testing.expectEqual(Strategy.GENERATED_VECTOR, picked);
}

