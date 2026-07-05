//! zix http https serve path, event-driven (https/1.1 over TLS 1.3, RFC 8446 + 9112).
//!
//! What:
//! - One SO_REUSEPORT listener + epoll instance per worker, like the cleartext .EPOLL model, but each
//!   connection terminates TLS in place via a resumable tls_session.Session (no thread per connection).
//!   recv ciphertext -> session decrypts -> plaintext feeds the request loop -> the router response is
//!   captured (the existing response sink, reused via tls_serve.processRequestToBuffer) -> encrypted
//!   back into TLS records -> sent. A worker multiplexes thousands of TLS connections.
//! - Keep-alive: a connection serves requests in a loop over the established session. Writes are
//!   non-blocking: on EAGAIN the unsent ciphertext is staged per connection and EPOLLOUT is armed.
//! - Cpuset-aware worker count + per-core pin (common.getAvailableCpuCount / common.pinToCpu), so a
//!   cgroup-pinned cpuset does not oversubscribe a core under a handshake storm (matches http1).
//! - Buffered responses only (SSE / streaming + WebSocket are out of scope, the same as tls_serve).

const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;

const Config = @import("config.zig").HttpServerConfig;
const common = @import("dispatch/common.zig");
const parser = @import("parser.zig");
const ws = @import("websocket.zig");
const tls_serve = @import("tls_serve.zig");
const session = @import("../tls/tls_session.zig");
const Tls = @import("../../tls/Tls.zig");
const slab = @import("../../multiplexers/slab.zig");

const MAX_FD = common.MAX_FD;
const EPOLL_MAX_EVENTS: usize = 4096;
const allocator = std.heap.smp_allocator;

const TLS_READ_STAGING_SIZE: usize = 32 * 1024;
const TLS_SEALED_OUT_SIZE: usize = 70 * 1024;
const TLS_PLAIN_STAGING_SIZE: usize = 32 * 1024;
const REQUEST_BUF_SIZE: usize = 17 * 1024;
const RESPONSE_BUF_SIZE: usize = 64 * 1024;
const tls_write_buf_initial: usize = 16 * 1024;

/// Listen and serve https/1.1 over TLS, multiplexed across one epoll worker per core. Generic over the
/// server type (the comptime-baked router), so the worker machinery is instantiated per server.
pub fn runTlsMux(server: anytype, io: std.Io) !void {
    return Worker(@TypeOf(server)).run(server, io);
}

