//! zix grpc https serve path, multiplexed (gRPC over TLS 1.3, RFC 8446 + 7540).
//!
//! What:
//! - The gRPC twin of ../tls_mux.zig: one SO_REUSEPORT listener + epoll instance per worker, each
//!   connection terminating TLS in place via a resumable tls_session.Session (no socketpair, no thread
//!   per connection). recv ciphertext -> session decrypts -> the resumable gRPC h2 mux
//!   (grpcMuxProcessRing) consumes plaintext -> its staged reply is encrypted back into TLS records
//!   through the frame write hook -> sent. A worker multiplexes thousands of TLS connections, so high
//!   concurrency no longer spawns a thread per connection (the thread-per-conn TLS path thrashes).

const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;

const core = @import("core.zig");
const Route = core.Route;
const GrpcServerConfig = @import("config.zig").GrpcServerConfig;
const common = @import("dispatch/common.zig");
const frame = @import("../frame.zig");
const session = @import("../../tls/tls_session.zig");
const Tls = @import("../../../tls/Tls.zig");
const record = @import("../../../tls/record.zig");
const slab = @import("../../../multiplexers/slab.zig");

const MAX_FD = common.MAX_FD;
const EPOLL_MAX_EVENTS: usize = 4096;

/// One sealed TLS record staging buffer: max record plaintext plus AEAD overhead.
const TLS_SEALED_RECORD_SIZE: usize = 18 * 1024;

/// Inbound ciphertext read staging (may hold several records per read).
const TLS_READ_STAGING_SIZE: usize = 32 * 1024;

const allocator = std.heap.smp_allocator;

const TlsConn = struct {
    fd: posix.fd_t,
    tls: session.Session,
    grpc: ?*core.GrpcMuxConn = null,
    opts: core.GrpcServeOpts,

    // Outbound ciphertext staged on EAGAIN. wbuf is the allocation (capacity), the live bytes are
    // wbuf[woff..wlen]. Length is tracked apart from capacity so a grown buffer never flushes its
    // uninitialized tail.
    wbuf: []u8 = &.{},
    woff: usize = 0,
    wlen: usize = 0,
    wclose: bool = false,
    want_out: bool = false,

    plain: [record.max_plaintext]u8 = undefined,
    plain_len: usize = 0,
};

const ConnTable = struct {
    slots: []?*TlsConn,

    fn init() !ConnTable {
        return .{ .slots = try slab.mapZeroedSlots(?*TlsConn, MAX_FD) };
    }

    fn deinit(self: *ConnTable) void {
        for (self.slots) |maybe| {
            if (maybe) |conn| freeConn(conn);
        }
        slab.unmapSlots(self.slots);
    }

    fn get(self: *ConnTable, fd: posix.fd_t) ?*TlsConn {
        const idx: usize = @intCast(fd);
        if (idx >= self.slots.len) return null;

        return self.slots[idx];
    }

    fn put(self: *ConnTable, conn: *TlsConn) void {
        self.slots[@intCast(conn.fd)] = conn;
    }

    fn drop(self: *ConnTable, fd: posix.fd_t) void {
        const idx: usize = @intCast(fd);
        if (idx >= self.slots.len) return;
        if (self.slots[idx]) |conn| freeConn(conn);
        self.slots[idx] = null;
    }
};

fn freeConn(conn: *TlsConn) void {
    if (conn.grpc) |grpc_conn| grpc_conn.deinit();
    if (conn.wbuf.len > 0) allocator.free(conn.wbuf);
    allocator.destroy(conn);
}

fn setNonBlock(fd: posix.fd_t) void {
    const cur = linux.fcntl(fd, posix.F.GETFL, 0);
    const nb: u32 = @bitCast(posix.O{ .NONBLOCK = true });
    _ = linux.fcntl(fd, posix.F.SETFL, cur | @as(usize, nb));
}

fn armOut(epfd: posix.fd_t, fd: posix.fd_t, on: bool) void {
    var flags: u32 = linux.EPOLL.IN | linux.EPOLL.RDHUP;
    if (on) flags |= linux.EPOLL.OUT;

    var ev = linux.epoll_event{ .events = flags, .data = .{ .fd = fd } };
    _ = linux.epoll_ctl(epfd, linux.EPOLL.CTL_MOD, fd, &ev);
}

