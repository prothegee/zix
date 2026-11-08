//! JZON behaviour deserialize_test
//!
//! ### file: src/jzon/tests/behaviour/deserialize_test.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! The public `deserialize` call builds the same value under every strategy, the
//! string and unknown key modes reach the path underneath, and a failure is named.
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

const Strategy = jzon.DeserializeStrategy;

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

/// Every strategy, so a case can assert all of them at once.
const STRATEGIES = [_]Strategy{ .STD, .SCANNER, .GENERATED, .GENERATED_VECTOR };

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

/// A record where every field but `id` declares a default.
const Defaults = struct {
    id: u32,
    status: Status = .PENDING,
    note: ?[]const u8 = null,
    retries: u8 = 3,
};

/// The shape the three failure report tests parse into.
const Record = struct {
    id: u32,
    customer: []const u8,
};

const DOCUMENT =
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

test "jzon behaviour: deserialize, every strategy reads the same order" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    inline for (STRATEGIES) |strategy| {
        const order = try jzon.deserialize(Order, arena.allocator(), DOCUMENT, .{
            .strategy = strategy,
        });

        try std.testing.expectEqual(@as(u64, 4815162342), order.id);
        try std.testing.expectEqualStrings("Rekha Nair", order.customer);
        try std.testing.expectEqual(Status.SHIPPED, order.status);
        try std.testing.expectEqualStrings("leave at the door", order.note.?);
        try std.testing.expectEqual(@as(usize, 2), order.tags.len);
        try std.testing.expectEqualStrings("gift", order.tags[1]);
        try std.testing.expectEqual(@as(usize, 2), order.lines.len);
        try std.testing.expectEqualStrings("CD-2", order.lines[1].sku);
        try std.testing.expectEqual(@as(u32, 1), order.lines[1].qty);
        try std.testing.expectEqual(@as(i64, 7098), order.totals.net_cents);
    }
}

test "jzon behaviour: deserialize, every strategy reads each shape on its own" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    inline for (STRATEGIES) |strategy| {
        const options: jzon.DeserializeOptions = .{ .strategy = strategy };

        const yes = try jzon.deserialize(bool, allocator, "true", options);
        const no = try jzon.deserialize(bool, allocator, "false", options);
        const byte = try jzon.deserialize(u8, allocator, "255", options);
        const signed = try jzon.deserialize(i64, allocator, "-9", options);
        const ratio = try jzon.deserialize(f64, allocator, "0.5", options);
        const status = try jzon.deserialize(Status, allocator, "\"CANCELLED\"", options);
        const text = try jzon.deserialize([]const u8, allocator, "\"text\"", options);
        const numbers = try jzon.deserialize([]const u32, allocator, "[1,2,3]", options);
        const absent = try jzon.deserialize(?u8, allocator, "null", options);
        const present = try jzon.deserialize(?u8, allocator, "9", options);

        try std.testing.expect(yes);
        try std.testing.expect(!no);
        try std.testing.expectEqual(@as(u8, 255), byte);
        try std.testing.expectEqual(@as(i64, -9), signed);
        try std.testing.expectEqual(@as(f64, 0.5), ratio);
        try std.testing.expectEqual(Status.CANCELLED, status);
        try std.testing.expectEqualStrings("text", text);
        try std.testing.expectEqual(@as(usize, 3), numbers.len);
        try std.testing.expectEqual(@as(u32, 3), numbers[2]);
        try std.testing.expect(absent == null);
        try std.testing.expectEqual(@as(?u8, 9), present);
    }
}

test "jzon behaviour: deserialize, every strategy reads a document laid out with whitespace" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const src =
        \\  {
        \\    "net_cents" : 7098 ,
        \\    "tax_cents" : -710
        \\  }
        \\
    ;

    inline for (STRATEGIES) |strategy| {
        const totals = try jzon.deserialize(Totals, arena.allocator(), src, .{
            .strategy = strategy,
        });

        try std.testing.expectEqual(@as(i64, 7098), totals.net_cents);
        try std.testing.expectEqual(@as(i64, -710), totals.tax_cents);
    }
}

test "jzon behaviour: deserialize, borrow mode reaches the path the strategy named" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    const src = "{\"net_cents\":1,\"tax_cents\":2}";
    const with_string = "{\"sku\":\"borrowed\",\"qty\":1,\"price_cents\":2}";

    inline for (STRATEGIES) |strategy| {
        const borrowed = try jzon.deserialize(Line, allocator, with_string, .{
            .strategy = strategy,
            .strings = .BORROW,
        });

        try std.testing.expect(inside(with_string, borrowed.sku));

        const copied = try jzon.deserialize(Line, allocator, with_string, .{
            .strategy = strategy,
            .strings = .COPY,
        });

        try std.testing.expect(!inside(with_string, copied.sku));
        try std.testing.expectEqualStrings("borrowed", copied.sku);

        // A value with no string in it reads the same under either mode.
        const totals = try jzon.deserialize(Totals, allocator, src, .{
            .strategy = strategy,
            .strings = .BORROW,
        });

        try std.testing.expectEqual(@as(i64, 1), totals.net_cents);
    }
}

