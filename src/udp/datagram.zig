//! zix udp raw datagram I/O primitives (ADR-049).
//!
//! What:
//! - A bound IPv4 UDP socket plus batched receive / send over recvmmsg / sendmmsg, the building
//!   blocks for the raw-bytes datagram path (`zix.Udp.Raw`). Address conversion helpers are portable
//!   and unit-tested. The batched syscalls are Linux-only (the raw server falls back elsewhere).
//!
//! Note:
//! - recvmmsg fills one sockaddr per datagram, so a reply to the sender reuses that address with no
//!   conversion. Conversion to / from `std.Io.net.IpAddress` happens only for the handler view and
//!   for replies addressed to a peer other than the sender.

const std = @import("std");
const builtin = @import("builtin");

const linux = std.os.linux;
const posix = std.posix;

const IpAddress = std.Io.net.IpAddress;

/// Whether the batched-syscall path is available on this target.
pub const is_linux = builtin.os.tag == .linux;

const sockaddr_in_len: posix.socklen_t = @sizeOf(posix.sockaddr.in);

// --------------------------------------------------------- //

/// Build a `sockaddr.in` from a parsed IPv4 address. The 4 address bytes map directly to the
/// network-order `addr` field, and the port is stored big-endian.
pub fn ip4ToSockaddr(ip: IpAddress) posix.sockaddr.in {
    return switch (ip) {
        .ip4 => |a| .{ .port = std.mem.nativeToBig(u16, a.port), .addr = @bitCast(a.bytes) },
        .ip6 => unreachable,
    };
}

/// Recover an IPv4 `std.Io.net.IpAddress` from a `sockaddr.in` the kernel filled in.
pub fn sockaddrToIp4(sa: posix.sockaddr.in) IpAddress {
    return .{ .ip4 = .{ .bytes = @bitCast(sa.addr), .port = std.mem.bigToNative(u16, sa.port) } };
}

/// Parse a bind address string ("0.0.0.0", "127.0.0.1") into a `sockaddr.in`.
pub fn parseBind(ip: []const u8, port: u16) !posix.sockaddr.in {
    const parsed = try IpAddress.parse(ip, port);

    return ip4ToSockaddr(parsed);
}

/// Open a bound IPv4 UDP socket. When `reuse` is set, SO_REUSEADDR + SO_REUSEPORT let many workers
/// bind the same port and the kernel load-balances datagrams across them. Socket / bind are raw
/// Linux syscalls (std.posix no longer wraps them since the std.Io migration). setsockopt is the
/// std.posix safe wrapper which remains.
pub fn open(ip: []const u8, port: u16, reuse: bool) !posix.socket_t {
    const srv = linux.socket(linux.AF.INET, linux.SOCK.DGRAM, linux.IPPROTO.UDP);
    switch (posix.errno(srv)) {
        .SUCCESS => {},
        else => return error.SocketFailed,
    }

    const fd: posix.socket_t = @intCast(srv);
    errdefer close(fd);

    if (reuse) {
        const one = std.mem.toBytes(@as(c_int, 1));
        posix.setsockopt(fd, linux.SOL.SOCKET, linux.SO.REUSEADDR, &one) catch {};
        posix.setsockopt(fd, linux.SOL.SOCKET, linux.SO.REUSEPORT, &one) catch return error.ReusePortFailed;
    }

    var addr = try parseBind(ip, port);
    const brv = linux.bind(fd, @ptrCast(&addr), sockaddr_in_len);
    switch (posix.errno(brv)) {
        .SUCCESS => {},
        else => return error.BindFailed,
    }

    return fd;
}

/// Close a raw socket descriptor.
pub fn close(fd: posix.socket_t) void {
    _ = linux.close(fd);
}

// --------------------------------------------------------- //

/// A received datagram: the payload bytes plus the sender address as the kernel reported it.
pub const Datagram = struct { data: []const u8, from: posix.sockaddr.in };

