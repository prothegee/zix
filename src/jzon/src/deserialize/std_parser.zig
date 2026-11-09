//! JZON std_parser
//!
//! ### file: src/jzon/src/deserialize/std_parser.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! The std-backed read path: reads a value through `std.json`, which reflects over the
//! target type at runtime. It takes every shape std takes.
//!
//! ### note:
//!
//! Everything the result points at comes from the allocator handed in, so an arena
//! reset frees a whole parse in one step. std's error set is wider than this module's
//! and shaped around std's internals, so every member is mapped here by name. std
//! reports a broken escape as a syntax error, so it lands on Unexpected, not BadEscape.
//! std surfaces neither the field nor the byte, so a failure here records an empty
//! `lastFailure`, which keeps an earlier failure on the thread from being read as this one.
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
const DeserializeOptions = @import("DeserializeOptions.zig");
const Failure = @import("Failure.zig");

const Allocator = std.mem.Allocator;

// --------------------------------------------------------- //
// Private:

/// Everything std can report from a parse over a complete document.
const StdError = std.json.ParseError(std.json.Scanner);

/// Translate one of std's failures into this module's set.
///
/// Note:
/// - Every member is named, so a std that adds one breaks the build here and gets a
///   deliberate mapping, not a silent one.
/// - Records an empty failure (no field, offset 0), so `lastFailure` never shows a
///   field left over from an earlier parse on this thread.
///
/// Param:
/// err - StdError (the failure std reported)
///
/// Return:
/// - Error (the closest failure under this module's name)
inline fn stdError(err: StdError) Error {
    @branchHint(.cold);

    Failure.noteOffset(0);

    return switch (err) {
        error.OutOfMemory => Error.Jzon_StdParser_OutOfMemory,
        error.UnknownField => Error.Jzon_StdParser_UnknownField,
        error.MissingField => Error.Jzon_StdParser_MissingField,
        error.InvalidEnumTag => Error.Jzon_StdParser_UnknownEnumValue,
        error.UnexpectedEndOfInput => Error.Jzon_StdParser_Truncated,
        error.BufferUnderrun => Error.Jzon_StdParser_Truncated,
        error.Overflow => Error.Jzon_StdParser_BadNumber,
        error.InvalidCharacter => Error.Jzon_StdParser_BadNumber,
        error.InvalidNumber => Error.Jzon_StdParser_BadNumber,
        error.SyntaxError => Error.Jzon_StdParser_Unexpected,
        error.UnexpectedToken => Error.Jzon_StdParser_Unexpected,
        error.DuplicateField => Error.Jzon_StdParser_Unexpected,
        error.LengthMismatch => Error.Jzon_StdParser_Unexpected,
        error.ValueTooLong => Error.Jzon_StdParser_Unexpected,
    };
}

// --------------------------------------------------------- //
// Public:

/// How a parse can fail.
///
/// Note:
/// - UnknownField, MissingField, UnknownEnumValue: the document and the type
///   disagree.
/// - Truncated, Unexpected, BadNumber: the document is not what it claims. Unexpected
///   also covers the same key twice and a value of the wrong shape.
pub const Error = error{
    Jzon_StdParser_UnknownField,
    Jzon_StdParser_MissingField,
    Jzon_StdParser_UnknownEnumValue,
    Jzon_StdParser_Truncated,
    Jzon_StdParser_Unexpected,
    Jzon_StdParser_BadNumber,
    Jzon_StdParser_OutOfMemory,
};

