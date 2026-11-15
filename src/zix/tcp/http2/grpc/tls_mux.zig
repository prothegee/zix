//! ZIX http2 grpc tls mux
//!
//! ### file: src/zix/tcp/http2/grpc/tls_mux.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! gRPC over TLS serve path for .EPOLL and .URING: one SO_REUSEPORT listener
//! and epoll instance per worker, each connection terminates TLS in place.
//!
//! ### note:
//!
//! recv ciphertext, decrypt, feed the resumable gRPC mux, flush its reply stage
//! through the writer write_hook, seal, send. No socketpair and no thread per
//! connection. Writes never block: on EAGAIN the ciphertext is staged and
//! EPOLLOUT is armed. The connection machinery (ConnTable, onCiphertext,
//! acceptAll) is public so the dual-listener loops host TLS connections next
//! to cleartext ones. TLS 1.3 only. The .ASYNC path (tls_serve) also serves
//! TLS 1.2.
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
const tlz = @import("tlz");
const Config = @import("Config.zig");
const log = @import("log.zig");
const mux_dispatch = @import("mux/mux_dispatch.zig");
const process = @import("mux/process.zig");
const writer = @import("../writer.zig");
const MuxConn = @import("mux/MuxConn.zig");
const TlsConn = @import("tls_mux/TlsConn.zig");
const WorkerCtx = @import("tls_mux/WorkerCtx.zig");
const tls_conn = @import("../../../multiplexers/tls_conn.zig");
const cpu_affinity = @import("../../../multiplexers/cpu_affinity.zig");

const linux = std.os.linux;

// --------------------------------------------------------- //
// Private:

const MAX_FD: usize = 1 << 16;
const EPOLL_MAX_EVENTS: usize = 4096;
const EPOLL_WAIT_TIMEOUT_MS: i32 = 1000;

/// Inbound ciphertext read staging (may hold several records per read).
const TLS_READ_STAGING_SIZE: usize = tls_conn.READ_STAGING_SIZE;

/// Decrypted plaintext staging for one feed.
const TLS_PLAIN_STAGING_SIZE: usize = 32 * 1024;

/// Handshake flight and alert staging for one feed.
const TLS_SEND_STAGING_SIZE: usize = 32 * 1024;

/// One sealed record: a full plaintext record plus its AEAD overhead.
const TLS_SEALED_RECORD_SIZE: usize = tlz.sealedLen(tlz.MAX_PLAINTEXT);

/// Data word of the listener in a TLS-only worker. No fd reaches it.
const LISTENER_DATA: u64 = tls_conn.TLS_EVENT_TAG - 1;

fn freeConn(conn: *TlsConn) void {
    conn.destroy();
}

