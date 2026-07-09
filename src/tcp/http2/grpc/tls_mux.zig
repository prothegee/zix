//! zix grpc https serve path, multiplexed (gRPC over TLS 1.3, RFC 8446 + 7540).
//!
//! What:
//! - The gRPC twin of ../tls_mux.zig: one SO_REUSEPORT listener + epoll instance per worker, each
//!   connection terminating TLS in place via the shared transport (multiplexers/tls_conn.zig), no
//!   socketpair, no thread per connection. recv ciphertext -> transport decrypts -> the resumable gRPC
//!   h2 mux (grpcMuxProcessRing) consumes plaintext -> its staged reply is encrypted back into TLS
//!   records through the frame write hook -> sent. A worker multiplexes thousands of TLS connections,
//!   so high concurrency no longer spawns a thread per connection (the thread-per-conn TLS path
//!   thrashes).

const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;

const core = @import("core.zig");
const Route = core.Route;
const GrpcServerConfig = @import("config.zig").GrpcServerConfig;
const common = @import("dispatch/common.zig");
const frame = @import("../frame.zig");
const Tls = @import("../../../tls/Tls.zig");
const record = @import("../../../tls/record.zig");
const tls_conn = @import("../../../multiplexers/tls_conn.zig");

const MAX_FD = common.MAX_FD;
const EPOLL_MAX_EVENTS: usize = 4096;

/// One sealed TLS record staging buffer: max record plaintext plus AEAD overhead.
const TLS_SEALED_RECORD_SIZE: usize = 18 * 1024;

/// Inbound ciphertext read staging (may hold several records per read).
const TLS_READ_STAGING_SIZE: usize = tls_conn.read_staging_size;

const allocator = std.heap.smp_allocator;

/// One multiplexed TLS connection: the shared byte transport (session + outbound backpressure
/// buffer), the gRPC h2 mux (allocated once the handshake establishes), and the plaintext record
/// accumulator.
/// One multiplexed TLS connection. Pub with ConnTable / onCiphertext / acceptAll: the
/// dual-listener loops (dispatch/epoll.zig, dispatch/uring.zig, config.tls_port) host the same
/// connections in the cleartext worker instead of a second fleet.
pub const TlsConn = struct {
    transport: tls_conn.Transport,
    grpc: ?*core.GrpcMuxConn = null,
    opts: core.GrpcServeOpts,

    // Plaintext the mux emitted this pass, accumulated then sealed in record-sized chunks.
    plain: [record.max_plaintext]u8 = undefined,
    plain_len: usize = 0,
};

/// Per-worker fd -> TlsConn map (shared-nothing, one worker owns a connection for its lifetime).
pub const ConnTable = tls_conn.ConnTable(TlsConn, MAX_FD, freeConn);

fn freeConn(conn: *TlsConn) void {
    if (conn.grpc) |grpc_conn| grpc_conn.deinit();
    conn.transport.deinit();
    allocator.destroy(conn);
}

/// Seal the connection's accumulated plaintext into TLS records and send (staging on backpressure).
fn flushPlain(conn: *TlsConn) void {
    if (conn.plain_len == 0) return;

    var sealed: [TLS_SEALED_RECORD_SIZE]u8 = undefined;
    const plain_len = conn.plain_len;
    conn.plain_len = 0;
    if (!conn.transport.sendPlain(conn.plain[0..plain_len], &sealed)) conn.transport.wclose = true;
}

/// The frame write hook: the mux writes plaintext h2 frames here. The plaintext accumulates into
/// `plain` and seals in record-sized chunks. `ctx` is the *TlsConn the worker set before driving
/// the mux.
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

/// Handle a readable TLS connection: decrypt available records, drive the handshake, then feed the
/// plaintext to the gRPC h2 mux and seal its reply. Returns false when the connection must close.
pub fn onReadable(comptime routes: []const Route, conn: *TlsConn) bool {
    var cipher: [TLS_READ_STAGING_SIZE]u8 = undefined;

    while (true) {
        const rc = linux.read(conn.transport.fd, &cipher, cipher.len);
        switch (posix.errno(rc)) {
            .SUCCESS => {
                if (rc == 0) return false;
            },
            .INTR => continue,
            .AGAIN => return true,
            else => return false,
        }

        if (!onCiphertext(routes, conn, cipher[0..@intCast(rc)])) return false;
        if (conn.transport.wclose) return conn.transport.want_out; // flush, then close
    }
}

/// Feed one received ciphertext chunk through the session and the gRPC h2 mux. The
/// recv-model-agnostic core of onReadable: the .EPOLL paths call it under their own read loop, the
/// .URING path calls it per recv completion. Returns false when the connection must close now.
/// transport.wclose set with staged bytes means flush, then close.
pub fn onCiphertext(comptime routes: []const Route, conn: *TlsConn, cipher: []const u8) bool {
    var to_send: [TLS_SEALED_RECORD_SIZE]u8 = undefined;
    var plain_in: [TLS_SEALED_RECORD_SIZE]u8 = undefined;

    const r = conn.transport.tls.feed(cipher, &to_send, &plain_in);

    if (r.to_send.len > 0 and !conn.transport.sendRaw(r.to_send)) return false;

    if (r.outcome == .established) {
        if (!conn.transport.tls.alpnIsH2()) return false;
        conn.grpc = core.GrpcMuxConn.init(conn.transport.fd, conn.opts) orelse return false;
    }

    if (r.outcome == .close) {
        conn.transport.wclose = true; // keep the conn only to flush a final alert
        return true;
    }

    if (r.plaintext.len > 0) {
        const grpc_conn = conn.grpc orelse return false;
        if (!feedMux(routes, conn, grpc_conn, r.plaintext)) return false;
    }

    return true;
}

/// Append decrypted plaintext to the mux read accumulator and drive one processing pass, sealing the
/// reply through the write hook. Returns false when the mux asks to close.
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

/// Accept every pending TLS connection on listener_fd and register each in epfd with
/// `ev_tag | fd` as the event data. The TLS-only worker passes 0 (plain fd), the dual-listener
/// .EPOLL loop passes tls_conn.tls_event_tag so its one loop can route TLS events.
pub fn acceptAll(table: *ConnTable, epfd: posix.fd_t, listener_fd: posix.fd_t, ctx: *const Tls.Context, opts: core.GrpcServeOpts, ev_tag: u64) void {
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
        conn.* = .{ .transport = tls_conn.Transport.init(fd, ctx), .opts = opts };
        conn.transport.wbuf_initial = opts.tls_write_buf_initial;
        conn.transport.ep_data = ev_tag | @as(u64, @intCast(fd));
        table.put(fd, conn);

        var ev = linux.epoll_event{ .events = linux.EPOLL.IN | linux.EPOLL.RDHUP, .data = .{ .u64 = conn.transport.ep_data } };
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
            common.setNonBlock(listener_fd);

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
                        acceptAll(&table, epfd, listener_fd, worker.ctx, worker.opts, 0);
                        continue;
                    }

                    const conn = table.get(ev.data.fd) orelse continue;
                    var keep = true;

                    if ((ev.events & (linux.EPOLL.HUP | linux.EPOLL.ERR)) != 0) {
                        keep = false;
                    } else {
                        if ((ev.events & linux.EPOLL.OUT) != 0) keep = conn.transport.onWritable(epfd);
                        if (keep and (ev.events & linux.EPOLL.IN) != 0) keep = onReadable(routes, conn);
                        if (keep and conn.transport.want_out) tls_conn.armOut(epfd, conn.transport.fd, conn.transport.ep_data, true);
                        if (keep and conn.transport.wclose and !conn.transport.want_out) keep = false;
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
