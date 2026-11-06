const std = @import("std");
const builtin = @import("builtin");
const windows = std.os.windows;

// Smallest IOCP round trip: create a port, post a completion packet, and
// dequeue it. Compile gate:
//   zig build-exe rnd/iocp-probe/iocp_smoke.zig -target x86_64-windows-gnu -fno-emit-bin
// Runs on a Windows host or under Wine:
//   wine iocp_smoke.exe

extern "kernel32" fn CreateIoCompletionPort(
    FileHandle: windows.HANDLE,
    ExistingCompletionPort: ?windows.HANDLE,
    CompletionKey: usize,
    NumberOfConcurrentThreads: u32,
) callconv(.winapi) ?windows.HANDLE;

extern "kernel32" fn PostQueuedCompletionStatus(
    CompletionPort: windows.HANDLE,
    dwNumberOfBytesTransferred: u32,
    dwCompletionKey: usize,
    lpOverlapped: ?*anyopaque,
) callconv(.winapi) windows.BOOL;

extern "kernel32" fn GetQueuedCompletionStatus(
    CompletionPort: windows.HANDLE,
    lpNumberOfBytesTransferred: *u32,
    lpCompletionKey: *usize,
    lpOverlapped: *?*anyopaque,
    dwMilliseconds: u32,
) callconv(.winapi) windows.BOOL;

const Overlapped = extern struct {
    Internal: usize,
    InternalHigh: usize,
    Offset: u32,
    OffsetHigh: u32,
    Event: ?windows.HANDLE,
};

const PROBE_KEY: usize = 0x21C;

pub fn main() !void {
    const port = CreateIoCompletionPort(
        windows.INVALID_HANDLE_VALUE,
        null,
        0,
        0,
    ) orelse return error.CreateIoCompletionPortFailed;
    defer _ = windows.CloseHandle(port);

    var overlapped: Overlapped = std.mem.zeroes(Overlapped);
    const posted = PostQueuedCompletionStatus(port, 0, PROBE_KEY, @ptrCast(&overlapped));
    if (posted == .FALSE) return error.PostQueuedCompletionStatusFailed;

    var bytes_transferred: u32 = 0;
    var completion_key: usize = 0;
    var dequeued: ?*anyopaque = null;
    const got = GetQueuedCompletionStatus(
        port,
        &bytes_transferred,
        &completion_key,
        &dequeued,
        std.math.maxInt(u32),
    );
    if (got == .FALSE) return error.GetQueuedCompletionStatusFailed;
    if (completion_key != PROBE_KEY) return error.CompletionKeyMismatch;

    std.debug.print("iocp smoke ok on {s}\n", .{@tagName(builtin.target.os.tag)});
}

