//! zixer flat config scanner: key: value lines, # comments, comma lists

const std = @import("std");

/// One parsed `key: value` line. Slices point into the scanned content.
pub const Entry = struct {
    key: []const u8,
    value: []const u8,
    line_no: usize,
};

pub const BadReason = enum {
    MISSING_COLON,
    EMPTY_KEY,
    EMPTY_VALUE,
};

/// A line the scanner cannot accept, kept for the fault report.
pub const BadLine = struct {
    text: []const u8,
    line_no: usize,
    reason: BadReason,
};

pub const Line = union(enum) {
    entry: Entry,
    bad: BadLine,
};

/// Line scanner over one config file content.
///
/// Note:
/// - Zero allocation: every returned slice points into the content given to init.
/// - Blank lines and full-line # comments are skipped, trailing # comments are stripped.
/// - The value keeps any ':' after the first one, so paths like C:/certs work.
pub const Scanner = struct {
    content: []const u8,
    pos: usize = 0,
    line_no: usize = 0,

    pub fn init(content: []const u8) Scanner {
        return .{ .content = content };
    }

    /// Next meaningful line, null at end of content.
    pub fn next(scanner: *Scanner) ?Line {
        while (scanner.pos < scanner.content.len) {
            const line_end = std.mem.indexOfScalarPos(u8, scanner.content, scanner.pos, '\n') orelse scanner.content.len;
            const raw = scanner.content[scanner.pos..line_end];
            scanner.pos = @min(line_end + 1, scanner.content.len);
            scanner.line_no += 1;

            const no_comment = if (std.mem.indexOfScalar(u8, raw, '#')) |hash_pos| raw[0..hash_pos] else raw;
            const line = std.mem.trim(u8, no_comment, " \t\r");
            if (line.len == 0) continue;

            const colon_pos = std.mem.indexOfScalar(u8, line, ':') orelse
                return .{ .bad = .{ .text = line, .line_no = scanner.line_no, .reason = .MISSING_COLON } };

            const key = std.mem.trim(u8, line[0..colon_pos], " \t");
            const value = std.mem.trim(u8, line[colon_pos + 1 ..], " \t");
            if (key.len == 0) return .{ .bad = .{ .text = line, .line_no = scanner.line_no, .reason = .EMPTY_KEY } };
            if (value.len == 0) return .{ .bad = .{ .text = line, .line_no = scanner.line_no, .reason = .EMPTY_VALUE } };

            return .{ .entry = .{ .key = key, .value = value, .line_no = scanner.line_no } };
        }

        return null;
    }
};

/// Iterator over a comma-separated list value.
///
/// Note:
/// - Items come back trimmed. An empty item (`a,,b` or a trailing comma) comes
///   back as "" so the schema can fault it instead of skipping a typo.
pub const ListIterator = struct {
    value: []const u8,
    pos: usize = 0,
    finished: bool = false,

    pub fn init(value: []const u8) ListIterator {
        return .{ .value = value };
    }

    /// Next trimmed item, null after the last one.
    pub fn next(iter: *ListIterator) ?[]const u8 {
        if (iter.finished) return null;

        const comma_pos = std.mem.indexOfScalarPos(u8, iter.value, iter.pos, ',') orelse {
            const item = std.mem.trim(u8, iter.value[iter.pos..], " \t");
            iter.finished = true;

            return item;
        };

        const item = std.mem.trim(u8, iter.value[iter.pos..comma_pos], " \t");
        iter.pos = comma_pos + 1;

        return item;
    }
};

