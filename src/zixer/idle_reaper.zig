//! zixer upstream leg: background sweep that gives aged idle conns back

const std = @import("std");

const upstream_conn = @import("upstream_conn.zig");

/// Gap between two sweeps. Half the age bound, so a conn is handed back
/// within roughly one and a half times IDLE_TTL_MS of going quiet.
pub const SWEEP_INTERVAL_MS: i64 = upstream_conn.IDLE_TTL_MS / 2;

/// Longest the thread sleeps without looking at the stop flag, so stopping a
/// site does not wait out a whole interval.
const WAKE_SLICE_MS: i64 = 100;

/// One thread per site that sweeps every idle cache that site owns.
///
/// Note:
/// - Expiry on acquire only fires when a request arrives, and a site holding
///   connections it is not using is exactly the case with no requests. This
///   is what covers a quiet site.
/// - A site with several workers owns one cache per worker, and one thread
///   sweeps them all. The sweep is a short walk over parked entries, so
///   spending a thread per worker on it would buy nothing.
/// - The reaper must live at a stable address: the thread holds a pointer to
///   it. Both site states that own one are heap allocated.
pub const Reaper = struct {
    /// io and caches are filled by start. A default Reaper is a valid
    /// never-started one, so a site with no idle cache can hold the field
    /// and still call stop on it.
    io: std.Io = undefined,
    caches: []upstream_conn.IdleCache = &.{},
    stop_flag: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,

    /// Start sweeping the given caches.
    ///
    /// Param:
    /// io - std.Io (must outlive the reaper)
    /// caches - []upstream_conn.IdleCache (must outlive the reaper)
    ///
    /// Return:
    /// - void, the thread is running
    /// - any std.Thread.spawn error, the reaper stays unstarted
    pub fn start(reaper: *Reaper, io: std.Io, caches: []upstream_conn.IdleCache) !void {
        reaper.* = .{ .io = io, .caches = caches };

        reaper.thread = try std.Thread.spawn(.{}, sweepLoop, .{reaper});
    }

    /// Stop sweeping and join the thread. Safe on a reaper that never started.
    pub fn stop(reaper: *Reaper) void {
        reaper.stop_flag.store(true, .release);

        if (reaper.thread) |thread| thread.join();
        reaper.thread = null;
    }
};

fn sweepLoop(reaper: *Reaper) void {
    while (!reaper.stop_flag.load(.acquire)) {
        if (!sleepInterval(reaper)) return;

        const now_ms = nowMs(reaper.io);
        for (reaper.caches) |*cache| _ = cache.sweepExpired(reaper.io, now_ms);
    }
}

/// Sleep one interval in slices, false when the site asked to stop.
fn sleepInterval(reaper: *Reaper) bool {
    var slept: i64 = 0;
    while (slept < SWEEP_INTERVAL_MS) : (slept += WAKE_SLICE_MS) {
        const slice = @min(WAKE_SLICE_MS, SWEEP_INTERVAL_MS - slept);
        std.Io.sleep(reaper.io, std.Io.Duration.fromMilliseconds(slice), .awake) catch return false;

        if (reaper.stop_flag.load(.acquire)) return false;
    }

    return true;
}

fn nowMs(io: std.Io) i64 {
    return std.Io.Clock.Timestamp.now(io, .real).raw.toMilliseconds();
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //

test "zix zixer: idle reaper, a quiet site gets its aged conn closed" {
    if (comptime @import("builtin").os.tag != .linux) {
        // non-linux region: the fixture parks a raw socketpair descriptor,
        // which only linux hands out here. Nothing is bound.
        std.log.info("idle reaper test needs linux", .{});

        return;
    }

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var fds: [2]std.posix.fd_t = undefined;
    try std.testing.expectEqual(@as(usize, 0), std.os.linux.socketpair(std.os.linux.AF.UNIX, std.os.linux.SOCK.STREAM, 0, &fds));
    defer _ = std.os.linux.close(fds[1]);

    var cache = try upstream_conn.IdleCache.init(std.testing.allocator, 1);
    defer cache.deinit(std.testing.allocator, io);

    // Parked with a stamp already past the age bound, so the first sweep
    // takes it. No request is ever made against this site.
    const stale_stamp = nowMs(io) - upstream_conn.IDLE_TTL_MS;
    const parked = upstream_conn.UpstreamConn{
        .stream = .{ .socket = .{ .handle = fds[0], .address = .{ .ip4 = .{ .bytes = .{ 0, 0, 0, 0 }, .port = 0 } } } },
        .slot_index = 0,
        .reused = false,
    };
    cache.release(io, parked, stale_stamp);
    try std.testing.expectEqual(@as(usize, 1), cache.totalIdle());

    var reaper: Reaper = undefined;
    try reaper.start(io, (&cache)[0..1]);
    defer reaper.stop();

    var waited: usize = 0;
    while (cache.totalIdle() > 0 and waited < 60) : (waited += 1) {
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(100), .awake) catch break;
    }

    try std.testing.expectEqual(@as(usize, 0), cache.totalIdle());

    // The backend end of that connection saw it close.
    var probe: [1]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), std.os.linux.read(fds[1], &probe, 1));
}

