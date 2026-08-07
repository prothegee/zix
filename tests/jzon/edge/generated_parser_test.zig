//! Edge tests: zix.jzon.generated_parser at the boundaries.
//! Covers documents that end early, carry more than one value, repeat a key or
//! hold a value the field cannot take, plus the two places this path answers
//! differently from the std-backed one.

const std = @import("std");
const zix = @import("zix");

const generated_parser = zix.jzon.generated_parser;
const scanner_parser = zix.jzon.scanner_parser;
const std_parser = zix.jzon.std_parser;

const Shape = generated_parser.Shape;

/// Both widths, so every case asserts the pair agrees.
const SHAPES = [_]Shape{
    .{ .scan = .SCALAR },
    .{ .scan = .VECTOR },
};

const Status = enum { PENDING, SHIPPED };

const Pair = struct {
    id: u8,
    name: []const u8,
};

/// Assert a document is refused the same way at both widths.
fn expectRefused(comptime T: type, src: []const u8, failure: anyerror) !void {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    inline for (SHAPES) |shape| {
        try std.testing.expectError(failure, generated_parser.parse(T, arena.allocator(), src, .{}, shape));
    }
}

test "zix edge: the generated parser reports a document that ends early" {
    try expectRefused(u8, "", error.Truncated);
    try expectRefused(Pair, "{", error.Truncated);
    try expectRefused(Pair, "{\"id\"", error.Truncated);
    try expectRefused(Pair, "{\"id\":", error.Truncated);
    try expectRefused(Pair, "{\"id\":1,", error.Truncated);
    try expectRefused([]const u32, "[1,2", error.Truncated);
    try expectRefused([]const u8, "\"unterminated", error.Truncated);
    try expectRefused(bool, "tru", error.Truncated);
}

test "zix edge: the generated parser reports a document carrying more than one value" {
    try expectRefused(u8, "1 2", error.Unexpected);
    try expectRefused(Pair, "{\"id\":1,\"name\":\"x\"}{}", error.Unexpected);
    try expectRefused([]const u32, "[1][2]", error.Unexpected);
}

test "zix edge: the generated parser reports the same key twice" {
    try expectRefused(Pair, "{\"id\":1,\"id\":2,\"name\":\"x\"}", error.Unexpected);
}

test "zix edge: the generated parser reports a number the field cannot take" {
    try expectRefused(Pair, "{\"id\":300,\"name\":\"x\"}", error.BadNumber);
    try expectRefused(Pair, "{\"id\":1.5,\"name\":\"x\"}", error.BadNumber);
    try expectRefused(Pair, "{\"id\":-1,\"name\":\"x\"}", error.BadNumber);
    try expectRefused(u64, "18446744073709551616", error.BadNumber);
    try expectRefused(f64, "1.2.3", error.BadNumber);
}

test "zix edge: the generated parser reports a value of the wrong shape" {
    try expectRefused(Pair, "{\"id\":null,\"name\":\"x\"}", error.Unexpected);
    try expectRefused(Pair, "{\"id\":1,\"name\":7}", error.Unexpected);
    try expectRefused(Pair, "[1,2]", error.Unexpected);
    try expectRefused([]const u32, "{}", error.Unexpected);
    try expectRefused(bool, "\"true\"", error.Unexpected);
}

test "zix edge: the generated parser reports a trailing comma" {
    try expectRefused(Pair, "{\"id\":1,\"name\":\"x\",}", error.Unexpected);
    try expectRefused([]const u32, "[1,2,]", error.Unexpected);
}

test "zix edge: the generated parser reports an object owing a field" {
    try expectRefused(Pair, "{}", error.MissingField);
    try expectRefused(Pair, "{\"id\":1}", error.MissingField);
}

test "zix edge: the generated parser reports a name no enum tag carries" {
    try expectRefused(Status, "\"GONE\"", error.UnknownEnumValue);
    try expectRefused(Status, "\"pending\"", error.UnknownEnumValue);
    try expectRefused(Status, "\"\"", error.UnknownEnumValue);
}

test "zix edge: the generated parser reads the empty string, object and array" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    const Holder = struct {
        text: []const u8,
        items: []const u32,
    };

    inline for (SHAPES) |shape| {
        const empty = try generated_parser.parse(Holder, allocator, "{\"text\":\"\",\"items\":[]}", .{}, shape);

        try std.testing.expectEqual(@as(usize, 0), empty.text.len);
        try std.testing.expectEqual(@as(usize, 0), empty.items.len);

        // A type that declares no fields is owed nothing, so an empty object is
        // a whole value for it.
        _ = try generated_parser.parse(struct {}, allocator, "{}", .{}, shape);
    }
}

