//! ZIX Http2 Grpc dispatch uring model
//!
//! ### file: src/zix/tcp/http2/grpc/dispatch/uring.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Linux io_uring model for gRPC: worker threads share nothing, each owns a
//! listener, a ring, and the h2c connections it accepted.
//!
//! ### note:
//!
//! - The ring owns accept (multishot), recv, and the send of conn.stage.
//!   A connection has at most one recv or one send in flight, so the read
//!   buffer and the stage are never touched while the kernel holds them.
//! - A reply larger than the stage is written straight to the fd while the
//!   call runs (see ReplyStage.zig), which blocks this worker until it is sent.
//! - A generation tag in user_data keeps a stale completion off a reused fd.
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
const log = @import("../log.zig");
const mux_dispatch = @import("../mux/mux_dispatch.zig");
const process = @import("../mux/process.zig");
const Config = @import("../Config.zig");
const MuxConn = @import("../mux/MuxConn.zig");
const ServeOpts = @import("../ServeOpts.zig");
const ResponseCache = @import("../../../../utils/cache/ResponseCache.zig");
const cpu_affinity = @import("../../../../multiplexers/cpu_affinity.zig");
const reuseport = @import("../../../../multiplexers/reuseport.zig");
const slab = @import("../../../../multiplexers/slab.zig");

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
    send,
};

/// Decoded user_data fields.
const Decoded = struct {
    op: OpKind,
    gen: u24,
    fd: linux.fd_t,
};

/// One connection on the ring.
const RingConn = struct {
    /// The h2 state: rbuf (read accumulator) and stage (reply bytes).
    conn: *MuxConn,
    /// Guards against a completion for an earlier connection on this fd.
    gen: u24,
    /// Stage bytes the kernel holds while a send is in flight. 0 when idle.
    inflight: usize = 0,
    /// Free the connection once the staged bytes are sent.
    closing: bool = false,
};

/// One worker's setup, passed by value to the spawned thread.
const WorkerCtx = struct {
    io: std.Io,
    opts: ServeOpts,
    listener: std.Io.net.Server,
    worker_id: usize,
    busy_poll_us: u32,
    stop: *std.atomic.Value(bool),
    failed: *std.atomic.Value(bool),
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

/// Best effort: a kernel that rejects TCP_NODELAY still serves the call.
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
            else => return Error.ZixHttp2_GrpcUring_SetupFailed,
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
            else => return Error.ZixHttp2_GrpcUring_WaitFailed,
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
        else => return Error.ZixHttp2_GrpcUring_WaitFailed,
    }
}

fn closeListeners(listeners: []std.Io.net.Server, io: std.Io) void {
    for (listeners) |*listener| listener.deinit(io);
}

fn failSetup(ctx: *const WorkerCtx) void {
    ctx.failed.store(true, .release);
    ctx.stop.store(true, .release);
}