/// TLS records must reach the peer in order (the AEAD nonce is the record sequence number). If
/// ciphertext is already staged, append rather than write directly, or a later record would overtake
/// the staged one on the wire and break decryption.
fn sendRaw(conn: *TlsConn, bytes: []const u8) bool {
    if (conn.wlen > conn.woff) {
        stageWrite(conn, bytes);
        return true;
    }

    var off: usize = 0;
    while (off < bytes.len) {
        const rc = linux.write(conn.fd, bytes[off..].ptr, bytes.len - off);
        switch (posix.errno(rc)) {
            .SUCCESS => {
                if (rc == 0) return false;
                off += @intCast(rc);
            },
            .INTR => continue,
            .AGAIN => {
                stageWrite(conn, bytes[off..]);
                return true;
            },
            else => return false,
        }
    }

    return true;
}

fn stageWrite(conn: *TlsConn, bytes: []const u8) void {
    const pending = conn.wlen - conn.woff;

    // Room already at the tail: append in place.
    if (conn.wbuf.len - conn.wlen >= bytes.len) {
        @memcpy(conn.wbuf[conn.wlen..][0..bytes.len], bytes);
        conn.wlen += bytes.len;
        conn.want_out = true;
        return;
    }

    const need = pending + bytes.len;

    // Compaction alone makes room: slide the live bytes to the front.
    if (conn.wbuf.len >= need) {
        std.mem.copyForwards(u8, conn.wbuf[0..pending], conn.wbuf[conn.woff..conn.wlen]);
        conn.woff = 0;
        conn.wlen = pending;

        @memcpy(conn.wbuf[conn.wlen..][0..bytes.len], bytes);
        conn.wlen += bytes.len;
        conn.want_out = true;
        return;
    }

    // Grow: allocate a larger buffer and move the live bytes to its front.
    var new_cap: usize = if (conn.wbuf.len == 0) conn.opts.tls_write_buf_initial else conn.wbuf.len * 2;
    while (new_cap < need) new_cap *= 2;

    const grown = allocator.alloc(u8, new_cap) catch {
        conn.wclose = true;
        return;
    };
    @memcpy(grown[0..pending], conn.wbuf[conn.woff..conn.wlen]);
    if (conn.wbuf.len > 0) allocator.free(conn.wbuf);
    conn.wbuf = grown;
    conn.woff = 0;
    conn.wlen = pending;

    @memcpy(conn.wbuf[conn.wlen..][0..bytes.len], bytes);
    conn.wlen += bytes.len;
    conn.want_out = true;
}

fn flushPlain(conn: *TlsConn) void {
    if (conn.plain_len == 0) return;

    var sealed: [TLS_SEALED_RECORD_SIZE]u8 = undefined;
    const ct = conn.tls.encrypt(conn.plain[0..conn.plain_len], &sealed);
    conn.plain_len = 0;
    if (!sendRaw(conn, ct)) conn.wclose = true;
}

fn hookWrite(ctx: *anyopaque, bytes: []const u8) void {
    const conn: *TlsConn = @ptrCast(@alignCast(ctx));
    var rest = bytes;
    while (rest.len > 0) {
        if (conn.plain_len == conn.plain.len) flushPlain(conn);

        const n = @min(rest.len, conn.plain.len - conn.plain_len);
        @memcpy(conn.plain[conn.plain_len..][0..n], rest[0..n]);
        conn.plain_len += n;
        rest = rest[n..];
    }
}

