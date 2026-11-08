//! JZON behaviour string_value_test
//!
//! ### file: src/jzon/tests/behaviour/string_value_test.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! A string token's value: borrowed from the document or copied out of it, and
//! decoded into the allocator whenever it carries an escape.
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

const StringSpan = jzon.StringSpan;
const string_value = jzon.string_value;

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

/// One escaped token body and the value it decodes to.
const EscapeCase = struct {
    raw: []const u8,
    value: []const u8,
};

/// Whether `text` points inside `document`.
fn pointsInto(text: []const u8, document: []const u8) bool {
    return @intFromPtr(text.ptr) >= @intFromPtr(document.ptr) and
        @intFromPtr(text.ptr) < @intFromPtr(document.ptr) + document.len;
}

/// A span over `raw`, flagged as carrying an escape or not.
fn spanOf(raw: []const u8, escaped: bool) StringSpan {
    return .{
        .raw = raw,
        .escaped = escaped,
    };
}

test "jzon behaviour: string_value, borrowed clean token is the document's own bytes" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const document = "no escape in here";
    const span = spanOf(document, false);

    const taken = try string_value.take(arena.allocator(), span, .{ .strings = .BORROW });

    try std.testing.expectEqualStrings(document, taken);
    try std.testing.expect(pointsInto(taken, document));
}

test "jzon behaviour: string_value, copied clean token stops depending on the document" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const document = "no escape in here";
    const span = spanOf(document, false);

    const taken = try string_value.take(arena.allocator(), span, .{ .strings = .COPY });

    try std.testing.expectEqualStrings(document, taken);
    try std.testing.expect(!pointsInto(taken, document));
}

test "jzon behaviour: string_value, copy is what a parse does unless told otherwise" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const document = "left alone";
    const span = spanOf(document, false);

    const taken = try string_value.take(arena.allocator(), span, .{});

    try std.testing.expect(!pointsInto(taken, document));
}

test "jzon behaviour: string_value, escaped token is decoded whichever mode is asked for" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    const document = "line\\nbreak\\ttab";
    const span = spanOf(document, true);

    const borrowed = try string_value.take(allocator, span, .{ .strings = .BORROW });
    const copied = try string_value.take(allocator, span, .{ .strings = .COPY });

    try std.testing.expectEqualStrings("line\nbreak\ttab", borrowed);
    try std.testing.expectEqualStrings("line\nbreak\ttab", copied);
    try std.testing.expect(!pointsInto(borrowed, document));
}

test "jzon behaviour: string_value, every escape the rules spell is read back" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    const cases = [_]EscapeCase{
        .{
            .raw = "\\\"",
            .value = "\"",
        },
        .{
            .raw = "\\\\",
            .value = "\\",
        },
        .{
            .raw = "\\/",
            .value = "/",
        },
        .{
            .raw = "\\b",
            .value = "\x08",
        },
        .{
            .raw = "\\f",
            .value = "\x0c",
        },
        .{
            .raw = "\\n",
            .value = "\n",
        },
        .{
            .raw = "\\r",
            .value = "\r",
        },
        .{
            .raw = "\\t",
            .value = "\t",
        },
        .{
            .raw = "\\u0041",
            .value = "A",
        },
        .{
            .raw = "\\u00e9",
            .value = "\xc3\xa9",
        },
        .{
            .raw = "\\ud83d\\udca9",
            .value = "\xf0\x9f\x92\xa9",
        },
    };

    for (cases) |case| {
        const taken = try string_value.take(allocator, spanOf(case.raw, true), .{});

        try std.testing.expectEqualStrings(case.value, taken);
    }
}

test "jzon behaviour: string_value, decoded token is exactly as long as its value" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const taken = try string_value.take(arena.allocator(), spanOf("\\n\\n\\n", true), .{});

    try std.testing.expectEqual(@as(usize, 3), taken.len);
    try std.testing.expectEqualStrings("\n\n\n", taken);
}