/// One ring, its fd slot table, and the connections it owns, for one Router.
fn Worker(comptime RouterType: type) type {
    return struct {
        ring: IoUring = undefined,
        slots: []?*RingConn = &.{},
        gen_counter: u24 = 0,
        listener_fd: std.posix.fd_t = -1,
        io: std.Io,
        opts: ServeOpts,
        busy_poll_us: u32 = 0,
        /// The multishot accept re-arm was lost to a full SQ. Retried on the
        /// next loop pass, so the worker never stops accepting.
        accept_pending: bool = false,

        const Self = @This();
        const allocator = std.heap.smp_allocator;

        fn getSqe(self: *Self) ?*linux.io_uring_sqe {
            if (self.ring.get_sqe()) |sqe| return sqe else |_| {}

            _ = self.ring.submit() catch |err| switch (err) {
                else => return null,
            };

            return self.ring.get_sqe() catch |err| switch (err) {
                else => null,
            };
        }

        fn lookup(self: *Self, decoded: Decoded) ?*RingConn {
            if (decoded.fd < 0) return null;
            const idx: usize = @intCast(decoded.fd);
            if (idx >= self.slots.len) return null;

            const ring_conn = self.slots[idx] orelse return null;
            if (ring_conn.gen != decoded.gen) return null;

            return ring_conn;
        }

        /// Free and close a connection with nothing in flight.
        fn finishClose(self: *Self, ring_conn: *RingConn) void {
            const fd = ring_conn.conn.fd;
            self.slots[@intCast(fd)] = null;

            ring_conn.conn.deinit();
            allocator.destroy(ring_conn);
            _ = linux.close(fd);
        }

        /// Close once the staged bytes are out. With a send in flight, the
        /// send completion finishes the close.
        fn beginClose(self: *Self, ring_conn: *RingConn) void {
            ring_conn.closing = true;
            if (ring_conn.inflight > 0) return;

            if (ring_conn.conn.stage.len > 0) {
                self.submitSend(ring_conn);

                return;
            }

            self.finishClose(ring_conn);
        }

        fn armAccept(self: *Self) void {
            const sqe = self.getSqe() orelse {
                self.accept_pending = true;

                return;
            };

            sqe.prep_multishot_accept(self.listener_fd, null, null, 0);
            sqe.user_data = packUserData(.accept, 0, self.listener_fd);
        }

        fn armRecv(self: *Self, ring_conn: *RingConn) void {
            const conn = ring_conn.conn;
            conn.compact();

            // A full buffer even after compaction holds a frame larger than
            // this connection can read.
            if (conn.rend == conn.rbuf.len) {
                self.beginClose(ring_conn);

                return;
            }

            const sqe = self.getSqe() orelse {
                self.beginClose(ring_conn);

                return;
            };

            sqe.prep_recv(conn.fd, conn.rbuf[conn.rend..], 0);
            sqe.user_data = packUserData(.recv, ring_conn.gen, conn.fd);
        }

        fn submitSend(self: *Self, ring_conn: *RingConn) void {
            const conn = ring_conn.conn;
            const sqe = self.getSqe() orelse {
                self.finishClose(ring_conn);

                return;
            };

            sqe.prep_send(conn.fd, conn.stage.buf[0..conn.stage.len], linux.MSG.NOSIGNAL);
            sqe.user_data = packUserData(.send, ring_conn.gen, conn.fd);

            ring_conn.inflight = conn.stage.len;
        }

        fn handleAccept(self: *Self, cqe: linux.io_uring_cqe) void {
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

            const conn = MuxConn.init(fd, self.opts, self.io) catch |err| switch (err) {
                error.ZixHttp2_GrpcMuxConn_OutOfMemory => {
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

        fn handleRecv(self: *Self, cqe: linux.io_uring_cqe, decoded: Decoded) void {
            const ring_conn = self.lookup(decoded) orelse return;

            // 0 is a peer hang-up, below 0 a receive error. A hang-up part way
            // through a request stages a GOAWAY, which beginClose sends before
            // the free. A receive error says nothing, the connection is
            // already broken.
            if (cqe.res <= 0) {
                if (cqe.res == 0) _ = mux_dispatch.hangupGoaway(ring_conn.conn);
                self.beginClose(ring_conn);

                return;
            }

            ring_conn.conn.rend += @intCast(cqe.res);

            const outcome = process.processRing(RouterType, ring_conn.conn);

            if (outcome == .close) {
                self.beginClose(ring_conn);

                return;
            }

            if (ring_conn.conn.stage.len > 0) {
                self.submitSend(ring_conn);

                return;
            }

            self.armRecv(ring_conn);
        }

        fn handleSend(self: *Self, cqe: linux.io_uring_cqe, decoded: Decoded) void {
            const ring_conn = self.lookup(decoded) orelse return;
            const conn = ring_conn.conn;

            ring_conn.inflight = 0;

            // A failed send leaves nothing worth flushing.
            if (cqe.res < 0) {
                self.finishClose(ring_conn);

                return;
            }

            const sent: usize = @intCast(cqe.res);
            if (sent < conn.stage.len) {
                const left = conn.stage.len - sent;
                std.mem.copyForwards(
                    u8,
                    conn.stage.buf[0..left],
                    conn.stage.buf[sent..conn.stage.len],
                );
                conn.stage.len = left;

                self.submitSend(ring_conn);

                return;
            }

            conn.stage.len = 0;

            if (ring_conn.closing) {
                self.finishClose(ring_conn);

                return;
            }

            self.armRecv(ring_conn);
        }

        /// Free and close every connection still in the table. Call after the
        /// ring is gone, so no send still reads a stage being freed.
        fn deinitConns(self: *Self) void {
            for (self.slots) |slot| {
                const ring_conn = slot orelse continue;

                self.finishClose(ring_conn);
            }
        }

        fn service(self: *Self, stop: *std.atomic.Value(bool)) void {
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
                        .send => self.handleSend(cqe, decoded),
                    }
                }
            }
        }

        fn main(ctx: WorkerCtx) void {
            const io = ctx.io;
            var listener = ctx.listener;
            defer listener.deinit(io);

            cpu_affinity.pinToCpu(ctx.worker_id);

            // Per-worker response cache. It lives on the worker stack, so the
            // pointer installed for this thread stays valid until it returns.
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

            var worker = Self{
                .slots = slots,
                .listener_fd = listener.socket.handle,
                .io = io,
                .opts = ctx.opts,
                .busy_poll_us = ctx.busy_poll_us,
            };
            worker.ring = initRing() catch |err| switch (err) {
                else => {
                    failSetup(&ctx);

                    return;
                },
            };
            // Runs after the ring is gone (defers run in reverse).
            defer worker.deinitConns();
            defer worker.ring.deinit();

            worker.service(ctx.stop);

            if (ctx.stop.load(.acquire)) failSetup(&ctx);
        }
    };
}

