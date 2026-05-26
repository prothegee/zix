//! zix http server

const std = @import("std");
const Config = @import("config.zig").HttpServerConfig;
const DispatchModel = @import("config.zig").DispatchModel;
const Router = @import("router.zig").Router;
const HandlerFn = @import("router.zig").HandlerFn;
const Route = @import("router.zig").Route;
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;
const fdWriteAll = @import("response.zig").fdWriteAll;
const formatHttpDate = @import("response.zig").formatHttpDate;
const Context = @import("context.zig").Context;
const method = @import("method.zig");
const static = @import("static.zig");
const parser = @import("parser.zig");

// Global date cache — updated by a background timer thread (model 2) or the accept loop (model 1).
// Readers do a single atomic load — no lock, no syscall per request.
// Double-buffered so the writer never tears a read in progress.
var g_date_bufs: [2][40]u8 = undefined;
var g_date_lens: [2]usize = .{ 0, 0 };
var g_date_active = std.atomic.Value(usize).init(0);
var g_date_secs = std.atomic.Value(u64).init(0);

fn updateDateCache(io: std.Io) void {
    const ts = std.Io.Clock.real.now(io);
    const raw_secs = ts.toSeconds();
    const cur_secs: u64 = if (raw_secs >= 0) @intCast(raw_secs) else 0;
    if (cur_secs != g_date_secs.load(.monotonic)) {
        const next_idx = 1 - g_date_active.load(.monotonic);
        const s = formatHttpDate(cur_secs, &g_date_bufs[next_idx]);
        g_date_lens[next_idx] = s.len;
        g_date_active.store(next_idx, .release);
        g_date_secs.store(cur_secs, .release);
    }
}

// --------------------------------------------------------- //
// Layer D: connection registry + timer eviction
// --------------------------------------------------------- //

const ConnEntry = struct {
    stream: std.Io.net.Stream,
    deadline: std.Io.Clock.Timestamp,
    done: std.atomic.Value(bool) = .init(false),
};

const ConnRegistry = struct {
    mutex: std.Io.Mutex = .init,
    entries: std.ArrayListUnmanaged(*ConnEntry) = .empty,

    fn register(self: *ConnRegistry, entry: *ConnEntry, io: std.Io) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.entries.append(std.heap.smp_allocator, entry) catch {};
    }

    fn deregister(self: *ConnRegistry, entry: *ConnEntry, io: std.Io) void {
        entry.done.store(true, .release);
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        for (self.entries.items, 0..) |e, i| {
            if (e == entry) {
                _ = self.entries.swapRemove(i);
                break;
            }
        }
    }

    fn evict(self: *ConnRegistry, io: std.Io) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const now = std.Io.Clock.Timestamp.now(io, .real);
        for (self.entries.items) |e| {
            if (!e.done.load(.acquire) and now.compare(.gte, e.deadline))
                e.stream.shutdown(io, .both) catch {};
        }
    }

    fn deinit(self: *ConnRegistry) void {
        self.entries.deinit(std.heap.smp_allocator);
    }
};

// --------------------------------------------------------- //

fn timerLoop(io: std.Io, registry: *ConnRegistry) void {
    while (true) {
        updateDateCache(io);
        registry.evict(io);
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(500), .awake) catch break;
    }
}

// --------------------------------------------------------- //

