//! zix tcp server

const std = @import("std");
const builtin = @import("builtin");
const Config = @import("config.zig");
const TcpServerConfig = Config.TcpServerConfig;
const DispatchModel = Config.DispatchModel;
const Logger = @import("../logger/logger.zig").Logger;
const uring = @import("io_uring/ring.zig");
const IoUring = std.os.linux.IoUring;

/// Emit a server lifecycle line. Routes through cfg.logger when present.
/// Without a logger it prints to stderr only in Debug builds (silent in release).
fn logSystem(cfg: TcpServerConfig, comptime fmt: []const u8, args: anytype) void {
    if (cfg.logger) |lg| {
        lg.system(.INFO, "tcp", fmt, args);
        return;
    }

    if (comptime builtin.mode == .Debug) std.debug.print("zix tcp: " ++ fmt ++ "\n", args);
}

/// Max epoll events drained per epoll_wait call. 512 lets a worker clear its
/// ready-fd set in one syscall at high connection counts.
const EPOLL_MAX_EVENTS: usize = 512;

// --------------------------------------------------------- //

/// User-provided connection handler. Receives the accepted stream and io.
/// The handler owns the stream for its lifetime. It must call stream.close(io) when done.
pub const HandlerFn = *const fn (stream: std.Io.net.Stream, io: std.Io) void;

/// Per-frame callback for the framed engine (runFramed). Called once per
/// length-prefixed frame (the engine drives the read/write loop, the callback
/// just processes one payload and writes a reply via frameRespond / fdWriteAll).
/// Unlike HandlerFn it does not own the connection and never blocks, so it can
/// run on the single-threaded .URING completion ring (ADR-037).
pub const FrameFn = *const fn (payload: []const u8, fd: std.posix.fd_t) void;

/// Frame wire format for the framed engine: a 4-byte big-endian length prefix
/// followed by that many payload bytes. Frames larger than this are rejected
/// (the connection is closed).
pub const FRAME_LEN_PREFIX: usize = 4;
pub const FRAME_MAX_PAYLOAD: usize = 1 << 20;

// --------------------------------------------------------- //
// Framed-engine response sink + helpers. While a sink is installed
// (tl_resp_sink, the .URING ring path), writes stage into it and coalesce into
// one ring send; otherwise they go straight to the fd (the blocking adapter).

/// Direct socket write, bypassing the coalescing sink.
fn rawFrameWrite(fd: std.posix.fd_t, data: []const u8) error{BrokenPipe}!void {
    var remaining = data;
    while (remaining.len > 0) {
        const rc = std.posix.system.write(fd, remaining.ptr, remaining.len);
        switch (std.posix.errno(rc)) {
            .SUCCESS => {
                const n: usize = @intCast(rc);
                if (n == 0) return error.BrokenPipe;

                remaining = remaining[n..];
            },
            .INTR => continue,
            else => return error.BrokenPipe,
        }
    }
}

/// Coalescing sink for the framed .URING path. Oversize writes flush straight to
/// the fd (safe under the ring's half-duplex guarantee).
pub const RespSink = struct {
    fd: std.posix.fd_t,
    buf: []u8,
    len: usize = 0,
    failed: bool = false,

    pub fn append(self: *RespSink, bytes: []const u8) void {
        if (bytes.len > self.buf.len) {
            self.flush();
            rawFrameWrite(self.fd, bytes) catch {
                self.failed = true;
            };

            return;
        }

        if (self.len + bytes.len > self.buf.len) self.flush();

        @memcpy(self.buf[self.len..][0..bytes.len], bytes);
        self.len += bytes.len;
    }

    pub fn flush(self: *RespSink) void {
        if (self.len == 0) return;

        rawFrameWrite(self.fd, self.buf[0..self.len]) catch {
            self.failed = true;
        };
        self.len = 0;
    }
};

/// Active sink for the current worker thread (set by the framed ring worker).
pub threadlocal var tl_resp_sink: ?*RespSink = null;

/// Write raw bytes to the connection: into the sink when one is installed
/// (coalesced ring send), otherwise straight to the fd.
pub fn fdWriteAll(fd: std.posix.fd_t, data: []const u8) error{BrokenPipe}!void {
    if (tl_resp_sink) |sink| {
        sink.append(data);

        return if (sink.failed) error.BrokenPipe else {};
    }

    return rawFrameWrite(fd, data);
}

/// Send a length-prefixed frame: a 4-byte big-endian length followed by payload.
/// The framed-engine reply helper for a FrameFn callback.
pub fn frameRespond(fd: std.posix.fd_t, payload: []const u8) error{BrokenPipe}!void {
    var hdr: [FRAME_LEN_PREFIX]u8 = undefined;
    std.mem.writeInt(u32, &hdr, @intCast(payload.len), .big);

    try fdWriteAll(fd, &hdr);
    try fdWriteAll(fd, payload);
}

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