fn onReadable(comptime routes: []const Route, conn: *TlsConn) bool {
    var cipher: [TLS_READ_STAGING_SIZE]u8 = undefined;
    var to_send: [TLS_SEALED_RECORD_SIZE]u8 = undefined;
    var plain_in: [TLS_SEALED_RECORD_SIZE]u8 = undefined;

    while (true) {
        const rc = linux.read(conn.fd, &cipher, cipher.len);
        switch (posix.errno(rc)) {
            .SUCCESS => {
                if (rc == 0) return false;
            },
            .INTR => continue,
            .AGAIN => return true,
            else => return false,
        }

        const got = cipher[0..@intCast(rc)];
        const r = conn.tls.feed(got, &to_send, &plain_in);

        if (r.to_send.len > 0 and !sendRaw(conn, r.to_send)) return false;

        if (r.outcome == .established) {
            if (!conn.tls.alpnIsH2()) return false;
            conn.grpc = core.GrpcMuxConn.init(conn.fd, conn.opts) orelse return false;
        }

        if (r.outcome == .close) {
            conn.wclose = true;
            return conn.want_out;
        }

        if (r.plaintext.len > 0) {
            const grpc_conn = conn.grpc orelse return false;
            if (!feedMux(routes, conn, grpc_conn, r.plaintext)) return false;
        }
    }
}

fn feedMux(comptime routes: []const Route, conn: *TlsConn, grpc_conn: *core.GrpcMuxConn, plaintext: []const u8) bool {
    if (grpc_conn.rstart == grpc_conn.rend) {
        grpc_conn.rstart = 0;
        grpc_conn.rend = 0;
    } else if (grpc_conn.rend == grpc_conn.rbuf.len) {
        const keep = grpc_conn.rend - grpc_conn.rstart;
        std.mem.copyForwards(u8, grpc_conn.rbuf[0..keep], grpc_conn.rbuf[grpc_conn.rstart..grpc_conn.rend]);
        grpc_conn.rstart = 0;
        grpc_conn.rend = keep;
    }

    if (plaintext.len > grpc_conn.rbuf.len - grpc_conn.rend) return false;
    @memcpy(grpc_conn.rbuf[grpc_conn.rend..][0..plaintext.len], plaintext);
    grpc_conn.rend += plaintext.len;

    frame.write_hook = hookWrite;
    frame.write_hook_ctx = conn;
    const outcome = core.grpcMuxProcessRing(routes, grpc_conn);
    grpc_conn.flushStage(); // staged reply -> frame.writeAllFD -> hook -> encrypt
    flushPlain(conn);
    frame.write_hook = null;
    frame.write_hook_ctx = null;

    return outcome != .close;
}

fn onWritable(epfd: posix.fd_t, conn: *TlsConn) bool {
    while (conn.woff < conn.wlen) {
        const rc = linux.write(conn.fd, conn.wbuf[conn.woff..].ptr, conn.wlen - conn.woff);
        switch (posix.errno(rc)) {
            .SUCCESS => {
                if (rc == 0) return false;
                conn.woff += @intCast(rc);
            },
            .INTR => continue,
            .AGAIN => return true,
            else => return false,
        }
    }

    // Drained. Keep the buffer for reuse (freeConn releases it at close) rather than free-here +
    // realloc-next-stage, which churns the shared allocator on the hot path under backpressure.
    conn.woff = 0;
    conn.wlen = 0;
    conn.want_out = false;
    armOut(epfd, conn.fd, false);

    return !conn.wclose;
}

fn acceptAll(table: *ConnTable, epfd: posix.fd_t, listener_fd: posix.fd_t, ctx: *const Tls.Context, opts: core.GrpcServeOpts) void {
    while (true) {
        const rc = linux.accept4(listener_fd, null, null, posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC);
        switch (posix.errno(rc)) {
            .SUCCESS => {},
            .AGAIN => return,
            .INTR, .CONNABORTED => continue,
            else => return,
        }

        const fd: posix.fd_t = @intCast(rc);
        common.setNoDelay(fd);

        const idx: usize = @intCast(fd);
        if (idx >= table.slots.len) {
            _ = linux.close(fd);
            continue;
        }

        const conn = allocator.create(TlsConn) catch {
            _ = linux.close(fd);
            continue;
        };
        conn.* = .{ .fd = fd, .tls = session.Session.init(ctx.cert_der, ctx.signing_key, ctx.alpn), .opts = opts };
        table.put(conn);

        var ev = linux.epoll_event{ .events = linux.EPOLL.IN | linux.EPOLL.RDHUP, .data = .{ .fd = fd } };
        if (posix.errno(linux.epoll_ctl(epfd, linux.EPOLL.CTL_ADD, fd, &ev)) != .SUCCESS) {
            table.drop(fd);
            _ = linux.close(fd);
        }
    }
}