test "zix edge: the generated parser reads the extremes of a width" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    inline for (SHAPES) |shape| {
        try std.testing.expectEqual(
            @as(u64, std.math.maxInt(u64)),
            try generated_parser.parse(u64, allocator, "18446744073709551615", .{}, shape),
        );
        try std.testing.expectEqual(
            @as(i64, std.math.minInt(i64)),
            try generated_parser.parse(i64, allocator, "-9223372036854775808", .{}, shape),
        );
    }
}

test "zix edge: the generated parser reads a nested slice of slices" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    inline for (SHAPES) |shape| {
        const grid = try generated_parser.parse(
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

test "zix edge: the generated parser reports an escape the rules do not spell" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    inline for (SHAPES) |shape| {
        const paired = try generated_parser.parse([]const u8, allocator, "\"\\ud83d\\udca9\"", .{}, shape);
        try std.testing.expectEqualStrings("\xf0\x9f\x92\xa9", paired);

        // This path decodes escapes itself, so it can say which of the two went
        // wrong. The scanner path leaves that to std, which calls a broken
        // escape a syntax error.
        try std.testing.expectError(error.BadEscape, generated_parser.parse([]const u8, allocator, "\"\\ud83d\"", .{}, shape));
        try std.testing.expectError(error.BadEscape, generated_parser.parse([]const u8, allocator, "\"\\q\"", .{}, shape));
    }

    try std.testing.expectError(error.Unexpected, scanner_parser.parse([]const u8, allocator, "\"\\q\"", .{}));
}

test "zix edge: the generated parser refuses an array of bytes as a string" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    // In jzon a slice of bytes is a string and nothing else. std also fills one
    // from an array of numbers, which is why the same type reads there and
    // fails here.
    inline for (SHAPES) |shape| {
        try std.testing.expectError(
            error.Unexpected,
            generated_parser.parse([]const u8, allocator, "[104,105]", .{}, shape),
        );
    }

    const theirs = try std_parser.parse([]const u8, allocator, "[104,105]", .{});
    try std.testing.expectEqualStrings("hi", theirs);
}

test "zix edge: the generated parser refuses a signed zero in an unsigned field" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    const src = "{\"id\":-0,\"name\":\"x\"}";

    // A sign against an unsigned field is a type error whatever the digits after
    // it are. std reads the digits and lands on zero. Neither serialize path
    // ever writes this, so no round trip crosses the difference.
    inline for (SHAPES) |shape| {
        try std.testing.expectError(error.BadNumber, generated_parser.parse(Pair, allocator, src, .{}, shape));
    }

    const theirs = try std_parser.parse(Pair, allocator, src, .{});
    try std.testing.expectEqual(@as(u8, 0), theirs.id);
}

test "zix edge: the generated parser steps over a deeply nested unknown value" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const src = "{\"id\":1,\"deep\":[[[{\"a\":{\"b\":[null,true,\"x\"]}}]]],\"name\":\"y\"}";

    inline for (SHAPES) |shape| {
        const pair = try generated_parser.parse(Pair, arena.allocator(), src, .{ .unknown = .SKIP }, shape);

        try std.testing.expectEqual(@as(u8, 1), pair.id);
        try std.testing.expectEqualStrings("y", pair.name);
    }
}

test "zix edge: an unknown value the parse steps over still has to be a value" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const src = "{\"id\":1,\"other\":[1,,2],\"name\":\"x\"}";

    inline for (SHAPES) |shape| {
        try std.testing.expectError(
            error.Unexpected,
            generated_parser.parse(Pair, arena.allocator(), src, .{ .unknown = .SKIP }, shape),
        );
    }
}

test "zix edge: the generated parser reports an allocator with nothing left" {
    var failing: std.testing.FailingAllocator = .init(std.testing.allocator, .{ .fail_index = 0 });

    inline for (SHAPES) |shape| {
        try std.testing.expectError(
            error.OutOfMemory,
            generated_parser.parse(Pair, failing.allocator(), "{\"id\":1,\"name\":\"x\"}", .{}, shape),
        );
    }
}
