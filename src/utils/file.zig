//! zix file utils

const std = @import("std");

// --------------------------------------------------------- //

/// Get file extension from file path
///
/// Note:
/// - "" if '.' is not found or '.' is the last character
///
/// Param:
/// file_path - []const u8
///
/// Return:
/// []const u8
pub fn extension(file_path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, file_path, '.')) |dot_pos| {
        if (dot_pos + 1 < file_path.len) {
            return file_path[dot_pos + 1 ..];
        }
    }
    return "";
}

/// Save file data to a directory, creating it if it does not exist
///
/// Param:
/// io        - std.Io
/// allocator - std.mem.Allocator (used to return an owned copy of the saved path)
/// dir       - []const u8 (destination directory path)
/// filename  - []const u8
/// data      - []const u8 (file content)
///
/// Return:
/// ![]const u8 (caller-owned full path of the saved file)
pub fn save(io: std.Io, allocator: std.mem.Allocator, dir: []const u8, filename: []const u8, data: []const u8) ![]const u8 {
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

    return try allocator.dupe(u8, full_path);
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //

test "zix test: utils file extension" {
    try std.testing.expectEqualStrings("txt", extension("file.txt"));
    try std.testing.expectEqualStrings("gz", extension("file.tar.gz"));
    try std.testing.expectEqualStrings("", extension("file"));
    try std.testing.expectEqualStrings("", extension("file."));
    try std.testing.expectEqualStrings("hidden", extension(".hidden"));
}
