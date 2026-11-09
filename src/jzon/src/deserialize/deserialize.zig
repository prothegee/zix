//! JZON deserialize
//!
//! ### file: src/jzon/src/deserialize/deserialize.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! The one call that turns JSON text into a typed value: runs the read path the options
//! name over the caller's document and builds the target type out of it.
//!
//! ### note:
//!
//! Everything the result points at comes from the allocator handed in, so an arena
//! reset frees a whole parse in one step. The generated strategies differ from `.STD`
//! in three places, each a shape no serialize path writes: a byte slice is a string and
//! never an array of numbers, a sign against an unsigned field is a type error, and a
//! broken escape is BadEscape (generated paths only) where std says Unexpected.
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
const ScanShape = @import("ScanShape.zig");
const generated_parser = @import("generated_parser.zig");
const scanner_parser = @import("scanner_parser.zig");
const std_parser = @import("std_parser.zig");

const Allocator = std.mem.Allocator;

// --------------------------------------------------------- //
// Private:

/// The width `.GENERATED` runs.
const SHAPE_SCALAR: ScanShape = .{ .scan = .SCALAR };

/// The width `.GENERATED_VECTOR` runs.
const SHAPE_VECTOR: ScanShape = .{ .scan = .VECTOR };

/// Every failure a private function here can hand back: the public set joined with
/// the sets of every read path.
const Inner = Error || std_parser.Error || scanner_parser.Error || generated_parser.Error;

/// Translate a failure from inside the module into the public set.
///
/// Param:
/// err - Inner (the failure a read path handed back)
///
/// Return:
/// - Error (the same failure under the public name)
inline fn innerError(err: Inner) Error {
    @branchHint(.cold);

    return switch (err) {
        error.Jzon_Deserialize_UnknownField => Error.Jzon_Deserialize_UnknownField,
        error.Jzon_Deserialize_MissingField => Error.Jzon_Deserialize_MissingField,
        error.Jzon_Deserialize_UnknownEnumValue => Error.Jzon_Deserialize_UnknownEnumValue,
        error.Jzon_Deserialize_Truncated => Error.Jzon_Deserialize_Truncated,
        error.Jzon_Deserialize_Unexpected => Error.Jzon_Deserialize_Unexpected,
        error.Jzon_Deserialize_BadNumber => Error.Jzon_Deserialize_BadNumber,
        error.Jzon_Deserialize_BadEscape => Error.Jzon_Deserialize_BadEscape,
        error.Jzon_Deserialize_NoSpaceLeft => Error.Jzon_Deserialize_NoSpaceLeft,
        error.Jzon_Deserialize_OutOfMemory => Error.Jzon_Deserialize_OutOfMemory,
        error.Jzon_StdParser_UnknownField => Error.Jzon_Deserialize_UnknownField,
        error.Jzon_StdParser_MissingField => Error.Jzon_Deserialize_MissingField,
        error.Jzon_StdParser_UnknownEnumValue => Error.Jzon_Deserialize_UnknownEnumValue,
        error.Jzon_StdParser_Truncated => Error.Jzon_Deserialize_Truncated,
        error.Jzon_StdParser_Unexpected => Error.Jzon_Deserialize_Unexpected,
        error.Jzon_StdParser_BadNumber => Error.Jzon_Deserialize_BadNumber,
        error.Jzon_StdParser_OutOfMemory => Error.Jzon_Deserialize_OutOfMemory,
        error.Jzon_ScannerParser_UnknownField => Error.Jzon_Deserialize_UnknownField,
        error.Jzon_ScannerParser_MissingField => Error.Jzon_Deserialize_MissingField,
        error.Jzon_ScannerParser_UnknownEnumValue => Error.Jzon_Deserialize_UnknownEnumValue,
        error.Jzon_ScannerParser_Truncated => Error.Jzon_Deserialize_Truncated,
        error.Jzon_ScannerParser_Unexpected => Error.Jzon_Deserialize_Unexpected,
        error.Jzon_ScannerParser_BadNumber => Error.Jzon_Deserialize_BadNumber,
        error.Jzon_ScannerParser_NoSpaceLeft => Error.Jzon_Deserialize_NoSpaceLeft,
        error.Jzon_ScannerParser_OutOfMemory => Error.Jzon_Deserialize_OutOfMemory,
        error.Jzon_GeneratedParser_UnknownField => Error.Jzon_Deserialize_UnknownField,
        error.Jzon_GeneratedParser_MissingField => Error.Jzon_Deserialize_MissingField,
        error.Jzon_GeneratedParser_UnknownEnumValue => Error.Jzon_Deserialize_UnknownEnumValue,
        error.Jzon_GeneratedParser_Truncated => Error.Jzon_Deserialize_Truncated,
        error.Jzon_GeneratedParser_Unexpected => Error.Jzon_Deserialize_Unexpected,
        error.Jzon_GeneratedParser_BadNumber => Error.Jzon_Deserialize_BadNumber,
        error.Jzon_GeneratedParser_BadEscape => Error.Jzon_Deserialize_BadEscape,
        error.Jzon_GeneratedParser_NoSpaceLeft => Error.Jzon_Deserialize_NoSpaceLeft,
        error.Jzon_GeneratedParser_OutOfMemory => Error.Jzon_Deserialize_OutOfMemory,
    };
}

