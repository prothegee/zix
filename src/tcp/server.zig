//! zix tcp server

const std = @import("std");
const Config = @import("config.zig");
const TcpServerConfig = Config.TcpServerConfig;
const DispatchModel = Config.DispatchModel;
const Logger = @import("../logger/logger.zig").Logger;

const queue_initial_cap: usize = 16;
const epoll_max_events: usize = 256;

// --------------------------------------------------------- //

/// User-provided connection handler. Receives the accepted stream and io.
/// The handler owns the stream for its lifetime. It must call stream.close(io) when done.
pub const HandlerFn = *const fn (stream: std.Io.net.Stream, io: std.Io) void;

// --------------------------------------------------------- //

fn getPeerAddr(fd: std.posix.fd_t, buf: []u8) []const u8 {
    var storage: std.posix.sockaddr.storage = undefined;
    var len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr.storage);
    std.posix.getpeername(fd, @ptrCast(&storage), &len) catch return "-";
    if (storage.family == std.posix.AF.INET) {
        const sock_in: *align(8) const std.posix.sockaddr.in = @ptrCast(&storage);
        const addr_bytes: [4]u8 = @bitCast(sock_in.addr);
        return std.fmt.bufPrint(buf, "{d}.{d}.{d}.{d}:{d}", .{
            addr_bytes[0],                          addr_bytes[1], addr_bytes[2], addr_bytes[3],
            std.mem.bigToNative(u16, sock_in.port),
        }) catch "-";
    }
    return "-";
}

fn getMonotonicMs() u64 {
    var spec: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &spec);
    const s: u64 = if (spec.sec >= 0) @intCast(spec.sec) else 0;
    const millis: u64 = if (spec.nsec >= 0) @as(u64, @intCast(spec.nsec)) / 1_000_000 else 0;
    return s * 1000 + millis;
}

// --------------------------------------------------------- //

// Work queue shared between accept threads (producers) and pool threads (consumers).
const ConnQueue = struct {
    mutex: std.Io.Mutex = .init,
    ready: std.Io.Condition = .init,
    items: std.ArrayListUnmanaged(std.Io.net.Stream) = .empty,
    closed: bool = false,

    fn push(self: *ConnQueue, stream: std.Io.net.Stream, io: std.Io) void {
        self.mutex.lockUncancelable(io);
        self.items.append(std.heap.smp_allocator, stream) catch {
            self.mutex.unlock(io);
            stream.close(io);
            return;
        };
        self.mutex.unlock(io);
        self.ready.signal(io);
    }

    fn pop(self: *ConnQueue, io: std.Io) ?std.Io.net.Stream {
        self.mutex.lockUncancelable(io);
        while (self.items.items.len == 0) {
            if (self.closed) {
                self.mutex.unlock(io);
                return null;
            }
            self.ready.waitUncancelable(io, &self.mutex);
        }
        const stream = self.items.orderedRemove(0);
        self.mutex.unlock(io);
        return stream;
    }

    fn close(self: *ConnQueue, io: std.Io) void {
        self.mutex.lockUncancelable(io);
        self.closed = true;
        self.mutex.unlock(io);
        self.ready.broadcast(io);
    }

    fn deinit(self: *ConnQueue) void {
        self.items.deinit(std.heap.smp_allocator);
    }
};

// --------------------------------------------------------- //

