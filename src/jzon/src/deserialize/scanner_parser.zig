//! JZON scanner_parser
//!
//! ### file: src/jzon/src/deserialize/scanner_parser.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! The scanner read path: pulls whole tokens off `std.json.Scanner`, so std still
//! decides what a valid document is, and hands each one to code built from the type.
//!
//! ### note:
//!
//! Reads the shapes the generated emitter writes. A field type outside that set is a
//! compile error naming the type. A slice of bytes is a string here and nothing else:
//! std also fills a `[]const u8` from an array of numbers, which this path refuses.
//! The scanner calls a broken escape a syntax error, so this path never reports
//! BadEscape. Under `.BORROW` a clean string is a slice of the document, so the
//! document has to outlive the value.
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
const fields = @import("fields.zig");
const float = @import("../float.zig");
const integer = @import("../integer.zig");
const reflect = @import("../reflect.zig");

const Allocator = std.mem.Allocator;

// --------------------------------------------------------- //
// Private:

/// Everything the scanner can report, whichever way a token is asked for.
const ScannerError = std.json.Scanner.NextError ||
    std.json.Scanner.PeekError ||
    std.json.Scanner.AllocError ||
    std.json.Scanner.SkipError;

/// The scanner, plus what taking a token off it needs.
const Source = struct {
    allocator: Allocator,
    scanner: *std.json.Scanner,
    /// The longest a single token can be, which is the document itself. std uses the
    /// same bound, so `ValueTooLong` never comes up in practice.
    value_cap: usize,

    /// Take the next whole token.
    fn next(self: Source, when: std.json.AllocWhen) Error!std.json.Token {
        return self.scanner.nextAllocMax(self.allocator, when, self.value_cap) catch |err|
            scannerError(err);
    }

    /// What the next token is, without taking it.
    fn peek(self: Source) Error!std.json.TokenType {
        return self.scanner.peekNextTokenType() catch |err| scannerError(err);
    }

    /// Step over the next whole value, however deep it nests.
    fn skip(self: Source) Error!void {
        return self.scanner.skipValue() catch |err| scannerError(err);
    }
};

/// Translate one of the scanner's failures into this module's set.
///
/// Note:
/// - Every member is named, so a std that adds one breaks the build here and gets a
///   deliberate mapping, not a silent one.
///
/// Param:
/// err - ScannerError (the failure the scanner reported)
///
/// Return:
/// - Error (the closest failure under this module's name)
fn scannerError(err: ScannerError) Error {
    return switch (err) {
        error.OutOfMemory => Error.Jzon_ScannerParser_OutOfMemory,
        error.UnexpectedEndOfInput => Error.Jzon_ScannerParser_Truncated,
        error.BufferUnderrun => Error.Jzon_ScannerParser_Truncated,
        error.SyntaxError => Error.Jzon_ScannerParser_Unexpected,
        error.ValueTooLong => Error.Jzon_ScannerParser_Unexpected,
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
        error.Jzon_Integer_NoSpaceLeft => Error.Jzon_ScannerParser_NoSpaceLeft,
        error.Jzon_Integer_BadNumber => Error.Jzon_ScannerParser_BadNumber,
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
        error.Jzon_Float_NoSpaceLeft => Error.Jzon_ScannerParser_NoSpaceLeft,
        error.Jzon_Float_BadNumber => Error.Jzon_ScannerParser_BadNumber,
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
        error.Jzon_Fields_Unexpected => Error.Jzon_ScannerParser_Unexpected,
        error.Jzon_Fields_MissingField => Error.Jzon_ScannerParser_MissingField,
    };
}

