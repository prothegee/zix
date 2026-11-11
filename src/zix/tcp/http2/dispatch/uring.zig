//! ZIX Http2 dispatch uring model
//!
//! ### file: src/zix/tcp/http2/dispatch/uring.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Linux io_uring model: worker threads share nothing, each owns a listener,
//! a ring, and the h2c connections it accepted.
//!
//! ### note:
//!
//! - The ring owns accept (multishot) and recv. Responses go straight to the
//!   fd, so the accepted fd is non-blocking and a full send buffer waits in
//!   the writer instead of blocking the worker.
//! - One recv is in flight per connection. A generation tag in user_data
//!   keeps a stale completion off a reused fd.
//! - The frames written while one recv is processed leave as one write (see
//!   coalesce.zig).
//! - No fallback: a kernel without io_uring ends the run with SetupFailed.
//! - TLS is not part of this model yet.
//!
//! ---------------------------------------------------------
//!
//! ### licenses:
//!
//! - BSD-3-Clause
//!
//! ### copyright:
//!
//! - (c) Prana Ron // @prothegee // prothegee@pm.me
//!
//! ### contributors:
//!
//! - Prana Ron // @prothegee // prothegee@pm.me
//!

const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const IoUring = linux.IoUring;
const cache = @import("../cache.zig");
const coalesce = @import("../coalesce.zig");
const handler = @import("../handler.zig");
const log = @import("../log.zig");
const mux_dispatch = @import("../mux/mux_dispatch.zig");
const process = @import("../mux/process.zig");
const Config = @import("../Config.zig");
const MuxConn = @import("../mux/MuxConn.zig");
const ServeOpts = @import("../ServeOpts.zig");
const ResponseCache = @import("../../../utils/cache/ResponseCache.zig");
const cpu_affinity = @import("../../../multiplexers/cpu_affinity.zig");
const reuseport = @import("../../../multiplexers/reuseport.zig");
const slab = @import("../../../multiplexers/slab.zig");
const HandlerFn = handler.HandlerFn;

// --------------------------------------------------------- //
// Private:

/// Largest fd the worker slot table can name.
const MAX_FD: usize = 1 << 16;

/// SQ entries per worker ring.
const RING_ENTRIES: u16 = 4096;

/// CQ entries per worker ring, larger than the default for multishot headroom.
const RING_CQ_ENTRIES: u32 = 16 * 1024;

/// Max CQEs drained per loop pass.
const CQE_BATCH: usize = 512;

/// How long a worker may sleep between stop checks, in seconds.
const WAIT_SECONDS: i64 = 1;

/// SO_BUSY_POLL option name (asm-generic/socket.h).
const SO_BUSY_POLL: u32 = 46;

/// Completion routing tag, carried in the top byte of user_data.
const OpKind = enum(u8) {
    accept,
    recv,
};

/// Decoded user_data fields.
const Decoded = struct {
    op: OpKind,
    gen: u24,
    fd: linux.fd_t,
};

/// One connection on the ring: the h2 state plus the generation tag.
const RingConn = struct {
    conn: *MuxConn,
    gen: u24,
};

/// One worker's setup, passed by value to the spawned thread.
const WorkerCtx = struct {
    io: std.Io,
    opts: ServeOpts,
    handler: HandlerFn,
    listener: std.Io.net.Server,
    worker_id: usize,
    busy_poll_us: u32,
    stop: *std.atomic.Value(bool),
    failed: *std.atomic.Value(bool),
};

