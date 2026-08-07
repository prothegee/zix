//! zixer upstream leg: tcp connect to one upstream and the idle keep-alive cache

const std = @import("std");

const tcp_nodelay = @import("tcp_nodelay.zig");

/// Idle connections kept per upstream slot. More than this closes on release.
pub const IDLE_CAP: usize = 4;

/// One live connection to an upstream, tagged with its pool slot.
pub const UpstreamConn = struct {
    stream: std.Io.net.Stream,
    slot_index: u32,
    /// True when this conn came from the idle cache. A reused conn that fails
    /// before the request body flows gets one fresh reconnect, the upstream
    /// may simply have timed out the idle socket.
    reused: bool,
};

/// Connect to one upstream. Only literal ip addresses are supported, name
/// resolution is not part of the phase 3 upstream leg.
///
/// Note:
/// - No connect timeout: the std.Io.Threaded backend panics on one (TODO in
///   std). A refused port fails fast, a blackholed address waits on the
///   operating system's own limit.
/// - Nagle is turned off here rather than at each caller: the request head
///   and the request body leave as separate writes, and the option rides
///   the socket into the idle cache, so a reused conn keeps it.
///
/// Param:
/// io - std.Io
/// host - []const u8 (literal ipv4 or ipv6 address)
/// port - u16
/// slot_index - u32 (pool slot this conn belongs to)
///
/// Return:
/// - UpstreamConn with reused = false
/// - error.BadUpstreamAddress when host is not a literal ip
/// - any connect error (refused, unreachable)
pub fn connect(io: std.Io, host: []const u8, port: u16, slot_index: u32) !UpstreamConn {
    const addr = std.Io.net.IpAddress.parse(host, port) catch return error.BadUpstreamAddress;

    const stream = try addr.connect(io, .{ .mode = .stream, .protocol = .tcp });
    tcp_nodelay.apply(stream);

    return .{ .stream = stream, .slot_index = slot_index, .reused = false };
}

/// Idle keep-alive connections per upstream slot, so a request after a
/// finished exchange skips the tcp handshake.
///
/// Note:
/// - Guarded by the same short spinlock idiom as the pool: acquire and
///   release run from concurrent edge connection tasks.
pub const IdleCache = struct {
    stacks: []Stack,
    lock_flag: std.atomic.Value(bool) = .init(false),

    const Stack = struct {
        conns: [IDLE_CAP]std.Io.net.Stream,
        len: usize = 0,
    };

    /// One stack per upstream slot.
    pub fn init(allocator: std.mem.Allocator, slot_count: usize) !IdleCache {
        const stacks = try allocator.alloc(Stack, slot_count);
        for (stacks) |*stack| stack.len = 0;

        return .{ .stacks = stacks };
    }

    /// Close every idle conn and free the stacks.
    pub fn deinit(cache: *IdleCache, allocator: std.mem.Allocator, io: std.Io) void {
        for (cache.stacks) |*stack| {
            for (stack.conns[0..stack.len]) |stream| stream.close(io);
        }

        allocator.free(cache.stacks);
    }

    /// Pop an idle conn for slot_index, null when none is cached.
    pub fn acquire(cache: *IdleCache, slot_index: u32) ?UpstreamConn {
        cache.lockAcquire();
        defer cache.lockRelease();

        const stack = &cache.stacks[slot_index];
        if (stack.len == 0) return null;

        stack.len -= 1;

        return .{ .stream = stack.conns[stack.len], .slot_index = slot_index, .reused = true };
    }

    /// Park a still-usable conn for reuse. A full stack closes it instead.
    pub fn release(cache: *IdleCache, io: std.Io, conn: UpstreamConn) void {
        cache.lockAcquire();

        const stack = &cache.stacks[conn.slot_index];
        if (stack.len == IDLE_CAP) {
            cache.lockRelease();
            conn.stream.close(io);

            return;
        }

        stack.conns[stack.len] = conn.stream;
        stack.len += 1;
        cache.lockRelease();
    }

    /// Idle conns currently parked for one slot.
    pub fn idleCount(cache: *IdleCache, slot_index: u32) usize {
        cache.lockAcquire();
        defer cache.lockRelease();

        return cache.stacks[slot_index].len;
    }

    fn lockAcquire(cache: *IdleCache) void {
        while (cache.lock_flag.swap(true, .acquire)) std.atomic.spinLoopHint();
    }

    fn lockRelease(cache: *IdleCache) void {
        cache.lock_flag.store(false, .release);
    }
};

