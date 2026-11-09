//! JZON zon deserialize
//!
//! ### file: src/jzon/src/zon/deserialize.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Read ZON text into a typed value, with the reading generated from the type.
//!
//! ### note:
//!
//! Covers the shape `build.zig.zon` uses: `.{}` structs and lists, strings and
//! multiline strings, integers (any base), floats (`inf`, `nan` too), booleans,
//! `null`, `.tag` enum literals, and `//` comments. No `std.zig.Ast` is built: the
//! text is walked once. Pointers other than slices, tuples, unions, char literals and
//! `@import` are compile errors or Unexpected. Allocations go to the caller's
//! allocator and are not freed on failure, so pass an arena.
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
const Allocator = std.mem.Allocator;
const Failure = @import("../deserialize/Failure.zig");
const fields = @import("../deserialize/fields.zig");
const reflect = @import("../reflect.zig");
const grammar = @import("grammar.zig");
const ZonOptions = @import("ZonOptions.zig");

// --------------------------------------------------------- //
// Private:

/// Every failure a private function here can hand back: this module's own set joined
/// with the grammar's and the field bookkeeping's.
const Inner = Error || grammar.Error || fields.Error;

/// The options a quoted name is read with: a clean name points into the document.
const NAME_OPTIONS: ZonOptions = .{ .strings = .BORROW };

/// What kind of number token `scanNumber` found.
const NumberKind = enum {
    /// An integer literal in any base.
    INTEGER,
    /// A float literal, decimal or hex.
    FLOAT,
    /// `inf` or `-inf`.
    INF,
    /// `nan`.
    NAN,
};

/// One number token, checked against the Zig number grammar.
const Number = struct {
    /// The whole token, sign included.
    text: []const u8,
    /// What the token is.
    kind: NumberKind,
    /// Whether the token starts with `-`.
    negative: bool,
    /// The first byte past the token.
    end: usize,
};

/// Where a parse is in the document, and where its allocations go.
const Reader = struct {
    allocator: Allocator,
    src: []const u8,
    pos: usize,

    /// Record the current byte as the stop point, then hand the error back.
    ///
    /// Param:
    /// err - Inner (the error to return)
    ///
    /// Return:
    /// - Inner (the same error it was given, always)
    fn stopAt(self: *const Reader, err: Inner) Inner {
        @branchHint(.cold);

        Failure.noteOffset(self.pos);

        return err;
    }

    /// Truncated at the end of the document, Unexpected anywhere else.
    ///
    /// Return:
    /// - Inner (the error that fits where the reader stands)
    fn refuse(self: *const Reader) Inner {
        @branchHint(.cold);

        if (self.pos >= self.src.len) return self.stopAt(Error.Jzon_ZonDeserialize_Truncated);

        return self.stopAt(Error.Jzon_ZonDeserialize_Unexpected);
    }

    /// Step over whitespace and comments.
    fn skip(self: *Reader) void {
        self.pos = grammar.skipIgnored(self.src, self.pos);
    }

    /// Whether the next token starts with `byte`, whitespace and comments skipped.
    ///
    /// Param:
    /// byte - u8 (the byte to look for)
    ///
    /// Return:
    /// - bool (true when it does, the reader stays on it)
    fn at(self: *Reader, byte: u8) bool {
        self.skip();

        return self.pos < self.src.len and self.src[self.pos] == byte;
    }

    /// Step over one byte that has to come next.
    ///
    /// Param:
    /// byte - u8 (the byte that has to come next)
    ///
    /// Return:
    /// - void
    /// - Error.Jzon_ZonDeserialize_Truncated or Unexpected when it does not
    fn expect(self: *Reader, byte: u8) Inner!void {
        if (!self.at(byte)) return self.refuse();

        self.pos += 1;
    }

    /// The bare name the next token is, without stepping over it.
    ///
    /// Return:
    /// - []const u8 (the name, empty when the next token is not a bare name)
    fn peekWord(self: *Reader) []const u8 {
        self.skip();

        if (self.pos >= self.src.len or !grammar.isNameStart(self.src[self.pos])) return "";

        return self.src[self.pos..grammar.nameEnd(self.src, self.pos)];
    }
};

/// Translate a failure from inside the module into this module's public set.
///
/// Param:
/// err - Inner (the failure a private function handed back)
///
/// Return:
/// - Error (the same failure under this module's name)
inline fn innerError(err: Inner) Error {
    @branchHint(.cold);

    return switch (err) {
        error.Jzon_ZonDeserialize_UnknownField => Error.Jzon_ZonDeserialize_UnknownField,
        error.Jzon_ZonDeserialize_MissingField => Error.Jzon_ZonDeserialize_MissingField,
        error.Jzon_ZonDeserialize_UnknownEnumValue => Error.Jzon_ZonDeserialize_UnknownEnumValue,
        error.Jzon_ZonDeserialize_Truncated => Error.Jzon_ZonDeserialize_Truncated,
        error.Jzon_ZonDeserialize_Unexpected => Error.Jzon_ZonDeserialize_Unexpected,
        error.Jzon_ZonDeserialize_BadNumber => Error.Jzon_ZonDeserialize_BadNumber,
        error.Jzon_ZonDeserialize_BadEscape => Error.Jzon_ZonDeserialize_BadEscape,
        error.Jzon_ZonDeserialize_OutOfMemory => Error.Jzon_ZonDeserialize_OutOfMemory,
        error.Jzon_ZonGrammar_Truncated => Error.Jzon_ZonDeserialize_Truncated,
        error.Jzon_ZonGrammar_Unexpected => Error.Jzon_ZonDeserialize_Unexpected,
        error.Jzon_Fields_Unexpected => Error.Jzon_ZonDeserialize_Unexpected,
        error.Jzon_Fields_MissingField => Error.Jzon_ZonDeserialize_MissingField,
    };
}

/// The body of `deserialize`, failing with the inner set.
fn deserializeInto(
    comptime Target: type,
    allocator: Allocator,
    src: []const u8,
    comptime options: ZonOptions,
) Inner!Target {
    var reader: Reader = .{
        .allocator = allocator,
        .src = src,
        .pos = 0,
    };

    const value = try readValue(Target, options, &reader, 0);

    reader.skip();
    if (reader.pos != src.len) return reader.stopAt(Error.Jzon_ZonDeserialize_Unexpected);

    return value;
}