// Raw fd queue for EPOLL dispatch — accept loop pushes fds, workers pop and hold each connection.
const FdQueue = struct {
    mutex: std.Io.Mutex = .init,
    ready: std.Io.Condition = .init,
    buf: []std.posix.fd_t = &.{},
    head: usize = 0,
    len: usize = 0,
    closed: bool = false,

    fn push(self: *FdQueue, fd: std.posix.fd_t, io: std.Io) void {
        self.mutex.lockUncancelable(io);
        if (self.len == self.buf.len) {
            const new_cap = if (self.buf.len == 0) queue_initial_cap else self.buf.len * 2;
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

    fn pop(self: *FdQueue, io: std.Io) ?std.posix.fd_t {
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

    fn close(self: *FdQueue, io: std.Io) void {
        self.mutex.lockUncancelable(io);
        self.closed = true;
        self.mutex.unlock(io);
        self.ready.broadcast(io);
    }

    fn deinit(self: *FdQueue) void {
        if (self.buf.len > 0) std.heap.smp_allocator.free(self.buf);
    }
};

// --------------------------------------------------------- //

const ConnTask = struct {
    stream: std.Io.net.Stream,
    io: std.Io,
    handler: HandlerFn,
    logger: ?*Logger,
};

fn dispatchConn(task: ConnTask) void {
    var peer_buf: [64]u8 = undefined;
    const peer = getPeerAddr(task.stream.socket.handle, &peer_buf);
    const start = getMonotonicMs();
    task.handler(task.stream, task.io);
    if (task.logger) |lg| lg.conn(peer, getMonotonicMs() - start, null);
}

// --------------------------------------------------------- //

// Accept thread for POOL dispatch — pushes accepted connections to the shared queue.
fn workerEntry(cfg: TcpServerConfig, queue: *ConnQueue, io: std.Io) void {
    const addr = std.Io.net.IpAddress.resolve(io, cfg.ip, cfg.port) catch |err| {
        if (cfg.logger) |lg| lg.system(.ERROR, "tcp", "resolve error: {}", .{err});
        return;
    };
    var net_server = addr.listen(io, .{
        .mode = .stream,
        .protocol = .tcp,
        .reuse_address = true,
        .kernel_backlog = cfg.kernel_backlog,
    }) catch |err| {
        if (cfg.logger) |lg| lg.system(.ERROR, "tcp", "listen error: {}", .{err});
        return;
    };
    defer net_server.deinit(io);

    while (true) {
        const stream = net_server.accept(io) catch |err| {
            if (err != error.ConnectionAborted) {
                if (cfg.logger) |lg| lg.system(.WARN, "tcp", "accept error: {}", .{err});
                break;
            }
            continue;
        };
        queue.push(stream, io);
    }
}

// Pool thread — pops connections from the shared queue and dispatches each to handler.
fn poolEntry(queue: *ConnQueue, io: std.Io, handler: HandlerFn, logger: ?*Logger) void {
    while (queue.pop(io)) |stream| {
        var peer_buf: [64]u8 = undefined;
        const peer = getPeerAddr(stream.socket.handle, &peer_buf);
        const start = getMonotonicMs();
        handler(stream, io);
        if (logger) |lg| lg.conn(peer, getMonotonicMs() - start, null);
    }
}

// Accept thread for MIXED dispatch — dispatches each accepted connection via io.async().
fn asyncWorkerEntry(cfg: TcpServerConfig, io: std.Io, handler: HandlerFn) void {
    const addr = std.Io.net.IpAddress.resolve(io, cfg.ip, cfg.port) catch |err| {
        if (cfg.logger) |lg| lg.system(.ERROR, "tcp", "resolve error: {}", .{err});
        return;
    };
    var net_server = addr.listen(io, .{
        .mode = .stream,
        .protocol = .tcp,
        .reuse_address = true,
        .kernel_backlog = cfg.kernel_backlog,
    }) catch |err| {
        if (cfg.logger) |lg| lg.system(.ERROR, "tcp", "listen error: {}", .{err});
        return;
    };
    defer net_server.deinit(io);

    while (true) {
        const stream = net_server.accept(io) catch |err| {
            if (err != error.ConnectionAborted) {
                if (cfg.logger) |lg| lg.system(.WARN, "tcp", "accept error: {}", .{err});
                break;
            }
            continue;
        };
        _ = io.async(dispatchConn, .{ConnTask{ .stream = stream, .io = io, .handler = handler, .logger = cfg.logger }});
    }
}

// EPOLL worker — pops a raw fd, constructs a Stream, and runs the handler for the full connection lifetime.
const EpollWorkerCtx = struct {
    queue: *FdQueue,
    io: std.Io,
    handler: HandlerFn,
    logger: ?*Logger,
};

fn epollWorkerEntry(ctx: EpollWorkerCtx) void {
    while (ctx.queue.pop(ctx.io)) |conn_fd| {
        const stream: std.Io.net.Stream = .{ .socket = .{
            .handle = conn_fd,
            .address = .{ .ip4 = .unspecified(0) },
        } };
        dispatchConn(.{ .stream = stream, .io = ctx.io, .handler = ctx.handler, .logger = ctx.logger });
    }
}

// --------------------------------------------------------- //

/// TCP stream server. Dispatches connections via POOL, ASYNC, MIXED, or EPOLL (Linux-only: non-Linux falls back to POOL).
///
/// Usage:
/// ```zig
/// var server = try TcpServer.init(config);
/// defer server.deinit();
/// try server.run(io);               // built-in echo handler
/// try server.runWith(io, myFn);     // custom handler
/// ```
pub const TcpServer = struct {
    const Self = @This();

    config: TcpServerConfig,

    // --------------------------------------------------------- //

    /// Initialize.
    ///
    /// Return:
    /// - !Self
    /// - error.PortNotConfigured if config.port is 0
    pub fn init(config: TcpServerConfig) !Self {
        if (config.port == 0) return error.PortNotConfigured;
        return .{ .config = config };
    }

    /// Initialize with CLI arg overrides for --ip and --port.
    /// Falls back to config defaults when args are absent.
    pub fn initArgs(config: TcpServerConfig, args: anytype) !Self {
        var cfg = config;
        var it = std.process.Args.Iterator.init(args);
        _ = it.skip();
        while (it.next()) |arg| {
            if (std.mem.eql(u8, arg, "--ip")) {
                if (it.next()) |val| cfg.ip = val;
            } else if (std.mem.eql(u8, arg, "--port")) {
                if (it.next()) |val| cfg.port = std.fmt.parseInt(u16, val, 10) catch cfg.port;
            }
        }
        return Self.init(cfg);
    }

    /// No-op: resources released inside run/runWith via defer.
    pub fn deinit(self: *Self) void {
        _ = self;
    }

    /// Listen and serve using the built-in echo handler.
    pub fn run(self: *Self, io: std.Io) !void {
        try self.runWith(io, echoHandler);
    }

    /// Listen and serve using a user-provided handler.
    /// handler(stream, io) is called for each accepted connection.
    /// The handler owns the stream and must call stream.close(io) before returning.
    pub fn runWith(self: *Self, io: std.Io, handler: HandlerFn) !void {
        const cfg = self.config;
        const cpu = try std.Thread.getCpuCount();

        switch (cfg.dispatch_model) {
            .ASYNC => {
                if (cfg.logger) |lg| lg.system(.INFO, "tcp", "listening on {s}:{d} (async)", .{ cfg.ip, cfg.port });

                const addr = try std.Io.net.IpAddress.resolve(io, cfg.ip, cfg.port);
                var net_server = try addr.listen(io, .{
                    .mode = .stream,
                    .protocol = .tcp,
                    .reuse_address = true,
                    .kernel_backlog = cfg.kernel_backlog,
                });
                defer net_server.deinit(io);

                while (true) {
                    const stream = net_server.accept(io) catch |err| {
                        if (err != error.ConnectionAborted) {
                            if (cfg.logger) |lg| lg.system(.WARN, "tcp", "accept error: {}", .{err});
                            break;
                        }
                        continue;
                    };
                    _ = io.async(dispatchConn, .{ConnTask{ .stream = stream, .io = io, .handler = handler, .logger = cfg.logger }});
                }
            },

            .POOL => {
                const worker_count = if (cfg.workers == 0) cpu else cfg.workers;
                const pool_count = if (cfg.pool_size == 0) @max(10, cpu * 2) else cfg.pool_size;

                if (cfg.logger) |lg| lg.system(.INFO, "tcp", "listening on {s}:{d} (pool/{d}x{d})", .{ cfg.ip, cfg.port, worker_count, pool_count });

                var queue = ConnQueue{};
                defer queue.deinit();

                const pool_threads = try std.heap.smp_allocator.alloc(std.Thread, pool_count);
                defer std.heap.smp_allocator.free(pool_threads);
                for (pool_threads) |*t| {
                    t.* = try std.Thread.spawn(.{ .stack_size = 512 * 1024 }, poolEntry, .{ &queue, io, handler, cfg.logger });
                }

                const acc_threads = try std.heap.smp_allocator.alloc(std.Thread, worker_count);
                defer std.heap.smp_allocator.free(acc_threads);
                for (acc_threads) |*t| {
                    t.* = try std.Thread.spawn(.{}, workerEntry, .{ cfg, &queue, io });
                }

                for (acc_threads) |t| t.join();
                queue.close(io);
                for (pool_threads) |t| t.join();
            },

            .MIXED => {
                const worker_count = if (cfg.workers == 0) cpu else cfg.workers;

                if (cfg.logger) |lg| lg.system(.INFO, "tcp", "listening on {s}:{d} (mixed/{d})", .{ cfg.ip, cfg.port, worker_count });

                const acc_threads = try std.heap.smp_allocator.alloc(std.Thread, worker_count);
                defer std.heap.smp_allocator.free(acc_threads);
                for (acc_threads) |*t| {
                    t.* = try std.Thread.spawn(.{}, asyncWorkerEntry, .{ cfg, io, handler });
                }

                for (acc_threads) |t| t.join();
            },

            .EPOLL => {
                if (comptime @import("builtin").target.os.tag == .linux) {
                    try self.runEpoll(io, handler, cpu);
                } else {
                    std.debug.print("zix tcp server: EPOLL is Linux-only. Falling back to POOL.\n", .{});
                    var fallback = self.*;
                    fallback.config.dispatch_model = .POOL;
                    try fallback.runWith(io, handler);
                }
            },
        }
    }

    /// EPOLL dispatch: a single epoll event loop accepts connections and hands
    /// each fd to a worker pool. Each worker runs the handler for the full
    /// connection lifetime. Linux-only.
    ///
    /// Note:
    /// - Workers hold each connection for its full lifetime (TCP connections are
    ///   stream-based: the handler loops until EOF). EPOLLONESHOT is not used.
    /// - The benefit over POOL is single-threaded accept vs N accept threads.
    /// - pool_size sets the worker count (0 = max(10, cpu * 2)).
    fn runEpoll(self: *Self, io: std.Io, handler: HandlerFn, cpu: usize) !void {
        const linux = std.os.linux;
        const cfg = self.config;
        const pool_count = if (cfg.pool_size == 0) @max(10, cpu * 2) else cfg.pool_size;

        const addr = std.Io.net.IpAddress.resolve(io, cfg.ip, cfg.port) catch |err| {
            if (cfg.logger) |lg| lg.system(.ERROR, "tcp", "epoll resolve error: {}", .{err});
            return err;
        };
        var net_server = addr.listen(io, .{
            .mode = .stream,
            .protocol = .tcp,
            .reuse_address = true,
            .kernel_backlog = cfg.kernel_backlog,
        }) catch |err| {
            if (cfg.logger) |lg| lg.system(.ERROR, "tcp", "epoll listen error: {}", .{err});
            return err;
        };
        defer net_server.deinit(io);
        const listener_fd = net_server.socket.handle;

        const cur_flags = linux.fcntl(listener_fd, std.posix.F.GETFL, 0);
        const nonblock_bit: u32 = @bitCast(std.posix.O{ .NONBLOCK = true });
        _ = linux.fcntl(listener_fd, std.posix.F.SETFL, cur_flags | @as(usize, nonblock_bit));

        const epfd_rc = linux.epoll_create1(linux.EPOLL.CLOEXEC);
        if (std.posix.errno(epfd_rc) != .SUCCESS) return error.EpollCreateFailed;
        const epfd: std.posix.fd_t = @intCast(epfd_rc);
        defer _ = linux.close(epfd);

        var listener_event = linux.epoll_event{
            .events = linux.EPOLL.IN | linux.EPOLL.ET,
            .data = .{ .fd = listener_fd },
        };
        if (std.posix.errno(linux.epoll_ctl(epfd, linux.EPOLL.CTL_ADD, listener_fd, &listener_event)) != .SUCCESS)
            return error.EpollCtlFailed;

        if (cfg.logger) |lg| lg.system(.INFO, "tcp", "listening on {s}:{d} (epoll/{d})", .{ cfg.ip, cfg.port, pool_count });

        var queue = FdQueue{};
        defer queue.deinit();

        const workers = try std.heap.smp_allocator.alloc(std.Thread, pool_count);
        defer std.heap.smp_allocator.free(workers);
        for (workers) |*t|
            t.* = try std.Thread.spawn(
                .{ .stack_size = 512 * 1024 },
                epollWorkerEntry,
                .{EpollWorkerCtx{ .queue = &queue, .io = io, .handler = handler, .logger = cfg.logger }},
            );

        const max_events = epoll_max_events;
        var events: [max_events]linux.epoll_event = undefined;
        while (true) {
            const wait_result = linux.epoll_wait(epfd, &events, max_events, -1);
            switch (std.posix.errno(wait_result)) {
                .SUCCESS => {},
                .INTR => continue,
                else => break,
            }
            const n: usize = @intCast(wait_result);
            for (events[0..n]) |ev| {
                if (ev.data.fd != listener_fd) continue;
                while (true) {
                    const accept_result = linux.accept4(listener_fd, null, null, std.posix.SOCK.CLOEXEC);
                    switch (std.posix.errno(accept_result)) {
                        .SUCCESS => {},
                        .AGAIN => break,
                        .INTR, .CONNABORTED => continue,
                        else => break,
                    }
                    const conn_fd: std.posix.fd_t = @intCast(accept_result);
                    queue.push(conn_fd, io);
                }
            }
        }

        queue.close(io);
        for (workers) |t| t.join();
    }
};

// --------------------------------------------------------- //

/// Built-in echo handler. Reads length-prefixed frames and echoes each back unchanged.
/// Frame format: [u32 payload_len, 4 bytes, big-endian] [payload bytes]
/// Payloads larger than 4096 bytes close the connection.
pub fn echoHandler(stream: std.Io.net.Stream, io: std.Io) void {
    defer stream.close(io);

    var read_buf: [4096 + 4]u8 = undefined;
    var write_buf: [4096 + 4]u8 = undefined;
    var payload_buf: [4096]u8 = undefined;

    var reader = stream.reader(io, &read_buf);
    var writer = stream.writer(io, &write_buf);

    while (true) {
        const len = reader.interface.takeVarInt(u32, .big, 4) catch return;
        if (len == 0 or len > payload_buf.len) return;

        reader.interface.readSliceAll(payload_buf[0..len]) catch return;

        var hdr: [4]u8 = undefined;
        std.mem.writeInt(u32, &hdr, len, .big);
        writer.interface.writeAll(&hdr) catch return;
        writer.interface.writeAll(payload_buf[0..len]) catch return;
        writer.interface.flush() catch return;
    }
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //

test "zix test: TcpServer init, port zero returns PortNotConfigured" {
    try std.testing.expectError(
        error.PortNotConfigured,
        TcpServer.init(.{ .ip = "127.0.0.1", .port = 0 }),
    );
}

test "zix test: TcpServer init, valid config succeeds and deinit is safe" {
    var server = try TcpServer.init(.{ .ip = "127.0.0.1", .port = 9300 });
    server.deinit();
}

test "zix test: TcpServer init with EPOLL dispatch model succeeds and deinit is safe" {
    var server = try TcpServer.init(.{ .ip = "127.0.0.1", .port = 9300, .dispatch_model = .EPOLL });
    server.deinit();
}