const WorkerCtx = struct {
    io: std.Io,
    ip: []const u8,
    port: u16,
    kernel_backlog: u31,
    ctx: *const Tls.Context,
    opts: core.GrpcServeOpts,
    worker_id: usize,
};

fn workerFn(comptime routes: []const Route) fn (WorkerCtx) void {
    return struct {
        fn run(worker: WorkerCtx) void {
            // Pin to the worker's CPU slot (cgroup-mask aware) so a pinned cpuset does not
            // oversubscribe one core under a handshake storm (mirrors http1's tls_mux).
            common.pinToCpu(worker.worker_id);

            const addr = std.Io.net.IpAddress.resolve(worker.io, worker.ip, worker.port) catch return;
            var srv = addr.listen(worker.io, .{ .reuse_address = true, .kernel_backlog = worker.kernel_backlog }) catch return;
            defer srv.deinit(worker.io);
            const listener_fd = srv.socket.handle;
            setNonBlock(listener_fd);

            const epfd_rc = linux.epoll_create1(linux.EPOLL.CLOEXEC);
            if (posix.errno(epfd_rc) != .SUCCESS) return;
            const epfd: posix.fd_t = @intCast(epfd_rc);
            defer _ = linux.close(epfd);

            var lev = linux.epoll_event{ .events = linux.EPOLL.IN, .data = .{ .fd = listener_fd } };
            if (posix.errno(linux.epoll_ctl(epfd, linux.EPOLL.CTL_ADD, listener_fd, &lev)) != .SUCCESS) return;

            var table = ConnTable.init() catch return;
            defer table.deinit();

            var events: [EPOLL_MAX_EVENTS]linux.epoll_event = undefined;
            while (true) {
                const wait_rc = linux.epoll_wait(epfd, &events, EPOLL_MAX_EVENTS, -1);
                switch (posix.errno(wait_rc)) {
                    .SUCCESS => {},
                    .INTR => continue,
                    else => return,
                }

                for (events[0..@intCast(wait_rc)]) |ev| {
                    if (ev.data.fd == listener_fd) {
                        acceptAll(&table, epfd, listener_fd, worker.ctx, worker.opts);
                        continue;
                    }

                    const conn = table.get(ev.data.fd) orelse continue;
                    var keep = true;

                    if ((ev.events & (linux.EPOLL.HUP | linux.EPOLL.ERR)) != 0) {
                        keep = false;
                    } else {
                        if ((ev.events & linux.EPOLL.OUT) != 0) keep = onWritable(epfd, conn);
                        if (keep and (ev.events & linux.EPOLL.IN) != 0) keep = onReadable(routes, conn);
                        if (keep and conn.want_out) armOut(epfd, conn.fd, true);
                        if (keep and conn.wclose and !conn.want_out) keep = false;
                    }

                    if (!keep) {
                        _ = linux.epoll_ctl(epfd, linux.EPOLL.CTL_DEL, ev.data.fd, null);
                        table.drop(ev.data.fd);
                        _ = linux.close(ev.data.fd);
                    }
                }
            }
        }
    }.run;
}

/// Listen and serve gRPC over TLS, multiplexed across one epoll worker per core.
pub fn runTlsMux(comptime routes: []const Route, config: GrpcServerConfig) !void {
    const ctx = config.tls.?;
    const cpu = common.getAvailableCpuCount();
    const worker_count = if (config.pool_size == 0) cpu else config.pool_size;
    const opts = common.serveOpts(config);

    common.logSystem(config, "listening on {s}:{d} (grpc TLS, epoll-mux/{d})", .{ config.ip, config.port, worker_count });

    const workers = try allocator.alloc(std.Thread, worker_count);
    defer allocator.free(workers);

    const wf = workerFn(routes);
    for (workers, 0..) |*t, i|
        t.* = try std.Thread.spawn(.{ .stack_size = config.worker_stack_size_bytes }, wf, .{WorkerCtx{
            .io = config.io,
            .ip = config.ip,
            .port = config.port,
            .kernel_backlog = config.kernel_backlog,
            .ctx = ctx,
            .opts = opts,
            .worker_id = i,
        }});

    for (workers) |t| t.join();
}