fn workerCount(workers: usize) usize {
    if (workers != 0) return workers;

    return @max(1, cpu_affinity.availableCpuCount());
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

fn setNonBlock(fd: std.posix.fd_t) bool {
    const rc = linux.fcntl(fd, linux.F.GETFL, 0);
    if (linux.errno(rc) != .SUCCESS) return false;

    var flags: linux.O = @bitCast(@as(u32, @intCast(rc)));
    flags.NONBLOCK = true;
    const bits: u32 = @bitCast(flags);
    const set_rc = linux.fcntl(fd, linux.F.SETFL, @intCast(bits));

    return linux.errno(set_rc) == .SUCCESS;
}

fn closeListeners(listeners: []std.Io.net.Server, io: std.Io) void {
    for (listeners) |*listener| listener.deinit(io);
}

/// Seal the plaintext staged this pass into one record and send it.
fn flushPlain(conn: *TlsConn) void {
    if (conn.plain_len == 0) return;

    var sealed: [TLS_SEALED_RECORD_SIZE]u8 = undefined;
    const plain_len = conn.plain_len;
    conn.plain_len = 0;

    if (!conn.transport.sendPlain(conn.plain[0..plain_len], &sealed)) {
        conn.transport.wclose = true;
    }
}

/// Seal one full record gathered from the staged prefix and a slice of the
/// source, so a large DATA payload is never copied into plain first.
fn sealGather(conn: *TlsConn, prefix: []const u8, tail: []const u8) void {
    var sealed: [TLS_SEALED_RECORD_SIZE]u8 = undefined;

    if (!conn.transport.sendPlainGather(prefix, tail, &sealed)) {
        conn.transport.wclose = true;
    }
}

/// The writer write_hook: the mux writes plaintext frames here. Every full
/// record the staged prefix plus bytes completes is sealed straight from
/// source, only the remainder below one record is staged.
fn hookWrite(ctx_ptr: *anyopaque, bytes: []const u8) void {
    const conn: *TlsConn = @ptrCast(@alignCast(ctx_ptr));
    var rest = bytes;

    while (conn.plain_len + rest.len >= conn.plain.len) {
        const take = conn.plain.len - conn.plain_len;
        sealGather(conn, conn.plain[0..conn.plain_len], rest[0..take]);

        conn.plain_len = 0;
        rest = rest[take..];
    }

    @memcpy(conn.plain[conn.plain_len..][0..rest.len], rest);
    conn.plain_len += rest.len;
}

/// Route every frame write on this thread into conn until uninstallHook.
fn installHook(conn: *TlsConn) void {
    writer.write_hook = hookWrite;
    writer.write_hook_ctx = conn;
}

/// Seal what is still staged, then give the writer back its direct path.
fn uninstallHook(conn: *TlsConn) void {
    flushPlain(conn);

    writer.write_hook = null;
    writer.write_hook_ctx = null;
}

/// Append decrypted plaintext to the mux read buffer and drive it, sealing
/// the reply stage through the write hook.
///
/// Note:
/// - Plaintext wider than the free room is fed in parts, each part processed
///   before the next, so a partial frame plus a full record never overflows.
///
/// Return:
/// - bool (false when the mux asks to close or a frame can never fit)
fn feedMux(
    comptime RouterType: type,
    conn: *TlsConn,
    mux: *MuxConn,
    plaintext: []const u8,
) bool {
    var rest = plaintext;

    while (rest.len > 0) {
        const take = mux.makeRoom(rest.len);
        if (take == 0) return false;

        @memcpy(mux.rbuf[mux.rend..][0..take], rest[0..take]);
        mux.rend += take;
        rest = rest[take..];

        installHook(conn);
        const outcome = process.processRing(RouterType, mux);
        mux.stage.flush();
        uninstallHook(conn);

        if (outcome == .close) return false;
    }

    return true;
}

/// The worker thread entry for one Router. std.Thread.spawn takes a plain
/// function, so the comptime Router is bound here.
fn WorkerEntry(comptime RouterType: type) type {
    return struct {
        fn main(ctx: WorkerCtx) void {
            var worker = ctx;
            const io = worker.io;
            defer worker.listener.deinit(io);

            // Pinned like the cleartext loop, so a handshake storm does not
            // thrash threads.
            cpu_affinity.pinToCpu(worker.worker_id);

            const listener_fd = worker.listener.socket.handle;
            if (!setNonBlock(listener_fd)) return worker.failSetup();

            const epfd_rc = linux.epoll_create1(linux.EPOLL.CLOEXEC);
            if (linux.errno(epfd_rc) != .SUCCESS) return worker.failSetup();

            const epfd: std.posix.fd_t = @intCast(epfd_rc);
            defer _ = linux.close(epfd);

            var listener_event = linux.epoll_event{
                .events = linux.EPOLL.IN,
                .data = .{ .u64 = LISTENER_DATA },
            };
            const add_rc = linux.epoll_ctl(
                epfd,
                linux.EPOLL.CTL_ADD,
                listener_fd,
                &listener_event,
            );
            if (linux.errno(add_rc) != .SUCCESS) return worker.failSetup();

            var table = ConnTable.init() catch |err| switch (err) {
                error.ZixMultiplexers_ConnTable_OutOfMemory,
                error.ZixMultiplexers_ConnTable_MapFailed,
                => return worker.failSetup(),
            };
            defer table.deinit();

            var events: [EPOLL_MAX_EVENTS]linux.epoll_event = undefined;
            while (!worker.stop.load(.acquire)) {
                const wait_rc = linux.epoll_wait(
                    epfd,
                    &events,
                    EPOLL_MAX_EVENTS,
                    EPOLL_WAIT_TIMEOUT_MS,
                );
                switch (linux.errno(wait_rc)) {
                    .SUCCESS => {},
                    .INTR => continue,
                    else => return worker.failSetup(),
                }

                const event_count: usize = @intCast(wait_rc);
                for (events[0..event_count]) |event| {
                    if (event.data.u64 == LISTENER_DATA) {
                        acceptAll(&table, epfd, listener_fd, .{
                            .io = io,
                            .ctx = worker.ctx,
                            .opts = worker.opts,
                            .ev_tag = 0,
                        });
                        continue;
                    }

                    const fd: std.posix.fd_t = @intCast(event.data.u64);
                    const conn = table.get(fd) orelse continue;

                    if (!onEvent(RouterType, conn, epfd, event.events)) {
                        _ = linux.epoll_ctl(epfd, linux.EPOLL.CTL_DEL, fd, null);
                        table.drop(fd);
                        _ = linux.close(fd);
                    }
                }
            }
        }
    };
}

// --------------------------------------------------------- //
// Public:

/// ZIX Http2 Grpc TLS mux error
pub const Error = error {
    ZixHttp2_GrpcTlsMux_Unsupported,
    ZixHttp2_GrpcTlsMux_ResolveFailed,
    ZixHttp2_GrpcTlsMux_ListenFailed,
    ZixHttp2_GrpcTlsMux_OutOfMemory,
    ZixHttp2_GrpcTlsMux_SpawnFailed,
    ZixHttp2_GrpcTlsMux_SetupFailed,
};

/// Per-worker fd to TlsConn map.
pub const ConnTable = tls_conn.ConnTable(TlsConn, MAX_FD, freeConn);

/// What every connection accepted on a TLS listener is given.
pub const AcceptOpts = @import("tls_mux/AcceptOpts.zig");

/// What a peer gets when it hangs up part way through a call: the GOAWAY the
/// cleartext models send, sealed into a record first.
///
/// Note:
/// - A connection with no call in flight, or one that never finished its
///   handshake, is answered nothing.
///
/// Return:
/// - bool (true when the connection must stay to flush the answer)
pub fn hangupGoaway(conn: *TlsConn) bool {
    const mux = conn.mux orelse return false;
    if (!mux.requestInFlight()) return false;

    installHook(conn);
    _ = mux_dispatch.hangupGoaway(mux);
    mux.stage.flush();
    uninstallHook(conn);

    conn.transport.wclose = true;

    return conn.transport.want_out;
}

/// Feed one received ciphertext chunk through the session and the gRPC mux.
/// The recv-model-agnostic core: epoll calls it from its read loop, io_uring
/// per recv completion.
///
/// Note:
/// - The mux is created once the handshake is established. A handshake that
///   did not select ALPN h2 closes the connection (RFC 7540 3.3).
///
/// Param:
/// RouterType - type (a Router, carrying route_slice and dispatch)
/// conn - *TlsConn (the connection the ciphertext arrived on)
/// cipher - []const u8 (the received ciphertext)
///
/// Return:
/// - bool (false when the connection must close now. wclose with staged bytes
///   means flush, then close)
pub fn onCiphertext(comptime RouterType: type, conn: *TlsConn, cipher: []const u8) bool {
    var to_send: [TLS_SEND_STAGING_SIZE]u8 = undefined;
    var plain_in: [TLS_PLAIN_STAGING_SIZE]u8 = undefined;

    const fed = conn.transport.tls.feed(cipher, &to_send, &plain_in);

    if (fed.to_send.len > 0 and !conn.transport.sendRaw(fed.to_send)) return false;

    if (fed.outcome == .ESTABLISHED) {
        if (!conn.transport.tls.alpnIsH2()) return false;

        conn.mux = MuxConn.init(conn.transport.fd, conn.opts, conn.io) catch |err| switch (err) {
            error.ZixHttp2_GrpcMuxConn_OutOfMemory => return false,
        };
    }

    if (fed.outcome == .CLOSE) {
        // Kept only to flush a final alert.
        conn.transport.wclose = true;

        return true;
    }

    if (fed.plaintext.len == 0) return true;

    const mux = conn.mux orelse return false;

    return feedMux(RouterType, conn, mux, fed.plaintext);
}

/// Handle a readable connection: read what the session can take, feed it.
///
/// Note:
/// - The read is sized by readRoom, not by the staging buffer. A busy socket
///   would otherwise hand the session two records at once, which it refuses.
///
/// Return:
/// - bool (false when the connection must close)
pub fn onReadable(comptime RouterType: type, conn: *TlsConn) bool {
    var cipher: [TLS_READ_STAGING_SIZE]u8 = undefined;

    while (true) {
        const room = conn.transport.tls.readRoom();
        if (room == 0) return false;

        const rc = linux.read(conn.transport.fd, &cipher, @min(cipher.len, room));
        switch (linux.errno(rc)) {
            .SUCCESS => if (rc == 0) return hangupGoaway(conn),
            .INTR => continue,
            .AGAIN => return true,
            else => return false,
        }

        if (!onCiphertext(RouterType, conn, cipher[0..rc])) return false;
        if (conn.transport.wclose) return conn.transport.want_out;
    }
}

/// Handle one epoll event on a TLS connection: flush, read, re-arm.
///
/// Return:
/// - bool (false when the connection must close)
pub fn onEvent(
    comptime RouterType: type,
    conn: *TlsConn,
    epfd: std.posix.fd_t,
    events: u32,
) bool {
    if ((events & (linux.EPOLL.HUP | linux.EPOLL.ERR)) != 0) return false;

    var keep = true;
    const transport = &conn.transport;

    if ((events & linux.EPOLL.OUT) != 0) keep = transport.onWritable(epfd);
    if (keep and (events & linux.EPOLL.IN) != 0) keep = onReadable(RouterType, conn);

    if (keep and transport.want_out) {
        tls_conn.armOut(epfd, transport.fd, transport.ep_data, true);
    }
    if (keep and transport.wclose and !transport.want_out) keep = false;

    return keep;
}

/// Accept every pending TLS connection and register each in epfd with
/// ev_tag | fd as the event data.
pub fn acceptAll(
    table: *ConnTable,
    epfd: std.posix.fd_t,
    listener_fd: std.posix.fd_t,
    opts: AcceptOpts,
) void {
    while (true) {
        const rc = linux.accept4(
            listener_fd,
            null,
            null,
            std.posix.SOCK.NONBLOCK | std.posix.SOCK.CLOEXEC,
        );
        switch (linux.errno(rc)) {
            .SUCCESS => {},
            .AGAIN => return,
            .INTR, .CONNABORTED => continue,
            else => return,
        }

        const fd: std.posix.fd_t = @intCast(rc);
        setNoDelay(fd);

        if (rc >= table.slots.len) {
            _ = linux.close(fd);
            continue;
        }

        const conn = TlsConn.create(opts.io, fd, opts.ctx, opts.opts) orelse {
            _ = linux.close(fd);
            continue;
        };
        conn.transport.ep_data = opts.ev_tag | rc;
        table.put(fd, conn);

        var event = linux.epoll_event{
            .events = linux.EPOLL.IN | linux.EPOLL.RDHUP,
            .data = .{ .u64 = conn.transport.ep_data },
        };
        const add_rc = linux.epoll_ctl(epfd, linux.EPOLL.CTL_ADD, fd, &event);
        if (linux.errno(add_rc) != .SUCCESS) {
            table.drop(fd);
            _ = linux.close(fd);
        }
    }
}

/// Listen and serve gRPC over TLS, one epoll worker per core, or per
/// config.workers when non-zero.
///
/// Param:
/// RouterType - type (a Router, carrying route_slice and dispatch)
/// config - Config (listen address, knobs)
/// ctx - *const tlz.Context (borrowed, must outlive the server)
///
/// Return:
/// - void once every worker stopped
/// - Error.ZixHttp2_GrpcTlsMux_ResolveFailed or ListenFailed when a bind fails
/// - Error.ZixHttp2_GrpcTlsMux_SetupFailed when a worker could not set up
pub fn run(comptime RouterType: type, config: Config, ctx: *const tlz.Context) Error!void {
    if (comptime builtin.target.os.tag != .linux) return Error.ZixHttp2_GrpcTlsMux_Unsupported;

    const io = config.io;
    const allocator = std.heap.smp_allocator;
    const workers = workerCount(config.workers);
    const opts = config.serveOpts();

    const address = std.Io.net.IpAddress.resolve(io, config.ip, config.port) catch |err| {
        switch (err) {
            else => return Error.ZixHttp2_GrpcTlsMux_ResolveFailed,
        }
    };

    const listeners = allocator.alloc(std.Io.net.Server, workers) catch |err| switch (err) {
        error.OutOfMemory => return Error.ZixHttp2_GrpcTlsMux_OutOfMemory,
    };
    defer allocator.free(listeners);

    var bound: usize = 0;
    while (bound < workers) : (bound += 1) {
        listeners[bound] = address.listen(io, .{
            .mode = .stream,
            .reuse_address = true,
            .kernel_backlog = config.kernel_backlog,
        }) catch |err| switch (err) {
            else => {
                closeListeners(listeners[0..bound], io);

                return Error.ZixHttp2_GrpcTlsMux_ListenFailed;
            },
        };
    }

    const threads = allocator.alloc(std.Thread, workers) catch |err| switch (err) {
        error.OutOfMemory => {
            closeListeners(listeners, io);

            return Error.ZixHttp2_GrpcTlsMux_OutOfMemory;
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
                .ctx = ctx,
                .listener = listeners[spawned],
                .worker_id = spawned,
                .stop = &stop,
                .failed = &failed,
            }},
        ) catch |err| switch (err) {
            else => {
                stop.store(true, .release);
                closeListeners(listeners[spawned..], io);
                for (threads[0..spawned]) |thread| thread.join();

                return Error.ZixHttp2_GrpcTlsMux_SpawnFailed;
            },
        };
    }

    log.logSystem(config, .INFO, "listening on {s}:{d} (grpc TLS, epoll-mux/{d})", .{
        config.ip,
        config.port,
        workers,
    });

    for (threads) |thread| thread.join();

    if (failed.load(.acquire)) return Error.ZixHttp2_GrpcTlsMux_SetupFailed;
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const frame = @import("../frame.zig");
const pair = @import("../../../utils/socket/pair.zig");
const router = @import("router.zig");
const HpackEncoder = @import("../hpack/HpackEncoder.zig");
const Request = @import("Request.zig");
const Response = @import("Response.zig");
const Context = @import("Context.zig");
const ServeOpts = @import("ServeOpts.zig");

