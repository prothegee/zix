//! JZON reflect
//!
//! ### file: src/jzon/src/reflect.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! The type questions jzon asks that `std.meta` does not answer directly: whether an
//! enum names every value, and what default a struct field declares.
//!
//! ### note:
//!
//! Zig 0.17 only. An enum's exhaustiveness lives in `mode`, and a struct field's
//! default lives in `field_attrs`. `std.meta.fieldNames` and `@FieldType` already
//! answer the rest, so a caller walking fields uses those directly.
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

/// Whether every value of an enum type has a tag name.
///
/// Note:
/// - A non-exhaustive enum carries values no name covers, which is why both
///   directions refuse one: there is no name to write, and no value to read a name
///   into.
///
/// Param:
/// Target - type (comptime, the enum type to ask about)
///
/// Return:
/// - bool (true when every value the type carries has a name)
pub inline fn isExhaustive(comptime Target: type) bool {
    return @typeInfo(Target).@"enum".mode == .exhaustive;
}

/// The default value a struct field declares, when it declares one.
///
/// Note:
/// - An optional field spelled `note: ?[]const u8 = null` has a default, and that
///   default is `null`. The result is one optional deeper than the field, so
///   "declares no default" and "defaults to null" stay apart.
///
/// Param:
/// Target - type (comptime, the struct declaring the field)
/// index - usize (comptime, the field's place in declaration order)
///
/// Return:
/// - ?Field (the declared default)
/// - null when the field declares no default
pub inline fn defaultOf(
    comptime Target: type,
    comptime index: usize,
) ?@FieldType(Target, std.meta.fieldNames(Target)[index]) {
    const Field = @FieldType(Target, std.meta.fieldNames(Target)[index]);
    const attrs = @typeInfo(Target).@"struct".field_attrs[index];

    return attrs.defaultValue(Field);
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const Closed = enum { PENDING, SHIPPED };
const Open = enum(u8) { PENDING, SHIPPED, _ };

const Point = struct {
    x: i32,
    y: i32,
};

const Record = struct {
    id: u32,
    name: []const u8,
    note: ?[]const u8 = null,
    retries: u8 = 3,
};

const Boundary = struct {
    note: ?[]const u8 = null,
    origin: Point = .{
        .x = 0,
        .y = 0,
    },
    tags: []const []const u8 = &.{},
    zero: u8 = 0,
    required: u8,
};

test "jzon: reflect, isExhaustive is true for an enum that names every value" {
    try std.testing.expect(isExhaustive(Closed));
}

test "jzon: reflect, isExhaustive is false for a non-exhaustive enum" {
    try std.testing.expect(!isExhaustive(Open));
}

test "jzon: reflect, defaultOf reads the default a field declares" {
    try std.testing.expectEqual(@as(?u8, 3), defaultOf(Record, 3));
}

test "jzon: reflect, defaultOf is null for a field without a default" {
    try std.testing.expect(defaultOf(Record, 0) == null);
    try std.testing.expect(defaultOf(Record, 1) == null);
}

test "jzon: reflect, defaultOf keeps a default of null apart from no default" {
    const note = defaultOf(Record, 2);

    try std.testing.expect(note != null);
    try std.testing.expect(note.? == null);
}

test "jzon: reflect, isExhaustive is false for a non-exhaustive enum of two bits" {
    try std.testing.expect(!isExhaustive(enum(u2) { A, _ }));
}

test "jzon: reflect, defaultOf is null for a required field after defaulted ones" {
    try std.testing.expect(defaultOf(Boundary, 4) == null);
}

test "jzon: reflect, defaultOf reads a default that is a whole struct" {
    const origin = defaultOf(Boundary, 1).?;

    try std.testing.expectEqual(@as(i32, 0), origin.x);
    try std.testing.expectEqual(@as(i32, 0), origin.y);
}

test "jzon: reflect, defaultOf reads a default that is an empty slice" {
    const tags = defaultOf(Boundary, 2).?;

    try std.testing.expectEqual(@as(usize, 0), tags.len);
}

test "jzon: reflect, defaultOf reads a default of zero as a value" {
    // Zero is a value, not the absence of one, so it comes back as a default, not as
    // null.
    const zero = defaultOf(Boundary, 3);

    try std.testing.expect(zero != null);
    try std.testing.expectEqual(@as(u8, 0), zero.?);
}

test "jzon: reflect, a struct without fields has no field names to walk" {
    const names = comptime std.meta.fieldNames(struct {});

    try std.testing.expectEqual(@as(usize, 0), names.len);
}

