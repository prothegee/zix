//! JZON deserialize Failure
//!
//! ### file: src/jzon/src/deserialize/Failure.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Which field and which byte the last failed parse on this thread stopped on.
//!
//! ### note:
//!
//! An error value has nowhere to put a field name or an offset, so this is a side
//! channel. It is per thread and the next failure replaces it, so read it right after
//! a parse returned an error.
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

// --------------------------------------------------------- //
// Fields:

/// The field the failure is about, empty when the failure is not about a field.
field: []const u8 = "",
/// Byte offset into the source where the parse stopped, or 0 when the path cannot
/// report one. The std-backed path never reports an offset, because std does not
/// surface its scanner's.
offset: usize = 0,
/// False until a parse has failed on this thread.
filled: bool = false,

const Self = @This();

// --------------------------------------------------------- //
// Private:

/// Per thread, because a parse never crosses threads: it is one call over one buffer.
threadlocal var last_failure: Self = .{};

// --------------------------------------------------------- //
// Public:

/// What the last failed parse on this thread was about.
///
/// Note:
/// - Read it immediately after a parse returned an error. A later failure
///   overwrites it, and a successful parse leaves whatever the previous failure wrote.
///
/// Usage:
/// ```zig
/// const record = jzon.deserialize(Order, allocator, body, .{}) catch |err| {
///     const failure = jzon.lastFailure();
///     std.log.err("{s} at byte {d}: {s}", .{
///         @errorName(err),
///         failure.offset,
///         failure.field,
///     });
///
///     return err;
/// };
/// ```
///
/// Return:
/// - Self (with `filled` false when nothing has failed on this thread yet)
pub fn lastFailure() Self {
    return last_failure;
}

/// Record that the failure about to be returned is about this field.
///
/// Param:
/// field - []const u8 (the field name, borrowed from the source or from reflection)
///
/// Return:
/// - void
pub fn noteField(field: []const u8) void {
    last_failure = .{
        .field = field,
        .offset = 0,
        .filled = true,
    };
}

/// Record that the failure about to be returned stopped at this byte.
///
/// Param:
/// offset - usize (byte offset into the source)
///
/// Return:
/// - void
pub fn noteOffset(offset: usize) void {
    last_failure = .{
        .field = "",
        .offset = offset,
        .filled = true,
    };
}

/// Record both, for a failure that knows the field and where it was reading.
///
/// Param:
/// field - []const u8 (the field name, borrowed from the source or from reflection)
/// offset - usize (byte offset into the source)
///
/// Return:
/// - void
pub fn noteFieldAt(field: []const u8, offset: usize) void {
    last_failure = .{
        .field = field,
        .offset = offset,
        .filled = true,
    };
}

/// Forget the last failure, so a test or a long-lived worker does not read a stale one.
///
/// Return:
/// - void
pub fn reset() void {
    last_failure = .{};
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "jzon deserialize: Failure, starts unfilled" {
    reset();

    const failure = lastFailure();

    try std.testing.expect(!failure.filled);
    try std.testing.expectEqual(@as(usize, 0), failure.offset);
    try std.testing.expectEqualStrings("", failure.field);
}

test "jzon deserialize: Failure, carries the field a failure was about" {
    reset();
    noteField("customer");

    const failure = lastFailure();

    try std.testing.expect(failure.filled);
    try std.testing.expectEqualStrings("customer", failure.field);
}

test "jzon deserialize: Failure, carries the byte a failure stopped on" {
    reset();
    noteOffset(42);

    const failure = lastFailure();

    try std.testing.expect(failure.filled);
    try std.testing.expectEqual(@as(usize, 42), failure.offset);
    try std.testing.expectEqualStrings("", failure.field);
}

test "jzon deserialize: Failure, carries field and byte when the path knows both" {
    reset();
    noteFieldAt("status", 17);

    const failure = lastFailure();

    try std.testing.expectEqualStrings("status", failure.field);
    try std.testing.expectEqual(@as(usize, 17), failure.offset);
}

test "jzon deserialize: Failure, newest note replaces the one before" {
    reset();
    noteField("first");
    noteOffset(9);

    const failure = lastFailure();

    try std.testing.expectEqualStrings("", failure.field);
    try std.testing.expectEqual(@as(usize, 9), failure.offset);
}

test "jzon deserialize: Failure, reset clears a filled failure" {
    noteFieldAt("total", 3);
    reset();

    const failure = lastFailure();

    try std.testing.expect(!failure.filled);
    try std.testing.expectEqualStrings("", failure.field);
}

test "jzon deserialize: Failure, offset at zero still counts as filled" {
    reset();
    noteOffset(0);

    const failure = lastFailure();

    try std.testing.expect(failure.filled);
    try std.testing.expectEqual(@as(usize, 0), failure.offset);
}

