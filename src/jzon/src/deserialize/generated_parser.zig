//! JZON generated_parser
//!
//! ### file: src/jzon/src/deserialize/generated_parser.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! The read path generated from the type: reads a document straight off jzon's own
//! `Cursor`, with the shape of the target type resolved at compile time.
//!
//! ### note:
//!
//! Reads what the generated emitter writes, and refuses at compile time what the
//! emitter refuses. A slice of bytes is a string here and nothing else. This path
//! decodes escapes itself, so a broken one is BadEscape, not Unexpected. Under
//! `.BORROW` a clean string is a slice of the document, so the document has to outlive
//! the value. The width (`ScanShape`) changes cost only: both widths read the same
//! documents and report the same failures.
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
const Cursor = @import("../Cursor.zig");
const DeserializeOptions = @import("DeserializeOptions.zig");
const Failure = @import("Failure.zig");
const ScanShape = @import("ScanShape.zig");
const fields = @import("fields.zig");
const float = @import("../float.zig");
const integer = @import("../integer.zig");
const reflect = @import("../reflect.zig");
const skip = @import("skip.zig");
const string_value = @import("string_value.zig");

const Allocator = std.mem.Allocator;

// --------------------------------------------------------- //
// Private:

/// The cursor, plus what turning a token into a value needs.
const Source = struct {
    allocator: Allocator,
    cursor: *Cursor,
};

/// The string mode a name is read under.
///
/// Note:
/// - A field name and an enum tag name are compared and then dropped, never kept, so
///   borrowing them costs nothing and saves a copy per key. The caller's mode governs
///   the strings that end up in the result.
const NAME_OPTIONS: DeserializeOptions = .{ .strings = .BORROW };

/// Translate a `Cursor` failure into this module's set.
///
/// Param:
/// err - Cursor.Error (the failure the cursor reported)
///
/// Return:
/// - Error (the same failure under this module's name)
fn cursorError(err: Cursor.Error) Error {
    return switch (err) {
        error.Jzon_Cursor_Truncated => Error.Jzon_GeneratedParser_Truncated,
        error.Jzon_Cursor_Unexpected => Error.Jzon_GeneratedParser_Unexpected,
    };
}

/// Translate a `ScanShape` failure into this module's set.
///
/// Param:
/// err - ScanShape.Error (the failure the width-picked scan reported)
///
/// Return:
/// - Error (the same failure under this module's name)
fn scanShapeError(err: ScanShape.Error) Error {
    return switch (err) {
        error.Jzon_ScanShape_Truncated => Error.Jzon_GeneratedParser_Truncated,
        error.Jzon_ScanShape_Unexpected => Error.Jzon_GeneratedParser_Unexpected,
    };
}

/// Translate an `integer` failure into this module's set.
///
/// Param:
/// err - integer.Error (the failure the integer reader reported)
///
/// Return:
/// - Error (the same failure under this module's name)
fn integerError(err: integer.Error) Error {
    return switch (err) {
        error.Jzon_Integer_NoSpaceLeft => Error.Jzon_GeneratedParser_NoSpaceLeft,
        error.Jzon_Integer_BadNumber => Error.Jzon_GeneratedParser_BadNumber,
    };
}

/// Translate a `float` failure into this module's set.
///
/// Param:
/// err - float.Error (the failure the float reader reported)
///
/// Return:
/// - Error (the same failure under this module's name)
fn floatError(err: float.Error) Error {
    return switch (err) {
        error.Jzon_Float_NoSpaceLeft => Error.Jzon_GeneratedParser_NoSpaceLeft,
        error.Jzon_Float_BadNumber => Error.Jzon_GeneratedParser_BadNumber,
    };
}

/// Translate a `fields` failure into this module's set.
///
/// Param:
/// err - fields.Error (the failure the field bookkeeping reported)
///
/// Return:
/// - Error (the same failure under this module's name)
fn fieldsError(err: fields.Error) Error {
    return switch (err) {
        error.Jzon_Fields_Unexpected => Error.Jzon_GeneratedParser_Unexpected,
        error.Jzon_Fields_MissingField => Error.Jzon_GeneratedParser_MissingField,
    };
}

/// Translate a `skip` failure into this module's set.
///
/// Param:
/// err - skip.Error (the failure the value walk reported)
///
/// Return:
/// - Error (the same failure under this module's name)
fn skipError(err: skip.Error) Error {
    return switch (err) {
        error.Jzon_Skip_Truncated => Error.Jzon_GeneratedParser_Truncated,
        error.Jzon_Skip_Unexpected => Error.Jzon_GeneratedParser_Unexpected,
    };
}