// Work queue shared between accept threads (producers) and pool threads (consumers).
// Accept threads push accepted streams immediately and never block on handling.
// Pool threads pop and handle each connection synchronously (blocking I/O, no scheduler).
// Implemented as a heap-backed ring buffer: push and pop are both O(1).
// The backing buffer doubles on overflow (initial capacity 16), allocated via smp_allocator.
const ConnQueue = struct {
    mutex: std.Io.Mutex = .init,
    ready: std.Io.Condition = .init,
    buf: []std.Io.net.Stream = &.{},
    head: usize = 0,
    len: usize = 0,
    closed: bool = false,

    // Push a new connection. Grows the ring buffer on overflow.
    // On OOM the stream is closed and the connection dropped.
    fn push(self: *ConnQueue, stream: std.Io.net.Stream, io: std.Io) void {
        self.mutex.lockUncancelable(io);
        if (self.len == self.buf.len) {
            const new_cap = if (self.buf.len == 0) 16 else self.buf.len * 2;
            const new_buf = std.heap.smp_allocator.alloc(std.Io.net.Stream, new_cap) catch {
                self.mutex.unlock(io);
                stream.close(io);
                return;
            };
            if (self.buf.len > 0) {
                for (0..self.len) |i| new_buf[i] = self.buf[(self.head + i) % self.buf.len];
                std.heap.smp_allocator.free(self.buf);
            }
            self.buf = new_buf;
            self.head = 0;
        }
        self.buf[(self.head + self.len) % self.buf.len] = stream;
        self.len += 1;
        self.mutex.unlock(io);
        self.ready.signal(io);
    }

    // Pop the next connection, blocking until one arrives.
    // Returns null only after close() has been called and the queue is empty.
    fn pop(self: *ConnQueue, io: std.Io) ?std.Io.net.Stream {
        self.mutex.lockUncancelable(io);
        while (self.len == 0) {
            if (self.closed) {
                self.mutex.unlock(io);
                return null;
            }
            self.ready.waitUncancelable(io, &self.mutex);
        }
        const stream = self.buf[self.head];
        self.head = (self.head + 1) % self.buf.len;
        self.len -= 1;
        self.mutex.unlock(io);
        return stream;
    }

    // Signal all waiting pool threads to drain and exit.
    fn close(self: *ConnQueue, io: std.Io) void {
        self.mutex.lockUncancelable(io);
        self.closed = true;
        self.mutex.unlock(io);
        self.ready.broadcast(io);
    }

    fn deinit(self: *ConnQueue) void {
        if (self.buf.len > 0) std.heap.smp_allocator.free(self.buf);
    }
};

// --------------------------------------------------------- //