/// One ring, its fd slot table, and the connections it owns.
const Worker = struct {
    ring: IoUring = undefined,
    slots: []?*RingConn = &.{},
    gen_counter: u24 = 0,
    listener_fd: std.posix.fd_t = -1,
    io: std.Io,
    opts: ServeOpts,
    handler_fn: HandlerFn,
    busy_poll_us: u32 = 0,
    /// The multishot accept re-arm was lost to a full SQ. Retried on the
    /// next loop pass, so the worker never stops accepting.
    accept_pending: bool = false,

    const allocator = std.heap.smp_allocator;

    fn getSqe(self: *Worker) ?*linux.io_uring_sqe {
        if (self.ring.get_sqe()) |sqe| return sqe else |_| {}

        _ = self.ring.submit() catch |err| switch (err) {
            else => return null,
        };

        return self.ring.get_sqe() catch |err| switch (err) {
            else => null,
        };
    }

    fn lookup(self: *Worker, decoded: Decoded) ?*RingConn {
        if (decoded.fd < 0) return null;
        const idx: usize = @intCast(decoded.fd);
        if (idx >= self.slots.len) return null;

        const ring_conn = self.slots[idx] orelse return null;
        if (ring_conn.gen != decoded.gen) return null;

        return ring_conn;
    }

    fn closeConn(self: *Worker, ring_conn: *RingConn) void {
        const fd = ring_conn.conn.fd;
        self.slots[@intCast(fd)] = null;

        ring_conn.conn.deinit();
        allocator.destroy(ring_conn);
        _ = linux.close(fd);
    }

    fn armAccept(self: *Worker) void {
        const sqe = self.getSqe() orelse {
            self.accept_pending = true;

            return;
        };

        sqe.prep_multishot_accept(self.listener_fd, null, null, 0);
        sqe.user_data = packUserData(.accept, 0, self.listener_fd);
    }

    fn armRecv(self: *Worker, ring_conn: *RingConn) void {
        const conn = ring_conn.conn;
        conn.compact();

        // A full buffer even after compaction holds a frame larger than this
        // connection can read.
        if (conn.rend == conn.rbuf.len) {
            self.closeConn(ring_conn);

            return;
        }

        const sqe = self.getSqe() orelse {
            self.closeConn(ring_conn);

            return;
        };

        sqe.prep_recv(conn.fd, conn.rbuf[conn.rend..], 0);
        sqe.user_data = packUserData(.recv, ring_conn.gen, conn.fd);
    }

    fn handleAccept(self: *Worker, cqe: linux.io_uring_cqe) void {
        const rearm = (cqe.flags & linux.IORING_CQE_F_MORE) == 0;
        defer if (rearm) self.armAccept();
        if (cqe.res < 0) return;

        const fd: std.posix.fd_t = cqe.res;
        const idx: usize = @intCast(fd);
        if (idx >= self.slots.len) {
            _ = linux.close(fd);

            return;
        }

        setNoDelay(fd);
        setBusyPoll(fd, self.busy_poll_us);
        if (!setNonBlock(fd)) {
            _ = linux.close(fd);

            return;
        }

        const conn = MuxConn.init(fd, self.opts, self.io) catch |err| switch (err) {
            error.ZixHttp2_MuxConn_OutOfMemory => {
                _ = linux.close(fd);

                return;
            },
        };
        const ring_conn = allocator.create(RingConn) catch |err| switch (err) {
            error.OutOfMemory => {
                conn.deinit();
                _ = linux.close(fd);

                return;
            },
        };

        self.gen_counter +%= 1;
        ring_conn.* = .{
            .conn = conn,
            .gen = self.gen_counter,
        };
        self.slots[idx] = ring_conn;

        self.armRecv(ring_conn);
    }

    fn handleRecv(self: *Worker, cqe: linux.io_uring_cqe, decoded: Decoded) void {
        const ring_conn = self.lookup(decoded) orelse return;

        // 0 is a peer hang-up, below 0 a receive error. A hang-up part way
        // through a request is answered with GOAWAY first. A receive error
        // says nothing, the connection is already broken.
        if (cqe.res <= 0) {
            if (cqe.res == 0) _ = mux_dispatch.hangupGoaway(ring_conn.conn);
            self.closeConn(ring_conn);

            return;
        }

        ring_conn.conn.rend += @intCast(cqe.res);

        coalesce.beginCoalesce(ring_conn.conn.fd);
        const outcome = process.processRing(self.handler_fn, ring_conn.conn);
        const write_failed = coalesce.endCoalesce();

        if (outcome == .close or write_failed) {
            self.closeConn(ring_conn);

            return;
        }

        self.armRecv(ring_conn);
    }

    fn deinitConns(self: *Worker) void {
        for (self.slots) |slot| {
            const ring_conn = slot orelse continue;

            self.closeConn(ring_conn);
        }
    }

    fn service(self: *Worker, stop: *std.atomic.Value(bool)) void {
        self.armAccept();

        var cqes: [CQE_BATCH]linux.io_uring_cqe = undefined;
        while (!stop.load(.acquire)) {
            waitOnce(&self.ring) catch |err| switch (err) {
                else => {
                    stop.store(true, .release);

                    return;
                },
            };

            if (self.accept_pending) {
                self.accept_pending = false;
                self.armAccept();
            }

            const count = self.ring.copy_cqes(&cqes, 0) catch |err| switch (err) {
                else => {
                    stop.store(true, .release);

                    return;
                },
            };

            for (cqes[0..count]) |cqe| {
                const decoded = unpackUserData(cqe.user_data);
                switch (decoded.op) {
                    .accept => self.handleAccept(cqe),
                    .recv => self.handleRecv(cqe, decoded),
                }
            }
        }
    }
};

