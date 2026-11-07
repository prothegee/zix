//! ZIX utils file
//!
//! ### file: src/zix/utils/file.zig
//! 
//! ### author: Prana Ron
//! 
//! ---------------------------------------------------------
//! 
//! ### brief:
//! 
//! File existence, extension, read, and write helpers.
//! 
//! ### note:
//! 
//! A path is resolved against the process working directory.
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
const builtin = @import("builtin");

// --------------------------------------------------------- //
// Private:

/// Largest "dir/filename" path save() can assemble on the stack.
const MAX_PATH_LEN: usize = 512;

/// Scratch buffer size backing the file writer in save().
const WRITE_BUF_SIZE: usize = 8192;

/// Targets where a directory can be opened and read, handing back its raw
/// entries instead of failing the read. Every other target refuses, so the
/// cause is already in the failure.
const READ_SUCCEEDS_ON_DIRECTORY: bool = builtin.os.tag == .netbsd;

// --------------------------------------------------------- //
// Public:

pub const Error = error {
    ZixUtils_File_NotFound,
    ZixUtils_File_PathIsDirectory,
    ZixUtils_File_TooLarge,
    ZixUtils_File_Unreadable,
    ZixUtils_File_PathTooLong,
    ZixUtils_File_CreateFailed,
    ZixUtils_File_WriteFailed,
    ZixUtils_File_OutOfMemory,
};

/// Check whether a file exists.
///
/// Param:
/// io - std.Io (the io the open runs on)
/// file_path - []const u8 (path to test)
///
/// Return:
/// - bool (true when the path can be opened for reading)
pub fn exists(io: std.Io, file_path: []const u8) Error!bool {
    const file = std.Io.Dir.cwd().openFile(
        io,
        file_path,
        .{ .mode = .read_only },
    ) catch |err| switch (err) {
        else => return false,
    };
    defer file.close(io);

    return true;
}

/// Get the file extension from a file path.
///
/// Note:
/// - An empty string is returned when `.` is absent or is the last character.
///
/// Param:
/// file_path - []const u8 (path to inspect)
///
/// Return:
/// - []const u8 (the suffix after the last dot, borrowed from file_path)
pub fn extension(file_path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, file_path, '.')) |dot_pos| {
        if (dot_pos + 1 < file_path.len) {
            return file_path[dot_pos + 1 ..];
        }
    }

    return "";
}

/// Read a whole file into memory.
///
/// Note:
/// - max_bytes is a hard ceiling, not a hint. A larger file fails rather than
///   allocating, so an unexpected input cannot exhaust memory.
/// - max_bytes is inclusive. A file of exactly max_bytes loads. The underlying
///   std limit is exclusive, so one byte is added here to make the parameter
///   mean what its name says.
/// - The path is resolved against the process working directory, so a relative
///   path only resolves when the process is launched from the expected
///   directory.
/// - A directory named as the path is rejected on every target. NetBSD allows
///   a directory to be read, so the kind is asked for there before the read
///   rather than inferred from it.
///
/// Param:
/// io - std.Io (the io the read runs on)
/// allocator - std.mem.Allocator (owns the returned bytes, caller frees)
/// file_path - []const u8 (path to read)
/// max_bytes - usize (largest file accepted, inclusive)
///
/// Return:
/// - []u8 (caller-owned file content)
/// - Error.ZixUtils_File_NotFound when the path does not resolve
/// - Error.ZixUtils_File_PathIsDirectory when the path names a directory
/// - Error.ZixUtils_File_TooLarge when the file is larger than max_bytes
/// - Error.ZixUtils_File_Unreadable when the path resolves and the read fails
/// - Error.ZixUtils_File_OutOfMemory when allocation fails
pub fn load(
    io: std.Io,
    allocator: std.mem.Allocator,
    file_path: []const u8,
    max_bytes: usize,
) Error![]u8 {
    // NetBSD hands back directory entries rather than refusing the read, so
    // without this the caller there receives binary dirent bytes as if they
    // were file content.
    if (comptime READ_SUCCEEDS_ON_DIRECTORY) {
        const info = std.Io.Dir.cwd().statFile(io, file_path, .{}) catch |err| switch (err) {
            error.FileNotFound => return Error.ZixUtils_File_NotFound,
            else => return Error.ZixUtils_File_Unreadable,
        };

        if (info.kind == .directory) return Error.ZixUtils_File_PathIsDirectory;
    }

    // A caller that only learns "NotFound" cannot tell a typo from a
    // permission problem, and the name is all it gets. Four causes, four
    // names, and the caller names the path it passed in.
    return std.Io.Dir.cwd().readFileAlloc(
        io,
        file_path,
        allocator,
        .limited(max_bytes +| 1),
    ) catch |err| switch (err) {
        error.FileNotFound => return Error.ZixUtils_File_NotFound,
        error.IsDir => return Error.ZixUtils_File_PathIsDirectory,
        error.StreamTooLong => return Error.ZixUtils_File_TooLarge,
        error.OutOfMemory => return Error.ZixUtils_File_OutOfMemory,
        else => return Error.ZixUtils_File_Unreadable,
    };
}