/// The body of `deserialize`: run the path the strategy names.
///
/// Param:
/// Target - type (comptime, the type to build)
/// allocator - Allocator (owns everything the result points at)
/// src - []const u8 (the whole document)
/// options - DeserializeOptions (comptime, strategy, string mode and unknown key rule)
///
/// Return:
/// - Target (the parsed value)
/// - Inner (the read path's failure under its own name)
fn parseInto(
    comptime Target: type,
    allocator: Allocator,
    src: []const u8,
    comptime options: DeserializeOptions,
) Inner!Target {
    return switch (options.strategy) {
        .STD => std_parser.parse(Target, allocator, src, options),
        .SCANNER => scanner_parser.parse(Target, allocator, src, options),
        .GENERATED => generated_parser.parse(Target, allocator, src, options, SHAPE_SCALAR),
        .GENERATED_VECTOR => generated_parser.parse(
            Target,
            allocator,
            src,
            options,
            SHAPE_VECTOR,
        ),
    };
}

// --------------------------------------------------------- //
// Public:

/// How a parse can fail.
///
/// Note:
/// - UnknownField, MissingField, UnknownEnumValue: the document and the type
///   disagree. `lastFailure().field` names the field.
/// - Truncated, Unexpected, BadNumber, BadEscape: the document is not what it claims.
///   On the cursor paths `lastFailure().offset` is the byte it stopped on.
/// - `.STD` reports neither field nor byte, because std surfaces neither.
/// - NoSpaceLeft exists so every member of the inner sets maps to a real member here.
///   A parse never returns it.
pub const Error = error{
    Jzon_Deserialize_UnknownField,
    Jzon_Deserialize_MissingField,
    Jzon_Deserialize_UnknownEnumValue,
    Jzon_Deserialize_Truncated,
    Jzon_Deserialize_Unexpected,
    Jzon_Deserialize_BadNumber,
    Jzon_Deserialize_BadEscape,
    Jzon_Deserialize_NoSpaceLeft,
    Jzon_Deserialize_OutOfMemory,
};