fn packUserData(op: OpKind, gen: u24, fd: linux.fd_t) u64 {
    const fd_bits: u32 = @bitCast(fd);

    return (@as(u64, @intFromEnum(op)) << 56) |
        (@as(u64, gen) << 32) |
        fd_bits;
}

fn unpackUserData(user_data: u64) Decoded {
    return .{
        .op = @enumFromInt(@as(u8, @intCast(user_data >> 56))),
        .gen = @intCast((user_data >> 32) & 0xff_ff_ff),
        .fd = @bitCast(@as(u32, @intCast(user_data & 0xff_ff_ff_ff))),
    };
}

fn workerCount(workers: usize) usize {
    if (workers != 0) return workers;

    return cpu_affinity.availableCpuCount();
}

/// Best effort: a kernel that rejects TCP_NODELAY still serves the request.
fn setNoDelay(fd: std.posix.fd_t) void {
    std.posix.setsockopt(
        fd,
        std.posix.IPPROTO.TCP,
        std.posix.TCP.NODELAY,
        std.mem.asBytes(&@as(c_int, 1)),
    ) catch |err| switch (err) {
        else => {},
    };
}

/// Spin up to us microseconds before the socket sleeps (SO_BUSY_POLL). 0
/// leaves it unset.
fn setBusyPoll(fd: std.posix.fd_t, us: u32) void {
    if (us == 0) return;

    std.posix.setsockopt(
        fd,
        std.posix.SOL.SOCKET,
        SO_BUSY_POLL,
        std.mem.asBytes(&@as(c_int, @intCast(@min(us, std.math.maxInt(c_int))))),
    ) catch |err| switch (err) {
        // Best effort: a kernel without SO_BUSY_POLL still serves.
        else => {},
    };
}

fn setNonBlock(fd: std.posix.fd_t) bool {
    const rc = linux.fcntl(fd, linux.F.GETFL, 0);
    if (std.posix.errno(rc) != .SUCCESS) return false;

    const flags: linux.O = @bitCast(@as(u32, @intCast(rc)));
    var nonblock = flags;
    nonblock.NONBLOCK = true;
    const bits: u32 = @bitCast(nonblock);
    const set_rc = linux.fcntl(fd, linux.F.SETFL, @intCast(bits));

    return std.posix.errno(set_rc) == .SUCCESS;
}

fn initRing() Error!IoUring {
    var params = std.mem.zeroInit(linux.io_uring_params, .{
        .flags = linux.IORING_SETUP_SINGLE_ISSUER |
            linux.IORING_SETUP_DEFER_TASKRUN |
            linux.IORING_SETUP_CQSIZE |
            linux.IORING_SETUP_CLAMP,
        .cq_entries = RING_CQ_ENTRIES,
    });

    const ring = IoUring.init_params(RING_ENTRIES, &params) catch |err| switch (err) {
        else => IoUring.init(RING_ENTRIES, 0) catch |fallback_err| switch (fallback_err) {
            else => return Error.ZixHttp2_Uring_SetupFailed,
        },
    };

    return ring;
}