test "jzon behaviour: deserialize, escaped string is decoded whichever mode was asked for" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    // The decoded bytes are nowhere in the document, so borrowing cannot return
    // them and the parse copies regardless of what the caller asked for.
    const src = "{\"sku\":\"one\\ttwo\",\"qty\":1,\"price_cents\":2}";

    inline for (STRATEGIES) |strategy| {
        const borrowed = try jzon.deserialize(Line, arena.allocator(), src, .{
            .strategy = strategy,
            .strings = .BORROW,
        });

        try std.testing.expectEqualStrings("one\ttwo", borrowed.sku);
        try std.testing.expect(!inside(src, borrowed.sku));
    }
}

test "jzon behaviour: deserialize, unknown key rule reaches the path the strategy named" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    const src = "{\"net_cents\":1,\"extra\":{\"deep\":[1,2,{\"a\":null}]},\"tax_cents\":2}";

    inline for (STRATEGIES) |strategy| {
        const skipped = try jzon.deserialize(Totals, allocator, src, .{
            .strategy = strategy,
            .unknown = .SKIP,
        });

        try std.testing.expectEqual(@as(i64, 1), skipped.net_cents);
        try std.testing.expectEqual(@as(i64, 2), skipped.tax_cents);

        const rejected = jzon.deserialize(Totals, allocator, src, .{
            .strategy = strategy,
            .unknown = .REJECT,
        });

        try std.testing.expectError(
            jzon.DeserializeError.Jzon_Deserialize_UnknownField,
            rejected,
        );
    }
}

test "jzon behaviour: deserialize, every strategy gives an absent field its declared default" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    inline for (STRATEGIES) |strategy| {
        const value = try jzon.deserialize(Defaults, arena.allocator(), "{\"id\":1}", .{
            .strategy = strategy,
        });

        try std.testing.expectEqual(@as(u32, 1), value.id);
        try std.testing.expectEqual(Status.PENDING, value.status);
        try std.testing.expect(value.note == null);
        try std.testing.expectEqual(@as(u8, 3), value.retries);
    }
}

test "jzon behaviour: deserialize, reads a shape only the default strategy has a form for" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    // std fills a byte slice from an array of numbers and takes a tuple as an
    // array. The generated strategies refuse both at compile time, so the
    // default one is the reason a caller is never stuck.
    const text = try jzon.deserialize([]const u8, allocator, "[104,105]", .{});
    try std.testing.expectEqualStrings("hi", text);

    const pair = try jzon.deserialize(struct { u8, bool }, allocator, "[1,true]", .{});
    try std.testing.expectEqual(@as(u8, 1), pair[0]);
    try std.testing.expect(pair[1]);
}

test "jzon behaviour: deserialize, a rejected field is named, which the error value cannot do" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    jzon.Failure.reset();

    const body = "{\"id\":42,\"customer\":\"Ada\",\"discount\":5}";
    const result = jzon.deserialize(Record, arena.allocator(), body, .{
        .strategy = .GENERATED,
    });

    try std.testing.expectError(jzon.DeserializeError.Jzon_Deserialize_UnknownField, result);

    const why = jzon.lastFailure();

    try std.testing.expect(why.filled);
    try std.testing.expectEqualStrings("discount", why.field);
}

test "jzon behaviour: deserialize, a field the document never filled is named" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    jzon.Failure.reset();

    const result = jzon.deserialize(Record, arena.allocator(), "{\"id\":42}", .{
        .strategy = .GENERATED,
    });

    try std.testing.expectError(jzon.DeserializeError.Jzon_Deserialize_MissingField, result);

    const why = jzon.lastFailure();

    try std.testing.expect(why.filled);
    try std.testing.expectEqualStrings("customer", why.field);
}

test "jzon behaviour: deserialize, a document that stops early reports the byte it stopped on" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    jzon.Failure.reset();

    const cut = "{\"id\":42,\"customer\":\"Ada";
    const result = jzon.deserialize(Record, arena.allocator(), cut, .{
        .strategy = .GENERATED,
    });

    try std.testing.expectError(jzon.DeserializeError.Jzon_Deserialize_Truncated, result);

    const why = jzon.lastFailure();

    try std.testing.expect(why.filled);
    try std.testing.expect(why.offset > 0);
    try std.testing.expect(why.offset <= cut.len);
}