/// Translate a `string_value` failure into this module's set.
///
/// Param:
/// err - string_value.Error (the failure taking a string reported)
///
/// Return:
/// - Error (the same failure under this module's name)
fn stringValueError(err: string_value.Error) Error {
    return switch (err) {
        error.Jzon_StringValue_BadEscape => Error.Jzon_GeneratedParser_BadEscape,
        error.Jzon_StringValue_NoSpaceLeft => Error.Jzon_GeneratedParser_NoSpaceLeft,
        error.Jzon_StringValue_OutOfMemory => Error.Jzon_GeneratedParser_OutOfMemory,
    };
}

/// Require `wanted` as the next byte and step past it.
///
/// Param:
/// cursor - *Cursor (the cursor to advance)
/// wanted - u8 (the byte the grammar needs here)
///
/// Return:
/// - void
/// - Error.Jzon_GeneratedParser_Truncated or Unexpected when it is not there
fn expectByte(cursor: *Cursor, wanted: u8) Error!void {
    cursor.expect(wanted) catch |err| return cursorError(err);
}

/// The next byte, without taking it.
///
/// Param:
/// cursor - *Cursor (the cursor to look at)
///
/// Return:
/// - u8 (the byte under the cursor)
/// - Error.Jzon_GeneratedParser_Truncated when the document has ended
fn peekByte(cursor: *Cursor) Error!u8 {
    return cursor.peek() catch |err| cursorError(err);
}

/// Require one literal word (`true`, `false`, `null`) and step past it.
///
/// Param:
/// cursor - *Cursor (the cursor to advance)
/// text - []const u8 (comptime, the word)
///
/// Return:
/// - void
/// - Error.Jzon_GeneratedParser_Truncated or Unexpected when it is not there
fn literal(cursor: *Cursor, comptime text: []const u8) Error!void {
    cursor.literal(text) catch |err| return cursorError(err);
}

/// Step over whitespace, then bound the number token that follows.
///
/// Param:
/// cursor - *Cursor (the cursor to advance)
/// shape - ScanShape (comptime, which width to scan at)
///
/// Return:
/// - []const u8 (the number token's bytes, unchecked)
/// - Error.Jzon_GeneratedParser_Truncated or Unexpected when no number starts here
fn numberText(cursor: *Cursor, comptime shape: ScanShape) Error![]const u8 {
    shape.skipSpace(cursor);

    return cursor.numberSpan() catch |err| cursorError(err);
}

/// Step over whitespace, then read a string token as a value.
///
/// Param:
/// source - Source (the cursor and its allocator)
/// shape - ScanShape (comptime, which width to scan at)
/// options - DeserializeOptions (comptime, the string mode to take it under)
///
/// Return:
/// - []const u8 (the string's value)
/// - Error (a broken token, a bad escape, or out of memory)
fn stringToken(
    source: Source,
    comptime shape: ScanShape,
    comptime options: DeserializeOptions,
) Error![]const u8 {
    shape.skipSpace(source.cursor);

    const span = shape.stringSpan(source.cursor) catch |err| return scanShapeError(err);

    return string_value.take(source.allocator, span, options) catch |err|
        stringValueError(err);
}

/// Read one value of `Target`, whatever shape the type is.
///
/// Param:
/// Target - type (comptime, the type to build)
/// source - Source (the cursor and its allocator)
/// options - DeserializeOptions (comptime, string mode and unknown key rule)
/// shape - ScanShape (comptime, which width to scan at)
///
/// Return:
/// - Target (the value)
/// - Error (any failure of the token or the field it lands in)
fn readValue(
    comptime Target: type,
    source: Source,
    comptime options: DeserializeOptions,
    comptime shape: ScanShape,
) Error!Target {
    switch (@typeInfo(Target)) {
        .bool => return readBool(source.cursor, shape),

        .int => {
            const text = try numberText(source.cursor, shape);

            return integer.parse(Target, text) catch |err| integerError(err);
        },

        .float => {
            const text = try numberText(source.cursor, shape);

            return float.parse(Target, text) catch |err| floatError(err);
        },

        .optional => |info| {
            shape.skipSpace(source.cursor);

            if ((try peekByte(source.cursor)) == 'n') {
                try literal(source.cursor, "null");

                return null;
            }

            return try readValue(info.child, source, options, shape);
        },

        .@"enum" => {
            if (!reflect.isExhaustive(Target)) @compileError(
                "jzon generated parser: " ++ @typeName(Target) ++
                    " is non-exhaustive, so a name cannot cover every value it carries",
            );

            return readEnum(Target, source, shape);
        },

        .@"struct" => |info| {
            if (info.is_tuple) @compileError(
                "jzon generated parser: " ++ @typeName(Target) ++
                    " is a tuple, which has no object form",
            );

            return readStruct(Target, source, options, shape);
        },

        .pointer => |info| {
            if (info.size != .slice) @compileError(
                "jzon generated parser: " ++ @typeName(Target) ++
                    " is not a slice, so it has no JSON form",
            );

            if (info.child == u8) return readString(Target, source, options, shape);

            return readSlice(Target, source, options, shape);
        },

        else => @compileError(
            "jzon generated parser: " ++ @typeName(Target) ++ " has no JSON form",
        ),
    }
}

