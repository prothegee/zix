//! JZON escape
//!
//! ### file: src/jzon/src/escape.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! JSON string escape rules (RFC8259 section 7), used in both directions: which bytes
//! a string may not carry raw, and how each one is spelled.
//!
//! ### note:
//!
//! Encoding matches `std.json.Stringify` at its default options byte for byte. Decoding
//! reads every escape form `std.json` reads, and refuses an unpaired surrogate half the
//! same way.
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
const Sink = @import("Sink.zig");

// --------------------------------------------------------- //
// Private:

const HEX_DIGITS = "0123456789abcdef";

/// One escaped form, held as a fixed array so the table below needs no pointers.
const Escaped = struct {
    text: [6]u8,
    len: u8,
};

/// The escaped form of every control byte. Five have a two-character spelling, the
/// rest go out as `\u00xx` with lowercase hex, which is what std emits.
const CONTROL: [0x20]Escaped = build: {
    var table: [0x20]Escaped = undefined;

    for (&table, 0..) |*entry, index| {
        const short: ?[]const u8 = switch (index) {
            0x08 => "\\b",
            0x09 => "\\t",
            0x0a => "\\n",
            0x0c => "\\f",
            0x0d => "\\r",
            else => null,
        };

        if (short) |form| {
            entry.* = .{
                .text = .{ form[0], form[1], 0, 0, 0, 0 },
                .len = 2,
            };
            continue;
        }

        entry.* = .{
            .text = .{ '\\', 'u', '0', '0', HEX_DIGITS[index >> 4], HEX_DIGITS[index & 0x0f] },
            .len = 6,
        };
    }

    break :build table;
};

/// Every failure a private function here can hand back: this module's own set joined
/// with the sink's.
const Inner = Error || Sink.Error;

/// Translate a failure from inside the module into this module's public set.
///
/// Param:
/// err - Inner (the failure a private function handed back)
///
/// Return:
/// - Error (the same failure under this module's name)
inline fn innerError(err: Inner) Error {
    @branchHint(.cold);

    return switch (err) {
        error.Jzon_Escape_NoSpaceLeft => Error.Jzon_Escape_NoSpaceLeft,
        error.Jzon_Escape_BadEscape => Error.Jzon_Escape_BadEscape,
        error.Jzon_Sink_NoSpaceLeft => Error.Jzon_Escape_NoSpaceLeft,
    };
}

/// Decode a `\u` escape whose four hex digits start at `index`, joining a surrogate
/// pair when the first half is a high surrogate.
///
/// Param:
/// sink - *Sink (where the decoded bytes go)
/// raw - []const u8 (the undecoded string body)
/// index - usize (where the four hex digits start)
///
/// Return:
/// - usize (the position just past the escape that was decoded)
/// - Error.Jzon_Sink_NoSpaceLeft when the encoded code point does not fit
/// - Error.Jzon_Escape_BadEscape on a short escape, a bad hex digit, or an unpaired half
fn decodeUnicode(sink: *Sink, raw: []const u8, index: usize) Inner!usize {
    const first = try hexQuad(raw, index);
    const after_first = index + 4;

    if (first < 0xd800 or first > 0xdfff) {
        try writeUtf8(sink, first);

        return after_first;
    }

    if (first > 0xdbff) return Error.Jzon_Escape_BadEscape;
    if (after_first + 6 > raw.len) return Error.Jzon_Escape_BadEscape;
    if (raw[after_first] != '\\' or raw[after_first + 1] != 'u') {
        return Error.Jzon_Escape_BadEscape;
    }

    const second = try hexQuad(raw, after_first + 2);
    if (second < 0xdc00 or second > 0xdfff) return Error.Jzon_Escape_BadEscape;

    const codepoint: u21 = 0x10000 +
        ((@as(u21, first) - 0xd800) << 10) +
        (@as(u21, second) - 0xdc00);
    try writeUtf8(sink, codepoint);

    return after_first + 6;
}

/// Read the four hex digits of a `\u` escape.
///
/// Param:
/// raw - []const u8 (the undecoded string body)
/// index - usize (where the four hex digits start)
///
/// Return:
/// - u16 (the value the digits spell)
/// - Error.Jzon_Escape_BadEscape when fewer than four digits are left or one is not hex
fn hexQuad(raw: []const u8, index: usize) Error!u16 {
    if (index + 4 > raw.len) return Error.Jzon_Escape_BadEscape;

    var value: u16 = 0;
    for (raw[index..][0..4]) |byte| {
        const digit: u16 = switch (byte) {
            '0'...'9' => byte - '0',
            'a'...'f' => byte - 'a' + 10,
            'A'...'F' => byte - 'A' + 10,
            else => return Error.Jzon_Escape_BadEscape,
        };

        value = value * 16 + digit;
    }

    return value;
}

