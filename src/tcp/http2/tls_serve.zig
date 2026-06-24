//! zix http2 https serve path (h2 over TLS 1.3 / 1.2, RFC 8446 + 7540 + 7301 ALPN).
//!
//! Note:
//! - Gated on config.tls (a *Tls.Context). An accept loop hands each connection to its own worker
//!   thread, which runs the shared h2-over-TLS terminator (../tls/h2_terminator.zig): the handshake
//!   negotiates ALPN h2, then a socketpair carries plaintext and the unchanged h2c engine
//!   (core.serveConn) runs on one end. The terminator pumps inbound (decrypt) and outbound (encrypt).
//! - The cleartext dispatch models (ASYNC / POOL / MIXED / EPOLL / URING) are untouched. https is a
//!   separate path on its own perf band, so the per-connection worker plus engine thread are
//!   acceptable here. Serving each connection on its own thread keeps the accept loop from blocking
//!   in the terminator, so many TLS connections proceed concurrently.

const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;
const core = @import("core.zig");
const Route = core.Route;
const Http2ServerConfig = @import("config.zig").Http2ServerConfig;
const common = @import("dispatch/common.zig");
const terminator = @import("../tls/h2_terminator.zig");

/// Engine context handed to the terminator: just the serve options. Routes are comptime, so the
/// engine entry below bakes them in.
const EngineCtx = struct { opts: core.ServeOpts };

/// Build the engine entry for a route table: run the cleartext h2c engine over the decrypted
/// socketpair end the terminator hands us.
fn engineEntry(comptime routes: []const Route) fn (EngineCtx, posix.fd_t) void {
    return struct {
        fn run(ec: EngineCtx, inner_fd: posix.fd_t) void {
            core.serveConn(routes, inner_fd, ec.opts);
        }
    }.run;
}

/// Per-connection TLS worker: terminate TLS and serve, then close the socket. One runs per accepted
/// connection so the accept loop never blocks in the terminator and connections proceed concurrently.
fn TlsConn(comptime routes: []const Route) type {
    return struct {
        const Ctx = struct {
            fd: posix.fd_t,
            opts: core.ServeOpts,
            ctx: *const @import("../../tls/Tls.zig").Context,
        };

        fn entry(c: Ctx) void {
            defer _ = linux.close(c.fd);

            terminator.serveConnTls(c.fd, c.ctx, EngineCtx, .{ .opts = c.opts }, engineEntry(routes)) catch {};
        }
    };
}

/// Listen and serve h2 over TLS. The cert / key / policy are loaded and validated once in the
/// context (config.tls), so the accept loop reads a ready context. Each accepted connection is
/// handed to its own worker thread. Routes are baked in at compile time, so the engine entry is
/// generated per route table.
pub fn runTls(comptime routes: []const Route, config: Http2ServerConfig) !void {
    const io = config.io;
    const ctx = config.tls.?;

    const addr = try std.Io.net.IpAddress.resolve(io, config.ip, config.port);
    var srv = try addr.listen(io, .{ .reuse_address = true });

    common.logSystem(config, "listening on {s}:{d} (h2, TLS)", .{ config.ip, config.port });

    const opts = common.serveOpts(config);

    while (true) {
        const stream = srv.accept(io) catch continue;
        const conn_fd = stream.socket.handle;

        const worker = std.Thread.spawn(.{ .stack_size = 512 * 1024 }, TlsConn(routes).entry, .{
            TlsConn(routes).Ctx{ .fd = conn_fd, .opts = opts, .ctx = ctx },
        }) catch {
            // Spawn failed: serve inline as a fallback so the connection is not dropped silently.
            terminator.serveConnTls(conn_fd, ctx, EngineCtx, .{ .opts = opts }, engineEntry(routes)) catch {};
            _ = linux.close(conn_fd);

            continue;
        };

        worker.detach();
    }
}
