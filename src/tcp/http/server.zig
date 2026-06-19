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
const rcache = @import("../../utils/response_cache.zig");
const setCache = @import("response.zig").setCache;
const RespSink = @import("response.zig").RespSink;
const resp_mod = @import("response.zig");
const uring = @import("../../multiplexers/ring.zig");
const slab = @import("../../multiplexers/slab.zig");
const IoUring = std.os.linux.IoUring;

// --------------------------------------------------------- //

const timer_interval_ms: u32 = 500;
const conn_queue_initial_cap: usize = 16;
/// Max epoll events drained per epoll_wait call. 1024 lets a worker clear its
/// ready-fd set in one syscall at high connection counts.
const EPOLL_MAX_EVENTS: usize = 1024;

/// Effective cache slot count for a worker, honoring cache_max_total_bytes.
/// When a memory ceiling is set, the entry count is reduced so the slab
/// (entries * value_bytes) fits. ResponseCache.init then rounds down to a power
/// of two, so the slab never exceeds the ceiling.
fn effectiveCacheEntries(config: Config) u32 {
    if (config.cache_max_total_bytes == 0) return config.cache_max_entries;

    const value_bytes: usize = @max(1, config.cache_max_value_bytes);
    const fit = config.cache_max_total_bytes / value_bytes;
    const capped = @min(@as(usize, config.cache_max_entries), fit);

    return @intCast(@max(@as(usize, 1), capped));
}

// Global date cache: updated by a background timer thread (model 2) or the accept loop (model 1).
// Readers do a single atomic load, no lock, no syscall per request.
// Double-buffered so the writer never tears a read in progress.
var g_date_bufs: [2][40]u8 = undefined;
var g_date_lens: [2]usize = .{ 0, 0 };
var g_date_active = std.atomic.Value(usize).init(0);
var g_date_secs = std.atomic.Value(u64).init(0);

// --------------------------------------------------------- //

fn updateDateCache(io: std.Io) void {
    const timestamp = std.Io.Clock.real.now(io);
    const raw_secs = timestamp.toSeconds();
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

/// Emit a server lifecycle line. Routes through config.logger when present.
/// Without a logger it prints to stderr only in Debug builds (silent in release).
fn logSystem(config: Config, comptime fmt: []const u8, args: anytype) void {
    if (config.logger) |lg| {
        lg.system(.INFO, "http", fmt, args);
        return;
    }

    if (comptime @import("builtin").mode == .Debug) std.debug.print("zix: " ++ fmt ++ "\n", args);
}

// --------------------------------------------------------- //
// Layer D: connection registry + timer eviction

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
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(timer_interval_ms), .awake) catch break;
    }
}

// --------------------------------------------------------- //