const CERT_PATH = "examples/certs/ecdsa_p256_cert.pem";
const KEY_PATH = "examples/certs/ecdsa_p256_key.pem";
const CONTENT_HANDSHAKE: u8 = @intFromEnum(tlz.ContentType.HANDSHAKE);
const CALL_PATH = "/svc.Svc/Method";

/// gRPC message prefix: compressed flag plus a 4-byte length.
const PREFIX_LEN: usize = 5;

/// Message bytes seen by bodyHandler, and how often it ran.
var body_seen: usize = 0;
var body_dispatches: usize = 0;

fn okHandler(_: *Request, res: *Response, _: *Context) anyerror!void {
    try res.finish(.OK, "");
}

fn bodyHandler(req: *Request, res: *Response, _: *Context) anyerror!void {
    body_dispatches += 1;
    body_seen = if (req.recvMessage()) |message| message.len else 0;

    try res.finish(.OK, "");
}

const ok_router = router.Router(&[_]router.Route{
    .{
        .path = CALL_PATH,
        .handler = okHandler,
    },
});

const body_router = router.Router(&[_]router.Route{
    .{
        .path = CALL_PATH,
        .handler = bodyHandler,
    },
});

fn testWriteAll(fd: std.posix.fd_t, bytes: []const u8) !void {
    var off: usize = 0;
    while (off < bytes.len) {
        const rc = linux.write(fd, bytes[off..].ptr, bytes.len - off);
        if (linux.errno(rc) != .SUCCESS) return error.ZixTest_WriteFailed;

        off += rc;
    }
}

