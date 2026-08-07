//! zixer upstream leg: tcp connect to one upstream and the idle keep-alive cache

const std = @import("std");

const tcp_nodelay = @import("tcp_nodelay.zig");

/// Idle connections kept per upstream slot. More than this closes on release.
pub const IDLE_CAP: usize = 4;

/// Idle connections kept across every slot of one site. A site with many
/// upstreams would otherwise park IDLE_CAP against each of them at once.
pub const TOTAL_IDLE_CAP: usize = 32;

/// How long a parked connection may sit unused before it is closed. An idle
/// pooled connection is capacity taken from the backend, so zixer gives it
/// back rather than holding it for a request that may never come.
pub const IDLE_TTL_MS: i64 = 5_000;

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
/// - Three bounds apply together: per_slot_cap per slot, total_cap across
///   the cache, and IDLE_TTL_MS of age. The two counts stop a burst from
///   parking a backend's capacity, the age stops a quiet site from holding
///   it forever.
/// - A site with several workers gives each worker its own cache through
///   initShare, which divides the counts. The bound is a site bound, not a
///   per-worker one: a backend must not lose more of its capacity just
///   because the edge runs more accept loops.
/// - Closing a socket is a syscall, so every path collects what it will
///   close, releases the lock, and closes after.
pub const IdleCache = struct {
    stacks: []Stack,
    per_slot_cap: usize = IDLE_CAP,
    total_cap: usize = TOTAL_IDLE_CAP,
    total_len: usize = 0,
    lock_flag: std.atomic.Value(bool) = .init(false),

    /// One parked connection and when it was parked.
    const Parked = struct {
        stream: std.Io.net.Stream,
        parked_at_ms: i64,
    };

    const Stack = struct {
        conns: [IDLE_CAP]Parked,
        len: usize = 0,
    };

    /// One stack per upstream slot, holding the whole site's idle bound.
    pub fn init(allocator: std.mem.Allocator, slot_count: usize) !IdleCache {
        return initShare(allocator, slot_count, 1);
    }

    /// One worker's share of the site's idle bound.
    ///
    /// Note:
    /// - worker_count of these caches together park no more connections
    ///   than a single init cache would, so adding workers never takes
    ///   more of a backend's capacity.
    /// - A share never falls below one connection: a worker that could
    ///   park nothing would reconnect on every request.
    ///
    /// Param:
    /// allocator - std.mem.Allocator (owns the stacks)
    /// slot_count - usize (upstreams of this site)
    /// worker_count - usize (accept loops sharing the site bound)
    ///
    /// Return:
    /// - IdleCache with the divided bounds
    pub fn initShare(allocator: std.mem.Allocator, slot_count: usize, worker_count: usize) !IdleCache {
        const stacks = try allocator.alloc(Stack, slot_count);
        for (stacks) |*stack| stack.len = 0;

        const workers = @max(1, worker_count);
        const total_cap = @max(1, TOTAL_IDLE_CAP / workers);

        return .{ .stacks = stacks, .per_slot_cap = @min(IDLE_CAP, total_cap), .total_cap = total_cap };
    }

    /// Close every idle conn and free the stacks.
    pub fn deinit(cache: *IdleCache, allocator: std.mem.Allocator, io: std.Io) void {
        for (cache.stacks) |*stack| {
            for (stack.conns[0..stack.len]) |parked| parked.stream.close(io);
        }

        allocator.free(cache.stacks);
    }

    /// Pop an idle conn for slot_index, null when none is cached.
    ///
    /// Note:
    /// - The stack is last-in-first-out, so the freshest conn comes back
    ///   first. Anything popped past its age is closed instead of handed
    ///   out, which keeps a stale socket out of a live exchange.
    ///
    /// Param:
    /// io - std.Io
    /// slot_index - u32
    /// now_ms - i64 (same clock release stamps with)
    ///
    /// Return:
    /// - ?UpstreamConn with reused = true
    pub fn acquire(cache: *IdleCache, io: std.Io, slot_index: u32, now_ms: i64) ?UpstreamConn {
        var expired: [IDLE_CAP]std.Io.net.Stream = undefined;
        var expired_len: usize = 0;
        var taken: ?std.Io.net.Stream = null;

        cache.lockAcquire();
        const stack = &cache.stacks[slot_index];
        while (stack.len > 0) {
            stack.len -= 1;
            cache.total_len -= 1;

            const parked = stack.conns[stack.len];
            if (now_ms - parked.parked_at_ms >= IDLE_TTL_MS) {
                expired[expired_len] = parked.stream;
                expired_len += 1;
                continue;
            }

            taken = parked.stream;
            break;
        }
        cache.lockRelease();

        for (expired[0..expired_len]) |stream| stream.close(io);

        const stream = taken orelse return null;

        return .{ .stream = stream, .slot_index = slot_index, .reused = true };
    }

    /// Park a still-usable conn for reuse. A full stack, a full site, or a
    /// conn the caller kept past its age closes it instead.
    ///
    /// Param:
    /// io - std.Io
    /// conn - UpstreamConn (the caller gives ownership up either way)
    /// now_ms - i64 (stamped on the entry, drives the age bound)
    pub fn release(cache: *IdleCache, io: std.Io, conn: UpstreamConn, now_ms: i64) void {
        cache.lockAcquire();

        const stack = &cache.stacks[conn.slot_index];
        if (stack.len == cache.per_slot_cap or cache.total_len == cache.total_cap) {
            cache.lockRelease();
            conn.stream.close(io);

            return;
        }

        stack.conns[stack.len] = .{ .stream = conn.stream, .parked_at_ms = now_ms };
        stack.len += 1;
        cache.total_len += 1;
        cache.lockRelease();
    }

    /// Close every parked conn that has sat longer than IDLE_TTL_MS.
    ///
    /// Note:
    /// - This is what a quiet site needs. Expiry on acquire only fires when
    ///   a request arrives, and the site holding connections it is not using
    ///   is exactly the case with no requests.
    ///
    /// Return:
    /// - usize (how many conns this sweep closed)
    pub fn sweepExpired(cache: *IdleCache, io: std.Io, now_ms: i64) usize {
        var expired: [TOTAL_IDLE_CAP]std.Io.net.Stream = undefined;
        var expired_len: usize = 0;

        cache.lockAcquire();
        for (cache.stacks) |*stack| {
            var kept: usize = 0;
            for (stack.conns[0..stack.len]) |parked| {
                if (now_ms - parked.parked_at_ms >= IDLE_TTL_MS and expired_len < expired.len) {
                    expired[expired_len] = parked.stream;
                    expired_len += 1;
                    continue;
                }

                stack.conns[kept] = parked;
                kept += 1;
            }

            cache.total_len -= stack.len - kept;
            stack.len = kept;
        }
        cache.lockRelease();

        for (expired[0..expired_len]) |stream| stream.close(io);

        return expired_len;
    }

    /// Idle conns currently parked for one slot.
    pub fn idleCount(cache: *IdleCache, slot_index: u32) usize {
        cache.lockAcquire();
        defer cache.lockRelease();

        return cache.stacks[slot_index].len;
    }

    /// Idle conns currently parked across every slot of this site.
    pub fn totalIdle(cache: *IdleCache) usize {
        cache.lockAcquire();
        defer cache.lockRelease();

        return cache.total_len;
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

    try std.testing.expectEqual(@as(?UpstreamConn, null), cache.acquire(io, 0, 0));

    cache.release(io, .{ .stream = fakeStream(fds[0]), .slot_index = 0, .reused = false }, 0);
    try std.testing.expectEqual(@as(usize, 1), cache.idleCount(0));
    try std.testing.expectEqual(@as(usize, 0), cache.idleCount(1));
    try std.testing.expectEqual(@as(usize, 1), cache.totalIdle());

    const back = cache.acquire(io, 0, 1).?;
    try std.testing.expect(back.reused);
    try std.testing.expectEqual(fds[0], back.stream.socket.handle);
    try std.testing.expectEqual(@as(usize, 0), cache.idleCount(0));
    try std.testing.expectEqual(@as(usize, 0), cache.totalIdle());

    // fds[0] goes back in so deinit closes it.
    cache.release(io, back, 1);
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
        cache.release(io, .{ .stream = fakeStream(fds[0]), .slot_index = 0, .reused = false }, 0);
    }
    defer for (&pairs) |*fds| {
        _ = std.os.linux.close(fds[1]);
    };

    try std.testing.expectEqual(@as(usize, IDLE_CAP), cache.idleCount(0));
    try std.testing.expectEqual(@as(usize, IDLE_CAP), cache.totalIdle());

    // The overflow conn was closed on release: its peer reads EOF.
    var probe: [1]u8 = undefined;
    const got = std.os.linux.read(pairs[IDLE_CAP][1], &probe, 1);
    try std.testing.expectEqual(@as(usize, 0), got);
}

