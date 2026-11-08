//! JZON behaviour std_parser_test
//!
//! ### file: src/jzon/tests/behaviour/std_parser_test.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! The std-backed parser reads a whole record, honours the string and unknown key
//! modes, and reads the shapes the generated parser refuses.
//!
//! ### note:
//!
//! n/a
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
const jzon = @import("jzon");

const std_parser = jzon.std_parser;

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const Status = enum { PENDING, SHIPPED, CANCELLED };

const Totals = struct {
    net_cents: i64,
    tax_cents: i64,
};

const Line = struct {
    sku: []const u8,
    qty: u32,
    price_cents: i64,
};

const Order = struct {
    id: u64,
    customer: []const u8,
    status: Status,
    note: ?[]const u8 = null,
    tags: []const []const u8,
    lines: []const Line,
    totals: Totals,
};

/// Two strings, one clean and one escaped.
const Pair = struct {
    plain: []const u8,
    escaped: []const u8,
};

/// A small record for the unknown key cases.
const Named = struct {
    id: u8,
    name: []const u8,
};

const ORDER_JSON =
    "{\"id\":4815162342,\"customer\":\"Rekha Nair\",\"status\":\"SHIPPED\"," ++
    "\"note\":\"leave at the door\",\"tags\":[\"priority\",\"gift\"]," ++
    "\"lines\":[{\"sku\":\"AB-1\",\"qty\":2,\"price_cents\":1299}," ++
    "{\"sku\":\"CD-2\",\"qty\":1,\"price_cents\":4500}]," ++
    "\"totals\":{\"net_cents\":7098,\"tax_cents\":710}}";

/// Whether `text` is a slice of `src` rather than a copy of it.
fn inside(src: []const u8, text: []const u8) bool {
    const start = @intFromPtr(src.ptr);
    const at = @intFromPtr(text.ptr);

    return at >= start and at < start + src.len;
}

test "jzon behaviour: std_parser, reads a whole order" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const order = try std_parser.parse(Order, arena.allocator(), ORDER_JSON, .{});

    try std.testing.expectEqual(@as(u64, 4815162342), order.id);
    try std.testing.expectEqualStrings("Rekha Nair", order.customer);
    try std.testing.expectEqual(Status.SHIPPED, order.status);
    try std.testing.expectEqualStrings("leave at the door", order.note.?);
    try std.testing.expectEqual(@as(usize, 2), order.tags.len);
    try std.testing.expectEqualStrings("gift", order.tags[1]);
    try std.testing.expectEqual(@as(usize, 2), order.lines.len);
    try std.testing.expectEqualStrings("CD-2", order.lines[1].sku);
    try std.testing.expectEqual(@as(i64, 4500), order.lines[1].price_cents);
    try std.testing.expectEqual(@as(i64, 710), order.totals.tax_cents);
}

test "jzon behaviour: std_parser, reads an unset optional as null" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const src = "{\"id\":1,\"customer\":\"x\",\"status\":\"PENDING\",\"note\":null," ++
        "\"tags\":[],\"lines\":[],\"totals\":{\"net_cents\":0,\"tax_cents\":0}}";

    const order = try std_parser.parse(Order, arena.allocator(), src, .{});

    try std.testing.expect(order.note == null);
    try std.testing.expectEqual(@as(usize, 0), order.tags.len);
    try std.testing.expectEqual(@as(usize, 0), order.lines.len);
}

test "jzon behaviour: std_parser, gives an absent field the default its type declares" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const src = "{\"id\":1,\"customer\":\"x\",\"status\":\"PENDING\"," ++
        "\"tags\":[],\"lines\":[],\"totals\":{\"net_cents\":0,\"tax_cents\":0}}";

    const order = try std_parser.parse(Order, arena.allocator(), src, .{});

    try std.testing.expect(order.note == null);
}

test "jzon behaviour: std_parser, borrows a clean string and copies an escaped one" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const src = "{\"plain\":\"borrowed\",\"escaped\":\"one\\ttwo\"}";

    const pair = try std_parser.parse(Pair, arena.allocator(), src, .{ .strings = .BORROW });

    try std.testing.expect(inside(src, pair.plain));
    try std.testing.expect(!inside(src, pair.escaped));
    try std.testing.expectEqualStrings("borrowed", pair.plain);
    try std.testing.expectEqualStrings("one\ttwo", pair.escaped);
}

test "jzon behaviour: std_parser, copies every string when asked to" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const src = "{\"plain\":\"copied\",\"escaped\":\"one\\ttwo\"}";

    const pair = try std_parser.parse(Pair, arena.allocator(), src, .{ .strings = .COPY });

    try std.testing.expect(!inside(src, pair.plain));
    try std.testing.expectEqualStrings("copied", pair.plain);
    try std.testing.expectEqualStrings("one\ttwo", pair.escaped);
}

test "jzon behaviour: std_parser, refuses a key the type does not declare" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const src = "{\"id\":1,\"name\":\"x\",\"shipped_at\":\"today\"}";

    try std.testing.expectError(
        std_parser.Error.Jzon_StdParser_UnknownField,
        std_parser.parse(Named, arena.allocator(), src, .{}),
    );
}

test "jzon behaviour: std_parser, steps over a key the type does not declare when asked to" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const src = "{\"id\":1,\"extra\":{\"deep\":[1,2,{\"deeper\":true}]},\"name\":\"x\"}";

    const named = try std_parser.parse(Named, arena.allocator(), src, .{ .unknown = .SKIP });

    try std.testing.expectEqual(@as(u8, 1), named.id);
    try std.testing.expectEqualStrings("x", named.name);
}

test "jzon behaviour: std_parser, reads the shapes the generated path refuses" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    // A dynamic value, which has no fixed type to generate from.
    const dynamic = try std_parser.parse(std.json.Value, allocator, "{\"a\":[1,true]}", .{});
    try std.testing.expectEqual(@as(usize, 1), dynamic.object.count());

    // A fixed-size array, which std reads and the generated path has no form for.
    const triple = try std_parser.parse([3]u8, allocator, "[1,2,3]", .{});
    try std.testing.expectEqual(@as(u8, 3), triple[2]);
}

test "jzon behaviour: std_parser, reads a bare value as well as an object" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    const number = try std_parser.parse(u32, allocator, "42", .{});
    const ratio = try std_parser.parse(f64, allocator, "2.5", .{});
    const flag = try std_parser.parse(bool, allocator, "true", .{});
    const status = try std_parser.parse(Status, allocator, "\"CANCELLED\"", .{});
    const text = try std_parser.parse([]const u8, allocator, "\"hi\"", .{});

    try std.testing.expectEqual(@as(u32, 42), number);
    try std.testing.expectEqual(@as(f64, 2.5), ratio);
    try std.testing.expect(flag);
    try std.testing.expectEqual(Status.CANCELLED, status);
    try std.testing.expectEqualStrings("hi", text);
}

