//! JZON zon serialize
//!
//! ### file: src/jzon/src/zon/serialize.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Write a typed value as ZON text into a caller buffer, multiline or compact.
//!
//! ### note:
//!
//! Covers the same shapes `deserialize.zig` reads, so whatever this writes reads back to
//! the same value. A name that is not a plain Zig identifier (a keyword such as
//! `type`, or one with a space) is written as `.@"..."`. A string that is not valid
//! UTF-8 has its bytes from 0x80 up written as `\xNN`, so the text stays valid Zig.
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
const Sink = @import("../Sink.zig");
const integer = @import("../integer.zig");
const reflect = @import("../reflect.zig");
const ZonOptions = @import("ZonOptions.zig");

// --------------------------------------------------------- //
// Private:

/// Every failure a private function here can hand back: this module's own set joined
/// with the sink's and the integer writer's.
const Inner = Error || Sink.Error || integer.Error;

/// Spaces per indent level in the MULTILINE layout.
const INDENT_WIDTH = 4;

/// Indent levels one MULTILINE break covers in a single copy. Deeper levels loop.
const BREAK_LEVELS = 16;

/// A line feed followed by the spaces of BREAK_LEVELS levels, sliced per break.
const BREAK: [1 + BREAK_LEVELS * INDENT_WIDTH]u8 = blk: {
    var bytes: [1 + BREAK_LEVELS * INDENT_WIDTH]u8 = @splat(' ');
    bytes[0] = '\n';

    break :blk bytes;
};

/// Lowercase hex digits for `\xNN`.
const HEX = "0123456789abcdef";

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
        error.Jzon_ZonSerialize_NoSpaceLeft => Error.Jzon_ZonSerialize_NoSpaceLeft,
        error.Jzon_ZonSerialize_BadNumber => Error.Jzon_ZonSerialize_BadNumber,
        error.Jzon_Sink_NoSpaceLeft => Error.Jzon_ZonSerialize_NoSpaceLeft,
        error.Jzon_Integer_NoSpaceLeft => Error.Jzon_ZonSerialize_NoSpaceLeft,
        error.Jzon_Integer_BadNumber => Error.Jzon_ZonSerialize_BadNumber,
    };
}

/// Write one value, picking the writing from its type at compile time.
///
/// Param:
/// sink - *Sink (where the text goes)
/// value - anytype (the value to write)
/// options - ZonOptions (comptime, `layout` and `hex_fields` are read)
/// level - usize (how many containers enclose this value)
///
/// Return:
/// - void
/// - Inner (a full buffer, translated once by `serialize`)
fn writeValue(
    sink: *Sink,
    value: anytype,
    comptime options: ZonOptions,
    level: usize,
) Inner!void {
    const Value = @TypeOf(value);

    switch (@typeInfo(Value)) {
        .bool => if (value) try sink.literal("true") else try sink.literal("false"),
        .int => try integer.appendTable(sink, value),
        .float => try writeFloat(sink, value),

        .optional => if (value) |inner| {
            try writeValue(sink, inner, options, level);
        } else {
            try sink.literal("null");
        },

        .@"enum" => {
            if (!reflect.isExhaustive(Value)) @compileError(
                "jzon zon: " ++ @typeName(Value) ++ " is not exhaustive, so it has no ZON form",
            );

            switch (value) {
                inline else => |tag| try sink.literal(comptime "." ++ spellName(@tagName(tag))),
            }
        },

        .@"struct" => |info| {
            if (info.is_tuple) @compileError(
                "jzon zon: " ++ @typeName(Value) ++
                    " is a tuple, which jzon zon does not take. Use an array",
            );

            try writeStruct(sink, value, options, level);
        },

        .array => try writeList(sink, value, options, level),

        .pointer => |info| {
            if (info.size != .slice) {
                @compileError("jzon zon: " ++ @typeName(Value) ++ " is not a slice");
            }

            if (info.child == u8) {
                try writeString(sink, value);
            } else {
                try writeList(sink, value, options, level);
            }
        },

        else => @compileError("jzon zon: " ++ @typeName(Value) ++ " has no ZON form"),
    }
}

