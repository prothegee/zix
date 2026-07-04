//! zix http .EPOLL dispatch model (Linux-only): shared-nothing event-loop
//! workers, each with its own SO_REUSEPORT listener and epoll instance. The
//! kernel load-balances new connections across all per-worker listeners, so
//! there is no shared queue and no cross-thread fd handoff.

const std = @import("std");
const common = @import("common.zig");
const logSystem = common.logSystem;
const processRequest = common.processRequest;
const pinToCpu = common.pinToCpu;
const getAvailableCpuCount = common.getAvailableCpuCount;
const effectiveCacheEntries = common.effectiveCacheEntries;
const EpollConnTable = common.EpollConnTable;
const epollAcceptAll = common.epollAcceptAll;
const EPOLL_MAX_EVENTS = common.EPOLL_MAX_EVENTS;
const EPOLL_OUT_BUF_SIZE = common.EPOLL_OUT_BUF_SIZE;
const parser = @import("../parser.zig");
const rcache = @import("../../../utils/response_cache.zig");
const resp_mod = @import("../response.zig");
const setCache = resp_mod.setCache;
const setCompression = resp_mod.setCompression;
const RespSink = resp_mod.RespSink;
const writeAllFD = resp_mod.writeAllFD;

// --------------------------------------------------------- //

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
/// server - anytype (pointer to the HttpServerImpl instance)
/// io - std.Io
/// worker_id - usize (used for pinToCpu)
fn epollWorker(server: anytype, io: std.Io, worker_id: usize) void {
    const linux = std.os.linux;
    const cfg = server.config;

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

    // Response compression, stateless per worker. Active under .EPOLL and .URING,
    // like the cache.
    if (cfg.compress) setCompression(cfg.compress, cfg.compression_min_size, cfg.compression_max_out);
    defer setCompression(false, 0, 0);

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
                epollAcceptAll(&table, epfd, listener_fd, cfg.busy_poll_us);
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
                const written = resp_mod.writeNonBlockFD(conn_fd, pending) orelse {
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
                writeAllFD(conn_fd, "HTTP/1.1 431 Request Header Fields Too Large\r\nContent-Length: 0\r\n\r\n") catch {};
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
            const outcome = processRequest(server, stream, conn_fd, io, conn.buf[0..conn.filled], &arena);
            resp_mod.tl_resp_sink = null;

            var close_conn = (outcome != .keep_alive) or sink.failed;

            // Flush the coalesced response. A partial write (EAGAIN) stages
            // the unwritten tail and arms EPOLLOUT instead of dropping it.
            if (!sink.failed and sink.len > 0) {
                if (resp_mod.writeNonBlockFD(conn_fd, sink.buf[0..sink.len])) |written| {
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

// --------------------------------------------------------- //
// EPOLL model

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
/// server - anytype (pointer to the HttpServerImpl instance)
/// io - std.Io
///
/// Return:
/// - !void (exits only on setup failure, otherwise runs forever)
pub fn runEpoll(server: anytype, io: std.Io) !void {
    const cfg = server.config;
    const worker_count = if (cfg.workers == 0) getAvailableCpuCount() else cfg.workers;

    logSystem(cfg, "listening on {s}:{d} (epoll, {d} workers, shared-nothing)", .{
        cfg.ip, cfg.port, worker_count,
    });

    const threads = try std.heap.smp_allocator.alloc(std.Thread, worker_count);
    defer std.heap.smp_allocator.free(threads);

    // std.compress.flate.Compress is about 230 KB and is built on the handler's stack
    // frame, so a compressing handler (sendNegotiated) needs more than the default
    // 512 KB worker stack. Thread stacks are demand-paged, so the larger limit costs
    // almost no RSS, and the bump applies only when compression is enabled.
    const worker_stack: usize = if (cfg.compress) @max(cfg.worker_stack_size_bytes, cfg.worker_stack_compress_bytes) else cfg.worker_stack_size_bytes;

    for (threads, 0..) |*t, idx| {
        t.* = try std.Thread.spawn(.{ .stack_size = worker_stack }, epollWorker, .{ server, io, idx });
    }

    for (threads) |t| t.join();
}