/// Read one value of a type, picking the reading from the type at compile time.
///
/// Param:
/// Target - type (comptime, the type to produce)
/// options - ZonOptions (comptime, strings, unknown, depth cap)
/// reader - *Reader (the reader to advance)
/// depth - usize (how many containers enclose this value)
///
/// Return:
/// - Target (the value)
/// - Inner (any failure below, translated once by `deserialize`)
fn readValue(
    comptime Target: type,
    comptime options: ZonOptions,
    reader: *Reader,
    depth: usize,
) Inner!Target {
    switch (@typeInfo(Target)) {
        .bool => return readBool(reader),
        .int => return readInt(Target, reader),
        .float => return readFloat(Target, reader),
        .@"enum" => return readEnum(Target, reader),
        .array => return readArray(Target, options, reader, depth),

        .optional => |info| {
            const word = reader.peekWord();

            if (std.mem.eql(u8, word, "null")) {
                reader.pos += word.len;

                return null;
            }

            return try readValue(info.child, options, reader, depth);
        },

        .@"struct" => |info| {
            if (info.is_tuple) @compileError(
                "jzon zon: " ++ @typeName(Target) ++
                    " is a tuple, which the parse does not read",
            );

            return readStruct(Target, options, reader, depth);
        },

        .pointer => |info| {
            if (info.size != .slice or !info.attrs.@"const" or info.sentinel() != null) {
                @compileError("jzon zon: " ++ @typeName(Target) ++ " is not a []const slice");
            }

            if (info.child == u8) return readString(options, reader);

            return readSlice(info.child, options, reader, depth);
        },

        else => @compileError("jzon zon: " ++ @typeName(Target) ++ " has no ZON form"),
    }
}

/// Read `true` or `false`.
///
/// Param:
/// reader - *Reader (the reader to advance)
///
/// Return:
/// - bool (the value)
/// - Error.Jzon_ZonDeserialize_Truncated or Unexpected when the token is neither
fn readBool(reader: *Reader) Inner!bool {
    const word = reader.peekWord();

    if (std.mem.eql(u8, word, "true")) {
        reader.pos += word.len;

        return true;
    }

    if (std.mem.eql(u8, word, "false")) {
        reader.pos += word.len;

        return false;
    }

    return reader.refuse();
}

/// Bound and check one number token, without stepping over it.
///
/// Param:
/// reader - *Reader (the reader, left on the token)
///
/// Return:
/// - Number (the token, its kind and its end)
/// - Error.Jzon_ZonDeserialize_Truncated or Unexpected when no number starts here
/// - Error.Jzon_ZonDeserialize_BadNumber when the token breaks the Zig number grammar
fn scanNumber(reader: *Reader) Inner!Number {
    reader.skip();

    const src = reader.src;
    const start = reader.pos;
    const negative = start < src.len and src[start] == '-';
    const body = start + @intFromBool(negative);

    if (body >= src.len) return reader.stopAt(Error.Jzon_ZonDeserialize_Truncated);

    if (grammar.isNameStart(src[body])) {
        const end = grammar.nameEnd(src, body);
        const word = src[body..end];

        const kind: NumberKind = if (std.mem.eql(u8, word, "inf"))
            .INF
        else if (std.mem.eql(u8, word, "nan") and !negative)
            .NAN
        else
            return reader.stopAt(Error.Jzon_ZonDeserialize_Unexpected);

        return .{
            .text = src[start..end],
            .kind = kind,
            .negative = negative,
            .end = end,
        };
    }

    if (src[body] < '0' or src[body] > '9') {
        return reader.stopAt(Error.Jzon_ZonDeserialize_Unexpected);
    }

    const end = grammar.numberEnd(src, body);

    const kind: NumberKind = switch (std.zig.parseNumberLiteral(src[body..end])) {
        .int, .big_int => .INTEGER,
        .float => .FLOAT,
        .failure => return reader.stopAt(Error.Jzon_ZonDeserialize_BadNumber),
    };

    return .{
        .text = src[start..end],
        .kind = kind,
        .negative = negative,
        .end = end,
    };
}

/// Read an integer literal in any base Zig allows.
///
/// Param:
/// Target - type (comptime, the integer type to produce)
/// reader - *Reader (the reader to advance)
///
/// Return:
/// - Target (the value)
/// - Error.Jzon_ZonDeserialize_BadNumber when the token is not an integer the type holds
fn readInt(comptime Target: type, reader: *Reader) Inner!Target {
    const number = try scanNumber(reader);

    if (number.kind != .INTEGER) return reader.stopAt(Error.Jzon_ZonDeserialize_BadNumber);

    const value = std.fmt.parseInt(Target, number.text, 0) catch |err| switch (err) {
        error.Overflow, error.InvalidCharacter => {
            return reader.stopAt(Error.Jzon_ZonDeserialize_BadNumber);
        },
    };

    reader.pos = number.end;

    return value;
}

/// Read a float, or an integer literal as a float.
///
/// Param:
/// Target - type (comptime, the float type to produce)
/// reader - *Reader (the reader to advance)
///
/// Return:
/// - Target (the value)
/// - Error.Jzon_ZonDeserialize_BadNumber when the token is not a number
fn readFloat(comptime Target: type, reader: *Reader) Inner!Target {
    const number = try scanNumber(reader);

    const value: Target = switch (number.kind) {
        .INF => if (number.negative) -std.math.inf(Target) else std.math.inf(Target),
        .NAN => std.math.nan(Target),

        .INTEGER, .FLOAT => std.fmt.parseFloat(Target, number.text) catch |err| switch (err) {
            error.InvalidCharacter => return reader.stopAt(Error.Jzon_ZonDeserialize_BadNumber),
        },
    };

    reader.pos = number.end;

    return value;
}