/// Read one whole record from a blocking fd.
fn readRecordFd(fd: std.posix.fd_t, buf: []u8) ![]const u8 {
    var got: usize = 0;
    var total: usize = 5;
    while (got < total) {
        const rc = linux.read(fd, buf[got..].ptr, total - got);
        if (linux.errno(rc) != .SUCCESS) return error.ZixTest_ReadFailed;
        if (rc == 0) return error.ZixTest_Closed;

        got += rc;
        if (got == 5) total = 5 + @as(usize, std.mem.readInt(u16, buf[3..5], .big));
    }

    return buf[0..total];
}

/// Read what is queued on a non-blocking fd onto the tail of buf.
fn drainNonblock(fd: std.posix.fd_t, buf: []u8, len: usize) usize {
    var total = len;
    while (total < buf.len) {
        const rc = linux.read(fd, buf[total..].ptr, buf.len - total);
        switch (linux.errno(rc)) {
            .SUCCESS => {
                if (rc == 0) break;

                total += rc;
            },
            .INTR => continue,
            else => break,
        }
    }

    return total;
}

/// What the server answered, decrypted from the records readable right now.
const Tally = struct {
    rst_protocol_error: usize = 0,
    goaway_protocol_error: usize = 0,
    /// HEADERS frames that end a stream: one gRPC trailer per finished call.
    trailers: usize = 0,
};

