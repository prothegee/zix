//! zix jzon read cursor.
//!
//! What:
//! - A bounds-checked cursor over a caller-owned document. Every read either has
//!   the bytes it needs or fails, so a truncated document can never be read past
//!   its end.
//! - This file owns one thing: where the next byte comes from and where a token
//!   ends. Turning a token into a value belongs to the parser above it.

const std = @import("std");

/// How a read can fail.
///
/// Note:
/// - Truncated means the document ended early. Unexpected means the byte that is
///   there cannot start what was asked for.
pub const Error = error{ Truncated, Unexpected };

/// A located JSON string token: the bytes between the quotes, plus whether any
/// of them are part of an escape sequence.
///
/// Note:
/// - `raw` is undecoded. When `escaped` is false it is already the string value,
///   which is what lets a parser borrow from the source instead of copying.
pub const StringSpan = struct {
    raw: []const u8,
    escaped: bool,
};

/// A read cursor over a caller-owned document.
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
pub const Cursor = struct {
    src: []const u8,
    pos: usize,

    /// A cursor positioned at the start of `src`.
    pub fn init(src: []const u8) Cursor {
        return .{ .src = src, .pos = 0 };
    }

    /// Whether every byte has been read.
    pub fn atEnd(self: Cursor) bool {
        return self.pos == self.src.len;
    }

    /// How many bytes are still unread.
    pub fn remaining(self: Cursor) usize {
        return self.src.len - self.pos;
    }

    /// The byte at the cursor, without advancing.
    ///
    /// Return:
    /// - u8 (the byte at the current position)
    /// - error.Truncated at the end of the document
    pub fn peek(self: Cursor) Error!u8 {
        if (self.pos == self.src.len) return error.Truncated;

        return self.src[self.pos];
    }

    /// The byte at the cursor, advancing past it.
    ///
    /// Return:
    /// - u8 (the byte that was at the current position)
    /// - error.Truncated at the end of the document
    pub fn take(self: *Cursor) Error!u8 {
        if (self.pos == self.src.len) return error.Truncated;

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
    /// - error.Truncated at the end of the document
    /// - error.Unexpected when a different byte is there
    pub fn expect(self: *Cursor, wanted: u8) Error!void {
        if (self.pos == self.src.len) return error.Truncated;
        if (self.src[self.pos] != wanted) return error.Unexpected;

        self.pos += 1;
    }

    /// Consume one byte only when it is `wanted`.
    ///
    /// Param:
    /// wanted - u8 (the byte to consume when present)
    ///
    /// Return:
    /// - bool (true when the byte was there and was consumed)
    pub fn accept(self: *Cursor, wanted: u8) bool {
        if (self.pos == self.src.len or self.src[self.pos] != wanted) return false;

        self.pos += 1;

        return true;
    }

    /// Consume a compile-time known run and require the document to carry it.
    /// This is how the `true`, `false` and `null` words are read.
    ///
    /// Param:
    /// text - []const u8 (comptime, the run the document must carry here)
    ///
    /// Return:
    /// - void
    /// - error.Truncated when fewer bytes than the run are left
    /// - error.Unexpected when the bytes differ
    pub fn literal(self: *Cursor, comptime text: []const u8) Error!void {
        if (self.remaining() < text.len) return error.Truncated;
        if (!std.mem.eql(u8, self.src[self.pos..][0..text.len], text)) return error.Unexpected;

        self.pos += text.len;
    }

    /// Step over the insignificant whitespace RFC 8259 2 allows between tokens:
    /// space, horizontal tab, line feed, carriage return.
    ///
    /// Note:
    /// - Nothing else counts as whitespace. A control byte outside that set is
    ///   left where it is, so the token that follows reports it instead of the
    ///   skip swallowing it.
    pub fn skipSpace(self: *Cursor) void {
        while (self.pos < self.src.len) : (self.pos += 1) {
            switch (self.src[self.pos]) {
                ' ', '\t', '\n', '\r' => {},
                else => return,
            }
        }
    }

    /// Read a string token, both quotes included, and return the bytes between
    /// them undecoded (RFC 8259 7).
    ///
    /// Note:
    /// - A backslash consumes the byte after it, so an escaped quote does not end
    ///   the token. Whether that escape is spelled correctly is the decoder's
    ///   question, not this one's.
    /// - A raw control byte below 0x20 is rejected, the rule std.json holds to.
    ///
    /// Return:
    /// - StringSpan (the undecoded body, plus whether it holds an escape)
    /// - error.Truncated when the closing quote never arrives
    /// - error.Unexpected when the token does not open with a quote, or carries a
    ///   raw control byte
    pub fn stringSpan(self: *Cursor) Error!StringSpan {
        try self.expect('"');

        const start = self.pos;
        var escaped = false;

        while (self.pos < self.src.len) : (self.pos += 1) {
            const byte = self.src[self.pos];
            if (byte == '"') {
                const raw = self.src[start..self.pos];
                self.pos += 1;

                return .{ .raw = raw, .escaped = escaped };
            }

            if (byte < 0x20) return error.Unexpected;

            if (byte == '\\') {
                if (self.pos + 1 == self.src.len) return error.Truncated;

                escaped = true;
                self.pos += 1;
            }
        }

        return error.Truncated;
    }

    /// Read a number token and return its bytes (RFC 8259 6).
    ///
    /// Note:
    /// - This bounds the token, it does not validate the grammar. `1.2.3` comes
    ///   back whole and is rejected by whatever converts it to a value.
    ///
    /// Return:
    /// - []const u8 (the number's bytes)
    /// - error.Truncated at the end of the document
    /// - error.Unexpected when the byte there is one no number can start with
    pub fn numberSpan(self: *Cursor) Error![]const u8 {
        if (self.pos == self.src.len) return error.Truncated;

        switch (self.src[self.pos]) {
            '-', '0'...'9' => {},
            else => return error.Unexpected,
        }

        const start = self.pos;
        while (self.pos < self.src.len) : (self.pos += 1) {
            switch (self.src[self.pos]) {
                '-', '+', '.', 'e', 'E', '0'...'9' => {},
                else => break,
            }
        }

        return self.src[start..self.pos];
    }
};

// --------------------------------------------------------- //
// --------------------------------------------------------- //

test "zix jzon: cursor walks tokens and reports what is left" {
    var cursor: Cursor = .init("{ \"id\" : 42 }");

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

test "zix jzon: cursor keeps an escaped quote inside the string token" {
    var cursor: Cursor = .init("\"say \\\"hi\\\" now\"rest");

    const span = try cursor.stringSpan();
    try std.testing.expectEqualStrings("say \\\"hi\\\" now", span.raw);
    try std.testing.expect(span.escaped);
    try std.testing.expectEqualStrings("rest", cursor.src[cursor.pos..]);
}

test "zix jzon: cursor reads the literal words and rejects a near miss" {
    var yes: Cursor = .init("true");
    try yes.literal("true");
    try std.testing.expect(yes.atEnd());

    var wrong: Cursor = .init("trve");
    try std.testing.expectError(error.Unexpected, wrong.literal("true"));

    var short: Cursor = .init("nul");
    try std.testing.expectError(error.Truncated, short.literal("null"));
}

test "zix jzon: cursor peek and take agree on the same byte" {
    var cursor: Cursor = .init("ab");

    try std.testing.expectEqual(@as(u8, 'a'), try cursor.peek());
    try std.testing.expectEqual(@as(u8, 'a'), try cursor.take());
    try std.testing.expectEqual(@as(u8, 'b'), try cursor.take());
    try std.testing.expectError(error.Truncated, cursor.peek());
    try std.testing.expectError(error.Truncated, cursor.take());
}

test "zix jzon: cursor accept leaves a byte that does not match" {
    var cursor: Cursor = .init(",]");

    try std.testing.expect(!cursor.accept(']'));
    try std.testing.expect(cursor.accept(','));
    try std.testing.expect(cursor.accept(']'));
    try std.testing.expect(!cursor.accept(']'));
}