/// Read a value of `Target` out of a whole JSON document.
///
/// Note:
/// - The strategy is comptime, so only the path it names is compiled in. A shape the
///   generated paths refuse still parses under the default `.STD`.
/// - The document has to hold one value and nothing after it, so trailing bytes are a
///   failure, not something left unread.
/// - The caller frees what the parse allocated. An arena frees it in one call, and
///   also frees what a failed parse allocated before it stopped. With a general
///   allocator every string and slice in the result is the caller's to free, and a
///   failed parse leaves its partial allocations behind.
///
/// Param:
/// Target - type (comptime, the type to build)
/// allocator - Allocator (owns everything the result points at)
/// src - []const u8 (the whole document)
/// options - DeserializeOptions (comptime, which read path runs, how strings are held,
///   and what an unknown key does)
///
/// Usage:
/// ```zig
/// // One arena per request: everything the parse allocates is freed at once.
/// var arena: std.heap.ArenaAllocator = .init(gpa);
/// defer arena.deinit();
///
/// const order = try jzon.deserialize(Order, arena.allocator(), body, .{});
///
/// const faster = try jzon.deserialize(Order, arena.allocator(), body, .{
///     .strategy = .GENERATED,
///     .strings = .BORROW,
///     .unknown = .SKIP,
/// });
/// ```
///
/// Return:
/// - Target (the parsed value)
/// - Error.Jzon_Deserialize_UnknownField, MissingField, UnknownEnumValue when the
///   document and the type disagree
/// - Error.Jzon_Deserialize_Truncated, Unexpected, BadNumber, BadEscape when the
///   document is not what it claims
/// - Error.Jzon_Deserialize_OutOfMemory when the allocator runs out
pub fn deserialize(
    comptime Target: type,
    allocator: Allocator,
    src: []const u8,
    comptime options: DeserializeOptions,
) Error!Target {
    return parseInto(Target, allocator, src, options) catch |err| innerError(err);
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const Failure = @import("Failure.zig");

const Strategy = DeserializeOptions.Strategy;

/// Every strategy, so a case can check all of them at once.
const STRATEGIES = [_]Strategy{ .STD, .SCANNER, .GENERATED, .GENERATED_VECTOR };

/// Every strategy generated from the type, where the deliberate differences live.
const GENERATED = [_]Strategy{ .SCANNER, .GENERATED, .GENERATED_VECTOR };

/// The strategies that read over jzon's own cursor, which report the stop byte.
const CURSOR_PATHS = [_]Strategy{ .GENERATED, .GENERATED_VECTOR };

const Status = enum { PENDING, SHIPPED };

const Nested = struct {
    alpha: i32,
    beta: []const u8,
};

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

/// Require `src` read as `Target` to fail with `expected` under every strategy.
fn expectFails(comptime Target: type, src: []const u8, expected: Error) !void {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    inline for (STRATEGIES) |strategy| {
        try std.testing.expectError(
            expected,
            deserialize(Target, arena.allocator(), src, .{ .strategy = strategy }),
        );
    }
}

/// Whether `text` points inside `document`.
fn pointsInto(text: []const u8, document: []const u8) bool {
    return @intFromPtr(text.ptr) >= @intFromPtr(document.ptr) and
        @intFromPtr(text.ptr) < @intFromPtr(document.ptr) + document.len;
}

test "jzon deserialize: deserialize, reads a record through every strategy" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    inline for (STRATEGIES) |strategy| {
        const record = try deserialize(Record, arena.allocator(), DOCUMENT, .{
            .strategy = strategy,
        });

        try std.testing.expectEqual(@as(u64, 7), record.id);
        try std.testing.expectEqualStrings("a\"b", record.name);
        try std.testing.expectEqual(@as(f64, 2.5), record.ratio);
        try std.testing.expect(record.active);
        try std.testing.expectEqual(Status.SHIPPED, record.status);
        try std.testing.expect(record.note == null);
        try std.testing.expectEqualStrings("two", record.tags[1]);
        try std.testing.expectEqual(@as(i32, -3), record.nested.alpha);
    }
}

test "jzon deserialize: deserialize, BORROW points a clean string into the document" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const src = "{\"alpha\":1,\"beta\":\"borrowed\"}";

    inline for (STRATEGIES) |strategy| {
        const borrowed = try deserialize(Nested, arena.allocator(), src, .{
            .strategy = strategy,
            .strings = .BORROW,
        });

        try std.testing.expect(pointsInto(borrowed.beta, src));
    }
}

test "jzon deserialize: deserialize, COPY keeps a clean string out of the document" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const src = "{\"alpha\":1,\"beta\":\"borrowed\"}";

    inline for (STRATEGIES) |strategy| {
        const copied = try deserialize(Nested, arena.allocator(), src, .{
            .strategy = strategy,
            .strings = .COPY,
        });

        try std.testing.expect(!pointsInto(copied.beta, src));
        try std.testing.expectEqualStrings("borrowed", copied.beta);
    }
}

test "jzon deserialize: deserialize, SKIP steps over an unknown key" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const src = "{\"alpha\":1,\"extra\":[1,{\"deep\":null}],\"beta\":\"x\"}";

    inline for (STRATEGIES) |strategy| {
        const skipped = try deserialize(Nested, arena.allocator(), src, .{
            .strategy = strategy,
            .unknown = .SKIP,
        });

        try std.testing.expectEqual(@as(i32, 1), skipped.alpha);
        try std.testing.expectEqualStrings("x", skipped.beta);
    }
}