/// Read one of the two boolean words.
///
/// Param:
/// cursor - *Cursor (the cursor to advance)
/// shape - ScanShape (comptime, which width to scan at)
///
/// Return:
/// - bool (the value)
/// - Error.Jzon_GeneratedParser_Unexpected when the token is not `true` or `false`
fn readBool(cursor: *Cursor, comptime shape: ScanShape) Error!bool {
    shape.skipSpace(cursor);

    switch (try peekByte(cursor)) {
        't' => {
            try literal(cursor, "true");

            return true;
        },

        'f' => {
            try literal(cursor, "false");

            return false;
        },

        else => return Error.Jzon_GeneratedParser_Unexpected,
    }
}

/// Read a string holding one of an enum's tag names.
///
/// Param:
/// Target - type (comptime, the exhaustive enum)
/// source - Source (the cursor and its allocator)
/// shape - ScanShape (comptime, which width to scan at)
///
/// Return:
/// - Target (the tag)
/// - Error.Jzon_GeneratedParser_UnknownEnumValue when no tag carries that name
fn readEnum(comptime Target: type, source: Source, comptime shape: ScanShape) Error!Target {
    const name = try stringToken(source, shape, NAME_OPTIONS);

    return std.meta.stringToEnum(Target, name) orelse {
        Failure.noteField(name);

        return Error.Jzon_GeneratedParser_UnknownEnumValue;
    };
}

/// Read a struct as a JSON object, matching each key against a field name.
///
/// Param:
/// Target - type (comptime, the struct to build)
/// source - Source (the cursor and its allocator)
/// options - DeserializeOptions (comptime, string mode and unknown key rule)
/// shape - ScanShape (comptime, which width to scan at)
///
/// Return:
/// - Target (the struct)
/// - Error (a bad key, a bad value, or a field the document owed)
fn readStruct(
    comptime Target: type,
    source: Source,
    comptime options: DeserializeOptions,
    comptime shape: ScanShape,
) Error!Target {
    const cursor = source.cursor;

    shape.skipSpace(cursor);
    try expectByte(cursor, '{');

    var result: Target = undefined;
    var seen: fields.Seen(Target) = .{};

    shape.skipSpace(cursor);

    if (!cursor.accept('}')) {
        while (true) {
            const key = try stringToken(source, shape, NAME_OPTIONS);

            shape.skipSpace(cursor);
            try expectByte(cursor, ':');

            try readField(Target, &result, &seen, key, source, options, shape);

            shape.skipSpace(cursor);
            if (cursor.accept(',')) continue;

            try expectByte(cursor, '}');
            break;
        }
    }

    seen.fill(&result) catch |err| return fieldsError(err);

    return result;
}

/// Read the value behind one object key into the field that key names.
///
/// Note:
/// - The match is unrolled over the field names at compile time, so a key costs one
///   comparison per field and no lookup structure is built for it.
///
/// Param:
/// Target - type (comptime, the struct being built)
/// result - *Target (the struct being built)
/// seen - *fields.Seen(Target) (which fields are already read)
/// key - []const u8 (the object key just read)
/// source - Source (the cursor and its allocator)
/// options - DeserializeOptions (comptime, string mode and unknown key rule)
/// shape - ScanShape (comptime, which width to scan at)
///
/// Return:
/// - void
/// - Error.Jzon_GeneratedParser_UnknownField when the key names no field under
///   `.REJECT`
fn readField(
    comptime Target: type,
    result: *Target,
    seen: *fields.Seen(Target),
    key: []const u8,
    source: Source,
    comptime options: DeserializeOptions,
    comptime shape: ScanShape,
) Error!void {
    inline for (comptime std.meta.fieldNames(Target), 0..) |name, index| {
        if (std.mem.eql(u8, name, key)) {
            seen.mark(index) catch |err| return fieldsError(err);

            const Field = @FieldType(Target, name);
            @field(result, name) = try readValue(Field, source, options, shape);

            return;
        }
    }

    switch (options.unknown) {
        .REJECT => {
            Failure.noteFieldAt(key, source.cursor.pos);

            return Error.Jzon_GeneratedParser_UnknownField;
        },
        .SKIP => skip.value(source.cursor, shape) catch |err| return skipError(err),
    }
}