/// Submit the staged SQEs and wait for at least one completion, with a
/// periodic bound when the kernel supports one so a worker can see stop.
fn waitOnce(ring: *IoUring) Error!void {
    if ((ring.features & linux.IORING_FEAT_EXT_ARG) == 0) {
        _ = ring.submit_and_wait(1) catch |err| switch (err) {
            error.SignalInterrupt => return,
            else => return Error.ZixHttp2_Uring_WaitFailed,
        };

        return;
    }

    const submitted = ring.flush_sq();
    var deadline = linux.kernel_timespec{
        .sec = WAIT_SECONDS,
        .nsec = 0,
    };
    var wait_arg = linux.io_uring_getevents_arg{
        .sigmask = 0,
        .sigmask_sz = 0,
        .pad = 0,
        .ts = @intFromPtr(&deadline),
    };
    const ring_fd: u64 = @bitCast(@as(i64, ring.fd));
    const rc = linux.syscall6(
        .io_uring_enter,
        ring_fd,
        submitted,
        1,
        linux.IORING_ENTER_GETEVENTS | linux.IORING_ENTER_EXT_ARG,
        @intFromPtr(&wait_arg),
        @sizeOf(linux.io_uring_getevents_arg),
    );

    switch (linux.errno(rc)) {
        .SUCCESS, .TIME, .INTR => {},
        else => return Error.ZixHttp2_Uring_WaitFailed,
    }
}

fn closeListeners(listeners: []std.Io.net.Server, io: std.Io) void {
    for (listeners) |*listener| listener.deinit(io);
}

fn failSetup(ctx: *const WorkerCtx) void {
    ctx.failed.store(true, .release);
    ctx.stop.store(true, .release);
}

fn workerMain(ctx: WorkerCtx) void {
    const io = ctx.io;
    var listener = ctx.listener;
    defer listener.deinit(io);

    cpu_affinity.pinToCpu(ctx.worker_id);
    handler.setAccessLogger(ctx.opts.logger);

    // Per-worker response cache. It lives on the worker stack, so the pointer
    // installed for this thread stays valid until this worker returns.
    var resp_cache: ?ResponseCache = null;
    cache.installWorker(&resp_cache, std.heap.smp_allocator, ctx.opts);
    defer cache.uninstallWorker(&resp_cache);

    const slots = slab.mapZeroedSlots(?*RingConn, MAX_FD) catch |err| switch (err) {
        error.ZixUtils_Slab_OutOfMemory,
        error.ZixUtils_Slab_MapFailed,
        => {
            failSetup(&ctx);

            return;
        },
    };
    defer slab.unmapSlots(slots);

    var worker = Worker{
        .slots = slots,
        .listener_fd = listener.socket.handle,
        .io = io,
        .opts = ctx.opts,
        .handler_fn = ctx.handler,
        .busy_poll_us = ctx.busy_poll_us,
    };
    worker.ring = initRing() catch |err| switch (err) {
        else => {
            failSetup(&ctx);

            return;
        },
    };
    defer worker.ring.deinit();
    defer worker.deinitConns();

    worker.service(ctx.stop);

    if (ctx.stop.load(.acquire)) failSetup(&ctx);
}

// --------------------------------------------------------- //
// Public:

/// ZIX Http2 uring dispatch error
pub const Error = error {
    ZixHttp2_Uring_Unsupported,
    ZixHttp2_Uring_ResolveFailed,
    ZixHttp2_Uring_ListenFailed,
    ZixHttp2_Uring_OutOfMemory,
    ZixHttp2_Uring_SpawnFailed,
    ZixHttp2_Uring_SetupFailed,
    ZixHttp2_Uring_WaitFailed,
};

