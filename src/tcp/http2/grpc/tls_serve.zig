//! zix grpc https serve path (gRPC over TLS 1.3 / 1.2, RFC 8446 + 7540 + 7301 ALPN).
//!
//! Note:
//! - Gated on config.tls (a *Tls.Context). An accept loop hands each connection to its own worker
//!   thread, which runs the shared h2-over-TLS terminator (../../tls/h2_terminator.zig): the
//!   handshake negotiates ALPN h2, then a socketpair carries plaintext and the unchanged h2c gRPC
//!   engine (core.serveGrpcConn) runs on one end. The terminator pumps inbound (decrypt) and
//!   outbound (encrypt).
//! - The cleartext dispatch models (ASYNC / POOL / MIXED / EPOLL / URING) are untouched. https is a
//!   separate path on its own perf band, so the per-connection worker plus engine thread are
//!   acceptable here. Serving each connection on its own thread keeps the accept loop from blocking
//!   in the terminator, so many TLS connections proceed concurrently.

const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;
const core = @import("core.zig");
const Route = core.Route;
const GrpcServerConfig = @import("config.zig").GrpcServerConfig;
const common = @import("dispatch/common.zig");
const terminator = @import("../../tls/h2_terminator.zig");
const Tls = @import("../../../tls/Tls.zig");

/// Engine context handed to the terminator: just the serve options. Routes are comptime, so the
/// engine entry below bakes them in.
const EngineCtx = struct { opts: core.GrpcServeOpts };

fn setNonBlock(fd: posix.fd_t) void {
    const cur = linux.fcntl(fd, posix.F.GETFL, 0);
    const nonblock: u32 = @bitCast(posix.O{ .NONBLOCK = true });
    _ = linux.fcntl(fd, posix.F.SETFL, cur | @as(usize, nonblock));
}

/// Build the engine entry for a route table: run the gRPC h2 mux state machine over the decrypted
/// socketpair end the terminator hands us. The mux is single-threaded per connection (one owner, no
/// per-stream worker threads), so it has the same wire correctness as the .EPOLL / .URING cleartext
/// loops and none of the write races the thread-per-stream blocking path can hit under a pumped
/// socketpair. The socketpair end is set non-blocking, then a poll loop drives one readable pass at
/// a time: grpcMuxOnReadable drains the buffer, dispatches complete streams, and flushes the staged
/// reply, returning .keep_alive when drained or .close on peer close / protocol error.
fn engineEntry(comptime routes: []const Route) fn (EngineCtx, posix.fd_t) void {
    return struct {
        fn run(ec: EngineCtx, inner_fd: posix.fd_t) void {
            setNonBlock(inner_fd);

            const conn = core.GrpcMuxConn.init(inner_fd, ec.opts) orelse return;
            defer conn.deinit();

            var pfd = [_]posix.pollfd{.{ .fd = inner_fd, .events = posix.POLL.IN, .revents = 0 }};
            while (true) {
                pfd[0].revents = 0;
                if (posix.errno(linux.poll(&pfd, 1, -1)) != .SUCCESS) return;

                if (core.grpcMuxOnReadable(routes, conn) == .close) return;
            }
        }
    }.run;
}

/// Per-connection TLS worker: terminate TLS and serve, then close the socket. One runs per accepted
/// connection so the accept loop never blocks in the terminator and connections proceed concurrently.
fn TlsConn(comptime routes: []const Route) type {
    return struct {
        const Ctx = struct {
            fd: posix.fd_t,
            opts: core.GrpcServeOpts,
            ctx: *const Tls.Context,
        };

        fn entry(c: Ctx) void {
            defer _ = linux.close(c.fd);

            terminator.serveConnTls(c.fd, c.ctx, EngineCtx, .{ .opts = c.opts }, engineEntry(routes)) catch {};
        }
    };
}

/// Listen and serve gRPC over TLS. The cert / key / policy are loaded and validated once in the
/// context (config.tls), so the accept loop reads a ready context. Each accepted connection is
/// handed to its own worker thread. Routes are baked in at compile time, so the engine entry is
/// generated per route table.
pub fn runTls(comptime routes: []const Route, config: GrpcServerConfig) !void {
    const io = config.io;
    const ctx = config.tls.?;

    const addr = try std.Io.net.IpAddress.resolve(io, config.ip, config.port);
    var srv = try addr.listen(io, .{ .reuse_address = true });

    common.logSystem(config, "listening on {s}:{d} (grpc, TLS)", .{ config.ip, config.port });

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