/// Read a slice as a JSON array, one element at a time.
///
/// Param:
/// Target - type (comptime, a plain slice type)
/// source - Source (the cursor and its allocator)
/// options - DeserializeOptions (comptime, string mode and unknown key rule)
/// shape - ScanShape (comptime, which width to scan at)
///
/// Return:
/// - Target (the slice, owned by the allocator)
/// - Error (a bad element, or Error.Jzon_GeneratedParser_OutOfMemory)
fn readSlice(
    comptime Target: type,
    source: Source,
    comptime options: DeserializeOptions,
    comptime shape: ScanShape,
) Error!Target {
    const Element = @typeInfo(Target).pointer.child;

    if (Target != []const Element and Target != []Element) @compileError(
        "jzon generated parser: " ++ @typeName(Target) ++
            " is not a plain slice, so a parse cannot produce it",
    );

    const cursor = source.cursor;

    shape.skipSpace(cursor);
    try expectByte(cursor, '[');

    var elements: std.ArrayList(Element) = .empty;

    shape.skipSpace(cursor);

    if (!cursor.accept(']')) {
        while (true) {
            const element = try readValue(Element, source, options, shape);

            elements.append(source.allocator, element) catch |err| switch (err) {
                error.OutOfMemory => return Error.Jzon_GeneratedParser_OutOfMemory,
            };

            shape.skipSpace(cursor);
            if (cursor.accept(',')) continue;

            try expectByte(cursor, ']');
            break;
        }
    }

    return elements.toOwnedSlice(source.allocator) catch |err| switch (err) {
        error.OutOfMemory => Error.Jzon_GeneratedParser_OutOfMemory,
    };
}

/// Read a string into the one slice type a parse can produce.
///
/// Param:
/// Target - type (comptime, must be `[]const u8`)
/// source - Source (the cursor and its allocator)
/// options - DeserializeOptions (comptime, string mode)
/// shape - ScanShape (comptime, which width to scan at)
///
/// Return:
/// - Target (the string)
/// - Error (a broken token, a bad escape, or out of memory)
fn readString(
    comptime Target: type,
    source: Source,
    comptime options: DeserializeOptions,
    comptime shape: ScanShape,
) Error!Target {
    if (Target != []const u8) @compileError(
        "jzon generated parser: " ++ @typeName(Target) ++
            " is not []const u8, the only string form a parse produces",
    );

    return stringToken(source, shape, options);
}

// --------------------------------------------------------- //
// Public:

/// How a parse can fail.
///
/// Note:
/// - UnknownField, MissingField, UnknownEnumValue: the document and the type
///   disagree. They also record the field name for `lastFailure`.
/// - Truncated, Unexpected, BadNumber, BadEscape: the document is not what it claims.
///   The cursor records the stop byte for Truncated and Unexpected.
/// - NoSpaceLeft exists so every member of the inner sets maps to a real member here.
///   A read never returns it.
pub const Error = error{
    Jzon_GeneratedParser_UnknownField,
    Jzon_GeneratedParser_MissingField,
    Jzon_GeneratedParser_UnknownEnumValue,
    Jzon_GeneratedParser_Truncated,
    Jzon_GeneratedParser_Unexpected,
    Jzon_GeneratedParser_BadNumber,
    Jzon_GeneratedParser_BadEscape,
    Jzon_GeneratedParser_NoSpaceLeft,
    Jzon_GeneratedParser_OutOfMemory,
};