/// Read a value of `Target` out of a whole JSON document.
///
/// Param:
/// Target - type (comptime, the type to build)
/// allocator - Allocator (owns everything the result points at)
/// src - []const u8 (the whole document)
/// options - DeserializeOptions (comptime, how strings are held and what an unknown
///   key does)
///
/// Return:
/// - Target (the parsed value)
/// - Error.Jzon_StdParser_UnknownField, MissingField, UnknownEnumValue when the
///   document and the type disagree
/// - Error.Jzon_StdParser_Truncated, Unexpected, BadNumber when the document is not
///   what it claims
/// - Error.Jzon_StdParser_OutOfMemory when the allocator runs out
pub fn parse(
    comptime Target: type,
    allocator: Allocator,
    src: []const u8,
    comptime options: DeserializeOptions,
) Error!Target {
    const std_options: std.json.ParseOptions = .{
        .ignore_unknown_fields = options.unknown == .SKIP,
        .allocate = switch (options.strings) {
            .COPY => .alloc_always,
            .BORROW => .alloc_if_needed,
        },
    };

    return std.json.parseFromSliceLeaky(Target, allocator, src, std_options) catch |err|
        stdError(err);
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const Nested = struct {
    alpha: i32,
    beta: []const u8,
};

const Status = enum { PENDING, SHIPPED };

const Record = struct {
    id: u64,
    name: []const u8,
    ratio: f64,
    active: bool,
    status: Status,
    note: ?[]const u8 = null,
    tags: []const []const u8,
    nested: Nested,
};

const Pair = struct {
    id: u8,
    name: []const u8,
};

const DOCUMENT =
    "{\"id\":7,\"name\":\"a\\\"b\",\"ratio\":2.5,\"active\":true," ++
    "\"status\":\"SHIPPED\",\"note\":null,\"tags\":[\"one\",\"two\"]," ++
    "\"nested\":{\"alpha\":-3,\"beta\":\"x\"}}";

/// Require `src` read as `Target` with default options to fail with `expected`.
fn expectFails(comptime Target: type, src: []const u8, expected: Error) !void {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectError(expected, parse(Target, arena.allocator(), src, .{}));
}

/// Whether `text` points inside `document`.
fn pointsInto(text: []const u8, document: []const u8) bool {
    return @intFromPtr(text.ptr) >= @intFromPtr(document.ptr) and
        @intFromPtr(text.ptr) < @intFromPtr(document.ptr) + document.len;
}

test "jzon deserialize: std_parser, reads a whole record" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const record = try parse(Record, arena.allocator(), DOCUMENT, .{});

    try std.testing.expectEqual(@as(u64, 7), record.id);
    try std.testing.expectEqualStrings("a\"b", record.name);
    try std.testing.expectEqual(@as(f64, 2.5), record.ratio);
    try std.testing.expect(record.active);
    try std.testing.expectEqual(Status.SHIPPED, record.status);
    try std.testing.expect(record.note == null);
    try std.testing.expectEqual(@as(usize, 2), record.tags.len);
    try std.testing.expectEqualStrings("two", record.tags[1]);
    try std.testing.expectEqual(@as(i32, -3), record.nested.alpha);
}

test "jzon deserialize: std_parser, BORROW points a clean string into the document" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const src = "{\"plain\":\"borrowed\",\"escaped\":\"one\\ttwo\"}";
    const Strings = struct {
        plain: []const u8,
        escaped: []const u8,
    };

    const strings = try parse(Strings, arena.allocator(), src, .{ .strings = .BORROW });

    try std.testing.expect(pointsInto(strings.plain, src));
    try std.testing.expectEqualStrings("one\ttwo", strings.escaped);
}

test "jzon deserialize: std_parser, unknown key is unknown field" {
    try expectFails(
        Pair,
        "{\"id\":1,\"name\":\"x\",\"other\":2}",
        Error.Jzon_StdParser_UnknownField,
    );
}

test "jzon deserialize: std_parser, absent field is missing field" {
    try expectFails(Pair, "{\"id\":1}", Error.Jzon_StdParser_MissingField);
}

test "jzon deserialize: std_parser, name no enum tag carries is unknown enum value" {
    try expectFails(Status, "\"GONE\"", Error.Jzon_StdParser_UnknownEnumValue);
    try expectFails(Status, "\"pending\"", Error.Jzon_StdParser_UnknownEnumValue);
}

test "jzon deserialize: std_parser, SKIP steps over an unknown key" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const src = "{\"id\":1,\"other\":{\"deep\":[1,2,3]},\"name\":\"x\"}";
    const pair = try parse(Pair, arena.allocator(), src, .{ .unknown = .SKIP });

    try std.testing.expectEqual(@as(u8, 1), pair.id);
    try std.testing.expectEqualStrings("x", pair.name);
}

test "jzon deserialize: std_parser, stdError maps every std member" {
    const cases = .{
        .{ error.OutOfMemory, Error.Jzon_StdParser_OutOfMemory },
        .{ error.UnknownField, Error.Jzon_StdParser_UnknownField },
        .{ error.MissingField, Error.Jzon_StdParser_MissingField },
        .{ error.InvalidEnumTag, Error.Jzon_StdParser_UnknownEnumValue },
        .{ error.UnexpectedEndOfInput, Error.Jzon_StdParser_Truncated },
        .{ error.BufferUnderrun, Error.Jzon_StdParser_Truncated },
        .{ error.Overflow, Error.Jzon_StdParser_BadNumber },
        .{ error.InvalidCharacter, Error.Jzon_StdParser_BadNumber },
        .{ error.InvalidNumber, Error.Jzon_StdParser_BadNumber },
        .{ error.SyntaxError, Error.Jzon_StdParser_Unexpected },
        .{ error.UnexpectedToken, Error.Jzon_StdParser_Unexpected },
        .{ error.DuplicateField, Error.Jzon_StdParser_Unexpected },
        .{ error.LengthMismatch, Error.Jzon_StdParser_Unexpected },
        .{ error.ValueTooLong, Error.Jzon_StdParser_Unexpected },
    };

    inline for (cases) |case| {
        try std.testing.expectEqual(case[1], stdError(case[0]));
    }
}

