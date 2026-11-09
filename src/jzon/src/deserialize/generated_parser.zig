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

/// Every failure a private function here can hand back: this module's own set joined
/// with the sets of the modules it reads through.
///
/// Note:
/// - Private on purpose. Inside the module every call uses `try`, and `parse`
///   translates once on the way out, so no call site on the hot path carries its own
///   translation.
const Inner = Error || Cursor.Error || ScanShape.Error || integer.Error || float.Error ||
    fields.Error || skip.Error || string_value.Error;

/// Translate a failure from inside the module into this module's public set.
///
/// Param:
/// err - Inner (the failure a private function handed back)
///
/// Return:
/// - Inner (the same failure under this module's name)
inline fn innerError(err: Inner) Error {
    @branchHint(.cold);

    return switch (err) {
        error.Jzon_GeneratedParser_UnknownField => Error.Jzon_GeneratedParser_UnknownField,
        error.Jzon_GeneratedParser_MissingField => Error.Jzon_GeneratedParser_MissingField,
        error.Jzon_GeneratedParser_UnknownEnumValue,
        => Error.Jzon_GeneratedParser_UnknownEnumValue,
        error.Jzon_GeneratedParser_Truncated => Error.Jzon_GeneratedParser_Truncated,
        error.Jzon_GeneratedParser_Unexpected => Error.Jzon_GeneratedParser_Unexpected,
        error.Jzon_GeneratedParser_BadNumber => Error.Jzon_GeneratedParser_BadNumber,
        error.Jzon_GeneratedParser_BadEscape => Error.Jzon_GeneratedParser_BadEscape,
        error.Jzon_GeneratedParser_NoSpaceLeft => Error.Jzon_GeneratedParser_NoSpaceLeft,
        error.Jzon_GeneratedParser_OutOfMemory => Error.Jzon_GeneratedParser_OutOfMemory,
        error.Jzon_Cursor_Truncated => Error.Jzon_GeneratedParser_Truncated,
        error.Jzon_Cursor_Unexpected => Error.Jzon_GeneratedParser_Unexpected,
        error.Jzon_ScanShape_Truncated => Error.Jzon_GeneratedParser_Truncated,
        error.Jzon_ScanShape_Unexpected => Error.Jzon_GeneratedParser_Unexpected,
        error.Jzon_Integer_NoSpaceLeft => Error.Jzon_GeneratedParser_NoSpaceLeft,
        error.Jzon_Integer_BadNumber => Error.Jzon_GeneratedParser_BadNumber,
        error.Jzon_Float_NoSpaceLeft => Error.Jzon_GeneratedParser_NoSpaceLeft,
        error.Jzon_Float_BadNumber => Error.Jzon_GeneratedParser_BadNumber,
        error.Jzon_Fields_Unexpected => Error.Jzon_GeneratedParser_Unexpected,
        error.Jzon_Fields_MissingField => Error.Jzon_GeneratedParser_MissingField,
        error.Jzon_Skip_Truncated => Error.Jzon_GeneratedParser_Truncated,
        error.Jzon_Skip_Unexpected => Error.Jzon_GeneratedParser_Unexpected,
        error.Jzon_StringValue_BadEscape => Error.Jzon_GeneratedParser_BadEscape,
        error.Jzon_StringValue_NoSpaceLeft => Error.Jzon_GeneratedParser_NoSpaceLeft,
        error.Jzon_StringValue_OutOfMemory => Error.Jzon_GeneratedParser_OutOfMemory,
    };
}

