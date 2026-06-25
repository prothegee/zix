//! zix udp raw datagram I/O primitives (ADR-049).
//!
//! What:
//! - A bound dual-stack (AF_INET6, IPV6_V6ONLY off) UDP socket plus batched receive / send over
//!   recvmmsg / sendmmsg, the building blocks for the raw-bytes datagram path (`zix.Udp.Raw`). One
//!   listener serves IPv4 (as IPv4-mapped) and IPv6 clients. Address conversion helpers are portable
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

const sockaddr_in6_len: posix.socklen_t = @sizeOf(posix.sockaddr.in6);

/// The IPv4-mapped IPv6 prefix (::ffff:0:0 / 96): the first 12 bytes of an IPv4-mapped address.
const v4_mapped_prefix = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff };

// --------------------------------------------------------- //

/// Build a dual-stack `sockaddr.in6` from a parsed address. An IPv4 address is stored in its
/// IPv4-mapped form (::ffff:a.b.c.d), so one AF_INET6 socket with IPV6_V6ONLY off serves both
/// families. The port is stored big-endian.
pub fn ipToSockaddr6(ip: IpAddress) posix.sockaddr.in6 {
    var addr: [16]u8 = @splat(0);
    var port: u16 = undefined;

    switch (ip) {
        .ip4 => |a| {
            @memcpy(addr[0..12], &v4_mapped_prefix);
            @memcpy(addr[12..16], &a.bytes);
            port = a.port;
        },
        .ip6 => |a| {
            @memcpy(&addr, &a.bytes);
            port = a.port;
        },
    }

    return .{ .port = std.mem.nativeToBig(u16, port), .flowinfo = 0, .addr = addr, .scope_id = 0 };
}

/// Recover a `std.Io.net.IpAddress` from a `sockaddr.in6` the kernel filled in. An IPv4-mapped
/// address (::ffff:a.b.c.d) returns as IPv4, a native IPv6 address as IPv6.
pub fn sockaddr6ToIp(sa: posix.sockaddr.in6) IpAddress {
    const port = std.mem.bigToNative(u16, sa.port);
    if (std.mem.eql(u8, sa.addr[0..12], &v4_mapped_prefix)) {
        return .{ .ip4 = .{ .bytes = sa.addr[12..16].*, .port = port } };
    }

    return .{ .ip6 = .{ .bytes = sa.addr, .port = port } };
}

/// Parse a bind address string ("::", "0.0.0.0", "127.0.0.1") into a dual-stack `sockaddr.in6`.
pub fn parseBind(ip: []const u8, port: u16) !posix.sockaddr.in6 {
    const parsed = try IpAddress.parse(ip, port);

    return ipToSockaddr6(parsed);
}

