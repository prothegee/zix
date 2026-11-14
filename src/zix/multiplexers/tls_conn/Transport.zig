//! ZIX multiplexers tls transport
//!
//! ### file: src/zix/multiplexers/tls_conn/Transport.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! The TLS byte transport of one multiplexed connection: the resumable session
//! plus the outbound ciphertext buffer staged on EAGAIN and flushed on EPOLLOUT.
//!
//! ### note:
//!
//! TLS records must reach the peer in order (the AEAD nonce is the record
//! sequence number). Once bytes are staged, every later send appends behind them.
//! Linux only: the writes go straight to the descriptor.
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
const tlz = @import("tlz");
const Session = @import("../../tls/tls_session/Session.zig");
const tls_conn = @import("../tls_conn.zig");

const linux = std.os.linux;

// --------------------------------------------------------- //
// Fields:

fd: std.posix.fd_t,
tls: Session,

/// Outbound ciphertext staged on EAGAIN. wbuf is the capacity, the live bytes
/// are wbuf[woff..wlen], so a grown buffer never sends its uninitialized tail.
wbuf: []u8 = &.{},
woff: usize = 0,
wlen: usize = 0,
/// Close once the staged bytes are flushed.
wclose: bool = false,
/// EPOLLOUT must be armed for this connection.
want_out: bool = false,

/// First wbuf allocation size.
wbuf_initial: usize = tls_conn.WRITE_BUF_INITIAL,

/// The epoll data word this connection was registered with. A dual-listener
/// loop tags TLS events here, so an EPOLLOUT re-arm keeps the tag.
ep_data: u64 = 0,

/// A ring send owns wbuf[woff..wlen] right now. While set the live bytes never
/// move: no compaction, and a grown buffer keeps the old one in retired.
inflight: bool = false,
/// The buffer an in-flight ring send still reads after a grow. Freed by
/// releaseRetired once that send completes.
retired: []u8 = &.{},

/// Owns wbuf and retired.
allocator: std.mem.Allocator = std.heap.smp_allocator,

const Self = @This();

// --------------------------------------------------------- //
// Private:

/// Append unsent ciphertext to the staged buffer, growing it as needed.
fn stageWrite(self: *Self, bytes: []const u8) void {
    const pending = self.wlen - self.woff;

    // Room already at the tail: append in place.
    if (self.wbuf.len - self.wlen >= bytes.len) {
        @memcpy(self.wbuf[self.wlen..][0..bytes.len], bytes);
        self.wlen += bytes.len;
        self.want_out = true;

        return;
    }

    const need = pending + bytes.len;

    // Compaction alone makes room: slide the live bytes to the front. Not while
    // a ring send reads them.
    if (!self.inflight and self.wbuf.len >= need) {
        std.mem.copyForwards(u8, self.wbuf[0..pending], self.wbuf[self.woff..self.wlen]);
        self.woff = 0;
        self.wlen = pending;

        @memcpy(self.wbuf[self.wlen..][0..bytes.len], bytes);
        self.wlen += bytes.len;
        self.want_out = true;

        return;
    }

    var new_cap: usize = if (self.wbuf.len == 0) self.wbuf_initial else self.wbuf.len * 2;
    while (new_cap < need) new_cap *= 2;

    const grown = self.allocator.alloc(u8, new_cap) catch |err| switch (err) {
        error.OutOfMemory => {
            self.wclose = true;

            return;
        },
    };

    @memcpy(grown[0..pending], self.wbuf[self.woff..self.wlen]);
    if (self.inflight and self.retired.len == 0) {
        self.retired = self.wbuf;
    } else if (self.wbuf.len > 0) {
        self.allocator.free(self.wbuf);
    }
    self.wbuf = grown;
    self.woff = 0;
    self.wlen = pending;

    @memcpy(self.wbuf[self.wlen..][0..bytes.len], bytes);
    self.wlen += bytes.len;
    self.want_out = true;
}

// --------------------------------------------------------- //
// Public:

/// Fresh transport for an accepted TLS connection, nothing staged.
///
/// Param:
/// io - std.Io (the CSPRNG for the session randoms)
/// fd - std.posix.fd_t (the accepted, non-blocking socket)
/// ctx - *const tlz.Context (borrowed identity, must outlive the transport)
///
/// Return:
/// - Self
pub fn init(io: std.Io, fd: std.posix.fd_t, ctx: *const tlz.Context) Self {
    return .{
        .fd = fd,
        .tls = Session.init(io, ctx.cert_der, ctx.signing_key, ctx.alpn),
        .ep_data = @intCast(fd),
    };
}

/// Free the staged buffer. The transport itself lives in the engine's
/// connection object.
pub fn deinit(self: *Self) void {
    if (self.wbuf.len > 0) self.allocator.free(self.wbuf);
    self.releaseRetired();

    self.wbuf = &.{};
}

/// Free the buffer an in-flight ring send was reading. Call once it completed.
pub fn releaseRetired(self: *Self) void {
    if (self.retired.len > 0) self.allocator.free(self.retired);

    self.retired = &.{};
}

/// Send bytes from any thread holding the connection lock (a TLS peer).
///
/// Note:
/// - Bytes already staged or in flight: append behind them, the owner flushes
///   them. Otherwise write now and wait out a full socket instead of staging,
///   because another thread cannot ask the owner loop for EPOLLOUT.
///
/// Return:
/// - bool (false when the connection must close)
pub fn sendShared(self: *Self, bytes: []const u8) bool {
    if (self.inflight or self.wlen > self.woff) {
        self.stageWrite(bytes);

        return !self.wclose;
    }

    var off: usize = 0;
    while (off < bytes.len) {
        const rc = linux.write(self.fd, bytes[off..].ptr, bytes.len - off);
        switch (std.posix.errno(rc)) {
            .SUCCESS => {
                if (rc == 0) return false;

                off += rc;
            },
            .INTR => continue,
            .AGAIN => {
                var poll_fds = [_]std.posix.pollfd{.{
                    .fd = self.fd,
                    .events = std.posix.POLL.OUT,
                    .revents = 0,
                }};
                _ = std.posix.poll(&poll_fds, -1) catch |err| switch (err) {
                    else => return false,
                };
            },
            else => return false,
        }
    }

    return true;
}

/// Send bytes now, staging what does not fit and asking for EPOLLOUT.
///
/// Return:
/// - true when sent or staged
/// - false on a fatal write error, the caller closes
pub fn sendRaw(self: *Self, bytes: []const u8) bool {
    if (self.wlen > self.woff) {
        self.stageWrite(bytes);

        return true;
    }

    var off: usize = 0;
    while (off < bytes.len) {
        const rc = linux.write(self.fd, bytes[off..].ptr, bytes.len - off);
        switch (std.posix.errno(rc)) {
            .SUCCESS => {
                if (rc == 0) return false;

                off += rc;
            },
            .INTR => continue,
            .AGAIN => {
                self.stageWrite(bytes[off..]);

                return true;
            },
            else => return false,
        }
    }

    return true;
}

/// Encrypt response plaintext into records and send.
///
/// Note:
/// - An empty seal means sealed was too small for the response. That is a dead
///   connection, not a short read, because a peer cannot tell a truncated body
///   from a complete one.
///
/// Param:
/// plaintext - []const u8 (response bytes)
/// sealed - []u8 (staging for the records, sized by tlz.sealedLen)
///
/// Return:
/// - bool (false when the connection must close)
pub fn sendPlain(self: *Self, plaintext: []const u8, sealed: []u8) bool {
    const cipher = self.tls.encrypt(plaintext, sealed);
    if (cipher.len == 0) return false;

    return self.sendRaw(cipher);
}

/// Encrypt one record gathered from a staged prefix and a payload tail, then
/// send. Records leave in sequence order, like sendPlain.
///
/// Return:
/// - bool (false when the connection must close, an empty seal included)
pub fn sendPlainGather(self: *Self, prefix: []const u8, tail: []const u8, sealed: []u8) bool {
    const cipher = self.tls.encrypt2(prefix, tail, sealed);
    if (cipher.len == 0) return false;

    return self.sendRaw(cipher);
}

