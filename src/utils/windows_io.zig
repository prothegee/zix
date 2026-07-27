//! Minimal blocking socket I/O over ntdll for Windows targets.
//!
//! What:
//! - The engine fast paths talk to sockets through raw POSIX descriptors. On
//!   Windows a socket is an AFD handle driven through ntdll (Zig 0.16 std does
//!   the same), so these helpers issue the AFD send, receive, and
//!   partial-disconnect ioctls plus NtClose, each completed through its own
//!   event, for the thread dispatch models.
//! - The plain NtReadFile / NtWriteFile path is NOT used: raw AFD endpoints
//!   (opened by std, not by Winsock) fail it with connection-abort statuses.
//!   The ioctls here are the requests std itself issues for every socket
//!   read and write, so they are the proven path on these handles.
//!
//! Note:
//! - Windows-only: every caller comptime-gates on builtin.os.tag == .windows,
//!   nothing here is analyzed on other targets.
//! - Best-effort semantics match the POSIX loops these back: any failed status
//!   maps to error.BrokenPipe, shutdown and close ignore failures.

const std = @import("std");
const windows = std.os.windows;

/// Per-call completion event for the NT I/O helpers below.
///
/// Note:
/// - The socket handles Zig 0.16 std hands out are AFD endpoints opened
///   asynchronous, and a socket's file object is signaled by EVERY completed
///   operation on it (std's own connect and send ioctls included). Waiting on
///   the socket handle can therefore return before this call's operation
///   finished, reading the status block too early. A fresh event per call is
///   signaled only by this one operation.
///
/// Return:
/// - windows.HANDLE (release with close())
/// - error.BrokenPipe if event creation fails
fn createIoEvent() error{BrokenPipe}!windows.HANDLE {
    var event: windows.HANDLE = undefined;
    const status = windows.ntdll.NtCreateEvent(
        &event,
        windows.ACCESS_MASK.Specific.Event.ALL_ACCESS,
        null,
        .Notification,
        .FALSE,
    );
    if (status != .SUCCESS) return error.BrokenPipe;

    return event;
}

/// One AFD send ioctl (the socket write request std itself issues), waiting
/// on a per-call event when the operation goes async.
///
/// Return:
/// - usize (bytes written)
/// - error.BrokenPipe on any failed status
pub fn writeOnce(handle: windows.HANDLE, data: []const u8) error{BrokenPipe}!usize {
    const event = try createIoEvent();
    defer close(event);

    const iovecs = [1]windows.AFD.WSABUF(.@"const"){.{
        .len = std.math.lossyCast(windows.ULONG, data.len),
        .buf = data.ptr,
    }};
    const info = windows.AFD.SEND_INFO{
        .BufferArray = &iovecs,
        .BufferCount = 1,
        .AfdFlags = .{ .NO_FAST_IO = true, .OVERLAPPED = true },
        .TdiFlags = .{},
    };

    var iosb: windows.IO_STATUS_BLOCK = undefined;
    var status = windows.ntdll.NtDeviceIoControlFile(
        handle,
        event,
        null,
        null,
        &iosb,
        windows.IOCTL.AFD.SEND,
        @ptrCast(&info),
        @sizeOf(windows.AFD.SEND_INFO),
        null,
        0,
    );
    if (status == .PENDING) {
        _ = windows.ntdll.NtWaitForSingleObject(event, .FALSE, null);
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
        const n = try writeOnce(handle, rem);
        if (n == 0) return error.BrokenPipe;

        rem = rem[n..];
    }
}

/// One AFD receive ioctl (the socket read request std itself issues), waiting
/// on a per-call event when the operation goes async. A graceful peer close
/// completes with SUCCESS and 0 bytes, same as a POSIX read.
///
/// Return:
/// - usize (bytes read, 0 when the peer closed)
/// - error.BrokenPipe on any failed status
pub fn readOnce(handle: windows.HANDLE, buf: []u8) error{BrokenPipe}!usize {
    const event = try createIoEvent();
    defer close(event);

    const iovecs = [1]windows.AFD.WSABUF(.@"var"){.{
        .len = std.math.lossyCast(windows.ULONG, buf.len),
        .buf = buf.ptr,
    }};
    const info = windows.AFD.RECV_INFO{
        .BufferArray = &iovecs,
        .BufferCount = 1,
        .AfdFlags = .{ .NO_FAST_IO = true, .OVERLAPPED = true },
        .TdiFlags = .{ .NORMAL = true },
    };

    var iosb: windows.IO_STATUS_BLOCK = undefined;
    var status = windows.ntdll.NtDeviceIoControlFile(
        handle,
        event,
        null,
        null,
        &iosb,
        windows.IOCTL.AFD.RECEIVE,
        @ptrCast(&info),
        @sizeOf(windows.AFD.RECV_INFO),
        null,
        0,
    );
    if (status == .PENDING) {
        _ = windows.ntdll.NtWaitForSingleObject(event, .FALSE, null);
        status = iosb.u.Status;
    }
    if (status == .END_OF_FILE) return 0;
    if (status != .SUCCESS) return error.BrokenPipe;

    return iosb.Information;
}