/// Open a bound dual-stack UDP socket (AF_INET6 with IPV6_V6ONLY off, so "::" also accepts IPv4).
/// When `reuse` is set, SO_REUSEADDR + SO_REUSEPORT let many workers
/// bind the same port and the kernel load-balances datagrams across them. Socket / bind are raw
/// Linux syscalls (std.posix no longer wraps them since the std.Io migration). setsockopt is the
/// std.posix safe wrapper which remains.
pub fn open(ip: []const u8, port: u16, reuse: bool) !posix.socket_t {
    const srv = linux.socket(linux.AF.INET6, linux.SOCK.DGRAM, linux.IPPROTO.UDP);
    switch (posix.errno(srv)) {
        .SUCCESS => {},
        else => return error.SocketFailed,
    }

    const fd: posix.socket_t = @intCast(srv);
    errdefer close(fd);

    // Dual-stack: clear IPV6_V6ONLY so an AF_INET6 socket bound to "::" also accepts IPv4 (as
    // IPv4-mapped ::ffff:a.b.c.d). This lets one listener serve clients reaching it over either
    // family, regardless of how the peer resolved the host.
    const off = std.mem.toBytes(@as(c_int, 0));
    posix.setsockopt(fd, linux.IPPROTO.IPV6, linux.IPV6.V6ONLY, &off) catch {};

    if (reuse) {
        const one = std.mem.toBytes(@as(c_int, 1));
        posix.setsockopt(fd, linux.SOL.SOCKET, linux.SO.REUSEADDR, &one) catch {};
        posix.setsockopt(fd, linux.SOL.SOCKET, linux.SO.REUSEPORT, &one) catch return error.ReusePortFailed;
    }

    var addr = try parseBind(ip, port);
    const brv = linux.bind(fd, @ptrCast(&addr), sockaddr_in6_len);
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
pub const Datagram = struct { data: []const u8, from: posix.sockaddr.in6 };

/// A reusable receive batch: one backing buffer carved into `count` MTU-sized slots, wired into the
/// mmsghdr / iovec / name arrays recvmmsg writes into.
pub const RecvBatch = struct {
    allocator: std.mem.Allocator,
    data: []u8,
    names: []posix.sockaddr.in6,
    iovs: []posix.iovec,
    hdrs: []linux.mmsghdr,
    slot_size: usize,
    received: usize = 0,

    /// Allocate a batch of `count` slots, each `slot_size` bytes wide.
    pub fn init(allocator: std.mem.Allocator, count: usize, slot_size: usize) !RecvBatch {
        const data = try allocator.alloc(u8, count * slot_size);
        errdefer allocator.free(data);

        const names = try allocator.alloc(posix.sockaddr.in6, count);
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
                    .namelen = sockaddr_in6_len,
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
    names: []posix.sockaddr.in6,
    iovs: []posix.iovec,
    hdrs: []linux.mmsghdr,
    cap: usize,
    used: usize = 0,
    count: usize = 0,

    /// Allocate a batch holding up to `count` replies totalling `buf_bytes` payload bytes.
    pub fn init(allocator: std.mem.Allocator, count: usize, buf_bytes: usize) !SendBatch {
        const data = try allocator.alloc(u8, buf_bytes);
        errdefer allocator.free(data);

        const names = try allocator.alloc(posix.sockaddr.in6, count);
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
    pub fn queue(self: *SendBatch, dest: posix.sockaddr.in6, bytes: []const u8) bool {
        if (self.count >= self.cap) return false;
        if (self.used + bytes.len > self.data.len) return false;

        @memcpy(self.data[self.used..][0..bytes.len], bytes);
        self.names[self.count] = dest;
        self.iovs[self.count] = .{ .base = self.data.ptr + self.used, .len = bytes.len };
        self.hdrs[self.count] = .{
            .hdr = .{
                .name = @ptrCast(&self.names[self.count]),
                .namelen = sockaddr_in6_len,
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

test "zix test: datagram, ip4 round trips through sockaddr.in6 as IPv4-mapped" {
    const ip = try std.Io.net.IpAddress.parse("127.0.0.1", 9070);
    const sa = ipToSockaddr6(ip);

    try std.testing.expectEqual(@as(u16, std.mem.nativeToBig(u16, 9070)), sa.port);
    // The 4 IPv4 bytes sit after the ::ffff: prefix.
    try std.testing.expectEqualSlices(u8, &v4_mapped_prefix, sa.addr[0..12]);
    try std.testing.expectEqualSlices(u8, &.{ 127, 0, 0, 1 }, sa.addr[12..16]);

    const back = sockaddr6ToIp(sa);
    try std.testing.expectEqual(@as(u16, 9070), back.ip4.port);
    try std.testing.expectEqualSlices(u8, &.{ 127, 0, 0, 1 }, &back.ip4.bytes);
}

test "zix test: datagram, native IPv6 round trips through sockaddr.in6" {
    const ip = try std.Io.net.IpAddress.parse("::1", 9071);
    const sa = ipToSockaddr6(ip);

    const back = sockaddr6ToIp(sa);
    try std.testing.expectEqual(@as(u16, 9071), back.ip6.port);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 }, &back.ip6.bytes);
}

test "zix test: datagram, parseBind accepts dotted-quad and ::" {
    const sa4 = try parseBind("10.0.0.1", 53);
    try std.testing.expectEqual(@as(u16, std.mem.nativeToBig(u16, 53)), sa4.port);
    try std.testing.expectEqualSlices(u8, &.{ 10, 0, 0, 1 }, sa4.addr[12..16]);

    const sa6 = try parseBind("::", 53);
    try std.testing.expectEqualSlices(u8, &(@as([16]u8, @splat(0))), &sa6.addr);
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
