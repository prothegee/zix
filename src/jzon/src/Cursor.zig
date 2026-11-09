//! JZON Cursor
//!
//! ### file: src/jzon/src/Cursor.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Bounds-checked read cursor over a caller-owned document: where the next byte comes
//! from and where a token ends.
//!
//! ### note:
//!
//! Every read either has the bytes it needs or fails, so a truncated document is never
//! read past its end. A failure also records its byte offset in `Failure`, read back
//! with `jzon.lastFailure()`.
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
const Failure = @import("deserialize/Failure.zig");
const StringSpan = @import("StringSpan.zig");

// --------------------------------------------------------- //
// Fields:

/// The caller-owned document every read comes from.
src: []const u8,
/// Where the next byte comes from, also the count of bytes read so far.
pos: usize,

const Self = @This();

// --------------------------------------------------------- //
// Public:

/// How a read can fail.
///
/// Note:
/// - Truncated means the document ended early. Unexpected means the byte that is
///   there cannot start what was asked for.
pub const Error = error{
    Jzon_Cursor_Truncated,
    Jzon_Cursor_Unexpected,
};

/// The insignificant whitespace RFC8259 section 2 allows between tokens: space,
/// horizontal tab, line feed, carriage return.
///
/// Note:
/// - Nothing else counts. A control byte outside this set is a token's problem, not
///   a skip's, so it is left where it is.
pub const WHITESPACE = [_]u8{
    ' ',
    '\t',
    '\n',
    '\r',
};

/// Whether one byte is insignificant whitespace.
///
/// Note:
/// - This is the whole rule, and every scan over a document asks it. A vector scan
///   builds its lane comparisons from the same `WHITESPACE` list, so the two widths
///   never drift apart.
///
/// Param:
/// byte - u8 (the byte to classify)
///
/// Return:
/// - bool (true when the byte may be stepped over between tokens)
pub inline fn isSpace(byte: u8) bool {
    inline for (WHITESPACE) |allowed| {
        if (byte == allowed) return true;
    }

    return false;
}

/// A cursor positioned at the start of `src`.
///
/// Usage:
/// ```zig
/// var cursor: Cursor = .init("{ \"id\": 42 }");
///
/// try cursor.expect('{');
/// cursor.skipSpace();
///
/// const key = try cursor.stringSpan();
/// ```
///
/// Param:
/// src - []const u8 (the document to read, owned by the caller)
///
/// Return:
/// - Self
pub fn init(src: []const u8) Self {
    return .{
        .src = src,
        .pos = 0,
    };
}

/// Record where the read stopped, then hand the error back.
///
/// Note:
/// - The error value has nowhere to put an offset, so it goes to `Failure` and the
///   caller reads it with `jzon.lastFailure()` right after the parse returned.
/// - Public so a scan at another width (`cursor_vector`) records its stop the same
///   way, through this one function.
///
/// Param:
/// err - Error (the error to return)
///
/// Return:
/// - Error (the same error it was given, always)
pub fn stopAt(self: Self, err: Error) Error {
    @branchHint(.cold);

    Failure.noteOffset(self.pos);

    return err;
}

/// Whether every byte has been read.
///
/// Return:
/// - bool
pub fn atEnd(self: Self) bool {
    return self.pos == self.src.len;
}

/// How many bytes are still unread.
///
/// Return:
/// - usize
pub fn remaining(self: Self) usize {
    return self.src.len - self.pos;
}

/// The byte at the cursor, without advancing.
///
/// Return:
/// - u8 (the byte at the current position)
/// - Error.Jzon_Cursor_Truncated at the end of the document
pub fn peek(self: Self) Error!u8 {
    if (self.pos == self.src.len) return self.stopAt(Error.Jzon_Cursor_Truncated);

    return self.src[self.pos];
}

/// The byte at the cursor, advancing past it.
///
/// Return:
/// - u8 (the byte that was at the current position)
/// - Error.Jzon_Cursor_Truncated at the end of the document
pub fn take(self: *Self) Error!u8 {
    if (self.pos == self.src.len) return self.stopAt(Error.Jzon_Cursor_Truncated);

    const value = self.src[self.pos];
    self.pos += 1;

    return value;
}

/// Consume one byte and require it to be `wanted`.
///
/// Param:
/// wanted - u8 (the byte the document must carry here)
///
/// Return:
/// - void
/// - Error.Jzon_Cursor_Truncated at the end of the document
/// - Error.Jzon_Cursor_Unexpected when a different byte is there
pub fn expect(self: *Self, wanted: u8) Error!void {
    if (self.pos == self.src.len) return self.stopAt(Error.Jzon_Cursor_Truncated);
    if (self.src[self.pos] != wanted) return self.stopAt(Error.Jzon_Cursor_Unexpected);

    self.pos += 1;
}