/// Flush staged ciphertext on EPOLLOUT.
///
/// Note:
/// - A drained buffer is kept for reuse. Freeing it here churns the allocator
///   under sustained backpressure. deinit releases it.
///
/// Return:
/// - bool (false when the connection must close)
pub fn onWritable(self: *Self, epfd: std.posix.fd_t) bool {
    while (self.woff < self.wlen) {
        const rc = linux.write(self.fd, self.wbuf[self.woff..].ptr, self.wlen - self.woff);
        switch (std.posix.errno(rc)) {
            .SUCCESS => {
                if (rc == 0) return false;

                self.woff += rc;
            },
            .INTR => continue,
            .AGAIN => return true,
            else => return false,
        }
    }

    self.woff = 0;
    self.wlen = 0;
    self.want_out = false;
    tls_conn.armOut(epfd, self.fd, self.ep_data, false);

    return !self.wclose;
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const pair = @import("../../utils/socket/pair.zig");

fn setNonBlockTest(fd: std.posix.fd_t) void {
    const rc = linux.fcntl(fd, linux.F.GETFL, 0);
    var flags: linux.O = @bitCast(@as(u32, @intCast(rc)));
    flags.NONBLOCK = true;
    const bits: u32 = @bitCast(flags);
    _ = linux.fcntl(fd, linux.F.SETFL, @intCast(bits));
}

/// Read what is queued on a non-blocking fd, stopping at EAGAIN.
fn drainFd(fd: std.posix.fd_t, sink: []u8) usize {
    var total: usize = 0;
    while (total < sink.len) {
        const rc = linux.read(fd, sink[total..].ptr, sink.len - total);
        if (std.posix.errno(rc) != .SUCCESS or rc == 0) break;

        total += rc;
    }

    return total;
}

test "zix multiplexers: Transport, sendRaw writes through when the socket has room" {
    if (comptime builtin.os.tag != .linux) return;

    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = linux.close(fds[0]);
    defer _ = linux.close(fds[1]);

    var transport: Self = .{
        .fd = fds[0],
        .tls = undefined,
        .allocator = std.testing.allocator,
    };
    defer transport.deinit();

    try std.testing.expect(transport.sendRaw("hello"));
    try std.testing.expect(!transport.want_out);

    var got: [16]u8 = undefined;
    const rc = linux.read(fds[1], &got, got.len);

    try std.testing.expectEqualStrings("hello", got[0..rc]);
}

test "zix multiplexers: Transport, backpressure stages then flushes in order" {
    if (comptime builtin.os.tag != .linux) return;

    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = linux.close(fds[0]);
    defer _ = linux.close(fds[1]);

    setNonBlockTest(fds[0]);
    setNonBlockTest(fds[1]);
    const tiny: u32 = 1;
    _ = linux.setsockopt(fds[0], linux.SOL.SOCKET, linux.SO.SNDBUF, @ptrCast(&tiny), 4);

    var transport: Self = .{
        .fd = fds[0],
        .tls = undefined,
        .allocator = std.testing.allocator,
    };
    defer transport.deinit();

    const block: [4096]u8 = @splat(0xAB);
    var pushed: usize = 0;
    while (!transport.want_out) {
        try std.testing.expect(transport.sendRaw(&block));
        pushed += block.len;
        try std.testing.expect(pushed < 1024 * 1024);
    }

    try std.testing.expect(transport.sendRaw("tail-marker"));
    pushed += "tail-marker".len;

    const epfd_rc = linux.epoll_create1(linux.EPOLL.CLOEXEC);
    const epfd: std.posix.fd_t = @intCast(epfd_rc);
    defer _ = linux.close(epfd);

    const sink = try std.testing.allocator.alloc(u8, 1024 * 1024);
    defer std.testing.allocator.free(sink);

    var drained: usize = 0;
    while (transport.wlen > transport.woff) {
        drained += drainFd(fds[1], sink[drained..]);
        try std.testing.expect(transport.onWritable(epfd));
    }
    drained += drainFd(fds[1], sink[drained..]);

    try std.testing.expectEqual(pushed, drained);
    try std.testing.expect(!transport.want_out);
    try std.testing.expectEqualStrings("tail-marker", sink[drained - 11 .. drained]);
}

test "zix multiplexers: Transport, stageWrite grows past wbuf_initial" {
    var transport: Self = .{
        .fd = -1,
        .tls = undefined,
        .wbuf_initial = 32,
        .allocator = std.testing.allocator,
    };
    defer transport.deinit();

    transport.stageWrite("0123456789abcdef0123456789abcdef");
    transport.stageWrite("-and-the-overflow-forces-a-grow");

    try std.testing.expect(transport.wbuf.len > 32);
    try std.testing.expect(!transport.wclose);
    try std.testing.expectEqualStrings(
        "0123456789abcdef0123456789abcdef-and-the-overflow-forces-a-grow",
        transport.wbuf[transport.woff..transport.wlen],
    );
}

test "zix multiplexers: Transport, stageWrite compacts before growing" {
    var transport: Self = .{
        .fd = -1,
        .tls = undefined,
        .wbuf_initial = 16,
        .allocator = std.testing.allocator,
    };
    defer transport.deinit();

    transport.stageWrite("0123456789abcdef");
    transport.woff = 10;
    transport.stageWrite("ghij");
    const live = transport.wbuf[transport.woff..transport.wlen];

    try std.testing.expectEqual(@as(usize, 16), transport.wbuf.len);
    try std.testing.expectEqualStrings("abcdefghij", live);
}

test "zix multiplexers: Transport, out of memory marks the connection for close" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{
        .fail_index = 0,
    });
    var transport: Self = .{
        .fd = -1,
        .tls = undefined,
        .allocator = failing.allocator(),
    };
    defer transport.deinit();

    transport.stageWrite("bytes");

    try std.testing.expect(transport.wclose);
    try std.testing.expectEqual(@as(usize, 0), transport.wlen);
}

