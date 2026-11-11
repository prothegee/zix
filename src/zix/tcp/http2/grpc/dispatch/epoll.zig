//! ZIX Http2 Grpc dispatch epoll model
//!
//! ### file: src/zix/tcp/http2/grpc/dispatch/epoll.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Linux epoll model for gRPC: worker threads share nothing, each owns a
//! listener, an epoll instance, and the h2c connections it accepted.
//!
//! ### note:
//!
//! - A connection is served on one worker from accept to close. A handler
//!   (also a server-streaming one) runs on the event loop, so a slow handler
//!   holds up the other connections of its worker.
//! - The frames staged while one readable event is processed leave as one
//!   write (see mux/process.zig).
//! - The Router is a comptime type, so the worker entry is built per Router.
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
const cache = @import("../cache.zig");
const log = @import("../log.zig");
const process = @import("../mux/process.zig");
const Config = @import("../Config.zig");
const ConnOutcome = @import("../../mux/conn_outcome.zig").ConnOutcome;
const MuxConn = @import("../mux/MuxConn.zig");
const ServeOpts = @import("../ServeOpts.zig");
const ResponseCache = @import("../../../../utils/cache/ResponseCache.zig");
const cpu_affinity = @import("../../../../multiplexers/cpu_affinity.zig");
const reuseport = @import("../../../../multiplexers/reuseport.zig");
const slab = @import("../../../../multiplexers/slab.zig");

// --------------------------------------------------------- //
// Private:

/// Largest fd the worker slot table can name. Linux hands out the lowest free
/// fd, so the table stays sparse. A connection on a higher fd is refused.
const MAX_FD: usize = 1 << 16;

/// Max events drained per epoll_wait call.
const EPOLL_MAX_EVENTS: usize = 512;

/// How long an idle worker sleeps between stop checks, in milliseconds.
const EPOLL_WAIT_TIMEOUT_MS: i32 = 1000;

/// SO_BUSY_POLL option name (asm-generic/socket.h).
const SO_BUSY_POLL: u32 = 46;

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

fn closeListeners(listeners: []std.Io.net.Server, io: std.Io) void {
    for (listeners) |*listener| listener.deinit(io);
}

fn failSetup(ctx: *const WorkerCtx) void {
    ctx.failed.store(true, .release);
    ctx.stop.store(true, .release);
}

/// Unregister, free, and close one connection.
fn closeConn(epfd: std.posix.fd_t, slots: []?*MuxConn, fd: std.posix.fd_t) void {
    _ = linux.epoll_ctl(epfd, linux.EPOLL.CTL_DEL, fd, null);

    const idx: usize = @intCast(fd);
    if (slots[idx]) |conn| conn.deinit();
    slots[idx] = null;

    _ = linux.close(fd);
}

/// Free and close every connection still in the table.
fn closeAll(slots: []?*MuxConn) void {
    for (slots) |*slot| {
        const conn = slot.* orelse continue;
        const fd = conn.fd;

        conn.deinit();
        slot.* = null;
        _ = linux.close(fd);
    }
}

/// Accept every pending connection and register each one. Level-triggered,
/// so draining to EAGAIN misses no accept.
fn acceptAll(
    epfd: std.posix.fd_t,
    listener_fd: std.posix.fd_t,
    slots: []?*MuxConn,
    opts: ServeOpts,
    busy_poll_us: u32,
    io: std.Io,
) void {
    while (true) {
        const rc = linux.accept4(
            listener_fd,
            null,
            null,
            std.posix.SOCK.NONBLOCK | std.posix.SOCK.CLOEXEC,
        );
        switch (std.posix.errno(rc)) {
            .SUCCESS => {},
            .AGAIN => return,
            .INTR, .CONNABORTED => continue,
            else => return,
        }

        const fd: std.posix.fd_t = @intCast(rc);
        const idx: usize = @intCast(fd);
        if (idx >= slots.len) {
            _ = linux.close(fd);
            continue;
        }

        setNoDelay(fd);
        setBusyPoll(fd, busy_poll_us);

        const conn = MuxConn.init(fd, opts, io) catch |err| switch (err) {
            error.ZixHttp2_GrpcMuxConn_OutOfMemory => {
                _ = linux.close(fd);
                continue;
            },
        };

        var event = linux.epoll_event{
            .events = linux.EPOLL.IN | linux.EPOLL.RDHUP,
            .data = .{ .u64 = @intCast(fd) },
        };
        const add_rc = linux.epoll_ctl(epfd, linux.EPOLL.CTL_ADD, fd, &event);
        if (std.posix.errno(add_rc) != .SUCCESS) {
            conn.deinit();
            _ = linux.close(fd);
            continue;
        }

        slots[idx] = conn;
    }
}

