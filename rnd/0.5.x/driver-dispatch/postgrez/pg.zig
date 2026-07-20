//! Minimal PostgreSQL wire protocol for the transport PoC (std only). The
//! handshake (startup + SCRAM auth) is blocking, run once per connection. The
//! query encode and the response scanner are transport-agnostic, so the ASYNC,
//! EPOLL, and URING loops share them. All socket I/O goes through raw
//! std.os.linux syscalls, since the posix fn wrappers were dropped in 0.16.

const std = @import("std");
const scram = @import("scram.zig");
const linux = std.os.linux;

pub const Fd = i32;
pub const PROTOCOL_VERSION: u32 = 196608; // 3.0

fn ok(rc: usize) bool {
    return std.posix.errno(rc) == .SUCCESS;
}

pub fn close(fd: Fd) void {
    _ = linux.close(fd);
}

pub fn connectTcp(port: u16) !Fd {
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

/// Read into buf, returning bytes read. 0 means EAGAIN or a benign stop, so a
/// non-blocking transport retries on the next readiness event.
pub fn readNb(fd: Fd, buf: []u8) usize {
    const rc = linux.read(fd, buf.ptr, buf.len);

    return if (ok(rc)) rc else 0;
}

/// Write from buf, returning bytes written. 0 means EAGAIN or a benign stop.
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

fn readFull(fd: Fd, buf: []u8) !void {
    var got: usize = 0;
    while (got < buf.len) {
        const rc = linux.read(fd, buf[got..].ptr, buf.len - got);
        switch (std.posix.errno(rc)) {
            .SUCCESS => {
                if (rc == 0) return error.Closed;
                got += rc;
            },
            .INTR, .AGAIN => continue,
            else => return error.Read,
        }
    }
}

const Message = struct { tag: u8, payload: []const u8 };

fn readMessage(fd: Fd, buf: []u8) !Message {
    var header: [5]u8 = undefined;
    try readFull(fd, &header);

    const len = std.mem.readInt(u32, header[1..5], .big);
    if (len < 4) return error.BadMessage;

    const payload_len = len - 4;
    if (payload_len > buf.len) return error.MessageTooLarge;
    try readFull(fd, buf[0..payload_len]);

    return .{ .tag = header[0], .payload = buf[0..payload_len] };
}

fn sendStartup(fd: Fd, user: []const u8, database: []const u8) !void {
    var buf: [512]u8 = undefined;
    var pos: usize = 4;

    std.mem.writeInt(u32, buf[pos..][0..4], PROTOCOL_VERSION, .big);
    pos += 4;
    pos = appendKv(&buf, pos, "user", user);
    pos = appendKv(&buf, pos, "database", database);
    buf[pos] = 0;
    pos += 1;

    std.mem.writeInt(u32, buf[0..4], @intCast(pos), .big);

    try writeAll(fd, buf[0..pos]);
}

fn appendKv(buf: []u8, start: usize, key: []const u8, value: []const u8) usize {
    var pos = start;
    @memcpy(buf[pos..][0..key.len], key);
    pos += key.len;
    buf[pos] = 0;
    pos += 1;
    @memcpy(buf[pos..][0..value.len], value);
    pos += value.len;
    buf[pos] = 0;
    pos += 1;

    return pos;
}

fn sendSasl(fd: Fd, tag: u8, parts: []const []const u8) !void {
    var buf: [1200]u8 = undefined;
    var total: usize = 5;
    for (parts) |part| {
        @memcpy(buf[total..][0..part.len], part);
        total += part.len;
    }

    buf[0] = tag;
    std.mem.writeInt(u32, buf[1..5], @intCast(total - 1), .big);

    try writeAll(fd, buf[0..total]);
}

/// Blocking startup + SCRAM-SHA-256 handshake, left ready for queries.
pub fn connectAuth(port: u16, user: []const u8, password: []const u8, database: []const u8) !Fd {
    const fd = try connectTcp(port);
    errdefer close(fd);

    try sendStartup(fd, user, database);

    var scratch: [4096]u8 = undefined;
    var state: ?scram.Scram = null;
    while (true) {
        const msg = try readMessage(fd, &scratch);

        switch (msg.tag) {
            'R' => {
                const code = std.mem.readInt(u32, msg.payload[0..4], .big);
                switch (code) {
                    0 => break, // AuthenticationOk
                    10 => {
                        var nonce: [24]u8 = undefined;
                        scram.randomNonce(&nonce);
                        state = scram.Scram.init(password, &nonce);

                        var first_buf: [160]u8 = undefined;
                        const client_first = state.?.clientFirst(&first_buf);
                        var len_be: [4]u8 = undefined;
                        std.mem.writeInt(u32, &len_be, @intCast(client_first.len), .big);

                        try sendSasl(fd, 'p', &.{ "SCRAM-SHA-256", &[_]u8{0}, &len_be, client_first });
                    },
                    11 => {
                        const client_final = try state.?.handleServerFirst(msg.payload[4..]);
                        try sendSasl(fd, 'p', &.{client_final});
                    },
                    12 => {}, // AuthenticationSASLFinal, server signature not verified in the PoC
                    else => return error.UnsupportedAuth,
                }
            },
            'E' => return error.ServerError,
            else => {}, // ParameterStatus / BackendKeyData / NoticeResponse
        }
    }

    try waitReady(fd, &scratch);

    return fd;
}

fn waitReady(fd: Fd, scratch: []u8) !void {
    while (true) {
        const msg = try readMessage(fd, scratch);
        if (msg.tag == 'E') return error.ServerError;
        if (msg.tag == 'Z') return;
    }
}

/// Encode a Simple Query ('Q') into out. Returns the total byte length.
pub fn encodeQuery(sql: []const u8, out: []u8) usize {
    const len: u32 = @intCast(4 + sql.len + 1);
    out[0] = 'Q';
    std.mem.writeInt(u32, out[1..5], len, .big);
    @memcpy(out[5..][0..sql.len], sql);
    out[5 + sql.len] = 0;

    return 6 + sql.len;
}

pub const ScanResult = struct { ready: usize, consumed: usize, failed: bool };

/// Scan complete backend messages in bytes, counting ReadyForQuery ('Z')
/// boundaries. One 'Z' marks one completed request (a query or a multi-statement
/// transaction). Stops at the last complete message, so the caller keeps the
/// trailing partial bytes and rescans after the next read.
pub fn scan(bytes: []const u8) ScanResult {
    var pos: usize = 0;
    var ready: usize = 0;
    var failed = false;

    while (pos + 5 <= bytes.len) {
        const len = std.mem.readInt(u32, bytes[pos + 1 ..][0..4], .big);
        const total = 1 + len;
        if (pos + total > bytes.len) break;

        const tag = bytes[pos];
        if (tag == 'Z') ready += 1;
        if (tag == 'E') failed = true;
        pos += total;
    }

    return .{ .ready = ready, .consumed = pos, .failed = failed };
}
