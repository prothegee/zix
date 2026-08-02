//! zix file utils

const std = @import("std");

/// Largest "dir/filename" path save() can assemble on the stack. Longer paths return error.PathTooLong.
const MAX_PATH_LEN: usize = 512;
/// Scratch buffer size backing the file writer in save().
const WRITE_BUF_SIZE: usize = 8192;

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
/// - []const u8
pub fn extension(file_path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, file_path, '.')) |dot_pos| {
        if (dot_pos + 1 < file_path.len) {
            return file_path[dot_pos + 1 ..];
        }
    }
    return "";
}

/// Read a whole file into memory
///
/// Note:
/// - max_bytes is a hard ceiling, not a hint. A larger file fails rather than allocating, so
///   an unexpected input cannot exhaust memory.
/// - max_bytes is INCLUSIVE: a file of exactly max_bytes loads. The underlying std limit is
///   exclusive (it rejects a file whose size equals the limit), so one byte is added here to
///   make the parameter mean what its name says.
/// - The path is resolved against the process working directory, so a relative path only
///   resolves when the process is launched from the expected directory.
///
/// Param:
/// io - std.Io
/// allocator - std.mem.Allocator (owns the returned bytes, caller frees)
/// file_path - []const u8 (path to read)
/// max_bytes - usize (largest file accepted, inclusive)
///
/// Return:
/// - ![]u8 (caller-owned file content)
/// - error.StreamTooLong if the file is larger than max_bytes
/// - error.FileNotFound if the path does not resolve
pub fn load(io: std.Io, allocator: std.mem.Allocator, file_path: []const u8, max_bytes: usize) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, file_path, allocator, .limited(max_bytes +| 1));
}

/// Save file data to a directory, creating it if it does not exist
///
/// Param:
/// io - std.Io
/// allocator - std.mem.Allocator (used to return an owned copy of the saved path)
/// dir - []const u8 (destination directory path)
/// filename - []const u8
/// data - []const u8 (file content)
///
/// Return:
/// - ![]const u8 (caller-owned full path of the saved file)
pub fn save(io: std.Io, allocator: std.mem.Allocator, dir: []const u8, filename: []const u8, data: []const u8) ![]const u8 {
    std.Io.Dir.cwd().createDirPath(io, dir) catch {};

    var path_buf: [MAX_PATH_LEN]u8 = undefined;
    if (dir.len + 1 + filename.len > path_buf.len) return error.PathTooLong;
    @memcpy(path_buf[0..dir.len], dir);
    path_buf[dir.len] = '/';
    @memcpy(path_buf[dir.len + 1 ..][0..filename.len], filename);
    const full_path = path_buf[0 .. dir.len + 1 + filename.len];

    const f = try std.Io.Dir.cwd().createFile(io, full_path, .{});
    defer f.close(io);

    var write_buf: [WRITE_BUF_SIZE]u8 = undefined;
    var writer = f.writer(io, &write_buf);
    try writer.interface.writeAll(data);
    try writer.interface.flush();

    return try allocator.dupe(u8, full_path);
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //

test "zix utils: file extension" {
    try std.testing.expectEqualStrings("txt", extension("file.txt"));
    try std.testing.expectEqualStrings("gz", extension("file.tar.gz"));
    try std.testing.expectEqualStrings("", extension("file"));
    try std.testing.expectEqualStrings("", extension("file."));
    try std.testing.expectEqualStrings("hidden", extension(".hidden"));
}

test "zix utils: file load, round trip through save" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();

    const io = threaded.io();
    const allocator = std.testing.allocator;
    const content = "<h1>zix</h1>\n";

    const saved_path = try save(io, allocator, "tmp/zix_file_load_test", "page.html", content);
    defer allocator.free(saved_path);
    defer std.Io.Dir.cwd().deleteFile(io, saved_path) catch {};

    const read_back = try load(io, allocator, saved_path, 4096);
    defer allocator.free(read_back);

    try std.testing.expectEqualStrings(content, read_back);
}

test "zix utils: file load, over max_bytes fails instead of allocating" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();

    const io = threaded.io();
    const allocator = std.testing.allocator;
    const content = "0123456789";

    const saved_path = try save(io, allocator, "tmp/zix_file_load_test", "oversize.txt", content);
    defer allocator.free(saved_path);
    defer std.Io.Dir.cwd().deleteFile(io, saved_path) catch {};

    // A ceiling below the file size must fail. Exactly the file size must succeed, which is
    // the whole point of the inclusive adjustment inside load().
    try std.testing.expectError(error.StreamTooLong, load(io, allocator, saved_path, content.len - 1));

    const exact = try load(io, allocator, saved_path, content.len);
    defer allocator.free(exact);

    try std.testing.expectEqualStrings(content, exact);
}

test "zix utils: file load, missing path returns FileNotFound" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();

    try std.testing.expectError(
        error.FileNotFound,
        load(threaded.io(), std.testing.allocator, "tmp/zix_file_load_test/definitely_absent.html", 4096),
    );
}
