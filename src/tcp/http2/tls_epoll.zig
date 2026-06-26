//! zix http2 https serve path, multiplexed (h2 over TLS 1.3, RFC 8446 + 7540).
//!
//! What:
//! - One SO_REUSEPORT listener + epoll instance per worker, like the cleartext .EPOLL model, but each
//!   connection terminates TLS in place via a resumable tls_session.Session (no socketpair, no thread
//!   per connection). recv ciphertext -> session decrypts -> the resumable h2 mux (mux.zig) consumes
//!   plaintext -> the mux's reply frames are encrypted back into TLS records through the frame write
//!   hook -> sent. A worker multiplexes thousands of TLS connections, so high concurrency no longer
//!   spawns thousands of threads (the thread-per-conn TLS path thrashes there).
//! - Writes are non-blocking: on EAGAIN the unsent ciphertext is staged per connection and EPOLLOUT is
//!   armed, so a slow client never parks the worker.

const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;

const core = @import("core.zig");
const Route = core.Route;
const Http2ServerConfig = @import("config.zig").Http2ServerConfig;
const common = @import("dispatch/common.zig");
const mux = @import("mux.zig");
const frame = @import("frame.zig");
const session = @import("../tls/tls_session.zig");
const Tls = @import("../../tls/Tls.zig");
const record = @import("../../tls/record.zig");
const slab = @import("../../multiplexers/slab.zig");

const MAX_FD = common.MAX_FD;
const EPOLL_MAX_EVENTS: usize = 4096;

/// One sealed TLS record staging buffer: max record plaintext plus AEAD overhead.
const TLS_SEALED_RECORD_SIZE: usize = 18 * 1024;

/// Inbound ciphertext read staging (may hold several records per read).
const TLS_READ_STAGING_SIZE: usize = 32 * 1024;
const allocator = std.heap.smp_allocator;

/// One multiplexed TLS connection: the resumable TLS session, the h2 mux (allocated once the handshake
/// establishes), and the outbound-ciphertext backpressure buffer.
const TlsConn = struct {
    fd: posix.fd_t,
    tls: session.Session,
    h2: ?*mux.MuxConn = null,
    opts: core.ServeOpts,

    // Outbound ciphertext staged on EAGAIN: a heap buffer flushed on the next EPOLLOUT. wbuf is the
    // allocation (capacity), the live bytes are wbuf[woff..wlen]. Capacity and length are tracked
    // separately so a grown buffer never transmits its uninitialized tail.
    wbuf: []u8 = &.{},
    woff: usize = 0,
    wlen: usize = 0,
    wclose: bool = false,
    want_out: bool = false,

    // Plaintext the mux emitted this pass, accumulated then sealed in record-sized chunks.
    plain: [record.max_plaintext]u8 = undefined,
    plain_len: usize = 0,
};

/// Per-worker fd -> TlsConn map (shared-nothing, one worker owns a connection for its lifetime).
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
    if (c.h2) |h2| h2.deinit();
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

/// Try to send `bytes` now; stage whatever does not fit and mark the connection for EPOLLOUT. Returns
/// false on a fatal write error (the caller closes).
///
/// Note:
/// - TLS records must reach the peer in order (the AEAD nonce is the record sequence number). If
///   ciphertext is already staged, this MUST append rather than write directly, or a later record
///   would overtake the staged one on the wire and break decryption.
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

/// Append unsent ciphertext to the connection's pending buffer (grown as needed) for the next EPOLLOUT.
/// The live bytes are wbuf[woff..wlen]; capacity (wbuf.len) is never used as the data length, so a
/// grown buffer never flushes its uninitialized tail.
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

/// Seal the connection's accumulated plaintext into TLS records and send (staging on backpressure).
fn flushPlain(c: *TlsConn) void {
    if (c.plain_len == 0) return;

    var sealed: [TLS_SEALED_RECORD_SIZE]u8 = undefined;
    const ct = c.tls.encrypt(c.plain[0..c.plain_len], &sealed);
    c.plain_len = 0;
    if (!sendRaw(c, ct)) c.wclose = true;
}

