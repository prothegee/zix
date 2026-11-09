//! JZON zon grammar
//!
//! ### file: src/jzon/src/zon/grammar.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! ZON byte classes and token bounds: where whitespace, comments, names, numbers and
//! strings start and end.
//!
//! ### note:
//!
//! A bound only says where a token ends. It does not check what is inside: a number
//! token is checked by `std.zig.parseNumberLiteral` and a string escape by
//! `std.zig.string_literal`, both on the parse side.
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
// Private:

/// Whether `pos` starts a `//` comment.
///
/// Param:
/// src - []const u8 (the document)
/// pos - usize (where to look)
///
/// Return:
/// - bool (true when the two bytes at `pos` are `//`)
fn isCommentAt(src: []const u8, pos: usize) bool {
    return pos + 1 < src.len and src[pos] == '/' and src[pos + 1] == '/';
}

// --------------------------------------------------------- //
// Public:

/// How a string bound can fail.
///
/// Note:
/// - Truncated means the document ended before the closing quote. Unexpected means a
///   raw line break or control byte sits inside the quotes, which Zig does not allow.
pub const Error = error{
    Jzon_ZonGrammar_Truncated,
    Jzon_ZonGrammar_Unexpected,
};

/// Whether a byte is whitespace between tokens.
///
/// Param:
/// byte - u8 (the byte to classify)
///
/// Return:
/// - bool (true for space, tab, line feed, carriage return)
pub fn isSpace(byte: u8) bool {
    return switch (byte) {
        ' ', '\t', '\n', '\r' => true,
        else => false,
    };
}

/// Whether a byte can start a bare name such as `name`, `true` or `inf`.
///
/// Param:
/// byte - u8 (the byte to classify)
///
/// Return:
/// - bool (true for a letter or `_`)
pub fn isNameStart(byte: u8) bool {
    return switch (byte) {
        'a'...'z', 'A'...'Z', '_' => true,
        else => false,
    };
}

/// Whether a byte can continue a bare name.
///
/// Param:
/// byte - u8 (the byte to classify)
///
/// Return:
/// - bool (true for a letter, a digit or `_`)
pub fn isNameChar(byte: u8) bool {
    return isNameStart(byte) or (byte >= '0' and byte <= '9');
}

/// Step over whitespace and `//` comments.
///
/// Note:
/// - `///` and `//!` are comments too, they start with `//`.
///
/// Param:
/// src - []const u8 (the document)
/// pos - usize (where to start)
///
/// Return:
/// - usize (the first byte that is neither, or `src.len`)
pub fn skipIgnored(src: []const u8, pos: usize) usize {
    var at = pos;

    while (at < src.len) {
        if (isSpace(src[at])) {
            at += 1;
        } else if (isCommentAt(src, at)) {
            at = lineEnd(src, at);
        } else {
            break;
        }
    }

    return at;
}

/// Where the line holding `pos` ends.
///
/// Param:
/// src - []const u8 (the document)
/// pos - usize (any byte on the line)
///
/// Return:
/// - usize (the index of the `\n`, or `src.len` on the last line)
pub fn lineEnd(src: []const u8, pos: usize) usize {
    return std.mem.indexOfScalarPos(u8, src, pos, '\n') orelse src.len;
}

/// Where a bare name ends.
///
/// Param:
/// src - []const u8 (the document)
/// pos - usize (the name's first byte)
///
/// Return:
/// - usize (the first byte that cannot continue the name)
pub fn nameEnd(src: []const u8, pos: usize) usize {
    var at = pos;
    while (at < src.len and isNameChar(src[at])) : (at += 1) {}

    return at;
}

