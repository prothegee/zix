//! zix http dispatch: the shared request pipeline plus the helpers every model
//! reuses (ADR-043). processRequest / handleOneRequest / handleConnection are
//! the engine core (routes ride on the server's comptime-baked router, so they
//! take server: anytype). The connection registry, work queue, date cache,
//! cpu-affinity helpers, and the EPOLL / URING per-connection tables live here
//! too. The dispatch loops themselves are one file per model under dispatch/.

const std = @import("std");
const builtin = @import("builtin");
const Config = @import("../config.zig").HttpServerConfig;
const Router = @import("../router.zig").Router;
const Route = @import("../router.zig").Route;
const Request = @import("../request.zig").Request;
const Response = @import("../response.zig").Response;
const writeAllFD = @import("../response.zig").writeAllFD;
const formatHttpDate = @import("../response.zig").formatHttpDate;
const Context = @import("../context.zig").Context;
const method = @import("../method.zig");
const static = @import("../static.zig");
const parser = @import("../parser.zig");
const rcache = @import("../../../utils/response_cache.zig");
const setCache = @import("../response.zig").setCache;
const RespSink = @import("../response.zig").RespSink;
const resp_mod = @import("../response.zig");
const slab = @import("../../../multiplexers/slab.zig");

// --------------------------------------------------------- //

const timer_interval_ms: u32 = 500;
pub const conn_queue_initial_cap: usize = 16;
/// Max epoll events drained per epoll_wait call. 1024 lets a worker clear its
/// ready-fd set in one syscall at high connection counts.
pub const EPOLL_MAX_EVENTS: usize = 1024;

/// Effective cache slot count for a worker, honoring cache_max_total_bytes.
/// When a memory ceiling is set, the entry count is reduced so the slab
/// (entries * value_bytes) fits. ResponseCache.init then rounds down to a power
/// of two, so the slab never exceeds the ceiling.
pub fn effectiveCacheEntries(config: Config) u32 {
    if (config.cache_max_total_bytes == 0) return config.cache_max_entries;

    const value_bytes: usize = @max(1, config.cache_max_value_bytes);
    const fit = config.cache_max_total_bytes / value_bytes;
    const capped = @min(@as(usize, config.cache_max_entries), fit);

    return @intCast(@max(@as(usize, 1), capped));
}

// Global date cache: updated by a background timer thread (model 2) or the accept loop (model 1).
// Readers do a single atomic load, no lock, no syscall per request.
// Double-buffered so the writer never tears a read in progress.
pub var g_date_bufs: [2][40]u8 = undefined;
pub var g_date_lens: [2]usize = .{ 0, 0 };
pub var g_date_active = std.atomic.Value(usize).init(0);
pub var g_date_secs = std.atomic.Value(u64).init(0);

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
pub fn logSystem(config: Config, comptime fmt: []const u8, args: anytype) void {
    if (config.logger) |lg| {
        lg.system(.INFO, "http", fmt, args);
        return;
    }

    if (comptime builtin.mode == .Debug) std.debug.print("zix: " ++ fmt ++ "\n", args);
}

// --------------------------------------------------------- //
// Layer D: connection registry + timer eviction

const ConnEntry = struct {
    stream: std.Io.net.Stream,
    deadline: std.Io.Clock.Timestamp,
    done: std.atomic.Value(bool) = .init(false),
};

pub const ConnRegistry = struct {
    mutex: std.Io.Mutex = .init,
    entries: std.ArrayListUnmanaged(*ConnEntry) = .empty,

    pub fn register(self: *ConnRegistry, entry: *ConnEntry, io: std.Io) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.entries.append(std.heap.smp_allocator, entry) catch {};
    }

    pub fn deregister(self: *ConnRegistry, entry: *ConnEntry, io: std.Io) void {
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

    pub fn evict(self: *ConnRegistry, io: std.Io) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const now = std.Io.Clock.Timestamp.now(io, .real);
        for (self.entries.items) |e| {
            if (!e.done.load(.acquire) and now.compare(.gte, e.deadline))
                e.stream.shutdown(io, .both) catch {};
        }
    }

    pub fn deinit(self: *ConnRegistry) void {
        self.entries.deinit(std.heap.smp_allocator);
    }
};

// --------------------------------------------------------- //

pub fn timerLoop(io: std.Io, registry: *ConnRegistry) void {
    while (true) {
        updateDateCache(io);
        registry.evict(io);
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(timer_interval_ms), .awake) catch break;
    }
}

// --------------------------------------------------------- //

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

/// Set O_NONBLOCK on a descriptor (the TLS epoll listener, so accept4 returns EAGAIN when drained).
pub fn setNonBlock(fd: std.posix.fd_t) void {
    const linux = std.os.linux;
    const cur_flags = linux.fcntl(fd, std.posix.F.GETFL, 0);
    const nonblock_bit: u32 = @bitCast(std.posix.O{ .NONBLOCK = true });
    _ = linux.fcntl(fd, std.posix.F.SETFL, cur_flags | @as(usize, nonblock_bit));
}

