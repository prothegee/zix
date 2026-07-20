//! Minimal Redis RESP protocol for the transport PoC (std only). Redis needs no
//! auth here (protected-mode off), so connect is a plain TCP dial. The command
//! encode and the reply scanner are transport-agnostic, shared by the ASYNC,
//! EPOLL, and URING loops. All socket I/O goes through raw std.os.linux
//! syscalls, since the posix fn wrappers were dropped in 0.16.

const std = @import("std");
const linux = std.os.linux;

pub const Fd = i32;

fn ok(rc: usize) bool {
    return std.posix.errno(rc) == .SUCCESS;
}

pub fn close(fd: Fd) void {
    _ = linux.close(fd);
}

pub fn connect(port: u16) !Fd {
    const sock_rc = linux.socket(linux.AF.INET, linux.SOCK.STREAM, linux.IPPROTO.TCP);
    if (!ok(sock_rc)) return error.Socket;

    const fd: Fd = @intCast(sock_rc);
    errdefer close(fd);

    const addr: linux.sockaddr.in = .{ .port = std.mem.nativeToBig(u16, port), .addr = @bitCast([4]u8{ 127, 0, 0, 1 }) };
    if (!ok(linux.connect(fd, @ptrCast(&addr), @sizeOf(linux.sockaddr.in)))) return error.Connect;

    setNoDelay(fd);

    return fd;
}

pub fn setNoDelay(fd: Fd) void {
    var one: i32 = 1;
    _ = linux.setsockopt(fd, linux.IPPROTO.TCP, linux.TCP.NODELAY, @ptrCast(&one), 4);
}

pub fn setNonBlock(fd: Fd) void {
    const flags = linux.fcntl(fd, std.posix.F.GETFL, 0);
    const nonblock: usize = @as(u32, @bitCast(std.posix.O{ .NONBLOCK = true }));
    _ = linux.fcntl(fd, std.posix.F.SETFL, flags | nonblock);
}

pub fn readNb(fd: Fd, buf: []u8) usize {
    const rc = linux.read(fd, buf.ptr, buf.len);

    return if (ok(rc)) rc else 0;
}

pub fn writeNb(fd: Fd, buf: []const u8) usize {
    const rc = linux.write(fd, buf.ptr, buf.len);

    return if (ok(rc)) rc else 0;
}

pub fn writeAll(fd: Fd, bytes: []const u8) !void {
    var sent: usize = 0;
    while (sent < bytes.len) {
        const rc = linux.write(fd, bytes[sent..].ptr, bytes.len - sent);
        switch (std.posix.errno(rc)) {
            .SUCCESS => {
                if (rc == 0) return error.Closed;
                sent += rc;
            },
            .INTR, .AGAIN => continue,
            else => return error.Write,
        }
    }
}

/// Render a RESP command from its parts into buf. Returns the byte length.
/// Example: encodeCmd(&.{ "SET", "item:1", "{...}" }, buf).
pub fn encodeCmd(parts: []const []const u8, buf: []u8) usize {
    var pos: usize = 0;
    pos += (std.fmt.bufPrint(buf[pos..], "*{d}\r\n", .{parts.len}) catch unreachable).len;

    for (parts) |part| {
        pos += (std.fmt.bufPrint(buf[pos..], "${d}\r\n", .{part.len}) catch unreachable).len;
        @memcpy(buf[pos..][0..part.len], part);
        pos += part.len;
        buf[pos] = '\r';
        buf[pos + 1] = '\n';
        pos += 2;
    }

    return pos;
}

/// Copy a pre-rendered command into out. The pool already holds full RESP
/// bytes, so the send path is a plain copy (mirrors pg.encodeQuery's shape).
pub fn encode(cmd: []const u8, out: []u8) usize {
    @memcpy(out[0..cmd.len], cmd);

    return cmd.len;
}

/// Length of one complete RESP reply at the front of bytes, or null when it has
/// not fully arrived. Handles the reply kinds the PoC issues: simple string
/// (+), error (-), integer (:), and bulk string ($, with -1 for nil).
fn replyLen(bytes: []const u8) ?usize {
    if (bytes.len == 0) return null;

    switch (bytes[0]) {
        '+', '-', ':' => {
            const eol = std.mem.indexOf(u8, bytes, "\r\n") orelse return null;

            return eol + 2;
        },
        '$' => {
            const eol = std.mem.indexOf(u8, bytes, "\r\n") orelse return null;
            const declared = std.fmt.parseInt(i64, bytes[1..eol], 10) catch return null;
            if (declared < 0) return eol + 2;

            const total = eol + 2 + @as(usize, @intCast(declared)) + 2;
            if (bytes.len < total) return null;

            return total;
        },
        else => return null,
    }
}

pub const ScanResult = struct { ready: usize, consumed: usize, failed: bool };

/// Scan complete RESP replies in bytes, counting one per reply. Stops at the
/// last complete reply, so the caller keeps the trailing partial bytes.
pub fn scan(bytes: []const u8) ScanResult {
    var pos: usize = 0;
    var ready: usize = 0;
    var failed = false;

    while (pos < bytes.len) {
        const len = replyLen(bytes[pos..]) orelse break;
        if (bytes[pos] == '-') failed = true;
        ready += 1;
        pos += len;
    }

    return .{ .ready = ready, .consumed = pos, .failed = failed };
}