fn applyConnTimeout(sock_fd: std.posix.fd_t, recv_ms: u32, send_ms: u32) void {
    if (recv_ms == 0 and send_ms == 0) return;

    if (recv_ms > 0) {
        const recv_tv = std.posix.timeval{ .sec = @intCast(recv_ms / 1000), .usec = @intCast((recv_ms % 1000) * 1000) };
        std.posix.setsockopt(sock_fd, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&recv_tv)) catch {};
    }

    if (send_ms > 0) {
        const send_tv = std.posix.timeval{ .sec = @intCast(send_ms / 1000), .usec = @intCast((send_ms % 1000) * 1000) };
        std.posix.setsockopt(sock_fd, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, std.mem.asBytes(&send_tv)) catch {};
    }
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

// Accept thread for POOL dispatch: pushes accepted connections to the shared queue.
fn workerEntry(cfg: TcpServerConfig, queue: *ConnQueue, io: std.Io) void {
    const addr = std.Io.net.IpAddress.resolve(io, cfg.ip, cfg.port) catch |err| {
        if (cfg.logger) |lg| lg.system(.ERROR, "tcp", "resolve error: {}", .{err});
        return;
    };
    var net_server = addr.listen(io, .{
        .mode = .stream,
        .protocol = .tcp,
        .reuse_address = true, // SO_REUSEADDR + SO_REUSEPORT on POSIX, required for POOL, applied to all models
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
        applyConnTimeout(stream.socket.handle, cfg.recv_timeout_ms, cfg.send_timeout_ms);

        queue.push(stream, io);
    }
}

// Pool thread: pops connections from the shared queue and dispatches each to handler.
fn poolEntry(queue: *ConnQueue, io: std.Io, handler: HandlerFn, logger: ?*Logger) void {
    while (queue.pop(io)) |stream| {
        var peer_buf: [64]u8 = undefined;
        const peer = getPeerAddr(stream.socket.handle, &peer_buf);
        const start = getMonotonicMs();
        handler(stream, io);
        if (logger) |lg| lg.conn(peer, getMonotonicMs() - start, null);
    }
}

// Accept thread for MIXED dispatch: dispatches each accepted connection via io.async().
fn asyncWorkerEntry(cfg: TcpServerConfig, io: std.Io, handler: HandlerFn) void {
    const addr = std.Io.net.IpAddress.resolve(io, cfg.ip, cfg.port) catch |err| {
        if (cfg.logger) |lg| lg.system(.ERROR, "tcp", "resolve error: {}", .{err});
        return;
    };
    var net_server = addr.listen(io, .{
        .mode = .stream,
        .protocol = .tcp,
        .reuse_address = true, // SO_REUSEADDR + SO_REUSEPORT on POSIX, required for POOL, applied to all models
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
        applyConnTimeout(stream.socket.handle, cfg.recv_timeout_ms, cfg.send_timeout_ms);

        _ = io.async(dispatchConn, .{ConnTask{ .stream = stream, .io = io, .handler = handler, .logger = cfg.logger }});
    }
}

const EpollWorkerCtx = struct {
    io: std.Io,
    ip: []const u8,
    port: u16,
    kernel_backlog: u31,
    recv_timeout_ms: u32,
    send_timeout_ms: u32,
    handler: HandlerFn,
    logger: ?*Logger,
};

/// EPOLL worker: owns one SO_REUSEPORT listener and one epoll instance.
/// The kernel load-balances connections across per-worker listeners with no
/// shared queue and no cross-thread fd handoff. Each accepted connection is
/// dispatched via io.async so the worker returns to epoll_wait immediately
/// and is not parked on the connection lifetime.
fn epollWorkerEntry(ctx: EpollWorkerCtx) void {
    const linux = std.os.linux;

    const addr = std.Io.net.IpAddress.resolve(ctx.io, ctx.ip, ctx.port) catch |err| {
        if (ctx.logger) |lg| lg.system(.ERROR, "tcp", "epoll worker resolve error: {}", .{err});
        return;
    };
    var srv = addr.listen(ctx.io, .{
        .mode = .stream,
        .protocol = .tcp,
        .reuse_address = true, // SO_REUSEADDR + SO_REUSEPORT on POSIX: each worker binds the same port
        .kernel_backlog = ctx.kernel_backlog,
    }) catch |err| {
        if (ctx.logger) |lg| lg.system(.ERROR, "tcp", "epoll worker listen error: {}", .{err});
        return;
    };
    defer srv.deinit(ctx.io);
    const listener_fd = srv.socket.handle;

    const cur_flags = linux.fcntl(listener_fd, std.posix.F.GETFL, 0);
    const nonblock_bit: u32 = @bitCast(std.posix.O{ .NONBLOCK = true });
    _ = linux.fcntl(listener_fd, std.posix.F.SETFL, cur_flags | @as(usize, nonblock_bit));

    const epfd_rc = linux.epoll_create1(linux.EPOLL.CLOEXEC);
    if (std.posix.errno(epfd_rc) != .SUCCESS) return;
    const epfd: std.posix.fd_t = @intCast(epfd_rc);
    defer _ = linux.close(epfd);

    var listener_event = linux.epoll_event{
        .events = linux.EPOLL.IN,
        .data = .{ .fd = listener_fd },
    };
    if (std.posix.errno(linux.epoll_ctl(epfd, linux.EPOLL.CTL_ADD, listener_fd, &listener_event)) != .SUCCESS) return;

    var events: [EPOLL_MAX_EVENTS]linux.epoll_event = undefined;
    var epoll_timeout: i32 = -1;
    while (true) {
        const wait_result = linux.epoll_wait(epfd, &events, EPOLL_MAX_EVENTS, epoll_timeout);
        switch (std.posix.errno(wait_result)) {
            .SUCCESS => {},
            .INTR => continue,
            else => return,
        }

        const n: usize = @intCast(wait_result);
        if (n == 0) {
            epoll_timeout = -1;
            continue;
        }

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
                applyConnTimeout(conn_fd, ctx.recv_timeout_ms, ctx.send_timeout_ms);
                const stream: std.Io.net.Stream = .{ .socket = .{
                    .handle = conn_fd,
                    .address = .{ .ip4 = .unspecified(0) },
                } };

                _ = ctx.io.async(dispatchConn, .{ConnTask{
                    .stream = stream,
                    .io = ctx.io,
                    .handler = ctx.handler,
                    .logger = ctx.logger,
                }});
            }
        }

        epoll_timeout = 0;
    }
}