/// Serve one event of a connection.
///
/// Param:
/// RouterType - type (a Router, carrying route_slice and dispatch)
/// conn - *MuxConn (the connection the event is for)
/// events - u32 (the epoll event bits)
///
/// Return:
/// - .keep_alive when the connection waits for more bytes
/// - .close on hang-up, an error event, a protocol error, or a failed read
fn serveEvent(comptime RouterType: type, conn: *MuxConn, events: u32) ConnOutcome {
    if ((events & (linux.EPOLL.HUP | linux.EPOLL.ERR)) != 0) return .close;

    return process.onReadable(RouterType, conn);
}

/// The worker thread entry for one Router. std.Thread.spawn takes a plain
/// function, so the comptime Router is bound here.
fn WorkerEntry(comptime RouterType: type) type {
    return struct {
        fn main(ctx: WorkerCtx) void {
            var worker = ctx;
            const io = worker.io;
            defer worker.listener.deinit(io);

            cpu_affinity.pinToCpu(worker.worker_id);

            // Per-worker response cache. It lives on the worker stack, so the
            // pointer installed for this thread stays valid until it returns.
            var resp_cache: ?ResponseCache = null;
            cache.installWorker(&resp_cache, std.heap.smp_allocator, worker.opts);
            defer cache.uninstallWorker(&resp_cache);

            const listener_fd = worker.listener.socket.handle;
            if (!setNonBlock(listener_fd)) {
                failSetup(&worker);
                return;
            }

            const epfd_rc = linux.epoll_create1(linux.EPOLL.CLOEXEC);
            if (std.posix.errno(epfd_rc) != .SUCCESS) {
                failSetup(&worker);
                return;
            }
            const epfd: std.posix.fd_t = @intCast(epfd_rc);
            defer _ = linux.close(epfd);

            var listener_event = linux.epoll_event{
                .events = linux.EPOLL.IN,
                .data = .{ .u64 = @intCast(listener_fd) },
            };
            const add_rc = linux.epoll_ctl(
                epfd,
                linux.EPOLL.CTL_ADD,
                listener_fd,
                &listener_event,
            );
            if (std.posix.errno(add_rc) != .SUCCESS) {
                failSetup(&worker);
                return;
            }

            const slots = slab.mapZeroedSlots(?*MuxConn, MAX_FD) catch |err| switch (err) {
                error.ZixUtils_Slab_OutOfMemory,
                error.ZixUtils_Slab_MapFailed,
                => {
                    failSetup(&worker);
                    return;
                },
            };
            defer slab.unmapSlots(slots);
            defer closeAll(slots);

            var events: [EPOLL_MAX_EVENTS]linux.epoll_event = undefined;
            var timeout_ms: i32 = EPOLL_WAIT_TIMEOUT_MS;
            while (!worker.stop.load(.acquire)) {
                const wait_rc = linux.epoll_wait(epfd, &events, EPOLL_MAX_EVENTS, timeout_ms);
                switch (std.posix.errno(wait_rc)) {
                    .SUCCESS => {},
                    .INTR => continue,
                    else => {
                        failSetup(&worker);
                        return;
                    },
                }

                const event_count: usize = @intCast(wait_rc);

                // After a busy pass, poll once more without sleeping. An idle
                // pass goes back to the bounded sleep.
                timeout_ms = if (event_count == 0) EPOLL_WAIT_TIMEOUT_MS else 0;

                for (events[0..event_count]) |event| {
                    const fd: std.posix.fd_t = @intCast(event.data.u64);
                    if (fd == listener_fd) {
                        acceptAll(
                            epfd,
                            listener_fd,
                            slots,
                            worker.opts,
                            worker.busy_poll_us,
                            io,
                        );
                        continue;
                    }

                    const conn = slots[@intCast(fd)] orelse continue;
                    if (serveEvent(RouterType, conn, event.events) == .close) {
                        closeConn(epfd, slots, fd);
                    }
                }
            }
        }
    };
}

// --------------------------------------------------------- //
// Public:

/// ZIX Http2 Grpc epoll dispatch error
pub const Error = error {
    ZixHttp2_GrpcEpoll_Unsupported,
    ZixHttp2_GrpcEpoll_ResolveFailed,
    ZixHttp2_GrpcEpoll_ListenFailed,
    ZixHttp2_GrpcEpoll_OutOfMemory,
    ZixHttp2_GrpcEpoll_SpawnFailed,
    ZixHttp2_GrpcEpoll_SetupFailed,
};