test "zix multiplexers: Transport, sendRaw on a closed socket fails" {
    if (comptime builtin.os.tag != .linux) return;

    var transport: Self = .{
        .fd = -1,
        .tls = undefined,
        .allocator = std.testing.allocator,
    };
    defer transport.deinit();

    try std.testing.expect(!transport.sendRaw("x"));
}

test "zix multiplexers: Transport, an in-flight grow keeps the old buffer alive" {
    var transport: Self = .{
        .fd = -1,
        .tls = undefined,
        .wbuf_initial = 8,
        .allocator = std.testing.allocator,
    };
    defer transport.deinit();

    transport.stageWrite("01234567");
    const sending = transport.wbuf;
    transport.inflight = true;
    transport.stageWrite("89");

    const live = transport.wbuf[transport.woff..transport.wlen];

    try std.testing.expect(transport.retired.ptr == sending.ptr);
    try std.testing.expectEqualStrings("0123456789", live);

    transport.inflight = false;
    transport.releaseRetired();

    try std.testing.expectEqual(@as(usize, 0), transport.retired.len);
}

test "zix multiplexers: Transport, no compaction while a send is in flight" {
    var transport: Self = .{
        .fd = -1,
        .tls = undefined,
        .wbuf_initial = 16,
        .allocator = std.testing.allocator,
    };
    defer transport.deinit();

    transport.stageWrite("0123456789abcdef");
    transport.woff = 10;
    transport.inflight = true;
    const sending = transport.wbuf;
    transport.stageWrite("ghij");

    const live = transport.wbuf[transport.woff..transport.wlen];

    try std.testing.expect(transport.retired.ptr == sending.ptr);
    try std.testing.expectEqualStrings("abcdefghij", live);
}

test "zix multiplexers: Transport, sendShared appends behind staged bytes" {
    var transport: Self = .{
        .fd = -1,
        .tls = undefined,
        .allocator = std.testing.allocator,
    };
    defer transport.deinit();

    transport.stageWrite("first");

    try std.testing.expect(transport.sendShared("second"));

    const live = transport.wbuf[transport.woff..transport.wlen];
    try std.testing.expectEqualStrings("firstsecond", live);
}

test "zix multiplexers: Transport, sendShared writes through when nothing is staged" {
    if (comptime builtin.os.tag != .linux) return;

    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = linux.close(fds[0]);
    defer _ = linux.close(fds[1]);

    var transport: Self = .{
        .fd = fds[0],
        .tls = undefined,
        .allocator = std.testing.allocator,
    };
    defer transport.deinit();

    try std.testing.expect(transport.sendShared("direct"));

    var got: [16]u8 = undefined;
    const rc = linux.read(fds[1], &got, got.len);

    try std.testing.expectEqualStrings("direct", got[0..rc]);
    try std.testing.expectEqual(@as(usize, 0), transport.wlen);
}