/// Read a value of `Target` out of a whole JSON document.
///
/// Note:
/// - The document has to hold one value and nothing after it, so trailing bytes are a
///   failure, not something left unread.
///
/// Param:
/// Target - type (comptime, the type to build)
/// allocator - Allocator (owns everything the result points at)
/// src - []const u8 (the whole document)
/// options - DeserializeOptions (comptime, how strings are held and what an unknown
///   key does)
/// shape - ScanShape (comptime, which width to scan at)
///
/// Return:
/// - Target (the parsed value)
/// - Error.Jzon_GeneratedParser_UnknownField, MissingField, UnknownEnumValue when the
///   document and the type disagree
/// - Error.Jzon_GeneratedParser_Truncated, Unexpected, BadNumber, BadEscape when the
///   document is not what it claims
/// - Error.Jzon_GeneratedParser_OutOfMemory when the allocator runs out
pub fn parse(
    comptime Target: type,
    allocator: Allocator,
    src: []const u8,
    comptime options: DeserializeOptions,
    comptime shape: ScanShape,
) Error!Target {
    var cursor: Cursor = .init(src);

    const source: Source = .{
        .allocator = allocator,
        .cursor = &cursor,
    };

    const value = try readValue(Target, source, options, shape);

    shape.skipSpace(&cursor);
    if (!cursor.atEnd()) return Error.Jzon_GeneratedParser_Unexpected;

    return value;
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const scanner_parser = @import("scanner_parser.zig");
const std_parser = @import("std_parser.zig");

/// Both widths, so a case can check the pair agrees.
const SHAPES = [_]ScanShape{
    .{ .scan = .SCALAR },
    .{ .scan = .VECTOR },
};

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

/// Require `src` read as `Target` to fail with `expected` at both widths.
fn expectFails(comptime Target: type, src: []const u8, expected: Error) !void {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    inline for (SHAPES) |shape| {
        try std.testing.expectError(
            expected,
            parse(Target, arena.allocator(), src, .{}, shape),
        );
    }
}

/// Whether `text` points inside `document`.
fn pointsInto(text: []const u8, document: []const u8) bool {
    return @intFromPtr(text.ptr) >= @intFromPtr(document.ptr) and
        @intFromPtr(text.ptr) < @intFromPtr(document.ptr) + document.len;
}

test "jzon deserialize: generated_parser, reads a whole record at both widths" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    inline for (SHAPES) |shape| {
        const record = try parse(Record, arena.allocator(), DOCUMENT, .{}, shape);

        try std.testing.expectEqual(@as(u64, 7), record.id);
        try std.testing.expectEqualStrings("a\"b", record.name);
        try std.testing.expectEqual(@as(f64, 2.5), record.ratio);
        try std.testing.expect(record.active);
        try std.testing.expectEqual(Status.SHIPPED, record.status);
        try std.testing.expect(record.note == null);
        try std.testing.expectEqual(@as(usize, 2), record.tags.len);
        try std.testing.expectEqualStrings("one", record.tags[0]);
        try std.testing.expectEqualStrings("x", record.nested.beta);
    }
}

test "jzon deserialize: generated_parser, reads the same record the scanner path reads" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    const theirs = try scanner_parser.parse(Record, allocator, DOCUMENT, .{});

    inline for (SHAPES) |shape| {
        const ours = try parse(Record, allocator, DOCUMENT, .{}, shape);

        try std.testing.expectEqual(theirs.id, ours.id);
        try std.testing.expectEqualStrings(theirs.name, ours.name);
        try std.testing.expectEqual(theirs.ratio, ours.ratio);
        try std.testing.expectEqual(theirs.status, ours.status);
        try std.testing.expectEqualStrings(theirs.tags[1], ours.tags[1]);
        try std.testing.expectEqual(theirs.nested.alpha, ours.nested.alpha);
    }
}

test "jzon deserialize: generated_parser, unknown key is unknown field" {
    try expectFails(
        Pair,
        "{\"id\":1,\"name\":\"x\",\"other\":2}",
        Error.Jzon_GeneratedParser_UnknownField,
    );
}

test "jzon deserialize: generated_parser, unknown key records its name and byte" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const src = "{\"id\":1,\"other\":2}";

    inline for (SHAPES) |shape| {
        Failure.reset();

        try std.testing.expectError(
            Error.Jzon_GeneratedParser_UnknownField,
            parse(Pair, arena.allocator(), src, .{}, shape),
        );

        const failure = Failure.lastFailure();

        try std.testing.expectEqualStrings("other", failure.field);
        try std.testing.expectEqual(@as(usize, 16), failure.offset);
    }
}

test "jzon deserialize: generated_parser, absent field is missing field" {
    try expectFails(Pair, "{\"id\":1}", Error.Jzon_GeneratedParser_MissingField);
}

test "jzon deserialize: generated_parser, SKIP steps over an unknown key" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const src = "{\"id\":1,\"other\":{\"deep\":[1,2,3]},\"name\":\"x\"}";

    inline for (SHAPES) |shape| {
        const pair = try parse(Pair, arena.allocator(), src, .{ .unknown = .SKIP }, shape);

        try std.testing.expectEqual(@as(u8, 1), pair.id);
        try std.testing.expectEqualStrings("x", pair.name);
    }
}