/// Write a float, with `inf`, `-inf` and `nan` as Zig spells them.
///
/// Param:
/// sink - *Sink (where the text goes)
/// value - anytype (any float width)
///
/// Return:
/// - void
/// - Error.Jzon_ZonSerialize_NoSpaceLeft when the digits do not fit
fn writeFloat(sink: *Sink, value: anytype) Inner!void {
    if (std.math.isNan(value)) return sink.literal("nan");
    if (std.math.isPositiveInf(value)) return sink.literal("inf");
    if (std.math.isNegativeInf(value)) return sink.literal("-inf");

    const printed = std.fmt.bufPrint(sink.tail(), "{}", .{value}) catch |err| switch (err) {
        error.NoSpaceLeft => return Error.Jzon_ZonSerialize_NoSpaceLeft,
    };

    try sink.commit(printed.len);
}

/// Write an integer as `0x...`, or `-0x...` when it is negative.
///
/// Param:
/// sink - *Sink (where the text goes)
/// value - anytype (any integer width)
///
/// Return:
/// - void
/// - Error.Jzon_ZonSerialize_NoSpaceLeft when the digits do not fit
fn writeHex(sink: *Sink, value: anytype) Inner!void {
    if (value < 0) try sink.byte('-');

    try sink.literal("0x");

    const magnitude = @abs(value);
    const printed = std.fmt.bufPrint(sink.tail(), "{x}", .{magnitude}) catch |err| switch (err) {
        error.NoSpaceLeft => return Error.Jzon_ZonSerialize_NoSpaceLeft,
    };

    try sink.commit(printed.len);
}

/// Write a field named in `hex_fields`: an integer as hex, a null as `null`.
///
/// Param:
/// sink - *Sink (where the text goes)
/// value - anytype (an integer or an optional integer)
/// name - []const u8 (comptime, the field name, for the compile error)
///
/// Return:
/// - void
/// - Error.Jzon_ZonSerialize_NoSpaceLeft when the text does not fit
fn writeHexField(sink: *Sink, value: anytype, comptime name: []const u8) Inner!void {
    switch (@typeInfo(@TypeOf(value))) {
        .int => try writeHex(sink, value),

        .optional => |info| {
            if (@typeInfo(info.child) != .int) hexNotInteger(name, @TypeOf(value));

            if (value) |inner| try writeHex(sink, inner) else try sink.literal("null");
        },

        else => hexNotInteger(name, @TypeOf(value)),
    }
}

/// Stop the build: a name in `hex_fields` belongs to a field that is not an integer.
///
/// Param:
/// name - []const u8 (comptime, the field name)
/// Field - type (the field's type)
fn hexNotInteger(comptime name: []const u8, comptime Field: type) noreturn {
    @compileError("jzon zon: hex field \"" ++ name ++ "\" is " ++ @typeName(Field) ++
        ", not an integer");
}

/// Whether a name is in `hex_fields`.
///
/// Param:
/// hex_fields - []const []const u8 (comptime, the names from the options)
/// name - []const u8 (comptime, the field name)
///
/// Return:
/// - bool (true when the field is written as hex)
fn isHexField(comptime hex_fields: []const []const u8, comptime name: []const u8) bool {
    comptime {
        for (hex_fields) |hex_name| {
            if (std.mem.eql(u8, hex_name, name)) return true;
        }

        return false;
    }
}

/// Whether a struct reachable from a type has a field with this name.
///
/// Param:
/// Value - type (comptime, the type to search)
/// name - []const u8 (comptime, the field name)
/// seen - []const type (comptime, the types already searched, so a type that holds
///   itself does not loop)
///
/// Return:
/// - bool (true when some struct inside has the field)
fn hasField(comptime Value: type, comptime name: []const u8, comptime seen: []const type) bool {
    comptime {
        for (seen) |done| {
            if (done == Value) return false;
        }

        const next = seen ++ [_]type{Value};

        return switch (@typeInfo(Value)) {
            .optional => |info| hasField(info.child, name, next),
            .array => |info| hasField(info.child, name, next),
            .pointer => |info| hasField(info.child, name, next),

            .@"struct" => |info| found: {
                for (info.field_names, info.field_types) |field_name, Field| {
                    if (!info.is_tuple and std.mem.eql(u8, field_name, name)) break :found true;
                    if (hasField(Field, name, next)) break :found true;
                }

                break :found false;
            },

            else => false,
        };
    }
}

