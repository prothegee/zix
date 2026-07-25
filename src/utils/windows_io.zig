//! Minimal blocking socket I/O over ntdll for Windows targets.
//!
//! What:
//! - The engine fast paths talk to sockets through raw POSIX descriptors. On
//!   Windows a socket is an AFD handle driven through ntdll (Zig 0.16 std does
//!   the same), so these helpers wrap NtReadFile / NtWriteFile / NtClose plus
//!   the AFD partial-disconnect ioctl with a wait-on-handle loop for the
//!   thread dispatch models.
//!
//! Note:
//! - Windows-only: every caller comptime-gates on builtin.os.tag == .windows,
//!   nothing here is analyzed on other targets.
//! - Best-effort semantics match the POSIX loops these back: any failed status
//!   maps to error.BrokenPipe, shutdown and close ignore failures.

const std = @import("std");
const windows = std.os.windows;

/// One NtWriteFile call, waiting on the handle when the operation goes async.
///
/// Return:
/// - usize (bytes written)
/// - error.BrokenPipe on any failed status
pub fn writeSome(handle: windows.HANDLE, data: []const u8) error{BrokenPipe}!usize {
    var iosb: windows.IO_STATUS_BLOCK = undefined;
    const len = std.math.lossyCast(windows.ULONG, data.len);

    var status = windows.ntdll.NtWriteFile(handle, null, null, null, &iosb, data.ptr, len, null, null);
    if (status == .PENDING) {
        _ = windows.ntdll.NtWaitForSingleObject(handle, .FALSE, null);
        status = iosb.u.Status;
    }
    if (status != .SUCCESS) return error.BrokenPipe;

    return iosb.Information;
}

/// Write all of data to a socket handle. Blocks until fully sent or failed.
///
/// Return:
/// - void
/// - error.BrokenPipe when the peer is gone or a write fails
pub fn writeAll(handle: windows.HANDLE, data: []const u8) error{BrokenPipe}!void {
    var rem = data;
    while (rem.len > 0) {
        const n = try writeSome(handle, rem);
        if (n == 0) return error.BrokenPipe;

        rem = rem[n..];
    }
}

/// One NtReadFile call, waiting on the handle when the operation goes async.
///
/// Return:
/// - usize (bytes read, 0 when the peer closed)
/// - error.BrokenPipe on any failed status
pub fn readSome(handle: windows.HANDLE, buf: []u8) error{BrokenPipe}!usize {
    var iosb: windows.IO_STATUS_BLOCK = undefined;
    const len = std.math.lossyCast(windows.ULONG, buf.len);

    var status = windows.ntdll.NtReadFile(handle, null, null, null, &iosb, buf.ptr, len, null, null);
    if (status == .PENDING) {
        _ = windows.ntdll.NtWaitForSingleObject(handle, .FALSE, null);
        status = iosb.u.Status;
    }
    if (status == .END_OF_FILE) return 0;
    if (status != .SUCCESS) return error.BrokenPipe;

    return iosb.Information;
}

/// Best-effort full shutdown (send + receive) of a socket handle, so a thread
/// blocked reading it wakes with end-of-stream. Mirrors shutdown(fd, SHUT_RDWR).
pub fn shutdown(handle: windows.HANDLE) void {
    var iosb: windows.IO_STATUS_BLOCK = undefined;
    const info = windows.AFD.PARTIAL_DISCONNECT_INFO{
        .DisconnectMode = .{ .SEND = true, .RECEIVE = true },
        .Timeout = -1,
    };

    const status = windows.ntdll.NtDeviceIoControlFile(
        handle,
        null,
        null,
        null,
        &iosb,
        windows.IOCTL.AFD.PARTIAL_DISCONNECT,
        @ptrCast(&info),
        @sizeOf(windows.AFD.PARTIAL_DISCONNECT_INFO),
        null,
        0,
    );
    if (status == .PENDING) _ = windows.ntdll.NtWaitForSingleObject(handle, .FALSE, null);
}

/// Close a socket handle. Mirrors close(fd).
pub fn close(handle: windows.HANDLE) void {
    _ = windows.ntdll.NtClose(handle);
}