// --------------------------------------------------------- //

/// Dispatch core: listen and serve connections with handler, selecting the
/// concurrency model from cfg.dispatch_model. handler(stream, io) runs once per
/// accepted connection and owns the stream (it must close it before returning).
/// Shared by the per-connection server (TcpServerImpl) and the framed adapter
/// fallback (TcpFramedServerImpl on every model except .URING).
fn serveDispatch(cfg: TcpServerConfig, io: std.Io, handler: HandlerFn) !void {
    const cpu = try std.Thread.getCpuCount();

    switch (cfg.dispatch_model) {
        .ASYNC => {
            logSystem(cfg, "listening on {s}:{d} (async)", .{ cfg.ip, cfg.port });

            const addr = try std.Io.net.IpAddress.resolve(io, cfg.ip, cfg.port);
            var net_server = try addr.listen(io, .{
                .mode = .stream,
                .protocol = .tcp,
                .reuse_address = true, // SO_REUSEADDR + SO_REUSEPORT on POSIX, required for POOL, applied to all models
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
                applyConnTimeout(stream.socket.handle, cfg.recv_timeout_ms, cfg.send_timeout_ms);

                _ = io.async(dispatchConn, .{ConnTask{ .stream = stream, .io = io, .handler = handler, .logger = cfg.logger }});
            }
        },

        .POOL => {
            const worker_count = if (cfg.workers == 0) cpu else cfg.workers;
            const pool_count = if (cfg.pool_size == 0) @max(10, cpu * 2) else cfg.pool_size;

            logSystem(cfg, "listening on {s}:{d} (pool/{d}x{d})", .{ cfg.ip, cfg.port, worker_count, pool_count });

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

            logSystem(cfg, "listening on {s}:{d} (mixed/{d})", .{ cfg.ip, cfg.port, worker_count });

            const acc_threads = try std.heap.smp_allocator.alloc(std.Thread, worker_count);
            defer std.heap.smp_allocator.free(acc_threads);
            for (acc_threads) |*t| {
                t.* = try std.Thread.spawn(.{}, asyncWorkerEntry, .{ cfg, io, handler });
            }

            for (acc_threads) |t| t.join();
        },

        // The per-connection blocking handler cannot run on the single-threaded
        // .URING ring, so .URING folds to the .EPOLL shared-nothing loop here.
        // The framed callback path (Server.initFramed) does run natively on the
        // ring (ADR-037, ADR-038).
        .EPOLL, .URING => {
            if (comptime @import("builtin").target.os.tag == .linux) {
                try runEpoll(cfg, io, handler, cpu);
            } else {
                logSystem(cfg, "EPOLL is Linux-only. Falling back to POOL.", .{});

                var pool_cfg = cfg;
                pool_cfg.dispatch_model = .POOL;

                try serveDispatch(pool_cfg, io, handler);
            }
        },
    }
}

/// EPOLL dispatch: spawns shared-nothing workers, each with its own
/// SO_REUSEPORT listener and epoll instance. Linux-only.
///
/// Note:
/// - The kernel distributes connections across per-worker listeners with no
///   shared queue and no cross-thread fd handoff.
/// - Each accepted connection is dispatched via io.async: the worker returns
///   to epoll_wait immediately and is not parked on the connection lifetime.
/// - workers = 0 (default): cpu_count workers.
/// - pool_size is ignored for EPOLL (no session-worker pool needed).
fn runEpoll(cfg: TcpServerConfig, io: std.Io, handler: HandlerFn, cpu: usize) !void {
    const worker_count = if (cfg.workers == 0) cpu else cfg.workers;

    logSystem(cfg, "listening on {s}:{d} (epoll/{d}, shared-nothing)", .{ cfg.ip, cfg.port, worker_count });

    const workers = try std.heap.smp_allocator.alloc(std.Thread, worker_count);
    defer std.heap.smp_allocator.free(workers);

    for (workers) |*t|
        t.* = try std.Thread.spawn(
            .{ .stack_size = 512 * 1024 },
            epollWorkerEntry,
            .{EpollWorkerCtx{
                .io = io,
                .ip = cfg.ip,
                .port = cfg.port,
                .kernel_backlog = cfg.kernel_backlog,
                .recv_timeout_ms = cfg.recv_timeout_ms,
                .send_timeout_ms = cfg.send_timeout_ms,
                .handler = handler,
                .logger = cfg.logger,
            }},
        );

    for (workers) |t| t.join();
}

/// Per-connection TCP server specialized over a comptime handler. The handler
/// is baked into the type at init, so run takes no handler argument (matching
/// the zix.Http1 / zix.Grpc shape). The handler owns each accepted stream and
/// must close it before returning.
fn TcpServerImpl(comptime handler: HandlerFn) type {
    return struct {
        config: TcpServerConfig,

        const Self = @This();

        pub fn init(config: TcpServerConfig) !Self {
            if (config.port == 0) return error.PortNotConfigured;

            return .{ .config = config };
        }

        pub fn deinit(_: *Self) void {}

        /// Listen and serve. Selects the concurrency model from config.dispatch_model.
        /// io is taken from config.io (caller-provided, must outlive the server).
        pub fn run(self: *const Self) !void {
            return serveDispatch(self.config, self.config.io, handler);
        }
    };
}

/// Framed TCP server specialized over a comptime per-frame callback. On .URING
/// the engine owns the connection and runs frame_fn on the io_uring ring; on
/// every other model frame_fn is wrapped in a blocking per-connection adapter
/// and served through serveDispatch. run takes no callback argument: it is
/// baked into the type at init.
fn TcpFramedServerImpl(comptime frame_fn: FrameFn) type {
    return struct {
        config: TcpServerConfig,

        const Self = @This();

        pub fn init(config: TcpServerConfig) !Self {
            if (config.port == 0) return error.PortNotConfigured;

            return .{ .config = config };
        }

        pub fn deinit(_: *Self) void {}

        pub fn run(self: *const Self) !void {
            const io = self.config.io;
            if (comptime builtin.target.os.tag == .linux) {
                if (self.config.dispatch_model == .URING) return runFramedUring(self.config, io, frame_fn);
            }

            return serveDispatch(self.config, io, frameAdapter(frame_fn));
        }
    };
}

/// Apply --ip and --port CLI overrides onto a config, falling back to the
/// config defaults when an arg is absent.
fn applyArgs(config: TcpServerConfig, args: anytype) TcpServerConfig {
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

    return cfg;
}

/// TCP stream server. The handler (or framed callback) is baked into the
/// server type at init (comptime), so run takes no handler argument. io is a
/// config field (config.io), so run takes no argument either, matching the
/// zix.Http1 / zix.Grpc server shape.
///
/// Usage:
/// ```zig
/// // per-connection handler (owns the stream)
/// var server = try zix.Tcp.Server.init(myHandler, config); // config.io required
/// defer server.deinit();
/// try server.run();
///
/// // the built-in echo handler, passed explicitly
/// var server = try zix.Tcp.Server.init(zix.Tcp.echoHandler, config);
///
/// // per-frame callback (engine owns the connection, runs on .URING)
/// var server = try zix.Tcp.Server.initFramed(myFrameFn, config);
/// try server.run();
/// ```
pub const Server = struct {
    /// Initialize a per-connection server with a comptime handler.
    ///
    /// Param:
    /// handler - comptime HandlerFn (baked into the server type)
    /// config - TcpServerConfig
    ///
    /// Return:
    /// - !TcpServerImpl(handler)
    /// - error.PortNotConfigured if config.port is 0
    pub fn init(comptime handler: HandlerFn, config: TcpServerConfig) !TcpServerImpl(handler) {
        return TcpServerImpl(handler).init(config);
    }

    /// Like init, but applies --ip and --port CLI overrides from args.
    pub fn initArgs(comptime handler: HandlerFn, config: TcpServerConfig, args: anytype) !TcpServerImpl(handler) {
        return TcpServerImpl(handler).init(applyArgs(config, args));
    }

    /// Initialize a framed server with a comptime per-frame callback. The
    /// callback never owns the connection, so it can run on the .URING ring.
    ///
    /// Param:
    /// frame_fn - comptime FrameFn (baked into the server type)
    /// config - TcpServerConfig
    ///
    /// Return:
    /// - !TcpFramedServerImpl(frame_fn)
    /// - error.PortNotConfigured if config.port is 0
    pub fn initFramed(comptime frame_fn: FrameFn, config: TcpServerConfig) !TcpFramedServerImpl(frame_fn) {
        return TcpFramedServerImpl(frame_fn).init(config);
    }

    /// Like initFramed, but applies --ip and --port CLI overrides from args.
    pub fn initFramedArgs(comptime frame_fn: FrameFn, config: TcpServerConfig, args: anytype) !TcpFramedServerImpl(frame_fn) {
        return TcpFramedServerImpl(frame_fn).init(applyArgs(config, args));
    }
};

// --------------------------------------------------------- //
// Framed io_uring ring (ADR-037 Phase 4 extension): shared-nothing, one ring +
// listener per worker. recv into the connection buffer, parse length-prefixed
// frames, call frame_fn per frame (the reply stages through tl_resp_sink), and
// submit one coalesced send per readable batch. Half-duplex per connection.
// Mirrors the zix.Http1 ring core with frame parsing in place of HTTP parsing.

const FrameOutcome = enum { keep_alive, close };

/// SQ entries per worker ring.
const URING_ENTRIES: u16 = 4096;
/// CQ entries per worker ring (multishot completion headroom).
const URING_CQ_ENTRIES: u32 = 16 * 1024;
/// Max CQEs drained per loop pass.
const URING_CQE_BATCH: usize = 512;
/// Per-connection staged-response buffer.
const URING_SEND_BUF_SIZE: usize = 64 * 1024;

/// Initialize a worker ring with the single-issuer fast-path flags, falling back
/// to a flagless ring when the kernel does not support them.
fn initUringRing() !IoUring {
    const linux = std.os.linux;
    var params = std.mem.zeroInit(linux.io_uring_params, .{
        .flags = linux.IORING_SETUP_SINGLE_ISSUER |
            linux.IORING_SETUP_DEFER_TASKRUN |
            linux.IORING_SETUP_CQSIZE |
            linux.IORING_SETUP_CLAMP,
        .cq_entries = URING_CQ_ENTRIES,
        .sq_thread_idle = 1000,
    });

    return IoUring.init_params(URING_ENTRIES, &params) catch return IoUring.init(URING_ENTRIES, 0);
}

fn ringSetNoDelay(fd: std.posix.fd_t) void {
    std.posix.setsockopt(fd, std.posix.IPPROTO.TCP, std.posix.TCP.NODELAY, std.mem.asBytes(&@as(c_int, 1))) catch {};
}

/// Per-connection ring state. buf accumulates frame bytes until whole frames are
/// present; send_buf holds the coalesced reply while a send is in flight; gen
/// guards against fd reuse.
const UringConn = struct {
    fd: std.posix.fd_t,
    gen: u24,
    buf: []u8,
    filled: usize,
    send_buf: []u8,
    staged: usize,
    inflight: usize,
    closing: bool,
};

const UringFrameCtx = struct {
    io: std.Io,
    ip: []const u8,
    port: u16,
    kernel_backlog: u31,
    recv_buf_size: usize,
};

/// Build a concrete framed io_uring worker entry with frame_fn baked in at
/// compile time, mirroring the zix.Http1 ring worker.
fn uringFrameWorkerFn(comptime frame_fn: FrameFn) fn (UringFrameCtx) void {
    return struct {
        const Worker = struct {
            ring: IoUring,
            slots: []?*UringConn,
            listener_fd: std.posix.fd_t,
            gen_counter: u24,
            recv_buf_size: usize,

            const W = @This();
            const allocator = std.heap.smp_allocator;
            const lx = std.os.linux;

            fn deinit(w: *W) void {
                for (w.slots) |maybe_conn| {
                    if (maybe_conn) |conn| {
                        _ = lx.close(conn.fd);
                        allocator.free(conn.buf);
                        allocator.free(conn.send_buf);
                        allocator.destroy(conn);
                    }
                }

                allocator.free(w.slots);
                w.ring.deinit();
            }

            fn getSqe(w: *W) ?*lx.io_uring_sqe {
                return w.ring.get_sqe() catch {
                    _ = w.ring.submit() catch return null;

                    return w.ring.get_sqe() catch null;
                };
            }

            fn lookup(w: *W, decoded: uring.Decoded) ?*UringConn {
                const idx: usize = @intCast(decoded.fd);
                if (idx >= w.slots.len) return null;

                const conn = w.slots[idx] orelse return null;
                if (conn.gen != decoded.gen) return null;

                return conn;
            }

            fn destroyConn(w: *W, conn: *UringConn) void {
                w.slots[@intCast(conn.fd)] = null;

                allocator.free(conn.buf);
                allocator.free(conn.send_buf);
                allocator.destroy(conn);
            }

            fn finishClose(w: *W, conn: *UringConn) void {
                _ = lx.close(conn.fd);
                w.destroyConn(conn);
            }

            fn beginClose(w: *W, conn: *UringConn) void {
                conn.closing = true;
                if (conn.inflight > 0) return;

                if (conn.staged > 0) {
                    w.submitSend(conn);
                    return;
                }

                w.finishClose(conn);
            }

            fn armAccept(w: *W) void {
                const sqe = w.getSqe() orelse return;
                sqe.prep_multishot_accept(w.listener_fd, null, null, 0);
                sqe.user_data = uring.packUserData(.accept, 0, w.listener_fd);
            }

            fn armRecv(w: *W, conn: *UringConn) void {
                if (conn.filled >= conn.buf.len) {
                    w.beginClose(conn);
                    return;
                }

                const sqe = w.getSqe() orelse {
                    w.beginClose(conn);
                    return;
                };
                sqe.prep_recv(conn.fd, conn.buf[conn.filled..], 0);
                sqe.user_data = uring.packUserData(.recv, conn.gen, conn.fd);
            }

            fn submitSend(w: *W, conn: *UringConn) void {
                const sqe = w.getSqe() orelse {
                    w.finishClose(conn);
                    return;
                };
                sqe.prep_send(conn.fd, conn.send_buf[0..conn.staged], lx.MSG.NOSIGNAL);
                sqe.user_data = uring.packUserData(.send, conn.gen, conn.fd);

                conn.inflight = conn.staged;
            }

            fn handleAccept(w: *W, cqe: lx.io_uring_cqe) void {
                const rearm = (cqe.flags & lx.IORING_CQE_F_MORE) == 0;
                defer if (rearm) w.armAccept();

                if (cqe.res < 0) return;

                const conn_fd: std.posix.fd_t = cqe.res;
                const idx: usize = @intCast(conn_fd);
                if (idx >= w.slots.len) {
                    _ = lx.close(conn_fd);
                    return;
                }

                ringSetNoDelay(conn_fd);

                const conn = allocator.create(UringConn) catch {
                    _ = lx.close(conn_fd);
                    return;
                };
                const buf = allocator.alloc(u8, w.recv_buf_size) catch {
                    allocator.destroy(conn);
                    _ = lx.close(conn_fd);
                    return;
                };
                const send_buf = allocator.alloc(u8, URING_SEND_BUF_SIZE) catch {
                    allocator.free(buf);
                    allocator.destroy(conn);
                    _ = lx.close(conn_fd);
                    return;
                };

                w.gen_counter +%= 1;
                conn.* = .{
                    .fd = conn_fd,
                    .gen = w.gen_counter,
                    .buf = buf,
                    .filled = 0,
                    .send_buf = send_buf,
                    .staged = 0,
                    .inflight = 0,
                    .closing = false,
                };
                w.slots[idx] = conn;

                w.armRecv(conn);
            }

            fn handleRecv(w: *W, cqe: lx.io_uring_cqe, decoded: uring.Decoded) void {
                const conn = w.lookup(decoded) orelse return;

                if (cqe.res <= 0) {
                    w.beginClose(conn);
                    return;
                }

                conn.filled += @intCast(cqe.res);

                const outcome = w.dispatch(conn);

                if (conn.staged > 0) {
                    w.submitSend(conn);
                    if (outcome == .close) conn.closing = true;

                    return;
                }

                if (outcome == .close) {
                    w.beginClose(conn);
                    return;
                }

                w.armRecv(conn);
            }

            fn handleSend(w: *W, cqe: lx.io_uring_cqe, decoded: uring.Decoded) void {
                const conn = w.lookup(decoded) orelse return;

                if (cqe.res < 0) {
                    w.beginClose(conn);
                    return;
                }

                const sent: usize = @intCast(cqe.res);
                if (sent < conn.staged) {
                    std.mem.copyForwards(u8, conn.send_buf[0 .. conn.staged - sent], conn.send_buf[sent..conn.staged]);
                    conn.staged -= sent;
                    conn.inflight = 0;
                    w.submitSend(conn);

                    return;
                }

                conn.staged = 0;
                conn.inflight = 0;

                if (conn.closing) {
                    w.finishClose(conn);
                    return;
                }

                w.armRecv(conn);
            }

            /// Parse every complete length-prefixed frame in conn.buf and call
            /// frame_fn for each (reply staged through the sink into send_buf),
            /// then compact the trailing partial frame to the front.
            fn dispatch(w: *W, conn: *UringConn) FrameOutcome {
                _ = w;
                const fd = conn.fd;

                var sink = RespSink{ .fd = fd, .buf = conn.send_buf };
                tl_resp_sink = &sink;
                defer tl_resp_sink = null;

                var consumed: usize = 0;
                var keep_alive = true;
                while (conn.filled - consumed >= FRAME_LEN_PREFIX) {
                    const rem = conn.buf[consumed..conn.filled];
                    const len = std.mem.readInt(u32, rem[0..FRAME_LEN_PREFIX], .big);
                    if (len == 0 or len > FRAME_MAX_PAYLOAD or FRAME_LEN_PREFIX + len > conn.buf.len) {
                        keep_alive = false;
                        break;
                    }

                    const need = FRAME_LEN_PREFIX + len;
                    if (rem.len < need) break;

                    frame_fn(rem[FRAME_LEN_PREFIX..need], fd);
                    consumed += need;
                }

                if (consumed >= conn.filled) {
                    conn.filled = 0;
                } else if (consumed > 0) {
                    std.mem.copyForwards(u8, conn.buf[0 .. conn.filled - consumed], conn.buf[consumed..conn.filled]);
                    conn.filled -= consumed;
                }

                conn.staged = sink.len;
                if (sink.failed) return .close;

                return if (keep_alive) .keep_alive else .close;
            }

            fn run(w: *W) void {
                w.armAccept();

                var cqes: [URING_CQE_BATCH]lx.io_uring_cqe = undefined;
                while (true) {
                    _ = w.ring.submit_and_wait(1) catch |err| switch (err) {
                        error.SignalInterrupt => continue,
                        else => return,
                    };

                    const count = w.ring.copy_cqes(&cqes, 0) catch return;
                    for (cqes[0..count]) |cqe| {
                        const decoded = uring.unpackUserData(cqe.user_data);
                        switch (decoded.op) {
                            .accept => w.handleAccept(cqe),
                            .recv => w.handleRecv(cqe, decoded),
                            .send => w.handleSend(cqe, decoded),
                            .timeout => {},
                        }
                    }
                }
            }
        };

        fn run(ctx: UringFrameCtx) void {
            const addr = std.Io.net.IpAddress.resolve(ctx.io, ctx.ip, ctx.port) catch return;
            var net_server = addr.listen(ctx.io, .{
                .mode = .stream,
                .protocol = .tcp,
                .reuse_address = true,
                .kernel_backlog = ctx.kernel_backlog,
            }) catch return;
            defer net_server.deinit(ctx.io);
            const listener_fd = net_server.socket.handle;

            const slots = std.heap.smp_allocator.alloc(?*UringConn, 1 << 16) catch return;
            @memset(slots, null);

            var worker = Worker{
                .ring = undefined,
                .slots = slots,
                .listener_fd = listener_fd,
                .gen_counter = 0,
                .recv_buf_size = ctx.recv_buf_size,
            };
            worker.ring = initUringRing() catch return;
            defer worker.deinit();

            worker.run();
        }
    }.run;
}

fn runFramedUring(cfg: TcpServerConfig, io: std.Io, comptime frame_fn: FrameFn) !void {
    const worker_count = if (cfg.workers == 0) (std.Thread.getCpuCount() catch 1) else cfg.workers;

    logSystem(cfg, "listening on {s}:{d} (io_uring framed/{d}, shared-nothing)", .{ cfg.ip, cfg.port, worker_count });

    const threads = try std.heap.smp_allocator.alloc(std.Thread, worker_count);
    defer std.heap.smp_allocator.free(threads);

    const worker_fn = uringFrameWorkerFn(frame_fn);
    for (threads) |*t|
        t.* = try std.Thread.spawn(
            .{ .stack_size = 512 * 1024 },
            worker_fn,
            .{UringFrameCtx{
                .io = io,
                .ip = cfg.ip,
                .port = cfg.port,
                .kernel_backlog = cfg.kernel_backlog,
                .recv_buf_size = cfg.max_recv_buf,
            }},
        );

    for (threads) |t| t.join();
}

/// Blocking adapter: wrap a FrameFn in a per-connection HandlerFn that reads
/// length-prefixed frames and dispatches each. Used for every dispatch model
/// other than .URING so runFramed works everywhere.
fn frameAdapter(comptime frame_fn: FrameFn) HandlerFn {
    return struct {
        fn handle(stream: std.Io.net.Stream, io: std.Io) void {
            defer stream.close(io);
            const fd = stream.socket.handle;

            const payload_buf = std.heap.smp_allocator.alloc(u8, FRAME_MAX_PAYLOAD) catch return;
            defer std.heap.smp_allocator.free(payload_buf);

            var read_buf: [4096]u8 = undefined;
            var reader = stream.reader(io, &read_buf);

            while (true) {
                const len = reader.interface.takeVarInt(u32, .big, FRAME_LEN_PREFIX) catch return;
                if (len == 0 or len > FRAME_MAX_PAYLOAD) return;

                reader.interface.readSliceAll(payload_buf[0..len]) catch return;

                frame_fn(payload_buf[0..len], fd);
            }
        }
    }.handle;
}

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
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();

    try std.testing.expectError(
        error.PortNotConfigured,
        Server.init(echoHandler, .{ .io = threaded.io(), .ip = "127.0.0.1", .port = 0 }),
    );
}