/// Stop the build when a name in `hex_fields` is not a field anywhere in the value.
///
/// Param:
/// Value - type (comptime, the type being written)
/// hex_fields - []const []const u8 (comptime, the names from the options)
fn checkHexFields(comptime Value: type, comptime hex_fields: []const []const u8) void {
    comptime {
        for (hex_fields) |name| {
            if (!hasField(Value, name, &.{})) @compileError(
                "jzon zon: hex field \"" ++ name ++ "\" is not a field of " ++ @typeName(Value),
            );
        }
    }
}

/// Spell a field or tag name at compile time, quoted as `@"..."` when it is not a
/// plain identifier.
///
/// Note:
/// - Names come from Zig source, so they are valid UTF-8 and bytes from 0x80 up stay
///   raw. Every other byte follows the same rules `writeEscape` writes at runtime.
///
/// Param:
/// name - []const u8 (comptime, the name)
///
/// Return:
/// - []const u8 (the spelling, a comptime constant)
fn spellName(comptime name: []const u8) []const u8 {
    comptime {
        if (std.zig.isValidId(name)) return name;

        var quoted: []const u8 = "@\"";

        for (name) |byte| {
            quoted = quoted ++ if (shortEscape(byte)) |short|
                short
            else if (isControl(byte))
                std.fmt.comptimePrint("\\x{x:0>2}", .{byte})
            else
                &[_]u8{byte};
        }

        return quoted ++ "\"";
    }
}

/// The two-character escape Zig has for a byte.
///
/// Param:
/// byte - u8 (the byte to spell)
///
/// Return:
/// - ?[]const u8 (the escape, or null when the byte has no short form)
fn shortEscape(byte: u8) ?[]const u8 {
    return switch (byte) {
        '"' => "\\\"",
        '\\' => "\\\\",
        '\n' => "\\n",
        '\r' => "\\r",
        '\t' => "\\t",
        else => null,
    };
}

/// Whether a byte is a control byte Zig does not take raw in a string.
///
/// Param:
/// byte - u8 (the byte to classify)
///
/// Return:
/// - bool (true below 0x20 and for 0x7f)
fn isControl(byte: u8) bool {
    return byte < 0x20 or byte == 0x7f;
}

/// Write a quoted string, escaping what Zig does not take raw.
///
/// Param:
/// sink - *Sink (where the text goes)
/// text - []const u8 (the bytes)
///
/// Return:
/// - void
/// - Error.Jzon_ZonSerialize_NoSpaceLeft when the text does not fit
fn writeString(sink: *Sink, text: []const u8) Inner!void {
    try sink.byte('"');

    // Checked only once a byte from 0x80 up shows up, so ASCII text never pays for it.
    var raw_high: ?bool = null;
    var run_start: usize = 0;

    for (text, 0..) |byte, index| {
        const plain = switch (byte) {
            '"', '\\', 0...31, 127 => false,
            128...255 => high: {
                if (raw_high == null) raw_high = std.unicode.utf8ValidateSlice(text);

                break :high raw_high.?;
            },
            else => true,
        };
        if (plain) continue;

        try sink.bytes(text[run_start..index]);
        try writeEscape(sink, byte);
        run_start = index + 1;
    }

    try sink.bytes(text[run_start..]);
    try sink.byte('"');
}

/// Write the escape for one byte.
///
/// Param:
/// sink - *Sink (where the text goes)
/// byte - u8 (the byte to escape)
///
/// Return:
/// - void
/// - Error.Jzon_ZonSerialize_NoSpaceLeft when the escape does not fit
fn writeEscape(sink: *Sink, byte: u8) Inner!void {
    if (shortEscape(byte)) |short| return sink.bytes(short);

    const hex = [4]u8{
        '\\',
        'x',
        HEX[byte >> 4],
        HEX[byte & 0x0f],
    };

    try sink.bytes(&hex);
}