/// A TlsConn served over a socketpair with an established client session.
const TestSession = struct {
    conn: *TlsConn,
    client_fd: std.posix.fd_t,
    server_fd: std.posix.fd_t,
    finished: tlz.Client.FinishResult,

    fn deinit(self: *TestSession) void {
        self.conn.destroy();
        _ = linux.close(self.client_fd);
        _ = linux.close(self.server_fd);
    }

    fn readable(self: *TestSession, comptime RouterType: type) bool {
        return onReadable(RouterType, self.conn);
    }

    fn sendPlain(self: *TestSession, plaintext: []const u8) !void {
        var enc: [tlz.sealedLen(tlz.MAX_PLAINTEXT)]u8 = undefined;

        try testWriteAll(self.client_fd, self.finished.connection.writeAppData(plaintext, &enc));
    }

    fn sendPreface(self: *TestSession) !void {
        var plain: [64]u8 = undefined;
        @memcpy(plain[0..frame.PREFACE.len], frame.PREFACE);
        frame.encodeFrameHeader(plain[frame.PREFACE.len..][0..frame.FRAME_HEADER_LEN], .{
            .length = 0,
            .frame_type = frame.FRAME_TYPE_SETTINGS,
            .flags = 0,
            .stream_id = 0,
        });

        try self.sendPlain(plain[0 .. frame.PREFACE.len + frame.FRAME_HEADER_LEN]);
    }

    fn sendFrame(
        self: *TestSession,
        frame_type: u8,
        flags: u8,
        sid: u31,
        payload: []const u8,
    ) !void {
        var plain: [tlz.MAX_PLAINTEXT]u8 = undefined;
        frame.encodeFrameHeader(plain[0..frame.FRAME_HEADER_LEN], .{
            .length = @intCast(payload.len),
            .frame_type = frame_type,
            .flags = flags,
            .stream_id = sid,
        });
        @memcpy(plain[frame.FRAME_HEADER_LEN..][0..payload.len], payload);

        try self.sendPlain(plain[0 .. frame.FRAME_HEADER_LEN + payload.len]);
    }

    /// Decrypt every whole record queued now and count the answers in it.
    fn tally(self: *TestSession) Tally {
        var cipher: [128 * 1024]u8 = undefined;
        const cipher_len = drainNonblock(self.client_fd, &cipher, 0);

        var plain: [128 * 1024]u8 = undefined;
        var plain_len: usize = 0;
        var off: usize = 0;
        while (cipher_len - off >= 5) {
            const rec_len = std.mem.readInt(u16, cipher[off + 3 ..][0..2], .big);
            if (cipher_len - off < 5 + rec_len) break;

            const rec = cipher[off .. off + 5 + rec_len];
            const client = &self.finished.connection;
            const dec = client.readAppData(rec, plain[plain_len..]) catch break;
            plain_len += dec.len;
            off += 5 + rec_len;
        }

        var result: Tally = .{};
        var frame_off: usize = 0;
        while (frame_off + frame.FRAME_HEADER_LEN <= plain_len) {
            const header = frame.parseFrameHeader(plain[frame_off..][0..frame.FRAME_HEADER_LEN]);
            frame_off += frame.FRAME_HEADER_LEN;
            if (frame_off + header.length > plain_len) break;

            const payload = plain[frame_off..][0..header.length];
            switch (header.frame_type) {
                frame.FRAME_TYPE_RST_STREAM => {
                    const code = std.mem.readInt(u32, payload[0..4], .big);
                    if (code == frame.ERR_PROTOCOL_ERROR) result.rst_protocol_error += 1;
                },
                frame.FRAME_TYPE_GOAWAY => {
                    const code = std.mem.readInt(u32, payload[4..8], .big);
                    if (code == frame.ERR_PROTOCOL_ERROR) result.goaway_protocol_error += 1;
                },
                frame.FRAME_TYPE_HEADERS => {
                    if ((header.flags & frame.FLAG_END_STREAM) != 0) result.trailers += 1;
                },
                else => {},
            }
            frame_off += header.length;
        }

        return result;
    }
};

