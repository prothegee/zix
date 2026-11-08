//! JZON string_value
//!
//! ### file: src/jzon/src/deserialize/string_value.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Turns a bounded string token into the bytes a parse hands back: a slice of the
//! document when it may be borrowed, bytes in the allocator otherwise.
//!
//! ### note:
//!
//! A token with an escape is decoded into the allocator whatever string mode was asked
//! for, because its decoded bytes appear nowhere in the document. The decoded form is
//! never longer than the undecoded one (every escape spells more bytes than the
//! character it stands for), so the room taken is the undecoded length and the slack
//! is handed back.
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
const Sink = @import("../Sink.zig");
const StringSpan = @import("../StringSpan.zig");
const escape = @import("../escape.zig");

const Allocator = std.mem.Allocator;

// --------------------------------------------------------- //
// Private:

/// Translate an `escape` failure into this module's set.
///
/// Param:
/// err - escape.Error (the failure the decoder reported)
///
/// Return:
/// - Error (the same failure under this module's name)
fn escapeError(err: escape.Error) Error {
    return switch (err) {
        error.Jzon_Escape_NoSpaceLeft => Error.Jzon_StringValue_NoSpaceLeft,
        error.Jzon_Escape_BadEscape => Error.Jzon_StringValue_BadEscape,
    };
}

/// Write a token's decoded bytes into the allocator.
///
/// Note:
/// - Room for the undecoded length always holds the decoded form, so the sink cannot
///   run out. The branch is still mapped, so a future escape form that grew could
///   never write past the room it was given.
///
/// Param:
/// allocator - Allocator (owns the decoded bytes)
/// raw - []const u8 (the undecoded token body)
///
/// Return:
/// - []const u8 (the decoded bytes)
/// - Error.Jzon_StringValue_BadEscape when an escape is one the rules do not spell
/// - Error.Jzon_StringValue_OutOfMemory when the allocator runs out
fn decode(allocator: Allocator, raw: []const u8) Error![]const u8 {
    const room = allocator.alloc(u8, raw.len) catch |err| switch (err) {
        error.OutOfMemory => return Error.Jzon_StringValue_OutOfMemory,
    };
    var sink: Sink = .init(room);

    escape.decode(&sink, raw) catch |err| return escapeError(err);

    const decoded = sink.written();

    // Best effort: a refused shrink only keeps the slack, the bytes are already right.
    _ = allocator.resize(room, decoded);

    return room[0..decoded];
}

// --------------------------------------------------------- //
// Public:

/// How taking a string can fail.
///
/// Note:
/// - NoSpaceLeft exists so every member of `escape.Error` maps to a real member here.
///   The room given to the decoder always fits, so it is never returned.
pub const Error = error{
    Jzon_StringValue_BadEscape,
    Jzon_StringValue_NoSpaceLeft,
    Jzon_StringValue_OutOfMemory,
};

/// The value of one string token.
///
/// Param:
/// allocator - Allocator (owns any bytes that are not the document's own)
/// span - StringSpan (the token's undecoded body, as a read cursor bounds it)
/// options - DeserializeOptions (comptime, which string mode the parse runs in)
///
/// Return:
/// - []const u8 (points into the document only under `.BORROW` and only when the token
///   carried no escape)
/// - Error.Jzon_StringValue_BadEscape when an escape is one the rules do not spell
/// - Error.Jzon_StringValue_OutOfMemory when the allocator runs out
pub fn take(
    allocator: Allocator,
    span: StringSpan,
    comptime options: DeserializeOptions,
) Error![]const u8 {
    if (span.escaped) return decode(allocator, span.raw);

    if (options.strings == .BORROW) return span.raw;

    return allocator.dupe(u8, span.raw) catch |err| switch (err) {
        error.OutOfMemory => Error.Jzon_StringValue_OutOfMemory,
    };
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

/// Whether `text` points inside `document`.
fn pointsInto(text: []const u8, document: []const u8) bool {
    return @intFromPtr(text.ptr) >= @intFromPtr(document.ptr) and
        @intFromPtr(text.ptr) < @intFromPtr(document.ptr) + document.len;
}

/// A span over `raw`, flagged as carrying an escape.
fn escapedSpan(raw: []const u8) StringSpan {
    return .{
        .raw = raw,
        .escaped = true,
    };
}

/// A span over `raw`, flagged as clean.
fn cleanSpan(raw: []const u8) StringSpan {
    return .{
        .raw = raw,
        .escaped = false,
    };
}

test "jzon deserialize: string_value, borrowed clean string is the document's own bytes" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const document = "borrowed";
    const taken = try take(arena.allocator(), cleanSpan(document), .{ .strings = .BORROW });

    try std.testing.expectEqualStrings("borrowed", taken);
    try std.testing.expect(pointsInto(taken, document));
}