/// Step to where the next entry starts: a new line and its indent, or one space.
///
/// Param:
/// sink - *Sink (where the text goes)
/// layout - ZonOptions.Layout (comptime, multiline or compact)
/// level - usize (the indent level of the entry)
///
/// Return:
/// - void
/// - Error.Jzon_ZonSerialize_NoSpaceLeft when the break does not fit
fn writeBreak(sink: *Sink, comptime layout: ZonOptions.Layout, level: usize) Inner!void {
    switch (layout) {
        .COMPACT => try sink.byte(' '),

        .MULTILINE => {
            const levels: usize = @min(level, BREAK_LEVELS);
            try sink.bytes(BREAK[0 .. 1 + levels * INDENT_WIDTH]);

            for (BREAK_LEVELS..@max(level, BREAK_LEVELS)) |_| {
                try sink.bytes(BREAK[1 .. 1 + INDENT_WIDTH]);
            }
        },
    }
}

/// Write what follows an entry: `,` always in MULTILINE, `,` between entries in
/// COMPACT.
///
/// Param:
/// sink - *Sink (where the text goes)
/// layout - ZonOptions.Layout (comptime, multiline or compact)
/// is_last - bool (whether this is the container's last entry)
///
/// Return:
/// - void
/// - Error.Jzon_ZonSerialize_NoSpaceLeft when the comma does not fit
fn writeSeparator(sink: *Sink, comptime layout: ZonOptions.Layout, is_last: bool) Inner!void {
    if (layout == .MULTILINE or !is_last) try sink.byte(',');
}

/// Write a struct as `.{ .name = value, ... }`.
///
/// Param:
/// sink - *Sink (where the text goes)
/// value - anytype (the struct)
/// options - ZonOptions (comptime, `layout` and `hex_fields` are read)
/// level - usize (how many containers enclose this one)
///
/// Return:
/// - void
/// - Error.Jzon_ZonSerialize_NoSpaceLeft when the text does not fit
fn writeStruct(
    sink: *Sink,
    value: anytype,
    comptime options: ZonOptions,
    level: usize,
) Inner!void {
    const layout = options.layout;
    const names = comptime std.meta.fieldNames(@TypeOf(value));

    if (names.len == 0) return sink.literal(".{}");

    try sink.literal(".{");

    inline for (names, 0..) |name, index| {
        const key = comptime "." ++ spellName(name) ++ " = ";

        switch (layout) {
            // The comma before, the space and the name are all comptime, so they go
            // out as one copy.
            .COMPACT => try sink.literal(comptime (if (index == 0) " " else ", ") ++ key),

            .MULTILINE => {
                try writeBreak(sink, layout, level + 1);
                try sink.literal(key);
            },
        }

        if (comptime isHexField(options.hex_fields, name)) {
            try writeHexField(sink, @field(value, name), name);
        } else {
            try writeValue(sink, @field(value, name), options, level + 1);
        }

        if (layout == .MULTILINE) try sink.byte(',');
    }

    try writeBreak(sink, layout, level);
    try sink.byte('}');
}

/// Write a slice or an array as `.{ a, b, ... }`.
///
/// Param:
/// sink - *Sink (where the text goes)
/// items - anytype (the elements)
/// options - ZonOptions (comptime, `layout` and `hex_fields` are read)
/// level - usize (how many containers enclose this one)
///
/// Return:
/// - void
/// - Error.Jzon_ZonSerialize_NoSpaceLeft when the text does not fit
fn writeList(
    sink: *Sink,
    items: anytype,
    comptime options: ZonOptions,
    level: usize,
) Inner!void {
    const layout = options.layout;

    if (items.len == 0) return sink.literal(".{}");

    try sink.literal(".{");

    for (items, 0..) |item, index| {
        try writeBreak(sink, layout, level + 1);
        try writeValue(sink, item, options, level + 1);
        try writeSeparator(sink, layout, index + 1 == items.len);
    }

    try writeBreak(sink, layout, level);
    try sink.byte('}');
}

// --------------------------------------------------------- //
// Public:

/// Every way a ZON serialize can fail.
///
/// Note:
/// - NoSpaceLeft is the only failure a write meets: nothing is allocated, so a full
///   buffer is the whole write surface.
/// - BadNumber is never returned. It is here because the integer writer's set has it,
///   and every member that set carries maps to a real one here.
pub const Error = error{
    Jzon_ZonSerialize_NoSpaceLeft,
    Jzon_ZonSerialize_BadNumber,
};