fn Worker(comptime Server: type) type {
    return struct {
        /// One TLS connection: the resumable session, the request accumulator, the server pointer (for
        /// the router), and the outbound-ciphertext backpressure buffer.
        const TlsConn = struct {
            fd: posix.fd_t,
            tls: session.Session,
            server: Server,
            ctx: *const Tls.Context,

            rbuf: [REQUEST_BUF_SIZE]u8 = undefined,
            rlen: usize = 0,

            wbuf: []u8 = &.{},
            woff: usize = 0,
            wlen: usize = 0,
            wclose: bool = false,
            want_out: bool = false,
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
            if (conn.wbuf.len > 0) allocator.free(conn.wbuf);
            allocator.destroy(conn);
        }

        fn armOut(epfd: posix.fd_t, fd: posix.fd_t, on: bool) void {
            var flags: u32 = linux.EPOLL.IN | linux.EPOLL.RDHUP;
            if (on) flags |= linux.EPOLL.OUT;

            var ev = linux.epoll_event{ .events = flags, .data = .{ .fd = fd } };
            _ = linux.epoll_ctl(epfd, linux.EPOLL.CTL_MOD, fd, &ev);
        }

        /// Try to send `bytes` now, staging whatever does not fit. TLS records must reach the peer in
        /// order (the AEAD nonce is the record sequence), so if ciphertext is already staged this MUST
        /// append rather than write directly.
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

        /// Append unsent ciphertext to the connection's pending buffer (grown as needed) for the next
        /// EPOLLOUT. The live bytes are wbuf[woff..wlen]. Capacity is never used as the data length.
        fn stageWrite(conn: *TlsConn, bytes: []const u8) void {
            const pending = conn.wlen - conn.woff;

            if (conn.wbuf.len - conn.wlen >= bytes.len) {
                @memcpy(conn.wbuf[conn.wlen..][0..bytes.len], bytes);
                conn.wlen += bytes.len;
                conn.want_out = true;
                return;
            }

            const need = pending + bytes.len;

            if (conn.wbuf.len >= need) {
                std.mem.copyForwards(u8, conn.wbuf[0..pending], conn.wbuf[conn.woff..conn.wlen]);
                conn.woff = 0;
                conn.wlen = pending;

                @memcpy(conn.wbuf[conn.wlen..][0..bytes.len], bytes);
                conn.wlen += bytes.len;
                conn.want_out = true;
                return;
            }

            var new_cap: usize = if (conn.wbuf.len == 0) tls_write_buf_initial else conn.wbuf.len * 2;
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

        /// Encrypt response plaintext into TLS records and send (staging on backpressure).
        fn sendPlain(conn: *TlsConn, plaintext: []const u8) bool {
            var sealed: [TLS_SEALED_OUT_SIZE]u8 = undefined;
            const ct = conn.tls.encrypt(plaintext, &sealed);

            return sendRaw(conn, ct);
        }

        /// Handle a readable TLS connection: decrypt records, drive the handshake, feed plaintext to the
        /// request loop, seal replies. Returns false when the connection must close.
        fn onReadable(conn: *TlsConn, io: std.Io, arena: *std.heap.ArenaAllocator) bool {
            var cipher: [TLS_READ_STAGING_SIZE]u8 = undefined;
            var to_send: [TLS_SEALED_OUT_SIZE]u8 = undefined;
            var plain_in: [TLS_PLAIN_STAGING_SIZE]u8 = undefined;

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

                if (r.outcome == .close) {
                    conn.wclose = true;
                    return conn.want_out;
                }

                if (r.plaintext.len > 0) {
                    if (!feedRequests(conn, r.plaintext, io, arena)) return false;
                    if (conn.wclose) return conn.want_out;
                }
            }
        }

        /// Accumulate decrypted plaintext and dispatch every complete request now buffered (pipelined
        /// requests drain in one pass). Returns false on a fatal write, sets conn.wclose otherwise.
        fn feedRequests(conn: *TlsConn, plaintext: []const u8, io: std.Io, arena: *std.heap.ArenaAllocator) bool {
            const cfg = conn.server.config;

            if (plaintext.len > conn.rbuf.len - conn.rlen) {
                conn.wclose = true;
                return true;
            }

            @memcpy(conn.rbuf[conn.rlen..][0..plaintext.len], plaintext);
            conn.rlen += plaintext.len;

            var response_buf: [RESPONSE_BUF_SIZE]u8 = undefined;

            while (conn.rlen > 0) {
                const maybe_head = parser.parse(conn.rbuf[0..conn.rlen], cfg.max_request_headers.value()) catch {
                    conn.wclose = true;
                    return true;
                };
                const head = maybe_head orelse return true; // incomplete head: wait for more
                if (head.chunked) {
                    conn.wclose = true; // chunked bodies are out of scope for the TLS cut
                    return true;
                }
                const total = head.body_offset + head.content_length;
                if (conn.rlen < total) return true; // wait for the full body

                // RFC 9110 7.4: a request for an authority this cert does not serve is misdirected (421).
                if (tls_serve.hostFromHead(conn.rbuf[0..head.body_offset])) |host_raw| {
                    const host = tls_serve.stripPort(host_raw);
                    Tls.verifyCertIdentity(conn.ctx.cert_der, host) catch {
                        const misdirected = "HTTP/1.1 421 Misdirected Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
                        _ = sendPlain(conn, misdirected);
                        conn.wclose = true;
                        return true;
                    };
                }

                const cap = tls_serve.processRequestToBuffer(conn.server, io, conn.rbuf[0..total], &response_buf, arena) catch {
                    _ = ws.takeWebSocket(); // the multiplexed path does not host WS (ADR-055), drop any handoff
                    conn.wclose = true; // ResponseTooLarge / StreamingNotSupported: close
                    return true;
                };
                if (!sendPlain(conn, cap.bytes)) return false;

                const remaining = conn.rlen - total;
                if (remaining > 0) std.mem.copyForwards(u8, conn.rbuf[0..remaining], conn.rbuf[total..conn.rlen]);
                conn.rlen = remaining;

                if (cap.outcome == .close) {
                    var close_buf: [64]u8 = undefined;
                    _ = sendRaw(conn, conn.tls.closeNotify(&close_buf));
                    conn.wclose = true;
                    return true;
                }
            }

            return true;
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

            conn.woff = 0;
            conn.wlen = 0;
            conn.want_out = false;
            armOut(epfd, conn.fd, false);

            return !conn.wclose;
        }

        fn acceptAll(table: *ConnTable, epfd: posix.fd_t, listener_fd: posix.fd_t, server: Server, ctx: *const Tls.Context) void {
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
                conn.* = .{
                    .fd = fd,
                    .tls = session.Session.init(ctx.cert_der, ctx.signing_key, ctx.alpn),
                    .server = server,
                    .ctx = ctx,
                };
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
            max_allocator_size: usize,
            worker_id: usize,
            server: Server,
            ctx: *const Tls.Context,
        };

        fn workerRun(worker: WorkerCtx) void {
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

            // One per-worker arena, reset per request inside processRequestToBuffer (shared-nothing,
            // one request processed at a time on this thread).
            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();
            _ = arena.allocator().alloc(u8, worker.max_allocator_size) catch {};
            _ = arena.reset(.retain_capacity);

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
                        acceptAll(&table, epfd, listener_fd, worker.server, worker.ctx);
                        continue;
                    }

                    const conn = table.get(ev.data.fd) orelse continue;
                    var keep = true;

                    if ((ev.events & (linux.EPOLL.HUP | linux.EPOLL.ERR)) != 0) {
                        keep = false;
                    } else {
                        if ((ev.events & linux.EPOLL.OUT) != 0) keep = onWritable(epfd, conn);
                        if (keep and (ev.events & linux.EPOLL.IN) != 0) keep = onReadable(conn, worker.io, &arena);
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

        fn run(server: Server, io: std.Io) !void {
            const cfg = server.config;
            const ctx = cfg.tls.?;
            // Cpuset-aware count, NOT the host CPU count, so a cgroup-pinned server does not spawn
            // host-many workers onto a few cores (matches the cleartext .EPOLL model and http1).
            const cpu = common.getAvailableCpuCount();
            const worker_count = if (cfg.workers == 0) cpu else cfg.workers;

            common.logSystem(cfg, "listening on {s}:{d} (https/1.1 TLS, epoll-mux/{d})", .{ cfg.ip, cfg.port, worker_count });

            const threads = try allocator.alloc(std.Thread, worker_count);
            defer allocator.free(threads);

            for (threads, 0..) |*t, i|
                t.* = try std.Thread.spawn(.{ .stack_size = cfg.worker_stack_size_bytes }, workerRun, .{WorkerCtx{
                    .io = io,
                    .ip = cfg.ip,
                    .port = cfg.port,
                    .kernel_backlog = cfg.kernel_backlog,
                    .max_allocator_size = cfg.max_allocator_size,
                    .worker_id = i,
                    .server = server,
                    .ctx = ctx,
                }});

            for (threads) |t| t.join();
        }
    };
}
