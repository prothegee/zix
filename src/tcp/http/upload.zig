//! zix http upload

const std = @import("std");

pub const MultipartField = struct {
    name: []const u8,
    filename: ?[]const u8,
    content_type: ?[]const u8,
    data: []const u8,
    is_file: bool,
};

pub const MultipartParser = struct {
    boundary: []const u8,
    fields: std.ArrayList(MultipartField),
    allocator: std.mem.Allocator,

    /// Brief:
    /// Initialize the multipart parser with the given boundary
    ///
    /// Param:
    /// allocator - std.mem.Allocator
    /// boundary  - []const u8 (boundary string from the Content-Type header)
    ///
    /// Return:
    /// MultipartParser
    pub fn init(allocator: std.mem.Allocator, boundary: []const u8) MultipartParser {
        return .{
            .boundary = boundary,
            .fields = .empty,
            .allocator = allocator,
        };
    }

    /// Brief:
    /// Free all parsed field data and the fields list
    ///
    /// Note:
    /// - Only file fields have heap-allocated data; form fields borrow from the body slice
    pub fn deinit(self: *MultipartParser) void {
        for (self.fields.items) |field| {
            if (field.is_file) self.allocator.free(field.data);
        }
        self.fields.deinit(self.allocator);
    }

    /// Brief:
    /// Parse the multipart body into individual fields
    ///
    /// Note:
    /// - File field data is heap-duplicated; form field data slices into the body
    ///
    /// Param:
    /// body - []const u8 (full request body)
    ///
    /// Return:
    /// !void
    pub fn parse(self: *MultipartParser, body: []const u8) !void {
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
            const ns = std.mem.indexOf(u8, body[start..], boundary_start);
            const ne = std.mem.indexOf(u8, body[start..], boundary_end);
            const nb = if (ns != null and ne != null) @min(ns.?, ne.?) else if (ns != null) ns.? else if (ne != null) ne.? else break;

            const part = body[start .. start + nb];
            const hend = std.mem.indexOf(u8, part, "\r\n\r\n") orelse {
                start = start + nb + (if (ns != null and ns.? == nb) boundary_start.len else boundary_end.len);
                continue;
            };
            const headers = part[0..hend];
            const content = part[hend + 4 ..];

            var field_name: ?[]const u8 = null;
            var field_filename: ?[]const u8 = null;
            var field_content_type: ?[]const u8 = null;

            var hit = std.mem.splitScalar(u8, headers, '\n');
            while (hit.next()) |line| {
                const trimmed = std.mem.trim(u8, line, "\r\n ");
                if (std.mem.startsWith(u8, trimmed, "Content-Disposition:")) {
                    const dv = trimmed["Content-Disposition:".len..];
                    if (std.mem.indexOf(u8, dv, "name=\"")) |ns2| {
                        const vs = ns2 + 6;
                        if (std.mem.indexOf(u8, dv[vs..], "\"")) |ve| field_name = dv[vs..][0..ve];
                    }
                    if (std.mem.indexOf(u8, dv, "filename=\"")) |fs| {
                        const vs = fs + 10;
                        if (std.mem.indexOf(u8, dv[vs..], "\"")) |ve| field_filename = dv[vs..][0..ve];
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

            start = start + nb + (if (ns != null and ns.? == nb) boundary_start.len else boundary_end.len);
            if (ns == null and ne != null) break;
        }
    }

    /// Brief:
    /// Look up a parsed field by name
    ///
    /// Note:
    /// - Returns null if no field with that name was parsed
    ///
    /// Param:
    /// name - []const u8
    ///
    /// Return:
    /// ?*MultipartField
    pub fn getField(self: *MultipartParser, name: []const u8) ?*MultipartField {
        for (self.fields.items) |*f| {
            if (std.mem.eql(u8, f.name, name)) return f;
        }
        return null;
    }
};

/// Brief:
/// Save file data to a directory, creating it if it does not exist
///
/// Param:
/// io       - std.Io
/// dir      - []const u8 (destination directory path)
/// filename - []const u8
/// data     - []const u8 (file content)
///
/// Return:
/// ![]const u8 (full path of the saved file)
pub fn saveFile(io: std.Io, dir: []const u8, filename: []const u8, data: []const u8) ![]const u8 {
    std.Io.Dir.cwd().createDirPath(io, dir) catch {};

    var path_buf: [512]u8 = undefined;
    if (dir.len + 1 + filename.len > path_buf.len) return error.PathTooLong;
    @memcpy(path_buf[0..dir.len], dir);
    path_buf[dir.len] = '/';
    @memcpy(path_buf[dir.len + 1 ..][0..filename.len], filename);
    const full_path = path_buf[0 .. dir.len + 1 + filename.len];

    const f = try std.Io.Dir.cwd().createFile(io, full_path, .{});
    defer f.close(io);

    var write_buf: [8192]u8 = undefined;
    var writer = f.writer(io, &write_buf);
    try writer.interface.writeAll(data);
    try writer.interface.flush();

    return full_path;
}
