//! ZIX utils Multipart
//!
//! ### file: src/zix/utils/Multipart.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Parser that splits a multipart/form-data body into named fields.
//!
//! ### note:
//!
//! Every field slice borrows the parsed body. Nothing is copied, so the body
//! must outlive the parser and every field read from it.
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
const Field = @import("MultipartField.zig");

// --------------------------------------------------------- //
// Fields:

boundary: []const u8,
fields: std.ArrayList(Field),
allocator: std.mem.Allocator,

const Self = @This();

// --------------------------------------------------------- //
// Private:

/// Position of the next real boundary delimiter at or after `from`.
///
/// Note:
/// - The boundary text counts as a delimiter only when CRLF (another part
///   follows) or two dashes (the body ends) come after it. A file that happens
///   to contain the boundary is not split in two.
/// - Scanning resumes from the last position instead of restarting, which
///   keeps a body with many parts linear.
///
/// Param:
/// body - []const u8 (full request body)
/// from - usize (byte offset to start scanning at)
/// delimiter - []const u8 (the boundary with its two leading dashes)
///
/// Return:
/// - usize (offset of the first dash of the delimiter)
/// - null when no delimiter follows `from`
fn findDelimiter(body: []const u8, from: usize, delimiter: []const u8) ?usize {
    var scan_pos = from;

    while (std.mem.indexOfPos(u8, body, scan_pos, delimiter)) |found| {
        const after_pos = found + delimiter.len;

        if (after_pos + 1 < body.len) {
            if (body[after_pos] == '-' and body[after_pos + 1] == '-') return found;
            if (body[after_pos] == '\r' and body[after_pos + 1] == '\n') return found;
        }

        scan_pos = found + 1;
    }

    return null;
}

/// Whether a match starting at `start_pos` begins a new Content-Disposition
/// parameter rather than ending a longer one. Walks back over spacing to the
/// separator in front of it.
///
/// Param:
/// disposition - []const u8 (the Content-Disposition value)
/// start_pos - usize (offset the match starts at)
///
/// Return:
/// - bool (true when only spacing and a parameter separator come before it)
fn startsParam(disposition: []const u8, start_pos: usize) bool {
    var back_pos = start_pos;

    while (back_pos > 0) {
        back_pos -= 1;

        switch (disposition[back_pos]) {
            ' ', '\t' => continue,
            ';' => return true,
            else => return false,
        }
    }

    return true;
}

/// Value of a quoted Content-Disposition parameter, so `name="upload"` yields
/// `upload`.
///
/// Note:
/// - The key must sit at a parameter boundary. That keeps a lookup of `name`
///   from finding the one spelled inside `filename`. Clients may write the two
///   in either order.
///
/// Param:
/// disposition - []const u8 (the Content-Disposition value, after the colon)
/// key - []const u8 (parameter name, e.g. "name" or "filename")
///
/// Return:
/// - []const u8 (the value between the quotes)
/// - null when the parameter is absent or its closing quote never arrives
fn dispositionParam(disposition: []const u8, key: []const u8) ?[]const u8 {
    var scan_pos: usize = 0;

    while (std.mem.indexOfPos(u8, disposition, scan_pos, key)) |found| {
        const after_pos = found + key.len;
        scan_pos = after_pos;

        if (!startsParam(disposition, found)) continue;
        if (after_pos + 1 >= disposition.len) continue;
        if (disposition[after_pos] != '=' or disposition[after_pos + 1] != '"') continue;

        const value_start = after_pos + 2;
        const value_end =
            std.mem.indexOfScalarPos(u8, disposition, value_start, '"') orelse return null;

        return disposition[value_start..value_end];
    }

    return null;
}

