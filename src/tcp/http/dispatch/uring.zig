//! zix http .URING dispatch model (Linux-only): shared-nothing io_uring ring per
//! worker. Each readable batch recvs into the connection buffer, runs one request
//! through processRequest with the response staged into a RespSink, and submits
//! one coalesced send. Half-duplex per connection, one request per buffer (matches
//! the EPOLL path, ADR-037 Phase 4 step 4).

const std = @import("std");
const common = @import("common.zig");
const epoll_model = @import("epoll.zig");
const logSystem = common.logSystem;
const processRequest = common.processRequest;
const pinToCpu = common.pinToCpu;
const getAvailableCpuCount = common.getAvailableCpuCount;
const effectiveCacheEntries = common.effectiveCacheEntries;
const setNoDelay = common.setNoDelay;
const initUringRing = common.initUringRing;
const UringHttpConn = common.UringHttpConn;
const HttpProcOutcome = common.HttpProcOutcome;
const MAX_FD = common.MAX_FD;
const URING_CQE_BATCH = common.URING_CQE_BATCH;
const URING_SEND_BUF_SIZE = common.URING_SEND_BUF_SIZE;
const parser = @import("../parser.zig");
const rcache = @import("../../../utils/response_cache.zig");
const resp_mod = @import("../response.zig");
const setCache = resp_mod.setCache;
const RespSink = resp_mod.RespSink;
const fdWriteAll = resp_mod.fdWriteAll;
const uring = @import("../../../multiplexers/ring.zig");
const slab = @import("../../../multiplexers/slab.zig");
const IoUring = std.os.linux.IoUring;

// --------------------------------------------------------- //
// URING dispatch (Linux): shared-nothing io_uring ring per worker.

/// One io_uring worker: a private SO_REUSEPORT listener and completion
/// loop. Each readable batch recvs into the connection buffer, runs one
/// request through processRequest with the response staged into a
/// RespSink, and submits one coalesced send. Half-duplex per connection,
/// one request per buffer (matches the EPOLL path, ADR-037 Phase 4 step 4).
fn uringWorker(server: anytype, io: std.Io, worker_id: usize) void {
    const ServerPtr = @TypeOf(server);
    const cfg = server.config;

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
        server: ServerPtr,
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
        .server = server,
        .io = io,
        .arena = &arena,
        .recv_buf_size = cfg.max_recv_buf,
    };
    worker.ring = initUringRing() catch return;
    defer worker.deinit();

    worker.run();
}

// --------------------------------------------------------- //
// URING model

/// URING dispatch (Linux-only): shared-nothing io_uring ring per worker.
pub fn runUring(server: anytype, io: std.Io) !void {
    const cfg = server.config;

    // Runtime probe: io_uring can be unavailable on this host (seccomp/sandbox,
    // RLIMIT_MEMLOCK, or an old kernel). Without this, every worker would fail
    // setup, return, and the server would vanish right after binding (a confusing
    // ServerStartTimeout downstream). Fall back to the EPOLL shared-nothing loop.
    var probe = initUringRing() catch |err| {
        logSystem(cfg, "io_uring unavailable ({s}): not suited to this environment (commonly RLIMIT_MEMLOCK, the ulimit -l cap, too low for the ring size). Falling back to EPOLL.", .{@errorName(err)});

        return epoll_model.runEpoll(server, io);
    };
    probe.deinit();

    const worker_count = if (cfg.workers == 0) getAvailableCpuCount() else cfg.workers;

    logSystem(cfg, "listening on {s}:{d} (io_uring, {d} workers, shared-nothing)", .{
        cfg.ip, cfg.port, worker_count,
    });

    const threads = try std.heap.smp_allocator.alloc(std.Thread, worker_count);
    defer std.heap.smp_allocator.free(threads);

    for (threads, 0..) |*t, idx| {
        t.* = try std.Thread.spawn(.{ .stack_size = 512 * 1024 }, uringWorker, .{ server, io, idx });
    }

    for (threads) |t| t.join();
}
