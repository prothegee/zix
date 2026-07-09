//! zix http2 dispatch: shared helpers across the dispatch models (ADR-043).
//! ConnQueue and the accept-side worker are route-agnostic. The pieces that call
//! core.serveConn(routes, ...) need the comptime route table, so they live in
//! Dispatch(routes).

const std = @import("std");
const builtin = @import("builtin");
const core = @import("../core.zig");
const frame = @import("../frame.zig");
const Http2ServerConfig = @import("../config.zig").Http2ServerConfig;
const Route = core.Route;

// --------------------------------------------------------- //

/// Emit a server lifecycle line. Routes through cfg.logger when set, otherwise
/// prints to stderr only in Debug builds (silent in release).
pub fn logSystem(cfg: Http2ServerConfig, comptime fmt: []const u8, args: anytype) void {
    if (cfg.logger) |lg| {
        lg.system(.INFO, "http2", fmt, args);
        return;
    }

    if (comptime builtin.mode == .Debug) std.debug.print("zix http2: " ++ fmt ++ "\n", args);
}

/// Build the per-connection serve options from the server config.
pub fn serveOpts(cfg: Http2ServerConfig) core.ServeOpts {
    return .{
        .max_streams = cfg.max_streams,
        .max_frame_size = cfg.max_frame_size,
        .max_header_scratch = cfg.max_header_scratch,
        .max_body = cfg.max_body,
        .conn_read_buf_min = cfg.max_recv_buf,
        .tls_write_buf_initial = cfg.tls_write_buf_initial_bytes,
        .response_cache = cfg.response_cache,
        .cache_max_entries = cfg.cache_max_entries,
        .cache_max_value_bytes = cfg.cache_max_value_bytes,
        .cache_ttl_ms = cfg.cache_ttl_ms,
        .cache_max_total_bytes = cfg.cache_max_total_bytes,
    };
}

/// Effective cache slot count for a worker, honoring cache_max_total_bytes. When a memory ceiling is
/// set, the entry count is reduced so the slab (entries * value_bytes) fits. ResponseCache.init then
/// rounds down to a power of two, so the slab never exceeds the ceiling. Mirrors zix.Grpc.
pub fn effectiveCacheEntries(opts: core.ServeOpts) u32 {
    if (opts.cache_max_total_bytes == 0) return opts.cache_max_entries;

    const value_bytes: usize = @max(1, opts.cache_max_value_bytes);
    const fit = opts.cache_max_total_bytes / value_bytes;
    const capped = @min(@as(usize, opts.cache_max_entries), fit);

    return @intCast(@max(@as(usize, 1), capped));
}

/// Highest fd a worker's mux table can index (EPOLL / URING models). Linux hands out the lowest
/// free fd, so the table stays sparse. Connections on fds at or above this are refused.
pub const MAX_FD: usize = 1 << 16;

/// Disable Nagle on a TCP socket so small h2 frames leave promptly.
pub fn setNoDelay(fd: std.posix.fd_t) void {
    if (comptime builtin.target.os.tag != .windows) {
        std.posix.setsockopt(
            fd,
            std.posix.IPPROTO.TCP,
            std.posix.TCP.NODELAY,
            std.mem.asBytes(&@as(c_int, 1)),
        ) catch {};
    }
}

/// Put a socket in non-blocking mode (listener and accepted fds in the event-driven paths).
pub fn setNonBlock(fd: std.posix.fd_t) void {
    const linux = std.os.linux;
    const cur = linux.fcntl(fd, std.posix.F.GETFL, 0);
    const nonblock: u32 = @bitCast(std.posix.O{ .NONBLOCK = true });
    _ = linux.fcntl(fd, std.posix.F.SETFL, cur | @as(usize, nonblock));
}

/// Spin up to `us` microseconds before the worker sleeps on a connection socket (SO_BUSY_POLL),
/// trading CPU for lower wake-up latency on saturated loopback benchmarks. us = 0 leaves it unset
/// (no syscall). Silent no-op when the kernel lacks SO_BUSY_POLL. Mirrors zix.Http1's setBusyPoll.
pub fn setBusyPoll(fd: std.posix.fd_t, us: u32) void {
    if (us == 0) return;

    const SO_BUSY_POLL: u32 = 46;
    std.posix.setsockopt(
        fd,
        std.posix.SOL.SOCKET,
        SO_BUSY_POLL,
        std.mem.asBytes(&@as(c_int, @intCast(us))),
    ) catch {};
}

// --------------------------------------------------------- //