test "zix zixer: idle reaper, stop joins promptly and leaves a fresh conn alone" {
    if (comptime @import("builtin").os.tag != .linux) {
        // non-linux region: the fixture parks a raw socketpair descriptor,
        // which only linux hands out here. Nothing is bound.
        std.log.info("idle reaper stop test needs linux", .{});

        return;
    }

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var fds: [2]std.posix.fd_t = undefined;
    try std.testing.expectEqual(@as(usize, 0), std.os.linux.socketpair(std.os.linux.AF.UNIX, std.os.linux.SOCK.STREAM, 0, &fds));
    defer _ = std.os.linux.close(fds[1]);

    var cache = try upstream_conn.IdleCache.init(std.testing.allocator, 1);
    defer cache.deinit(std.testing.allocator, io);

    const parked = upstream_conn.UpstreamConn{
        .stream = .{ .socket = .{ .handle = fds[0], .address = .{ .ip4 = .{ .bytes = .{ 0, 0, 0, 0 }, .port = 0 } } } },
        .slot_index = 0,
        .reused = false,
    };
    cache.release(io, parked, nowMs(io));

    var reaper: Reaper = undefined;
    try reaper.start(io, (&cache)[0..1]);
    reaper.stop();

    // Stopping inside one interval leaves the fresh conn parked, and a
    // second stop on a joined reaper is harmless.
    try std.testing.expectEqual(@as(usize, 1), cache.totalIdle());
    reaper.stop();
}

test "zix zixer: idle reaper, one thread sweeps every worker cache of a site" {
    if (comptime @import("builtin").os.tag != .linux) {
        // non-linux region: the fixture parks raw socketpair descriptors,
        // which only linux hands out here. Nothing is bound.
        std.log.info("idle reaper multi cache test needs linux", .{});

        return;
    }

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var caches: [3]upstream_conn.IdleCache = undefined;
    for (&caches) |*cache| cache.* = try upstream_conn.IdleCache.initShare(std.testing.allocator, 1, caches.len);
    defer for (&caches) |*cache| cache.deinit(std.testing.allocator, io);

    // One already-aged conn parked in each worker's cache.
    var pairs: [3][2]std.posix.fd_t = undefined;
    defer for (&pairs) |*fds| {
        _ = std.os.linux.close(fds[1]);
    };

    const stale_stamp = nowMs(io) - upstream_conn.IDLE_TTL_MS;
    for (&pairs, &caches) |*fds, *cache| {
        try std.testing.expectEqual(@as(usize, 0), std.os.linux.socketpair(std.os.linux.AF.UNIX, std.os.linux.SOCK.STREAM, 0, fds));
        cache.release(io, .{
            .stream = .{ .socket = .{ .handle = fds[0], .address = .{ .ip4 = .{ .bytes = .{ 0, 0, 0, 0 }, .port = 0 } } } },
            .slot_index = 0,
            .reused = false,
        }, stale_stamp);
    }

    var reaper: Reaper = undefined;
    try reaper.start(io, &caches);
    defer reaper.stop();

    var waited: usize = 0;
    while (waited < 60) : (waited += 1) {
        if (caches[0].totalIdle() + caches[1].totalIdle() + caches[2].totalIdle() == 0) break;

        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(100), .awake) catch break;
    }

    // No cache is left holding a backend connection, not just the first.
    for (&caches) |*cache| try std.testing.expectEqual(@as(usize, 0), cache.totalIdle());

    var probe: [1]u8 = undefined;
    for (&pairs) |*fds| try std.testing.expectEqual(@as(usize, 0), std.os.linux.read(fds[1], &probe, 1));
}
