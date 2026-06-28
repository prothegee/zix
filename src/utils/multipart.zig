//! zix multipart utils

const std = @import("std");

// --------------------------------------------------------- //

pub const Field = struct {
    name: []const u8,
    filename: ?[]const u8,
    content_type: ?[]const u8,
    data: []const u8,
    is_file: bool,
};

pub const Parser = struct {
    boundary: []const u8,
    fields: std.ArrayList(Field),
    allocator: std.mem.Allocator,

    /// Initialize the multipart parser with the given boundary
    ///
    /// Param:
    /// allocator - std.mem.Allocator
    /// boundary - []const u8 (boundary string from the Content-Type header)
    ///
    /// Return:
    /// - Parser
    pub fn init(allocator: std.mem.Allocator, boundary: []const u8) Parser {
        return .{
            .boundary = boundary,
            .fields = .empty,
            .allocator = allocator,
        };
    }

    /// Free all parsed field data and the fields list
    ///
    /// Note:
    /// - Only file fields have heap-allocated data, form fields borrow from the body slice
    pub fn deinit(self: *Parser) void {
        for (self.fields.items) |field| {
            if (field.is_file) self.allocator.free(field.data);
        }
        self.fields.deinit(self.allocator);
    }

    /// Parse the multipart body into individual fields
    ///
    /// Note:
    /// - File field data is heap-duplicated, form field data slices into the body
    ///
    /// Param:
    /// body - []const u8 (full request body)
    ///
    /// Return:
    /// - !void
    pub fn parse(self: *Parser, body: []const u8) !void {
        const boundary_start = try self.allocator.alloc(u8, self.boundary.len + 4);
        defer self.allocator.free(boundary_start);
        boundary_start[0] = '-';
        boundary_start[1] = '-';
        @memcpy(boundary_start[2..][0..self.boundary.len], self.boundary);
        boundary_start[2 + self.boundary.len] = '\r';
        boundary_start[2 + self.boundary.len + 1] = '\n';

        const boundary_end = try self.allocator.alloc(u8, self.boundary.len + 6);
        defer self.allocator.free(boundary_end);
        boundary_end[0] = '-';
        boundary_end[1] = '-';
        @memcpy(boundary_end[2..][0..self.boundary.len], self.boundary);
        boundary_end[2 + self.boundary.len] = '-';
        boundary_end[2 + self.boundary.len + 1] = '-';
        boundary_end[2 + self.boundary.len + 2] = '\r';
        boundary_end[2 + self.boundary.len + 3] = '\n';

        var start: usize = 0;
        const first = std.mem.indexOf(u8, body, boundary_start) orelse return;
        start = first + boundary_start.len;

        while (start < body.len) {
            const next_start = std.mem.indexOf(u8, body[start..], boundary_start);
            const next_end = std.mem.indexOf(u8, body[start..], boundary_end);
            const next_boundary = if (next_start != null and next_end != null) @min(next_start.?, next_end.?) else if (next_start != null) next_start.? else if (next_end != null) next_end.? else break;

            const part = body[start .. start + next_boundary];
            const header_end = std.mem.indexOf(u8, part, "\r\n\r\n") orelse {
                start = start + next_boundary + (if (next_start != null and next_start.? == next_boundary) boundary_start.len else boundary_end.len);
                continue;
            };
            const headers = part[0..header_end];
            const content = part[header_end + 4 ..];

            var field_name: ?[]const u8 = null;
            var field_filename: ?[]const u8 = null;
            var field_content_type: ?[]const u8 = null;

            var header_iter = std.mem.splitScalar(u8, headers, '\n');
            while (header_iter.next()) |line| {
                const trimmed = std.mem.trim(u8, line, "\r\n ");
                if (std.mem.startsWith(u8, trimmed, "Content-Disposition:")) {
                    const disposition_val = trimmed["Content-Disposition:".len..];
                    if (std.mem.indexOf(u8, disposition_val, "name=\"")) |name_offset| {
                        const val_start = name_offset + 6;
                        if (std.mem.indexOf(u8, disposition_val[val_start..], "\"")) |val_end| field_name = disposition_val[val_start..][0..val_end];
                    }
                    if (std.mem.indexOf(u8, disposition_val, "filename=\"")) |filename_offset| {
                        const val_start = filename_offset + 10;
                        if (std.mem.indexOf(u8, disposition_val[val_start..], "\"")) |val_end| field_filename = disposition_val[val_start..][0..val_end];
                    }
                } else if (std.mem.startsWith(u8, trimmed, "Content-Type:")) {
                    field_content_type = std.mem.trim(u8, trimmed["Content-Type:".len..], " \r\n");
                }
            }

            if (field_name) |name| {
                const data = if (field_filename != null)
                    try self.allocator.dupe(u8, std.mem.trim(u8, content, "\r\n"))
                else
                    std.mem.trim(u8, content, "\r\n");

                try self.fields.append(self.allocator, .{
                    .name = name,
                    .filename = field_filename,
                    .content_type = field_content_type,
                    .data = data,
                    .is_file = (field_filename != null),
                });
            }

            start = start + next_boundary + (if (next_start != null and next_start.? == next_boundary) boundary_start.len else boundary_end.len);
            if (next_start == null and next_end != null) break;
        }
    }

    /// Look up a parsed field by name
    ///
    /// Note:
    /// - null if no field with that name was parsed
    ///
    /// Param:
    /// name - []const u8
    ///
    /// Return:
    /// - ?*Field
    pub fn getField(self: *Parser, name: []const u8) ?*Field {
        for (self.fields.items) |*f| {
            if (std.mem.eql(u8, f.name, name)) return f;
        }
        return null;
    }
};

// --------------------------------------------------------- //
// --------------------------------------------------------- //

test "zix test: multipart Parser parses form and file fields" {
    const boundary = "boundary123";
    const body =
        "--boundary123\r\n" ++
        "Content-Disposition: form-data; name=\"field1\"\r\n" ++
        "\r\n" ++
        "value1\r\n" ++
        "--boundary123\r\n" ++
        "Content-Disposition: form-data; name=\"file1\"; filename=\"test.txt\"\r\n" ++
        "Content-Type: text/plain\r\n" ++
        "\r\n" ++
        "hello world\r\n" ++
        "--boundary123--\r\n";

    var parser = Parser.init(std.testing.allocator, boundary);
    defer parser.deinit();

    try parser.parse(body);

    try std.testing.expectEqual(@as(usize, 2), parser.fields.items.len);

    const f1 = parser.getField("field1").?;
    try std.testing.expectEqualStrings("field1", f1.name);
    try std.testing.expectEqualStrings("value1", f1.data);
    try std.testing.expect(!f1.is_file);

    const f2 = parser.getField("file1").?;
    try std.testing.expectEqualStrings("file1", f2.name);
    try std.testing.expectEqualStrings("test.txt", f2.filename.?);
    try std.testing.expectEqualStrings("text/plain", f2.content_type.?);
    try std.testing.expectEqualStrings("hello world", f2.data);
    try std.testing.expect(f2.is_file);
}
