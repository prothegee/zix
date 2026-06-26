//! zix grpc https serve path, multiplexed (gRPC over TLS 1.3, RFC 8446 + 7540).
//!
//! What:
//! - The gRPC twin of ../tls_epoll.zig: one SO_REUSEPORT listener + epoll instance per worker, each
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
            if (maybe) |c| freeConn(c);
        }
        slab.unmapSlots(self.slots);
    }

    fn get(self: *ConnTable, fd: posix.fd_t) ?*TlsConn {
        const idx: usize = @intCast(fd);
        if (idx >= self.slots.len) return null;

        return self.slots[idx];
    }

    fn put(self: *ConnTable, c: *TlsConn) void {
        self.slots[@intCast(c.fd)] = c;
    }

    fn drop(self: *ConnTable, fd: posix.fd_t) void {
        const idx: usize = @intCast(fd);
        if (idx >= self.slots.len) return;
        if (self.slots[idx]) |c| freeConn(c);
        self.slots[idx] = null;
    }
};

fn freeConn(c: *TlsConn) void {
    if (c.grpc) |g| g.deinit();
    if (c.wbuf.len > 0) allocator.free(c.wbuf);
    allocator.destroy(c);
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
fn sendRaw(c: *TlsConn, bytes: []const u8) bool {
    if (c.wlen > c.woff) {
        stageWrite(c, bytes);
        return true;
    }

    var off: usize = 0;
    while (off < bytes.len) {
        const rc = linux.write(c.fd, bytes[off..].ptr, bytes.len - off);
        switch (posix.errno(rc)) {
            .SUCCESS => {
                if (rc == 0) return false;
                off += @intCast(rc);
            },
            .INTR => continue,
            .AGAIN => {
                stageWrite(c, bytes[off..]);
                return true;
            },
            else => return false,
        }
    }

    return true;
}

fn stageWrite(c: *TlsConn, bytes: []const u8) void {
    const pending = c.wlen - c.woff;

    // Room already at the tail: append in place.
    if (c.wbuf.len - c.wlen >= bytes.len) {
        @memcpy(c.wbuf[c.wlen..][0..bytes.len], bytes);
        c.wlen += bytes.len;
        c.want_out = true;
        return;
    }

    const need = pending + bytes.len;

    // Compaction alone makes room: slide the live bytes to the front.
    if (c.wbuf.len >= need) {
        std.mem.copyForwards(u8, c.wbuf[0..pending], c.wbuf[c.woff..c.wlen]);
        c.woff = 0;
        c.wlen = pending;

        @memcpy(c.wbuf[c.wlen..][0..bytes.len], bytes);
        c.wlen += bytes.len;
        c.want_out = true;
        return;
    }

    // Grow: allocate a larger buffer and move the live bytes to its front.
    var new_cap: usize = if (c.wbuf.len == 0) 16 * 1024 else c.wbuf.len * 2;
    while (new_cap < need) new_cap *= 2;

    const grown = allocator.alloc(u8, new_cap) catch {
        c.wclose = true;
        return;
    };
    @memcpy(grown[0..pending], c.wbuf[c.woff..c.wlen]);
    if (c.wbuf.len > 0) allocator.free(c.wbuf);
    c.wbuf = grown;
    c.woff = 0;
    c.wlen = pending;

    @memcpy(c.wbuf[c.wlen..][0..bytes.len], bytes);
    c.wlen += bytes.len;
    c.want_out = true;
}

fn flushPlain(c: *TlsConn) void {
    if (c.plain_len == 0) return;

    var sealed: [TLS_SEALED_RECORD_SIZE]u8 = undefined;
    const ct = c.tls.encrypt(c.plain[0..c.plain_len], &sealed);
    c.plain_len = 0;
    if (!sendRaw(c, ct)) c.wclose = true;
}

fn hookWrite(ctx: *anyopaque, bytes: []const u8) void {
    const c: *TlsConn = @ptrCast(@alignCast(ctx));
    var rest = bytes;
    while (rest.len > 0) {
        if (c.plain_len == c.plain.len) flushPlain(c);

        const n = @min(rest.len, c.plain.len - c.plain_len);
        @memcpy(c.plain[c.plain_len..][0..n], rest[0..n]);
        c.plain_len += n;
        rest = rest[n..];
    }
}

fn onReadable(comptime routes: []const Route, c: *TlsConn) bool {
    var cipher: [TLS_READ_STAGING_SIZE]u8 = undefined;
    var to_send: [TLS_SEALED_RECORD_SIZE]u8 = undefined;
    var plain_in: [TLS_SEALED_RECORD_SIZE]u8 = undefined;

    while (true) {
        const rc = linux.read(c.fd, &cipher, cipher.len);
        switch (posix.errno(rc)) {
            .SUCCESS => {
                if (rc == 0) return false;
            },
            .INTR => continue,
            .AGAIN => return true,
            else => return false,
        }

        const got = cipher[0..@intCast(rc)];
        const r = c.tls.feed(got, &to_send, &plain_in);

        if (r.to_send.len > 0 and !sendRaw(c, r.to_send)) return false;

        if (r.outcome == .established) {
            if (!c.tls.alpnIsH2()) return false;
            c.grpc = core.GrpcMuxConn.init(c.fd, c.opts) orelse return false;
        }

        if (r.outcome == .close) {
            c.wclose = true;
            return c.want_out;
        }

        if (r.plaintext.len > 0) {
            const g = c.grpc orelse return false;
            if (!feedMux(routes, c, g, r.plaintext)) return false;
        }
    }
}

fn feedMux(comptime routes: []const Route, c: *TlsConn, g: *core.GrpcMuxConn, plaintext: []const u8) bool {
    if (g.rstart == g.rend) {
        g.rstart = 0;
        g.rend = 0;
    } else if (g.rend == g.rbuf.len) {
        const keep = g.rend - g.rstart;
        std.mem.copyForwards(u8, g.rbuf[0..keep], g.rbuf[g.rstart..g.rend]);
        g.rstart = 0;
        g.rend = keep;
    }

    if (plaintext.len > g.rbuf.len - g.rend) return false;
    @memcpy(g.rbuf[g.rend..][0..plaintext.len], plaintext);
    g.rend += plaintext.len;

    frame.write_hook = hookWrite;
    frame.write_hook_ctx = c;
    const outcome = core.grpcMuxProcessRing(routes, g);
    g.flushStage(); // staged reply -> frame.fdWriteAll -> hook -> encrypt
    flushPlain(c);
    frame.write_hook = null;
    frame.write_hook_ctx = null;

    return outcome != .close;
}

fn onWritable(epfd: posix.fd_t, c: *TlsConn) bool {
    while (c.woff < c.wlen) {
        const rc = linux.write(c.fd, c.wbuf[c.woff..].ptr, c.wlen - c.woff);
        switch (posix.errno(rc)) {
            .SUCCESS => {
                if (rc == 0) return false;
                c.woff += @intCast(rc);
            },
            .INTR => continue,
            .AGAIN => return true,
            else => return false,
        }
    }

    // Drained. Keep the buffer for reuse (freeConn releases it at close) rather than free-here +
    // realloc-next-stage, which churns the shared allocator on the hot path under backpressure.
    c.woff = 0;
    c.wlen = 0;
    c.want_out = false;
    armOut(epfd, c.fd, false);

    return !c.wclose;
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

        const c = allocator.create(TlsConn) catch {
            _ = linux.close(fd);
            continue;
        };
        c.* = .{ .fd = fd, .tls = session.Session.init(ctx.cert_der, ctx.signing_key, ctx.alpn), .opts = opts };
        table.put(c);

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
};

fn workerFn(comptime routes: []const Route) fn (WorkerCtx) void {
    return struct {
        fn run(w: WorkerCtx) void {
            const addr = std.Io.net.IpAddress.resolve(w.io, w.ip, w.port) catch return;
            var srv = addr.listen(w.io, .{ .reuse_address = true, .kernel_backlog = w.kernel_backlog }) catch return;
            defer srv.deinit(w.io);
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
                        acceptAll(&table, epfd, listener_fd, w.ctx, w.opts);
                        continue;
                    }

                    const c = table.get(ev.data.fd) orelse continue;
                    var keep = true;

                    if ((ev.events & (linux.EPOLL.HUP | linux.EPOLL.ERR)) != 0) {
                        keep = false;
                    } else {
                        if ((ev.events & linux.EPOLL.OUT) != 0) keep = onWritable(epfd, c);
                        if (keep and (ev.events & linux.EPOLL.IN) != 0) keep = onReadable(routes, c);
                        if (keep and c.want_out) armOut(epfd, c.fd, true);
                        if (keep and c.wclose and !c.want_out) keep = false;
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
pub fn runTlsEpoll(comptime routes: []const Route, config: GrpcServerConfig) !void {
    const ctx = config.tls.?;
    const cpu = try std.Thread.getCpuCount();
    const worker_count = if (config.pool_size == 0) cpu else config.pool_size;
    const opts = common.serveOpts(config);

    common.logSystem(config, "listening on {s}:{d} (grpc TLS, epoll-mux/{d})", .{ config.ip, config.port, worker_count });

    const workers = try allocator.alloc(std.Thread, worker_count);
    defer allocator.free(workers);

    const wf = workerFn(routes);
    for (workers) |*t|
        t.* = try std.Thread.spawn(.{ .stack_size = 512 * 1024 }, wf, .{WorkerCtx{
            .io = config.io,
            .ip = config.ip,
            .port = config.port,
            .kernel_backlog = config.kernel_backlog,
            .ctx = ctx,
            .opts = opts,
        }});

    for (workers) |t| t.join();
}