test "jzon deserialize: generated_parser, BORROW points a clean string into the document" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const src = "{\"plain\":\"borrowed\",\"escaped\":\"one\\ttwo\"}";
    const Strings = struct {
        plain: []const u8,
        escaped: []const u8,
    };

    inline for (SHAPES) |shape| {
        const borrowed = try parse(Strings, arena.allocator(), src, .{
            .strings = .BORROW,
        }, shape);

        try std.testing.expect(pointsInto(borrowed.plain, src));
        try std.testing.expectEqualStrings("one\ttwo", borrowed.escaped);
    }
}

test "jzon deserialize: generated_parser, COPY keeps a clean string out of the document" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const src = "{\"alpha\":1,\"beta\":\"copied\"}";

    inline for (SHAPES) |shape| {
        const copied = try parse(Nested, arena.allocator(), src, .{ .strings = .COPY }, shape);

        try std.testing.expect(!pointsInto(copied.beta, src));
        try std.testing.expectEqualStrings("copied", copied.beta);
    }
}

test "jzon deserialize: generated_parser, reads a document laid out with whitespace" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const src =
        \\  {
        \\    "id"   : 9 ,
        \\    "name" : "spaced out"
        \\  }
    ;

    inline for (SHAPES) |shape| {
        const pair = try parse(Pair, arena.allocator(), src, .{}, shape);

        try std.testing.expectEqual(@as(u8, 9), pair.id);
        try std.testing.expectEqualStrings("spaced out", pair.name);
    }
}

test "jzon deserialize: generated_parser, cursorError maps every cursor member" {
    const truncated = cursorError(error.Jzon_Cursor_Truncated);
    const unexpected = cursorError(error.Jzon_Cursor_Unexpected);

    try std.testing.expectEqual(Error.Jzon_GeneratedParser_Truncated, truncated);
    try std.testing.expectEqual(Error.Jzon_GeneratedParser_Unexpected, unexpected);
}

test "jzon deserialize: generated_parser, scanShapeError maps every scan member" {
    const truncated = scanShapeError(error.Jzon_ScanShape_Truncated);
    const unexpected = scanShapeError(error.Jzon_ScanShape_Unexpected);

    try std.testing.expectEqual(Error.Jzon_GeneratedParser_Truncated, truncated);
    try std.testing.expectEqual(Error.Jzon_GeneratedParser_Unexpected, unexpected);
}

test "jzon deserialize: generated_parser, integerError maps every integer member" {
    const no_space = integerError(error.Jzon_Integer_NoSpaceLeft);
    const bad_number = integerError(error.Jzon_Integer_BadNumber);

    try std.testing.expectEqual(Error.Jzon_GeneratedParser_NoSpaceLeft, no_space);
    try std.testing.expectEqual(Error.Jzon_GeneratedParser_BadNumber, bad_number);
}

test "jzon deserialize: generated_parser, floatError maps every float member" {
    const no_space = floatError(error.Jzon_Float_NoSpaceLeft);
    const bad_number = floatError(error.Jzon_Float_BadNumber);

    try std.testing.expectEqual(Error.Jzon_GeneratedParser_NoSpaceLeft, no_space);
    try std.testing.expectEqual(Error.Jzon_GeneratedParser_BadNumber, bad_number);
}

test "jzon deserialize: generated_parser, fieldsError maps every fields member" {
    const unexpected = fieldsError(error.Jzon_Fields_Unexpected);
    const missing = fieldsError(error.Jzon_Fields_MissingField);

    try std.testing.expectEqual(Error.Jzon_GeneratedParser_Unexpected, unexpected);
    try std.testing.expectEqual(Error.Jzon_GeneratedParser_MissingField, missing);
}

test "jzon deserialize: generated_parser, skipError maps every skip member" {
    const truncated = skipError(error.Jzon_Skip_Truncated);
    const unexpected = skipError(error.Jzon_Skip_Unexpected);

    try std.testing.expectEqual(Error.Jzon_GeneratedParser_Truncated, truncated);
    try std.testing.expectEqual(Error.Jzon_GeneratedParser_Unexpected, unexpected);
}