/// Best-effort full shutdown (send + receive) of a socket handle, so a thread
/// blocked reading it wakes with end-of-stream. Mirrors shutdown(fd, SHUT_RDWR).
pub fn shutdown(handle: windows.HANDLE) void {
    const event = createIoEvent() catch return;
    defer close(event);

    var iosb: windows.IO_STATUS_BLOCK = undefined;
    const info = windows.AFD.PARTIAL_DISCONNECT_INFO{
        .DisconnectMode = .{ .SEND = true, .RECEIVE = true },
        .Timeout = -1,
    };

    const status = windows.ntdll.NtDeviceIoControlFile(
        handle,
        event,
        null,
        null,
        &iosb,
        windows.IOCTL.AFD.PARTIAL_DISCONNECT,
        @ptrCast(&info),
        @sizeOf(windows.AFD.PARTIAL_DISCONNECT_INFO),
        null,
        0,
    );
    if (status == .PENDING) _ = windows.ntdll.NtWaitForSingleObject(event, .FALSE, null);
}

/// Close a socket handle. Mirrors close(fd).
pub fn close(handle: windows.HANDLE) void {
    _ = windows.ntdll.NtClose(handle);
}

/// Wall-clock nanoseconds since the Unix epoch (real/system time basis).
/// Mirrors clock_gettime(CLOCK_REALTIME).
///
/// Return:
/// - u64 (nanoseconds since 1970-01-01, converted from the NTFS/Windows epoch)
pub fn wallClockNs() u64 {
    const epoch_ns: i96 = @as(i96, std.time.epoch.windows) * std.time.ns_per_s;
    const filetime_ns: i96 = @as(i96, windows.ntdll.RtlGetSystemTimePrecise()) * 100;

    return @intCast(filetime_ns + epoch_ns);
}

/// Monotonic microseconds from the performance counter, never steps backward.
/// Mirrors clock_gettime(CLOCK_MONOTONIC).
///
/// Return:
/// - u64 (microseconds since an arbitrary reference point)
pub fn monotonicUs() u64 {
    var frequency: windows.LARGE_INTEGER = undefined;
    _ = windows.ntdll.RtlQueryPerformanceFrequency(&frequency);

    var counter: windows.LARGE_INTEGER = undefined;
    _ = windows.ntdll.RtlQueryPerformanceCounter(&counter);

    const frequency_u64: u64 = @bitCast(frequency);
    const counter_u64: u64 = @bitCast(counter);

    return counter_u64 * std.time.us_per_s / frequency_u64;
}

// --------------------------------------------------------- //
// WSAPoll: the ntdll read/write helpers above block indefinitely, so a caller
// that needs a real recv/send timeout on Windows polls readiness through here
// first. This is the only place in the file that touches ws2_32 rather than
// ntdll, since no AFD_POLL layout is published for Zig to bind against.

/// WSAPoll event bit for readability. Mirrors POSIX POLLIN (POLLRDNORM | POLLRDBAND).
pub const POLLIN: i16 = 0x0300;

/// WSAPoll event bit for writability. Mirrors POSIX POLLOUT (POLLWRNORM).
pub const POLLOUT: i16 = 0x0010;

/// WSAPoll revents bit for an invalid socket: the poll did not watch the
/// handle at all, so it must not count as ready.
const POLLNVAL: i16 = 0x0004;

const WSAPOLLFD = extern struct {
    fd: usize,
    events: i16,
    revents: i16,
};