/// Where a number token ends, its sign not included.
///
/// Note:
/// - Takes every byte Zig's tokenizer takes into a number: digits, letters, `_`, `.`,
///   and a `+` or `-` right after an exponent letter. So `0x1F`, `1_000`, `1.5e-3` and
///   `0x1p+4` are one token each, and a bad one such as `12ab` is still one token that
///   the number check then refuses.
///
/// Param:
/// src - []const u8 (the document)
/// pos - usize (the first digit)
///
/// Return:
/// - usize (the first byte past the token)
pub fn numberEnd(src: []const u8, pos: usize) usize {
    var at = pos;

    while (at < src.len) : (at += 1) {
        const byte = src[at];

        if (isNameChar(byte) or byte == '.') continue;

        const after_exponent = at > pos and switch (src[at - 1]) {
            'e', 'E', 'p', 'P' => true,
            else => false,
        };
        if ((byte == '+' or byte == '-') and after_exponent) continue;

        break;
    }

    return at;
}

/// Where a quoted string ends.
///
/// Param:
/// src - []const u8 (the document)
/// pos - usize (the opening `"`)
///
/// Return:
/// - usize (the first byte past the closing `"`)
/// - Error.Jzon_ZonGrammar_Truncated when the document ends inside the string
/// - Error.Jzon_ZonGrammar_Unexpected when a line break or control byte is inside
pub fn stringEnd(src: []const u8, pos: usize) Error!usize {
    var at = pos + 1;

    while (at < src.len) : (at += 1) {
        switch (src[at]) {
            '"' => return at + 1,
            '\\' => at += 1,
            '\t' => {},
            0...8, 10...31, 127 => return Error.Jzon_ZonGrammar_Unexpected,
            else => {},
        }
    }

    return Error.Jzon_ZonGrammar_Truncated;
}

/// Whether `pos` starts a multiline string line, `\\`.
///
/// Param:
/// src - []const u8 (the document)
/// pos - usize (where to look)
///
/// Return:
/// - bool (true when the two bytes at `pos` are `\\`)
pub fn isMultilineAt(src: []const u8, pos: usize) bool {
    return pos + 1 < src.len and src[pos] == '\\' and src[pos + 1] == '\\';
}