/// Run one uring worker per available CPU, or per config.workers when
/// non-zero.
///
/// Note:
/// - Every listener is bound here, in worker order, before any worker
///   starts. A bind failure returns before anything serves.
/// - config.reuseport_cbpf steers a connection to the worker of the CPU that
///   received it. A kernel that refuses it logs a warning and keeps the
///   default hash.
///
/// Param:
/// config - Config (server configuration)
/// handler_fn - HandlerFn (top-level handler)
///
/// Return:
/// - void when every worker stopped cleanly
/// - Error.ZixHttp2_Uring_Unsupported off Linux
/// - Error.ZixHttp2_Uring_ResolveFailed, ListenFailed, OutOfMemory, or
///   SpawnFailed before serving
/// - Error.ZixHttp2_Uring_SetupFailed when a worker could not start its ring
pub fn run(config: Config, handler_fn: HandlerFn) Error!void {
    if (comptime builtin.target.os.tag != .linux) {
        return Error.ZixHttp2_Uring_Unsupported;
    }

    const io = config.io;
    const allocator = std.heap.smp_allocator;
    const workers = workerCount(config.workers);
    const opts = config.serveOpts();

    const address = std.Io.net.IpAddress.resolve(
        io,
        config.ip,
        config.port,
    ) catch |err| switch (err) {
        else => return Error.ZixHttp2_Uring_ResolveFailed,
    };

    const listeners = allocator.alloc(
        std.Io.net.Server,
        workers,
    ) catch |err| switch (err) {
        error.OutOfMemory => return Error.ZixHttp2_Uring_OutOfMemory,
    };

    var bound: usize = 0;
    while (bound < workers) : (bound += 1) {
        listeners[bound] = address.listen(io, .{
            .mode = .stream,
            .reuse_address = true,
            .kernel_backlog = config.kernel_backlog,
        }) catch |err| switch (err) {
            else => {
                closeListeners(listeners[0..bound], io);
                allocator.free(listeners);

                return Error.ZixHttp2_Uring_ListenFailed;
            },
        };
    }

    if (config.reuseport_cbpf and
        !reuseport.attachCpuSteering(listeners[0].socket.handle, workers))
    {
        log.logSystem(
            config,
            .WARN,
            "reuseport_cbpf refused by the kernel, keeping the default hash",
            .{},
        );
    }

    const threads = allocator.alloc(
        std.Thread,
        workers,
    ) catch |err| switch (err) {
        error.OutOfMemory => {
            closeListeners(listeners, io);
            allocator.free(listeners);

            return Error.ZixHttp2_Uring_OutOfMemory;
        },
    };
    defer allocator.free(threads);

    var stop = std.atomic.Value(bool).init(false);
    var failed = std.atomic.Value(bool).init(false);

    var spawned: usize = 0;
    while (spawned < workers) : (spawned += 1) {
        threads[spawned] = std.Thread.spawn(
            .{
                .stack_size = config.worker_stack_size_bytes,
            },
            workerMain,
            .{WorkerCtx{
                .io = io,
                .opts = opts,
                .handler = handler_fn,
                .listener = listeners[spawned],
                .worker_id = spawned,
                .busy_poll_us = config.busy_poll_us,
                .stop = &stop,
                .failed = &failed,
            }},
        ) catch |err| switch (err) {
            else => {
                stop.store(true, .release);
                closeListeners(listeners[spawned..], io);
                for (threads[0..spawned]) |thread| thread.join();
                allocator.free(listeners);

                return Error.ZixHttp2_Uring_SpawnFailed;
            },
        };
    }

    log.logSystem(
        config,
        .INFO,
        "listening on {s}:{d} (io_uring, {d} workers)",
        .{ config.ip, config.port, workers },
    );

    for (threads) |thread| thread.join();

    allocator.free(listeners);

    if (failed.load(.acquire)) return Error.ZixHttp2_Uring_SetupFailed;
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const frame = @import("../frame.zig");
const pair = @import("../../../utils/socket/pair.zig");
const writer = @import("../writer.zig");
const Context = @import("../Context.zig");
const Header = @import("../hpack/Header.zig");
const HpackDecoder = @import("../hpack/HpackDecoder.zig");
const HpackEncoder = @import("../hpack/HpackEncoder.zig");
const Request = @import("../Request.zig");
const Response = @import("../Response.zig");

/// Handler calls seen by okHandler.
var ok_calls: usize = 0;

fn mockHandler(_: *Request, _: *Response, _: *Context) anyerror!void {}

fn okHandler(_: *Request, res: *Response, _: *Context) anyerror!void {
    ok_calls += 1;

    try res.sendText("ok");
}

fn testConfig() Config {
    return .{
        .io = std.testing.io,
        .ip = "127.0.0.1",
        .port = 0,
        .dispatch_model = .URING,
    };
}

fn testRing() ?IoUring {
    return initRing() catch |err| switch (err) {
        else => {
            std.log.info("io_uring unavailable ({s}), test skipped", .{@errorName(err)});

            return null;
        },
    };
}

/// A worker with a live ring and a slot table, or null without io_uring.
fn testWorker(handler_fn: HandlerFn) !?Worker {
    var worker = Worker{
        .io = std.testing.io,
        .opts = .{},
        .handler_fn = handler_fn,
    };
    worker.ring = testRing() orelse return null;
    errdefer worker.ring.deinit();

    worker.slots = try slab.mapZeroedSlots(?*RingConn, MAX_FD);

    return worker;
}

fn testWorkerDeinit(worker: *Worker) void {
    worker.deinitConns();
    slab.unmapSlots(worker.slots);
    worker.ring.deinit();
}

/// An accept completion for fd, as the multishot accept reports it.
fn testAcceptCqe(fd: std.posix.fd_t) linux.io_uring_cqe {
    return .{
        .user_data = packUserData(.accept, 0, -1),
        .res = fd,
        .flags = linux.IORING_CQE_F_MORE,
    };
}

/// Write one complete frame the way a client would.
fn writeFrameTo(
    fd: std.posix.fd_t,
    frame_type: u8,
    flags: u8,
    sid: u31,
    payload: []const u8,
) !void {
    var buf: [frame.FRAME_HEADER_LEN]u8 = undefined;
    frame.encodeFrameHeader(&buf, .{
        .length = @intCast(payload.len),
        .frame_type = frame_type,
        .flags = flags,
        .stream_id = sid,
    });

    try writer.writeAllDirectFD(fd, &buf);
    if (payload.len > 0) try writer.writeAllDirectFD(fd, payload);
}

/// Send the preface, SETTINGS, and one GET / on stream 1.
fn writeOneRequest(fd: std.posix.fd_t) !void {
    var block: [128]u8 = undefined;
    var encoder = HpackEncoder.init(&block);
    try encoder.writeHeader(":method", "GET");
    try encoder.writeHeader(":path", "/");

    const flags = frame.FLAG_END_HEADERS | frame.FLAG_END_STREAM;

    try writer.writeAllDirectFD(fd, frame.PREFACE);
    try writeFrameTo(fd, frame.FRAME_TYPE_SETTINGS, 0, 0, "");
    try writeFrameTo(fd, frame.FRAME_TYPE_HEADERS, flags, 1, encoder.encoded());
}

/// Place what the peer sent into the read buffer, the way a recv completion
/// does, and return the completion for it.
fn testRecvCqe(ring_conn: *RingConn) !linux.io_uring_cqe {
    const conn = ring_conn.conn;
    const got = try std.posix.read(conn.fd, conn.rbuf[conn.rend..]);

    return .{
        .user_data = packUserData(.recv, ring_conn.gen, conn.fd),
        .res = @intCast(got),
        .flags = 0,
    };
}

/// Read until EOF and count the :status 200 answers on stream 1.
fn countStatus200(fd: std.posix.fd_t, buf: []u8) usize {
    var total: usize = 0;
    while (total < buf.len) {
        const got = std.posix.read(fd, buf[total..]) catch |err| switch (err) {
            else => break,
        };
        if (got == 0) break;

        total += got;
    }

    var decoder = HpackDecoder.init();
    var count: usize = 0;
    var pos: usize = 0;

    while (pos + frame.FRAME_HEADER_LEN <= total) {
        const header = frame.parseFrameHeader(buf[pos..][0..frame.FRAME_HEADER_LEN]);
        pos += frame.FRAME_HEADER_LEN;
        if (pos + header.length > total) break;

        const payload = buf[pos..][0..header.length];
        pos += header.length;

        if (header.frame_type != frame.FRAME_TYPE_HEADERS) continue;
        if (header.stream_id != 1) continue;

        var headers: [frame.MAX_HEADERS]Header = undefined;
        var scratch: [256]u8 = undefined;
        const decoded = decoder.decode(payload, &headers, &scratch) catch |err| switch (err) {
            else => continue,
        };

        for (headers[0..decoded]) |entry| {
            if (!std.mem.eql(u8, entry.name, ":status")) continue;

            if (std.mem.eql(u8, entry.value, "200")) count += 1;
        }
    }

    return count;
}


/// A listener on a free loopback port, as run binds it.
fn testListener() !std.Io.net.Server {
    const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);

    return address.listen(std.testing.io, .{
        .mode = .stream,
        .reuse_address = true,
        .kernel_backlog = 8,
    });
}