/// Read the name after a `.`: a bare name, or `@"..."` for any other spelling.
///
/// Param:
/// reader - *Reader (the reader, on the byte right after the `.`)
///
/// Return:
/// - []const u8 (the name, into the document unless `@"..."` held an escape)
/// - Error.Jzon_ZonDeserialize_Truncated or Unexpected when no name starts here
/// - Error.Jzon_ZonDeserialize_BadEscape when a `@"..."` escape is broken
fn readName(reader: *Reader) Inner![]const u8 {
    const src = reader.src;
    const start = reader.pos;

    if (start >= src.len) return reader.stopAt(Error.Jzon_ZonDeserialize_Truncated);

    if (src[start] == '@') {
        reader.pos += 1;
        if (reader.pos >= src.len) return reader.stopAt(Error.Jzon_ZonDeserialize_Truncated);
        if (src[reader.pos] != '"') return reader.stopAt(Error.Jzon_ZonDeserialize_Unexpected);

        return readQuoted(NAME_OPTIONS, reader);
    }

    if (!grammar.isNameStart(src[start])) {
        return reader.stopAt(Error.Jzon_ZonDeserialize_Unexpected);
    }

    reader.pos = grammar.nameEnd(src, start);

    return src[start..reader.pos];
}

/// Read a `"..."` string, decoding its escapes.
///
/// Param:
/// options - ZonOptions (comptime, whether a clean string is borrowed)
/// reader - *Reader (the reader, on the opening `"`)
///
/// Return:
/// - []const u8 (the text)
/// - Error.Jzon_ZonDeserialize_BadEscape when an escape is broken
/// - Error.Jzon_ZonDeserialize_OutOfMemory when the allocator runs out
fn readQuoted(comptime options: ZonOptions, reader: *Reader) Inner![]const u8 {
    const start = reader.pos;
    const end = grammar.stringEnd(reader.src, start) catch |err| return reader.stopAt(err);
    const quoted = reader.src[start..end];
    const text = quoted[1 .. quoted.len - 1];

    if (std.mem.indexOfScalar(u8, text, '\\') == null) {
        reader.pos = end;
        if (options.strings == .BORROW) return text;

        return reader.allocator.dupe(u8, text) catch |err| switch (err) {
            error.OutOfMemory => Error.Jzon_ZonDeserialize_OutOfMemory,
        };
    }

    const decoded = std.zig.string_literal.parseAlloc(reader.allocator, quoted) catch |err| {
        return switch (err) {
            error.OutOfMemory => Error.Jzon_ZonDeserialize_OutOfMemory,
            error.InvalidLiteral => reader.stopAt(Error.Jzon_ZonDeserialize_BadEscape),
        };
    };

    reader.pos = end;

    return decoded;
}

/// Read a run of `\\` lines as one string, lines joined with `\n`.
///
/// Note:
/// - Lines may be split by whitespace and comments, as Zig allows.
/// - Under `.BORROW`, one line with no `\r` dropped points into the document.
///   Anything else is joined into a new allocation.
///
/// Param:
/// options - ZonOptions (comptime, whether a one-line string is borrowed)
/// reader - *Reader (the reader, on the first `\\`)
///
/// Return:
/// - []const u8 (the text)
/// - Error.Jzon_ZonDeserialize_OutOfMemory when the allocator runs out
fn readMultiline(comptime options: ZonOptions, reader: *Reader) Inner![]const u8 {
    const src = reader.src;
    const first = reader.pos;

    var lines: usize = 0;
    var total: usize = 0;
    var clean = true;
    var line_at = first;
    var last_end = first;

    while (grammar.isMultilineAt(src, line_at)) {
        const text = grammar.multilineText(src, line_at);
        last_end = grammar.lineEnd(src, line_at);

        if (text.len != last_end - line_at - 2) clean = false;

        total += text.len;
        lines += 1;
        line_at = grammar.skipIgnored(src, last_end);
    }

    reader.pos = last_end;

    if (lines == 1 and clean and options.strings == .BORROW) {
        return grammar.multilineText(src, first);
    }

    const joined = reader.allocator.alloc(u8, total + lines - 1) catch |err| switch (err) {
        error.OutOfMemory => return Error.Jzon_ZonDeserialize_OutOfMemory,
    };

    var written: usize = 0;
    line_at = first;

    for (0..lines) |index| {
        if (index > 0) {
            joined[written] = '\n';
            written += 1;
        }

        const text = grammar.multilineText(src, line_at);
        @memcpy(joined[written..][0..text.len], text);
        written += text.len;

        line_at = grammar.skipIgnored(src, grammar.lineEnd(src, line_at));
    }

    return joined;
}

/// Read a string in either form.
///
/// Param:
/// options - ZonOptions (comptime, whether a clean string is borrowed)
/// reader - *Reader (the reader to advance)
///
/// Return:
/// - []const u8 (the text)
/// - Error.Jzon_ZonDeserialize_Truncated or Unexpected when no string starts here
/// - Error.Jzon_ZonDeserialize_BadEscape, OutOfMemory as `readQuoted` and `readMultiline`
fn readString(comptime options: ZonOptions, reader: *Reader) Inner![]const u8 {
    if (reader.at('"')) return readQuoted(options, reader);
    if (grammar.isMultilineAt(reader.src, reader.pos)) return readMultiline(options, reader);

    return reader.refuse();
}

/// Read a `.tag` enum literal.
///
/// Param:
/// Target - type (comptime, the exhaustive enum)
/// reader - *Reader (the reader to advance)
///
/// Return:
/// - Target (the tag)
/// - Error.Jzon_ZonDeserialize_UnknownEnumValue when no tag carries that name, with the
///   name noted for `lastFailure`
fn readEnum(comptime Target: type, reader: *Reader) Inner!Target {
    if (!reflect.isExhaustive(Target)) @compileError(
        "jzon zon: " ++ @typeName(Target) ++ " is not exhaustive, so it has no ZON form",
    );

    try reader.expect('.');

    const name_at = reader.pos;
    const name = try readName(reader);

    return std.meta.stringToEnum(Target, name) orelse {
        Failure.noteFieldAt(name, name_at);

        return Error.Jzon_ZonDeserialize_UnknownEnumValue;
    };
}

/// Step over `.{`, refusing one container more than the cap allows.
///
/// Param:
/// options - ZonOptions (comptime, the depth cap)
/// reader - *Reader (the reader to advance)
/// depth - usize (how many containers already enclose this one)
///
/// Return:
/// - usize (the depth inside this container)
/// - Error.Jzon_ZonDeserialize_Unexpected when the container nests past `max_depth`
fn open(comptime options: ZonOptions, reader: *Reader, depth: usize) Inner!usize {
    reader.skip();
    if (depth >= options.max_depth) return reader.stopAt(Error.Jzon_ZonDeserialize_Unexpected);

    try reader.expect('.');
    try reader.expect('{');

    return depth + 1;
}