fn testContext() !tlz.Context {
    return tlz.Context.init(std.testing.allocator, std.testing.io, .{
        .cert_path = CERT_PATH,
        .key_path = KEY_PATH,
        .alpn = &.{.H2},
    });
}

/// Run the client handshake against a TlsConn driven through onReadable.
fn startSession(
    self: *TestSession,
    comptime RouterType: type,
    ctx: *const tlz.Context,
    opts: ServeOpts,
    alpn: []const tlz.Alpn,
) !void {
    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    try std.testing.expect(setNonBlock(fds[1]));

    const conn = TlsConn.create(std.testing.io, fds[1], ctx, opts) orelse {
        return error.ZixTest_OutOfMemory;
    };

    self.* = .{
        .conn = conn,
        .client_fd = fds[0],
        .server_fd = fds[1],
        .finished = undefined,
    };

    var hello_buf: [512]u8 = undefined;
    const started = try tlz.Client.start(.{
        .client_random = @splat(0x11),
        .ephemeral_secret = @splat(0x42),
        .alpn = alpn,
    }, &hello_buf);
    var state = started.state;

    var hello_rec: [600]u8 = undefined;
    hello_rec[0] = CONTENT_HANDSHAKE;
    std.mem.writeInt(u16, hello_rec[1..3], 0x0303, .big);
    std.mem.writeInt(u16, hello_rec[3..5], @intCast(started.client_hello.len), .big);
    @memcpy(hello_rec[5..][0..started.client_hello.len], started.client_hello);
    try testWriteAll(self.client_fd, hello_rec[0 .. 5 + started.client_hello.len]);

    try std.testing.expect(self.readable(RouterType));

    var flight_buf: [4096]u8 = undefined;
    var flight_len: usize = 0;
    for (0..3) |_| {
        const rec = try readRecordFd(self.client_fd, flight_buf[flight_len..]);
        flight_len += rec.len;
    }

    var fin_buf: [256]u8 = undefined;
    self.finished = try tlz.Client.finish(&state, flight_buf[0..flight_len], &fin_buf);
    try testWriteAll(self.client_fd, self.finished.client_finished);
}