// Work queue shared between accept threads (producers) and pool threads (consumers).
// Accept threads push accepted streams immediately and never block on handling.
// Pool threads pop and handle each connection synchronously (blocking I/O, no scheduler).
// Implemented as a heap-backed ring buffer: push and pop are both O(1).
// The backing buffer doubles on overflow (initial capacity conn_queue_initial_cap), allocated via smp_allocator.
const ConnQueue = struct {
    mutex: std.Io.Mutex = .init,
    ready: std.Io.Condition = .init,
    buf: []std.Io.net.Stream = &.{},
    head: usize = 0,
    len: usize = 0,
    closed: bool = false,

    // Push a new connection. Grows the ring buffer on overflow.
    // On OOM (Out Of Memory) the stream is closed and the connection dropped.
    fn push(self: *ConnQueue, stream: std.Io.net.Stream, io: std.Io) void {
        self.mutex.lockUncancelable(io);
        if (self.len == self.buf.len) {
            const new_cap = if (self.buf.len == 0) conn_queue_initial_cap else self.buf.len * 2;
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

/// Spin up to 50 us before blocking. Reduces wake-up latency on saturated
/// loopback benchmarks. Silent no-op when the kernel lacks SO_BUSY_POLL support.
fn setBusyPoll(fd: std.posix.fd_t) void {
    const SO_BUSY_POLL: u32 = 46;
    std.posix.setsockopt(
        fd,
        std.posix.SOL.SOCKET,
        SO_BUSY_POLL,
        std.mem.asBytes(&@as(c_int, 50)),
    ) catch {};
}

/// Pin the calling thread to the CPU slot assigned to worker_id, respecting
/// the cgroup-allowed CPU mask so we never select a CPU the container cannot use.
fn pinToCpu(worker_id: usize) void {
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

/// Count CPUs available to this process via sched_getaffinity, respecting cgroup
/// and taskset restrictions. Falls back to std.Thread.getCpuCount when the syscall
/// fails.
fn getAvailableCpuCount() usize {
    const linux = std.os.linux;
    var cpu_set: linux.cpu_set_t = undefined;
    if (linux.sched_getaffinity(0, @sizeOf(linux.cpu_set_t), &cpu_set) != 0) {
        return std.Thread.getCpuCount() catch 1;
    }

    var count: usize = 0;
    for (cpu_set) |word| count += @popCount(word);

    return if (count == 0) 1 else count;
}

// --------------------------------------------------------- //
// EPOLL per-connection recv state

/// Highest fd a worker's table can index. Linux hands out the lowest free fd,
/// so the table stays sparse. Connections on fds at or above this are refused.
const MAX_FD: usize = 1 << 16;

/// Per-connection EPOLL recv state. buf is a slab slice (contiguous pre-allocated
/// region, Linux demand-paged). filled tracks accumulated bytes.
/// Empty slots are identified by buf.len == 0.
const EpollConn = struct {
    fd: std.posix.fd_t,
    buf: []u8,
    filled: usize,
    /// Response bytes staged when a write hit EAGAIN (send buffer full). The
    /// worker arms EPOLLOUT and drains this on the next writable event instead of
    /// parking on a slow client. Heap-owned (smp_allocator) while non-empty.
    write_pending: []u8 = &.{},
    /// Bytes of write_pending already flushed.
    write_pending_off: usize = 0,
    /// Close the connection once the staged bytes finish flushing.
    write_pending_close: bool = false,
};

/// Private per-worker fd to EpollConn map. The slab (MAX_FD * buf_size virtual
/// bytes) is pre-allocated once at init, each accept assigns a slice from it with
/// no heap call. Physical pages are demand-paged, so only active connections
/// consume RAM.
const EpollConnTable = struct {
    slots: []EpollConn,
    slab: []u8,
    buf_size: usize,

    fn init(buf_size: usize) !EpollConnTable {
        // Slots are mmap'd (kernel-zeroed, demand-paged) rather than allocated +
        // memset, so untouched slots cost no physical memory and the array does
        // not fault in all MAX_FD slots per worker. See multiplexers/slab.
        const slots = try slab.mapZeroedSlots(EpollConn, MAX_FD);

        // Slab not memset: physical pages committed only on first recv per slot.
        const recv_slab = try std.heap.smp_allocator.alloc(u8, MAX_FD * buf_size);

        return .{ .slots = slots, .slab = recv_slab, .buf_size = buf_size };
    }

    fn deinit(self: *EpollConnTable) void {
        std.heap.smp_allocator.free(self.slab);
        slab.unmapSlots(self.slots);
    }

    fn get(self: *EpollConnTable, fd: std.posix.fd_t) ?*EpollConn {
        const idx: usize = @intCast(fd);
        if (idx >= self.slots.len) return null;

        const conn = &self.slots[idx];

        return if (conn.buf.len > 0) conn else null;
    }

    fn alloc(self: *EpollConnTable, fd: std.posix.fd_t) ?*EpollConn {
        const idx: usize = @intCast(fd);
        if (idx >= self.slots.len) return null;

        const buf = self.slab[idx * self.buf_size ..][0..self.buf_size];
        self.slots[idx] = .{ .fd = fd, .buf = buf, .filled = 0 };

        return &self.slots[idx];
    }

    fn free(self: *EpollConnTable, fd: std.posix.fd_t) void {
        const idx: usize = @intCast(fd);
        if (idx >= self.slots.len) return;

        const conn = &self.slots[idx];
        if (conn.buf.len == 0) return;

        if (conn.write_pending.len > 0) std.heap.smp_allocator.free(conn.write_pending);
        slab.releaseSlabPages(conn.buf);
        conn.* = std.mem.zeroes(EpollConn);
    }
};

// --------------------------------------------------------- //
// URING per-connection state + ring init (ADR-037 Phase 4 step 4)

/// SQ entries per worker ring.
const URING_ENTRIES: u16 = 4096;
/// CQ entries per worker ring (multishot completion headroom).
const URING_CQ_ENTRIES: u32 = 16 * 1024;
/// Max CQEs drained per loop pass.
const URING_CQE_BATCH: usize = 512;
/// Per-connection staged-response buffer: one coalesced send per request.
const URING_SEND_BUF_SIZE: usize = 16 * 1024;

/// Per-worker EPOLL response staging buffer: the handler's writes coalesce here,
/// the worker flushes once, and any unwritten tail is staged for EPOLLOUT.
const EPOLL_OUT_BUF_SIZE: usize = 64 * 1024;

/// Outcome of one ring process pass over a connection's read buffer.
const HttpProcOutcome = enum { need_more, keep_alive, close };

/// Initialize a worker ring with the single-issuer fast-path flags, falling back
/// to a flagless ring when the kernel does not support them. Mirrors the
/// zix.Http1 ring init.
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

/// Per-connection ring state. buf accumulates request bytes until the header end
/// is found, send_buf holds the coalesced response while a send is in flight, and
/// gen guards against fd reuse. One request is served per buffer (no pipelined
/// drain), matching the EPOLL path.
const UringHttpConn = struct {
    fd: std.posix.fd_t,
    gen: u24,
    buf: []u8,
    filled: usize,
    send_buf: []u8,
    staged: usize,
    inflight: usize,
    closing: bool,
};

/// Accept every pending connection on listener_fd and register each in epfd.
/// Level-triggered, draining to EAGAIN guarantees no accept is missed.
fn epollAcceptAll(table: *EpollConnTable, epfd: std.posix.fd_t, listener_fd: std.posix.fd_t) void {
    const linux = std.os.linux;

    while (true) {
        const rc = linux.accept4(listener_fd, null, null, std.posix.SOCK.NONBLOCK | std.posix.SOCK.CLOEXEC);
        switch (std.posix.errno(rc)) {
            .SUCCESS => {},
            .AGAIN => return,
            .INTR, .CONNABORTED => continue,
            else => return,
        }

        const conn_fd: std.posix.fd_t = @intCast(rc);
        setNoDelay(conn_fd);
        setBusyPoll(conn_fd);
        if (table.alloc(conn_fd) == null) {
            _ = linux.close(conn_fd);
            continue;
        }

        var ev = linux.epoll_event{
            .events = linux.EPOLL.IN | linux.EPOLL.RDHUP,
            .data = .{ .fd = conn_fd },
        };
        if (std.posix.errno(linux.epoll_ctl(epfd, linux.EPOLL.CTL_ADD, conn_fd, &ev)) != .SUCCESS) {
            table.free(conn_fd);
            _ = linux.close(conn_fd);
        }
    }
}

// --------------------------------------------------------- //

// Internal generic implementation: use `Server.init(stack_threshold, routes, config)` publicly.
fn HttpServerImpl(comptime stack_threshold: usize, comptime routes: []const Route) type {
    return struct {
        config: Config,
        router: Router(routes) = .{},
        registry: ConnRegistry = .{},

        const Self = @This();

        // --------------------------------------------------------- //

        /// Outcome of processing one request: whether the connection may be reused.
        const ReqOutcome = enum { keep_alive, close };

        /// Parse and dispatch one complete HTTP request from buf.
        /// buf must contain the full header block. arena must be reset by the caller
        /// before entry. This function does not reset it.
        ///
        /// Return:
        /// - .keep_alive when the connection may serve another request
        /// - .close on error, streaming, unconsumed body, Connection: close, or peer hangup
        fn processRequest(
            server: *Self,
            stream: std.Io.net.Stream,
            fd: std.posix.fd_t,
            io: std.Io,
            buf: []u8,
            arena: *std.heap.ArenaAllocator,
        ) ReqOutcome {
            const allocator = arena.allocator();
            const cfg = server.config;

            const head = parser.parse(buf, cfg.max_request_headers.value()) catch {
                fdWriteAll(fd, "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n") catch {};
                return .close;
            } orelse return .close;

            var req = Request{
                .buf = buf,
                .head = head,
                .fd = fd,
                .buf_filled = buf.len,
                .allocator = allocator,
            };
            var res = Response.init(fd, head.keep_alive, io, allocator, cfg.max_response_headers.value());

            // Zero-syscall Date: one atomic load from the global double-buffered cache.
            const idx = g_date_active.load(.acquire);
            res.date_cache = g_date_bufs[idx][0..g_date_lens[idx]];

            var ctx = Context{ .io = io, .allocator = allocator, .stream = stream, .logger = cfg.logger };

            // Layer B: optional handler deadline.
            if (cfg.handler_timeout_ms > 0) ctx = ctx.withTimeout(cfg.handler_timeout_ms);

            const matched = server.router.dispatch(&req, &res, &ctx) catch false;
            if (res.streaming) return .close;

            if (!matched) {
                var served = false;
                if (cfg.public_dir.len > 0) {
                    const request_path = req.path();
                    const stripped = if (request_path.len > 0 and request_path[0] == '/') request_path[1..] else request_path;
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
                const forwarded_for = req.header("x-forwarded-for") orelse "";
                const real_ip = req.header("x-real-ip") orelse "";
                const client_ip = if (forwarded_for.len > 0) blk: {
                    const comma = std.mem.indexOf(u8, forwarded_for, ",") orelse forwarded_for.len;
                    break :blk std.mem.trim(u8, forwarded_for[0..comma], " ");
                } else real_ip;
                const user_agent = req.header("user-agent") orelse "";
                const origin = req.header("origin") orelse "";
                lg.access(
                    method.stringFromEnum(req.method()),
                    req.path(),
                    @intFromEnum(res.status),
                    res.bytes_written,
                    client_ip,
                    user_agent,
                    origin,
                );
            }

            // Keep-alive: if there is a body and the handler did not consume it,
            // close rather than risk misaligned reads on the next request.
            if (head.content_length > 0 and req.body_cache == null) return .close;

            return if (head.keep_alive) .keep_alive else .close;
        }

        /// Recv loop + dispatch for one HTTP request on a blocking fd (POOL/ASYNC/MIXED).
        ///
        /// Note:
        /// - Incremental recv loop accumulates bytes until \r\n\r\n is found
        /// - Zero-copy parse: all request fields are offsets into buf_read
        /// - Date header read from the global double-buffered cache (one atomic load)
        /// - Falls back to static file serving, then 404, when no route matches
        ///
        /// Param:
        /// server - *Self
        /// stream - std.Io.net.Stream (passed to Context for upgrade handlers)
        /// fd - std.posix.fd_t (raw socket for recv/send on the hot path)
        /// io - std.Io
        /// buf_read - []u8 (read buffer, owned by caller)
        /// arena - *std.heap.ArenaAllocator (reset to retain_capacity on entry)
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
            var filled: usize = 0;
            var found = false;

            while (filled < buf_read.len) {
                const n = std.posix.read(fd, buf_read[filled..]) catch break;
                if (n == 0) break;
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

            return processRequest(server, stream, fd, io, buf_read[0..filled], arena);
        }

        /// Handle a single TCP connection with a keep-alive request loop (POOL/MIXED/ASYNC)
        ///
        /// Note:
        /// - Sets TCP_NODELAY immediately on accepted connection
        /// - Stack-allocates the read buffer when max_recv_buf <= stack_threshold,
        ///   heap-allocates from smp_allocator otherwise
        /// - Per-connection arena is pre-warmed with max_allocator_size then reset
        ///   with retain_capacity before the loop, first request pays no heap cost
        /// - Loops calling handleOneRequest until it yields .close
        ///
        /// Param:
        /// stream - std.Io.net.Stream
        /// io - std.Io
        /// server - *Self
        fn handleConnection(stream: std.Io.net.Stream, io: std.Io, server: *Self) void {
            defer stream.close(io);
            setNoDelay(stream.socket.handle);

            const cfg = server.config;
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

            // Read buffer: stack when max_recv_buf <= stack_threshold, heap otherwise.
            var stack_read: [stack_threshold]u8 = undefined;
            const buf_read = if (cfg.max_recv_buf <= stack_threshold)
                stack_read[0..cfg.max_recv_buf]
            else
                std.heap.smp_allocator.alloc(u8, cfg.max_recv_buf) catch return;
            defer if (cfg.max_recv_buf > stack_threshold) std.heap.smp_allocator.free(buf_read);

            var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
            defer arena.deinit();
            _ = arena.allocator().alloc(u8, cfg.max_allocator_size) catch {};
            _ = arena.reset(.retain_capacity);

            while (true) {
                if (handleOneRequest(server, stream, fd, io, buf_read, &arena) == .close) break;
            }
        }

        // --------------------------------------------------------- //

        /// Accept thread: accepts connections and enqueues them immediately.
        /// Stays in the accept loop at all times. Does not handle I/O.
        ///
        /// Note:
        /// - reuse_address = true sets SO_REUSEADDR + SO_REUSEPORT on POSIX,
        ///   allowing all accept threads to listen on the same port in parallel
        fn workerEntry(self: *Self, queue: *ConnQueue, io: std.Io) void {
            const cfg = self.config;

            const addr = std.Io.net.IpAddress.resolve(io, cfg.ip, cfg.port) catch |err| {
                logSystem(cfg, "worker resolve error: {}", .{err});
                return;
            };
            var net_server = addr.listen(io, .{
                .mode = .stream,
                .kernel_backlog = @intCast(cfg.kernel_backlog),
                .reuse_address = true, // SO_REUSEADDR + SO_REUSEPORT on POSIX, required for POOL, applied to all models
            }) catch |err| {
                logSystem(cfg, "worker listen error: {}", .{err});
                return;
            };
            defer net_server.deinit(io);

            while (true) {
                const stream = net_server.accept(io) catch |err| {
                    if (err != error.ConnectionAborted) {
                        logSystem(cfg, "worker accept error: {}", .{err});
                        break;
                    }
                    continue;
                };
                queue.push(stream, io);
            }
        }

        /// Pool thread: pops connections from the queue and handles each one
        /// synchronously with blocking I/O (no scheduler, no fiber overhead).
        /// Exits when the queue is closed and drained.
        fn poolEntry(self: *Self, queue: *ConnQueue, io: std.Io) void {
            while (queue.pop(io)) |stream| {
                handleConnection(stream, io, self);
            }
        }

        /// Accept thread for MIXED dispatch: accepts connections and dispatches each via io.async().
        /// No ConnQueue. The shared io Threaded pool handles scheduling.
        fn asyncWorkerEntry(self: *Self, io: std.Io, worker_id: usize) void {
            pinToCpu(worker_id);

            const cfg = self.config;

            const addr = std.Io.net.IpAddress.resolve(io, cfg.ip, cfg.port) catch |err| {
                logSystem(cfg, "worker resolve error: {}", .{err});
                return;
            };
            var net_server = addr.listen(io, .{
                .mode = .stream,
                .kernel_backlog = @intCast(cfg.kernel_backlog),
                .reuse_address = true, // SO_REUSEADDR + SO_REUSEPORT on POSIX, required for POOL, applied to all models
            }) catch |err| {
                logSystem(cfg, "worker listen error: {}", .{err});
                return;
            };
            defer net_server.deinit(io);

            while (true) {
                const stream = net_server.accept(io) catch |err| {
                    if (err != error.ConnectionAborted) {
                        logSystem(cfg, "worker accept error: {}", .{err});
                        break;
                    }
                    continue;
                };
                _ = io.async(handleConnection, .{ stream, io, self });
            }
        }

        /// EPOLL worker: owns one SO_REUSEPORT listener and one epoll instance.
        /// The kernel load-balances new connections across all per-worker listeners so
        /// there is no shared queue and no cross-thread fd handoff.
        ///
        /// Note:
        /// - EpollConnTable holds per-connection recv state. Each accept assigns a
        ///   slab slice with no heap call, filled tracks accumulated bytes across events.
        /// - Accepted fds are NONBLOCK: the recv loop reads until EAGAIN, allowing
        ///   headers that arrive in multiple TCP segments without blocking the worker.
        /// - Connections are level-triggered: the fd stays registered after each request
        ///   and re-fires when new data arrives (keep-alive without re-arm syscalls).
        /// - Arena and slab are allocated once per worker and reused across all connections.
        ///
        /// Param:
        /// self - *Self
        /// io - std.Io
        /// worker_id - usize (used for pinToCpu)
        fn epollWorker(self: *Self, io: std.Io, worker_id: usize) void {
            const linux = std.os.linux;
            const cfg = self.config;

            pinToCpu(worker_id);

            const addr = std.Io.net.IpAddress.resolve(io, cfg.ip, cfg.port) catch |err| {
                logSystem(cfg, "epoll worker resolve error: {}", .{err});
                return;
            };
            var net_server = addr.listen(io, .{
                .mode = .stream,
                .kernel_backlog = @intCast(cfg.kernel_backlog),
                .reuse_address = true, // SO_REUSEADDR + SO_REUSEPORT: each worker binds the same port
            }) catch |err| {
                logSystem(cfg, "epoll worker listen error: {}", .{err});
                return;
            };
            defer net_server.deinit(io);
            const listener_fd = net_server.socket.handle;

            // Non-blocking listener so epollAcceptAll drains to EAGAIN without blocking.
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

            var table = EpollConnTable.init(cfg.max_recv_buf) catch return;
            defer table.deinit();

            var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
            defer arena.deinit();
            _ = arena.allocator().alloc(u8, cfg.max_allocator_size) catch {};
            _ = arena.reset(.retain_capacity);

            // Per-worker response cache: lock-free by ownership, never shared.
            var response_cache: rcache.ResponseCache = undefined;
            var cache_on = false;
            if (cfg.response_cache) {
                if (rcache.ResponseCache.init(std.heap.smp_allocator, .{
                    .max_entries = effectiveCacheEntries(cfg),
                    .max_value_bytes = cfg.cache_max_value_bytes,
                })) |built| {
                    response_cache = built;
                    cache_on = true;
                    setCache(&response_cache, cfg.cache_ttl_ms);
                } else |_| {
                    cache_on = false;
                }
            }
            defer if (cache_on) {
                setCache(null, 0);
                response_cache.deinit();
            };

            // Per-worker response staging buffer: the handler's writes coalesce
            // into this sink, then the worker flushes it once per request.
            const out_buf = std.heap.smp_allocator.alloc(u8, EPOLL_OUT_BUF_SIZE) catch return;
            defer std.heap.smp_allocator.free(out_buf);

            var events: [EPOLL_MAX_EVENTS]linux.epoll_event = undefined;
            var epoll_timeout: i32 = -1;
            while (true) {
                const wait_result = linux.epoll_wait(epfd, &events, EPOLL_MAX_EVENTS, epoll_timeout);
                switch (std.posix.errno(wait_result)) {
                    .SUCCESS => {},
                    .INTR => continue,
                    else => return,
                }

                const event_count: usize = @intCast(wait_result);
                if (event_count == 0) {
                    epoll_timeout = -1;
                    continue;
                }

                for (events[0..event_count]) |ev| {
                    if (ev.data.fd == listener_fd) {
                        epollAcceptAll(&table, epfd, listener_fd);
                        continue;
                    }

                    const conn_fd = ev.data.fd;

                    if ((ev.events & (linux.EPOLL.HUP | linux.EPOLL.ERR | linux.EPOLL.RDHUP)) != 0) {
                        if (table.get(conn_fd)) |_| table.free(conn_fd);
                        _ = linux.epoll_ctl(epfd, linux.EPOLL.CTL_DEL, conn_fd, null);
                        _ = linux.close(conn_fd);
                        continue;
                    }

                    const conn = table.get(conn_fd) orelse continue;

                    // Drain a staged response before anything else: never start a
                    // new request while a prior response is still flushing, so the
                    // response order is preserved under pipelining (the connection
                    // is EPOLLOUT-armed only while write_pending holds bytes).
                    if (conn.write_pending.len > conn.write_pending_off) {
                        const pending = conn.write_pending[conn.write_pending_off..];
                        const written = resp_mod.fdWriteNonBlock(conn_fd, pending) orelse {
                            table.free(conn_fd);
                            _ = linux.epoll_ctl(epfd, linux.EPOLL.CTL_DEL, conn_fd, null);
                            _ = linux.close(conn_fd);
                            continue;
                        };

                        conn.write_pending_off += written;
                        if (conn.write_pending_off < conn.write_pending.len) continue;

                        const drained_close = conn.write_pending_close;
                        std.heap.smp_allocator.free(conn.write_pending);
                        conn.write_pending = &.{};
                        conn.write_pending_off = 0;
                        conn.write_pending_close = false;
                        conn.filled = 0;

                        if (drained_close) {
                            table.free(conn_fd);
                            _ = linux.epoll_ctl(epfd, linux.EPOLL.CTL_DEL, conn_fd, null);
                            _ = linux.close(conn_fd);
                            continue;
                        }

                        var disarm_ev = linux.epoll_event{
                            .events = linux.EPOLL.IN | linux.EPOLL.RDHUP,
                            .data = .{ .fd = conn_fd },
                        };
                        _ = linux.epoll_ctl(epfd, linux.EPOLL.CTL_MOD, conn_fd, &disarm_ev);

                        continue;
                    }

                    // Recv into conn.buf[conn.filled..]. NONBLOCK fd: read() returns
                    // EAGAIN when no more data is buffered in the kernel, so we break
                    // and wait for the next IN event (partial headers across segments).
                    var should_close = false;
                    var found_headers = false;
                    while (conn.filled < conn.buf.len) {
                        const n = std.posix.read(conn_fd, conn.buf[conn.filled..]) catch |err| {
                            if (err != error.WouldBlock) should_close = true;
                            break;
                        };
                        if (n == 0) {
                            should_close = true;
                            break;
                        }
                        const prev = conn.filled;
                        conn.filled += n;
                        const search_from = if (prev > 3) prev - 3 else 0;
                        if (parser.findHeaderEnd(conn.buf[0..conn.filled], search_from)) |_| {
                            found_headers = true;
                            break;
                        }
                    }

                    if (!should_close and !found_headers and conn.filled >= conn.buf.len) {
                        fdWriteAll(conn_fd, "HTTP/1.1 431 Request Header Fields Too Large\r\nContent-Length: 0\r\n\r\n") catch {};
                        should_close = true;
                    }

                    if (should_close) {
                        table.free(conn_fd);
                        _ = linux.epoll_ctl(epfd, linux.EPOLL.CTL_DEL, conn_fd, null);
                        _ = linux.close(conn_fd);
                        continue;
                    }

                    if (!found_headers) continue;

                    const stream = std.Io.net.Stream{ .socket = .{ .handle = conn_fd, .address = undefined } };
                    _ = arena.reset(.retain_capacity);

                    var sink = RespSink{ .fd = conn_fd, .buf = out_buf };
                    resp_mod.tl_resp_sink = &sink;
                    const outcome = processRequest(self, stream, conn_fd, io, conn.buf[0..conn.filled], &arena);
                    resp_mod.tl_resp_sink = null;

                    var close_conn = (outcome != .keep_alive) or sink.failed;

                    // Flush the coalesced response. A partial write (EAGAIN) stages
                    // the unwritten tail and arms EPOLLOUT instead of dropping it.
                    if (!sink.failed and sink.len > 0) {
                        if (resp_mod.fdWriteNonBlock(conn_fd, sink.buf[0..sink.len])) |written| {
                            if (written < sink.len) {
                                const remaining = sink.buf[written..sink.len];
                                if (std.heap.smp_allocator.alloc(u8, remaining.len)) |staged| {
                                    @memcpy(staged, remaining);
                                    conn.write_pending = staged;
                                    conn.write_pending_off = 0;
                                    conn.write_pending_close = (outcome != .keep_alive);
                                    conn.filled = 0;

                                    var arm_ev = linux.epoll_event{
                                        .events = linux.EPOLL.IN | linux.EPOLL.OUT | linux.EPOLL.RDHUP,
                                        .data = .{ .fd = conn_fd },
                                    };
                                    _ = linux.epoll_ctl(epfd, linux.EPOLL.CTL_MOD, conn_fd, &arm_ev);

                                    continue;
                                } else |_| {
                                    close_conn = true;
                                }
                            }
                        } else {
                            close_conn = true;
                        }
                    }

                    if (close_conn) {
                        table.free(conn_fd);
                        _ = linux.epoll_ctl(epfd, linux.EPOLL.CTL_DEL, conn_fd, null);
                        _ = linux.close(conn_fd);
                    } else {
                        conn.filled = 0;
                    }
                }

                epoll_timeout = 0;
            }
        }

        /// EPOLL dispatch: spawns shared-nothing event loop workers, each with its own
        /// SO_REUSEPORT listener and epoll instance. Linux-only.
        ///
        /// Note:
        /// - The kernel distributes connections across per-worker listeners with no shared
        ///   accept queue and no cross-thread fd handoffs.
        /// - workers = 0 (default): one worker per available CPU (respects cgroup mask).
        /// - workers = N: exactly N workers.
        ///
        /// Param:
        /// self - *Self
        /// io - std.Io
        ///
        /// Return:
        /// - !void (exits only on setup failure, otherwise runs forever)
        fn runEpoll(self: *Self, io: std.Io) !void {
            const worker_count = if (self.config.workers == 0) getAvailableCpuCount() else self.config.workers;

            logSystem(self.config, "listening on {s}:{d} (epoll, {d} workers, shared-nothing)", .{
                self.config.ip, self.config.port, worker_count,
            });

            const threads = try std.heap.smp_allocator.alloc(std.Thread, worker_count);
            defer std.heap.smp_allocator.free(threads);

            for (threads, 0..) |*t, idx| {
                t.* = try std.Thread.spawn(.{ .stack_size = 512 * 1024 }, epollWorker, .{ self, io, idx });
            }

            for (threads) |t| t.join();
        }

        // --------------------------------------------------------- //
        // URING dispatch (Linux): shared-nothing io_uring ring per worker.

        /// One io_uring worker: a private SO_REUSEPORT listener and completion
        /// loop. Each readable batch recvs into the connection buffer, runs one
        /// request through processRequest with the response staged into a
        /// RespSink, and submits one coalesced send. Half-duplex per connection,
        /// one request per buffer (matches the EPOLL path, ADR-037 Phase 4 step 4).
        fn uringWorker(self: *Self, io: std.Io, worker_id: usize) void {
            const cfg = self.config;

            pinToCpu(worker_id);

            const addr = std.Io.net.IpAddress.resolve(io, cfg.ip, cfg.port) catch return;
            var net_server = addr.listen(io, .{
                .mode = .stream,
                .kernel_backlog = @intCast(cfg.kernel_backlog),
                .reuse_address = true,
            }) catch return;
            defer net_server.deinit(io);
            const listener_fd = net_server.socket.handle;

            var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
            defer arena.deinit();
            _ = arena.allocator().alloc(u8, cfg.max_allocator_size) catch {};
            _ = arena.reset(.retain_capacity);

            // Per-worker response cache: lock-free by ownership, never shared.
            var response_cache: rcache.ResponseCache = undefined;
            var cache_on = false;
            if (cfg.response_cache) {
                if (rcache.ResponseCache.init(std.heap.smp_allocator, .{
                    .max_entries = effectiveCacheEntries(cfg),
                    .max_value_bytes = cfg.cache_max_value_bytes,
                })) |built| {
                    response_cache = built;
                    cache_on = true;
                    setCache(&response_cache, cfg.cache_ttl_ms);
                } else |_| {
                    cache_on = false;
                }
            }
            defer if (cache_on) {
                setCache(null, 0);
                response_cache.deinit();
            };

            const slots = slab.mapZeroedSlots(?*UringHttpConn, MAX_FD) catch return;

            const Worker = struct {
                ring: IoUring,
                slots: []?*UringHttpConn,
                listener_fd: std.posix.fd_t,
                gen_counter: u24,
                server: *Self,
                io: std.Io,
                arena: *std.heap.ArenaAllocator,
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

                    slab.unmapSlots(w.slots);
                    w.ring.deinit();
                }

                fn getSqe(w: *W) ?*lx.io_uring_sqe {
                    return w.ring.get_sqe() catch {
                        _ = w.ring.submit() catch return null;

                        return w.ring.get_sqe() catch null;
                    };
                }

                fn lookup(w: *W, decoded: uring.Decoded) ?*UringHttpConn {
                    const idx: usize = @intCast(decoded.fd);
                    if (idx >= w.slots.len) return null;

                    const conn = w.slots[idx] orelse return null;
                    if (conn.gen != decoded.gen) return null;

                    return conn;
                }

                fn destroyConn(w: *W, conn: *UringHttpConn) void {
                    w.slots[@intCast(conn.fd)] = null;

                    allocator.free(conn.buf);
                    allocator.free(conn.send_buf);
                    allocator.destroy(conn);
                }

                fn finishClose(w: *W, conn: *UringHttpConn) void {
                    _ = lx.close(conn.fd);
                    w.destroyConn(conn);
                }

                fn beginClose(w: *W, conn: *UringHttpConn) void {
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

                fn armRecv(w: *W, conn: *UringHttpConn) void {
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

                fn submitSend(w: *W, conn: *UringHttpConn) void {
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

                    setNoDelay(conn_fd);

                    const conn = allocator.create(UringHttpConn) catch {
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

                    switch (w.process(conn)) {
                        .need_more => w.armRecv(conn),
                        .keep_alive => {
                            if (conn.staged > 0) w.submitSend(conn) else w.armRecv(conn);
                        },
                        .close => {
                            if (conn.staged > 0) {
                                w.submitSend(conn);
                                conn.closing = true;
                            } else {
                                w.beginClose(conn);
                            }
                        },
                    }
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

                /// Find the header terminator (accumulating across recvs), then
                /// run one request with the response staged into a RespSink. The
                /// request is consumed (conn.filled reset to 0), matching the
                /// EPOLL one-request-per-buffer behavior.
                fn process(w: *W, conn: *UringHttpConn) HttpProcOutcome {
                    if (parser.findHeaderEnd(conn.buf[0..conn.filled], 0) == null) {
                        if (conn.filled >= conn.buf.len) {
                            fdWriteAll(conn.fd, "HTTP/1.1 431 Request Header Fields Too Large\r\nContent-Length: 0\r\n\r\n") catch {};
                            return .close;
                        }

                        return .need_more;
                    }

                    var sink = RespSink{ .fd = conn.fd, .buf = conn.send_buf };
                    resp_mod.tl_resp_sink = &sink;
                    _ = w.arena.reset(.retain_capacity);

                    const stream = std.Io.net.Stream{ .socket = .{ .handle = conn.fd, .address = undefined } };
                    const outcome = processRequest(w.server, stream, conn.fd, w.io, conn.buf[0..conn.filled], w.arena);
                    resp_mod.tl_resp_sink = null;

                    conn.staged = sink.len;
                    conn.filled = 0;
                    if (sink.failed) return .close;

                    return if (outcome == .keep_alive) .keep_alive else .close;
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
                                .close => {},
                            }
                        }
                    }
                }
            };

            var worker = Worker{
                .ring = undefined,
                .slots = slots,
                .listener_fd = listener_fd,
                .gen_counter = 0,
                .server = self,
                .io = io,
                .arena = &arena,
                .recv_buf_size = cfg.max_recv_buf,
            };
            worker.ring = initUringRing() catch return;
            defer worker.deinit();

            worker.run();
        }

        /// URING dispatch (Linux-only): shared-nothing io_uring ring per worker.
        fn runUring(self: *Self, io: std.Io) !void {
            const worker_count = if (self.config.workers == 0) getAvailableCpuCount() else self.config.workers;

            logSystem(self.config, "listening on {s}:{d} (io_uring, {d} workers, shared-nothing)", .{
                self.config.ip, self.config.port, worker_count,
            });

            const threads = try std.heap.smp_allocator.alloc(std.Thread, worker_count);
            defer std.heap.smp_allocator.free(threads);

            for (threads, 0..) |*t, idx| {
                t.* = try std.Thread.spawn(.{ .stack_size = 512 * 1024 }, uringWorker, .{ self, io, idx });
            }

            for (threads) |t| t.join();
        }

        // --------------------------------------------------------- //

        /// Initialize the HTTP server with the given config
        ///
        /// Param:
        /// config - HttpServerConfig
        ///
        /// Return:
        /// - !Self
        pub fn init(config: Config) !Self {
            return .{ .config = config };
        }

        /// Free registry storage
        pub fn deinit(self: *Self) void {
            self.registry.deinit();
        }

        /// Start listening and accepting connections
        ///
        /// Note:
        /// - workers = 0 (default): cpu_count accept threads + max(10, cpu_count * 2) pool threads
        /// - workers = N: exactly N accept threads, same pool sizing formula
        /// - If config.public_dir is non-empty, validates the directory exists. Yields error.PublicDirNotFound if absent
        /// - Accept threads listen on the same port via SO_REUSEPORT
        /// - Pool threads handle connections synchronously via a shared work queue
        ///
        /// Return:
        /// - !void
        pub fn run(self: *Self) !void {
            const cfg = self.config;
            const cpu = try std.Thread.getCpuCount();

            const thread_io: std.Io = cfg.io;

            if (cfg.public_dir.len > 0) {
                const dir = std.Io.Dir.openDir(std.Io.Dir.cwd(), thread_io, cfg.public_dir, .{}) catch return error.PublicDirNotFound;
                dir.close(thread_io);
            }

            // Background timer: updates date cache every 500ms, evicts timed-out connections.
            const timer_thread = try std.Thread.spawn(.{}, timerLoop, .{ thread_io, &self.registry });
            defer timer_thread.detach();

            const effective_model: DispatchModel = blk: {
                if (comptime @import("builtin").target.os.tag != .linux) {
                    // EPOLL and URING are Linux-only: fall back to POOL elsewhere.
                    if (cfg.dispatch_model == .EPOLL or cfg.dispatch_model == .URING) {
                        logSystem(cfg, "EPOLL/URING are Linux-only. Falling back to POOL.", .{});
                        break :blk .POOL;
                    }
                }
                break :blk cfg.dispatch_model;
            };

            switch (effective_model) {
                .POOL => {
                    const worker_count = if (cfg.workers == 0) cpu else cfg.workers;
                    const pool_size = if (cfg.pool_size == 0) @max(10, cpu * 2) else cfg.pool_size;

                    logSystem(cfg, "listening on {s}:{d} ({d} accept, {d} pool)", .{ cfg.ip, cfg.port, worker_count, pool_size });

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
                    logSystem(cfg, "listening on {s}:{d} (io.async)", .{ cfg.ip, cfg.port });

                    const addr = std.Io.net.IpAddress.resolve(thread_io, cfg.ip, cfg.port) catch |err| {
                        logSystem(cfg, "resolve error: {}", .{err});
                        return;
                    };
                    var net_server = addr.listen(thread_io, .{
                        .mode = .stream,
                        .kernel_backlog = @intCast(cfg.kernel_backlog),
                        .reuse_address = true, // SO_REUSEADDR + SO_REUSEPORT on POSIX, required for POOL, applied to all models
                    }) catch |err| {
                        logSystem(cfg, "listen error: {}", .{err});
                        return;
                    };
                    defer net_server.deinit(thread_io);

                    while (true) {
                        const stream = net_server.accept(thread_io) catch |err| {
                            if (err != error.ConnectionAborted) {
                                logSystem(cfg, "accept error: {}", .{err});
                                break;
                            }
                            continue;
                        };
                        _ = thread_io.async(handleConnection, .{ stream, thread_io, self });
                    }
                },

                .MIXED => {
                    const worker_count = if (cfg.workers == 0) cpu else cfg.workers;

                    logSystem(cfg, "listening on {s}:{d} ({d} accept, io.async)", .{ cfg.ip, cfg.port, worker_count });

                    const acc_threads = try std.heap.smp_allocator.alloc(std.Thread, worker_count);
                    defer std.heap.smp_allocator.free(acc_threads);
                    for (acc_threads, 0..) |*t, idx| {
                        t.* = try std.Thread.spawn(.{}, asyncWorkerEntry, .{ self, thread_io, idx });
                    }

                    for (acc_threads) |t| t.join();
                },

                .EPOLL => {
                    try self.runEpoll(thread_io);
                },

                // Native io_uring ring path (ADR-037 Phase 4 step 4).
                .URING => {
                    try self.runUring(thread_io);
                },
            }
        }
    };
}

// --------------------------------------------------------- //

/// HTTP server: initialize with a comptime stack buffer threshold and comptime route table
///
/// Note:
/// - stack_threshold sets the cutoff for stack vs heap I/O buffers per connection:
///   if max_recv_buf fits within stack_threshold the buffer lives on the
///   connection thread stack, otherwise heap-allocated
/// - stack_threshold must be comptime so Zig can size the stack arrays at compile time
/// - routes must be comptime: the router is baked into the server type at compile time
///   (no heap allocation, no dynamic registration after init)
/// - workers in config controls accept thread count:
///   0 (default) = cpu_count accept threads, max(10, cpu_count * 2) pool threads.
///   N           = exactly N accept threads, same pool sizing formula.
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
    /// Initialize the HTTP server
    ///
    /// Param:
    /// stack_threshold - comptime usize (stack buffer size cutoff, e.g. 4096)
    /// routes - comptime []const Route (route table baked into server type)
    /// config - HttpServerConfig
    ///
    /// Return:
    /// - !HttpServerImpl(stack_threshold, routes)
    pub fn init(
        comptime stack_threshold: usize,
        comptime routes: []const Route,
        config: Config,
    ) !HttpServerImpl(stack_threshold, routes) {
        return HttpServerImpl(stack_threshold, routes).init(config);
    }
};

// --------------------------------------------------------- //
// --------------------------------------------------------- //

test "zix http: EpollConnTable slab alloc and free lifecycle" {
    var table = try EpollConnTable.init(256);
    defer table.deinit();

    try std.testing.expectEqual(@as(?*EpollConn, null), table.get(5));

    const conn = table.alloc(5).?;
    try std.testing.expectEqual(@as(std.posix.fd_t, 5), conn.fd);
    try std.testing.expectEqual(@as(usize, 256), conn.buf.len);
    try std.testing.expectEqual(@as(usize, 0), conn.filled);

    const got = table.get(5).?;
    try std.testing.expectEqual(conn, got);

    table.free(5);
    try std.testing.expectEqual(@as(?*EpollConn, null), table.get(5));

    table.free(5);
}

test "zix http: EpollConnTable filled tracks accumulated bytes" {
    var table = try EpollConnTable.init(512);
    defer table.deinit();

    const conn = table.alloc(10).?;
    conn.filled = 42;
    try std.testing.expectEqual(@as(usize, 42), table.get(10).?.filled);

    table.free(10);
    try std.testing.expectEqual(@as(?*EpollConn, null), table.get(10));
}

test "zix http: EpollConnTable get returns null for out-of-range fd" {
    var table = try EpollConnTable.init(64);
    defer table.deinit();

    try std.testing.expectEqual(@as(?*EpollConn, null), table.get(MAX_FD));
    try std.testing.expectEqual(@as(?*EpollConn, null), table.alloc(MAX_FD));
}

test "zix http: getAvailableCpuCount returns at least 1" {
    const count = getAvailableCpuCount();
    try std.testing.expect(count >= 1);
}

test "zix http: effectiveCacheEntries honors the memory ceiling" {
    const base = Config{ .io = undefined, .ip = "127.0.0.1", .port = 0, .cache_max_entries = 1024, .cache_max_value_bytes = 16 * 1024 };

    // no ceiling: the configured entry count passes through unchanged
    try std.testing.expectEqual(@as(u32, 1024), effectiveCacheEntries(base));

    // ceiling caps the entry count so entries * value_bytes fits
    var capped = base;
    capped.cache_max_total_bytes = 256 * 1024;
    try std.testing.expectEqual(@as(u32, 16), effectiveCacheEntries(capped));

    // a tiny ceiling still yields at least one slot
    var tiny = base;
    tiny.cache_max_total_bytes = 1;
    try std.testing.expectEqual(@as(u32, 1), effectiveCacheEntries(tiny));
}

fn cacheRouteHandler(req: *Request, res: *Response, _: *Context) anyerror!void {
    if (res.serveCached(req)) return;

    try res.sendCached(req, "cached-body", 0);
}

test "zix http: EPOLL processRequest serves a cache miss then a hit" {
    var cache = try rcache.ResponseCache.init(std.testing.allocator, .{ .max_entries = 16, .max_value_bytes = 256 });
    defer cache.deinit();

    setCache(&cache, 1000);
    defer setCache(null, 0);

    const routes = [_]Route{.{ .path = "/cached", .handler = cacheRouteHandler }};
    const ServerImpl = HttpServerImpl(4096, &routes);
    var server = try ServerImpl.init(.{ .io = undefined, .ip = "127.0.0.1", .port = 0, .response_cache = true });
    defer server.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var fds: [2]i32 = undefined;
    try std.testing.expectEqual(@as(usize, 0), std.os.linux.socketpair(std.os.linux.AF.UNIX, std.os.linux.SOCK.STREAM, 0, &fds));
    defer _ = std.os.linux.close(fds[0]);
    defer _ = std.os.linux.close(fds[1]);

    const stream = std.Io.net.Stream{ .socket = .{ .handle = fds[1], .address = undefined } };
    const raw = "GET /cached HTTP/1.1\r\nHost: x\r\n\r\n";

    // first request: cache miss, handler builds and stores the response
    var buf1: [128]u8 = undefined;
    @memcpy(buf1[0..raw.len], raw);
    _ = arena.reset(.retain_capacity);
    _ = server.processRequest(stream, fds[1], undefined, buf1[0..raw.len], &arena);

    var first: [256]u8 = undefined;
    const n1 = try std.posix.read(fds[0], &first);
    try std.testing.expect(std.mem.endsWith(u8, first[0..n1], "\r\n\r\ncached-body"));

    // second request: cache hit, identical bytes served with no rebuild
    var buf2: [128]u8 = undefined;
    @memcpy(buf2[0..raw.len], raw);
    _ = arena.reset(.retain_capacity);
    _ = server.processRequest(stream, fds[1], undefined, buf2[0..raw.len], &arena);

    var second: [256]u8 = undefined;
    const n2 = try std.posix.read(fds[0], &second);
    try std.testing.expectEqualStrings(first[0..n1], second[0..n2]);

    // the entry is present and fresh
    try std.testing.expect(cache.lookup(rcache.hashKey("GET", "/cached", ""), rcache.nowMillis()) != null);
}