/// Step over the `}` of an empty container.
///
/// Return:
/// - bool (true when the container closed right away)
fn closed(reader: *Reader) bool {
    if (!reader.at('}')) return false;

    reader.pos += 1;

    return true;
}

/// Step over what follows an entry: `,` then maybe `}`, or `}` alone.
///
/// Return:
/// - bool (true when the container closed)
/// - Error.Jzon_ZonDeserialize_Truncated or Unexpected when neither follows
fn next(reader: *Reader) Inner!bool {
    if (closed(reader)) return true;

    try reader.expect(',');

    return closed(reader);
}

/// Whether the reader stands on a `.name =` entry rather than on a value.
///
/// Return:
/// - bool (true for a field entry, the reader does not move)
fn isFieldEntry(reader: *Reader) bool {
    const src = reader.src;
    const start = reader.pos;

    if (start + 1 >= src.len or src[start] != '.') return false;

    const quoted = start + 2 < src.len and src[start + 1] == '@' and src[start + 2] == '"';

    const name_end = if (quoted)
        grammar.stringEnd(src, start + 2) catch return false
    else if (grammar.isNameStart(src[start + 1]))
        grammar.nameEnd(src, start + 1)
    else
        return false;

    const after = grammar.skipIgnored(src, name_end);

    return after < src.len and src[after] == '=';
}

/// Read a `.{ .name = value, ... }` struct, matching each name against a field.
///
/// Param:
/// Target - type (comptime, the struct to produce)
/// options - ZonOptions (comptime, unknown mode and the rest)
/// reader - *Reader (the reader to advance)
/// depth - usize (how many containers enclose this one)
///
/// Return:
/// - Target (the value, with left-out fields at their defaults)
/// - Error.Jzon_ZonDeserialize_UnknownField when a name matches no field under REJECT
/// - Error.Jzon_ZonDeserialize_Unexpected when a name comes twice
/// - Error.Jzon_Fields_MissingField when a left-out field has no default
fn readStruct(
    comptime Target: type,
    comptime options: ZonOptions,
    reader: *Reader,
    depth: usize,
) Inner!Target {
    const inside = try open(options, reader, depth);

    var result: Target = undefined;
    var seen: fields.Seen(Target) = .{};
    var done = closed(reader);

    while (!done) {
        try reader.expect('.');

        const key_at = reader.pos;
        const key = try readName(reader);

        try reader.expect('=');
        try readField(Target, options, reader, inside, &result, &seen, key, key_at);

        done = try next(reader);
    }

    try seen.fill(&result);

    return result;
}

/// Read the value of one struct entry into the field its name matches.
///
/// Param:
/// Target - type (comptime, the struct being built)
/// options - ZonOptions (comptime, unknown mode and the rest)
/// reader - *Reader (the reader, on the value)
/// depth - usize (the depth inside the struct)
/// result - *Target (the value being built)
/// seen - *fields.Seen(Target) (which fields have been read)
/// key - []const u8 (the entry's name)
/// key_at - usize (where the name starts, for `lastFailure`)
///
/// Return:
/// - void
/// - Error.Jzon_ZonDeserialize_UnknownField, Unexpected as `readStruct`
fn readField(
    comptime Target: type,
    comptime options: ZonOptions,
    reader: *Reader,
    depth: usize,
    result: *Target,
    seen: *fields.Seen(Target),
    key: []const u8,
    key_at: usize,
) Inner!void {
    inline for (comptime std.meta.fieldNames(Target), 0..) |name, index| {
        if (std.mem.eql(u8, key, name)) {
            if (seen.isMarked(index)) {
                Failure.noteFieldAt(key, key_at);

                return Error.Jzon_ZonDeserialize_Unexpected;
            }

            try seen.mark(index);
            const Field = @FieldType(Target, name);

            @field(result, name) = try readValue(Field, options, reader, depth);

            return;
        }
    }

    switch (options.unknown) {
        .REJECT => {
            Failure.noteFieldAt(key, key_at);

            return Error.Jzon_ZonDeserialize_UnknownField;
        },

        .SKIP => try skipValue(options, reader, depth),
    }
}

/// Read a `.{ a, b, ... }` list into a fixed-size array.
///
/// Param:
/// Target - type (comptime, the array type)
/// options - ZonOptions (comptime, passed to each element)
/// reader - *Reader (the reader to advance)
/// depth - usize (how many containers enclose this one)
///
/// Return:
/// - Target (the array)
/// - Error.Jzon_ZonDeserialize_Unexpected when the list holds more or fewer elements
fn readArray(
    comptime Target: type,
    comptime options: ZonOptions,
    reader: *Reader,
    depth: usize,
) Inner!Target {
    const info = @typeInfo(Target).array;
    const inside = try open(options, reader, depth);

    var result: Target = undefined;
    var count: usize = 0;
    var done = closed(reader);

    while (!done) {
        if (count == info.len) return reader.stopAt(Error.Jzon_ZonDeserialize_Unexpected);

        result[count] = try readValue(info.child, options, reader, inside);
        count += 1;

        done = try next(reader);
    }

    if (count != info.len) return reader.stopAt(Error.Jzon_ZonDeserialize_Unexpected);

    return result;
}

/// Read a `.{ a, b, ... }` list into a new slice.
///
/// Param:
/// Element - type (comptime, the element type)
/// options - ZonOptions (comptime, passed to each element)
/// reader - *Reader (the reader to advance)
/// depth - usize (how many containers enclose this one)
///
/// Return:
/// - []const Element (the elements, owned by the allocator)
/// - Error.Jzon_ZonDeserialize_OutOfMemory when the allocator runs out
fn readSlice(
    comptime Element: type,
    comptime options: ZonOptions,
    reader: *Reader,
    depth: usize,
) Inner![]const Element {
    const inside = try open(options, reader, depth);

    var elements: std.ArrayList(Element) = .empty;
    var done = closed(reader);

    while (!done) {
        const element = try readValue(Element, options, reader, inside);

        elements.append(reader.allocator, element) catch |err| switch (err) {
            error.OutOfMemory => return Error.Jzon_ZonDeserialize_OutOfMemory,
        };

        done = try next(reader);
    }

    return elements.toOwnedSlice(reader.allocator) catch |err| switch (err) {
        error.OutOfMemory => Error.Jzon_ZonDeserialize_OutOfMemory,
    };
}