/// A reusable receive batch: one backing buffer carved into `count` MTU-sized slots, wired into the
/// mmsghdr / iovec / name arrays recvmmsg writes into.
pub const RecvBatch = struct {
    allocator: std.mem.Allocator,
    data: []u8,
    names: []posix.sockaddr.in,
    iovs: []posix.iovec,
    hdrs: []linux.mmsghdr,
    slot_size: usize,
    received: usize = 0,

    /// Allocate a batch of `count` slots, each `slot_size` bytes wide.
    pub fn init(allocator: std.mem.Allocator, count: usize, slot_size: usize) !RecvBatch {
        const data = try allocator.alloc(u8, count * slot_size);
        errdefer allocator.free(data);

        const names = try allocator.alloc(posix.sockaddr.in, count);
        errdefer allocator.free(names);

        const iovs = try allocator.alloc(posix.iovec, count);
        errdefer allocator.free(iovs);

        const hdrs = try allocator.alloc(linux.mmsghdr, count);
        errdefer allocator.free(hdrs);

        for (0..count) |i| {
            iovs[i] = .{ .base = data.ptr + i * slot_size, .len = slot_size };
            hdrs[i] = .{
                .hdr = .{
                    .name = @ptrCast(&names[i]),
                    .namelen = sockaddr_in_len,
                    .iov = @ptrCast(&iovs[i]),
                    .iovlen = 1,
                    .control = null,
                    .controllen = 0,
                    .flags = 0,
                },
                .len = 0,
            };
        }

        return .{ .allocator = allocator, .data = data, .names = names, .iovs = iovs, .hdrs = hdrs, .slot_size = slot_size };
    }

    pub fn deinit(self: *RecvBatch) void {
        self.allocator.free(self.data);
        self.allocator.free(self.names);
        self.allocator.free(self.iovs);
        self.allocator.free(self.hdrs);
    }

    /// Receive up to `count` datagrams in one syscall. MSG_WAITFORONE returns as soon as at least
    /// one datagram is available (without it, recvmmsg would block for the whole batch). A signal
    /// interruption yields 0 (the caller loops).
    pub fn recv(self: *RecvBatch, fd: posix.socket_t) !usize {
        const rc = linux.recvmmsg(fd, self.hdrs.ptr, @intCast(self.hdrs.len), linux.MSG.WAITFORONE, null);
        switch (posix.errno(rc)) {
            .SUCCESS => {},
            .INTR => return 0,
            else => return error.RecvFailed,
        }

        self.received = rc;

        return rc;
    }

    /// The i-th received datagram. Valid for i < the count returned by `recv`.
    pub fn get(self: *const RecvBatch, i: usize) Datagram {
        return .{ .data = self.data[i * self.slot_size ..][0..self.hdrs[i].len], .from = self.names[i] };
    }
};

/// A reusable send batch: queued replies copied into a backing buffer and flushed via sendmmsg. The
/// copy keeps replies valid even when the handler hands back bytes that live in the receive buffer.
pub const SendBatch = struct {
    allocator: std.mem.Allocator,
    data: []u8,
    names: []posix.sockaddr.in,
    iovs: []posix.iovec,
    hdrs: []linux.mmsghdr,
    cap: usize,
    used: usize = 0,
    count: usize = 0,

    /// Allocate a batch holding up to `count` replies totalling `buf_bytes` payload bytes.
    pub fn init(allocator: std.mem.Allocator, count: usize, buf_bytes: usize) !SendBatch {
        const data = try allocator.alloc(u8, buf_bytes);
        errdefer allocator.free(data);

        const names = try allocator.alloc(posix.sockaddr.in, count);
        errdefer allocator.free(names);

        const iovs = try allocator.alloc(posix.iovec, count);
        errdefer allocator.free(iovs);

        const hdrs = try allocator.alloc(linux.mmsghdr, count);
        errdefer allocator.free(hdrs);

        return .{ .allocator = allocator, .data = data, .names = names, .iovs = iovs, .hdrs = hdrs, .cap = count };
    }

    pub fn deinit(self: *SendBatch) void {
        self.allocator.free(self.data);
        self.allocator.free(self.names);
        self.allocator.free(self.iovs);
        self.allocator.free(self.hdrs);
    }

    /// Queue one reply to `dest`. Returns false when the batch is full (by count or by payload
    /// bytes), signalling the caller to flush and retry.
    pub fn queue(self: *SendBatch, dest: posix.sockaddr.in, bytes: []const u8) bool {
        if (self.count >= self.cap) return false;
        if (self.used + bytes.len > self.data.len) return false;

        @memcpy(self.data[self.used..][0..bytes.len], bytes);
        self.names[self.count] = dest;
        self.iovs[self.count] = .{ .base = self.data.ptr + self.used, .len = bytes.len };
        self.hdrs[self.count] = .{
            .hdr = .{
                .name = @ptrCast(&self.names[self.count]),
                .namelen = sockaddr_in_len,
                .iov = @ptrCast(&self.iovs[self.count]),
                .iovlen = 1,
                .control = null,
                .controllen = 0,
                .flags = 0,
            },
            .len = 0,
        };

        self.used += bytes.len;
        self.count += 1;

        return true;
    }

    /// Send every queued reply, then reset the batch. Handles partial sends and signal interruption.
    pub fn flush(self: *SendBatch, fd: posix.socket_t) !void {
        var sent: usize = 0;
        while (sent < self.count) {
            const rc = linux.sendmmsg(fd, self.hdrs.ptr + sent, @intCast(self.count - sent), 0);
            switch (posix.errno(rc)) {
                .SUCCESS => {},
                .INTR => continue,
                else => return error.SendFailed,
            }
            if (rc == 0) break;
            sent += rc;
        }

        self.reset();
    }

    /// Drop all queued replies without sending.
    pub fn reset(self: *SendBatch) void {
        self.used = 0;
        self.count = 0;
    }
};