// --------------------------------------------------------- //
// Public:

/// ZIX Http2 Grpc uring dispatch error
pub const Error = error {
    ZixHttp2_GrpcUring_Unsupported,
    ZixHttp2_GrpcUring_ResolveFailed,
    ZixHttp2_GrpcUring_ListenFailed,
    ZixHttp2_GrpcUring_OutOfMemory,
    ZixHttp2_GrpcUring_SpawnFailed,
    ZixHttp2_GrpcUring_SetupFailed,
    ZixHttp2_GrpcUring_WaitFailed,
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
/// RouterType - type (a Router, carrying route_slice and dispatch)
/// config - Config (server configuration)
///
/// Return:
/// - void when every worker stopped cleanly
/// - Error.ZixHttp2_GrpcUring_Unsupported off Linux
/// - Error.ZixHttp2_GrpcUring_ResolveFailed, ListenFailed, OutOfMemory, or
///   SpawnFailed before serving
/// - Error.ZixHttp2_GrpcUring_SetupFailed when a worker could not start its ring
pub fn run(comptime RouterType: type, config: Config) Error!void {
    if (comptime builtin.target.os.tag != .linux) {
        return Error.ZixHttp2_GrpcUring_Unsupported;
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
        else => return Error.ZixHttp2_GrpcUring_ResolveFailed,
    };

    const listeners = allocator.alloc(
        std.Io.net.Server,
        workers,
    ) catch |err| switch (err) {
        error.OutOfMemory => return Error.ZixHttp2_GrpcUring_OutOfMemory,
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

                return Error.ZixHttp2_GrpcUring_ListenFailed;
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

            return Error.ZixHttp2_GrpcUring_OutOfMemory;
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
            Worker(RouterType).main,
            .{WorkerCtx{
                .io = io,
                .opts = opts,
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

                return Error.ZixHttp2_GrpcUring_SpawnFailed;
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

    if (failed.load(.acquire)) return Error.ZixHttp2_GrpcUring_SetupFailed;
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const frame = @import("../../frame.zig");
const pair = @import("../../../../utils/socket/pair.zig");
const router = @import("../router.zig");
const writer = @import("../../writer.zig");
const Context = @import("../Context.zig");
const Header = @import("../../hpack/Header.zig");
const HpackDecoder = @import("../../hpack/HpackDecoder.zig");
const HpackEncoder = @import("../../hpack/HpackEncoder.zig");
const Request = @import("../Request.zig");
const Response = @import("../Response.zig");

/// Handler calls seen by okHandler.
var ok_calls: usize = 0;

fn okHandler(_: *Request, res: *Response, _: *Context) anyerror!void {
    ok_calls += 1;

    try res.finish(.OK, "");
}

const TestRouter = router.Router(&[_]router.Route{
    .{
        .path = "/svc.Svc/Method",
        .handler = okHandler,
    },
});

const TestWorker = Worker(TestRouter);

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
fn testWorker() !?TestWorker {
    var worker = TestWorker{
        .io = std.testing.io,
        .opts = .{},
    };
    worker.ring = testRing() orelse return null;
    errdefer worker.ring.deinit();

    worker.slots = try slab.mapZeroedSlots(?*RingConn, MAX_FD);

    return worker;
}

fn testWorkerDeinit(worker: *TestWorker) void {
    worker.ring.deinit();
    worker.deinitConns();
    slab.unmapSlots(worker.slots);
}

/// An accept completion for fd, as the multishot accept reports it.
fn testAcceptCqe(fd: std.posix.fd_t) linux.io_uring_cqe {
    return .{
        .user_data = packUserData(.accept, 0, -1),
        .res = fd,
        .flags = linux.IORING_CQE_F_MORE,
    };
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

/// Submit the queued SQEs and handle the send completion of fd.
fn testCompleteSend(worker: *TestWorker, fd: std.posix.fd_t) !void {
    var cqes: [8]linux.io_uring_cqe = undefined;

    while (true) {
        _ = try worker.ring.submit_and_wait(1);

        const count = try worker.ring.copy_cqes(&cqes, 0);
        for (cqes[0..count]) |cqe| {
            const decoded = unpackUserData(cqe.user_data);
            if (decoded.op != .send or decoded.fd != fd) continue;

            worker.handleSend(cqe, decoded);

            return;
        }
    }
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

/// Send the preface, SETTINGS, and one unary call with an empty message on
/// stream 1.
fn writeOneCall(fd: std.posix.fd_t) !void {
    var block: [128]u8 = undefined;
    var encoder = HpackEncoder.init(&block);
    try encoder.writeHeader(":method", "POST");
    try encoder.writeHeader(":path", "/svc.Svc/Method");

    const empty_message = [_]u8{ 0, 0, 0, 0, 0 };
    const head_flags = frame.FLAG_END_HEADERS;

    try writer.writeAllDirectFD(fd, frame.PREFACE);
    try writeFrameTo(fd, frame.FRAME_TYPE_SETTINGS, 0, 0, "");
    try writeFrameTo(fd, frame.FRAME_TYPE_HEADERS, head_flags, 1, encoder.encoded());
    try writeFrameTo(fd, frame.FRAME_TYPE_DATA, frame.FLAG_END_STREAM, 1, &empty_message);
}

/// Read until EOF and count the grpc-status 0 trailers on stream 1.
fn countStatusOk(fd: std.posix.fd_t, buf: []u8) usize {
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
            const is_ok =
                std.mem.eql(u8, entry.name, "grpc-status") and
                std.mem.eql(u8, entry.value, "0");
            if (is_ok) count += 1;
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

/// Run the worker on its own thread, send one call from a real client, then
/// stop the worker.
///
/// Return:
/// - usize (the grpc-status 0 trailers the client read)
fn testServeOverWorker() !usize {
    const listener = try testListener();
    const address = listener.socket.address;

    var stop = std.atomic.Value(bool).init(false);
    var failed = std.atomic.Value(bool).init(false);
    const thread = try std.Thread.spawn(.{}, TestWorker.main, .{WorkerCtx{
        .io = std.testing.io,
        .opts = .{},
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

    try writeOneCall(client.socket.handle);
    _ = linux.shutdown(client.socket.handle, linux.SHUT.WR);

    var buf: [8192]u8 = undefined;

    return countStatusOk(client.socket.handle, &buf);
}

test "zix http2 grpc: uring, user_data round trip preserves op, gen, fd" {
    const decoded = unpackUserData(packUserData(.send, 0xabcdef, 1234));

    try std.testing.expectEqual(OpKind.send, decoded.op);
    try std.testing.expectEqual(@as(u24, 0xabcdef), decoded.gen);
    try std.testing.expectEqual(@as(linux.fd_t, 1234), decoded.fd);
}

test "zix http2 grpc: uring, user_data keeps a negative fd" {
    const decoded = unpackUserData(packUserData(.accept, 0, -1));

    try std.testing.expectEqual(OpKind.accept, decoded.op);
    try std.testing.expectEqual(@as(linux.fd_t, -1), decoded.fd);
}

test "zix http2 grpc: uring, workerCount keeps an explicit count" {
    try std.testing.expectEqual(@as(usize, 5), workerCount(5));
}

test "zix http2 grpc: uring, workerCount zero is at least 1" {
    try std.testing.expect(workerCount(0) >= 1);
}

test "zix http2 grpc: uring, handleAccept registers the connection" {
    if (comptime builtin.target.os.tag != .linux) return error.SkipZigTest;

    var worker = try testWorker() orelse return error.SkipZigTest;
    defer testWorkerDeinit(&worker);

    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);

    worker.handleAccept(testAcceptCqe(fds[1]));

    const ring_conn = worker.slots[@intCast(fds[1])].?;

    try std.testing.expectEqual(@as(u24, 1), ring_conn.gen);
    try std.testing.expect(!worker.accept_pending);
}

test "zix http2 grpc: uring, handleAccept error leaves the table empty" {
    if (comptime builtin.target.os.tag != .linux) return error.SkipZigTest;

    var worker = try testWorker() orelse return error.SkipZigTest;
    defer testWorkerDeinit(&worker);

    worker.handleAccept(testAcceptCqe(-@as(i32, @intFromEnum(linux.E.AGAIN))));

    try std.testing.expectEqual(@as(u24, 0), worker.gen_counter);
}

test "zix http2 grpc: uring, handleRecv stages the reply and sends it on the ring" {
    if (comptime builtin.target.os.tag != .linux) return error.SkipZigTest;

    var worker = try testWorker() orelse return error.SkipZigTest;

    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);

    worker.handleAccept(testAcceptCqe(fds[1]));
    try writeOneCall(fds[0]);

    const ring_conn = worker.slots[@intCast(fds[1])].?;
    const cqe = try testRecvCqe(ring_conn);

    ok_calls = 0;
    worker.handleRecv(cqe, unpackUserData(cqe.user_data));

    const staged = ring_conn.inflight;
    try testCompleteSend(&worker, fds[1]);

    const kept = worker.slots[@intCast(fds[1])] != null;
    const drained = ring_conn.inflight == 0 and ring_conn.conn.stage.len == 0;
    testWorkerDeinit(&worker);

    var buf: [8192]u8 = undefined;

    try std.testing.expect(staged > 0);
    try std.testing.expect(kept);
    try std.testing.expect(drained);
    try std.testing.expectEqual(@as(usize, 1), countStatusOk(fds[0], &buf));
    try std.testing.expectEqual(@as(usize, 1), ok_calls);
}

test "zix http2 grpc: uring, handleRecv peer hang-up on an idle connection closes it" {
    if (comptime builtin.target.os.tag != .linux) return error.SkipZigTest;

    var worker = try testWorker() orelse return error.SkipZigTest;
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

test "zix http2 grpc: uring, handleRecv hang-up mid-request sends GOAWAY before close" {
    if (comptime builtin.target.os.tag != .linux) return error.SkipZigTest;

    var worker = try testWorker() orelse return error.SkipZigTest;
    defer testWorkerDeinit(&worker);

    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);

    worker.handleAccept(testAcceptCqe(fds[1]));

    const ring_conn = worker.slots[@intCast(fds[1])].?;
    _ = ring_conn.conn.claimSlot(1).?;

    const cqe: linux.io_uring_cqe = .{
        .user_data = packUserData(.recv, ring_conn.gen, fds[1]),
        .res = 0,
        .flags = 0,
    };
    worker.handleRecv(cqe, unpackUserData(cqe.user_data));

    try std.testing.expect(ring_conn.closing);
    try std.testing.expect(ring_conn.inflight > 0);

    try testCompleteSend(&worker, fds[1]);

    var head: [frame.FRAME_HEADER_LEN]u8 = undefined;
    _ = try std.posix.read(fds[0], &head);
    const header = frame.parseFrameHeader(&head);

    try std.testing.expect(worker.slots[@intCast(fds[1])] == null);
    try std.testing.expectEqual(frame.FRAME_TYPE_GOAWAY, header.frame_type);
}

test "zix http2 grpc: uring, handleRecv stale generation is ignored" {
    if (comptime builtin.target.os.tag != .linux) return error.SkipZigTest;

    var worker = try testWorker() orelse return error.SkipZigTest;
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

test "zix http2 grpc: uring, handleSend partial send resends the rest" {
    if (comptime builtin.target.os.tag != .linux) return error.SkipZigTest;

    var worker = try testWorker() orelse return error.SkipZigTest;
    defer testWorkerDeinit(&worker);

    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);

    worker.handleAccept(testAcceptCqe(fds[1]));

    const ring_conn = worker.slots[@intCast(fds[1])].?;
    ring_conn.conn.stage.append("abcdef");
    ring_conn.inflight = 6;

    const cqe: linux.io_uring_cqe = .{
        .user_data = packUserData(.send, ring_conn.gen, fds[1]),
        .res = 2,
        .flags = 0,
    };
    worker.handleSend(cqe, unpackUserData(cqe.user_data));

    const stage = &ring_conn.conn.stage;

    try std.testing.expectEqualStrings("cdef", stage.buf[0..stage.len]);
    try std.testing.expectEqual(@as(usize, 4), ring_conn.inflight);
}

test "zix http2 grpc: uring, handleSend error closes the connection" {
    if (comptime builtin.target.os.tag != .linux) return error.SkipZigTest;

    var worker = try testWorker() orelse return error.SkipZigTest;
    defer testWorkerDeinit(&worker);

    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);

    worker.handleAccept(testAcceptCqe(fds[1]));

    const ring_conn = worker.slots[@intCast(fds[1])].?;
    ring_conn.conn.stage.append("abc");
    ring_conn.inflight = 3;

    const cqe: linux.io_uring_cqe = .{
        .user_data = packUserData(.send, ring_conn.gen, fds[1]),
        .res = -@as(i32, @intFromEnum(linux.E.PIPE)),
        .flags = 0,
    };
    worker.handleSend(cqe, unpackUserData(cqe.user_data));

    try std.testing.expect(worker.slots[@intCast(fds[1])] == null);
}

test "zix http2 grpc: uring, run with an unresolvable ip is ResolveFailed" {
    if (comptime builtin.target.os.tag != .linux) return error.SkipZigTest;

    var config = testConfig();
    config.ip = "not-an-ip";

    try std.testing.expectError(
        Error.ZixHttp2_GrpcUring_ResolveFailed,
        run(TestRouter, config),
    );
}

test "zix http2 grpc: uring, run off Linux is Unsupported" {
    if (comptime builtin.target.os.tag == .linux) return error.SkipZigTest;

    const result = run(TestRouter, testConfig());

    try std.testing.expectError(Error.ZixHttp2_GrpcUring_Unsupported, result);
}

test "zix http2 grpc: uring, worker serves one call end to end" {
    if (comptime builtin.target.os.tag != .linux) return error.SkipZigTest;

    // The worker needs a ring of its own.
    var probe = testRing() orelse return error.SkipZigTest;
    probe.deinit();

    ok_calls = 0;

    try std.testing.expectEqual(@as(usize, 1), try testServeOverWorker());
    try std.testing.expectEqual(@as(usize, 1), ok_calls);
}