/// Step over one whole value of any shape, however deep it nests.
///
/// Param:
/// options - ZonOptions (comptime, the depth cap)
/// reader - *Reader (the reader to advance)
/// depth - usize (how many containers enclose this value)
///
/// Return:
/// - void
/// - Error.Jzon_ZonDeserialize_Truncated, Unexpected, BadNumber when the value is malformed
fn skipValue(comptime options: ZonOptions, reader: *Reader, depth: usize) Inner!void {
    reader.skip();
    if (reader.pos >= reader.src.len) return reader.stopAt(Error.Jzon_ZonDeserialize_Truncated);

    const src = reader.src;
    const lead = src[reader.pos];

    if (lead == '"') {
        reader.pos = grammar.stringEnd(src, reader.pos) catch |err| return reader.stopAt(err);

        return;
    }

    if (grammar.isMultilineAt(src, reader.pos)) {
        var line_at = reader.pos;

        while (grammar.isMultilineAt(src, line_at)) {
            reader.pos = grammar.lineEnd(src, line_at);
            line_at = grammar.skipIgnored(src, reader.pos);
        }

        return;
    }

    if (lead == '.') {
        const after_dot = grammar.skipIgnored(src, reader.pos + 1);

        if (after_dot < src.len and src[after_dot] == '{') {
            return skipContainer(options, reader, depth);
        }

        reader.pos += 1;
        _ = try readName(reader);

        return;
    }

    const word = reader.peekWord();

    if (std.mem.eql(u8, word, "true") or
        std.mem.eql(u8, word, "false") or
        std.mem.eql(u8, word, "null"))
    {
        reader.pos += word.len;

        return;
    }

    reader.pos = (try scanNumber(reader)).end;
}

/// Step over a `.{ ... }` whose entries are fields, values, or both.
///
/// Param:
/// options - ZonOptions (comptime, the depth cap)
/// reader - *Reader (the reader, on the `.`)
/// depth - usize (how many containers enclose this one)
///
/// Return:
/// - void
/// - Error.Jzon_ZonDeserialize_Unexpected when the container nests past `max_depth`
fn skipContainer(comptime options: ZonOptions, reader: *Reader, depth: usize) Inner!void {
    const inside = try open(options, reader, depth);

    var done = closed(reader);

    while (!done) {
        reader.skip();

        if (isFieldEntry(reader)) {
            reader.pos += 1;
            _ = try readName(reader);
            try reader.expect('=');
        }

        try skipValue(options, reader, inside);

        done = try next(reader);
    }
}

// --------------------------------------------------------- //
// Public:

/// Every way a ZON deserialize can fail.
///
/// Note:
/// - UnknownField, MissingField, UnknownEnumValue: the document and the type disagree.
///   Each notes the name for `lastFailure`.
/// - Truncated, Unexpected, BadNumber, BadEscape: the document is not what it claims,
///   or nests past `max_depth`. Each notes the stop byte for `lastFailure`. A name
///   that comes twice is Unexpected, with the name noted.
/// - OutOfMemory: the allocator ran out.
pub const Error = error{
    Jzon_ZonDeserialize_UnknownField,
    Jzon_ZonDeserialize_MissingField,
    Jzon_ZonDeserialize_UnknownEnumValue,
    Jzon_ZonDeserialize_Truncated,
    Jzon_ZonDeserialize_Unexpected,
    Jzon_ZonDeserialize_BadNumber,
    Jzon_ZonDeserialize_BadEscape,
    Jzon_ZonDeserialize_OutOfMemory,
};

/// Read ZON text into a typed value.
///
/// Note:
/// - Strings are copied into `allocator` unless `.strings = .BORROW`, so pass an arena
///   and free it once.
/// - A field the document leaves out takes its declared default. An optional field
///   with no default has to be written, as `null` or a value.
///
/// Param:
/// Target - type (comptime, the type to produce)
/// allocator - std.mem.Allocator (where strings and slices go, an arena fits best)
/// src - []const u8 (the ZON text)
/// options - ZonOptions (comptime, strings, unknown, depth cap)
///
/// Usage:
/// ```zig
/// var arena: std.heap.ArenaAllocator = .init(allocator);
/// defer arena.deinit();
///
/// const package = try jzon.zon.deserialize(Package, arena.allocator(), src, .{
///     .unknown = .SKIP,
/// });
/// ```
///
/// Return:
/// - Target (the parsed value)
/// - Error.Jzon_ZonDeserialize_UnknownField, MissingField, UnknownEnumValue when the document
///   and the type disagree
/// - Error.Jzon_ZonDeserialize_Truncated, Unexpected, BadNumber, BadEscape when the document
///   is not what it claims
/// - Error.Jzon_ZonDeserialize_OutOfMemory when the allocator runs out
pub fn deserialize(
    comptime Target: type,
    allocator: Allocator,
    src: []const u8,
    comptime options: ZonOptions,
) Error!Target {
    return deserializeInto(Target, allocator, src, options) catch |err| innerError(err);
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const Status = enum { PENDING, SHIPPED };

const Point = struct {
    x: i32,
    y: i32,
};

const Record = struct {
    id: u32,
    name: []const u8,
    score: f64,
    active: bool,
    tags: []const []const u8,
    status: Status = .PENDING,
    note: ?[]const u8 = null,
};

const Package = struct {
    const Name = enum { jzon };

    const Semver = struct {
        major: u32,
        minor: u32,
        patch: u32,
    };

    name: Name,
    version: []const u8,
    semver: Semver,
    fingerprint: u64,
    minimum_zig_version: []const u8,
    paths: []const []const u8,
};

const PACKAGE_TEXT =
    \\.{
    \\    .name = .jzon,
    \\    .version = "0.1.0",
    \\    .semver = .{
    \\        .major = 0,
    \\        .minor = 1,
    \\        .patch = 0,
    \\    },
    \\    .fingerprint = 0x64d61eca0e47a420,
    \\    .minimum_zig_version = "0.17.0",
    \\    .paths = .{
    \\        "build.zig",
    \\        "build.zig.zon",
    \\        "src",
    \\    },
    \\}
    \\
;

/// Parse with a fresh arena and hand back the error, or fail when the parse passes.
fn expectFails(
    comptime Target: type,
    src: []const u8,
    comptime options: ZonOptions,
    expected: Error,
) !void {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectError(expected, deserialize(Target, arena.allocator(), src, options));
}

test "jzon zon: deserialize, reads a build.zig.zon shape" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const package = try deserialize(Package, arena.allocator(), PACKAGE_TEXT, .{});

    try std.testing.expectEqual(Package.Name.jzon, package.name);
    try std.testing.expectEqualStrings("0.1.0", package.version);
    try std.testing.expectEqual(@as(u32, 1), package.semver.minor);
    try std.testing.expectEqual(@as(u64, 0x64d61eca0e47a420), package.fingerprint);
    try std.testing.expectEqual(@as(usize, 3), package.paths.len);
    try std.testing.expectEqualStrings("build.zig.zon", package.paths[1]);
}