/// Pull one part's headers and content out of the bytes between two
/// delimiters, and append it as a field.
///
/// Note:
/// - A part with no name in its Content-Disposition is skipped, since nothing
///   could look it up afterwards.
///
/// Param:
/// self - *Self
/// raw - []const u8 (bytes after one delimiter's CRLF up to the next delimiter)
///
/// Return:
/// - void
/// - Error.ZixUtils_Multipart_OutOfMemory when the field list cannot grow
fn appendPart(self: *Self, raw: []const u8) Error!void {
    const header_end = std.mem.indexOf(u8, raw, "\r\n\r\n") orelse return;

    const headers = raw[0..header_end];
    var content = raw[header_end + 4 ..];

    // The CRLF in front of the next delimiter is framing, not content. Exactly
    // those two bytes come off, so a file ending in CR or LF keeps them.
    if (std.mem.endsWith(u8, content, "\r\n")) content = content[0 .. content.len - 2];

    var field_name: ?[]const u8 = null;
    var field_filename: ?[]const u8 = null;
    var field_content_type: ?[]const u8 = null;

    var header_iter = std.mem.splitScalar(u8, headers, '\n');
    while (header_iter.next()) |line| {
        const trimmed = std.mem.trim(u8, line, "\r\n ");

        if (std.mem.startsWith(u8, trimmed, "Content-Disposition:")) {
            const disposition = trimmed["Content-Disposition:".len..];
            field_name = dispositionParam(disposition, "name");
            field_filename = dispositionParam(disposition, "filename");
        } else if (std.mem.startsWith(u8, trimmed, "Content-Type:")) {
            field_content_type = std.mem.trim(u8, trimmed["Content-Type:".len..], " \r\n");
        }
    }

    const name = field_name orelse return;

    self.fields.append(self.allocator, .{
        .name = name,
        .filename = field_filename,
        .content_type = field_content_type,
        .data = content,
        .is_file = field_filename != null,
    }) catch |err| switch (err) {
        error.OutOfMemory => return Error.ZixUtils_Multipart_OutOfMemory,
    };
}

// --------------------------------------------------------- //
// Public:

pub const Error = error {
    /// No opening boundary anywhere in the body. An empty body lands here,
    /// which tells "the upload never arrived" apart from "no fields".
    ZixUtils_Multipart_NoBoundary,
    /// Parts were found but the closing boundary never was, so the body is
    /// cut short.
    ZixUtils_Multipart_Unterminated,
    /// The delimiter or the field list could not be allocated.
    ZixUtils_Multipart_OutOfMemory,
};

/// Create a parser for one boundary.
///
/// Param:
/// allocator - std.mem.Allocator (backs the field list)
/// boundary - []const u8 (boundary value from the Content-Type header)
///
/// Return:
/// - Self
pub fn init(allocator: std.mem.Allocator, boundary: []const u8) Self {
    return .{
        .boundary = boundary,
        .fields = .empty,
        .allocator = allocator,
    };
}

/// Free the field list.
///
/// Note:
/// - Every slice in a Field borrows the parsed body, so the list is all there
///   is to free.
///
/// Param:
/// self - *Self
///
/// Return:
/// - void
pub fn deinit(self: *Self) void {
    self.fields.deinit(self.allocator);
}

/// Parse a whole multipart body into fields.
///
/// Note:
/// - The body must be whole. A short one is refused rather than parsed part
///   way, so a handler never stores a cut upload as complete.
/// - One forward pass over the body, so cost stays linear in its size.
/// - Every field slice borrows the body.
///
/// Param:
/// self - *Self
/// body - []const u8 (full request body)
///
/// Return:
/// - void
/// - Error.ZixUtils_Multipart_NoBoundary when the opening boundary is absent
/// - Error.ZixUtils_Multipart_Unterminated when the closing boundary is absent
/// - Error.ZixUtils_Multipart_OutOfMemory when an allocation fails
pub fn parse(self: *Self, body: []const u8) Error!void {
    const delimiter = self.allocator.alloc(u8, self.boundary.len + 2) catch |err| switch (err) {
        error.OutOfMemory => return Error.ZixUtils_Multipart_OutOfMemory,
    };
    defer self.allocator.free(delimiter);

    delimiter[0] = '-';
    delimiter[1] = '-';
    @memcpy(delimiter[2..][0..self.boundary.len], self.boundary);

    var cursor =
        findDelimiter(body, 0, delimiter) orelse return Error.ZixUtils_Multipart_NoBoundary;

    while (true) {
        const after_pos = cursor + delimiter.len;

        // findDelimiter already proved these two bytes are two dashes or CRLF,
        // so one dash is enough to tell the closing delimiter apart.
        if (body[after_pos] == '-') return;

        const part_start = after_pos + 2;
        const next_pos =
            findDelimiter(body, part_start, delimiter) orelse
            return Error.ZixUtils_Multipart_Unterminated;

        try self.appendPart(body[part_start..next_pos]);

        cursor = next_pos;
    }
}

