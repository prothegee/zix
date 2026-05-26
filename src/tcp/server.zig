//! zix tcp server

const std = @import("std");
const Config = @import("config.zig");
const TcpServerConfig = Config.TcpServerConfig;
const DispatchModel = Config.DispatchModel;
const Logger = @import("../logger/logger.zig").Logger;

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
        const sin: *align(8) const std.posix.sockaddr.in = @ptrCast(&storage);
        const b: [4]u8 = @bitCast(sin.addr);
        return std.fmt.bufPrint(buf, "{d}.{d}.{d}.{d}:{d}", .{
            b[0],                               b[1], b[2], b[3],
            std.mem.bigToNative(u16, sin.port),
        }) catch "-";
    }
    return "-";
}

fn getMonotonicMs() u64 {
    var spec: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &spec);
    const s: u64 = if (spec.sec >= 0) @intCast(spec.sec) else 0;
    const ms: u64 = if (spec.nsec >= 0) @as(u64, @intCast(spec.nsec)) / 1_000_000 else 0;
    return s * 1000 + ms;
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

// --------------------------------------------------------- //

/// TCP stream server. Dispatches connections via POOL, ASYNC, or MIXED.
///
/// Usage:
///   var server = try TcpServer.init(config);
///   defer server.deinit();
///   try server.run(io);               // built-in echo handler
///   try server.runWith(io, myFn);     // custom handler
pub const TcpServer = struct {
    const Self = @This();

    config: TcpServerConfig,

    // --------------------------------------------------------- //

    /// Initialize. Returns error.PortNotConfigured if config.port is 0.
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

            // EPOLL is HTTP-only. The generic TCP server falls back to the POOL model.
            .POOL, .EPOLL => {
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
        }
    }
};

// --------------------------------------------------------- //

/// Built-in echo handler. Reads length-prefixed frames and echoes each back unchanged.
/// Frame format: [u32 payload_len, 4 bytes, big-endian] [payload bytes]
/// Payloads larger than 4096 bytes close the connection.
pub fn echoHandler(stream: std.Io.net.Stream, io: std.Io) void {
    defer stream.close(io);

    var rbuf: [4096 + 4]u8 = undefined;
    var wbuf: [4096 + 4]u8 = undefined;
    var payload_buf: [4096]u8 = undefined;

    var rdr = stream.reader(io, &rbuf);
    var wtr = stream.writer(io, &wbuf);

    while (true) {
        const len = rdr.interface.takeVarInt(u32, .big, 4) catch return;
        if (len == 0 or len > payload_buf.len) return;

        rdr.interface.readSliceAll(payload_buf[0..len]) catch return;

        var hdr: [4]u8 = undefined;
        std.mem.writeInt(u32, &hdr, len, .big);
        wtr.interface.writeAll(&hdr) catch return;
        wtr.interface.writeAll(payload_buf[0..len]) catch return;
        wtr.interface.flush() catch return;
    }
}

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