/// Read one value of `Target`, whatever shape the type is.
///
/// Param:
/// Target - type (comptime, the type to build)
/// source - Source (the scanner and its allocator)
/// options - DeserializeOptions (comptime, string mode and unknown key rule)
///
/// Return:
/// - Target (the value)
/// - Error (any failure of the token or the field it lands in)
fn readValue(
    comptime Target: type,
    source: Source,
    comptime options: DeserializeOptions,
) Error!Target {
    switch (@typeInfo(Target)) {
        .bool => return readBool(source),

        .int => {
            const text = try numberText(source);

            return integer.parse(Target, text) catch |err| integerError(err);
        },

        .float => {
            const text = try numberText(source);

            return float.parse(Target, text) catch |err| floatError(err);
        },

        .optional => |info| {
            if ((try source.peek()) == .null) {
                _ = try source.next(.alloc_if_needed);

                return null;
            }

            return try readValue(info.child, source, options);
        },

        .@"enum" => {
            if (!reflect.isExhaustive(Target)) @compileError(
                "jzon parser: " ++ @typeName(Target) ++
                    " is non-exhaustive, so a name cannot cover every value it carries",
            );

            return readEnum(Target, source);
        },

        .@"struct" => |info| {
            if (info.is_tuple) @compileError(
                "jzon parser: " ++ @typeName(Target) ++ " is a tuple, which has no object form",
            );

            return readStruct(Target, source, options);
        },

        .pointer => |info| {
            if (info.size != .slice) @compileError(
                "jzon parser: " ++ @typeName(Target) ++
                    " is not a slice, so it has no JSON form",
            );

            if (info.child == u8) return readString(Target, source, options);

            return readSlice(Target, source, options);
        },

        else => @compileError("jzon parser: " ++ @typeName(Target) ++ " has no JSON form"),
    }
}

/// Read one of the two boolean words.
///
/// Param:
/// source - Source (the scanner and its allocator)
///
/// Return:
/// - bool (the value)
/// - Error.Jzon_ScannerParser_Unexpected when the token is not `true` or `false`
fn readBool(source: Source) Error!bool {
    return switch (try source.next(.alloc_if_needed)) {
        .true => true,
        .false => false,
        else => Error.Jzon_ScannerParser_Unexpected,
    };
}

/// Read a string holding one of an enum's tag names.
///
/// Param:
/// Target - type (comptime, the exhaustive enum)
/// source - Source (the scanner and its allocator)
///
/// Return:
/// - Target (the tag)
/// - Error.Jzon_ScannerParser_UnknownEnumValue when no tag carries that name
fn readEnum(comptime Target: type, source: Source) Error!Target {
    const name = try stringText(source, .alloc_if_needed);

    return std.meta.stringToEnum(Target, name) orelse {
        Failure.noteField(name);

        return Error.Jzon_ScannerParser_UnknownEnumValue;
    };
}

/// Read a struct as a JSON object, matching each key against a field name.
///
/// Note:
/// - The key match is unrolled over the field names at compile time, so a key costs
///   one comparison per field and no lookup structure is built.
///
/// Param:
/// Target - type (comptime, the struct to build)
/// source - Source (the scanner and its allocator)
/// options - DeserializeOptions (comptime, string mode and unknown key rule)
///
/// Return:
/// - Target (the struct)
/// - Error (a bad key, a bad value, or a field the document owed)
fn readStruct(
    comptime Target: type,
    source: Source,
    comptime options: DeserializeOptions,
) Error!Target {
    if ((try source.next(.alloc_if_needed)) != .object_begin) {
        return Error.Jzon_ScannerParser_Unexpected;
    }

    var result: Target = undefined;
    var seen: fields.Seen(Target) = .{};

    while (true) {
        const key = switch (try source.next(.alloc_if_needed)) {
            .object_end => break,
            .string => |text| text,
            .allocated_string => |text| text,
            else => return Error.Jzon_ScannerParser_Unexpected,
        };

        var matched = false;

        inline for (comptime std.meta.fieldNames(Target), 0..) |name, index| {
            if (!matched and std.mem.eql(u8, name, key)) {
                seen.mark(index) catch |err| return fieldsError(err);

                @field(result, name) = try readValue(@FieldType(Target, name), source, options);
                matched = true;
            }
        }

        if (matched) continue;

        switch (options.unknown) {
            .REJECT => {
                Failure.noteField(key);

                return Error.Jzon_ScannerParser_UnknownField;
            },
            .SKIP => try source.skip(),
        }
    }

    seen.fill(&result) catch |err| return fieldsError(err);

    return result;
}