test "zix zixer: upstream conn, idle cache refuses to park past the site total" {
    if (comptime @import("builtin").os.tag != .linux) {
        // non-linux region: the fixture parks raw socketpair descriptors,
        // which only linux hands out here. Nothing is bound.
        std.log.info("idle cache total bound test needs linux", .{});

        return;
    }

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Enough slots that the per-slot cap alone would allow far more than the
    // site total: the total is what has to stop it.
    const slot_count = TOTAL_IDLE_CAP / IDLE_CAP + 2;
    var cache = try IdleCache.init(std.testing.allocator, slot_count);
    defer cache.deinit(std.testing.allocator, io);

    var pairs: [(TOTAL_IDLE_CAP / IDLE_CAP + 2) * IDLE_CAP][2]std.posix.fd_t = undefined;
    defer for (&pairs) |*fds| {
        _ = std.os.linux.close(fds[1]);
    };

    for (&pairs, 0..) |*fds, i| {
        try std.testing.expectEqual(@as(usize, 0), std.os.linux.socketpair(std.os.linux.AF.UNIX, std.os.linux.SOCK.STREAM, 0, fds));
        cache.release(io, .{ .stream = fakeStream(fds[0]), .slot_index = @intCast(i / IDLE_CAP), .reused = false }, 0);
    }

    try std.testing.expectEqual(TOTAL_IDLE_CAP, cache.totalIdle());

    // The first conn past the site total was closed, so its peer reads EOF.
    var probe: [1]u8 = undefined;
    const got = std.os.linux.read(pairs[TOTAL_IDLE_CAP][1], &probe, 1);
    try std.testing.expectEqual(@as(usize, 0), got);
}

