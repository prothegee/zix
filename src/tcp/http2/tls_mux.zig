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
    if (conn.h2) |h2| h2.deinit();
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

/// Try to send `bytes` now. Stage whatever does not fit and mark the connection for EPOLLOUT. Returns
/// false on a fatal write error (the caller closes).
///
/// Note:
/// - TLS records must reach the peer in order (the AEAD nonce is the record sequence number). If
///   ciphertext is already staged, this MUST append rather than write directly, or a later record
///   would overtake the staged one on the wire and break decryption.
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

/// Append unsent ciphertext to the connection's pending buffer (grown as needed) for the next EPOLLOUT.
/// The live bytes are wbuf[woff..wlen]. Capacity (wbuf.len) is never used as the data length, so a
/// grown buffer never flushes its uninitialized tail.
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

/// Seal the connection's accumulated plaintext into TLS records and send (staging on backpressure).
fn flushPlain(conn: *TlsConn) void {
    if (conn.plain_len == 0) return;

    var sealed: [TLS_SEALED_RECORD_SIZE]u8 = undefined;
    const ct = conn.tls.encrypt(conn.plain[0..conn.plain_len], &sealed);
    conn.plain_len = 0;
    if (!sendRaw(conn, ct)) conn.wclose = true;
}

/// Seal-in-place toggle. true: seal a full record straight from source via the gather encrypt, so a
/// large DATA payload is not copied into `plain` first. false: accumulate into `plain` and seal there
/// (the pre-seal-in-place path). Comptime, so the effect can be A/B'd against an otherwise identical
/// build without changing any other behavior.
const seal_in_place = true;

/// Seal one full record (the staged prefix gathered with a slice of the source) and send. Avoids
/// copying the source slice into `plain` first. prefix.len + tail.len == plain.len (a full record).
/// Ordering matches flushPlain: records leave in sequence order through sendRaw.
fn sealGather(conn: *TlsConn, prefix: []const u8, tail: []const u8) void {
    var sealed: [TLS_SEALED_RECORD_SIZE]u8 = undefined;
    const ct = conn.tls.encrypt2(prefix, tail, &sealed);
    if (!sendRaw(conn, ct)) conn.wclose = true;
}

/// The frame write hook: the mux writes plaintext h2 frames here. With seal_in_place a full record (the
/// staged prefix plus this write) is sealed straight from source, so a large DATA payload is not copied
/// into `plain` first, only the sub-record remainder is staged. Otherwise the plaintext accumulates
/// into `plain` and seals when it fills. `ctx` is the *TlsConn the worker set before driving the mux.
fn hookWrite(ctx: *anyopaque, bytes: []const u8) void {
    const conn: *TlsConn = @ptrCast(@alignCast(ctx));
    var rest = bytes;

    if (seal_in_place) {
        // Seal every full record that the staged prefix plus `rest` completes, gathering the staged
        // bytes with a slice of `rest` straight from source (no bulk copy of the payload into `plain`).
        while (conn.plain_len + rest.len >= conn.plain.len) {
            const take = conn.plain.len - conn.plain_len;
            sealGather(conn, conn.plain[0..conn.plain_len], rest[0..take]);
            conn.plain_len = 0;
            rest = rest[take..];
        }

        @memcpy(conn.plain[conn.plain_len..][0..rest.len], rest[0..rest.len]);
        conn.plain_len += rest.len;

        return;
    }

    // Accumulate-then-seal: stage into `plain`, flushing a full record when it fills.
    while (rest.len > 0) {
        if (conn.plain_len == conn.plain.len) flushPlain(conn);

        const n = @min(rest.len, conn.plain.len - conn.plain_len);
        @memcpy(conn.plain[conn.plain_len..][0..n], rest[0..n]);
        conn.plain_len += n;
        rest = rest[n..];
    }
}

/// Handle a readable TLS connection: decrypt available records, drive the handshake, then feed the
/// plaintext to the h2 mux and seal its reply. Returns false when the connection must close.
fn onReadable(comptime routes: []const Route, conn: *TlsConn) bool {
    var cipher: [TLS_READ_STAGING_SIZE]u8 = undefined;
    var to_send: [TLS_SEALED_RECORD_SIZE]u8 = undefined;
    var plain_in: [TLS_SEALED_RECORD_SIZE]u8 = undefined;

    while (true) {
        const rc = linux.read(conn.fd, &cipher, cipher.len);
        switch (posix.errno(rc)) {
            .SUCCESS => {
                if (rc == 0) return false; // peer closed
            },
            .INTR => continue,
            .AGAIN => return true, // drained
            else => return false,
        }

        const got = cipher[0..@intCast(rc)];
        const r = conn.tls.feed(got, &to_send, &plain_in);

        if (r.to_send.len > 0 and !sendRaw(conn, r.to_send)) return false;

        if (r.outcome == .established) {
            if (!conn.tls.alpnIsH2()) return false;
            conn.h2 = mux.MuxConn.init(conn.fd, conn.opts) orelse return false;
        }

        if (r.outcome == .close) {
            conn.wclose = true;
            return conn.want_out; // keep the conn only to flush a final alert
        }

        if (r.plaintext.len > 0) {
            const h2 = conn.h2 orelse return false;
            if (!feedMux(routes, conn, h2, r.plaintext)) return false;
        }
    }
}

/// Append decrypted plaintext to the mux read accumulator and drive one processing pass, sealing the
/// reply through the write hook. Returns false when the mux asks to close.
fn feedMux(comptime routes: []const Route, conn: *TlsConn, h2: *mux.MuxConn, plaintext: []const u8) bool {
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
    frame.write_hook_ctx = conn;
    const outcome = mux.processRing(routes, h2);
    flushPlain(conn);
    frame.write_hook = null;
    frame.write_hook_ctx = null;

    return outcome != .close;
}

/// Flush staged outbound ciphertext on an EPOLLOUT. Returns false when the connection must close.
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

    // Drained. Keep the buffer for reuse instead of freeing: under sustained backpressure (large
    // bodies, small MTU) the stage/drain cycle repeats constantly, and a free here plus a realloc on
    // the next stageWrite churns the shared allocator on the hot path. freeConn releases it at close.
    conn.woff = 0;
    conn.wlen = 0;
    conn.want_out = false;
    armOut(epfd, conn.fd, false);

    return !conn.wclose;
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
    opts: core.ServeOpts,
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

/// Listen and serve h2 over TLS, multiplexed across one epoll worker per core.
pub fn runTlsMux(comptime routes: []const Route, config: Http2ServerConfig) !void {
    const ctx = config.tls.?;
    const cpu = common.getAvailableCpuCount();
    const worker_count = if (config.pool_size == 0) cpu else config.pool_size;
    const opts = common.serveOpts(config);

    common.logSystem(config, "listening on {s}:{d} (h2 TLS, epoll-mux/{d})", .{ config.ip, config.port, worker_count });

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