/// Read a slice as a JSON array, one element at a time.
///
/// Param:
/// Target - type (comptime, a plain slice type)
/// source - Source (the scanner and its allocator)
/// options - DeserializeOptions (comptime, string mode and unknown key rule)
///
/// Return:
/// - Target (the slice, owned by the allocator)
/// - Error (a bad element, or Error.Jzon_ScannerParser_OutOfMemory)
fn readSlice(
    comptime Target: type,
    source: Source,
    comptime options: DeserializeOptions,
) Error!Target {
    const Element = @typeInfo(Target).pointer.child;

    if (Target != []const Element and Target != []Element) @compileError(
        "jzon parser: " ++ @typeName(Target) ++
            " is not a plain slice, so a parse cannot produce it",
    );

    if ((try source.next(.alloc_if_needed)) != .array_begin) {
        return Error.Jzon_ScannerParser_Unexpected;
    }

    var elements: std.ArrayList(Element) = .empty;

    while ((try source.peek()) != .array_end) {
        const element = try readValue(Element, source, options);

        elements.append(source.allocator, element) catch |err| switch (err) {
            error.OutOfMemory => return Error.Jzon_ScannerParser_OutOfMemory,
        };
    }

    _ = try source.next(.alloc_if_needed);

    return elements.toOwnedSlice(source.allocator) catch |err| switch (err) {
        error.OutOfMemory => Error.Jzon_ScannerParser_OutOfMemory,
    };
}

/// Read a string into the one slice type a parse can produce.
///
/// Param:
/// Target - type (comptime, must be `[]const u8`)
/// source - Source (the scanner and its allocator)
/// options - DeserializeOptions (comptime, string mode)
///
/// Return:
/// - Target (the string)
/// - Error.Jzon_ScannerParser_Unexpected when the token is not a string
fn readString(
    comptime Target: type,
    source: Source,
    comptime options: DeserializeOptions,
) Error!Target {
    if (Target != []const u8) @compileError(
        "jzon parser: " ++ @typeName(Target) ++
            " is not []const u8, the only string form a parse produces",
    );

    const when: std.json.AllocWhen = switch (options.strings) {
        .COPY => .alloc_always,
        .BORROW => .alloc_if_needed,
    };

    return stringText(source, when);
}

/// The bytes of a string token, decoded and whole.
///
/// Param:
/// source - Source (the scanner and its allocator)
/// when - std.json.AllocWhen (whether a clean string is copied)
///
/// Return:
/// - []const u8 (the decoded string)
/// - Error.Jzon_ScannerParser_Unexpected when the token is not a string
fn stringText(source: Source, when: std.json.AllocWhen) Error![]const u8 {
    return switch (try source.next(when)) {
        .string => |text| text,
        .allocated_string => |text| text,
        else => Error.Jzon_ScannerParser_Unexpected,
    };
}

/// The bytes of a number token, which never need decoding.
///
/// Param:
/// source - Source (the scanner and its allocator)
///
/// Return:
/// - []const u8 (the number text)
/// - Error.Jzon_ScannerParser_Unexpected when the token is not a number
fn numberText(source: Source) Error![]const u8 {
    return switch (try source.next(.alloc_if_needed)) {
        .number => |text| text,
        .allocated_number => |text| text,
        else => Error.Jzon_ScannerParser_Unexpected,
    };
}

// --------------------------------------------------------- //
// Public:

/// How a parse can fail.
///
/// Note:
/// - UnknownField, MissingField, UnknownEnumValue: the document and the type
///   disagree. They also record the field name for `lastFailure`.
/// - Truncated, Unexpected, BadNumber: the document is not what it claims.
/// - NoSpaceLeft exists so every member of `integer.Error` and `float.Error` maps to
///   a real member here. A read never returns it.
pub const Error = error{
    Jzon_ScannerParser_UnknownField,
    Jzon_ScannerParser_MissingField,
    Jzon_ScannerParser_UnknownEnumValue,
    Jzon_ScannerParser_Truncated,
    Jzon_ScannerParser_Unexpected,
    Jzon_ScannerParser_BadNumber,
    Jzon_ScannerParser_NoSpaceLeft,
    Jzon_ScannerParser_OutOfMemory,
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
///
/// Return:
/// - Target (the parsed value)
/// - Error.Jzon_ScannerParser_UnknownField, MissingField, UnknownEnumValue when the
///   document and the type disagree
/// - Error.Jzon_ScannerParser_Truncated, Unexpected, BadNumber when the document is
///   not what it claims
/// - Error.Jzon_ScannerParser_OutOfMemory when the allocator runs out
pub fn parse(
    comptime Target: type,
    allocator: Allocator,
    src: []const u8,
    comptime options: DeserializeOptions,
) Error!Target {
    var scanner = std.json.Scanner.initCompleteInput(allocator, src);
    defer scanner.deinit();

    const source: Source = .{
        .allocator = allocator,
        .scanner = &scanner,
        .value_cap = src.len,
    };

    const value = try readValue(Target, source, options);

    if ((try source.next(.alloc_if_needed)) != .end_of_document) {
        return Error.Jzon_ScannerParser_Unexpected;
    }

    return value;
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const std_parser = @import("std_parser.zig");

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

test "jzon deserialize: scanner_parser, reads a whole record" {
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
    try std.testing.expectEqualStrings("one", record.tags[0]);
    try std.testing.expectEqualStrings("x", record.nested.beta);
}

test "jzon deserialize: scanner_parser, reads the same record the std path reads" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    const ours = try parse(Record, allocator, DOCUMENT, .{});
    const theirs = try std_parser.parse(Record, allocator, DOCUMENT, .{});

    try std.testing.expectEqual(theirs.id, ours.id);
    try std.testing.expectEqualStrings(theirs.name, ours.name);
    try std.testing.expectEqual(theirs.ratio, ours.ratio);
    try std.testing.expectEqual(theirs.status, ours.status);
    try std.testing.expectEqualStrings(theirs.tags[1], ours.tags[1]);
    try std.testing.expectEqual(theirs.nested.alpha, ours.nested.alpha);
}

test "jzon deserialize: scanner_parser, unknown key is unknown field" {
    try expectFails(
        Pair,
        "{\"id\":1,\"name\":\"x\",\"other\":2}",
        Error.Jzon_ScannerParser_UnknownField,
    );
}

test "jzon deserialize: scanner_parser, unknown key records its name for lastFailure" {
    Failure.reset();

    try expectFails(
        Pair,
        "{\"id\":1,\"name\":\"x\",\"other\":2}",
        Error.Jzon_ScannerParser_UnknownField,
    );
    try std.testing.expectEqualStrings("other", Failure.lastFailure().field);
}

test "jzon deserialize: scanner_parser, absent field is missing field" {
    try expectFails(Pair, "{\"id\":1}", Error.Jzon_ScannerParser_MissingField);
}

test "jzon deserialize: scanner_parser, SKIP steps over an unknown key" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const src = "{\"id\":1,\"other\":{\"deep\":[1,2,3]},\"name\":\"x\"}";
    const pair = try parse(Pair, arena.allocator(), src, .{ .unknown = .SKIP });

    try std.testing.expectEqual(@as(u8, 1), pair.id);
    try std.testing.expectEqualStrings("x", pair.name);
}

test "jzon deserialize: scanner_parser, BORROW points a clean string into the document" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const src = "{\"plain\":\"borrowed\",\"escaped\":\"one\\ttwo\"}";
    const Strings = struct {
        plain: []const u8,
        escaped: []const u8,
    };

    const borrowed = try parse(Strings, arena.allocator(), src, .{ .strings = .BORROW });

    try std.testing.expect(pointsInto(borrowed.plain, src));
    try std.testing.expectEqualStrings("one\ttwo", borrowed.escaped);
}