/// Run one epoll worker per available CPU, or per config.workers when
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
/// - Error.ZixHttp2_GrpcEpoll_Unsupported off Linux
/// - Error.ZixHttp2_GrpcEpoll_ResolveFailed, ListenFailed, OutOfMemory, or
///   SpawnFailed before serving
/// - Error.ZixHttp2_GrpcEpoll_SetupFailed when a worker could not start its loop
pub fn run(comptime RouterType: type, config: Config) Error!void {
    if (comptime builtin.target.os.tag != .linux) {
        return Error.ZixHttp2_GrpcEpoll_Unsupported;
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
        else => return Error.ZixHttp2_GrpcEpoll_ResolveFailed,
    };

    const listeners = allocator.alloc(
        std.Io.net.Server,
        workers,
    ) catch |err| switch (err) {
        error.OutOfMemory => return Error.ZixHttp2_GrpcEpoll_OutOfMemory,
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

                return Error.ZixHttp2_GrpcEpoll_ListenFailed;
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

            return Error.ZixHttp2_GrpcEpoll_OutOfMemory;
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
            WorkerEntry(RouterType).main,
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

                return Error.ZixHttp2_GrpcEpoll_SpawnFailed;
            },
        };
    }

    log.logSystem(
        config,
        .INFO,
        "listening on {s}:{d} (epoll, {d} workers)",
        .{ config.ip, config.port, workers },
    );

    for (threads) |thread| thread.join();

    allocator.free(listeners);

    if (failed.load(.acquire)) return Error.ZixHttp2_GrpcEpoll_SetupFailed;
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

