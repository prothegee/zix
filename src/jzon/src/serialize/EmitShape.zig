//! JZON EmitShape
//!
//! ### file: src/jzon/src/serialize/EmitShape.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! The pairing the generated emitter runs with: how integers reach the buffer
//! (`NumberPath`) and how strings are scanned for escapes (`EscapePath`).
//!
//! ### note:
//!
//! The two choices are independent, so every pairing is valid, and every pairing writes
//! the same bytes. The write side keeps the `Emit` prefix so it never shares a file name
//! with the read side's `ScanShape`.
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

/// How an integer reaches the buffer.
numbers: NumberPath = .TABLE,
/// How a string is scanned for the bytes that need escaping.
escapes: EscapePath = .SCALAR,

const Self = @This();

// --------------------------------------------------------- //
// Public:

/// How an integer reaches the buffer.
pub const NumberPath = enum {
    /// Through `std.fmt`, which runs its width and alignment pass per value.
    FMT,
    /// Digits written straight into the sink.
    TABLE,
};

/// How a string is scanned for the bytes that need escaping.
pub const EscapePath = enum {
    /// One byte at a time.
    SCALAR,
    /// One vector lane at a time, which pays on long strings only.
    VECTOR,
};

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

/// Read the pairing out of a shape passed at compile time, the way an emitter does.
fn pick(comptime shape: Self) Self {
    return shape;
}

test "jzon serialize: EmitShape, default numbers path is TABLE" {
    const shape: Self = .{};

    try std.testing.expectEqual(NumberPath.TABLE, shape.numbers);
}

test "jzon serialize: EmitShape, default escapes path is SCALAR" {
    const shape: Self = .{};

    try std.testing.expectEqual(EscapePath.SCALAR, shape.escapes);
}

test "jzon serialize: EmitShape, every pairing can be built" {
    inline for (@typeInfo(NumberPath).@"enum".field_names) |number_name| {
        inline for (@typeInfo(EscapePath).@"enum".field_names) |escape_name| {
            const shape: Self = .{
                .numbers = @field(NumberPath, number_name),
                .escapes = @field(EscapePath, escape_name),
            };

            try std.testing.expectEqualStrings(number_name, @tagName(shape.numbers));
            try std.testing.expectEqualStrings(escape_name, @tagName(shape.escapes));
        }
    }
}

test "jzon serialize: EmitShape, NumberPath keeps its two names" {
    const names = @typeInfo(NumberPath).@"enum".field_names;

    try std.testing.expectEqual(@as(usize, 2), names.len);
    try std.testing.expectEqualStrings("FMT", names[0]);
    try std.testing.expectEqualStrings("TABLE", names[1]);
}

test "jzon serialize: EmitShape, EscapePath keeps its two names" {
    const names = @typeInfo(EscapePath).@"enum".field_names;

    try std.testing.expectEqual(@as(usize, 2), names.len);
    try std.testing.expectEqualStrings("SCALAR", names[0]);
    try std.testing.expectEqualStrings("VECTOR", names[1]);
}

test "jzon serialize: EmitShape, one field set keeps the other at its default" {
    const shape: Self = .{
        .escapes = .VECTOR,
    };

    try std.testing.expectEqual(NumberPath.TABLE, shape.numbers);
    try std.testing.expectEqual(EscapePath.VECTOR, shape.escapes);
}

test "jzon serialize: EmitShape, works as a comptime argument" {
    const shape = comptime pick(.{
        .numbers = .FMT,
        .escapes = .VECTOR,
    });

    try std.testing.expectEqual(NumberPath.FMT, shape.numbers);
    try std.testing.expectEqual(EscapePath.VECTOR, shape.escapes);
}