/// Spin up to 50 us before blocking. Reduces wake-up latency on saturated
/// loopback benchmarks. Silent no-op when the kernel lacks SO_BUSY_POLL support.
pub fn setBusyPoll(fd: std.posix.fd_t, us: u32) void {
    const SO_BUSY_POLL: u32 = 46;
    std.posix.setsockopt(
        fd,
        std.posix.SOL.SOCKET,
        SO_BUSY_POLL,
        std.mem.asBytes(&@as(c_int, @intCast(us))),
    ) catch {};
}

/// Pin the calling thread to the CPU slot assigned to worker_id, respecting
/// the cgroup-allowed CPU mask so we never select a CPU the container cannot use.
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

/// Count CPUs available to this process via sched_getaffinity, respecting cgroup
/// and taskset restrictions. Falls back to std.Thread.getCpuCount when the syscall
/// fails.
pub fn getAvailableCpuCount() usize {
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
pub const MAX_FD: usize = 1 << 16;

/// Per-connection EPOLL recv state. buf is a slab slice (contiguous pre-allocated
/// region, Linux demand-paged). filled tracks accumulated bytes.
/// Empty slots are identified by buf.len == 0.
pub const EpollConn = struct {
    fd: std.posix.fd_t,
    buf: []u8,
    /// Compact slab slot backing buf, returned to the free-list on close so the
    /// resident recv slab packs to the live connection count, not the fd range.
    slot: u32 = 0,
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

/// Private per-worker fd to EpollConn map. Not shared between workers: a
/// connection fd is accepted and served by a single worker, and freed before its
/// fd can be reused, so a stale slot is always zeroed by the time it is reused.
///
/// Recv buffers live in a per-worker slab carved into fixed-size slots. A
/// connection draws a compact slot index from a free-list on accept (reusing a
/// closed connection's slot first), not its fd, so the resident slab tracks the
/// live connection count rather than the fd range. Indexing by fd instead spread
/// the touched pages across the whole fd space (fds climb under load and churn),
/// which held far more resident than the live set. Slots are page-aligned so a
/// closed slot's pages reclaim cleanly. Empty fd slots are identified by buf.len == 0.
pub const EpollConnTable = struct {
    slots: []EpollConn,
    slab: []u8,
    /// Usable recv bytes per connection (config.max_recv_buf).
    buf_size: usize,
    /// Slab bytes per slot: buf_size rounded up to a page so a released slot's
    /// pages reclaim without touching a live neighbor slot.
    stride: usize,
    /// Stack of closed slot indices available for reuse, newest on top.
    free_slots: []u32,
    free_count: usize,
    /// Next never-used slot index. Slots are handed out compactly from 0, so the
    /// touched slab prefix bounds the resident recv memory.
    slot_top: usize,

    pub fn init(buf_size: usize) !EpollConnTable {
        // Slots are mmap'd (kernel-zeroed, demand-paged) rather than allocated +
        // memset, so untouched slots cost no physical memory and the array does
        // not fault in all MAX_FD slots per worker. See multiplexers/slab.
        const slots = try slab.mapZeroedSlots(EpollConn, MAX_FD);
        errdefer slab.unmapSlots(slots);

        // Page-align the slot stride so a closed slot's MADV_DONTNEED reclaims
        // whole pages, never a page half-shared with a live neighbor slot.
        const stride = std.mem.alignForward(usize, buf_size, std.heap.page_size_min);

        // Slab not memset: physical pages committed only on first recv per slot.
        const recv_slab = try std.heap.smp_allocator.alloc(u8, MAX_FD * stride);
        errdefer std.heap.smp_allocator.free(recv_slab);

        const free_slots = try std.heap.smp_allocator.alloc(u32, MAX_FD);

        return .{
            .slots = slots,
            .slab = recv_slab,
            .buf_size = buf_size,
            .stride = stride,
            .free_slots = free_slots,
            .free_count = 0,
            .slot_top = 0,
        };
    }

    pub fn deinit(self: *EpollConnTable) void {
        std.heap.smp_allocator.free(self.free_slots);
        std.heap.smp_allocator.free(self.slab);
        slab.unmapSlots(self.slots);
    }

    pub fn get(self: *EpollConnTable, fd: std.posix.fd_t) ?*EpollConn {
        const idx: usize = @intCast(fd);
        if (idx >= self.slots.len) return null;

        const conn = &self.slots[idx];

        return if (conn.buf.len > 0) conn else null;
    }

    /// Draw a compact slab slot: reuse a closed slot when one is free, else take
    /// the next never-used slot. Null when the slab is exhausted (all MAX_FD slots live).
    fn acquireSlot(self: *EpollConnTable) ?u32 {
        if (self.free_count > 0) {
            self.free_count -= 1;

            return self.free_slots[self.free_count];
        }

        if (self.slot_top >= MAX_FD) return null;

        const slot: u32 = @intCast(self.slot_top);
        self.slot_top += 1;

        return slot;
    }

    pub fn alloc(self: *EpollConnTable, fd: std.posix.fd_t) ?*EpollConn {
        const idx: usize = @intCast(fd);
        if (idx >= self.slots.len) return null;

        const slot = self.acquireSlot() orelse return null;
        const buf = self.slab[slot * self.stride ..][0..self.buf_size];
        self.slots[idx] = .{ .fd = fd, .buf = buf, .slot = slot, .filled = 0 };

        return &self.slots[idx];
    }

    pub fn free(self: *EpollConnTable, fd: std.posix.fd_t) void {
        const idx: usize = @intCast(fd);
        if (idx >= self.slots.len) return;

        const conn = &self.slots[idx];
        if (conn.buf.len == 0) return;

        if (conn.write_pending.len > 0) std.heap.smp_allocator.free(conn.write_pending);

        // Return the slot pages to the OS and the slot index to the free-list, so the next accept
        // reuses a low slot and the resident slab stays packed to the live set.
        const slot = conn.slot;
        slab.releaseSlabPages(self.slab[slot * self.stride ..][0..self.stride]);
        self.free_slots[self.free_count] = slot;
        self.free_count += 1;

        conn.* = std.mem.zeroes(EpollConn);
    }
};

// --------------------------------------------------------- //
// URING per-connection state + ring init (ADR-037 Phase 4 step 4)

/// SQ entries per worker ring.
pub const URING_ENTRIES: u16 = 4096;
/// CQ entries per worker ring (multishot completion headroom).
pub const URING_CQ_ENTRIES: u32 = 16 * 1024;
/// Max CQEs drained per loop pass.
pub const URING_CQE_BATCH: usize = 512;
/// Per-connection staged-response buffer: one coalesced send per request.
pub const URING_SEND_BUF_SIZE: usize = 16 * 1024;
/// io_uring SQPOLL kernel-thread idle before it sleeps, in milliseconds. Inert
/// unless IORING_SETUP_SQPOLL is set (it is not here), kept for when it is.
pub const URING_SQ_THREAD_IDLE_MS: u32 = 1000;

/// Per-worker EPOLL response staging buffer: the handler's writes coalesce here,
/// the worker flushes once, and any unwritten tail is staged for EPOLLOUT.
pub const EPOLL_OUT_BUF_SIZE: usize = 64 * 1024;

/// Outcome of one ring process pass over a connection's read buffer.
pub const HttpProcOutcome = enum { need_more, keep_alive, close };

/// Initialize a worker ring with the single-issuer fast-path flags, falling back
/// to a flagless ring when the kernel does not support them. Mirrors the
/// zix.Http1 ring init.
pub fn initUringRing() !std.os.linux.IoUring {
    const linux = std.os.linux;
    var params = std.mem.zeroInit(linux.io_uring_params, .{
        .flags = linux.IORING_SETUP_SINGLE_ISSUER |
            linux.IORING_SETUP_DEFER_TASKRUN |
            linux.IORING_SETUP_CQSIZE |
            linux.IORING_SETUP_CLAMP,
        .cq_entries = URING_CQ_ENTRIES,
        .sq_thread_idle = URING_SQ_THREAD_IDLE_MS,
    });

    return std.os.linux.IoUring.init_params(URING_ENTRIES, &params) catch return std.os.linux.IoUring.init(URING_ENTRIES, 0);
}

/// Per-connection ring state. buf accumulates request bytes until the header end
/// is found, send_buf holds the coalesced response while a send is in flight, and
/// gen guards against fd reuse. One request is served per buffer (no pipelined
/// drain), matching the EPOLL path.
pub const UringHttpConn = struct {
    fd: std.posix.fd_t,
    gen: u24,
    buf: []u8,
    filled: usize,
    send_buf: []u8,
    staged: usize,
    inflight: usize,
    closing: bool,
    /// Idle-pool links, valid only while this connection sits in the worker's idle pool between a
    /// close and the next accept that reuses it. The warm pool is doubly linked (most-recently-used
    /// at the head, least-recently-used at the tail) so the release path evicts the LRU tail in O(1).
    /// The cold stack uses next only. Mirrors the zix.Http1 URING idle pool.
    next: ?*UringHttpConn = null,
    prev: ?*UringHttpConn = null,
};

/// Accept every pending connection on listener_fd and register each in epfd.
/// Level-triggered, draining to EAGAIN guarantees no accept is missed.
pub fn epollAcceptAll(table: *EpollConnTable, epfd: std.posix.fd_t, listener_fd: std.posix.fd_t, busy_poll_us: u32) void {
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
        setBusyPoll(conn_fd, busy_poll_us);
        if (table.alloc(conn_fd) == null) {
            _ = linux.close(conn_fd);
            continue;
        }

        // Registered via the u64 data form (same bytes for an fd) so the dual-listener loop can
        // rely on the whole data word: TLS events carry a tag bit there, cleartext events must not.
        var ev = linux.epoll_event{
            .events = linux.EPOLL.IN | linux.EPOLL.RDHUP,
            .data = .{ .u64 = @intCast(conn_fd) },
        };
        if (std.posix.errno(linux.epoll_ctl(epfd, linux.EPOLL.CTL_ADD, conn_fd, &ev)) != .SUCCESS) {
            table.free(conn_fd);
            _ = linux.close(conn_fd);
        }
    }
}

// --------------------------------------------------------- //
// Shared request pipeline. routes ride on server.router (comptime-baked), so
// these take server: anytype rather than naming the generic server type.

/// Outcome of processing one request: whether the connection may be reused.
pub const ReqOutcome = enum { keep_alive, close };

/// Parse and dispatch one complete HTTP request from buf.
/// buf must contain the full header block. arena must be reset by the caller
/// before entry. This function does not reset it.
///
/// Return:
/// - .keep_alive when the connection may serve another request
/// - .close on error, streaming, unconsumed body, Connection: close, or peer hangup
pub fn processRequest(
    server: anytype,
    stream: std.Io.net.Stream,
    fd: std.posix.fd_t,
    io: std.Io,
    buf: []u8,
    arena: *std.heap.ArenaAllocator,
) ReqOutcome {
    const allocator = arena.allocator();
    const cfg = server.config;

    // Install the large-body SO_RCVBUF for this worker (read by Request.body when a big body comes
    // off the socket). Shared by every dispatch model, since all funnel through here.
    @import("../request.zig").setLargeBodyRcvbuf(cfg.large_body_rcvbuf);

    // Install the body read timeout so a multi-segment body on the non-blocking fd waits for the
    // next segment (up to this bound) instead of truncating at the first EAGAIN.
    @import("../request.zig").setBodyReadTimeout(cfg.body_read_timeout_ms);

    const head = parser.parse(buf, cfg.max_request_headers.value()) catch {
        writeAllFD(fd, "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n") catch {};
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
/// server - anytype (pointer to the HttpServerImpl instance)
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
    server: anytype,
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
            writeAllFD(fd, "HTTP/1.1 431 Request Header Fields Too Large\r\nContent-Length: 0\r\n\r\n") catch {};
        }
        return .close;
    }

    return processRequest(server, stream, fd, io, buf_read[0..filled], arena);
}