test "jzon zon: deserialize, reads a compact record" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const src =
        \\.{ .id = 1, .name = "foo_0", .score = 0.5, .active = true,
        \\.tags = .{ "urgent", "verified" } }
    ;
    const record = try deserialize(Record, arena.allocator(), src, .{});

    try std.testing.expectEqual(@as(u32, 1), record.id);
    try std.testing.expectEqualStrings("foo_0", record.name);
    try std.testing.expectEqual(@as(f64, 0.5), record.score);
    try std.testing.expect(record.active);
    try std.testing.expectEqualStrings("verified", record.tags[1]);
}

test "jzon zon: deserialize, left-out fields take their defaults" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const src = ".{ .id = 1, .name = \"a\", .score = 1, .active = false, .tags = .{} }";
    const record = try deserialize(Record, arena.allocator(), src, .{});

    try std.testing.expectEqual(Status.PENDING, record.status);
    try std.testing.expectEqual(@as(?[]const u8, null), record.note);
}

test "jzon zon: deserialize, reads an enum literal" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const status = try deserialize(Status, arena.allocator(), ".SHIPPED", .{});

    try std.testing.expectEqual(Status.SHIPPED, status);
}

test "jzon zon: deserialize, reads a quoted enum literal" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const status = try deserialize(Status, arena.allocator(), ".@\"PENDING\"", .{});

    try std.testing.expectEqual(Status.PENDING, status);
}

test "jzon zon: deserialize, reads a quoted field name" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const point = try deserialize(Point, arena.allocator(), ".{ .@\"x\" = 1, .y = 2 }", .{});

    try std.testing.expectEqual(@as(i32, 1), point.x);
}

test "jzon zon: deserialize, reads a quoted field name with an escape" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const point = try deserialize(Point, arena.allocator(), ".{ .@\"\\x78\" = 3, .y = 2 }", .{});

    try std.testing.expectEqual(@as(i32, 3), point.x);
}

test "jzon zon: deserialize, reads optional null" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const value = try deserialize(?u8, arena.allocator(), "null", .{});

    try std.testing.expectEqual(@as(?u8, null), value);
}

test "jzon zon: deserialize, reads optional value" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectEqual(@as(?u8, 7), try deserialize(?u8, arena.allocator(), "7", .{}));
}

test "jzon zon: deserialize, reads nested struct and array" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const Shape = struct {
        corners: [2]Point,
        grid: []const []const u16,
    };
    const src = ".{ .corners = .{ .{ .x = 1, .y = 2 }, .{ .x = 3, .y = 4 } }, " ++
        ".grid = .{ .{ 1, 2 }, .{} } }";
    const shape = try deserialize(Shape, arena.allocator(), src, .{});

    try std.testing.expectEqual(@as(i32, 4), shape.corners[1].y);
    try std.testing.expectEqual(@as(u16, 2), shape.grid[0][1]);
    try std.testing.expectEqual(@as(usize, 0), shape.grid[1].len);
}

test "jzon zon: deserialize, reads integers in every base" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const src = ".{ 10, 0x1F, 0o17, 0b101, -1_000 }";
    const numbers = try deserialize([5]i32, arena.allocator(), src, .{});

    try std.testing.expectEqual([5]i32{ 10, 31, 15, 5, -1000 }, numbers);
}

test "jzon zon: deserialize, reads integer literal into a float" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectEqual(@as(f64, 2), try deserialize(f64, arena.allocator(), "2", .{}));
}

test "jzon zon: deserialize, reads hex float" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const value = try deserialize(f64, arena.allocator(), "0x1.8p1", .{});

    try std.testing.expectEqual(@as(f64, 3), value);
}

test "jzon zon: deserialize, reads inf and negative inf" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const values = try deserialize([2]f64, arena.allocator(), ".{ inf, -inf }", .{});

    try std.testing.expect(std.math.isPositiveInf(values[0]));
    try std.testing.expect(std.math.isNegativeInf(values[1]));
}

test "jzon zon: deserialize, reads nan" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expect(std.math.isNan(try deserialize(f32, arena.allocator(), "nan", .{})));
}

test "jzon zon: deserialize, decodes string escapes" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const src = "\"a\\n\\t\\\"\\x41\\u{e9}\"";
    const text = try deserialize([]const u8, arena.allocator(), src, .{});

    try std.testing.expectEqualStrings("a\n\t\"A\xc3\xa9", text);
}

test "jzon zon: deserialize, reads a multiline string" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const src = "\\\\first\r\n    // between\n  \\\\second\n";
    const text = try deserialize([]const u8, arena.allocator(), src, .{});

    try std.testing.expectEqualStrings("first\nsecond", text);
}

test "jzon zon: deserialize, reads a multiline string field" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const Doc = struct {
        body: []const u8,
        after: u8,
    };
    const src = ".{\n    .body =\n        \\\\one\n        \\\\two\n    ,\n    .after = 1,\n}";
    const doc = try deserialize(Doc, arena.allocator(), src, .{});

    try std.testing.expectEqualStrings("one\ntwo", doc.body);
    try std.testing.expectEqual(@as(u8, 1), doc.after);
}