test "zix test: TcpServer init, valid config succeeds and deinit is safe" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();

    var server = try Server.init(echoHandler, .{ .io = threaded.io(), .ip = "127.0.0.1", .port = 9300 });
    server.deinit();
}

test "zix test: TcpServer init with EPOLL dispatch model succeeds and deinit is safe" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();

    var server = try Server.init(echoHandler, .{ .io = threaded.io(), .ip = "127.0.0.1", .port = 9300, .dispatch_model = .EPOLL });
    server.deinit();
}

test "zix test: TcpServer EPOLL uses workers field for worker count, pool_size is ignored" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();

    const server = try Server.init(echoHandler, .{
        .io = threaded.io(),
        .ip = "127.0.0.1",
        .port = 9300,
        .dispatch_model = .EPOLL,
        .workers = 4,
        .pool_size = 99,
    });
    try std.testing.expectEqual(@as(usize, 4), server.config.workers);
    try std.testing.expectEqual(@as(usize, 99), server.config.pool_size);
}

test "zix test: TcpServer init, timeout fields default to zero" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();

    const server = try Server.init(echoHandler, .{ .io = threaded.io(), .ip = "127.0.0.1", .port = 9300 });
    try std.testing.expectEqual(@as(u32, 0), server.config.recv_timeout_ms);
    try std.testing.expectEqual(@as(u32, 0), server.config.send_timeout_ms);
}