test "zix zixer: upstream conn, an aged conn is closed instead of handed out" {
    if (comptime @import("builtin").os.tag != .linux) {
        // non-linux region: the fixture parks raw socketpair descriptors,
        // which only linux hands out here. Nothing is bound.
        std.log.info("idle cache age bound test needs linux", .{});

        return;
    }

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var fds: [2]std.posix.fd_t = undefined;
    try std.testing.expectEqual(@as(usize, 0), std.os.linux.socketpair(std.os.linux.AF.UNIX, std.os.linux.SOCK.STREAM, 0, &fds));
    defer _ = std.os.linux.close(fds[1]);

    var cache = try IdleCache.init(std.testing.allocator, 1);
    defer cache.deinit(std.testing.allocator, io);

    cache.release(io, .{ .stream = fakeStream(fds[0]), .slot_index = 0, .reused = false }, 1000);

    // Inside the age it comes back, past it the caller is told there is
    // nothing cached and the socket is gone.
    try std.testing.expectEqual(@as(?UpstreamConn, null), cache.acquire(io, 0, 1000 + IDLE_TTL_MS));
    try std.testing.expectEqual(@as(usize, 0), cache.totalIdle());

    var probe: [1]u8 = undefined;
    const got = std.os.linux.read(fds[1], &probe, 1);
    try std.testing.expectEqual(@as(usize, 0), got);
}