/// Write one code point as UTF-8.
///
/// Param:
/// sink - *Sink (where the encoded bytes go)
/// codepoint - u21 (the code point to encode)
///
/// Return:
/// - void
/// - Error.Jzon_Sink_NoSpaceLeft when the encoded bytes do not fit
/// - Error.Jzon_Escape_BadEscape when the code point has no UTF-8 form
fn writeUtf8(sink: *Sink, codepoint: u21) Inner!void {
    var encoded: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(codepoint, &encoded) catch |err| switch (err) {
        else => return Error.Jzon_Escape_BadEscape,
    };

    try sink.bytes(encoded[0..len]);
}

/// The body of `spell`, failing with the inner set.
fn spellInto(sink: *Sink, byte: u8) Inner!void {
    switch (byte) {
        '"' => try sink.literal("\\\""),
        '\\' => try sink.literal("\\\\"),
        0x00...0x1f => {
            const entry = CONTROL[byte];
            try sink.bytes(entry.text[0..entry.len]);
        },
        else => try sink.byte(byte),
    }
}

/// The body of `encodeBody`, failing with the inner set.
fn bodyInto(sink: *Sink, text: []const u8) Inner!void {
    var clean_from: usize = 0;
    var index: usize = 0;

    while (index < text.len) : (index += 1) {
        const byte = text[index];
        if (!isEscaped(byte)) continue;

        try sink.bytes(text[clean_from..index]);
        try spellInto(sink, byte);

        clean_from = index + 1;
    }

    try sink.bytes(text[clean_from..]);
}

/// The body of `encode`, failing with the inner set.
fn quoted(sink: *Sink, text: []const u8) Inner!void {
    try sink.byte('"');
    try bodyInto(sink, text);
    try sink.byte('"');
}

/// The body of `decode`, failing with the inner set.
fn decodeInto(sink: *Sink, raw: []const u8) Inner!void {
    var index: usize = 0;

    while (index < raw.len) {
        if (raw[index] != '\\') {
            const start = index;
            while (index < raw.len and raw[index] != '\\') : (index += 1) {}

            try sink.bytes(raw[start..index]);
            continue;
        }

        index += 1;
        if (index == raw.len) return Error.Jzon_Escape_BadEscape;

        const spelling = raw[index];
        index += 1;

        const decoded: u8 = switch (spelling) {
            '"' => '"',
            '\\' => '\\',
            '/' => '/',
            'b' => 0x08,
            'f' => 0x0c,
            'n' => '\n',
            'r' => '\r',
            't' => '\t',
            'u' => {
                index = try decodeUnicode(sink, raw, index);
                continue;
            },
            else => return Error.Jzon_Escape_BadEscape,
        };

        try sink.byte(decoded);
    }
}

// --------------------------------------------------------- //
// Public:

/// How escaping can fail: no room for the bytes, or an escape the rules do not spell.
///
/// Note:
/// - Encoding never reports BadEscape. Only `decode` does.
pub const Error = error{
    Jzon_Escape_NoSpaceLeft,
    Jzon_Escape_BadEscape,
};

/// Whether one byte cannot go out raw.
///
/// Note:
/// - This is the whole rule. A scan that classifies bytes another way (a vector lane
///   at a time, see `lane.firstEscaped`) still spells each hit through `spell`, so
///   the two never drift apart.
///
/// Param:
/// byte - u8 (the byte to classify)
///
/// Return:
/// - bool (true when the byte has to be escaped)
pub inline fn isEscaped(byte: u8) bool {
    return byte == '"' or byte == '\\' or byte < 0x20;
}

/// Whether `text` holds a byte that cannot go out raw.
///
/// Note:
/// - A parser uses this to decide it may hand back a slice of the source instead of
///   copying, and an emitter to skip the escape scan for a clean run.
///
/// Param:
/// text - []const u8 (the bytes to check)
///
/// Return:
/// - bool (true when at least one byte needs escaping)
pub fn needsEscape(text: []const u8) bool {
    for (text) |byte| {
        if (isEscaped(byte)) return true;
    }

    return false;
}

/// Write one byte's escaped spelling.
///
/// Note:
/// - Meant for a byte `isEscaped` accepts. Any other byte is written as itself, which
///   is what it would have been anyway, so a caller that classifies wrongly still
///   emits correct text.
///
/// Param:
/// sink - *Sink (where the spelling goes)
/// byte - u8 (the byte to spell)
///
/// Return:
/// - void
/// - Error.Jzon_Escape_NoSpaceLeft when the spelling does not fit
pub fn spell(sink: *Sink, byte: u8) Error!void {
    return spellInto(sink, byte) catch |err| innerError(err);
}