/// Run workerMain on its own thread, send one request from a real client,
/// then stop the worker.
///
/// Return:
/// - usize (the :status 200 answers the client read)
fn testServeOverWorker() !usize {
    const listener = try testListener();
    const address = listener.socket.address;

    var stop = std.atomic.Value(bool).init(false);
    var failed = std.atomic.Value(bool).init(false);
    const thread = try std.Thread.spawn(.{}, workerMain, .{WorkerCtx{
        .io = std.testing.io,
        .opts = .{},
        .handler = okHandler,
        .listener = listener,
        .worker_id = 0,
        .busy_poll_us = 0,
        .stop = &stop,
        .failed = &failed,
    }});
    defer thread.join();
    defer stop.store(true, .release);

    var client = try address.connect(std.testing.io, .{
        .mode = .stream,
    });
    defer client.close(std.testing.io);

    try writeOneRequest(client.socket.handle);
    _ = linux.shutdown(client.socket.handle, linux.SHUT.WR);

    var buf: [8192]u8 = undefined;

    return countStatus200(client.socket.handle, &buf);
}

test "zix http2: uring, user_data round trip preserves op, gen, fd" {
    const decoded = unpackUserData(packUserData(.recv, 0xabcdef, 1234));

    try std.testing.expectEqual(OpKind.recv, decoded.op);
    try std.testing.expectEqual(@as(u24, 0xabcdef), decoded.gen);
    try std.testing.expectEqual(@as(linux.fd_t, 1234), decoded.fd);
}