// --------------------------------------------------------- //
// --------------------------------------------------------- //

test "zix test: datagram, ip4 address round trips through sockaddr.in" {
    const ip = try std.Io.net.IpAddress.parse("127.0.0.1", 9070);
    const sa = ip4ToSockaddr(ip);

    try std.testing.expectEqual(@as(u16, std.mem.nativeToBig(u16, 9070)), sa.port);

    const back = sockaddrToIp4(sa);
    try std.testing.expectEqual(@as(u16, 9070), back.ip4.port);
    try std.testing.expectEqualSlices(u8, &.{ 127, 0, 0, 1 }, &back.ip4.bytes);
}

test "zix test: datagram, parseBind accepts dotted-quad" {
    const sa = try parseBind("10.0.0.1", 53);
    try std.testing.expectEqual(@as(u16, std.mem.nativeToBig(u16, 53)), sa.port);
    try std.testing.expectEqualSlices(u8, &.{ 10, 0, 0, 1 }, &@as([4]u8, @bitCast(sa.addr)));
}

test "zix test: SendBatch queues replies and reports full" {
    var batch = try SendBatch.init(std.testing.allocator, 2, 32);
    defer batch.deinit();

    const dest = try parseBind("127.0.0.1", 1234);
    try std.testing.expect(batch.queue(dest, "ab"));
    try std.testing.expect(batch.queue(dest, "cde"));
    try std.testing.expectEqual(@as(usize, 2), batch.count);

    // Third queue exceeds the 2-slot cap.
    try std.testing.expect(!batch.queue(dest, "f"));

    // The payload bytes were copied in order.
    try std.testing.expectEqualStrings("abcde", batch.data[0..batch.used]);
    try std.testing.expectEqual(@as(usize, 2), batch.iovs[0].len);
    try std.testing.expectEqual(@as(usize, 3), batch.iovs[1].len);

    batch.reset();
    try std.testing.expectEqual(@as(usize, 0), batch.count);
    try std.testing.expectEqual(@as(usize, 0), batch.used);
}

test "zix test: SendBatch rejects an oversized payload" {
    var batch = try SendBatch.init(std.testing.allocator, 4, 4);
    defer batch.deinit();

    const dest = try parseBind("127.0.0.1", 1234);
    try std.testing.expect(batch.queue(dest, "abcd"));
    try std.testing.expect(!batch.queue(dest, "x"));
}

test "zix test: RecvBatch allocates slots and wires headers" {
    var batch = try RecvBatch.init(std.testing.allocator, 4, 1500);
    defer batch.deinit();

    try std.testing.expectEqual(@as(usize, 4), batch.hdrs.len);
    try std.testing.expectEqual(@as(usize, 1500), batch.iovs[0].len);
    try std.testing.expectEqual(@as(usize, 4 * 1500), batch.data.len);
    try std.testing.expectEqual(@as(usize, 1), batch.hdrs[0].hdr.iovlen);
}