/// Look up a parsed field by name.
///
/// Param:
/// self - *Self
/// name - []const u8 (field name from Content-Disposition)
///
/// Return:
/// - *Field (the first field with that name)
/// - null when no field with that name was parsed
pub fn getField(self: *Self, name: []const u8) ?*Field {
    for (self.fields.items) |*field| {
        if (std.mem.eql(u8, field.name, name)) return field;
    }

    return null;
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "zix utils: Multipart, parses a form field" {
    const body =
        "--boundary123\r\n" ++
        "Content-Disposition: form-data; name=\"field1\"\r\n" ++
        "\r\n" ++
        "value1\r\n" ++
        "--boundary123--\r\n";

    var parser = init(std.testing.allocator, "boundary123");
    defer parser.deinit();

    try parser.parse(body);

    const field = parser.getField("field1").?;
    try std.testing.expectEqualStrings("value1", field.data);
    try std.testing.expect(!field.is_file);
}

test "zix utils: Multipart, parses a file field" {
    const body =
        "--boundary123\r\n" ++
        "Content-Disposition: form-data; name=\"file1\"; filename=\"test.txt\"\r\n" ++
        "Content-Type: text/plain\r\n" ++
        "\r\n" ++
        "hello world\r\n" ++
        "--boundary123--\r\n";

    var parser = init(std.testing.allocator, "boundary123");
    defer parser.deinit();

    try parser.parse(body);

    const field = parser.getField("file1").?;
    try std.testing.expectEqualStrings("test.txt", field.filename.?);
    try std.testing.expectEqualStrings("text/plain", field.content_type.?);
    try std.testing.expectEqualStrings("hello world", field.data);
    try std.testing.expect(field.is_file);
}

test "zix utils: Multipart, getField returns null for an unknown name" {
    const body =
        "--b\r\n" ++
        "Content-Disposition: form-data; name=\"one\"\r\n" ++
        "\r\n" ++
        "1\r\n" ++
        "--b--\r\n";

    var parser = init(std.testing.allocator, "b");
    defer parser.deinit();

    try parser.parse(body);

    try std.testing.expect(parser.getField("two") == null);
}

test "zix utils: Multipart, keeps file bytes that are CR or LF" {
    // Only the two framing bytes in front of the next delimiter belong to the
    // protocol. The other line terminators are file data.
    const payload = "\r\nPAYLOAD\n\n";
    const body =
        "--bin\r\n" ++
        "Content-Disposition: form-data; name=\"f\"; filename=\"a.bin\"\r\n" ++
        "\r\n" ++
        payload ++ "\r\n" ++
        "--bin--\r\n";

    var parser = init(std.testing.allocator, "bin");
    defer parser.deinit();

    try parser.parse(body);

    try std.testing.expectEqualStrings(payload, parser.getField("f").?.data);
}

test "zix utils: Multipart, accepts a closing boundary without CRLF" {
    const body =
        "--b\r\n" ++
        "Content-Disposition: form-data; name=\"one\"\r\n" ++
        "\r\n" ++
        "1\r\n" ++
        "--b\r\n" ++
        "Content-Disposition: form-data; name=\"two\"\r\n" ++
        "\r\n" ++
        "2\r\n" ++
        "--b--";

    var parser = init(std.testing.allocator, "b");
    defer parser.deinit();

    try parser.parse(body);

    try std.testing.expectEqual(@as(usize, 2), parser.fields.items.len);
    try std.testing.expectEqualStrings("2", parser.getField("two").?.data);
}

test "zix utils: Multipart, empty body is a missing boundary" {
    var parser = init(std.testing.allocator, "b");
    defer parser.deinit();

    try std.testing.expectError(Error.ZixUtils_Multipart_NoBoundary, parser.parse(""));
    try std.testing.expectEqual(@as(usize, 0), parser.fields.items.len);
}

test "zix utils: Multipart, body without the boundary is a missing boundary" {
    const body =
        "--other\r\n" ++
        "Content-Disposition: form-data; name=\"one\"\r\n" ++
        "\r\n" ++
        "1\r\n" ++
        "--other--\r\n";

    var parser = init(std.testing.allocator, "b");
    defer parser.deinit();

    try std.testing.expectError(Error.ZixUtils_Multipart_NoBoundary, parser.parse(body));
}

test "zix utils: Multipart, cut body is unterminated" {
    const body =
        "--b\r\n" ++
        "Content-Disposition: form-data; name=\"f\"; filename=\"a.bin\"\r\n" ++
        "\r\n" ++
        "half of the fi";

    var parser = init(std.testing.allocator, "b");
    defer parser.deinit();

    try std.testing.expectError(Error.ZixUtils_Multipart_Unterminated, parser.parse(body));
}

test "zix utils: Multipart, keeps content that spells the boundary" {
    // The boundary inside a file is not a delimiter unless CRLF or the
    // closing dashes follow it.
    const payload = "before--zixB!after";
    const body =
        "--zixB\r\n" ++
        "Content-Disposition: form-data; name=\"f\"; filename=\"a.bin\"\r\n" ++
        "\r\n" ++
        payload ++ "\r\n" ++
        "--zixB--\r\n";

    var parser = init(std.testing.allocator, "zixB");
    defer parser.deinit();

    try parser.parse(body);

    try std.testing.expectEqual(@as(usize, 1), parser.fields.items.len);
    try std.testing.expectEqualStrings(payload, parser.getField("f").?.data);
}

test "zix utils: Multipart, skips the preamble before the first boundary" {
    const body =
        "this text is not part of any field\r\n" ++
        "--b\r\n" ++
        "Content-Disposition: form-data; name=\"one\"\r\n" ++
        "\r\n" ++
        "1\r\n" ++
        "--b--\r\n";

    var parser = init(std.testing.allocator, "b");
    defer parser.deinit();

    try parser.parse(body);

    try std.testing.expectEqual(@as(usize, 1), parser.fields.items.len);
    try std.testing.expectEqualStrings("1", parser.getField("one").?.data);
}

test "zix utils: Multipart, skips a part without a name" {
    const body =
        "--b\r\n" ++
        "Content-Type: text/plain\r\n" ++
        "\r\n" ++
        "orphan\r\n" ++
        "--b\r\n" ++
        "Content-Disposition: form-data; name=\"kept\"\r\n" ++
        "\r\n" ++
        "value\r\n" ++
        "--b--\r\n";

    var parser = init(std.testing.allocator, "b");
    defer parser.deinit();

    try parser.parse(body);

    try std.testing.expectEqual(@as(usize, 1), parser.fields.items.len);
    try std.testing.expectEqualStrings("value", parser.getField("kept").?.data);
}

test "zix utils: Multipart, skips a part with a filename but no name" {
    const body =
        "--b\r\n" ++
        "Content-Disposition: form-data; filename=\"a.bin\"\r\n" ++
        "\r\n" ++
        "payload\r\n" ++
        "--b--\r\n";

    var parser = init(std.testing.allocator, "b");
    defer parser.deinit();

    try parser.parse(body);

    try std.testing.expectEqual(@as(usize, 0), parser.fields.items.len);
}

test "zix utils: Multipart, skips a part without a header end" {
    const body =
        "--b\r\n" ++
        "Content-Disposition: form-data; name=\"broken\"\r\n" ++
        "--b--\r\n";

    var parser = init(std.testing.allocator, "b");
    defer parser.deinit();

    try parser.parse(body);

    try std.testing.expectEqual(@as(usize, 0), parser.fields.items.len);
}

test "zix utils: Multipart, reads quoted name when filename comes first" {
    // `filename="` spells `name="` inside itself, so a plain substring search
    // finds the wrong one in this order.
    const body =
        "--b\r\n" ++
        "Content-Disposition: form-data; filename=\"a.bin\"; name=\"upload\"\r\n" ++
        "\r\n" ++
        "payload\r\n" ++
        "--b--\r\n";

    var parser = init(std.testing.allocator, "b");
    defer parser.deinit();

    try parser.parse(body);

    const field = parser.getField("upload").?;
    try std.testing.expectEqualStrings("upload", field.name);
    try std.testing.expectEqualStrings("a.bin", field.filename.?);
}

test "zix utils: Multipart, unclosed name quote leaves the part unnamed" {
    const body =
        "--b\r\n" ++
        "Content-Disposition: form-data; name=\"upload\r\n" ++
        "\r\n" ++
        "payload\r\n" ++
        "--b--\r\n";

    var parser = init(std.testing.allocator, "b");
    defer parser.deinit();

    try parser.parse(body);

    try std.testing.expectEqual(@as(usize, 0), parser.fields.items.len);
}

test "zix utils: Multipart, file data borrows the body" {
    const body =
        "--b\r\n" ++
        "Content-Disposition: form-data; name=\"f\"; filename=\"a.bin\"\r\n" ++
        "\r\n" ++
        "payload\r\n" ++
        "--b--\r\n";

    var parser = init(std.testing.allocator, "b");
    defer parser.deinit();

    try parser.parse(body);

    const field = parser.getField("f").?;
    const content_offset = std.mem.indexOf(u8, body, "payload").?;

    try std.testing.expectEqual(
        @intFromPtr(body.ptr) + content_offset,
        @intFromPtr(field.data.ptr),
    );
}

test "zix utils: Multipart, parses a body of many parts" {
    const allocator = std.testing.allocator;
    const part_count: usize = 200;

    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(allocator);

    var scratch: [32]u8 = undefined;
    var index: usize = 0;
    while (index < part_count) : (index += 1) {
        try body.appendSlice(allocator, "--b\r\nContent-Disposition: form-data; name=\"");
        try body.appendSlice(allocator, try std.fmt.bufPrint(&scratch, "f{d}", .{index}));
        try body.appendSlice(allocator, "\"\r\n\r\n");
        try body.appendSlice(allocator, try std.fmt.bufPrint(&scratch, "v{d}", .{index}));
        try body.appendSlice(allocator, "\r\n");
    }
    try body.appendSlice(allocator, "--b--\r\n");

    var parser = init(allocator, "b");
    defer parser.deinit();

    try parser.parse(body.items);

    try std.testing.expectEqual(part_count, parser.fields.items.len);
    try std.testing.expectEqualStrings("v199", parser.getField("f199").?.data);
}

test "zix utils: Multipart, delimiter allocation failure is out of memory" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{
        .fail_index = 0,
    });

    var parser = init(failing.allocator(), "b");
    defer parser.deinit();

    try std.testing.expectError(
        Error.ZixUtils_Multipart_OutOfMemory,
        parser.parse("--b--\r\n"),
    );
}

test "zix utils: Multipart, field list allocation failure is out of memory" {
    const body =
        "--b\r\n" ++
        "Content-Disposition: form-data; name=\"one\"\r\n" ++
        "\r\n" ++
        "1\r\n" ++
        "--b--\r\n";

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{
        .fail_index = 1,
    });

    var parser = init(failing.allocator(), "b");
    defer parser.deinit();

    try std.testing.expectError(Error.ZixUtils_Multipart_OutOfMemory, parser.parse(body));
}