/// Consume one byte only when it is `wanted`.
///
/// Param:
/// wanted - u8 (the byte to consume when present)
///
/// Return:
/// - bool (true when the byte was there and was consumed)
pub fn accept(self: *Self, wanted: u8) bool {
    if (self.pos == self.src.len or self.src[self.pos] != wanted) return false;

    self.pos += 1;

    return true;
}

/// Consume a compile-time known run and require the document to carry it. This is
/// how the `true`, `false`, and `null` words are read.
///
/// Param:
/// text - []const u8 (comptime, the run the document must carry here)
///
/// Return:
/// - void
/// - Error.Jzon_Cursor_Truncated when fewer bytes than the run are left
/// - Error.Jzon_Cursor_Unexpected when the bytes differ
pub fn literal(self: *Self, comptime text: []const u8) Error!void {
    if (self.remaining() < text.len) return self.stopAt(Error.Jzon_Cursor_Truncated);

    const matches = std.mem.eql(u8, self.src[self.pos..][0..text.len], text);
    if (!matches) return self.stopAt(Error.Jzon_Cursor_Unexpected);

    self.pos += text.len;
}

/// Step over the insignificant whitespace between tokens, one byte at a time.
/// `isSpace` holds the set.
///
/// Return:
/// - void
pub fn skipSpace(self: *Self) void {
    const src = self.src;
    var pos = self.pos;

    while (pos < src.len and isSpace(src[pos])) : (pos += 1) {}

    self.pos = pos;
}

/// Read a string token, both quotes included, and return the bytes between them
/// undecoded (RFC8259 section 7).
///
/// Note:
/// - A backslash consumes the byte after it, so an escaped quote does not end the
///   token. Whether that escape is spelled correctly is the decoder's question.
/// - A raw control byte below 0x20 is rejected, the rule std.json holds to.
/// - The scan runs on local copies of `src` and `pos` and writes the position back
///   once, as `skipSpace` and `numberSpan` do. Through `self`, the compiler has to
///   assume a byte read may change the position and reloads it every step (measured).
///
/// Return:
/// - StringSpan (the undecoded body, plus whether it holds an escape)
/// - Error.Jzon_Cursor_Truncated when the closing quote never arrives
/// - Error.Jzon_Cursor_Unexpected when the token does not open with a quote, or
///   carries a raw control byte
pub fn stringSpan(self: *Self) Error!StringSpan {
    try self.expect('"');

    const src = self.src;
    const start = self.pos;
    var pos = start;
    var escaped = false;

    while (pos < src.len) : (pos += 1) {
        const byte = src[pos];
        if (byte == '"') {
            self.pos = pos + 1;

            return .{
                .raw = src[start..pos],
                .escaped = escaped,
            };
        }

        if (byte < 0x20) {
            self.pos = pos;

            return self.stopAt(Error.Jzon_Cursor_Unexpected);
        }

        if (byte == '\\') {
            if (pos + 1 == src.len) {
                self.pos = pos;

                return self.stopAt(Error.Jzon_Cursor_Truncated);
            }

            escaped = true;
            pos += 1;
        }
    }

    self.pos = pos;

    return self.stopAt(Error.Jzon_Cursor_Truncated);
}