/// Parse a config boolean. Only `true` and `false` are accepted, null otherwise.
pub fn parseBool(value: []const u8) ?bool {
    if (std.mem.eql(u8, value, "true")) return true;
    if (std.mem.eql(u8, value, "false")) return false;

    return null;
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //

test "zix zixer: cfg scanner, entries with comments and blank lines" {
    const content =
        "# full-line comment\n" ++
        "workers: 4\n" ++
        "\n" ++
        "dispatch: uring   # trailing comment\n";

    var scanner = Scanner.init(content);

    const first = scanner.next().?.entry;
    try std.testing.expectEqualStrings("workers", first.key);
    try std.testing.expectEqualStrings("4", first.value);
    try std.testing.expectEqual(@as(usize, 2), first.line_no);

    const second = scanner.next().?.entry;
    try std.testing.expectEqualStrings("dispatch", second.key);
    try std.testing.expectEqualStrings("uring", second.value);
    try std.testing.expectEqual(@as(usize, 4), second.line_no);

    try std.testing.expectEqual(@as(?Line, null), scanner.next());
}

test "zix zixer: cfg scanner, value keeps colons after the first" {
    var scanner = Scanner.init("tls_cert: C:/certs/fullchain.pem\n");

    const entry = scanner.next().?.entry;
    try std.testing.expectEqualStrings("tls_cert", entry.key);
    try std.testing.expectEqualStrings("C:/certs/fullchain.pem", entry.value);
}

test "zix zixer: cfg scanner, crlf and missing final newline" {
    var scanner = Scanner.init("ip: 0.0.0.0\r\nport: 8080");

    try std.testing.expectEqualStrings("0.0.0.0", scanner.next().?.entry.value);
    try std.testing.expectEqualStrings("8080", scanner.next().?.entry.value);
    try std.testing.expectEqual(@as(?Line, null), scanner.next());
}

test "zix zixer: cfg scanner, malformed lines come back as bad" {
    var scanner = Scanner.init("no separator here\n: value only\nkey only:\n");

    const missing_colon = scanner.next().?.bad;
    try std.testing.expectEqual(BadReason.MISSING_COLON, missing_colon.reason);
    try std.testing.expectEqualStrings("no separator here", missing_colon.text);

    const empty_key = scanner.next().?.bad;
    try std.testing.expectEqual(BadReason.EMPTY_KEY, empty_key.reason);

    const empty_value = scanner.next().?.bad;
    try std.testing.expectEqual(BadReason.EMPTY_VALUE, empty_value.reason);
    try std.testing.expectEqual(@as(usize, 3), empty_value.line_no);
}

test "zix zixer: cfg scanner, comment-only value is an empty value" {
    var scanner = Scanner.init("port: # forgot the number\n");

    try std.testing.expectEqual(BadReason.EMPTY_VALUE, scanner.next().?.bad.reason);
}

test "zix zixer: cfg scanner, list iterator splits and trims" {
    var iter = ListIterator.init("127.0.0.1:3000, 127.0.0.1:3001 ,127.0.0.1:3002");

    try std.testing.expectEqualStrings("127.0.0.1:3000", iter.next().?);
    try std.testing.expectEqualStrings("127.0.0.1:3001", iter.next().?);
    try std.testing.expectEqualStrings("127.0.0.1:3002", iter.next().?);
    try std.testing.expectEqual(@as(?[]const u8, null), iter.next());
}

test "zix zixer: cfg scanner, list iterator surfaces empty items" {
    var doubled = ListIterator.init("a,,b");
    try std.testing.expectEqualStrings("a", doubled.next().?);
    try std.testing.expectEqualStrings("", doubled.next().?);
    try std.testing.expectEqualStrings("b", doubled.next().?);

    var trailing = ListIterator.init("a,");
    try std.testing.expectEqualStrings("a", trailing.next().?);
    try std.testing.expectEqualStrings("", trailing.next().?);
    try std.testing.expectEqual(@as(?[]const u8, null), trailing.next());
}

test "zix zixer: cfg scanner, bool accepts only true and false" {
    try std.testing.expectEqual(@as(?bool, true), parseBool("true"));
    try std.testing.expectEqual(@as(?bool, false), parseBool("false"));
    try std.testing.expectEqual(@as(?bool, null), parseBool("True"));
    try std.testing.expectEqual(@as(?bool, null), parseBool("1"));
    try std.testing.expectEqual(@as(?bool, null), parseBool("yes"));
}