/// The text of one multiline string line, without the `\\` and the line end.
///
/// Note:
/// - A `\r` right before the `\n` is the line end, not text, so a CRLF file reads the
///   same as an LF one.
///
/// Param:
/// src - []const u8 (the document)
/// pos - usize (the `\\` that starts the line)
///
/// Return:
/// - []const u8 (the line text, pointing into `src`)
pub fn multilineText(src: []const u8, pos: usize) []const u8 {
    const end = lineEnd(src, pos);
    const text = src[pos + 2 .. end];

    if (text.len > 0 and text[text.len - 1] == '\r') return text[0 .. text.len - 1];

    return text;
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "jzon zon: grammar, isSpace takes the four whitespace bytes" {
    for (" \t\n\r") |byte| try std.testing.expect(isSpace(byte));
}

test "jzon zon: grammar, isSpace refuses other bytes" {
    for ("a.0/\x0b\x0c") |byte| try std.testing.expect(!isSpace(byte));
}

test "jzon zon: grammar, isNameStart takes letters and underscore" {
    for ("azAZ_") |byte| try std.testing.expect(isNameStart(byte));
}

test "jzon zon: grammar, isNameStart refuses a digit" {
    try std.testing.expect(!isNameStart('0'));
}

test "jzon zon: grammar, isNameChar takes a digit" {
    try std.testing.expect(isNameChar('9'));
}

test "jzon zon: grammar, skipIgnored steps over whitespace" {
    try std.testing.expectEqual(@as(usize, 4), skipIgnored(" \t\n x", 0));
}

test "jzon zon: grammar, skipIgnored steps over a comment" {
    try std.testing.expectEqual(@as(usize, 11), skipIgnored("// note\n   x", 0));
}

test "jzon zon: grammar, skipIgnored steps over a doc comment" {
    try std.testing.expectEqual(@as(usize, 9), skipIgnored("/// doc\n x", 0));
}

test "jzon zon: grammar, skipIgnored stops at a lone slash" {
    try std.testing.expectEqual(@as(usize, 1), skipIgnored(" /x", 0));
}

test "jzon zon: grammar, skipIgnored reaches the end of a comment-only tail" {
    try std.testing.expectEqual(@as(usize, 7), skipIgnored("// tail", 0));
}

test "jzon zon: grammar, skipIgnored on empty input stays at zero" {
    try std.testing.expectEqual(@as(usize, 0), skipIgnored("", 0));
}

test "jzon zon: grammar, lineEnd finds the line feed" {
    try std.testing.expectEqual(@as(usize, 3), lineEnd("abc\ndef", 0));
}

test "jzon zon: grammar, lineEnd on the last line is the length" {
    try std.testing.expectEqual(@as(usize, 7), lineEnd("abc\ndef", 4));
}

test "jzon zon: grammar, nameEnd stops at the first non-name byte" {
    try std.testing.expectEqual(@as(usize, 7), nameEnd("field_1 = 2", 0));
}

test "jzon zon: grammar, nameEnd at the end is the length" {
    try std.testing.expectEqual(@as(usize, 4), nameEnd("name", 0));
}

test "jzon zon: grammar, numberEnd takes a decimal" {
    try std.testing.expectEqual(@as(usize, 3), numberEnd("123,", 0));
}

test "jzon zon: grammar, numberEnd takes a hex with separators" {
    try std.testing.expectEqual(@as(usize, 9), numberEnd("0x64d6_1e }", 0));
}

test "jzon zon: grammar, numberEnd takes an exponent sign" {
    try std.testing.expectEqual(@as(usize, 6), numberEnd("1.5e-3,", 0));
}

test "jzon zon: grammar, numberEnd takes a hex exponent sign" {
    try std.testing.expectEqual(@as(usize, 6), numberEnd("0x1p+4}", 0));
}

test "jzon zon: grammar, numberEnd stops at a sign not after an exponent" {
    try std.testing.expectEqual(@as(usize, 1), numberEnd("1-2", 0));
}

test "jzon zon: grammar, numberEnd keeps a bad token whole" {
    try std.testing.expectEqual(@as(usize, 4), numberEnd("12ab ", 0));
}

test "jzon zon: grammar, stringEnd finds the closing quote" {
    try std.testing.expectEqual(@as(usize, 5), try stringEnd("\"abc\",", 0));
}

test "jzon zon: grammar, stringEnd steps over an escaped quote" {
    try std.testing.expectEqual(@as(usize, 6), try stringEnd("\"a\\\"b\"", 0));
}

test "jzon zon: grammar, stringEnd takes a tab" {
    try std.testing.expectEqual(@as(usize, 3), try stringEnd("\"\t\"", 0));
}

test "jzon zon: grammar, stringEnd without a closing quote is truncated" {
    try std.testing.expectError(Error.Jzon_ZonGrammar_Truncated, stringEnd("\"abc", 0));
}

test "jzon zon: grammar, stringEnd with a trailing backslash is truncated" {
    try std.testing.expectError(Error.Jzon_ZonGrammar_Truncated, stringEnd("\"a\\", 0));
}

test "jzon zon: grammar, stringEnd with a line break is unexpected" {
    try std.testing.expectError(Error.Jzon_ZonGrammar_Unexpected, stringEnd("\"a\nb\"", 0));
}

test "jzon zon: grammar, stringEnd with a control byte is unexpected" {
    try std.testing.expectError(Error.Jzon_ZonGrammar_Unexpected, stringEnd("\"a\x01\"", 0));
}

test "jzon zon: grammar, isMultilineAt takes two backslashes" {
    try std.testing.expect(isMultilineAt("\\\\text", 0));
}

test "jzon zon: grammar, isMultilineAt refuses one backslash at the end" {
    try std.testing.expect(!isMultilineAt("\\", 0));
}

test "jzon zon: grammar, multilineText drops the prefix and the line feed" {
    try std.testing.expectEqualStrings("one", multilineText("\\\\one\n", 0));
}

test "jzon zon: grammar, multilineText drops a CR before the line feed" {
    try std.testing.expectEqualStrings("one", multilineText("\\\\one\r\n", 0));
}

test "jzon zon: grammar, multilineText of an empty line is empty" {
    try std.testing.expectEqualStrings("", multilineText("\\\\\n", 0));
}

test "jzon zon: grammar, multilineText runs to the end without a line feed" {
    try std.testing.expectEqualStrings("tail", multilineText("\\\\tail", 0));
}

