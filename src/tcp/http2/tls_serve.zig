//! zix http2 https serve path (h2 over TLS 1.3 / 1.2, RFC 8446 + 7540 + 7301 ALPN).
//!
//! Note:
//! - Gated on config.tls (a *Tls.Context). An accept loop hands each connection to its own worker
//!   thread, which runs the shared h2-over-TLS terminator (../tls/h2_terminator.zig): the handshake
//!   negotiates ALPN h2, then the inline-mux driver below drives the resumable h2 state machine
//!   (mux.zig) directly over the decrypted stream. The mux writes its frames through a thread-local
//!   hook that seals them into TLS records, so there is NO socketpair and NO second thread per
//!   connection (one thread per connection, not two). This is what lets the TLS path scale to high
//!   connection counts instead of livelocking on a per-connection socketpair relay.
//! - The cleartext dispatch models (ASYNC / POOL / MIXED / EPOLL / URING) are untouched. https is a
//!   separate path on its own perf band.

const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;
const core = @import("core.zig");
const Route = core.Route;
const Http2ServerConfig = @import("config.zig").Http2ServerConfig;
const common = @import("dispatch/common.zig");
const terminator = @import("../tls/h2_terminator.zig");
const mux = @import("mux.zig");
const frame = @import("frame.zig");

/// The most plaintext one TLS record carries (RFC 8446 5.1). The mux's frames are sealed in chunks of
/// at most this, so the seal buffer holds one record (plaintext + AEAD + content-type + header).
const max_plaintext: usize = 16 * 1024;

/// Drive the resumable h2 mux inline over a decrypted TLS connection: read a record, decrypt it, feed
/// the plaintext to the mux, and seal the mux's reply frames back into records. No socketpair, no
/// second thread. Generic over the TLS connection type (1.3 or 1.2), both expose readAppData /
/// writeAppData / closeNotify.
fn runInlineMux(comptime routes: []const Route, opts: core.ServeOpts, fd: posix.fd_t, conn: anytype, record_buf: []u8) void {
    const mux_conn = mux.MuxConn.init(fd, opts) orelse return;
    defer mux_conn.deinit();

    // The mux writes plaintext through frame.fdWriteAll. The hook seals that plaintext into TLS records
    // and writes them to the socket, so the unchanged mux serves a TLS connection.
    const Encryptor = struct {
        conn: @TypeOf(conn),
        fd: posix.fd_t,
        plain: [max_plaintext]u8 = undefined,
        plain_len: usize = 0,
        seal: [max_plaintext + 1024]u8 = undefined,
        failed: bool = false,

        fn flush(self: *@This()) void {
            if (self.plain_len == 0 or self.failed) return;

            const sealed = self.conn.writeAppData(self.plain[0..self.plain_len], &self.seal);
            terminator.writeAll(self.fd, sealed) catch {
                self.failed = true;
            };
            self.plain_len = 0;
        }

        fn append(self: *@This(), bytes: []const u8) void {
            var rest = bytes;
            while (rest.len > 0 and !self.failed) {
                if (self.plain_len == self.plain.len) self.flush();
                if (self.failed) return;

                const n = @min(rest.len, self.plain.len - self.plain_len);
                @memcpy(self.plain[self.plain_len..][0..n], rest[0..n]);
                self.plain_len += n;
                rest = rest[n..];
            }
        }
    };

    var enc = Encryptor{ .conn = conn, .fd = fd };

    const hook = struct {
        fn call(ctx: *anyopaque, bytes: []const u8) void {
            const e: *Encryptor = @ptrCast(@alignCast(ctx));
            e.append(bytes);
        }
    }.call;

    frame.write_hook = hook;
    frame.write_hook_ctx = &enc;
    defer {
        frame.write_hook = null;
        frame.write_hook_ctx = null;
    }

    var decrypt: [max_plaintext]u8 = undefined;
    while (true) {
        // Compact the read accumulator before the next record (mirrors the URING armRecv compaction).
        if (mux_conn.rstart == mux_conn.rend) {
            mux_conn.rstart = 0;
            mux_conn.rend = 0;
        } else if (mux_conn.rend == mux_conn.rbuf.len) {
            const n = mux_conn.rend - mux_conn.rstart;
            std.mem.copyForwards(u8, mux_conn.rbuf[0..n], mux_conn.rbuf[mux_conn.rstart..mux_conn.rend]);
            mux_conn.rstart = 0;
            mux_conn.rend = n;
        }

        if (mux_conn.rend == mux_conn.rbuf.len) break; // a single frame larger than the buffer

        const rec = terminator.readRecord(fd, record_buf) catch break;
        if (rec.content_type == terminator.content_type_change_cipher_spec) continue;
        if (rec.content_type != terminator.content_type_application_data) break; // alert / close_notify

        const plain = conn.readAppData(rec.full, &decrypt) catch break;

        // Feed the decrypted plaintext into the mux read accumulator (the record fits post-compaction).
        if (plain.len > mux_conn.rbuf.len - mux_conn.rend) break;
        @memcpy(mux_conn.rbuf[mux_conn.rend..][0..plain.len], plain);
        mux_conn.rend += plain.len;

        const outcome = mux.processRing(routes, mux_conn);
        enc.flush();
        if (enc.failed or outcome == .close) break;
    }

    // close_notify so the client finalizes the connection cleanly.
    var close_buf: [64]u8 = undefined;
    terminator.writeAll(fd, conn.closeNotify(&close_buf)) catch {};
}