/// The frame write hook: the mux writes plaintext h2 frames here; accumulate, sealing in record-sized
/// chunks. `ctx` is the *TlsConn the worker set before driving the mux.
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

/// Handle a readable TLS connection: decrypt available records, drive the handshake, then feed the
/// plaintext to the h2 mux and seal its reply. Returns false when the connection must close.
fn onReadable(comptime routes: []const Route, c: *TlsConn) bool {
    var cipher: [TLS_READ_STAGING_SIZE]u8 = undefined;
    var to_send: [TLS_SEALED_RECORD_SIZE]u8 = undefined;
    var plain_in: [TLS_SEALED_RECORD_SIZE]u8 = undefined;

    while (true) {
        const rc = linux.read(c.fd, &cipher, cipher.len);
        switch (posix.errno(rc)) {
            .SUCCESS => {
                if (rc == 0) return false; // peer closed
            },
            .INTR => continue,
            .AGAIN => return true, // drained
            else => return false,
        }

        const got = cipher[0..@intCast(rc)];
        const r = c.tls.feed(got, &to_send, &plain_in);

        if (r.to_send.len > 0 and !sendRaw(c, r.to_send)) return false;

        if (r.outcome == .established) {
            if (!c.tls.alpnIsH2()) return false;
            c.h2 = mux.MuxConn.init(c.fd, c.opts) orelse return false;
        }

        if (r.outcome == .close) {
            c.wclose = true;
            return c.want_out; // keep the conn only to flush a final alert
        }

        if (r.plaintext.len > 0) {
            const h2 = c.h2 orelse return false;
            if (!feedMux(routes, c, h2, r.plaintext)) return false;
        }
    }
}

/// Append decrypted plaintext to the mux read accumulator and drive one processing pass, sealing the
/// reply through the write hook. Returns false when the mux asks to close.
fn feedMux(comptime routes: []const Route, c: *TlsConn, h2: *mux.MuxConn, plaintext: []const u8) bool {
    // Compact, then append (a record is <= 16 KiB, the mux rbuf is >= 32 KiB).
    if (h2.rstart == h2.rend) {
        h2.rstart = 0;
        h2.rend = 0;
    } else if (h2.rend == h2.rbuf.len) {
        const keep = h2.rend - h2.rstart;
        std.mem.copyForwards(u8, h2.rbuf[0..keep], h2.rbuf[h2.rstart..h2.rend]);
        h2.rstart = 0;
        h2.rend = keep;
    }

    if (plaintext.len > h2.rbuf.len - h2.rend) return false;
    @memcpy(h2.rbuf[h2.rend..][0..plaintext.len], plaintext);
    h2.rend += plaintext.len;

    frame.write_hook = hookWrite;
    frame.write_hook_ctx = c;
    const outcome = mux.processRing(routes, h2);
    flushPlain(c);
    frame.write_hook = null;
    frame.write_hook_ctx = null;

    return outcome != .close;
}

/// Flush staged outbound ciphertext on an EPOLLOUT. Returns false when the connection must close.
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

    // Drained. Keep the buffer for reuse instead of freeing: under sustained backpressure (large
    // bodies, small MTU) the stage/drain cycle repeats constantly, and a free here plus a realloc on
    // the next stageWrite churns the shared allocator on the hot path. freeConn releases it at close.
    c.woff = 0;
    c.wlen = 0;
    c.want_out = false;
    armOut(epfd, c.fd, false);

    return !c.wclose;
}

fn acceptAll(table: *ConnTable, epfd: posix.fd_t, listener_fd: posix.fd_t, ctx: *const Tls.Context, opts: core.ServeOpts) void {
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
    opts: core.ServeOpts,
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

/// Listen and serve h2 over TLS, multiplexed across one epoll worker per core.
pub fn runTlsEpoll(comptime routes: []const Route, config: Http2ServerConfig) !void {
    const ctx = config.tls.?;
    const cpu = try std.Thread.getCpuCount();
    const worker_count = if (config.pool_size == 0) cpu else config.pool_size;
    const opts = common.serveOpts(config);

    common.logSystem(config, "listening on {s}:{d} (h2 TLS, epoll-mux/{d})", .{ config.ip, config.port, worker_count });

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
