//! ZIX Logger windows_file
//!
//! ### file: src/zix/logger/windows_file.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Windows log-file backend over ntdll: create the day directory, open the file
//! for append, write, and close.
//!
//! ### note:
//!
//! The logger writes from a background thread it owns and must stay free of a
//! `std.Io` instance, so this uses the ntdll surface directly. Every caller is
//! comptime-gated on Windows; nothing here is analyzed on other targets.
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
const windows = std.os.windows;

// --------------------------------------------------------- //
// Private:

/// NtWriteFile offset meaning "append at the end of the file".
const WRITE_TO_END_OF_FILE: windows.LARGE_INTEGER = -1;

/// Convert a slashed path into the `\??\` NT form NtCreateFile expects.
fn ntPath(path: []const u8) Error!std.Io.Threaded.WindowsPathSpace {
    return std.Io.Threaded.sliceToPrefixedFileW(
        null,
        path,
        .{
            .allow_relative = false,
        },
    ) catch return Error.ZixLogger_WindowsFile_PathBad;
}

// --------------------------------------------------------- //
// Public:

/// ZIX Logger windows_file error
pub const Error = error{
    ZixLogger_WindowsFile_PathBad,
    ZixLogger_WindowsFile_OpenFailed,
    ZixLogger_WindowsFile_WriteFailed,
};

/// Create one directory, treating "it is already there" as success.
pub fn createDir(path: []const u8) Error!void {
    if (comptime builtin.os.tag != .windows) {
        return Error.ZixLogger_WindowsFile_OpenFailed;
    }

    const space = try ntPath(path);
    var name = space.string();
    const attributes = windows.OBJECT.ATTRIBUTES{ .ObjectName = &name };

    var handle: windows.HANDLE = undefined;
    var iosb: windows.IO_STATUS_BLOCK = undefined;
    const status = windows.ntdll.NtCreateFile(
        &handle,
        .{
            .STANDARD = .{
                .SYNCHRONIZE = true,
            },
            .SPECIFIC = .{
                .FILE = .{
                    .READ_DATA = true,
                },
            },
        },
        &attributes,
        &iosb,
        null,
        .{ .DIRECTORY = true },
        .{
            .READ = true,
            .WRITE = true,
        },
        .OPEN_IF,
        .{
            .DIRECTORY_FILE = true,
            .IO = .SYNCHRONOUS_NONALERT,
        },
        null,
        0,
    );
    if (status != .SUCCESS) return Error.ZixLogger_WindowsFile_OpenFailed;

    _ = windows.ntdll.NtClose(handle);
}

/// Open a log file for append, creating it when it is not there yet.
pub fn openAppend(path: []const u8) Error!windows.HANDLE {
    if (comptime builtin.os.tag != .windows) {
        return Error.ZixLogger_WindowsFile_OpenFailed;
    }

    const space = try ntPath(path);
    var name = space.string();
    const attributes = windows.OBJECT.ATTRIBUTES{ .ObjectName = &name };

    var handle: windows.HANDLE = undefined;
    var iosb: windows.IO_STATUS_BLOCK = undefined;
    const status = windows.ntdll.NtCreateFile(
        &handle,
        .{
            .STANDARD = .{
                .SYNCHRONIZE = true,
            },
            .SPECIFIC = .{
                .FILE = .{
                    .APPEND_DATA = true,
                },
            },
        },
        &attributes,
        &iosb,
        null,
        .{ .NORMAL = true },
        .{
            .READ = true,
            .WRITE = true,
        },
        .OPEN_IF,
        .{
            .NON_DIRECTORY_FILE = true,
            .IO = .SYNCHRONOUS_NONALERT,
        },
        null,
        0,
    );
    if (status != .SUCCESS) return Error.ZixLogger_WindowsFile_OpenFailed;

    return handle;
}

/// Write every byte to an append handle.
pub fn writeAll(handle: windows.HANDLE, data: []const u8) Error!void {
    var remaining = data;
    while (remaining.len > 0) {
        var iosb: windows.IO_STATUS_BLOCK = undefined;
        var offset: windows.LARGE_INTEGER = WRITE_TO_END_OF_FILE;
        const status = windows.ntdll.NtWriteFile(
            handle,
            null,
            null,
            null,
            &iosb,
            remaining.ptr,
            std.math.lossyCast(windows.ULONG, remaining.len),
            &offset,
            null,
        );
        if (status != .SUCCESS) return Error.ZixLogger_WindowsFile_WriteFailed;

        const written = iosb.Information;
        if (written == 0) return Error.ZixLogger_WindowsFile_WriteFailed;

        remaining = remaining[written..];
    }
}

pub fn closeFile(handle: windows.HANDLE) void {
    _ = windows.ntdll.NtClose(handle);
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "zix logger: windows_file, non-target calls report open failure" {
    if (comptime builtin.os.tag == .windows) return;

    try std.testing.expectError(
        Error.ZixLogger_WindowsFile_OpenFailed,
        createDir("logs"),
    );
    try std.testing.expectError(
        Error.ZixLogger_WindowsFile_OpenFailed,
        openAppend("logs/log"),
    );
}

test "zix logger: windows_file, empty path is rejected on Windows" {
    if (comptime builtin.os.tag != .windows) return;

    try std.testing.expectError(
        Error.ZixLogger_WindowsFile_PathBad,
        openAppend(""),
    );
}