/// Write a typed value as ZON text into `buf`.
///
/// Note:
/// - The text ends at the closing `}` or the last value byte, with no trailing line
///   feed. Add one when the text goes to a file.
///
/// Param:
/// buf - []u8 (where the ZON text goes, caller owned)
/// value - anytype (the value to write)
/// options - ZonOptions (comptime, `layout` and `hex_fields` are read)
///
/// Usage:
/// ```zig
/// var buf: [4 * 1024]u8 = undefined;
///
/// const len = try jzon.zon.serialize(&buf, package, .{});
/// const compact = try jzon.zon.serialize(&buf, package, .{ .layout = .COMPACT });
/// const hex = try jzon.zon.serialize(&buf, package, .{
///     .hex_fields = &.{"fingerprint"},
/// });
/// ```
///
/// Return:
/// - usize (how many bytes of `buf` the value took)
/// - Error.Jzon_ZonSerialize_NoSpaceLeft when the text does not fit
pub fn serialize(buf: []u8, value: anytype, comptime options: ZonOptions) Error!usize {
    comptime checkHexFields(@TypeOf(value), options.hex_fields);

    var sink: Sink = .init(buf);

    writeValue(&sink, value, options, 0) catch |err| return innerError(err);

    return sink.written();
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const deserialize = @import("deserialize.zig").deserialize;

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

const RECORD: Record = .{
    .id = 1,
    .name = "foo_0",
    .score = 0.5,
    .active = true,
    .tags = &.{ "urgent", "verified" },
    .status = .SHIPPED,
    .note = null,
};

/// A string literal as the slice type a record field holds.
fn asSlice(comptime literal: []const u8) []const u8 {
    return literal;
}

/// A list nested `depth` levels deep, for indent cases.
fn Nest(comptime depth: usize) type {
    if (depth == 0) return u8;

    return [1]Nest(depth - 1);
}

/// Emit into a fixed buffer and compare with the expected text.
fn expectEmits(expected: []const u8, value: anytype, comptime options: ZonOptions) !void {
    var buf: [1024]u8 = undefined;

    const len = try serialize(&buf, value, options);

    try std.testing.expectEqualStrings(expected, buf[0..len]);
}

/// Emit, parse back with a fresh arena, and compare with the value.
fn expectRoundTrip(comptime Target: type, value: Target, comptime options: ZonOptions) !void {
    var buf: [1024]u8 = undefined;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const len = try serialize(&buf, value, options);
    const back = try deserialize(Target, arena.allocator(), buf[0..len], .{});

    try std.testing.expectEqualDeep(value, back);
}

test "jzon zon: serialize, MULTILINE record" {
    const expected =
        \\.{
        \\    .id = 1,
        \\    .name = "foo_0",
        \\    .score = 0.5,
        \\    .active = true,
        \\    .tags = .{
        \\        "urgent",
        \\        "verified",
        \\    },
        \\    .status = .SHIPPED,
        \\    .note = null,
        \\}
    ;

    try expectEmits(expected, RECORD, .{});
}

test "jzon zon: serialize, COMPACT record" {
    const expected = ".{ .id = 1, .name = \"foo_0\", .score = 0.5, .active = true, " ++
        ".tags = .{ \"urgent\", \"verified\" }, .status = .SHIPPED, .note = null }";

    try expectEmits(expected, RECORD, .{ .layout = .COMPACT });
}

test "jzon zon: serialize, empty slice is an empty container" {
    const empty: []const u8 = &.{};
    const list: []const u32 = &.{};

    try expectEmits("\"\"", empty, .{});
    try expectEmits(".{}", list, .{});
}

test "jzon zon: serialize, empty struct is an empty container" {
    try expectEmits(".{}", struct {}{}, .{ .layout = .COMPACT });
}

test "jzon zon: serialize, array is a list" {
    try expectEmits(".{ 1, 2 }", [2]u8{ 1, 2 }, .{ .layout = .COMPACT });
}

test "jzon zon: serialize, optional value is written bare" {
    const value: ?u8 = 7;

    try expectEmits("7", value, .{});
}

test "jzon zon: serialize, float specials" {
    try expectEmits("inf", std.math.inf(f64), .{});
    try expectEmits("-inf", -std.math.inf(f64), .{});
    try expectEmits("nan", std.math.nan(f32), .{});
}

test "jzon zon: serialize, negative integer" {
    try expectEmits("-128", @as(i8, -128), .{});
}

test "jzon zon: serialize, string escapes" {
    try expectEmits("\"a\\n\\t\\r\\\"\\\\\\x01\\x7f\"", asSlice("a\n\t\r\"\\\x01\x7f"), .{});
}

test "jzon zon: serialize, valid UTF-8 stays raw" {
    try expectEmits("\"caf\xc3\xa9\"", asSlice("caf\xc3\xa9"), .{});
}

test "jzon zon: serialize, invalid UTF-8 is written as hex" {
    try expectEmits("\"a\\xff\"", asSlice("a\xff"), .{});
}

test "jzon zon: serialize, keyword field name is quoted" {
    const Keyed = struct {
        @"error": u8,
        @"two words": u8,
    };
    const value: Keyed = .{
        .@"error" = 1,
        .@"two words" = 2,
    };
    const expected = ".{ .@\"error\" = 1, .@\"two words\" = 2 }";

    try expectEmits(expected, value, .{ .layout = .COMPACT });
}

test "jzon zon: serialize, exact-fit buffer" {
    const point: Point = .{
        .x = 1,
        .y = 2,
    };
    const expected = ".{ .x = 1, .y = 2 }";

    var exact: [expected.len]u8 = undefined;
    const len = try serialize(&exact, point, .{ .layout = .COMPACT });

    try std.testing.expectEqualStrings(expected, exact[0..len]);
}

test "jzon zon: serialize, one byte short is no space left" {
    const point: Point = .{
        .x = 1,
        .y = 2,
    };
    const expected = ".{ .x = 1, .y = 2 }";

    var short: [expected.len - 1]u8 = undefined;

    try std.testing.expectError(
        Error.Jzon_ZonSerialize_NoSpaceLeft,
        serialize(&short, point, .{ .layout = .COMPACT }),
    );
}

test "jzon zon: serialize, float that does not fit is no space left" {
    var buf: [2]u8 = undefined;

    const value: f64 = 0.125;

    const result = serialize(&buf, value, .{});

    try std.testing.expectError(Error.Jzon_ZonSerialize_NoSpaceLeft, result);
}

test "jzon zon: serialize, empty buffer is no space left" {
    var buf: [0]u8 = undefined;

    try std.testing.expectError(Error.Jzon_ZonSerialize_NoSpaceLeft, serialize(&buf, true, .{}));
}

test "jzon zon: serialize, round trip record in both layouts" {
    try expectRoundTrip(Record, RECORD, .{});
    try expectRoundTrip(Record, RECORD, .{ .layout = .COMPACT });
}

test "jzon zon: serialize, round trip nested struct and array" {
    const Shape = struct {
        corners: [2]Point,
        grid: []const []const u16,
        maybe: ?Point,
    };
    const value: Shape = .{
        .corners = .{
            .{
                .x = -1,
                .y = 2,
            },
            .{
                .x = 3,
                .y = -4,
            },
        },
        .grid = &.{ &.{ 1, 2 }, &.{} },
        .maybe = null,
    };

    try expectRoundTrip(Shape, value, .{});
}

test "jzon zon: serialize, round trip escaped and non-ASCII strings" {
    const texts: []const []const u8 = &.{ "a\n\"b\"\\", "caf\xc3\xa9", "\xff\x00", "" };

    try expectRoundTrip([]const []const u8, texts, .{});
}

test "jzon zon: serialize, round trip quoted names" {
    const Keyed = struct {
        @"error": Status,
        @"two words": bool,
    };
    const value: Keyed = .{
        .@"error" = .SHIPPED,
        .@"two words" = true,
    };

    try expectRoundTrip(Keyed, value, .{});
}

test "jzon zon: serialize, round trip integer edges" {
    const Edges = struct {
        low: i64,
        high: u64,
        small: i8,
    };
    const value: Edges = .{
        .low = std.math.minInt(i64),
        .high = std.math.maxInt(u64),
        .small = -128,
    };

    try expectRoundTrip(Edges, value, .{});
}

test "jzon zon: serialize, round trip floats" {
    const values = [_]f64{ 0.1, -2.5e-300, 1e300, 0, std.math.inf(f64) };

    try expectRoundTrip([5]f64, values, .{});
}

test "jzon zon: serialize, round trip nan" {
    var buf: [16]u8 = undefined;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const len = try serialize(&buf, std.math.nan(f64), .{});

    const back = try deserialize(f64, arena.allocator(), buf[0..len], .{});

    try std.testing.expect(std.math.isNan(back));
}

test "jzon zon: serialize, innerError keeps every own member" {
    inline for (@typeInfo(Error).error_set.error_names.?) |name| {
        const own = @field(Error, name);

        try std.testing.expectEqual(own, innerError(own));
    }
}

test "jzon zon: serialize, innerError renames the sink member" {
    try std.testing.expectEqual(
        Error.Jzon_ZonSerialize_NoSpaceLeft,
        innerError(Sink.Error.Jzon_Sink_NoSpaceLeft),
    );
}

test "jzon zon: serialize, innerError renames every integer member" {
    try std.testing.expectEqual(
        Error.Jzon_ZonSerialize_NoSpaceLeft,
        innerError(integer.Error.Jzon_Integer_NoSpaceLeft),
    );
    try std.testing.expectEqual(
        Error.Jzon_ZonSerialize_BadNumber,
        innerError(integer.Error.Jzon_Integer_BadNumber),
    );
}

test "jzon zon: serialize, spellName keeps a plain identifier" {
    try std.testing.expectEqualStrings("name_1", comptime spellName("name_1"));
}

test "jzon zon: serialize, spellName quotes a keyword" {
    try std.testing.expectEqualStrings("@\"error\"", comptime spellName("error"));
}

test "jzon zon: serialize, spellName escapes a quote and a control byte" {
    try std.testing.expectEqualStrings("@\"a\\\"\\x01\"", comptime spellName("a\"\x01"));
}

test "jzon zon: serialize, shortEscape has no form for a plain byte" {
    try std.testing.expectEqual(@as(?[]const u8, null), shortEscape('a'));
}

test "jzon zon: serialize, isControl takes 0x1f and 0x7f only" {
    try std.testing.expect(isControl(0x1f));
    try std.testing.expect(isControl(0x7f));
    try std.testing.expect(!isControl(' '));
}

test "jzon zon: serialize, enum tag with a quoted name" {
    const Kind = enum { plain, @"two words" };

    try expectEmits(".@\"two words\"", Kind.@"two words", .{});
}

test "jzon zon: serialize, MULTILINE indent past BREAK_LEVELS" {
    const depth = BREAK_LEVELS + 2;

    var buf: [4096]u8 = undefined;
    const value = std.mem.zeroes(Nest(depth));
    const len = try serialize(&buf, value, .{});

    const deepest: [1 + depth * INDENT_WIDTH]u8 = blk: {
        var bytes: [1 + depth * INDENT_WIDTH]u8 = @splat(' ');
        bytes[0] = '\n';

        break :blk bytes;
    };

    try std.testing.expect(std.mem.indexOf(u8, buf[0..len], &deepest ++ "0,") != null);
}

test "jzon zon: serialize, round trip past BREAK_LEVELS" {
    const Deep = Nest(BREAK_LEVELS + 2);

    var buf: [4096]u8 = undefined;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const value = std.mem.zeroes(Deep);
    const len = try serialize(&buf, value, .{});
    const back = try deserialize(Deep, arena.allocator(), buf[0..len], .{});

    try std.testing.expectEqualDeep(value, back);
}

test "jzon zon: serialize, hex field is written as hex" {
    const Package = struct {
        major: u32,
        fingerprint: u64,
    };
    const value: Package = .{
        .major = 6,
        .fingerprint = 0x4cc61d74dc93a20b,
    };
    const expected = ".{ .major = 6, .fingerprint = 0x4cc61d74dc93a20b }";

    try expectEmits(expected, value, .{
        .layout = .COMPACT,
        .hex_fields = &.{"fingerprint"},
    });
}

test "jzon zon: serialize, every listed hex field is written as hex" {
    const Masks = struct {
        read: u8,
        write: u16,
        count: u8,
    };
    const value: Masks = .{
        .read = 0xff,
        .write = 0x1f,
        .count = 3,
    };
    const expected = ".{ .read = 0xff, .write = 0x1f, .count = 3 }";

    try expectEmits(expected, value, .{
        .layout = .COMPACT,
        .hex_fields = &.{
            "read",
            "write",
        },
    });
}

test "jzon zon: serialize, hex field matches at every depth" {
    const Item = struct { id: u8 };
    const Outer = struct {
        id: u8,
        items: []const Item,
    };
    const value: Outer = .{
        .id = 10,
        .items = &.{.{ .id = 11 }},
    };
    const expected = ".{ .id = 0xa, .items = .{ .{ .id = 0xb } } }";

    try expectEmits(expected, value, .{
        .layout = .COMPACT,
        .hex_fields = &.{"id"},
    });
}

test "jzon zon: serialize, negative hex field" {
    const Offset = struct { delta: i64 };
    const value: Offset = .{ .delta = std.math.minInt(i64) };

    try expectEmits(".{ .delta = -0x8000000000000000 }", value, .{
        .layout = .COMPACT,
        .hex_fields = &.{"delta"},
    });
}

test "jzon zon: serialize, zero hex field" {
    const Flags = struct { bits: u32 };
    const value: Flags = .{ .bits = 0 };

    try expectEmits(".{ .bits = 0x0 }", value, .{
        .layout = .COMPACT,
        .hex_fields = &.{"bits"},
    });
}

test "jzon zon: serialize, optional hex field" {
    const Maybe = struct {
        set: ?u16,
        unset: ?u16,
    };
    const value: Maybe = .{
        .set = 0xbeef,
        .unset = null,
    };
    const expected = ".{ .set = 0xbeef, .unset = null }";

    try expectEmits(expected, value, .{
        .layout = .COMPACT,
        .hex_fields = &.{
            "set",
            "unset",
        },
    });
}

test "jzon zon: serialize, hex field that does not fit is no space left" {
    const Package = struct { fingerprint: u64 };
    const value: Package = .{ .fingerprint = 0x4cc61d74dc93a20b };

    var buf: [24]u8 = undefined;

    try std.testing.expectError(
        Error.Jzon_ZonSerialize_NoSpaceLeft,
        serialize(&buf, value, .{
            .layout = .COMPACT,
            .hex_fields = &.{"fingerprint"},
        }),
    );
}

test "jzon zon: serialize, round trip hex fields in both layouts" {
    const Package = struct {
        major: u32,
        fingerprint: u64,
        delta: ?i32,
    };
    const value: Package = .{
        .major = 6,
        .fingerprint = 0x4cc61d74dc93a20b,
        .delta = -0x1f,
    };

    try expectRoundTrip(Package, value, .{ .hex_fields = &.{
        "fingerprint",
        "delta",
    } });
    try expectRoundTrip(Package, value, .{
        .layout = .COMPACT,
        .hex_fields = &.{"fingerprint"},
    });
}

test "jzon zon: serialize, isHexField finds a listed name" {
    try std.testing.expect(comptime isHexField(&.{
        "a",
        "fingerprint",
    }, "fingerprint"));
}

test "jzon zon: serialize, isHexField skips an unlisted name" {
    try std.testing.expect(!comptime isHexField(&.{"fingerprint"}, "major"));
}

test "jzon zon: serialize, hasField finds a nested field" {
    const Line = struct { sku: u8 };
    const Order = struct { lines: []const ?Line };

    try std.testing.expect(comptime hasField(Order, "sku", &.{}));
}

test "jzon zon: serialize, hasField misses an absent name" {
    try std.testing.expect(!comptime hasField(Point, "z", &.{}));
}

test "jzon zon: serialize, hasField skips tuple positions" {
    try std.testing.expect(!comptime hasField(struct { u8 }, "0", &.{}));
}

test "jzon zon: serialize, hasField stops on a type that holds itself" {
    const Tree = struct {
        value: u8,
        children: []const @This(),
    };

    try std.testing.expect(comptime hasField(Tree, "value", &.{}));
    try std.testing.expect(!comptime hasField(Tree, "missing", &.{}));
}