test "zix test: TcpServer init, timeout fields stored from config" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();

    const server = try Server.init(echoHandler, .{
        .io = threaded.io(),
        .ip = "127.0.0.1",
        .port = 9300,
        .recv_timeout_ms = 5000,
        .send_timeout_ms = 3000,
    });
    try std.testing.expectEqual(@as(u32, 5000), server.config.recv_timeout_ms);
    try std.testing.expectEqual(@as(u32, 3000), server.config.send_timeout_ms);
}

fn testTcpHandler(stream: std.Io.net.Stream, io: std.Io) void {
    stream.close(io);
}

fn testTcpFrame(payload: []const u8, fd: std.posix.fd_t) void {
    _ = payload;
    _ = fd;
}

test "zix test: Tcp.Server.init bakes a comptime handler and stores config" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();

    const server = try Server.init(testTcpHandler, .{
        .io = threaded.io(),
        .ip = "127.0.0.1",
        .port = 9300,
        .dispatch_model = .MIXED,
        .workers = 3,
    });
    try std.testing.expectEqual(@as(usize, 3), server.config.workers);
    try std.testing.expectEqual(DispatchModel.MIXED, server.config.dispatch_model);
}

test "zix test: Tcp.Server.initFramed, port zero returns PortNotConfigured" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();

    try std.testing.expectError(
        error.PortNotConfigured,
        Server.initFramed(testTcpFrame, .{ .io = threaded.io(), .ip = "127.0.0.1", .port = 0 }),
    );
}

