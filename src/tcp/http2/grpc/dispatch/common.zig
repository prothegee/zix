//! zix grpc dispatch: helpers shared across the dispatch models (ADR-043).
//! The route-agnostic pieces (logSystem, opts builders, setNoDelay, ConnQueue,
//! the accept worker) are plain decls. The route-table-dependent per-connection
//! helpers live in Dispatch(routes), since core.serveGrpcConn takes comptime
//! routes. EPOLL and URING keep their own (route-baked) workers in their files.

const std = @import("std");
const builtin = @import("builtin");
const core = @import("../core.zig");
const GrpcServerConfig = @import("../config.zig").GrpcServerConfig;
const Route = core.Route;

/// Effective cache slot count for a worker, honoring cache_max_total_bytes.
/// When a memory ceiling is set, the entry count is reduced so the slab
/// (entries * value_bytes) fits. ResponseCache.init then rounds down to a power
/// of two, so the slab never exceeds the ceiling.
pub fn effectiveCacheEntries(opts: core.GrpcServeOpts) u32 {
    if (opts.cache_max_total_bytes == 0) return opts.cache_max_entries;

    const value_bytes: usize = @max(1, opts.cache_max_value_bytes);
    const fit = opts.cache_max_total_bytes / value_bytes;
    const capped = @min(@as(usize, opts.cache_max_entries), fit);

    return @intCast(@max(@as(usize, 1), capped));
}

/// Emit a server lifecycle line. Routes through cfg.logger when present.
/// Without a logger it prints to stderr only in Debug builds (silent in release).
pub fn logSystem(cfg: GrpcServerConfig, comptime fmt: []const u8, args: anytype) void {
    if (cfg.logger) |lg| {
        lg.system(.INFO, "grpc", fmt, args);
        return;
    }

    if (comptime builtin.mode == .Debug) std.debug.print("zix grpc: " ++ fmt ++ "\n", args);
}

/// Basic per-connection serve options, used by ASYNC / POOL / MIXED (the
/// response cache is active only on the multiplexed EPOLL / URING workers).
pub fn serveOpts(cfg: GrpcServerConfig) core.GrpcServeOpts {
    return .{
        .max_streams = cfg.max_streams,
        .max_frame_size = cfg.max_frame_size,
        .max_header_scratch = cfg.max_header_scratch,
        .max_body = cfg.max_body,
        .conn_read_buf_min = cfg.max_recv_buf,
        .tls_write_buf_initial = cfg.tls_write_buf_initial_bytes,
        .logger = cfg.logger,
        .handler_timeout_ms = cfg.handler_timeout_ms,
        .io = cfg.io,
        .compress = cfg.compress,
    };
}

/// Full serve options including the response-cache fields, used by the
/// multiplexed EPOLL / URING workers.
pub fn serveOptsWithCache(cfg: GrpcServerConfig) core.GrpcServeOpts {
    return .{
        .max_streams = cfg.max_streams,
        .max_frame_size = cfg.max_frame_size,
        .max_header_scratch = cfg.max_header_scratch,
        .max_body = cfg.max_body,
        .conn_read_buf_min = cfg.max_recv_buf,
        .tls_write_buf_initial = cfg.tls_write_buf_initial_bytes,
        .logger = cfg.logger,
        .handler_timeout_ms = cfg.handler_timeout_ms,
        .io = cfg.io,
        .compress = cfg.compress,
        .response_cache = cfg.response_cache,
        .cache_max_entries = cfg.cache_max_entries,
        .cache_max_value_bytes = cfg.cache_max_value_bytes,
        .cache_ttl_ms = cfg.cache_ttl_ms,
        .cache_max_total_bytes = cfg.cache_max_total_bytes,
    };
}

/// Highest fd a worker's table can index. Linux hands out the lowest free fd, so
/// the table stays sparse. Connections on fds at or above this are refused.
pub const MAX_FD: usize = 1 << 16;

pub fn setNoDelay(fd: std.posix.fd_t) void {
    if (comptime @import("builtin").target.os.tag != .windows) {
        std.posix.setsockopt(
            fd,
            std.posix.IPPROTO.TCP,
            std.posix.TCP.NODELAY,
            std.mem.asBytes(&@as(c_int, 1)),
        ) catch {};
    }
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

/// Route-table-dependent dispatch helpers for ASYNC / POOL / MIXED. The route
/// set is comptime, so every function that calls core.serveGrpcConn(routes, ...)
/// is baked per route table.
pub fn Dispatch(comptime routes: []const Route) type {
    return struct {
        pub const ConnTask = struct {
            fd: std.posix.fd_t,
            opts: core.GrpcServeOpts,
        };

        pub fn dispatchConn(task: ConnTask) void {
            defer _ = std.os.linux.close(task.fd);
            core.serveGrpcConn(routes, task.fd, task.opts);
        }

        pub const PoolCtx = struct {
            queue: *ConnQueue,
            io: std.Io,
            opts: core.GrpcServeOpts,
        };

        pub fn poolEntry(ctx: PoolCtx) void {
            while (ctx.queue.pop(ctx.io)) |fd| {
                defer _ = std.os.linux.close(fd);
                core.serveGrpcConn(routes, fd, ctx.opts);
            }
        }

        pub const AsyncWorkerCtx = struct {
            io: std.Io,
            ip: []const u8,
            port: u16,
            kernel_backlog: u31,
            opts: core.GrpcServeOpts,
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
