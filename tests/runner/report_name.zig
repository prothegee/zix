//! What a test-runner check calls itself in its result line.
//!
//! What:
//! - One name, built from the example a check runs: `zix-example-<name>-<arch>-<os>`, which is what
//!   that example's installed binary is called. A result line names a file a reader can open.
//!
//! Note:
//! - The runner builds its own copy of each example rather than running the installed one, so the
//!   name is composed here rather than read off the path the runner was handed. The source file is
//!   the same either way, and the file is what somebody goes looking for.
//! - The triple has to match what zix-build-examples.zig appends, or the reported name points at a
//!   binary that is not in zig-out under that name.
//! - std only, no zix. That is what lets this carry its own tests in the same step isolate.zig runs
//!   in, rather than needing the whole check surface compiled as a test binary.

const std = @import("std");
const builtin = @import("builtin");

/// The prefix every reported name carries, so a zix line is telling apart from a sibling project's
/// in a combined log.
pub const PREFIX: []const u8 = "zix-example-";

/// The target triple an installed example binary carries. Comptime, because a runner only ever
/// reports about its own target.
pub const TARGET_TRIPLE = @tagName(builtin.target.cpu.arch) ++ "-" ++ @tagName(builtin.target.os.tag);

/// Longest name `write` produces.
pub const MAX_LEN: usize = 96;

/// The name a check reports itself as.
///
/// Note:
/// - Falls back to the bare example name when the buffer is too small, so a result line is always
///   printed even if it is shorter than intended. A runner that swallowed its own output over a
///   naming detail would be worse than one that names a check plainly.
///
/// Param:
/// buf - []u8 (at least MAX_LEN)
/// example - []const u8 (the example file stem, without its .zig)
///
/// Return:
/// - []const u8, borrowing `buf`
pub fn write(buf: []u8, example: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "{s}{s}-{s}", .{ PREFIX, example, TARGET_TRIPLE }) catch example;
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //

test "zix runner: report name, it reads as the example's installed binary" {
    var buf: [MAX_LEN]u8 = undefined;
    const name = write(&buf, "http_basic");

    try std.testing.expect(std.mem.startsWith(u8, name, "zix-example-http_basic-"));
    try std.testing.expect(std.mem.endsWith(u8, name, TARGET_TRIPLE));
}

test "zix runner: report name, the triple is this build's own target" {
    var buf: [MAX_LEN]u8 = undefined;
    const name = write(&buf, "tcp_server");

    // The same two tags zix-build-examples.zig joins for the installed binary.
    const expected = "zix-example-tcp_server-" ++
        @tagName(builtin.target.cpu.arch) ++ "-" ++ @tagName(builtin.target.os.tag);

    try std.testing.expectEqualStrings(expected, name);
}

test "zix runner: report name, two examples never report the same name" {
    var first_buf: [MAX_LEN]u8 = undefined;
    var second_buf: [MAX_LEN]u8 = undefined;

    const first = write(&first_buf, "http_static");
    const second = write(&second_buf, "http1_static");

    try std.testing.expect(!std.mem.eql(u8, first, second));
}

test "zix runner: report name, the longest example this repository has still fits" {
    var buf: [MAX_LEN]u8 = undefined;

    // Longer than any example file stem in the tree, so MAX_LEN has room to spare for the next one.
    const name = write(&buf, "http1_manual_concurrent_and_then_some");

    try std.testing.expect(std.mem.startsWith(u8, name, PREFIX));
    try std.testing.expect(std.mem.endsWith(u8, name, TARGET_TRIPLE));
}

test "zix runner: report name, a buffer too small answers the example rather than nothing" {
    var tiny: [4]u8 = undefined;

    try std.testing.expectEqualStrings("http_basic", write(&tiny, "http_basic"));
}