/// Winsock's version-negotiation output, required once before any other
/// ws2_32 call (including WSAPoll) will succeed. Only the version fields are
/// read here, the rest is scratch space sized to match winsock2.h's WSADATA.
const WSADATA = extern struct {
    version: u16,
    high_version: u16,
    max_sockets: u16,
    max_udp_dg: u16,
    vendor_info: ?[*:0]u8,
    description: [257]u8,
    system_status: [129]u8,
};

extern "ws2_32" fn WSAStartup(version_requested: u16, data: *WSADATA) callconv(.winapi) i32;
extern "ws2_32" fn WSAPoll(fds: [*]WSAPOLLFD, count: c_ulong, timeout_ms: i32) callconv(.winapi) i32;

var wsa_ready: std.atomic.Value(bool) = .init(false);

fn ensureWsaStarted() void {
    if (wsa_ready.load(.acquire)) return;

    var data: WSADATA = undefined;
    _ = WSAStartup(0x0202, &data); // MAKEWORD(2, 2): request Winsock 2.2

    wsa_ready.store(true, .release);
}

/// Poll a socket handle for readiness with a millisecond timeout.
///
/// Param:
/// handle - windows.HANDLE (the socket, from stream.socket.handle)
/// events - i16 (POLLIN or POLLOUT above)
/// timeout_ms - u32 (0 polls once and returns immediately)
///
/// Return:
/// - true when the event is ready before the timeout
/// - false when the timeout elapses first
/// - error.BrokenPipe if WSAPoll itself fails
pub fn pollReady(handle: windows.HANDLE, events: i16, timeout_ms: u32) error{BrokenPipe}!bool {
    ensureWsaStarted();

    var pfd = [1]WSAPOLLFD{.{ .fd = @intFromPtr(handle), .events = events, .revents = 0 }};
    const timeout: i32 = @intCast(@min(timeout_ms, @as(u32, std.math.maxInt(i32))));

    const n = WSAPoll(&pfd, 1, timeout);
    if (n < 0) return error.BrokenPipe;
    if (pfd[0].revents & POLLNVAL != 0) return error.BrokenPipe;

    return n > 0;
}

// --------------------------------------------------------- //
// Secure random: mirrors std.Io.Threaded's own Windows randomSecure, reading
// straight from the CNG device rather than ProcessPrng (bcryptprimitives.dll
// heap-allocates per call and reruns a self-test on every load). ntdll-only,
// no new DLL dependency.

var cng_handle: ?windows.HANDLE = null;
var cng_ready: std.atomic.Value(bool) = .init(false);

fn getCngDevice() error{EntropyUnavailable}!windows.HANDLE {
    if (cng_ready.load(.acquire)) return cng_handle.?;

    var fresh_handle: windows.HANDLE = undefined;
    var iosb: windows.IO_STATUS_BLOCK = undefined;
    var name = windows.UNICODE_STRING.init(&.{ '\\', 'D', 'e', 'v', 'i', 'c', 'e', '\\', 'C', 'N', 'G' });
    const attrs = windows.OBJECT.ATTRIBUTES{ .ObjectName = &name };

    const status = windows.ntdll.NtOpenFile(
        &fresh_handle,
        .{ .STANDARD = .{ .SYNCHRONIZE = true }, .SPECIFIC = .{ .FILE = .{ .READ_DATA = true } } },
        &attrs,
        &iosb,
        .VALID_FLAGS,
        .{ .IO = .SYNCHRONOUS_NONALERT },
    );
    if (status != .SUCCESS) return error.EntropyUnavailable;

    cng_handle = fresh_handle;
    cng_ready.store(true, .release);
    return fresh_handle;
}

/// Fill buf with cryptographically secure random bytes. Mirrors getrandom(buf, buf.len, 0).
///
/// Return:
/// - void
/// - error.EntropyUnavailable if the device open or the read fails
pub fn secureRandom(buf: []u8) error{EntropyUnavailable}!void {
    if (buf.len == 0) return;

    const handle = try getCngDevice();

    var iosb: windows.IO_STATUS_BLOCK = undefined;
    const len: windows.ULONG = std.math.lossyCast(windows.ULONG, buf.len);
    const status = windows.ntdll.NtDeviceIoControlFile(
        handle,
        null,
        null,
        null,
        &iosb,
        windows.IOCTL.KSEC.GEN_RANDOM,
        null,
        0,
        buf.ptr,
        len,
    );
    if (status != .SUCCESS) return error.EntropyUnavailable;
}