test "jzon deserialize: scanner_parser, COPY keeps a clean string out of the document" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const src = "{\"alpha\":1,\"beta\":\"copied\"}";
    const copied = try parse(Nested, arena.allocator(), src, .{ .strings = .COPY });

    try std.testing.expect(!pointsInto(copied.beta, src));
    try std.testing.expectEqualStrings("copied", copied.beta);
}

test "jzon deserialize: scanner_parser, scannerError maps every scanner member" {
    const cases = .{
        .{ error.OutOfMemory, Error.Jzon_ScannerParser_OutOfMemory },
        .{ error.UnexpectedEndOfInput, Error.Jzon_ScannerParser_Truncated },
        .{ error.BufferUnderrun, Error.Jzon_ScannerParser_Truncated },
        .{ error.SyntaxError, Error.Jzon_ScannerParser_Unexpected },
        .{ error.ValueTooLong, Error.Jzon_ScannerParser_Unexpected },
    };

    inline for (cases) |case| {
        try std.testing.expectEqual(case[1], scannerError(case[0]));
    }
}

test "jzon deserialize: scanner_parser, integerError maps every integer member" {
    const no_space = integerError(error.Jzon_Integer_NoSpaceLeft);
    const bad_number = integerError(error.Jzon_Integer_BadNumber);

    try std.testing.expectEqual(Error.Jzon_ScannerParser_NoSpaceLeft, no_space);
    try std.testing.expectEqual(Error.Jzon_ScannerParser_BadNumber, bad_number);
}

test "jzon deserialize: scanner_parser, floatError maps every float member" {
    const no_space = floatError(error.Jzon_Float_NoSpaceLeft);
    const bad_number = floatError(error.Jzon_Float_BadNumber);

    try std.testing.expectEqual(Error.Jzon_ScannerParser_NoSpaceLeft, no_space);
    try std.testing.expectEqual(Error.Jzon_ScannerParser_BadNumber, bad_number);
}

test "jzon deserialize: scanner_parser, fieldsError maps every fields member" {
    const unexpected = fieldsError(error.Jzon_Fields_Unexpected);
    const missing = fieldsError(error.Jzon_Fields_MissingField);

    try std.testing.expectEqual(Error.Jzon_ScannerParser_Unexpected, unexpected);
    try std.testing.expectEqual(Error.Jzon_ScannerParser_MissingField, missing);
}

test "jzon deserialize: scanner_parser, document that ends early is truncated" {
    try expectFails(u8, "", Error.Jzon_ScannerParser_Truncated);
    try expectFails(Pair, "{", Error.Jzon_ScannerParser_Truncated);
    try expectFails(Pair, "{\"id\":1,", Error.Jzon_ScannerParser_Truncated);
}

test "jzon deserialize: scanner_parser, more than one value is unexpected" {
    try expectFails(u8, "1 2", Error.Jzon_ScannerParser_Unexpected);
    try expectFails(Pair, "{\"id\":1,\"name\":\"x\"}{}", Error.Jzon_ScannerParser_Unexpected);
}

test "jzon deserialize: scanner_parser, same key twice is unexpected" {
    try expectFails(
        Pair,
        "{\"id\":1,\"id\":2,\"name\":\"x\"}",
        Error.Jzon_ScannerParser_Unexpected,
    );
}

test "jzon deserialize: scanner_parser, number the field cannot take is bad number" {
    try expectFails(Pair, "{\"id\":300,\"name\":\"x\"}", Error.Jzon_ScannerParser_BadNumber);
    try expectFails(Pair, "{\"id\":1.5,\"name\":\"x\"}", Error.Jzon_ScannerParser_BadNumber);
    try expectFails(Pair, "{\"id\":-1,\"name\":\"x\"}", Error.Jzon_ScannerParser_BadNumber);
}

test "jzon deserialize: scanner_parser, signed zero in an unsigned field is bad number" {
    // A sign against an unsigned field is a type error, whatever the digits after it.
    // std reads the digits and lands on zero. Neither serialize path writes this.
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    const src = "{\"id\":-0,\"name\":\"x\"}";

    try std.testing.expectError(
        Error.Jzon_ScannerParser_BadNumber,
        parse(Pair, allocator, src, .{}),
    );

    const theirs = try std_parser.parse(Pair, allocator, src, .{});

    try std.testing.expectEqual(@as(u8, 0), theirs.id);
}