/// Per-worker write-coalescing buffer for the cleartext h2 mux. Installed as the frame write hook
/// (`frame.write_hook`) around one readable batch, so every frame the mux writes (HEADERS, DATA,
/// SETTINGS, WINDOW_UPDATE) stages into one buffer and leaves as a single write per batch instead of
/// one write per frame. With TCP_NODELAY on, the unbatched path emitted a separate tiny TCP segment
/// per frame, so a 100-stream h2load batch cost about 200 segments and trailed the TLS mux (which
/// already coalesces into TLS records). The buffer flushes when full and writes an oversized frame
/// straight through, so correctness never depends on the buffer being large enough. One worker thread
/// owns it, so no synchronization is needed.
const MUX_COALESCE_BUF: usize = 64 * 1024;

const MuxCoalesceSink = struct {
    fd: std.posix.fd_t = -1,
    len: usize = 0,
    failed: bool = false,
    buf: [MUX_COALESCE_BUF]u8 = undefined,

    fn append(self: *MuxCoalesceSink, bytes: []const u8) void {
        if (bytes.len > self.buf.len) {
            self.flush();
            frame.writeAllRawFD(self.fd, bytes) catch {
                self.failed = true;
            };

            return;
        }

        if (self.len + bytes.len > self.buf.len) self.flush();

        @memcpy(self.buf[self.len..][0..bytes.len], bytes);
        self.len += bytes.len;
    }

    fn flush(self: *MuxCoalesceSink) void {
        if (self.len == 0) return;

        frame.writeAllRawFD(self.fd, self.buf[0..self.len]) catch {
            self.failed = true;
        };
        self.len = 0;
    }
};

/// Per-worker coalescing sink. A threadlocal so each mux worker owns one, reused across the
/// connections it serves (only one connection's batch is in flight at a time on a worker).
threadlocal var tl_mux_sink: MuxCoalesceSink = .{};

fn muxCoalesceWrite(ctx: *anyopaque, bytes: []const u8) void {
    const sink: *MuxCoalesceSink = @ptrCast(@alignCast(ctx));
    sink.append(bytes);
}

/// Install the per-worker coalescing sink as the frame write hook for one readable batch. Pair every
/// call with endCoalesce (use defer). While installed, mux frame writes stage instead of hitting the
/// socket per frame.
pub fn beginCoalesce(fd: std.posix.fd_t) void {
    tl_mux_sink.fd = fd;
    tl_mux_sink.len = 0;
    tl_mux_sink.failed = false;
    frame.write_hook = muxCoalesceWrite;
    frame.write_hook_ctx = &tl_mux_sink;
}

/// Flush the staged batch and uninstall the hook.
///
/// Return:
/// - bool (true when a write failed during the batch, so the caller should close the connection)
pub fn endCoalesce() bool {
    tl_mux_sink.flush();
    frame.write_hook = null;
    frame.write_hook_ctx = null;

    return tl_mux_sink.failed;
}

// --------------------------------------------------------- //

pub const ConnQueue = struct {
    mutex: std.Io.Mutex = .init,
    ready: std.Io.Condition = .init,
    buf: []std.posix.fd_t = &.{},
    head: usize = 0,
    len: usize = 0,
    closed: bool = false,

    pub fn push(self: *ConnQueue, fd: std.posix.fd_t, io: std.Io) void {
        self.mutex.lockUncancelable(io);
        if (self.len == self.buf.len) {
            const new_cap = if (self.buf.len == 0) 16 else self.buf.len * 2;
            const new_buf = std.heap.smp_allocator.alloc(std.posix.fd_t, new_cap) catch {
                self.mutex.unlock(io);
                _ = std.os.linux.close(fd);
                return;
            };
            if (self.buf.len > 0) {
                for (0..self.len) |i| new_buf[i] = self.buf[(self.head + i) % self.buf.len];
                std.heap.smp_allocator.free(self.buf);
            }
            self.buf = new_buf;
            self.head = 0;
        }
        self.buf[(self.head + self.len) % self.buf.len] = fd;
        self.len += 1;
        self.mutex.unlock(io);
        self.ready.signal(io);
    }

    pub fn pop(self: *ConnQueue, io: std.Io) ?std.posix.fd_t {
        self.mutex.lockUncancelable(io);
        while (self.len == 0) {
            if (self.closed) {
                self.mutex.unlock(io);
                return null;
            }
            self.ready.waitUncancelable(io, &self.mutex);
        }
        const fd = self.buf[self.head];
        self.head = (self.head + 1) % self.buf.len;
        self.len -= 1;
        self.mutex.unlock(io);
        return fd;
    }

    pub fn close(self: *ConnQueue, io: std.Io) void {
        self.mutex.lockUncancelable(io);
        self.closed = true;
        self.mutex.unlock(io);
        self.ready.broadcast(io);
    }

    pub fn deinit(self: *ConnQueue) void {
        if (self.buf.len > 0) std.heap.smp_allocator.free(self.buf);
    }
};