test "zix zixer: upstream conn, sweep closes the aged and keeps the fresh" {
    if (comptime @import("builtin").os.tag != .linux) {
        // non-linux region: the fixture parks raw socketpair descriptors,
        // which only linux hands out here. Nothing is bound.
        std.log.info("idle cache sweep test needs linux", .{});

        return;
    }

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var aged: [2]std.posix.fd_t = undefined;
    var fresh: [2]std.posix.fd_t = undefined;
    try std.testing.expectEqual(@as(usize, 0), std.os.linux.socketpair(std.os.linux.AF.UNIX, std.os.linux.SOCK.STREAM, 0, &aged));
    try std.testing.expectEqual(@as(usize, 0), std.os.linux.socketpair(std.os.linux.AF.UNIX, std.os.linux.SOCK.STREAM, 0, &fresh));
    defer _ = std.os.linux.close(aged[1]);
    defer _ = std.os.linux.close(fresh[1]);

    var cache = try IdleCache.init(std.testing.allocator, 2);
    defer cache.deinit(std.testing.allocator, io);

    cache.release(io, .{ .stream = fakeStream(aged[0]), .slot_index = 0, .reused = false }, 0);
    cache.release(io, .{ .stream = fakeStream(fresh[0]), .slot_index = 1, .reused = false }, IDLE_TTL_MS);

    try std.testing.expectEqual(@as(usize, 1), cache.sweepExpired(io, IDLE_TTL_MS));
    try std.testing.expectEqual(@as(usize, 0), cache.idleCount(0));
    try std.testing.expectEqual(@as(usize, 1), cache.idleCount(1));
    try std.testing.expectEqual(@as(usize, 1), cache.totalIdle());

    // The aged peer sees EOF, the fresh one is still open.
    var probe: [1]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), std.os.linux.read(aged[1], &probe, 1));

    const fresh_conn = cache.acquire(io, 1, IDLE_TTL_MS).?;
    try std.testing.expectEqual(fresh[0], fresh_conn.stream.socket.handle);
    cache.release(io, fresh_conn, IDLE_TTL_MS);
}

test "zix zixer: upstream conn, a worker share divides the site idle bound" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // One worker keeps the whole site bound, which is what init means.
    var alone = try IdleCache.initShare(std.testing.allocator, 1, 1);
    defer alone.deinit(std.testing.allocator, io);
    try std.testing.expectEqual(TOTAL_IDLE_CAP, alone.total_cap);
    try std.testing.expectEqual(IDLE_CAP, alone.per_slot_cap);

    // Eight workers hold an eighth each, so the site total is unchanged.
    var shared = try IdleCache.initShare(std.testing.allocator, 1, 8);
    defer shared.deinit(std.testing.allocator, io);
    try std.testing.expectEqual(TOTAL_IDLE_CAP / 8, shared.total_cap);
    try std.testing.expectEqual(@as(usize, 8) * shared.total_cap, TOTAL_IDLE_CAP);

    // The per-slot cap never sits above the total a worker may hold.
    try std.testing.expect(shared.per_slot_cap <= shared.total_cap);
}

test "zix zixer: upstream conn, a worker share never falls below one conn" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // More workers than the site bound has room for: a worker that could
    // park nothing would reconnect on every single request.
    var tiny = try IdleCache.initShare(std.testing.allocator, 1, TOTAL_IDLE_CAP * 4);
    defer tiny.deinit(std.testing.allocator, io);

    try std.testing.expectEqual(@as(usize, 1), tiny.total_cap);
    try std.testing.expectEqual(@as(usize, 1), tiny.per_slot_cap);

    // A zero worker count is nonsense a caller should never pass, and it
    // still has to give a usable cache rather than divide by zero.
    var zero = try IdleCache.initShare(std.testing.allocator, 1, 0);
    defer zero.deinit(std.testing.allocator, io);
    try std.testing.expectEqual(TOTAL_IDLE_CAP, zero.total_cap);
}

test "zix zixer: upstream conn, a share cache stops parking at its own total" {
    if (comptime @import("builtin").os.tag != .linux) {
        // non-linux region: the fixture parks raw socketpair descriptors,
        // which only linux hands out here. Nothing is bound.
        std.log.info("idle cache worker share bound test needs linux", .{});

        return;
    }

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Four workers, so this cache holds a quarter of the site bound.
    const share = TOTAL_IDLE_CAP / 4;
    var cache = try IdleCache.initShare(std.testing.allocator, share + 1, 4);
    defer cache.deinit(std.testing.allocator, io);

    var pairs: [TOTAL_IDLE_CAP / 4 + 1][2]std.posix.fd_t = undefined;
    defer for (&pairs) |*fds| {
        _ = std.os.linux.close(fds[1]);
    };

    // One conn per slot, so only the share bound can stop the last one.
    for (&pairs, 0..) |*fds, i| {
        try std.testing.expectEqual(@as(usize, 0), std.os.linux.socketpair(std.os.linux.AF.UNIX, std.os.linux.SOCK.STREAM, 0, fds));
        cache.release(io, .{ .stream = fakeStream(fds[0]), .slot_index = @intCast(i), .reused = false }, 0);
    }

    try std.testing.expectEqual(share, cache.totalIdle());

    // The one past the share was closed, so its peer reads EOF.
    var probe: [1]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), std.os.linux.read(pairs[share][1], &probe, 1));
}