test "zix http2: uring, user_data keeps a negative fd" {
    const decoded = unpackUserData(packUserData(.accept, 0, -1));

    try std.testing.expectEqual(OpKind.accept, decoded.op);
    try std.testing.expectEqual(@as(linux.fd_t, -1), decoded.fd);
}

test "zix http2: uring, workerCount keeps an explicit count" {
    try std.testing.expectEqual(@as(usize, 5), workerCount(5));
}

test "zix http2: uring, workerCount zero is at least 1" {
    try std.testing.expect(workerCount(0) >= 1);
}

test "zix http2: uring, handleAccept registers the connection" {
    if (comptime builtin.target.os.tag != .linux) return error.SkipZigTest;

    var worker = try testWorker(mockHandler) orelse return error.SkipZigTest;
    defer testWorkerDeinit(&worker);

    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);

    worker.handleAccept(testAcceptCqe(fds[1]));

    const ring_conn = worker.slots[@intCast(fds[1])].?;

    try std.testing.expectEqual(@as(u24, 1), ring_conn.gen);
    try std.testing.expect(!worker.accept_pending);
}

test "zix http2: uring, handleAccept error leaves the table empty" {
    if (comptime builtin.target.os.tag != .linux) return error.SkipZigTest;

    var worker = try testWorker(mockHandler) orelse return error.SkipZigTest;
    defer testWorkerDeinit(&worker);

    worker.handleAccept(testAcceptCqe(-@as(i32, @intFromEnum(linux.E.AGAIN))));

    try std.testing.expectEqual(@as(u24, 0), worker.gen_counter);
}