fn testConfig() Config {
    return .{
        .io = std.testing.io,
        .ip = "127.0.0.1",
        .port = 0,
        .dispatch_model = .EPOLL,
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

/// Send the preface, SETTINGS, and one unary call with an empty message on
/// stream 1.
fn writeOneCall(fd: std.posix.fd_t) !void {
    var block: [128]u8 = undefined;
    var encoder = HpackEncoder.init(&block);
    try encoder.writeHeader(":method", "POST");
    try encoder.writeHeader(":path", "/svc.Svc/Method");

    const empty_message = [_]u8{ 0, 0, 0, 0, 0 };

    try writer.writeAllDirectFD(fd, frame.PREFACE);
    try writeFrameTo(fd, frame.FRAME_TYPE_SETTINGS, 0, 0, "");
    try writeFrameTo(fd, frame.FRAME_TYPE_HEADERS, frame.FLAG_END_HEADERS, 1, encoder.encoded());
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

/// A listener on a free loopback port, non-blocking, as a worker holds it.
fn testListener() !std.Io.net.Server {
    const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    const listener = try address.listen(std.testing.io, .{
        .mode = .stream,
        .reuse_address = true,
        .kernel_backlog = 8,
    });

    try std.testing.expect(setNonBlock(listener.socket.handle));

    return listener;
}

fn testEpoll() !std.posix.fd_t {
    const rc = linux.epoll_create1(linux.EPOLL.CLOEXEC);
    if (std.posix.errno(rc) != .SUCCESS) return error.SkipZigTest;

    return @intCast(rc);
}

fn countSlots(slots: []?*MuxConn) usize {
    var count: usize = 0;
    for (slots) |slot| {
        if (slot != null) count += 1;
    }

    return count;
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
    const thread = try std.Thread.spawn(.{}, WorkerEntry(TestRouter).main, .{WorkerCtx{
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

test "zix http2 grpc: epoll, workerCount keeps an explicit count" {
    try std.testing.expectEqual(@as(usize, 3), workerCount(3));
}

test "zix http2 grpc: epoll, workerCount zero is at least 1" {
    try std.testing.expect(workerCount(0) >= 1);
}

test "zix http2 grpc: epoll, setNonBlock sets O_NONBLOCK" {
    if (comptime builtin.target.os.tag != .linux) return error.SkipZigTest;

    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    try std.testing.expect(setNonBlock(fds[1]));

    const rc = linux.fcntl(fds[1], linux.F.GETFL, 0);
    const flags: linux.O = @bitCast(@as(u32, @intCast(rc)));

    try std.testing.expect(flags.NONBLOCK);
}

test "zix http2 grpc: epoll, serveEvent answers one call" {
    if (comptime builtin.target.os.tag != .linux) return error.SkipZigTest;

    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);

    try std.testing.expect(setNonBlock(fds[1]));
    try writeOneCall(fds[0]);

    const conn = try MuxConn.init(fds[1], .{}, std.testing.io);

    ok_calls = 0;
    const outcome = serveEvent(TestRouter, conn, linux.EPOLL.IN);

    conn.deinit();
    _ = std.posix.system.close(fds[1]);

    var buf: [8192]u8 = undefined;

    try std.testing.expectEqual(ConnOutcome.keep_alive, outcome);
    try std.testing.expectEqual(@as(usize, 1), countStatusOk(fds[0], &buf));
    try std.testing.expectEqual(@as(usize, 1), ok_calls);
}

test "zix http2 grpc: epoll, serveEvent on HUP is close" {
    if (comptime builtin.target.os.tag != .linux) return error.SkipZigTest;

    const conn = try MuxConn.init(-1, .{}, std.testing.io);
    defer conn.deinit();

    const outcome = serveEvent(TestRouter, conn, linux.EPOLL.HUP);

    try std.testing.expectEqual(ConnOutcome.close, outcome);
}

test "zix http2 grpc: epoll, serveEvent on ERR is close" {
    if (comptime builtin.target.os.tag != .linux) return error.SkipZigTest;

    const conn = try MuxConn.init(-1, .{}, std.testing.io);
    defer conn.deinit();

    const outcome = serveEvent(TestRouter, conn, linux.EPOLL.ERR);

    try std.testing.expectEqual(ConnOutcome.close, outcome);
}

test "zix http2 grpc: epoll, serveEvent peer hang-up is close" {
    if (comptime builtin.target.os.tag != .linux) return error.SkipZigTest;

    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[1]);

    try std.testing.expect(setNonBlock(fds[1]));
    _ = std.posix.system.close(fds[0]);

    const conn = try MuxConn.init(fds[1], .{}, std.testing.io);
    defer conn.deinit();

    const outcome = serveEvent(TestRouter, conn, linux.EPOLL.IN);

    try std.testing.expectEqual(ConnOutcome.close, outcome);
}

test "zix http2 grpc: epoll, acceptAll with nothing pending registers nothing" {
    if (comptime builtin.target.os.tag != .linux) return error.SkipZigTest;

    var listener = try testListener();
    defer listener.deinit(std.testing.io);

    const epfd = try testEpoll();
    defer _ = linux.close(epfd);

    var slots: [64]?*MuxConn = @splat(null);
    acceptAll(epfd, listener.socket.handle, &slots, .{}, 0, std.testing.io);

    try std.testing.expectEqual(@as(usize, 0), countSlots(&slots));
}

test "zix http2 grpc: epoll, acceptAll registers a pending connection" {
    if (comptime builtin.target.os.tag != .linux) return error.SkipZigTest;

    var listener = try testListener();
    defer listener.deinit(std.testing.io);

    const epfd = try testEpoll();
    defer _ = linux.close(epfd);

    var client = try listener.socket.address.connect(std.testing.io, .{
        .mode = .stream,
    });
    defer client.close(std.testing.io);

    const slots = try slab.mapZeroedSlots(?*MuxConn, MAX_FD);
    defer slab.unmapSlots(slots);
    defer closeAll(slots);

    acceptAll(epfd, listener.socket.handle, slots, .{}, 0, std.testing.io);

    try std.testing.expectEqual(@as(usize, 1), countSlots(slots));
}

test "zix http2 grpc: epoll, closeConn frees the slot" {
    if (comptime builtin.target.os.tag != .linux) return error.SkipZigTest;

    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);

    const epfd = try testEpoll();
    defer _ = linux.close(epfd);

    const slots = try slab.mapZeroedSlots(?*MuxConn, MAX_FD);
    defer slab.unmapSlots(slots);

    slots[@intCast(fds[1])] = try MuxConn.init(fds[1], .{}, std.testing.io);
    closeConn(epfd, slots, fds[1]);

    try std.testing.expectEqual(@as(usize, 0), countSlots(slots));
}

test "zix http2 grpc: epoll, run with an unresolvable ip is ResolveFailed" {
    if (comptime builtin.target.os.tag != .linux) return error.SkipZigTest;

    var config = testConfig();
    config.ip = "not-an-ip";

    try std.testing.expectError(
        Error.ZixHttp2_GrpcEpoll_ResolveFailed,
        run(TestRouter, config),
    );
}

test "zix http2 grpc: epoll, run off Linux is Unsupported" {
    if (comptime builtin.target.os.tag == .linux) return error.SkipZigTest;

    const result = run(TestRouter, testConfig());

    try std.testing.expectError(Error.ZixHttp2_GrpcEpoll_Unsupported, result);
}

test "zix http2 grpc: epoll, worker serves one call end to end" {
    if (comptime builtin.target.os.tag != .linux) return error.SkipZigTest;

    ok_calls = 0;

    try std.testing.expectEqual(@as(usize, 1), try testServeOverWorker());
    try std.testing.expectEqual(@as(usize, 1), ok_calls);
}