test "jzon deserialize: deserialize, REJECT refuses an unknown key" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const src = "{\"alpha\":1,\"extra\":[1,{\"deep\":null}],\"beta\":\"x\"}";

    inline for (STRATEGIES) |strategy| {
        try std.testing.expectError(
            Error.Jzon_Deserialize_UnknownField,
            deserialize(Nested, arena.allocator(), src, .{
                .strategy = strategy,
                .unknown = .REJECT,
            }),
        );
    }
}

test "jzon deserialize: deserialize, every strategy reports through one error set" {
    try expectFails(Nested, "{\"alpha\":", Error.Jzon_Deserialize_Truncated);
    try expectFails(Nested, "[]", Error.Jzon_Deserialize_Unexpected);
    try expectFails(Nested, "{\"alpha\":1}", Error.Jzon_Deserialize_MissingField);
    try expectFails(Nested, "{\"gone\":1}", Error.Jzon_Deserialize_UnknownField);
}

test "jzon deserialize: deserialize, STD reads a shape the generated paths refuse" {
    // std fills a byte slice from an array of numbers, which the generated paths
    // refuse. The default path is the one that stays correct for it.
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const text = try deserialize([]const u8, arena.allocator(), "[104,105]", .{});

    try std.testing.expectEqualStrings("hi", text);
}

test "jzon deserialize: deserialize, unknown field names the field for lastFailure" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    inline for (GENERATED) |strategy| {
        Failure.reset();

        try std.testing.expectError(
            Error.Jzon_Deserialize_UnknownField,
            deserialize(Pair, arena.allocator(), "{\"id\":1,\"gone\":2}", .{
                .strategy = strategy,
            }),
        );
        try std.testing.expectEqualStrings("gone", Failure.lastFailure().field);
    }
}

test "jzon deserialize: deserialize, escaped unknown field outlives the freed arena" {
    inline for (GENERATED) |strategy| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);

        Failure.reset();

        // The escaped key is decoded into the arena, which is freed before the read.
        try std.testing.expectError(
            Error.Jzon_Deserialize_UnknownField,
            deserialize(Pair, arena.allocator(), "{\"id\":1,\"g\\u006fne\":2}", .{
                .strategy = strategy,
            }),
        );
        arena.deinit();

        try std.testing.expectEqualStrings("gone", Failure.lastFailure().field);
    }
}

test "jzon deserialize: deserialize, cursor path failure notes the stop byte" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    // The `x` at byte 6 cannot start a number.
    inline for (CURSOR_PATHS) |strategy| {
        Failure.reset();

        try std.testing.expectError(
            Error.Jzon_Deserialize_Unexpected,
            deserialize(Pair, arena.allocator(), "{\"id\":x}", .{
                .strategy = strategy,
            }),
        );

        const failure = Failure.lastFailure();

        try std.testing.expect(failure.filled);
        try std.testing.expectEqual(@as(usize, 6), failure.offset);
    }
}

test "jzon deserialize: deserialize, trailing bytes after the value are unexpected" {
    try expectFails(u8, "1 2", Error.Jzon_Deserialize_Unexpected);
    try expectFails(Pair, "{\"id\":1,\"name\":\"x\"}{}", Error.Jzon_Deserialize_Unexpected);
    try expectFails([]const u32, "[1][2]", Error.Jzon_Deserialize_Unexpected);
}

test "jzon deserialize: deserialize, innerError renames every std_parser member" {
    const cases = .{
        .{ error.Jzon_StdParser_UnknownField, Error.Jzon_Deserialize_UnknownField },
        .{ error.Jzon_StdParser_MissingField, Error.Jzon_Deserialize_MissingField },
        .{ error.Jzon_StdParser_UnknownEnumValue, Error.Jzon_Deserialize_UnknownEnumValue },
        .{ error.Jzon_StdParser_Truncated, Error.Jzon_Deserialize_Truncated },
        .{ error.Jzon_StdParser_Unexpected, Error.Jzon_Deserialize_Unexpected },
        .{ error.Jzon_StdParser_BadNumber, Error.Jzon_Deserialize_BadNumber },
        .{ error.Jzon_StdParser_OutOfMemory, Error.Jzon_Deserialize_OutOfMemory },
    };

    inline for (cases) |case| {
        try std.testing.expectEqual(case[1], innerError(case[0]));
    }
}