test "jzon deserialize: std_parser, document that ends early is truncated" {
    try expectFails(u8, "", Error.Jzon_StdParser_Truncated);
    try expectFails(Pair, "{", Error.Jzon_StdParser_Truncated);
    try expectFails(Pair, "{\"id\":1,", Error.Jzon_StdParser_Truncated);
}

test "jzon deserialize: std_parser, more than one value is unexpected" {
    try expectFails(u8, "1 2", Error.Jzon_StdParser_Unexpected);
    try expectFails(Pair, "{\"id\":1,\"name\":\"x\"}{}", Error.Jzon_StdParser_Unexpected);
}

test "jzon deserialize: std_parser, same key twice is unexpected" {
    try expectFails(Pair, "{\"id\":1,\"id\":2,\"name\":\"x\"}", Error.Jzon_StdParser_Unexpected);
}

test "jzon deserialize: std_parser, number the field cannot take is bad number" {
    try expectFails(Pair, "{\"id\":300,\"name\":\"x\"}", Error.Jzon_StdParser_BadNumber);
    try expectFails(Pair, "{\"id\":1.5,\"name\":\"x\"}", Error.Jzon_StdParser_BadNumber);
    try expectFails(Pair, "{\"id\":-1,\"name\":\"x\"}", Error.Jzon_StdParser_BadNumber);
}

test "jzon deserialize: std_parser, value of the wrong shape is unexpected" {
    try expectFails(Pair, "{\"id\":null,\"name\":\"x\"}", Error.Jzon_StdParser_Unexpected);
    try expectFails(Pair, "{\"id\":1,\"name\":7}", Error.Jzon_StdParser_Unexpected);
    try expectFails(Pair, "[1,2]", Error.Jzon_StdParser_Unexpected);
}

test "jzon deserialize: std_parser, empty object owing fields is missing field" {
    try expectFails(Pair, "{}", Error.Jzon_StdParser_MissingField);
}

test "jzon deserialize: std_parser, decodes a surrogate pair" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const paired = try parse([]const u8, arena.allocator(), "\"\\ud83d\\udca9\"", .{});

    try std.testing.expectEqualStrings("\xf0\x9f\x92\xa9", paired);
}

test "jzon deserialize: std_parser, broken escape is unexpected" {
    // std reports a broken escape as a syntax error, not as its own kind.
    try expectFails([]const u8, "\"\\ud83d\"", Error.Jzon_StdParser_Unexpected);
    try expectFails([]const u8, "\"\\q\"", Error.Jzon_StdParser_Unexpected);
}

test "jzon deserialize: std_parser, reads the empty string and array" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const Holder = struct {
        text: []const u8,
        items: []const u32,
    };

    const empty = try parse(Holder, arena.allocator(), "{\"text\":\"\",\"items\":[]}", .{});

    try std.testing.expectEqual(@as(usize, 0), empty.text.len);
    try std.testing.expectEqual(@as(usize, 0), empty.items.len);
}

test "jzon deserialize: std_parser, empty object fills a type without fields" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    _ = try parse(struct {}, arena.allocator(), "{}", .{});
}

test "jzon deserialize: std_parser, SKIP steps over a deeply nested unknown value" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const src = "{\"id\":1,\"deep\":[[[{\"a\":{\"b\":[null,true,\"x\"]}}]]],\"name\":\"y\"}";
    const pair = try parse(Pair, arena.allocator(), src, .{ .unknown = .SKIP });

    try std.testing.expectEqual(@as(u8, 1), pair.id);
    try std.testing.expectEqualStrings("y", pair.name);
}

test "jzon deserialize: std_parser, reads the extremes of a width" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    const widest = try parse(u64, allocator, "18446744073709551615", .{});
    const lowest = try parse(i64, allocator, "-9223372036854775808", .{});

    try std.testing.expectEqual(@as(u64, std.math.maxInt(u64)), widest);
    try std.testing.expectEqual(@as(i64, std.math.minInt(i64)), lowest);
}

test "jzon deserialize: std_parser, one past the widest value is bad number" {
    try expectFails(u64, "18446744073709551616", Error.Jzon_StdParser_BadNumber);
}

test "jzon deserialize: std_parser, failure clears a stale field" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const Target = struct { id: u32 };

    Failure.noteField("stale");

    const result = parse(Target, arena.allocator(), "{}", .{});

    try std.testing.expectError(Error.Jzon_StdParser_MissingField, result);
    try std.testing.expectEqualStrings("", Failure.lastFailure().field);
}

test "jzon deserialize: std_parser, failure is recorded as filled at offset zero" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    Failure.reset();

    const result = parse(u32, arena.allocator(), "x", .{});

    try std.testing.expectError(Error.Jzon_StdParser_Unexpected, result);

    const failure = Failure.lastFailure();

    try std.testing.expect(failure.filled);
    try std.testing.expectEqual(@as(usize, 0), failure.offset);
}