/// Stack read-buffer cap for the thread models (POOL / MIXED / ASYNC): a connection whose
/// max_recv_buf fits within this reads on the connection thread stack, a larger max_recv_buf
/// heap-allocates from smp_allocator. max_recv_buf (config) is the tuning knob, this cap only
/// bounds the comptime-sized stack array.
pub const stack_read_buf_max: usize = 4096;

/// Handle a single TCP connection with a keep-alive request loop (POOL/MIXED/ASYNC)
///
/// Note:
/// - Sets TCP_NODELAY immediately on accepted connection
/// - Stack-allocates the read buffer when max_recv_buf <= stack_read_buf_max,
///   heap-allocates from smp_allocator otherwise
/// - Per-connection arena is pre-warmed with max_allocator_size then reset
///   with retain_capacity before the loop, first request pays no heap cost
/// - Loops calling handleOneRequest until it yields .close
///
/// Param:
/// stream - std.Io.net.Stream
/// io - std.Io
/// server - anytype (pointer to the HttpServerImpl instance)
pub fn handleConnection(stream: std.Io.net.Stream, io: std.Io, server: anytype) void {
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

    // Read buffer: stack when max_recv_buf <= stack_read_buf_max, heap otherwise.
    var stack_read: [stack_read_buf_max]u8 = undefined;
    const buf_read = if (cfg.max_recv_buf <= stack_read_buf_max)
        stack_read[0..cfg.max_recv_buf]
    else
        std.heap.smp_allocator.alloc(u8, cfg.max_recv_buf) catch return;
    defer if (cfg.max_recv_buf > stack_read_buf_max) std.heap.smp_allocator.free(buf_read);

    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();
    _ = arena.allocator().alloc(u8, cfg.max_allocator_size) catch {};
    _ = arena.reset(.retain_capacity);

    while (true) {
        if (handleOneRequest(server, stream, fd, io, buf_read, &arena) == .close) break;
    }
}