test "jzon deserialize: generated_parser, stringValueError maps every string member" {
    const bad_escape = stringValueError(error.Jzon_StringValue_BadEscape);
    const no_space = stringValueError(error.Jzon_StringValue_NoSpaceLeft);
    const no_memory = stringValueError(error.Jzon_StringValue_OutOfMemory);

    try std.testing.expectEqual(Error.Jzon_GeneratedParser_BadEscape, bad_escape);
    try std.testing.expectEqual(Error.Jzon_GeneratedParser_NoSpaceLeft, no_space);
    try std.testing.expectEqual(Error.Jzon_GeneratedParser_OutOfMemory, no_memory);
}

test "jzon deserialize: generated_parser, document that ends early is truncated" {
    try expectFails(u8, "", Error.Jzon_GeneratedParser_Truncated);
    try expectFails(Pair, "{", Error.Jzon_GeneratedParser_Truncated);
    try expectFails(Pair, "{\"id\"", Error.Jzon_GeneratedParser_Truncated);
    try expectFails(Pair, "{\"id\":", Error.Jzon_GeneratedParser_Truncated);
    try expectFails(Pair, "{\"id\":1,", Error.Jzon_GeneratedParser_Truncated);
    try expectFails([]const u32, "[1,2", Error.Jzon_GeneratedParser_Truncated);
    try expectFails([]const u8, "\"unterminated", Error.Jzon_GeneratedParser_Truncated);
    try expectFails(bool, "tru", Error.Jzon_GeneratedParser_Truncated);
}

test "jzon deserialize: generated_parser, more than one value is unexpected" {
    try expectFails(u8, "1 2", Error.Jzon_GeneratedParser_Unexpected);
    try expectFails(Pair, "{\"id\":1,\"name\":\"x\"}{}", Error.Jzon_GeneratedParser_Unexpected);
    try expectFails([]const u32, "[1][2]", Error.Jzon_GeneratedParser_Unexpected);
}

test "jzon deserialize: generated_parser, same key twice is unexpected" {
    try expectFails(
        Pair,
        "{\"id\":1,\"id\":2,\"name\":\"x\"}",
        Error.Jzon_GeneratedParser_Unexpected,
    );
}

test "jzon deserialize: generated_parser, number the field cannot take is bad number" {
    try expectFails(Pair, "{\"id\":300,\"name\":\"x\"}", Error.Jzon_GeneratedParser_BadNumber);
    try expectFails(Pair, "{\"id\":1.5,\"name\":\"x\"}", Error.Jzon_GeneratedParser_BadNumber);
    try expectFails(Pair, "{\"id\":-1,\"name\":\"x\"}", Error.Jzon_GeneratedParser_BadNumber);
    try expectFails(u64, "18446744073709551616", Error.Jzon_GeneratedParser_BadNumber);
    try expectFails(f64, "1.2.3", Error.Jzon_GeneratedParser_BadNumber);
}

test "jzon deserialize: generated_parser, value of the wrong shape is unexpected" {
    try expectFails(Pair, "{\"id\":null,\"name\":\"x\"}", Error.Jzon_GeneratedParser_Unexpected);
    try expectFails(Pair, "{\"id\":1,\"name\":7}", Error.Jzon_GeneratedParser_Unexpected);
    try expectFails(Pair, "[1,2]", Error.Jzon_GeneratedParser_Unexpected);
    try expectFails([]const u32, "{}", Error.Jzon_GeneratedParser_Unexpected);
    try expectFails(bool, "\"true\"", Error.Jzon_GeneratedParser_Unexpected);
}

test "jzon deserialize: generated_parser, trailing comma is unexpected" {
    try expectFails(Pair, "{\"id\":1,\"name\":\"x\",}", Error.Jzon_GeneratedParser_Unexpected);
    try expectFails([]const u32, "[1,2,]", Error.Jzon_GeneratedParser_Unexpected);
}

test "jzon deserialize: generated_parser, object owing a field is missing field" {
    try expectFails(Pair, "{}", Error.Jzon_GeneratedParser_MissingField);
}

test "jzon deserialize: generated_parser, name no enum tag carries is unknown enum value" {
    try expectFails(Status, "\"GONE\"", Error.Jzon_GeneratedParser_UnknownEnumValue);
    try expectFails(Status, "\"pending\"", Error.Jzon_GeneratedParser_UnknownEnumValue);
    try expectFails(Status, "\"\"", Error.Jzon_GeneratedParser_UnknownEnumValue);
}

