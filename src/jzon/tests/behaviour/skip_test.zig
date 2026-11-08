//! JZON behaviour skip_test
//!
//! ### file: src/jzon/tests/behaviour/skip_test.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Skip steps over a whole value of any form at both scan widths and leaves
//! what follows it unread.
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

const Cursor = jzon.Cursor;
const ScanShape = jzon.ScanShape;
const skip = jzon.skip;

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

/// Both widths, so every case asserts the pair agrees.
const SHAPES = [_]ScanShape{
    .{ .scan = .SCALAR },
    .{ .scan = .VECTOR },
};

/// Step over the value at the head of `document` and assert what is left.
fn expectLeaves(document: []const u8, rest: []const u8) !void {
    inline for (SHAPES) |shape| {
        var cursor: Cursor = .init(document);
        try skip.value(&cursor, shape);

        try std.testing.expectEqualStrings(rest, cursor.src[cursor.pos..]);
    }
}

test "jzon behaviour: skip, steps over each scalar form" {
    try expectLeaves("true|rest", "|rest");
    try expectLeaves("false|rest", "|rest");
    try expectLeaves("null|rest", "|rest");
    try expectLeaves("0|rest", "|rest");
    try expectLeaves("-42|rest", "|rest");
    try expectLeaves("1.5e-3|rest", "|rest");
    try expectLeaves("\"a string\"|rest", "|rest");
}

test "jzon behaviour: skip, steps over an object and everything inside it" {
    try expectLeaves("{}|rest", "|rest");
    try expectLeaves("{\"a\":1}|rest", "|rest");
    try expectLeaves("{\"a\":1,\"b\":\"two\",\"c\":null}|rest", "|rest");
    try expectLeaves("{\"a\":{\"b\":{\"c\":[1,2,3]}}}|rest", "|rest");
}

test "jzon behaviour: skip, steps over an array and everything inside it" {
    try expectLeaves("[]|rest", "|rest");
    try expectLeaves("[1,2,3]|rest", "|rest");
    try expectLeaves("[\"one\",{\"a\":true},[null]]|rest", "|rest");
    try expectLeaves("[[[[[]]]]]|rest", "|rest");
}

test "jzon behaviour: skip, steps over a value laid out with whitespace" {
    try expectLeaves("  {  \"a\" :  [ 1 , 2 ]  ,  \"b\" :  true  }  |rest", "  |rest");
    try expectLeaves("\n\t\"padded\"\n|rest", "\n|rest");
}

test "jzon behaviour: skip, steps over a string carrying escapes and braces" {
    // The braces inside the string must not be counted as nesting, and the
    // escaped quote must not be read as the token's end.
    try expectLeaves("{\"a\":\"{ \\\" not structure ] \"}|rest", "|rest");
}

test "jzon behaviour: skip, leaves a value it has not stepped over yet unread" {
    inline for (SHAPES) |shape| {
        var cursor: Cursor = .init("[1,2] [3,4]");

        try skip.value(&cursor, shape);
        try std.testing.expectEqualStrings(" [3,4]", cursor.src[cursor.pos..]);

        try skip.value(&cursor, shape);
        try std.testing.expect(cursor.atEnd());
    }
}