test "jzon deserialize: deserialize, innerError renames every scanner_parser member" {
    const cases = .{
        .{ error.Jzon_ScannerParser_UnknownField, Error.Jzon_Deserialize_UnknownField },
        .{ error.Jzon_ScannerParser_MissingField, Error.Jzon_Deserialize_MissingField },
        .{
            error.Jzon_ScannerParser_UnknownEnumValue,
            Error.Jzon_Deserialize_UnknownEnumValue,
        },
        .{ error.Jzon_ScannerParser_Truncated, Error.Jzon_Deserialize_Truncated },
        .{ error.Jzon_ScannerParser_Unexpected, Error.Jzon_Deserialize_Unexpected },
        .{ error.Jzon_ScannerParser_BadNumber, Error.Jzon_Deserialize_BadNumber },
        .{ error.Jzon_ScannerParser_NoSpaceLeft, Error.Jzon_Deserialize_NoSpaceLeft },
        .{ error.Jzon_ScannerParser_OutOfMemory, Error.Jzon_Deserialize_OutOfMemory },
    };

    inline for (cases) |case| {
        try std.testing.expectEqual(case[1], innerError(case[0]));
    }
}

test "jzon deserialize: deserialize, innerError renames every generated_parser member" {
    const cases = .{
        .{ error.Jzon_GeneratedParser_UnknownField, Error.Jzon_Deserialize_UnknownField },
        .{ error.Jzon_GeneratedParser_MissingField, Error.Jzon_Deserialize_MissingField },
        .{
            error.Jzon_GeneratedParser_UnknownEnumValue,
            Error.Jzon_Deserialize_UnknownEnumValue,
        },
        .{ error.Jzon_GeneratedParser_Truncated, Error.Jzon_Deserialize_Truncated },
        .{ error.Jzon_GeneratedParser_Unexpected, Error.Jzon_Deserialize_Unexpected },
        .{ error.Jzon_GeneratedParser_BadNumber, Error.Jzon_Deserialize_BadNumber },
        .{ error.Jzon_GeneratedParser_BadEscape, Error.Jzon_Deserialize_BadEscape },
        .{ error.Jzon_GeneratedParser_NoSpaceLeft, Error.Jzon_Deserialize_NoSpaceLeft },
        .{ error.Jzon_GeneratedParser_OutOfMemory, Error.Jzon_Deserialize_OutOfMemory },
    };

    inline for (cases) |case| {
        try std.testing.expectEqual(case[1], innerError(case[0]));
    }
}

test "jzon deserialize: deserialize, innerError keeps every own member" {
    inline for (@typeInfo(Error).error_set.error_names.?) |name| {
        const own = @field(Error, name);

        try std.testing.expectEqual(own, innerError(own));
    }
}

test "jzon deserialize: deserialize, document that ends early is truncated" {
    try expectFails(Pair, "{", Error.Jzon_Deserialize_Truncated);
    try expectFails(Pair, "{\"id\":", Error.Jzon_Deserialize_Truncated);
    try expectFails(Pair, "{\"id\":1,", Error.Jzon_Deserialize_Truncated);
    try expectFails([]const u32, "[1,2", Error.Jzon_Deserialize_Truncated);
    try expectFails([]const u8, "\"unterminated", Error.Jzon_Deserialize_Truncated);
}

test "jzon deserialize: deserialize, number the field cannot take is bad number" {
    try expectFails(Pair, "{\"id\":300,\"name\":\"x\"}", Error.Jzon_Deserialize_BadNumber);
}

test "jzon deserialize: deserialize, value of the wrong shape is unexpected" {
    try expectFails(Pair, "{\"id\":null,\"name\":\"x\"}", Error.Jzon_Deserialize_Unexpected);
    try expectFails(Pair, "{\"id\":1,\"name\":7}", Error.Jzon_Deserialize_Unexpected);
    try expectFails([]const u32, "{}", Error.Jzon_Deserialize_Unexpected);
}

test "jzon deserialize: deserialize, object owing a field is missing field" {
    try expectFails(Pair, "{}", Error.Jzon_Deserialize_MissingField);
    try expectFails(Pair, "{\"id\":1}", Error.Jzon_Deserialize_MissingField);
}

test "jzon deserialize: deserialize, key the type does not declare is unknown field" {
    try expectFails(
        Pair,
        "{\"id\":1,\"name\":\"x\",\"gone\":2}",
        Error.Jzon_Deserialize_UnknownField,
    );
}