// --------------------------------------------------------- //

pub const WorkerCtx = struct {
    queue: *ConnQueue,
    io: std.Io,
    ip: []const u8,
    port: u16,
    kernel_backlog: u31,
};

pub fn workerEntry(ctx: WorkerCtx) void {
    const addr = std.Io.net.IpAddress.resolve(ctx.io, ctx.ip, ctx.port) catch return;
    var listener = addr.listen(ctx.io, .{
        .reuse_address = true, // SO_REUSEADDR + SO_REUSEPORT on POSIX, required for POOL, applied to all models
        .kernel_backlog = ctx.kernel_backlog,
    }) catch return;
    defer listener.deinit(ctx.io);

    while (true) {
        const stream = listener.accept(ctx.io) catch |err| {
            if (err != error.ConnectionAborted) break;
            continue;
        };
        ctx.queue.push(stream.socket.handle, ctx.io);
    }
}

// --------------------------------------------------------- //

/// Route-table-dependent dispatch helpers. The route set is comptime, so every
/// function that calls core.serveConn(routes, ...) is baked per route table.
pub fn Dispatch(comptime routes: []const Route) type {
    return struct {
        pub const ConnTask = struct {
            fd: std.posix.fd_t,
            opts: core.ServeOpts,
        };

        pub fn dispatchConn(task: ConnTask) void {
            defer _ = std.os.linux.close(task.fd);
            core.serveConn(routes, task.fd, task.opts);
        }

        pub const PoolCtx = struct {
            queue: *ConnQueue,
            io: std.Io,
            opts: core.ServeOpts,
        };

        pub fn poolEntry(ctx: PoolCtx) void {
            while (ctx.queue.pop(ctx.io)) |fd| {
                defer _ = std.os.linux.close(fd);
                core.serveConn(routes, fd, ctx.opts);
            }
        }

        pub const AsyncWorkerCtx = struct {
            io: std.Io,
            ip: []const u8,
            port: u16,
            kernel_backlog: u31,
            opts: core.ServeOpts,
        };

        pub fn asyncWorkerEntry(ctx: AsyncWorkerCtx) void {
            const addr = std.Io.net.IpAddress.resolve(ctx.io, ctx.ip, ctx.port) catch return;
            var listener = addr.listen(ctx.io, .{
                .reuse_address = true, // SO_REUSEADDR + SO_REUSEPORT on POSIX, required for POOL, applied to all models
                .kernel_backlog = ctx.kernel_backlog,
            }) catch return;
            defer listener.deinit(ctx.io);

            while (true) {
                const stream = listener.accept(ctx.io) catch |err| {
                    if (err != error.ConnectionAborted) break;
                    continue;
                };
                _ = ctx.io.async(dispatchConn, .{ConnTask{
                    .fd = stream.socket.handle,
                    .opts = ctx.opts,
                }});
            }
        }
    };
}

/// Pin the calling thread to the CPU slot assigned to worker_id, respecting the cgroup-allowed CPU
/// mask so we never select a CPU the container cannot use. Used by the TLS epoll workers so a
/// cgroup-pinned cpuset does not oversubscribe one core under a handshake storm (mirrors http1).
pub fn pinToCpu(worker_id: usize) void {
    const linux = std.os.linux;
    var cpu_set: linux.cpu_set_t = undefined;
    if (linux.sched_getaffinity(0, @sizeOf(linux.cpu_set_t), &cpu_set) != 0) return;

    var cpu_list: [256]u32 = undefined;
    var n_cpus: usize = 0;
    for (cpu_set, 0..) |word, word_idx| {
        var w = word;
        while (w != 0) : (w &= w - 1) {
            if (n_cpus < cpu_list.len) {
                cpu_list[n_cpus] = @intCast(word_idx * @bitSizeOf(usize) + @ctz(w));
                n_cpus += 1;
            }
        }
    }
    if (n_cpus == 0) return;

    const target = cpu_list[worker_id % n_cpus];
    var target_set: linux.cpu_set_t = std.mem.zeroes(linux.cpu_set_t);
    const cpu_word = target / @bitSizeOf(usize);
    const cpu_bit: u6 = @intCast(target % @bitSizeOf(usize));
    target_set[cpu_word] |= @as(usize, 1) << cpu_bit;

    linux.sched_setaffinity(0, &target_set) catch {};
}