test "zix http2: uring, handleRecv answers one request" {
    if (comptime builtin.target.os.tag != .linux) return error.SkipZigTest;

    var worker = try testWorker(okHandler) orelse return error.SkipZigTest;

    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);

    worker.handleAccept(testAcceptCqe(fds[1]));
    try writeOneRequest(fds[0]);

    const ring_conn = worker.slots[@intCast(fds[1])].?;
    const cqe = try testRecvCqe(ring_conn);

    ok_calls = 0;
    worker.handleRecv(cqe, unpackUserData(cqe.user_data));

    const kept = worker.slots[@intCast(fds[1])] != null;
    testWorkerDeinit(&worker);

    var buf: [8192]u8 = undefined;

    try std.testing.expect(kept);
    try std.testing.expectEqual(@as(usize, 1), countStatus200(fds[0], &buf));
    try std.testing.expectEqual(@as(usize, 1), ok_calls);
}

test "zix http2: uring, handleRecv removes the write hook" {
    if (comptime builtin.target.os.tag != .linux) return error.SkipZigTest;

    var worker = try testWorker(okHandler) orelse return error.SkipZigTest;
    defer testWorkerDeinit(&worker);

    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);

    worker.handleAccept(testAcceptCqe(fds[1]));
    try writeOneRequest(fds[0]);

    const cqe = try testRecvCqe(worker.slots[@intCast(fds[1])].?);
    worker.handleRecv(cqe, unpackUserData(cqe.user_data));

    try std.testing.expect(writer.write_hook == null);
}

test "zix http2: uring, handleRecv peer hang-up closes the connection" {
    if (comptime builtin.target.os.tag != .linux) return error.SkipZigTest;

    var worker = try testWorker(mockHandler) orelse return error.SkipZigTest;
    defer testWorkerDeinit(&worker);

    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);

    worker.handleAccept(testAcceptCqe(fds[1]));

    const ring_conn = worker.slots[@intCast(fds[1])].?;
    const cqe: linux.io_uring_cqe = .{
        .user_data = packUserData(.recv, ring_conn.gen, fds[1]),
        .res = 0,
        .flags = 0,
    };
    worker.handleRecv(cqe, unpackUserData(cqe.user_data));

    try std.testing.expect(worker.slots[@intCast(fds[1])] == null);
}

test "zix http2: uring, handleRecv stale generation is ignored" {
    if (comptime builtin.target.os.tag != .linux) return error.SkipZigTest;

    var worker = try testWorker(mockHandler) orelse return error.SkipZigTest;
    defer testWorkerDeinit(&worker);

    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);

    worker.handleAccept(testAcceptCqe(fds[1]));

    const ring_conn = worker.slots[@intCast(fds[1])].?;
    const cqe: linux.io_uring_cqe = .{
        .user_data = packUserData(.recv, ring_conn.gen +% 1, fds[1]),
        .res = 0,
        .flags = 0,
    };
    worker.handleRecv(cqe, unpackUserData(cqe.user_data));

    try std.testing.expect(worker.slots[@intCast(fds[1])] != null);
}

test "zix http2: uring, run with an unresolvable ip is ResolveFailed" {
    if (comptime builtin.target.os.tag != .linux) return error.SkipZigTest;

    var config = testConfig();
    config.ip = "not-an-ip";

    try std.testing.expectError(Error.ZixHttp2_Uring_ResolveFailed, run(config, mockHandler));
}

test "zix http2: uring, run off Linux is Unsupported" {
    if (comptime builtin.target.os.tag == .linux) return error.SkipZigTest;

    const result = run(testConfig(), mockHandler);

    try std.testing.expectError(Error.ZixHttp2_Uring_Unsupported, result);
}

test "zix http2: uring, worker serves one connection end to end" {
    if (comptime builtin.target.os.tag != .linux) return error.SkipZigTest;

    // The worker needs a ring of its own.
    var probe = testRing() orelse return error.SkipZigTest;
    probe.deinit();

    ok_calls = 0;

    try std.testing.expectEqual(@as(usize, 1), try testServeOverWorker());
    try std.testing.expectEqual(@as(usize, 1), ok_calls);
}