/// Step over whitespace, then bound the number token that follows.
///
/// Param:
/// cursor - *Cursor (the cursor to advance)
/// shape - ScanShape (comptime, which width to scan at)
///
/// Return:
/// - []const u8 (the number token's bytes, unchecked)
/// - Inner (a cursor failure, untranslated) when no number starts here
inline fn numberText(cursor: *Cursor, comptime shape: ScanShape) Inner![]const u8 {
    shape.skipSpace(cursor);

    return cursor.numberSpan();
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
/// - Inner (a broken token, a bad escape, or out of memory)
inline fn stringToken(
    source: Source,
    comptime shape: ScanShape,
    comptime options: DeserializeOptions,
) Inner![]const u8 {
    shape.skipSpace(source.cursor);

    const span = try shape.stringSpan(source.cursor);

    return string_value.take(source.allocator, span, options);
}

/// Read one value of `Target`, whatever shape the type is, straight into `out`.
///
/// Note:
/// - Every read writes into its destination and returns only the error code. A
///   returned value travels back through a stack slot that the copy, decode, and
///   error paths all write, and reading it back stalled on every string (measured).
///
/// Param:
/// Target - type (comptime, the type to build)
/// out - *Target (where the value goes, left undefined on a failure)
/// source - Source (the cursor and its allocator)
/// options - DeserializeOptions (comptime, string mode and unknown key rule)
/// shape - ScanShape (comptime, which width to scan at)
///
/// Return:
/// - void
/// - Inner (any failure of the token or the field it lands in)
fn readInto(
    comptime Target: type,
    out: *Target,
    source: Source,
    comptime options: DeserializeOptions,
    comptime shape: ScanShape,
) Inner!void {
    switch (@typeInfo(Target)) {
        .bool => out.* = try readBool(source.cursor, shape),

        .int => {
            const text = try numberText(source.cursor, shape);

            out.* = integer.parse(Target, text) catch |err| {
                Failure.noteOffset(source.cursor.pos - text.len);

                return err;
            };
        },

        .float => {
            const text = try numberText(source.cursor, shape);

            out.* = float.parse(Target, text) catch |err| {
                Failure.noteOffset(source.cursor.pos - text.len);

                return err;
            };
        },

        .optional => |info| {
            shape.skipSpace(source.cursor);

            if ((try source.cursor.peek()) == 'n') {
                try source.cursor.literal("null");

                out.* = null;

                return;
            }

            var payload: info.child = undefined;
            try readInto(info.child, &payload, source, options, shape);

            out.* = payload;
        },

        .@"enum" => {
            if (!reflect.isExhaustive(Target)) @compileError(
                "jzon generated parser: " ++ @typeName(Target) ++
                    " is non-exhaustive, so a name cannot cover every value it carries",
            );

            out.* = try readEnum(Target, source, shape);
        },

        .@"struct" => |info| {
            if (info.is_tuple) @compileError(
                "jzon generated parser: " ++ @typeName(Target) ++
                    " is a tuple, which has no object form",
            );

            try readStruct(Target, out, source, options, shape);
        },

        .pointer => |info| {
            if (info.size != .slice) @compileError(
                "jzon generated parser: " ++ @typeName(Target) ++
                    " is not a slice, so it has no JSON form",
            );

            if (info.child == u8) return readString(Target, out, source, options, shape);

            try readSlice(Target, out, source, options, shape);
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
fn readBool(cursor: *Cursor, comptime shape: ScanShape) Inner!bool {
    shape.skipSpace(cursor);

    switch (try cursor.peek()) {
        't' => {
            try cursor.literal("true");

            return true;
        },

        'f' => {
            try cursor.literal("false");

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
fn readEnum(comptime Target: type, source: Source, comptime shape: ScanShape) Inner!Target {
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
/// out - *Target (the struct, filled field by field)
/// source - Source (the cursor and its allocator)
/// options - DeserializeOptions (comptime, string mode and unknown key rule)
/// shape - ScanShape (comptime, which width to scan at)
///
/// Return:
/// - void
/// - Inner (a bad key, a bad value, or a field the document owed)
fn readStruct(
    comptime Target: type,
    out: *Target,
    source: Source,
    comptime options: DeserializeOptions,
    comptime shape: ScanShape,
) Inner!void {
    const cursor = source.cursor;

    shape.skipSpace(cursor);
    try cursor.expect('{');

    var seen: fields.Seen(Target) = .{};

    shape.skipSpace(cursor);

    if (!cursor.accept('}')) {
        while (true) {
            const key = try stringToken(source, shape, NAME_OPTIONS);

            shape.skipSpace(cursor);
            try cursor.expect(':');

            try readField(Target, out, &seen, key, source, options, shape);

            shape.skipSpace(cursor);
            if (cursor.accept(',')) continue;

            try cursor.expect('}');
            break;
        }
    }

    try seen.fill(out);
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
) Inner!void {
    inline for (comptime std.meta.fieldNames(Target), 0..) |name, index| {
        if (std.mem.eql(u8, name, key)) {
            try seen.mark(index);

            const Field = @FieldType(Target, name);

            try readInto(Field, &@field(result, name), source, options, shape);

            return;
        }
    }

    switch (options.unknown) {
        .REJECT => {
            Failure.noteFieldAt(key, source.cursor.pos);

            return Error.Jzon_GeneratedParser_UnknownField;
        },
        .SKIP => try skip.value(source.cursor, shape),
    }
}

/// Read a slice as a JSON array, one element at a time.
///
/// Param:
/// Target - type (comptime, a plain slice type)
/// out - *Target (the slice, owned by the allocator)
/// source - Source (the cursor and its allocator)
/// options - DeserializeOptions (comptime, string mode and unknown key rule)
/// shape - ScanShape (comptime, which width to scan at)
///
/// Return:
/// - void
/// - Inner (a bad element, or Error.Jzon_GeneratedParser_OutOfMemory)
fn readSlice(
    comptime Target: type,
    out: *Target,
    source: Source,
    comptime options: DeserializeOptions,
    comptime shape: ScanShape,
) Inner!void {
    const Element = @typeInfo(Target).pointer.child;

    if (Target != []const Element and Target != []Element) @compileError(
        "jzon generated parser: " ++ @typeName(Target) ++
            " is not a plain slice, so a parse cannot produce it",
    );

    const cursor = source.cursor;

    shape.skipSpace(cursor);
    try cursor.expect('[');

    var elements: std.ArrayList(Element) = .empty;

    shape.skipSpace(cursor);

    if (!cursor.accept(']')) {
        while (true) {
            const slot = elements.addOne(source.allocator) catch |err| switch (err) {
                error.OutOfMemory => return Error.Jzon_GeneratedParser_OutOfMemory,
            };

            try readInto(Element, slot, source, options, shape);

            shape.skipSpace(cursor);
            if (cursor.accept(',')) continue;

            try cursor.expect(']');
            break;
        }
    }

    out.* = elements.toOwnedSlice(source.allocator) catch |err| switch (err) {
        error.OutOfMemory => return Error.Jzon_GeneratedParser_OutOfMemory,
    };
}

/// Read a string into the one slice type a parse can produce.
///
/// Param:
/// Target - type (comptime, must be `[]const u8`)
/// out - *Target (the string)
/// source - Source (the cursor and its allocator)
/// options - DeserializeOptions (comptime, string mode)
/// shape - ScanShape (comptime, which width to scan at)
///
/// Return:
/// - void
/// - Inner (a broken token, a bad escape, or out of memory)
fn readString(
    comptime Target: type,
    out: *Target,
    source: Source,
    comptime options: DeserializeOptions,
    comptime shape: ScanShape,
) Inner!void {
    if (Target != []const u8) @compileError(
        "jzon generated parser: " ++ @typeName(Target) ++
            " is not []const u8, the only string form a parse produces",
    );

    out.* = try stringToken(source, shape, options);
}

// --------------------------------------------------------- //
// Public:

/// How a parse can fail.
///
/// Note:
/// - UnknownField, MissingField, UnknownEnumValue: the document and the type
///   disagree. They also record the field name for `lastFailure`.
/// - Truncated, Unexpected, BadNumber, BadEscape: the document is not what it claims.
///   The stop byte is recorded for Truncated, Unexpected and BadNumber.
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

    var value: Target = undefined;
    readInto(Target, &value, source, options, shape) catch |err| return innerError(err);

    shape.skipSpace(&cursor);

    if (!cursor.atEnd()) {
        Failure.noteOffset(cursor.pos);

        return Error.Jzon_GeneratedParser_Unexpected;
    }

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

/// Require `innerError` to turn `from` into `wanted`.
fn expectInner(from: Inner, wanted: Error) !void {
    try std.testing.expectEqual(wanted, innerError(from));
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

test "jzon deserialize: generated_parser, innerError keeps every own member" {
    try expectInner(
        error.Jzon_GeneratedParser_UnknownField,
        Error.Jzon_GeneratedParser_UnknownField,
    );
    try expectInner(
        error.Jzon_GeneratedParser_MissingField,
        Error.Jzon_GeneratedParser_MissingField,
    );
    try expectInner(
        error.Jzon_GeneratedParser_UnknownEnumValue,
        Error.Jzon_GeneratedParser_UnknownEnumValue,
    );
    try expectInner(
        error.Jzon_GeneratedParser_Truncated,
        Error.Jzon_GeneratedParser_Truncated,
    );
    try expectInner(
        error.Jzon_GeneratedParser_Unexpected,
        Error.Jzon_GeneratedParser_Unexpected,
    );
    try expectInner(
        error.Jzon_GeneratedParser_BadNumber,
        Error.Jzon_GeneratedParser_BadNumber,
    );
    try expectInner(
        error.Jzon_GeneratedParser_BadEscape,
        Error.Jzon_GeneratedParser_BadEscape,
    );
    try expectInner(
        error.Jzon_GeneratedParser_NoSpaceLeft,
        Error.Jzon_GeneratedParser_NoSpaceLeft,
    );
    try expectInner(
        error.Jzon_GeneratedParser_OutOfMemory,
        Error.Jzon_GeneratedParser_OutOfMemory,
    );
}

test "jzon deserialize: generated_parser, innerError maps every cursor member" {
    try expectInner(
        error.Jzon_Cursor_Truncated,
        Error.Jzon_GeneratedParser_Truncated,
    );
    try expectInner(
        error.Jzon_Cursor_Unexpected,
        Error.Jzon_GeneratedParser_Unexpected,
    );
}

test "jzon deserialize: generated_parser, innerError maps every scan member" {
    try expectInner(
        error.Jzon_ScanShape_Truncated,
        Error.Jzon_GeneratedParser_Truncated,
    );
    try expectInner(
        error.Jzon_ScanShape_Unexpected,
        Error.Jzon_GeneratedParser_Unexpected,
    );
}

test "jzon deserialize: generated_parser, innerError maps every integer member" {
    try expectInner(
        error.Jzon_Integer_NoSpaceLeft,
        Error.Jzon_GeneratedParser_NoSpaceLeft,
    );
    try expectInner(
        error.Jzon_Integer_BadNumber,
        Error.Jzon_GeneratedParser_BadNumber,
    );
}

test "jzon deserialize: generated_parser, innerError maps every float member" {
    try expectInner(
        error.Jzon_Float_NoSpaceLeft,
        Error.Jzon_GeneratedParser_NoSpaceLeft,
    );
    try expectInner(
        error.Jzon_Float_BadNumber,
        Error.Jzon_GeneratedParser_BadNumber,
    );
}

test "jzon deserialize: generated_parser, innerError maps every fields member" {
    try expectInner(
        error.Jzon_Fields_Unexpected,
        Error.Jzon_GeneratedParser_Unexpected,
    );
    try expectInner(
        error.Jzon_Fields_MissingField,
        Error.Jzon_GeneratedParser_MissingField,
    );
}

test "jzon deserialize: generated_parser, innerError maps every skip member" {
    try expectInner(
        error.Jzon_Skip_Truncated,
        Error.Jzon_GeneratedParser_Truncated,
    );
    try expectInner(
        error.Jzon_Skip_Unexpected,
        Error.Jzon_GeneratedParser_Unexpected,
    );
}

test "jzon deserialize: generated_parser, innerError maps every string member" {
    try expectInner(
        error.Jzon_StringValue_BadEscape,
        Error.Jzon_GeneratedParser_BadEscape,
    );
    try expectInner(
        error.Jzon_StringValue_NoSpaceLeft,
        Error.Jzon_GeneratedParser_NoSpaceLeft,
    );
    try expectInner(
        error.Jzon_StringValue_OutOfMemory,
        Error.Jzon_GeneratedParser_OutOfMemory,
    );
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

test "jzon deserialize: generated_parser, bad number records the token start" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const Target = struct { id: u8 };

    inline for (SHAPES) |shape| {
        Failure.noteField("stale");

        const result = parse(Target, arena.allocator(), "{\"id\":-1}", .{}, shape);

        try std.testing.expectError(Error.Jzon_GeneratedParser_BadNumber, result);
        try std.testing.expectEqualStrings("", Failure.lastFailure().field);
        try std.testing.expectEqual(@as(usize, 6), Failure.lastFailure().offset);
    }
}

test "jzon deserialize: generated_parser, float bad number records the token start" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    inline for (SHAPES) |shape| {
        Failure.noteField("stale");

        const result = parse(f64, arena.allocator(), " 01.5", .{}, shape);

        try std.testing.expectError(Error.Jzon_GeneratedParser_BadNumber, result);
        try std.testing.expectEqual(@as(usize, 1), Failure.lastFailure().offset);
    }
}

test "jzon deserialize: generated_parser, trailing bytes record the stop byte" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    inline for (SHAPES) |shape| {
        Failure.noteField("stale");

        const result = parse(u8, arena.allocator(), "1 2", .{}, shape);

        try std.testing.expectError(Error.Jzon_GeneratedParser_Unexpected, result);
        try std.testing.expectEqualStrings("", Failure.lastFailure().field);
        try std.testing.expectEqual(@as(usize, 2), Failure.lastFailure().offset);
    }
}