test "jzon zon: deserialize, BORROW points a clean string into the document" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const src = "\"clean\"";
    const text = try deserialize([]const u8, arena.allocator(), src, .{ .strings = .BORROW });

    try std.testing.expectEqual(@intFromPtr(src.ptr + 1), @intFromPtr(text.ptr));
}

test "jzon zon: deserialize, BORROW points a one-line multiline string into the document" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const src = "\\\\line\n";
    const text = try deserialize([]const u8, arena.allocator(), src, .{ .strings = .BORROW });

    try std.testing.expectEqual(@intFromPtr(src.ptr + 2), @intFromPtr(text.ptr));
}

test "jzon zon: deserialize, BORROW still decodes an escaped string" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const src = "\"a\\tb\"";
    const text = try deserialize([]const u8, arena.allocator(), src, .{ .strings = .BORROW });

    try std.testing.expectEqualStrings("a\tb", text);
}

test "jzon zon: deserialize, COPY does not point into the document" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const src = "\"clean\"";
    const text = try deserialize([]const u8, arena.allocator(), src, .{});

    try std.testing.expect(@intFromPtr(text.ptr) != @intFromPtr(src.ptr + 1));
    try std.testing.expectEqualStrings("clean", text);
}

test "jzon zon: deserialize, steps over comments and whitespace" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const src = "// head\n.{ // open\n  .x = 1, /// doc\n  .y = 2 // tail\n}\n// end";
    const point = try deserialize(Point, arena.allocator(), src, .{});

    try std.testing.expectEqual(@as(i32, 2), point.y);
}

test "jzon zon: deserialize, takes a trailing comma" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const point = try deserialize(Point, arena.allocator(), ".{ .x = 1, .y = 2, }", .{});

    try std.testing.expectEqual(@as(i32, 1), point.x);
}

test "jzon zon: deserialize, SKIP steps over an unknown key of any shape" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const src = ".{ .deps = .{ .a = .{ .url = \"u\", .lazy = true }, " ++
        ".b = .{ 1, .tag, -inf } }, " ++
        ".text = \\\\raw\n, .x = 1, .gone = null, .y = 2 }";
    const point = try deserialize(Point, arena.allocator(), src, .{ .unknown = .SKIP });

    try std.testing.expectEqual(@as(i32, 1), point.x);
    try std.testing.expectEqual(@as(i32, 2), point.y);
}

test "jzon zon: deserialize, REJECT refuses an unknown key" {
    const src = ".{ .x = 1, .z = 3, .y = 2 }";

    try expectFails(Point, src, .{}, Error.Jzon_ZonDeserialize_UnknownField);
}

test "jzon zon: deserialize, REJECT notes the unknown key" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    Failure.reset();
    const result = deserialize(Point, arena.allocator(), ".{ .x = 1, .zed = 3 }", .{});

    try std.testing.expectError(Error.Jzon_ZonDeserialize_UnknownField, result);

    const failure = Failure.lastFailure();

    try std.testing.expectEqualStrings("zed", failure.field);
    try std.testing.expectEqual(@as(usize, 12), failure.offset);
}

test "jzon zon: deserialize, duplicate key is unexpected" {
    const src = ".{ .x = 1, .x = 2, .y = 3 }";

    try expectFails(Point, src, .{}, Error.Jzon_ZonDeserialize_Unexpected);
}

test "jzon zon: deserialize, duplicate key notes the name" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    Failure.reset();
    const result = deserialize(Point, arena.allocator(), ".{ .x = 1, .x = 2 }", .{});

    try std.testing.expectError(Error.Jzon_ZonDeserialize_Unexpected, result);

    try std.testing.expectEqualStrings("x", Failure.lastFailure().field);
}

test "jzon zon: deserialize, missing field without a default" {
    try expectFails(Point, ".{ .x = 1 }", .{}, Error.Jzon_ZonDeserialize_MissingField);
}

test "jzon zon: deserialize, missing field notes the name" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    Failure.reset();
    const result = deserialize(Point, arena.allocator(), ".{ .x = 1 }", .{});

    try std.testing.expectError(Error.Jzon_ZonDeserialize_MissingField, result);

    try std.testing.expectEqualStrings("y", Failure.lastFailure().field);
}

test "jzon zon: deserialize, unknown enum tag" {
    try expectFails(Status, ".GONE", .{}, Error.Jzon_ZonDeserialize_UnknownEnumValue);
}

test "jzon zon: deserialize, enum without a dot is unexpected" {
    try expectFails(Status, "PENDING", .{}, Error.Jzon_ZonDeserialize_Unexpected);
}

test "jzon zon: deserialize, empty document is truncated" {
    try expectFails(Point, "", .{}, Error.Jzon_ZonDeserialize_Truncated);
}

test "jzon zon: deserialize, cut struct is truncated" {
    try expectFails(Point, ".{ .x = 1, .y = ", .{}, Error.Jzon_ZonDeserialize_Truncated);
}

test "jzon zon: deserialize, cut after a value is truncated" {
    try expectFails(Point, ".{ .x = 1, .y = 2", .{}, Error.Jzon_ZonDeserialize_Truncated);
}

test "jzon zon: deserialize, cut string is truncated" {
    try expectFails([]const u8, "\"abc", .{}, Error.Jzon_ZonDeserialize_Truncated);
}

test "jzon zon: deserialize, cut field name is truncated" {
    try expectFails(Point, ".{ .", .{}, Error.Jzon_ZonDeserialize_Truncated);
}

test "jzon zon: deserialize, truncated notes the end offset" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    Failure.reset();
    const result = deserialize(Point, arena.allocator(), ".{ .x = 1", .{});

    try std.testing.expectError(Error.Jzon_ZonDeserialize_Truncated, result);

    try std.testing.expectEqual(@as(usize, 9), Failure.lastFailure().offset);
}

test "jzon zon: deserialize, JSON object is unexpected" {
    try expectFails(Point, "{\"x\": 1, \"y\": 2}", .{}, Error.Jzon_ZonDeserialize_Unexpected);
}

test "jzon zon: deserialize, missing equals is unexpected" {
    try expectFails(Point, ".{ .x 1, .y = 2 }", .{}, Error.Jzon_ZonDeserialize_Unexpected);
}