/// Save file data to a directory, creating it if it does not exist.
///
/// Param:
/// io - std.Io (the io the write runs on)
/// allocator - std.mem.Allocator (owns the returned path copy, caller frees)
/// dir - []const u8 (destination directory path)
/// filename - []const u8 (name of the file inside dir)
/// data - []const u8 (file content)
///
/// Return:
/// - []const u8 (caller-owned full path of the saved file)
/// - Error.ZixUtils_File_PathTooLong when the path does not fit the buffer
/// - Error.ZixUtils_File_CreateFailed when the file cannot be created
/// - Error.ZixUtils_File_WriteFailed when the content cannot be written
/// - Error.ZixUtils_File_OutOfMemory when the path copy cannot be allocated
pub fn save(
    io: std.Io,
    allocator: std.mem.Allocator,
    dir: []const u8,
    filename: []const u8,
    data: []const u8,
) Error![]const u8 {
    var path_buf: [MAX_PATH_LEN]u8 = undefined;
    if (dir.len + 1 + filename.len > path_buf.len) {
        return Error.ZixUtils_File_PathTooLong;
    }

    // Best effort. A missing parent directory surfaces at createFile below.
    std.Io.Dir.cwd().createDirPath(io, dir) catch |err| switch (err) {
        else => {},
    };

    @memcpy(path_buf[0..dir.len], dir);
    path_buf[dir.len] = '/';
    @memcpy(path_buf[dir.len + 1 ..][0..filename.len], filename);
    const full_path = path_buf[0 .. dir.len + 1 + filename.len];

    const file = std.Io.Dir.cwd().createFile(io, full_path, .{}) catch |err| switch (err) {
        else => return Error.ZixUtils_File_CreateFailed,
    };
    defer file.close(io);

    var write_buf: [WRITE_BUF_SIZE]u8 = undefined;
    var writer = file.writer(io, &write_buf);

    writer.interface.writeAll(data) catch |err| switch (err) {
        else => return Error.ZixUtils_File_WriteFailed,
    };
    writer.interface.flush() catch |err| switch (err) {
        else => return Error.ZixUtils_File_WriteFailed,
    };

    return allocator.dupe(u8, full_path) catch |err| switch (err) {
        error.OutOfMemory => return Error.ZixUtils_File_OutOfMemory,
    };
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "zix utils: file, exists reports a present and an absent path" {
    const io = std.testing.io;
    const content = "abcdefg";
    const file_save = "exists.txt";
    const file_error = "not-exists.txt";

    const file = try std.Io.Dir.cwd().createFile(io, file_save, .{ .read = true });
    defer file.close(io);
    defer std.Io.Dir.cwd().deleteFile(io, file_save) catch |err| switch (err) {
        else => {},
    };
    _ = try file.writePositionalAll(io, content, 0);

    try std.testing.expect(try exists(io, file_save));
    try std.testing.expect(!try exists(io, file_error));
}

test "zix utils: file, extension returns the suffix after the last dot" {
    try std.testing.expectEqualStrings("txt", extension("file.txt"));
    try std.testing.expectEqualStrings("gz", extension("file.tar.gz"));
    try std.testing.expectEqualStrings("", extension("file"));
    try std.testing.expectEqualStrings("", extension("file."));
    try std.testing.expectEqualStrings("hidden", extension(".hidden"));
    try std.testing.expectEqualStrings("", extension(""));
}

test "zix utils: file, save and load round trip" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();

    const io = threaded.io();
    const allocator = std.testing.allocator;
    const content = "<h1>zix</h1>\n";

    const saved_path = try save(io, allocator, "tmp/zix_file_load_test", "page.html", content);
    defer allocator.free(saved_path);
    defer std.Io.Dir.cwd().deleteFile(io, saved_path) catch |err| switch (err) {
        else => {},
    };

    const read_back = try load(io, allocator, saved_path, 4096);
    defer allocator.free(read_back);

    try std.testing.expectEqualStrings(content, read_back);
}

test "zix utils: file, load rejects a file over max_bytes" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();

    const io = threaded.io();
    const allocator = std.testing.allocator;
    const content = "0123456789";

    const saved_path = try save(
        io,
        allocator,
        "tmp/zix_file_load_test",
        "oversize.txt",
        content,
    );
    defer allocator.free(saved_path);
    defer std.Io.Dir.cwd().deleteFile(io, saved_path) catch |err| switch (err) {
        else => {},
    };

    // A ceiling below the file size must fail. Exactly the file size must
    // succeed, which is the point of the inclusive adjustment inside load().
    try std.testing.expectError(
        Error.ZixUtils_File_TooLarge,
        load(io, allocator, saved_path, content.len - 1),
    );

    const exact = try load(io, allocator, saved_path, content.len);
    defer allocator.free(exact);

    try std.testing.expectEqualStrings(content, exact);
}

test "zix utils: file, load names a missing path as missing" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();

    try std.testing.expectError(
        Error.ZixUtils_File_NotFound,
        load(
            threaded.io(),
            std.testing.allocator,
            "tmp/zix_file_load_test/definitely_absent.html",
            4096,
        ),
    );
}

test "zix utils: file, load names a directory as a directory" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();

    const io = threaded.io();
    std.Io.Dir.cwd().createDirPath(
        io,
        "tmp/zix_file_load_test/a_directory",
    ) catch |err| switch (err) {
        else => {},
    };
    defer std.Io.Dir.cwd().deleteTree(
        io,
        "tmp/zix_file_load_test/a_directory",
    ) catch |err| switch (err) {
        else => {},
    };

    try std.testing.expectError(
        Error.ZixUtils_File_PathIsDirectory,
        load(io, std.testing.allocator, "tmp/zix_file_load_test/a_directory", 4096),
    );
}

test "zix utils: file, save rejects a path that is too long" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();

    const long_dir: [600]u8 = @splat('a');

    try std.testing.expectError(
        Error.ZixUtils_File_PathTooLong,
        save(threaded.io(), std.testing.allocator, &long_dir, "file.txt", "x"),
    );
}