// --------------------------------------------------------- //
// --------------------------------------------------------- //

fn fakeStream(handle: std.posix.fd_t) std.Io.net.Stream {
    return .{ .socket = .{ .handle = handle, .address = .{ .ip4 = .{ .bytes = .{ 0, 0, 0, 0 }, .port = 0 } } } };
}

test "zix zixer: upstream conn, non-literal host is refused before any socket" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    try std.testing.expectError(error.BadUpstreamAddress, connect(io, "backend.local", 3000, 0));
}

test "zix zixer: upstream conn, connect hands back a socket with nagle off" {
    if (comptime @import("builtin").os.tag != .linux) {
        // non-linux region: the option is set the same way, but std has no
        // portable getsockopt in Zig 0.16 to read it back. Nothing is bound.
        std.log.info("upstream conn nodelay readback needs linux", .{});

        return;
    }

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const addr = try std.Io.net.IpAddress.parse("127.0.0.1", 18942);
    var server = try addr.listen(io, .{ .kernel_backlog = 4, .reuse_address = true });
    defer server.deinit(io);

    const conn = try connect(io, "127.0.0.1", 18942, 0);
    defer conn.stream.close(io);
    const accepted = try server.accept(io);
    defer accepted.close(io);

    var value: c_int = -1;
    var value_len: std.os.linux.socklen_t = @sizeOf(c_int);
    const rc = std.os.linux.getsockopt(
        conn.stream.socket.handle,
        std.posix.IPPROTO.TCP,
        std.posix.TCP.NODELAY,
        std.mem.asBytes(&value),
        &value_len,
    );

    try std.testing.expectEqual(std.os.linux.E.SUCCESS, std.os.linux.errno(rc));
    try std.testing.expect(value != 0);
}

test "zix zixer: upstream conn, idle cache round trips a conn per slot" {
    if (comptime @import("builtin").os.tag != .linux) return error.SkipZigTest;

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var fds: [2]std.posix.fd_t = undefined;
    try std.testing.expectEqual(@as(usize, 0), std.os.linux.socketpair(std.os.linux.AF.UNIX, std.os.linux.SOCK.STREAM, 0, &fds));
    defer _ = std.os.linux.close(fds[1]);

    var cache = try IdleCache.init(std.testing.allocator, 2);
    defer cache.deinit(std.testing.allocator, io);

    try std.testing.expectEqual(@as(?UpstreamConn, null), cache.acquire(0));

    cache.release(io, .{ .stream = fakeStream(fds[0]), .slot_index = 0, .reused = false });
    try std.testing.expectEqual(@as(usize, 1), cache.idleCount(0));
    try std.testing.expectEqual(@as(usize, 0), cache.idleCount(1));

    const back = cache.acquire(0).?;
    try std.testing.expect(back.reused);
    try std.testing.expectEqual(fds[0], back.stream.socket.handle);
    try std.testing.expectEqual(@as(usize, 0), cache.idleCount(0));

    // fds[0] goes back in so deinit closes it.
    cache.release(io, back);
}

test "zix zixer: upstream conn, idle cache closes overflow instead of growing" {
    if (comptime @import("builtin").os.tag != .linux) return error.SkipZigTest;

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var cache = try IdleCache.init(std.testing.allocator, 1);
    defer cache.deinit(std.testing.allocator, io);

    var pairs: [IDLE_CAP + 1][2]std.posix.fd_t = undefined;
    for (&pairs) |*fds| {
        try std.testing.expectEqual(@as(usize, 0), std.os.linux.socketpair(std.os.linux.AF.UNIX, std.os.linux.SOCK.STREAM, 0, fds));
        cache.release(io, .{ .stream = fakeStream(fds[0]), .slot_index = 0, .reused = false });
    }
    defer for (&pairs) |*fds| {
        _ = std.os.linux.close(fds[1]);
    };

    try std.testing.expectEqual(@as(usize, IDLE_CAP), cache.idleCount(0));

    // The overflow conn was closed on release: its peer reads EOF.
    var probe: [1]u8 = undefined;
    const got = std.os.linux.read(pairs[IDLE_CAP][1], &probe, 1);
    try std.testing.expectEqual(@as(usize, 0), got);
}