test "jzon zon: deserialize, missing comma is unexpected" {
    try expectFails(Point, ".{ .x = 1 .y = 2 }", .{}, Error.Jzon_ZonDeserialize_Unexpected);
}

test "jzon zon: deserialize, lone comma is unexpected" {
    try expectFails([]const u32, ".{ , }", .{}, Error.Jzon_ZonDeserialize_Unexpected);
}

test "jzon zon: deserialize, trailing bytes are unexpected" {
    try expectFails(u8, "1 2", .{}, Error.Jzon_ZonDeserialize_Unexpected);
}

test "jzon zon: deserialize, bool word that is not true or false is unexpected" {
    try expectFails(bool, "yes", .{}, Error.Jzon_ZonDeserialize_Unexpected);
}

test "jzon zon: deserialize, line break in a string is unexpected" {
    try expectFails([]const u8, "\"a\nb\"", .{}, Error.Jzon_ZonDeserialize_Unexpected);
}

test "jzon zon: deserialize, unknown word is unexpected under SKIP" {
    try expectFails(Point, ".{ .z = maybe, .x = 1, .y = 2 }", .{
        .unknown = .SKIP,
    }, Error.Jzon_ZonDeserialize_Unexpected);
}

test "jzon zon: deserialize, array with too few elements is unexpected" {
    try expectFails([3]u8, ".{ 1, 2 }", .{}, Error.Jzon_ZonDeserialize_Unexpected);
}

test "jzon zon: deserialize, array with too many elements is unexpected" {
    try expectFails([1]u8, ".{ 1, 2 }", .{}, Error.Jzon_ZonDeserialize_Unexpected);
}

test "jzon zon: deserialize, integer past the type is a bad number" {
    try expectFails(u8, "256", .{}, Error.Jzon_ZonDeserialize_BadNumber);
}

test "jzon zon: deserialize, negative into unsigned is a bad number" {
    try expectFails(u8, "-1", .{}, Error.Jzon_ZonDeserialize_BadNumber);
}

test "jzon zon: deserialize, float into an integer is a bad number" {
    try expectFails(u8, "1.5", .{}, Error.Jzon_ZonDeserialize_BadNumber);
}

test "jzon zon: deserialize, leading zero is a bad number" {
    try expectFails(u8, "012", .{}, Error.Jzon_ZonDeserialize_BadNumber);
}

test "jzon zon: deserialize, double underscore is a bad number" {
    try expectFails(u32, "1__0", .{}, Error.Jzon_ZonDeserialize_BadNumber);
}

test "jzon zon: deserialize, digits run into letters is a bad number" {
    try expectFails(u32, "12ab", .{}, Error.Jzon_ZonDeserialize_BadNumber);
}

test "jzon zon: deserialize, plus sign is unexpected" {
    try expectFails(u32, "+1", .{}, Error.Jzon_ZonDeserialize_Unexpected);
}

test "jzon zon: deserialize, negative nan is unexpected" {
    try expectFails(f64, "-nan", .{}, Error.Jzon_ZonDeserialize_Unexpected);
}

test "jzon zon: deserialize, inf into an integer is a bad number" {
    try expectFails(i32, "inf", .{}, Error.Jzon_ZonDeserialize_BadNumber);
}

test "jzon zon: deserialize, bad string escape" {
    try expectFails([]const u8, "\"a\\qb\"", .{}, Error.Jzon_ZonDeserialize_BadEscape);
}

test "jzon zon: deserialize, bad escape in a quoted name" {
    try expectFails(Point, ".{ .@\"\\q\" = 1 }", .{}, Error.Jzon_ZonDeserialize_BadEscape);
}

test "jzon zon: deserialize, nesting past max_depth is unexpected" {
    const Deep = struct {
        inner: struct {
            inner: struct {
                value: u8,
            },
        },
    };
    const src = ".{ .inner = .{ .inner = .{ .value = 1 } } }";

    try expectFails(Deep, src, .{ .max_depth = 2 }, Error.Jzon_ZonDeserialize_Unexpected);
}

test "jzon zon: deserialize, nesting at max_depth is read" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const grid = try deserialize([]const []const u16, arena.allocator(), ".{ .{ 1 } }", .{
        .max_depth = 2,
    });

    try std.testing.expectEqual(@as(u16, 1), grid[0][0]);
}

test "jzon zon: deserialize, SKIP still holds the depth cap" {
    const src = ".{ .deep = .{ .{ .{ 1 } } }, .x = 1, .y = 2 }";

    try expectFails(Point, src, .{
        .unknown = .SKIP,
        .max_depth = 3,
    }, Error.Jzon_ZonDeserialize_Unexpected);
}

test "jzon zon: deserialize, max_depth of zero refuses any container" {
    const src = ".{ .x = 1, .y = 2 }";

    try expectFails(Point, src, .{ .max_depth = 0 }, Error.Jzon_ZonDeserialize_Unexpected);
}

test "jzon zon: deserialize, out of memory is reported" {
    var failing: std.testing.FailingAllocator = .init(
        std.testing.allocator,
        .{ .fail_index = 0 },
    );

    const result = deserialize([]const u8, failing.allocator(), "\"text\"", .{});

    try std.testing.expectError(Error.Jzon_ZonDeserialize_OutOfMemory, result);
}

test "jzon zon: deserialize, innerError keeps every own member" {
    inline for (@typeInfo(Error).error_set.error_names.?) |name| {
        const own = @field(Error, name);

        try std.testing.expectEqual(own, innerError(own));
    }
}

test "jzon zon: deserialize, innerError renames every grammar member" {
    try std.testing.expectEqual(
        Error.Jzon_ZonDeserialize_Truncated,
        innerError(grammar.Error.Jzon_ZonGrammar_Truncated),
    );
    try std.testing.expectEqual(
        Error.Jzon_ZonDeserialize_Unexpected,
        innerError(grammar.Error.Jzon_ZonGrammar_Unexpected),
    );
}

test "jzon zon: deserialize, innerError renames every fields member" {
    try std.testing.expectEqual(
        Error.Jzon_ZonDeserialize_Unexpected,
        innerError(fields.Error.Jzon_Fields_Unexpected),
    );
    try std.testing.expectEqual(
        Error.Jzon_ZonDeserialize_MissingField,
        innerError(fields.Error.Jzon_Fields_MissingField),
    );
}