// Work queue of ready connection fds for the EPOLL worker pool (Linux only).
// The single epoll loop (producer) pushes readable sockets, workers (consumers) pop them.
// Heap-backed ring buffer: push and pop are both O(1), doubling on overflow (initial 64).
const FdQueue = struct {
    mutex: std.Io.Mutex = .init,
    ready: std.Io.Condition = .init,
    buf: []std.posix.fd_t = &.{},
    head: usize = 0,
    len: usize = 0,
    closed: bool = false,

    // Push a ready fd. Grows the ring buffer on overflow. On OOM the fd is closed.
    fn push(self: *FdQueue, fd: std.posix.fd_t, io: std.Io) void {
        self.mutex.lockUncancelable(io);
        if (self.len == self.buf.len) {
            const new_cap = if (self.buf.len == 0) 64 else self.buf.len * 2;
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

    // Pop the next ready fd, blocking until one arrives.
    // Returns null only after close() has been called and the queue is empty.
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

// Internal generic implementation — use `Server.init(stack_threshold, routes, config)` publicly.
fn HttpServerImpl(comptime stack_threshold: usize, comptime routes: []const Route) type {
    return struct {
        config: Config,
        router: Router(routes) = .{},
        registry: ConnRegistry = .{},

        const Self = @This();

        // --------------------------------------------------------- //

        /// Outcome of processing one request: whether the connection may be reused.
        const ReqOutcome = enum { keep_alive, close };

        /// Brief:
        /// Disable Nagle on a socket so each response flushes immediately
        ///
        /// Param:
        /// fd - std.posix.fd_t
        fn setNoDelay(fd: std.posix.fd_t) void {
            if (comptime @import("builtin").target.os.tag != .windows) {
                std.posix.setsockopt(
                    fd,
                    std.posix.IPPROTO.TCP,
                    std.posix.TCP.NODELAY,
                    std.mem.asBytes(&@as(c_int, 1)),
                ) catch {};
            }
        }

        /// Brief:
        /// Process exactly one HTTP request on fd using caller-owned buffers
        ///
        /// Note:
        /// - Shared by the POOL keep-alive loop (called repeatedly) and the EPOLL
        ///   worker (called once per readable event)
        /// - Incremental recv loop accumulates bytes until the end-of-headers marker
        /// - Zero-copy parse: all request fields are offsets into buf_read
        /// - Date header read from the global double-buffered cache (one atomic load)
        /// - Falls back to static file serving, then 404, when no route matches
        ///
        /// Param:
        /// server   - *Self
        /// stream   - std.Io.net.Stream (passed to Context for upgrade handlers)
        /// fd       - std.posix.fd_t (raw socket for recv/send on the hot path)
        /// io       - std.Io
        /// buf_read - []u8 (read buffer, owned by caller)
        /// arena    - *std.heap.ArenaAllocator (reset to retain_capacity on entry)
        ///
        /// Return:
        /// - .keep_alive when the connection may serve another request
        /// - .close on error, streaming, unconsumed body, Connection: close, or peer hangup
        fn handleOneRequest(
            server: *Self,
            stream: std.Io.net.Stream,
            fd: std.posix.fd_t,
            io: std.Io,
            buf_read: []u8,
            arena: *std.heap.ArenaAllocator,
        ) ReqOutcome {
            _ = arena.reset(.retain_capacity);
            const allocator = arena.allocator();
            const cfg = server.config;

            // Incremental recv loop: accumulate bytes until \r\n\r\n is found.
            // Only the new tail is searched each iteration to avoid re-scanning.
            var filled: usize = 0;
            var found = false;

            while (filled < buf_read.len) {
                const n = std.posix.read(fd, buf_read[filled..]) catch break;
                if (n == 0) break; // peer closed
                const prev = filled;
                filled += n;
                const search_from = if (prev > 3) prev - 3 else 0;
                if (parser.findHeaderEnd(buf_read[0..filled], search_from)) |_| {
                    found = true;
                    break;
                }
            }

            if (!found) {
                if (filled >= buf_read.len) {
                    fdWriteAll(fd, "HTTP/1.1 431 Request Header Fields Too Large\r\nContent-Length: 0\r\n\r\n") catch {};
                }
                return .close;
            }

            // Zero-copy parse: all fields are offsets into buf_read.
            const head = parser.parse(buf_read[0..filled], cfg.max_request_headers.value()) catch {
                fdWriteAll(fd, "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n") catch {};
                return .close;
            } orelse return .close; // incomplete — should not happen since found == true

            var req = Request{
                .buf = buf_read[0..filled],
                .head = head,
                .fd = fd,
                .buf_filled = filled,
                .allocator = allocator,
            };
            var res = Response.init(fd, head.keep_alive, io, allocator, cfg.max_response_headers.value());

            // Zero-syscall Date: one atomic load from the global double-buffered cache.
            const idx = g_date_active.load(.acquire);
            res.date_cache = g_date_bufs[idx][0..g_date_lens[idx]];

            var ctx = Context{ .io = io, .allocator = allocator, .stream = stream, .logger = cfg.logger };
            // Layer B: optional handler deadline. Handlers call ctx.timedOut() between steps.
            if (cfg.handler_timeout_ms > 0) ctx = ctx.withTimeout(cfg.handler_timeout_ms);

            const matched = server.router.dispatch(&req, &res, &ctx) catch false;
            if (res.streaming) return .close;

            if (!matched) {
                var served = false;
                if (cfg.public_dir.len > 0) {
                    const sub = req.path();
                    const stripped = if (sub.len > 0 and sub[0] == '/') sub[1..] else sub;
                    if (stripped.len > 0) {
                        served = static.serve(&req, fd, stripped, cfg.public_dir, io) catch false;
                    }
                }
                if (!served) {
                    res.setStatus(.NOT_FOUND);
                    res.send("Not Found") catch {};
                }
            }

            if (cfg.logger) |lg| {
                const ua = req.header("user-agent") orelse "";
                const origin = req.header("origin") orelse "";
                lg.access(
                    method.stringFromEnum(req.method()),
                    req.path(),
                    @intFromEnum(res.status),
                    res.bytes_written,
                    ua,
                    origin,
                );
            }

            // Keep-alive: if there is a body and the handler did not consume it,
            // close rather than risk misaligned reads on the next request.
            if (head.content_length > 0 and req.body_cache == null) return .close;
            return if (head.keep_alive) .keep_alive else .close;
        }

        /// Brief:
        /// Handle a single TCP connection with a keep-alive request loop (POOL/MIXED/ASYNC)
        ///
        /// Note:
        /// - Sets TCP_NODELAY immediately on accepted connection
        /// - Stack-allocates the read buffer when max_client_request <= stack_threshold,
        ///   heap-allocates from smp_allocator otherwise
        /// - Per-connection arena is pre-warmed with max_allocator_size then reset
        ///   with retain_capacity before the loop — first request pays no heap cost
        /// - Loops calling handleOneRequest until it returns .close
        ///
        /// Param:
        /// stream - std.Io.net.Stream
        /// io     - std.Io
        /// server - *Self
        fn handleConnection(stream: std.Io.net.Stream, io: std.Io, server: *Self) void {
            defer stream.close(io);
            setNoDelay(stream.socket.handle);

            const cfg = server.config;
            // Raw fd — all recv/send on the hot path bypass std.Io dispatch.
            const fd = stream.socket.handle;

            // Layer D: connection guard via registry eviction.
            var maybe_conn_entry: ?ConnEntry = null;
            if (cfg.conn_timeout_ms > 0) {
                maybe_conn_entry = ConnEntry{
                    .stream = stream,
                    .deadline = std.Io.Clock.Timestamp.fromNow(
                        io,
                        std.Io.Clock.Duration{ .raw = std.Io.Duration.fromMilliseconds(cfg.conn_timeout_ms), .clock = .real },
                    ),
                };
                server.registry.register(&maybe_conn_entry.?, io);
            }
            defer if (maybe_conn_entry != null) server.registry.deregister(&maybe_conn_entry.?, io);

            // Read buffer: stack when max_client_request <= stack_threshold, heap otherwise.
            var stack_read: [stack_threshold]u8 = undefined;
            const buf_read = if (cfg.max_client_request <= stack_threshold)
                stack_read[0..cfg.max_client_request]
            else
                std.heap.smp_allocator.alloc(u8, cfg.max_client_request) catch return;
            defer if (cfg.max_client_request > stack_threshold) std.heap.smp_allocator.free(buf_read);

            var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
            defer arena.deinit();
            _ = arena.allocator().alloc(u8, cfg.max_allocator_size) catch {};
            _ = arena.reset(.retain_capacity);

            while (true) {
                if (handleOneRequest(server, stream, fd, io, buf_read, &arena) == .close) break;
            }
        }

        // --------------------------------------------------------- //

        /// Brief:
        /// Accept thread — accepts connections and enqueues them immediately.
        /// Never handles I/O stays in the accept loop at all times.
        ///
        /// Note:
        /// - reuse_address = true sets SO_REUSEADDR + SO_REUSEPORT on POSIX,
        ///   allowing all accept threads to listen on the same port in parallel
        fn workerEntry(self: *Self, queue: *ConnQueue, io: std.Io) void {
            const cfg = self.config;

            const addr = std.Io.net.IpAddress.resolve(io, cfg.ip, cfg.port) catch |err| {
                std.debug.print("zix: worker resolve error: {}\n", .{err});
                return;
            };
            var net_server = addr.listen(io, .{
                .mode = .stream,
                .kernel_backlog = @intCast(cfg.max_kernel_backlog),
                .reuse_address = true,
            }) catch |err| {
                std.debug.print("zix: worker listen error: {}\n", .{err});
                return;
            };
            defer net_server.deinit(io);

            while (true) {
                const stream = net_server.accept(io) catch |err| {
                    if (err != error.ConnectionAborted) {
                        std.debug.print("zix: worker accept error: {}\n", .{err});
                        break;
                    }
                    continue;
                };
                queue.push(stream, io);
            }
        }

        /// Brief:
        /// Pool thread — pops connections from the queue and handles each one
        /// synchronously with blocking I/O (no scheduler, no fiber overhead).
        /// Exits when the queue is closed and drained.
        fn poolEntry(self: *Self, queue: *ConnQueue, io: std.Io) void {
            while (queue.pop(io)) |stream| {
                handleConnection(stream, io, self);
            }
        }

        /// Brief:
        /// Accept thread for MIXED dispatch — accepts connections and dispatches each via io.async().
        /// No ConnQueue. The shared io Threaded pool handles scheduling.
        fn asyncWorkerEntry(self: *Self, io: std.Io) void {
            const cfg = self.config;

            const addr = std.Io.net.IpAddress.resolve(io, cfg.ip, cfg.port) catch |err| {
                std.debug.print("zix: worker resolve error: {}\n", .{err});
                return;
            };
            var net_server = addr.listen(io, .{
                .mode = .stream,
                .kernel_backlog = @intCast(cfg.max_kernel_backlog),
                .reuse_address = true,
            }) catch |err| {
                std.debug.print("zix: worker listen error: {}\n", .{err});
                return;
            };
            defer net_server.deinit(io);

            while (true) {
                const stream = net_server.accept(io) catch |err| {
                    if (err != error.ConnectionAborted) {
                        std.debug.print("zix: worker accept error: {}\n", .{err});
                        break;
                    }
                    continue;
                };
                _ = io.async(handleConnection, .{ stream, io, self });
            }
        }

        /// Brief:
        /// EPOLL worker — pops a ready socket, serves one request, then re-arms
        /// the one-shot interest (keep-alive) or removes and closes the connection
        ///
        /// Note:
        /// - Read buffer and arena are allocated once per worker thread and reused
        ///   across requests and connections (each request is self-contained)
        ///
        /// Param:
        /// self  - *Self
        /// queue - *FdQueue
        /// epfd  - std.posix.fd_t (epoll instance to re-arm or remove against)
        /// io    - std.Io
        fn epollWorkerEntry(self: *Self, queue: *FdQueue, epfd: std.posix.fd_t, io: std.Io) void {
            const linux = std.os.linux;
            const cfg = self.config;

            const buf_read = std.heap.smp_allocator.alloc(u8, cfg.max_client_request) catch return;
            defer std.heap.smp_allocator.free(buf_read);

            var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
            defer arena.deinit();
            _ = arena.allocator().alloc(u8, cfg.max_allocator_size) catch {};
            _ = arena.reset(.retain_capacity);

            while (queue.pop(io)) |fd| {
                const stream = std.Io.net.Stream{ .socket = .{ .handle = fd, .address = undefined } };
                if (handleOneRequest(self, stream, fd, io, buf_read, &arena) == .keep_alive) {
                    // Re-arm the one-shot interest so the next request wakes the loop.
                    var cev = linux.epoll_event{
                        .events = linux.EPOLL.IN | linux.EPOLL.ONESHOT | linux.EPOLL.RDHUP,
                        .data = .{ .fd = fd },
                    };
                    if (std.posix.errno(linux.epoll_ctl(epfd, linux.EPOLL.CTL_MOD, fd, &cev)) != .SUCCESS) {
                        _ = linux.epoll_ctl(epfd, linux.EPOLL.CTL_DEL, fd, null);
                        _ = linux.close(fd);
                    }
                } else {
                    _ = linux.epoll_ctl(epfd, linux.EPOLL.CTL_DEL, fd, null);
                    _ = linux.close(fd);
                }
            }
        }

        /// Brief:
        /// EPOLL dispatch: a single epoll event loop accepts connections and hands
        /// readable sockets to a worker pool. Linux-only.
        ///
        /// Note:
        /// - Listener is non-blocking and edge-triggered: accept is drained until EAGAIN
        /// - Connections register EPOLLIN | EPOLLONESHOT | EPOLLRDHUP, so each readable
        ///   socket is reported exactly once and one worker owns it until it re-arms
        ///   (keep-alive) or closes it. Idle keep-alive connections hold no thread
        /// - pool_size sets the worker count (0 = max(10, cpu * 2))
        ///
        /// Param:
        /// self - *Self
        /// io   - std.Io
        ///
        /// Return:
        /// !void (returns only on setup failure, otherwise the event loop runs forever)
        fn runEpoll(self: *Self, io: std.Io) !void {
            const linux = std.os.linux;
            const cfg = self.config;
            const cpu = try std.Thread.getCpuCount();
            const pool_size = if (cfg.pool_size == 0) @max(10, cpu * 2) else cfg.pool_size;

            const addr = std.Io.net.IpAddress.resolve(io, cfg.ip, cfg.port) catch |err| {
                std.debug.print("zix: epoll resolve error: {}\n", .{err});
                return err;
            };
            var net_server = addr.listen(io, .{
                .mode = .stream,
                .kernel_backlog = @intCast(cfg.max_kernel_backlog),
                .reuse_address = true,
            }) catch |err| {
                std.debug.print("zix: epoll listen error: {}\n", .{err});
                return err;
            };
            defer net_server.deinit(io);
            const listener_fd = net_server.socket.handle;

            // Make the listener non-blocking so edge-triggered accept can drain to EAGAIN.
            const cur_flags = linux.fcntl(listener_fd, std.posix.F.GETFL, 0);
            const nonblock_bit: u32 = @bitCast(std.posix.O{ .NONBLOCK = true });
            _ = linux.fcntl(listener_fd, std.posix.F.SETFL, cur_flags | @as(usize, nonblock_bit));

            const epfd_rc = linux.epoll_create1(linux.EPOLL.CLOEXEC);
            if (std.posix.errno(epfd_rc) != .SUCCESS) return error.EpollCreateFailed;
            const epfd: std.posix.fd_t = @intCast(epfd_rc);
            defer _ = linux.close(epfd);

            var lev = linux.epoll_event{
                .events = linux.EPOLL.IN | linux.EPOLL.ET,
                .data = .{ .fd = listener_fd },
            };
            if (std.posix.errno(linux.epoll_ctl(epfd, linux.EPOLL.CTL_ADD, listener_fd, &lev)) != .SUCCESS)
                return error.EpollCtlFailed;

            std.debug.print("zix: listening on {s}:{d} (epoll, {d} workers)\n", .{ cfg.ip, cfg.port, pool_size });

            var queue = FdQueue{};
            defer queue.deinit();

            const workers = try std.heap.smp_allocator.alloc(std.Thread, pool_size);
            defer std.heap.smp_allocator.free(workers);
            for (workers) |*t| {
                t.* = try std.Thread.spawn(.{ .stack_size = 512 * 1024 }, epollWorkerEntry, .{ self, &queue, epfd, io });
            }

            const max_events = 256;
            var events: [max_events]linux.epoll_event = undefined;
            while (true) {
                const wrc = linux.epoll_wait(epfd, &events, max_events, -1);
                switch (std.posix.errno(wrc)) {
                    .SUCCESS => {},
                    .INTR => continue,
                    else => break,
                }
                const n: usize = @intCast(wrc);
                for (events[0..n]) |ev| {
                    if (ev.data.fd == listener_fd) {
                        // Edge-triggered: drain the accept queue until it would block.
                        while (true) {
                            const arc = linux.accept4(listener_fd, null, null, std.posix.SOCK.CLOEXEC);
                            switch (std.posix.errno(arc)) {
                                .SUCCESS => {},
                                .AGAIN => break,
                                .INTR, .CONNABORTED => continue,
                                else => break,
                            }
                            const conn_fd: std.posix.fd_t = @intCast(arc);
                            setNoDelay(conn_fd);
                            var cev = linux.epoll_event{
                                .events = linux.EPOLL.IN | linux.EPOLL.ONESHOT | linux.EPOLL.RDHUP,
                                .data = .{ .fd = conn_fd },
                            };
                            if (std.posix.errno(linux.epoll_ctl(epfd, linux.EPOLL.CTL_ADD, conn_fd, &cev)) != .SUCCESS) {
                                _ = linux.close(conn_fd);
                            }
                        }
                    } else {
                        queue.push(ev.data.fd, io);
                    }
                }
            }

            queue.close(io);
            for (workers) |t| t.join();
        }

        // --------------------------------------------------------- //

        /// Brief:
        /// Initialize the HTTP server with the given config
        ///
        /// Param:
        /// config - HttpServerConfig
        ///
        /// Return:
        /// !Self
        pub fn init(config: Config) !Self {
            return .{ .config = config };
        }

        /// Brief:
        /// Free registry storage
        pub fn deinit(self: *Self) void {
            self.registry.deinit();
        }

        /// Brief:
        /// Start listening and accepting connections
        ///
        /// Note:
        /// - workers = 0 (default): cpu_count accept threads + max(10, cpu_count * 2) pool threads
        /// - workers = N: exactly N accept threads, same pool sizing formula
        /// - If config.public_dir is non-empty, validates the directory exists, returns error.PublicDirNotFound if not
        /// - Accept threads listen on the same port via SO_REUSEPORT
        /// - Pool threads handle connections synchronously via a shared work queue
        ///
        /// Return:
        /// !void
        pub fn run(self: *Self) !void {
            const cfg = self.config;
            const cpu = try std.Thread.getCpuCount();

            // Use caller's io if provided; otherwise create an internal Threaded backend.
            // Caller-provided io: async_limit and stack_size from InitOptions are respected.
            // Internal: stack_size=512KB reduces virtual memory and TLB pressure.
            var internal: ?std.Io.Threaded = if (cfg.io == null)
                std.Io.Threaded.init(std.heap.smp_allocator, .{ .stack_size = 512 * 1024 })
            else
                null;
            defer if (internal) |*t| t.deinit();
            const thread_io: std.Io = cfg.io orelse internal.?.io();

            if (cfg.public_dir.len > 0) {
                const dir = std.Io.Dir.openDir(std.Io.Dir.cwd(), thread_io, cfg.public_dir, .{}) catch return error.PublicDirNotFound;
                dir.close(thread_io);
            }

            // Background timer: updates date cache every 500ms, evicts timed-out connections.
            const timer_thread = try std.Thread.spawn(.{}, timerLoop, .{ thread_io, &self.registry });
            defer timer_thread.detach();

            switch (cfg.dispatch_model) {
                .POOL => {
                    const worker_count = if (cfg.workers == 0) cpu else cfg.workers;
                    const pool_size = if (cfg.pool_size == 0) @max(10, cpu * 2) else cfg.pool_size;

                    std.debug.print("zix: listening on {s}:{d} ({d} accept, {d} pool)\n", .{ cfg.ip, cfg.port, worker_count, pool_size });

                    var queue = ConnQueue{};
                    defer queue.deinit();

                    const pool_threads = try std.heap.smp_allocator.alloc(std.Thread, pool_size);
                    defer std.heap.smp_allocator.free(pool_threads);
                    for (pool_threads) |*t| {
                        t.* = try std.Thread.spawn(
                            .{ .stack_size = 512 * 1024 },
                            poolEntry,
                            .{ self, &queue, thread_io },
                        );
                    }

                    const acc_threads = try std.heap.smp_allocator.alloc(std.Thread, worker_count);
                    defer std.heap.smp_allocator.free(acc_threads);
                    for (acc_threads) |*t| {
                        t.* = try std.Thread.spawn(.{}, workerEntry, .{ self, &queue, thread_io });
                    }

                    for (acc_threads) |t| t.join();
                    queue.close(thread_io);
                    for (pool_threads) |t| t.join();
                },

                .ASYNC => {
                    std.debug.print("zix: listening on {s}:{d} (io.async)\n", .{ cfg.ip, cfg.port });

                    const addr = std.Io.net.IpAddress.resolve(thread_io, cfg.ip, cfg.port) catch |err| {
                        std.debug.print("zix: resolve error: {}\n", .{err});
                        return;
                    };
                    var net_server = addr.listen(thread_io, .{
                        .mode = .stream,
                        .kernel_backlog = @intCast(cfg.max_kernel_backlog),
                        .reuse_address = true,
                    }) catch |err| {
                        std.debug.print("zix: listen error: {}\n", .{err});
                        return;
                    };
                    defer net_server.deinit(thread_io);

                    while (true) {
                        const stream = net_server.accept(thread_io) catch |err| {
                            if (err != error.ConnectionAborted) {
                                std.debug.print("zix: accept error: {}\n", .{err});
                                break;
                            }
                            continue;
                        };
                        _ = thread_io.async(handleConnection, .{ stream, thread_io, self });
                    }
                },

                .MIXED => {
                    const worker_count = if (cfg.workers == 0) cpu else cfg.workers;

                    std.debug.print("zix: listening on {s}:{d} ({d} accept, io.async)\n", .{ cfg.ip, cfg.port, worker_count });

                    const acc_threads = try std.heap.smp_allocator.alloc(std.Thread, worker_count);
                    defer std.heap.smp_allocator.free(acc_threads);
                    for (acc_threads) |*t| {
                        t.* = try std.Thread.spawn(.{}, asyncWorkerEntry, .{ self, thread_io });
                    }

                    for (acc_threads) |t| t.join();
                },

                .EPOLL => {
                    if (comptime @import("builtin").target.os.tag == .linux) {
                        try self.runEpoll(thread_io);
                    } else {
                        std.debug.print("zix: EPOLL dispatch is Linux-only. Use .POOL on this platform.\n", .{});
                        return error.EpollUnsupported;
                    }
                },
            }
        }
    };
}

// --------------------------------------------------------- //

/// Brief:
/// HTTP server — initialize with a comptime stack buffer threshold and comptime route table
///
/// Note:
/// - stack_threshold sets the cutoff for stack vs heap I/O buffers per connection:
///   if max_client_request fits within stack_threshold the buffer lives on the
///   connection thread stack, otherwise heap-allocated
/// - stack_threshold must be comptime so Zig can size the stack arrays at compile time
/// - routes must be comptime: the router is baked into the server type at compile time
///   (no heap allocation, no dynamic registration after init)
/// - workers in config controls accept thread count:
///     0 (default) -> cpu_count accept threads, max(10, cpu_count * 2) pool threads
///     N           -> exactly N accept threads, same pool sizing formula
///
/// Usage:
/// ```zig
/// var server = try zix.Http.Server.init(4096, &[_]zix.Http.Route{
///     .{ .path = "/",      .handler = homeHandler },
///     .{ .path = "/api",   .handler = apiHandler,  .kind = .PREFIX },
///     .{ .path = "/u/:id", .handler = userHandler, .kind = .PARAM },
/// }, .{ .ip = "0.0.0.0", .port = 8080, ... });
/// ```
pub const Server = struct {
    /// Brief:
    /// Initialize the HTTP server
    ///
    /// Param:
    /// stack_threshold - comptime usize (stack buffer size cutoff, e.g. 4096)
    /// routes          - comptime []const Route (route table baked into server type)
    /// config          - HttpServerConfig
    ///
    /// Return:
    /// !HttpServerImpl(stack_threshold, routes)
    pub fn init(
        comptime stack_threshold: usize,
        comptime routes: []const Route,
        config: Config,
    ) !HttpServerImpl(stack_threshold, routes) {
        return HttpServerImpl(stack_threshold, routes).init(config);
    }
};