/// Terminator driver: drives the resumable h2 mux inline over the decrypted stream (no socketpair).
fn MuxDriver(comptime routes: []const Route) type {
    return struct {
        opts: core.ServeOpts,

        pub fn drive(self: @This(), fd: posix.fd_t, conn: anytype, record_buf: []u8) void {
            runInlineMux(routes, self.opts, fd, conn, record_buf);
        }
    };
}

/// Per-connection TLS worker: terminate TLS and serve the inline mux, then close the socket. One
/// thread per connection so the accept loop never blocks in the terminator.
fn TlsConn(comptime routes: []const Route) type {
    return struct {
        const Ctx = struct {
            fd: posix.fd_t,
            opts: core.ServeOpts,
            ctx: *const @import("../../tls/Tls.zig").Context,
        };

        fn entry(c: Ctx) void {
            defer _ = linux.close(c.fd);

            terminator.serveConnTls(c.fd, c.ctx, MuxDriver(routes){ .opts = c.opts }) catch {};
        }
    };
}

/// Listen and serve h2 over TLS. The cert / key / policy are loaded and validated once in the context
/// (config.tls). Each accepted connection is handed to its own worker thread. Routes are baked in at
/// compile time, so the driver is generated per route table.
pub fn runTls(comptime routes: []const Route, config: Http2ServerConfig) !void {
    const io = config.io;
    const ctx = config.tls.?;

    const addr = try std.Io.net.IpAddress.resolve(io, config.ip, config.port);
    var srv = try addr.listen(io, .{ .reuse_address = true, .kernel_backlog = config.kernel_backlog });

    common.logSystem(config, "listening on {s}:{d} (h2, TLS)", .{ config.ip, config.port });

    const opts = common.serveOpts(config);

    while (true) {
        const stream = srv.accept(io) catch continue;
        const conn_fd = stream.socket.handle;

        const worker = std.Thread.spawn(.{ .stack_size = 512 * 1024 }, TlsConn(routes).entry, .{
            TlsConn(routes).Ctx{ .fd = conn_fd, .opts = opts, .ctx = ctx },
        }) catch {
            // Spawn failed (thread / pids limit under extreme load): drop this connection and keep
            // accepting. Serving inline here would block the accept loop for the connection's whole
            // lifetime, wedging every other pending connection. The client retries the dropped one.
            _ = linux.close(conn_fd);

            continue;
        };

        worker.detach();
    }
}