test "jzon deserialize: string_value, copied clean string leaves the document behind" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const document = "copied";
    const taken = try take(arena.allocator(), cleanSpan(document), .{ .strings = .COPY });

    try std.testing.expectEqualStrings("copied", taken);
    try std.testing.expect(!pointsInto(taken, document));
}

test "jzon deserialize: string_value, escaped string is decoded under BORROW" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const document = "one\\ttwo";
    const taken = try take(arena.allocator(), escapedSpan(document), .{ .strings = .BORROW });

    try std.testing.expectEqualStrings("one\ttwo", taken);
    try std.testing.expect(!pointsInto(taken, document));
}

test "jzon deserialize: string_value, escaped string is decoded under COPY" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const taken = try take(arena.allocator(), escapedSpan("one\\ttwo"), .{ .strings = .COPY });

    try std.testing.expectEqualStrings("one\ttwo", taken);
}

test "jzon deserialize: string_value, decoded string is exactly as long as its value" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const taken = try take(arena.allocator(), escapedSpan("\\ud83d\\udca9"), .{});

    try std.testing.expectEqualStrings("\xf0\x9f\x92\xa9", taken);
    try std.testing.expectEqual(@as(usize, 4), taken.len);
}

test "jzon deserialize: string_value, escapeError maps no space left" {
    const err = escapeError(error.Jzon_Escape_NoSpaceLeft);

    try std.testing.expectEqual(Error.Jzon_StringValue_NoSpaceLeft, err);
}

test "jzon deserialize: string_value, escapeError maps bad escape" {
    const err = escapeError(error.Jzon_Escape_BadEscape);

    try std.testing.expectEqual(Error.Jzon_StringValue_BadEscape, err);
}

test "jzon deserialize: string_value, empty token comes back empty in either mode" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    const borrowed = try take(allocator, cleanSpan(""), .{ .strings = .BORROW });
    const copied = try take(allocator, cleanSpan(""), .{ .strings = .COPY });

    try std.testing.expectEqual(@as(usize, 0), borrowed.len);
    try std.testing.expectEqual(@as(usize, 0), copied.len);
}

test "jzon deserialize: string_value, token of only escapes decodes to its value alone" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const taken = try take(arena.allocator(), escapedSpan("\\u0000\\u001f\\u007f"), .{});

    try std.testing.expectEqualStrings("\x00\x1f\x7f", taken);
}

test "jzon deserialize: string_value, escape the rules do not spell is bad escape" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    const broken = [_][]const u8{
        "\\",
        "\\q",
        "\\u",
        "\\u00",
        "\\u00zz",
        "\\ud83d",
        "\\udca9",
        "\\ud83d\\u0041",
    };

    for (broken) |raw| {
        try std.testing.expectError(
            Error.Jzon_StringValue_BadEscape,
            take(allocator, escapedSpan(raw), .{}),
        );
    }
}

test "jzon deserialize: string_value, token flagged escaped without one comes back unchanged" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    // A read cursor never produces this pairing, but decoding a clean body has to be
    // the body itself, not a failure.
    const taken = try take(arena.allocator(), escapedSpan("plain"), .{ .strings = .BORROW });

    try std.testing.expectEqualStrings("plain", taken);
}

test "jzon deserialize: string_value, copy with an empty allocator is out of memory" {
    var failing: std.testing.FailingAllocator = .init(std.testing.allocator, .{
        .fail_index = 0,
    });

    try std.testing.expectError(
        Error.Jzon_StringValue_OutOfMemory,
        take(failing.allocator(), cleanSpan("copied"), .{ .strings = .COPY }),
    );
}

test "jzon deserialize: string_value, decode with an empty allocator is out of memory" {
    var failing: std.testing.FailingAllocator = .init(std.testing.allocator, .{
        .fail_index = 0,
    });

    try std.testing.expectError(
        Error.Jzon_StringValue_OutOfMemory,
        take(failing.allocator(), escapedSpan("one\\ttwo"), .{}),
    );
}

test "jzon deserialize: string_value, borrow of a clean token asks the allocator for nothing" {
    var failing: std.testing.FailingAllocator = .init(std.testing.allocator, .{
        .fail_index = 0,
    });

    const document = "borrowed";
    const taken = try take(failing.allocator(), cleanSpan(document), .{ .strings = .BORROW });

    try std.testing.expectEqualStrings(document, taken);
    try std.testing.expectEqual(@as(usize, 0), failing.allocations);
}

test "jzon deserialize: string_value, escape as long as its value keeps every byte" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    // Four hex digits become up to three UTF-8 bytes, so the escape is always the
    // longer spelling and the room taken always holds the result.
    const taken = try take(arena.allocator(), escapedSpan("\\uffff"), .{});

    try std.testing.expectEqualStrings("\xef\xbf\xbf", taken);
}