test "zix test: Tcp.Server.initFramed, valid config succeeds and deinit is safe" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();

    var server = try Server.initFramed(testTcpFrame, .{ .io = threaded.io(), .ip = "127.0.0.1", .port = 9304, .dispatch_model = .URING });
    server.deinit();
}

test "zix test: applyConnTimeout, zero ms is no-op on real socket" {
    const linux = std.os.linux;
    const sock_fd: std.posix.fd_t = @intCast(linux.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0));
    try std.testing.expect(sock_fd > 0);
    defer _ = linux.close(sock_fd);

    applyConnTimeout(sock_fd, 0, 0);

    var recv_tv: std.posix.timeval = undefined;
    var opt_len: std.posix.socklen_t = @sizeOf(std.posix.timeval);
    _ = linux.getsockopt(sock_fd, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, @ptrCast(&recv_tv), &opt_len);
    try std.testing.expectEqual(@as(isize, 0), recv_tv.sec);
    try std.testing.expectEqual(@as(i64, 0), recv_tv.usec);
}

test "zix test: applyConnTimeout, sets SO_RCVTIMEO on real socket" {
    const linux = std.os.linux;
    const sock_fd: std.posix.fd_t = @intCast(linux.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0));
    try std.testing.expect(sock_fd > 0);
    defer _ = linux.close(sock_fd);

    applyConnTimeout(sock_fd, 2500, 0);

    var recv_tv: std.posix.timeval = undefined;
    var opt_len: std.posix.socklen_t = @sizeOf(std.posix.timeval);
    _ = linux.getsockopt(sock_fd, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, @ptrCast(&recv_tv), &opt_len);
    try std.testing.expectEqual(@as(isize, 2), recv_tv.sec);
    try std.testing.expectEqual(@as(i64, 500_000), recv_tv.usec);
}

test "zix test: applyConnTimeout, sets SO_SNDTIMEO on real socket" {
    const linux = std.os.linux;
    const sock_fd: std.posix.fd_t = @intCast(linux.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0));
    try std.testing.expect(sock_fd > 0);
    defer _ = linux.close(sock_fd);

    applyConnTimeout(sock_fd, 0, 1000);

    var send_tv: std.posix.timeval = undefined;
    var opt_len: std.posix.socklen_t = @sizeOf(std.posix.timeval);
    _ = linux.getsockopt(sock_fd, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, @ptrCast(&send_tv), &opt_len);
    try std.testing.expectEqual(@as(isize, 1), send_tv.sec);
    try std.testing.expectEqual(@as(i64, 0), send_tv.usec);
}