test "jzon deserialize: scanner_parser, value of the wrong shape is unexpected" {
    try expectFails(Pair, "{\"id\":null,\"name\":\"x\"}", Error.Jzon_ScannerParser_Unexpected);
    try expectFails(Pair, "{\"id\":1,\"name\":7}", Error.Jzon_ScannerParser_Unexpected);
    try expectFails(Pair, "[1,2]", Error.Jzon_ScannerParser_Unexpected);
}

test "jzon deserialize: scanner_parser, empty object owing fields is missing field" {
    try expectFails(Pair, "{}", Error.Jzon_ScannerParser_MissingField);
}

test "jzon deserialize: scanner_parser, name no enum tag carries is unknown enum value" {
    try expectFails(Status, "\"GONE\"", Error.Jzon_ScannerParser_UnknownEnumValue);
    try expectFails(Status, "\"pending\"", Error.Jzon_ScannerParser_UnknownEnumValue);
}

test "jzon deserialize: scanner_parser, decodes a surrogate pair" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const paired = try parse([]const u8, arena.allocator(), "\"\\ud83d\\udca9\"", .{});

    try std.testing.expectEqualStrings("\xf0\x9f\x92\xa9", paired);
}

test "jzon deserialize: scanner_parser, broken escape is unexpected" {
    // The scanner decides what an escape is, and it calls a broken one a syntax error.
    try expectFails([]const u8, "\"\\ud83d\"", Error.Jzon_ScannerParser_Unexpected);
    try expectFails([]const u8, "\"\\q\"", Error.Jzon_ScannerParser_Unexpected);
}

test "jzon deserialize: scanner_parser, reads the empty string and array" {
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

test "jzon deserialize: scanner_parser, empty object fills a type without fields" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    _ = try parse(struct {}, arena.allocator(), "{}", .{});
}

test "jzon deserialize: scanner_parser, SKIP steps over a deeply nested unknown value" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const src = "{\"id\":1,\"deep\":[[[{\"a\":{\"b\":[null,true,\"x\"]}}]]],\"name\":\"y\"}";
    const pair = try parse(Pair, arena.allocator(), src, .{ .unknown = .SKIP });

    try std.testing.expectEqual(@as(u8, 1), pair.id);
    try std.testing.expectEqualStrings("y", pair.name);
}

test "jzon deserialize: scanner_parser, reads the extremes of a width" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    const widest = try parse(u64, allocator, "18446744073709551615", .{});
    const lowest = try parse(i64, allocator, "-9223372036854775808", .{});

    try std.testing.expectEqual(@as(u64, std.math.maxInt(u64)), widest);
    try std.testing.expectEqual(@as(i64, std.math.minInt(i64)), lowest);
}

test "jzon deserialize: scanner_parser, one past the widest value is bad number" {
    try expectFails(u64, "18446744073709551616", Error.Jzon_ScannerParser_BadNumber);
}

test "jzon deserialize: scanner_parser, array of numbers for a byte slice is unexpected" {
    // A slice of bytes is a string and nothing else here. std also fills one from an
    // array of numbers, which is why the same type reads there and fails here.
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    try std.testing.expectError(
        Error.Jzon_ScannerParser_Unexpected,
        parse([]const u8, allocator, "[104,105]", .{}),
    );

    const theirs = try std_parser.parse([]const u8, allocator, "[104,105]", .{});

    try std.testing.expectEqualStrings("hi", theirs);
}

test "jzon deserialize: scanner_parser, reads a nested slice of slices" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const grid = try parse([]const []const u32, arena.allocator(), "[[1,2],[],[3]]", .{});

    try std.testing.expectEqual(@as(usize, 3), grid.len);
    try std.testing.expectEqual(@as(u32, 2), grid[0][1]);
    try std.testing.expectEqual(@as(usize, 0), grid[1].len);
    try std.testing.expectEqual(@as(u32, 3), grid[2][0]);
}