test "jzon deserialize: generated_parser, reads the empty string and array" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const Holder = struct {
        text: []const u8,
        items: []const u32,
    };
    const src = "{\"text\":\"\",\"items\":[]}";

    inline for (SHAPES) |shape| {
        const empty = try parse(Holder, arena.allocator(), src, .{}, shape);

        try std.testing.expectEqual(@as(usize, 0), empty.text.len);
        try std.testing.expectEqual(@as(usize, 0), empty.items.len);
    }
}

test "jzon deserialize: generated_parser, empty object fills a type without fields" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    inline for (SHAPES) |shape| {
        _ = try parse(struct {}, arena.allocator(), "{}", .{}, shape);
    }
}

test "jzon deserialize: generated_parser, reads the extremes of a width" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    inline for (SHAPES) |shape| {
        const widest = try parse(u64, allocator, "18446744073709551615", .{}, shape);
        const lowest = try parse(i64, allocator, "-9223372036854775808", .{}, shape);

        try std.testing.expectEqual(@as(u64, std.math.maxInt(u64)), widest);
        try std.testing.expectEqual(@as(i64, std.math.minInt(i64)), lowest);
    }
}

test "jzon deserialize: generated_parser, reads a nested slice of slices" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    inline for (SHAPES) |shape| {
        const grid = try parse(
            []const []const u32,
            arena.allocator(),
            "[[1,2],[],[3]]",
            .{},
            shape,
        );

        try std.testing.expectEqual(@as(usize, 3), grid.len);
        try std.testing.expectEqual(@as(u32, 2), grid[0][1]);
        try std.testing.expectEqual(@as(usize, 0), grid[1].len);
        try std.testing.expectEqual(@as(u32, 3), grid[2][0]);
    }
}

test "jzon deserialize: generated_parser, decodes a surrogate pair" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    inline for (SHAPES) |shape| {
        const src = "\"\\ud83d\\udca9\"";
        const paired = try parse([]const u8, arena.allocator(), src, .{}, shape);

        try std.testing.expectEqualStrings("\xf0\x9f\x92\xa9", paired);
    }
}

test "jzon deserialize: generated_parser, broken escape is bad escape" {
    // This path decodes escapes itself, so it can say which of the two went wrong. The
    // scanner path leaves that to std, which calls a broken escape a syntax error.
    try expectFails([]const u8, "\"\\ud83d\"", Error.Jzon_GeneratedParser_BadEscape);
    try expectFails([]const u8, "\"\\q\"", Error.Jzon_GeneratedParser_BadEscape);
}

test "jzon deserialize: generated_parser, array of numbers for a byte slice is unexpected" {
    // A slice of bytes is a string and nothing else here. std also fills one from an
    // array of numbers, which is why the same type reads there and fails here.
    try expectFails([]const u8, "[104,105]", Error.Jzon_GeneratedParser_Unexpected);

    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const theirs = try std_parser.parse([]const u8, arena.allocator(), "[104,105]", .{});

    try std.testing.expectEqualStrings("hi", theirs);
}

test "jzon deserialize: generated_parser, signed zero in an unsigned field is bad number" {
    // A sign against an unsigned field is a type error whatever the digits after it.
    try expectFails(Pair, "{\"id\":-0,\"name\":\"x\"}", Error.Jzon_GeneratedParser_BadNumber);
}

test "jzon deserialize: generated_parser, SKIP steps over a deeply nested unknown value" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const src = "{\"id\":1,\"deep\":[[[{\"a\":{\"b\":[null,true,\"x\"]}}]]],\"name\":\"y\"}";

    inline for (SHAPES) |shape| {
        const pair = try parse(Pair, arena.allocator(), src, .{ .unknown = .SKIP }, shape);

        try std.testing.expectEqual(@as(u8, 1), pair.id);
        try std.testing.expectEqualStrings("y", pair.name);
    }
}

test "jzon deserialize: generated_parser, malformed value SKIP steps over is unexpected" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const src = "{\"id\":1,\"other\":[1,,2],\"name\":\"x\"}";

    inline for (SHAPES) |shape| {
        try std.testing.expectError(
            Error.Jzon_GeneratedParser_Unexpected,
            parse(Pair, arena.allocator(), src, .{ .unknown = .SKIP }, shape),
        );
    }
}

test "jzon deserialize: generated_parser, empty allocator is out of memory" {
    var failing: std.testing.FailingAllocator = .init(std.testing.allocator, .{
        .fail_index = 0,
    });

    inline for (SHAPES) |shape| {
        try std.testing.expectError(
            Error.Jzon_GeneratedParser_OutOfMemory,
            parse(Pair, failing.allocator(), "{\"id\":1,\"name\":\"x\"}", .{}, shape),
        );
    }
}