test "jzon deserialize: deserialize, name no enum tag carries is unknown enum value" {
    try expectFails(Status, "\"GONE\"", Error.Jzon_Deserialize_UnknownEnumValue);
    try expectFails(Status, "\"pending\"", Error.Jzon_Deserialize_UnknownEnumValue);
}

test "jzon deserialize: deserialize, every strategy reads the empty string and array" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const Holder = struct {
        text: []const u8,
        items: []const u32,
    };
    const src = "{\"text\":\"\",\"items\":[]}";

    inline for (STRATEGIES) |strategy| {
        const empty = try deserialize(Holder, arena.allocator(), src, .{
            .strategy = strategy,
        });

        try std.testing.expectEqual(@as(usize, 0), empty.text.len);
        try std.testing.expectEqual(@as(usize, 0), empty.items.len);
    }
}

test "jzon deserialize: deserialize, empty object fills a type without fields" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    inline for (STRATEGIES) |strategy| {
        _ = try deserialize(struct {}, arena.allocator(), "{}", .{ .strategy = strategy });
    }
}

test "jzon deserialize: deserialize, every strategy reads the extremes of a width" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    inline for (STRATEGIES) |strategy| {
        const options: DeserializeOptions = .{ .strategy = strategy };

        const widest = try deserialize(u64, allocator, "18446744073709551615", options);
        const lowest = try deserialize(i64, allocator, "-9223372036854775808", options);

        try std.testing.expectEqual(@as(u64, std.math.maxInt(u64)), widest);
        try std.testing.expectEqual(@as(i64, std.math.minInt(i64)), lowest);
    }
}

test "jzon deserialize: deserialize, generated strategy refuses an array of bytes" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    inline for (GENERATED) |strategy| {
        try std.testing.expectError(
            Error.Jzon_Deserialize_Unexpected,
            deserialize([]const u8, allocator, "[104,105]", .{ .strategy = strategy }),
        );
    }
}

test "jzon deserialize: deserialize, generated strategy refuses a signed zero unsigned" {
    // A sign against an unsigned field is a type error whatever the digits after it.
    // std reads the digits and lands on zero. No serialize strategy writes this.
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    const src = "{\"id\":-0,\"name\":\"x\"}";

    inline for (GENERATED) |strategy| {
        try std.testing.expectError(
            Error.Jzon_Deserialize_BadNumber,
            deserialize(Pair, allocator, src, .{ .strategy = strategy }),
        );
    }

    const theirs = try deserialize(Pair, allocator, src, .{});

    try std.testing.expectEqual(@as(u8, 0), theirs.id);
}

test "jzon deserialize: deserialize, only a cursor path names a bad escape" {
    // The generated parser decodes escapes itself, so it can say which of the two went
    // wrong. The other paths leave that to std, which calls it a syntax error.
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    const src = "\"\\q\"";

    inline for (CURSOR_PATHS) |strategy| {
        try std.testing.expectError(
            Error.Jzon_Deserialize_BadEscape,
            deserialize([]const u8, allocator, src, .{ .strategy = strategy }),
        );
    }

    inline for ([_]Strategy{ .STD, .SCANNER }) |strategy| {
        try std.testing.expectError(
            Error.Jzon_Deserialize_Unexpected,
            deserialize([]const u8, allocator, src, .{ .strategy = strategy }),
        );
    }
}

test "jzon deserialize: deserialize, optional without a declared default is still owed" {
    // Spelling a field `?T` says what it can hold, not that a document may leave it
    // out. `= null` is what makes it optional, on every strategy.
    const Owed = struct {
        id: u8,
        note: ?[]const u8,
    };

    try expectFails(Owed, "{\"id\":1}", Error.Jzon_Deserialize_MissingField);
}

test "jzon deserialize: deserialize, empty allocator is out of memory" {
    var failing: std.testing.FailingAllocator = .init(std.testing.allocator, .{
        .fail_index = 0,
    });

    inline for (STRATEGIES) |strategy| {
        try std.testing.expectError(
            Error.Jzon_Deserialize_OutOfMemory,
            deserialize(Pair, failing.allocator(), "{\"id\":1,\"name\":\"x\"}", .{
                .strategy = strategy,
            }),
        );
    }
}