/// Encode a call head: POST on CALL_PATH, with a content-length when given.
fn encodeHead(block: []u8, content_length: ?[]const u8) ![]const u8 {
    var encoder = HpackEncoder.init(block);
    try encoder.writeHeader(":method", "POST");
    try encoder.writeHeader(":path", CALL_PATH);
    if (content_length) |declared| try encoder.writeHeader("content-length", declared);

    return encoder.encoded();
}

/// Start an established gRPC session: handshake, preface, server SETTINGS drained.
fn startGrpc(
    session: *TestSession,
    comptime RouterType: type,
    ctx: *const tlz.Context,
    opts: ServeOpts,
) !void {
    try startSession(session, RouterType, ctx, opts, &.{.H2});
    errdefer session.deinit();

    try std.testing.expect(session.readable(RouterType));
    try std.testing.expect(session.conn.mux != null);
    try std.testing.expect(setNonBlock(session.client_fd));

    try session.sendPreface();
    try std.testing.expect(session.readable(RouterType));
    _ = session.tally();
}

test "zix http2 grpc: tls_mux, answers one unary call sealed" {
    var ctx = try testContext();
    defer ctx.deinit();

    var session: TestSession = undefined;
    try startGrpc(&session, ok_router, &ctx, .{
        .max_streams = 16,
    });
    defer session.deinit();

    var block: [128]u8 = undefined;
    const head = try encodeHead(&block, null);
    const empty_message = [_]u8{ 0, 0, 0, 0, 0 };
    try session.sendFrame(frame.FRAME_TYPE_HEADERS, frame.FLAG_END_HEADERS, 1, head);
    try session.sendFrame(frame.FRAME_TYPE_DATA, frame.FLAG_END_STREAM, 1, &empty_message);

    try std.testing.expect(session.readable(ok_router));

    const result = session.tally();

    try std.testing.expectEqual(@as(usize, 1), result.trailers);
    try std.testing.expect(writer.write_hook == null);
}

test "zix http2 grpc: tls_mux, a handshake without ALPN h2 closes" {
    var ctx = try testContext();
    defer ctx.deinit();

    var session: TestSession = undefined;
    try startSession(&session, ok_router, &ctx, .{}, &.{});
    defer session.deinit();

    try std.testing.expect(!session.readable(ok_router));
    try std.testing.expect(session.conn.mux == null);
}

test "zix http2 grpc: tls_mux, a body short of its content-length is reset" {
    var ctx = try testContext();
    defer ctx.deinit();

    var session: TestSession = undefined;
    try startGrpc(&session, ok_router, &ctx, .{
        .max_streams = 16,
    });
    defer session.deinit();

    var block: [128]u8 = undefined;
    const head = try encodeHead(&block, "100");
    try session.sendFrame(frame.FRAME_TYPE_HEADERS, frame.FLAG_END_HEADERS, 1, head);

    const short: [40]u8 = @splat(0);
    try session.sendFrame(frame.FRAME_TYPE_DATA, frame.FLAG_END_STREAM, 1, &short);

    _ = session.readable(ok_router);

    const result = session.tally();

    try std.testing.expectEqual(@as(usize, 1), result.rst_protocol_error);
    try std.testing.expectEqual(@as(usize, 0), result.trailers);
}