/// Write `text` as a complete JSON string, quotes included.
///
/// Param:
/// sink - *Sink (where the string goes)
/// text - []const u8 (the bytes to escape and write)
///
/// Return:
/// - void
/// - Error.Jzon_Escape_NoSpaceLeft when the escaped form does not fit
pub fn encode(sink: *Sink, text: []const u8) Error!void {
    return quoted(sink, text) catch |err| innerError(err);
}

/// Write `text` escaped, without the surrounding quotes.
///
/// Note:
/// - Clean runs are copied whole, so a string with no escape costs one copy.
/// - Bytes at 0x7f and above go out unchanged, which is what std does with its
///   default options. A UTF-8 input stays UTF-8, nothing is escaped to ASCII.
///
/// Param:
/// sink - *Sink (where the bytes go)
/// text - []const u8 (the bytes to escape and write)
///
/// Return:
/// - void
/// - Error.Jzon_Escape_NoSpaceLeft when the escaped form does not fit
pub fn encodeBody(sink: *Sink, text: []const u8) Error!void {
    return bodyInto(sink, text) catch |err| innerError(err);
}

/// Write the decoded value of an escaped string body.
///
/// Note:
/// - `raw` is a string token's bytes without its quotes, the shape
///   `Cursor.stringSpan` hands back.
/// - A `\u` escape becomes UTF-8. A high surrogate must be followed immediately by a
///   low one in `\u` notation, the rule std.json holds to, so an unpaired half is
///   BadEscape rather than a replacement character.
///
/// Param:
/// sink - *Sink (where the decoded bytes go)
/// raw - []const u8 (the undecoded string body)
///
/// Return:
/// - void
/// - Error.Jzon_Escape_NoSpaceLeft when the decoded form does not fit
/// - Error.Jzon_Escape_BadEscape on an escape the rules do not spell
pub fn decode(sink: *Sink, raw: []const u8) Error!void {
    return decodeInto(sink, raw) catch |err| innerError(err);
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

/// Render the same string through std.json.Stringify, for the tests that assert the
/// two agree byte for byte.
fn stdEncoded(buf: []u8, text: []const u8) std.json.Stringify.Error![]const u8 {
    var writer = std.Io.Writer.fixed(buf);
    try std.json.Stringify.value(text, .{}, &writer);

    return writer.buffered();
}

test "jzon: escape, leaves a clean string alone" {
    var buf: [32]u8 = undefined;
    var sink: Sink = .init(&buf);

    try encode(&sink, "hello world");

    try std.testing.expectEqualStrings("\"hello world\"", sink.filled());
}

test "jzon: escape, spells the quote, the backslash, and the named controls" {
    var buf: [64]u8 = undefined;
    var sink: Sink = .init(&buf);

    try encode(&sink, "a\"b\\c\nd\te\rf\x08g\x0ch");

    try std.testing.expectEqualStrings(
        "\"a\\\"b\\\\c\\nd\\te\\rf\\bg\\fh\"",
        sink.filled(),
    );
}

test "jzon: escape, spells an unnamed control byte as lowercase hex" {
    var buf: [32]u8 = undefined;
    var sink: Sink = .init(&buf);

    try encode(&sink, "\x00\x0b\x1f");

    try std.testing.expectEqualStrings("\"\\u0000\\u000b\\u001f\"", sink.filled());
}

test "jzon: escape, agrees with std.json.Stringify byte for byte" {
    const samples = [_][]const u8{
        "",
        "plain",
        "quote \" and backslash \\",
        "control \x00\x01\x0b\x1f end",
        "named \n\r\t\x08\x0c end",
        "utf8 \xc3\xa9 \xe2\x82\xac \xf0\x9f\x92\xa9",
        "delete \x7f byte",
    };

    for (samples) |sample| {
        var ours: [256]u8 = undefined;
        var sink: Sink = .init(&ours);
        try encode(&sink, sample);

        var theirs: [256]u8 = undefined;
        try std.testing.expectEqualStrings(try stdEncoded(&theirs, sample), sink.filled());
    }
}

test "jzon: escape, needsEscape sees exactly what encode would spell" {
    try std.testing.expect(!needsEscape("plain text"));
    try std.testing.expect(!needsEscape("\x7f\xff"));
    try std.testing.expect(needsEscape("with \" quote"));
    try std.testing.expect(needsEscape("with \\ backslash"));
    try std.testing.expect(needsEscape("with \n newline"));
}

test "jzon: escape, isEscaped answers for the byte set encode rewrites" {
    try std.testing.expect(isEscaped('"'));
    try std.testing.expect(isEscaped('\\'));
    try std.testing.expect(isEscaped(0x00));
    try std.testing.expect(isEscaped(0x1f));
    try std.testing.expect(!isEscaped(0x20));
    try std.testing.expect(!isEscaped('a'));
    try std.testing.expect(!isEscaped(0x7f));
    try std.testing.expect(!isEscaped(0xff));
}

test "jzon: escape, spell writes what encodeBody writes for the same byte" {
    for (0..256) |value| {
        const byte: u8 = @intCast(value);

        var one: [8]u8 = undefined;
        var spelled: Sink = .init(&one);
        try spell(&spelled, byte);

        var whole: [8]u8 = undefined;
        var encoded: Sink = .init(&whole);
        try encodeBody(&encoded, &[_]u8{byte});

        try std.testing.expectEqualStrings(encoded.filled(), spelled.filled());
    }
}

test "jzon: escape, decode reverses every spelling encode produces" {
    const samples = [_][]const u8{
        "",
        "plain",
        "quote \" and backslash \\",
        "control \x00\x01\x0b\x1f end",
        "named \n\r\t\x08\x0c end",
        "utf8 \xc3\xa9 \xe2\x82\xac \xf0\x9f\x92\xa9",
    };

    for (samples) |sample| {
        var encoded: [256]u8 = undefined;
        var writer: Sink = .init(&encoded);
        try encodeBody(&writer, sample);

        var decoded: [256]u8 = undefined;
        var reader: Sink = .init(&decoded);
        try decode(&reader, writer.filled());

        try std.testing.expectEqualStrings(sample, reader.filled());
    }
}

test "jzon: escape, decode accepts the escaped solidus encode never emits" {
    var buf: [16]u8 = undefined;
    var sink: Sink = .init(&buf);

    try decode(&sink, "a\\/b");

    try std.testing.expectEqualStrings("a/b", sink.filled());
}

test "jzon: escape, decode joins a surrogate pair into one code point" {
    var buf: [16]u8 = undefined;
    var sink: Sink = .init(&buf);

    try decode(&sink, "\\ud83d\\udca9");

    try std.testing.expectEqualStrings("\xf0\x9f\x92\xa9", sink.filled());
}

test "jzon: escape, decode rejects an unpaired surrogate half" {
    var buf: [16]u8 = undefined;

    var lone_high: Sink = .init(&buf);
    try std.testing.expectError(Error.Jzon_Escape_BadEscape, decode(&lone_high, "\\ud83d"));

    var lone_low: Sink = .init(&buf);
    try std.testing.expectError(Error.Jzon_Escape_BadEscape, decode(&lone_low, "\\udca9"));

    var high_then_plain: Sink = .init(&buf);
    try std.testing.expectError(
        Error.Jzon_Escape_BadEscape,
        decode(&high_then_plain, "\\ud83d\\u0041"),
    );
}

test "jzon: escape, encodes every control byte the way std does" {
    for (0..0x20) |code| {
        const sample = [_]u8{@intCast(code)};

        var ours: [16]u8 = undefined;
        var sink: Sink = .init(&ours);
        try encode(&sink, &sample);

        var theirs: [16]u8 = undefined;
        try std.testing.expectEqualStrings(try stdEncoded(&theirs, &sample), sink.filled());
    }
}

test "jzon: escape, leaves every byte from 0x20 raw except quote and backslash" {
    for (0x20..0x100) |code| {
        const byte: u8 = @intCast(code);
        if (byte == '"' or byte == '\\') continue;

        const sample = [_]u8{byte};

        var buf: [16]u8 = undefined;
        var sink: Sink = .init(&buf);
        try encodeBody(&sink, &sample);

        try std.testing.expectEqualStrings(&sample, sink.filled());
    }
}

test "jzon: escape, encode on an empty string writes only the quotes" {
    var buf: [8]u8 = undefined;
    var sink: Sink = .init(&buf);

    try encode(&sink, "");

    try std.testing.expectEqualStrings("\"\"", sink.filled());
}

test "jzon: escape, encode fills an exact-fit buffer" {
    var buf: [9]u8 = undefined;
    var sink: Sink = .init(&buf);

    try encode(&sink, "a\nbcde");

    try std.testing.expectEqualStrings("\"a\\nbcde\"", sink.filled());
    try std.testing.expectEqual(@as(usize, 0), sink.remaining());
}

test "jzon: escape, encode one byte short is no space left" {
    var buf: [8]u8 = undefined;
    var sink: Sink = .init(&buf);

    try std.testing.expectError(Error.Jzon_Escape_NoSpaceLeft, encode(&sink, "a\nbcde"));
}

test "jzon: escape, spell into a full buffer is no space left" {
    var buf: [1]u8 = undefined;
    var sink: Sink = .init(&buf);

    try std.testing.expectError(Error.Jzon_Escape_NoSpaceLeft, spell(&sink, '"'));
    try std.testing.expectEqual(@as(usize, 0), sink.written());
}

test "jzon: escape, decode of an incomplete or unknown escape is a bad escape" {
    var buf: [16]u8 = undefined;

    var lone_backslash: Sink = .init(&buf);
    try std.testing.expectError(Error.Jzon_Escape_BadEscape, decode(&lone_backslash, "ab\\"));

    var unknown_spelling: Sink = .init(&buf);
    try std.testing.expectError(Error.Jzon_Escape_BadEscape, decode(&unknown_spelling, "a\\qb"));

    var short_unicode: Sink = .init(&buf);
    try std.testing.expectError(Error.Jzon_Escape_BadEscape, decode(&short_unicode, "\\u12"));

    var bad_hex: Sink = .init(&buf);
    try std.testing.expectError(Error.Jzon_Escape_BadEscape, decode(&bad_hex, "\\u12g4"));
}

test "jzon: escape, decode reads hex digits in either case" {
    var lower_buf: [8]u8 = undefined;
    var lower: Sink = .init(&lower_buf);
    try decode(&lower, "\\u00e9");

    var upper_buf: [8]u8 = undefined;
    var upper: Sink = .init(&upper_buf);
    try decode(&upper, "\\u00E9");

    try std.testing.expectEqualStrings("\xc3\xa9", lower.filled());
    try std.testing.expectEqualStrings(lower.filled(), upper.filled());
}

test "jzon: escape, decode refuses every unpaired surrogate half" {
    const samples = [_][]const u8{
        "\\ud800",
        "\\udc00",
        "\\ud800abc",
        "\\ud800\\ud800",
        "\\ud800\\u0041",
    };

    for (samples) |sample| {
        var buf: [16]u8 = undefined;
        var sink: Sink = .init(&buf);

        try std.testing.expectError(Error.Jzon_Escape_BadEscape, decode(&sink, sample));
    }
}

test "jzon: escape, decode carries the surrogate range boundaries" {
    var lowest_buf: [8]u8 = undefined;
    var lowest: Sink = .init(&lowest_buf);
    try decode(&lowest, "\\ud800\\udc00");

    var highest_buf: [8]u8 = undefined;
    var highest: Sink = .init(&highest_buf);
    try decode(&highest, "\\udbff\\udfff");

    try std.testing.expectEqualStrings("\xf0\x90\x80\x80", lowest.filled());
    try std.testing.expectEqualStrings("\xf4\x8f\xbf\xbf", highest.filled());
}

test "jzon: escape, decode of \\u0000 yields the nul byte" {
    var buf: [8]u8 = undefined;
    var sink: Sink = .init(&buf);

    try decode(&sink, "a\\u0000b");

    try std.testing.expectEqualStrings("a\x00b", sink.filled());
}

test "jzon: escape, decode refuses to overrun the buffer" {
    var tight: [3]u8 = undefined;
    var sink: Sink = .init(&tight);

    try std.testing.expectError(Error.Jzon_Escape_NoSpaceLeft, decode(&sink, "abcd"));

    var one_short: [3]u8 = undefined;
    var unicode: Sink = .init(&one_short);
    try std.testing.expectError(
        Error.Jzon_Escape_NoSpaceLeft,
        decode(&unicode, "\\ud83d\\udca9"),
    );
}

test "jzon: escape, needsEscape on an empty string is false" {
    try std.testing.expect(!needsEscape(""));
}

test "jzon: escape, innerError keeps its own no space left" {
    const err = innerError(error.Jzon_Escape_NoSpaceLeft);

    try std.testing.expectEqual(Error.Jzon_Escape_NoSpaceLeft, err);
}

test "jzon: escape, innerError keeps its own bad escape" {
    const err = innerError(error.Jzon_Escape_BadEscape);

    try std.testing.expectEqual(Error.Jzon_Escape_BadEscape, err);
}

test "jzon: escape, innerError renames sink no space left to its own name" {
    const err = innerError(error.Jzon_Sink_NoSpaceLeft);

    try std.testing.expectEqual(Error.Jzon_Escape_NoSpaceLeft, err);
}