/// Count CPUs available to this process via sched_getaffinity, respecting cgroup and taskset
/// restrictions (falls back to std.Thread.getCpuCount on failure). The TLS epoll default of one
/// worker per available CPU so workers are never oversubscribed under a cgroup-limited cpuset.
pub fn getAvailableCpuCount() usize {
    const linux = std.os.linux;
    var cpu_set: linux.cpu_set_t = undefined;
    if (linux.sched_getaffinity(0, @sizeOf(linux.cpu_set_t), &cpu_set) != 0) {
        return std.Thread.getCpuCount() catch 1;
    }

    var count: usize = 0;
    for (cpu_set) |word| {
        count += @popCount(word);
    }

    return if (count == 0) 1 else count;
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //

test "zix test: http2 effectiveCacheEntries honors the memory ceiling" {
    const base = core.ServeOpts{ .cache_max_entries = 1024, .cache_max_value_bytes = 16 * 1024 };

    // no ceiling: the configured entry count passes through
    try std.testing.expectEqual(@as(u32, 1024), effectiveCacheEntries(base));

    // ceiling of 256 KiB / 16 KiB = 16 slots, below the configured 1024
    var capped = base;
    capped.cache_max_total_bytes = 256 * 1024;
    try std.testing.expectEqual(@as(u32, 16), effectiveCacheEntries(capped));

    // a tiny ceiling still yields at least one slot
    var tiny = base;
    tiny.cache_max_total_bytes = 1;
    try std.testing.expectEqual(@as(u32, 1), effectiveCacheEntries(tiny));
}

test "zix test: http2 MuxCoalesceSink stages small writes and flushes them in order" {
    var fds: [2]i32 = undefined;
    try std.testing.expectEqual(@as(usize, 0), std.os.linux.socketpair(std.os.linux.AF.UNIX, std.os.linux.SOCK.STREAM, 0, &fds));
    defer _ = std.os.linux.close(fds[0]);
    defer _ = std.os.linux.close(fds[1]);

    var sink = MuxCoalesceSink{ .fd = fds[1] };

    // Two small appends stay buffered (coalesced), nothing on the wire yet.
    sink.append("AAAA");
    sink.append("BBBB");
    try std.testing.expectEqual(@as(usize, 8), sink.len);
    try std.testing.expect(!sink.failed);

    // Flush sends both in one ordered write.
    sink.flush();
    var recv: [16]u8 = undefined;
    const n = try std.posix.read(fds[0], recv[0..]);
    try std.testing.expectEqual(@as(usize, 8), n);
    try std.testing.expectEqualStrings("AAAABBBB", recv[0..n]);
    try std.testing.expectEqual(@as(usize, 0), sink.len);
}

test "zix test: http2 MuxCoalesceSink flushes the buffer then writes an oversized frame straight through" {
    var fds: [2]i32 = undefined;
    try std.testing.expectEqual(@as(usize, 0), std.os.linux.socketpair(std.os.linux.AF.UNIX, std.os.linux.SOCK.STREAM, 0, &fds));
    defer _ = std.os.linux.close(fds[0]);
    defer _ = std.os.linux.close(fds[1]);

    var sink = MuxCoalesceSink{ .fd = fds[1] };

    // A staged prefix, then a frame larger than the whole buffer: the prefix flushes first to keep
    // wire order, then the oversized frame is written directly. The reader (a stream socket) sees the
    // prefix ahead of the large frame.
    sink.append("PFX");
    var big: [MUX_COALESCE_BUF + 16]u8 = undefined;
    @memset(&big, 'Z');
    sink.append(&big);
    try std.testing.expectEqual(@as(usize, 0), sink.len);
    try std.testing.expect(!sink.failed);

    var got: usize = 0;
    var first3: [3]u8 = undefined;
    var scratch: [4096]u8 = undefined;
    while (got < 3 + big.len) {
        const n = try std.posix.read(fds[0], scratch[0..]);
        if (n == 0) break;
        if (got < 3) {
            const take = @min(3 - got, n);
            @memcpy(first3[got..][0..take], scratch[0..take]);
        }
        got += n;
    }
    try std.testing.expectEqual(@as(usize, 3 + big.len), got);
    try std.testing.expectEqualStrings("PFX", first3[0..3]);
}