test "zix http2 grpc: tls_mux, a hangup mid-call gets GOAWAY" {
    var ctx = try testContext();
    defer ctx.deinit();

    var session: TestSession = undefined;
    try startGrpc(&session, ok_router, &ctx, .{
        .max_streams = 16,
    });
    defer session.deinit();

    var block: [128]u8 = undefined;
    const head = try encodeHead(&block, null);
    try session.sendFrame(frame.FRAME_TYPE_HEADERS, frame.FLAG_END_HEADERS, 1, head);

    _ = session.readable(ok_router);
    _ = session.tally();

    try std.testing.expect(session.conn.mux.?.requestInFlight());
    _ = hangupGoaway(session.conn);

    const result = session.tally();

    try std.testing.expectEqual(@as(usize, 1), result.goaway_protocol_error);
    try std.testing.expect(session.conn.transport.wclose);
}

test "zix http2 grpc: tls_mux, an idle hangup answers nothing" {
    var ctx = try testContext();
    defer ctx.deinit();

    var session: TestSession = undefined;
    try startGrpc(&session, ok_router, &ctx, .{
        .max_streams = 16,
    });
    defer session.deinit();

    try std.testing.expect(!hangupGoaway(session.conn));

    const result = session.tally();

    try std.testing.expectEqual(@as(usize, 0), result.goaway_protocol_error);
    try std.testing.expect(!session.conn.transport.wclose);
}

test "zix http2 grpc: tls_mux, a message over several TLS records reaches the handler" {
    var ctx = try testContext();
    defer ctx.deinit();

    var session: TestSession = undefined;
    try startGrpc(&session, body_router, &ctx, .{
        .max_streams = 16,
        .max_body = 65536,
    });
    defer session.deinit();

    const chunk_len: usize = 13000;
    const chunks: usize = 3;
    const message_len = chunk_len * chunks - PREFIX_LEN;

    var block: [128]u8 = undefined;
    const head = try encodeHead(&block, null);
    try session.sendFrame(frame.FRAME_TYPE_HEADERS, frame.FLAG_END_HEADERS, 1, head);

    // Three DATA frames, one record each, all queued before the server reads.
    // The first one opens with the gRPC prefix of the whole message.
    var payload: [chunk_len]u8 = @splat('u');
    payload[0] = 0;
    std.mem.writeInt(u32, payload[1..5], @intCast(message_len), .big);
    for (0..chunks) |idx| {
        const flags: u8 = if (idx == chunks - 1) frame.FLAG_END_STREAM else 0;
        try session.sendFrame(frame.FRAME_TYPE_DATA, flags, 1, &payload);
        if (idx == 0) @memset(payload[0..PREFIX_LEN], 'u');
    }

    body_dispatches = 0;
    body_seen = 0;
    _ = session.readable(body_router);

    const result = session.tally();

    try std.testing.expectEqual(@as(usize, 1), body_dispatches);
    try std.testing.expectEqual(message_len, body_seen);
    try std.testing.expectEqual(@as(usize, 0), result.rst_protocol_error);
    try std.testing.expectEqual(@as(usize, 1), result.trailers);
}

test "zix http2 grpc: tls_mux, onEvent closes on HUP" {
    var ctx: tlz.Context = undefined;
    ctx.cert_der = &.{};
    ctx.signing_key = .{ .rsa = .{} };
    ctx.alpn = &.{};

    const conn = TlsConn.create(std.testing.io, 9, &ctx, .{}) orelse {
        return error.ZixTest_OutOfMemory;
    };
    defer conn.destroy();

    try std.testing.expect(!onEvent(ok_router, conn, -1, linux.EPOLL.HUP));
}

test "zix http2 grpc: tls_mux, hookWrite seals a write wider than one record" {
    var ctx = try testContext();
    defer ctx.deinit();

    var session: TestSession = undefined;
    try startGrpc(&session, ok_router, &ctx, .{});
    defer session.deinit();

    const wide: [tlz.MAX_PLAINTEXT + 100]u8 = @splat('w');
    hookWrite(session.conn, &wide);

    try std.testing.expectEqual(@as(usize, 100), session.conn.plain_len);

    flushPlain(session.conn);

    try std.testing.expectEqual(@as(usize, 0), session.conn.plain_len);
}

test "zix http2 grpc: tls_mux, workerCount honors an explicit count" {
    try std.testing.expectEqual(@as(usize, 3), workerCount(3));
}

test "zix http2 grpc: tls_mux, workerCount zero is at least 1" {
    try std.testing.expect(workerCount(0) >= 1);
}