/// Read a number token and return its bytes (RFC8259 section 6).
///
/// Note:
/// - This bounds the token, it does not validate the grammar. `1.2.3` comes back
///   whole and is rejected by whatever converts it to a value.
///
/// Return:
/// - []const u8 (the number's bytes)
/// - Error.Jzon_Cursor_Truncated at the end of the document
/// - Error.Jzon_Cursor_Unexpected when the byte there is one no number can start with
pub fn numberSpan(self: *Self) Error![]const u8 {
    if (self.pos == self.src.len) return self.stopAt(Error.Jzon_Cursor_Truncated);

    switch (self.src[self.pos]) {
        '-', '0'...'9' => {},
        else => return self.stopAt(Error.Jzon_Cursor_Unexpected),
    }

    const src = self.src;
    const start = self.pos;
    var pos = start;

    while (pos < src.len) : (pos += 1) {
        switch (src[pos]) {
            '-', '+', '.', 'e', 'E', '0'...'9' => {},
            else => break,
        }
    }

    self.pos = pos;

    return src[start..pos];
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "jzon: Cursor, walks tokens and reports what is left" {
    var cursor: Self = .init("{ \"id\" : 42 }");

    try cursor.expect('{');
    cursor.skipSpace();

    const key = try cursor.stringSpan();
    try std.testing.expectEqualStrings("id", key.raw);
    try std.testing.expect(!key.escaped);

    cursor.skipSpace();
    try cursor.expect(':');
    cursor.skipSpace();

    try std.testing.expectEqualStrings("42", try cursor.numberSpan());

    cursor.skipSpace();
    try std.testing.expect(cursor.accept('}'));
    try std.testing.expect(cursor.atEnd());
    try std.testing.expectEqual(@as(usize, 0), cursor.remaining());
}

test "jzon: Cursor, keeps an escaped quote inside the string token" {
    var cursor: Self = .init("\"say \\\"hi\\\" now\"rest");

    const span = try cursor.stringSpan();

    try std.testing.expectEqualStrings("say \\\"hi\\\" now", span.raw);
    try std.testing.expect(span.escaped);
    try std.testing.expectEqualStrings("rest", cursor.src[cursor.pos..]);
}

test "jzon: Cursor, literal reads a matching word" {
    var cursor: Self = .init("true");

    try cursor.literal("true");

    try std.testing.expect(cursor.atEnd());
}

test "jzon: Cursor, literal rejects a near miss" {
    var cursor: Self = .init("trve");

    try std.testing.expectError(Error.Jzon_Cursor_Unexpected, cursor.literal("true"));
}

test "jzon: Cursor, literal on a short document is truncated" {
    var cursor: Self = .init("nul");

    try std.testing.expectError(Error.Jzon_Cursor_Truncated, cursor.literal("null"));
}

test "jzon: Cursor, peek and take agree on the same byte" {
    var cursor: Self = .init("ab");

    try std.testing.expectEqual(@as(u8, 'a'), try cursor.peek());
    try std.testing.expectEqual(@as(u8, 'a'), try cursor.take());
    try std.testing.expectEqual(@as(u8, 'b'), try cursor.take());
    try std.testing.expectError(Error.Jzon_Cursor_Truncated, cursor.peek());
    try std.testing.expectError(Error.Jzon_Cursor_Truncated, cursor.take());
}

test "jzon: Cursor, isSpace answers for exactly the bytes skipSpace steps over" {
    for (0..256) |value| {
        const byte: u8 = @intCast(value);

        var cursor: Self = .init(&[_]u8{byte});
        cursor.skipSpace();

        try std.testing.expectEqual(isSpace(byte), cursor.atEnd());
    }

    try std.testing.expectEqual(@as(usize, 4), WHITESPACE.len);
}

test "jzon: Cursor, accept leaves a byte that does not match" {
    var cursor: Self = .init(",]");

    try std.testing.expect(!cursor.accept(']'));
    try std.testing.expect(cursor.accept(','));
    try std.testing.expect(cursor.accept(']'));
    try std.testing.expect(!cursor.accept(']'));
}

test "jzon: Cursor, empty document has nothing to give" {
    var cursor: Self = .init("");

    try std.testing.expect(cursor.atEnd());
    try std.testing.expectEqual(@as(usize, 0), cursor.remaining());
    try std.testing.expectError(Error.Jzon_Cursor_Truncated, cursor.peek());
    try std.testing.expectError(Error.Jzon_Cursor_Truncated, cursor.take());
    try std.testing.expectError(Error.Jzon_Cursor_Truncated, cursor.expect('{'));
    try std.testing.expectError(Error.Jzon_Cursor_Truncated, cursor.stringSpan());
    try std.testing.expectError(Error.Jzon_Cursor_Truncated, cursor.numberSpan());
    try std.testing.expect(!cursor.accept('{'));

    cursor.skipSpace();
    try std.testing.expect(cursor.atEnd());
}

test "jzon: Cursor, all-whitespace document lands at the end" {
    var cursor: Self = .init(" \t\n\r");

    cursor.skipSpace();

    try std.testing.expect(cursor.atEnd());
}

test "jzon: Cursor, string that never closes is truncated" {
    var open: Self = .init("\"unterminated");
    try std.testing.expectError(Error.Jzon_Cursor_Truncated, open.stringSpan());

    var trailing_backslash: Self = .init("\"broken\\");
    try std.testing.expectError(Error.Jzon_Cursor_Truncated, trailing_backslash.stringSpan());

    var escaped_close: Self = .init("\"never done\\\"");
    try std.testing.expectError(Error.Jzon_Cursor_Truncated, escaped_close.stringSpan());
}

test "jzon: Cursor, raw control byte inside a string is unexpected" {
    var newline: Self = .init("\"line\nbreak\"");
    try std.testing.expectError(Error.Jzon_Cursor_Unexpected, newline.stringSpan());

    var nul: Self = .init("\"has\x00nul\"");
    try std.testing.expectError(Error.Jzon_Cursor_Unexpected, nul.stringSpan());

    var unit_separator: Self = .init("\"has\x1fseparator\"");
    try std.testing.expectError(Error.Jzon_Cursor_Unexpected, unit_separator.stringSpan());
}

test "jzon: Cursor, boundary bytes 0x20, 0x7f, and 0xff pass raw in a string" {
    var space: Self = .init("\" \"");
    try std.testing.expectEqualStrings(" ", (try space.stringSpan()).raw);

    var delete: Self = .init("\"\x7f\"");
    try std.testing.expectEqualStrings("\x7f", (try delete.stringSpan()).raw);

    var high: Self = .init("\"\xff\"");
    try std.testing.expectEqualStrings("\xff", (try high.stringSpan()).raw);
}

test "jzon: Cursor, empty string token gives an empty span" {
    var cursor: Self = .init("\"\"");

    const span = try cursor.stringSpan();

    try std.testing.expectEqual(@as(usize, 0), span.raw.len);
    try std.testing.expect(!span.escaped);
    try std.testing.expect(cursor.atEnd());
}

test "jzon: Cursor, expect on a wrong byte is unexpected" {
    var cursor: Self = .init("}");

    try std.testing.expectError(Error.Jzon_Cursor_Unexpected, cursor.expect('{'));
}

test "jzon: Cursor, expect on a spent document is truncated" {
    var cursor: Self = .init("");

    try std.testing.expectError(Error.Jzon_Cursor_Truncated, cursor.expect('{'));
}

test "jzon: Cursor, stringSpan on a number is unexpected" {
    var cursor: Self = .init("42");

    try std.testing.expectError(Error.Jzon_Cursor_Unexpected, cursor.stringSpan());
}

test "jzon: Cursor, numberSpan on a string is unexpected" {
    var cursor: Self = .init("\"42\"");

    try std.testing.expectError(Error.Jzon_Cursor_Unexpected, cursor.numberSpan());
}

test "jzon: Cursor, numberSpan runs to the end of the document" {
    var cursor: Self = .init("12345");

    try std.testing.expectEqualStrings("12345", try cursor.numberSpan());
    try std.testing.expect(cursor.atEnd());
}

test "jzon: Cursor, numberSpan holds a malformed token whole" {
    var cursor: Self = .init("1.2.3,");

    // Bounding a token and validating it are separate jobs. The malformed run comes
    // back whole and is rejected by whatever converts it.
    try std.testing.expectEqualStrings("1.2.3", try cursor.numberSpan());
    try std.testing.expect(cursor.accept(','));
}

test "jzon: Cursor, literal fits exactly at the end of the document" {
    var cursor: Self = .init("null");

    try cursor.literal("null");

    try std.testing.expect(cursor.atEnd());
}

test "jzon: Cursor, literal one byte short leaves the position untouched" {
    var cursor: Self = .init("fals");

    try std.testing.expectError(Error.Jzon_Cursor_Truncated, cursor.literal("false"));
    try std.testing.expectEqual(@as(usize, 4), cursor.remaining());
}

test "jzon: Cursor, truncation notes the stop offset in Failure" {
    Failure.reset();
    var cursor: Self = .init("\"open");

    try std.testing.expectError(Error.Jzon_Cursor_Truncated, cursor.stringSpan());

    const failure = Failure.lastFailure();
    try std.testing.expect(failure.filled);
    try std.testing.expectEqual(@as(usize, 5), failure.offset);
}

test "jzon: Cursor, unexpected byte notes the stop offset in Failure" {
    Failure.reset();
    var cursor: Self = .init("  x");

    cursor.skipSpace();
    try std.testing.expectError(Error.Jzon_Cursor_Unexpected, cursor.expect('{'));

    const failure = Failure.lastFailure();
    try std.testing.expect(failure.filled);
    try std.testing.expectEqual(@as(usize, 2), failure.offset);
}

test "jzon: Cursor, stopAt returns the error it was given" {
    var cursor: Self = .init("ab");
    cursor.pos = 1;

    const err = cursor.stopAt(Error.Jzon_Cursor_Unexpected);

    try std.testing.expectEqual(Error.Jzon_Cursor_Unexpected, err);
}

test "jzon: Cursor, stopAt at the end of the document notes that offset" {
    Failure.reset();
    var cursor: Self = .init("ab");
    cursor.pos = 2;

    const err = cursor.stopAt(Error.Jzon_Cursor_Truncated);

    try std.testing.expectEqual(Error.Jzon_Cursor_Truncated, err);
    try std.testing.expectEqual(@as(usize, 2), Failure.lastFailure().offset);
}

test "jzon: Cursor, numberSpan on a non-number notes the stop offset in Failure" {
    Failure.reset();
    var cursor: Self = .init("[x");

    try cursor.expect('[');
    try std.testing.expectError(Error.Jzon_Cursor_Unexpected, cursor.numberSpan());

    const failure = Failure.lastFailure();
    try std.testing.expect(failure.filled);
    try std.testing.expectEqual(@as(usize, 1), failure.offset);
}

