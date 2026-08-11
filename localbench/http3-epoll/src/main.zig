//! localbench: zix-http3
//!
//! zix.Http3 (.EPOLL), Router-only: pure-Zig QUIC on std.crypto
//! (RFC 9000/9001/9002/9114), one SO_REUSEPORT worker per core on UDP 8443,
//! one handler module per route (src/handlers/). TLS 1.3 rides inside the
//! handshake and ALPN h3 is negotiated by the engine. /static is served by
//! the engine from public_dir.
//!
//! Note:
//! - public_dir_cache_ttl_ms is REQUIRED here, unlike on the TCP engines. An
//!   HTTP/3 response body outlives the handler (the pump reads it again for
//!   every packet and every retransmission), so it has to come from the cache.
//!   At 0 the engine serves no static file at all and falls through to 404.
//!   This is a protocol constraint, not a caching choice.
//! - QUIC has no cleartext mode, so a missing certificate is fatal: there is no
//!   cleartext listener to degrade to the way the TCP entries have.

const std = @import("std");
const zix = @import("zix");

const baseline = @import("handlers/baseline.zig");

const paths = @import("shared/paths.zig");

// --------------------------------------------------------- //

const Routes = zix.Http3.Router(&[_]zix.Http3.Route{
    .{ .path = baseline.PATH, .handler = baseline.RESPONSE },
});

pub fn main(process: std.process.Init) !void {
    var tls_alloc = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer tls_alloc.deinit();

    var tls = try zix.Tls.Context.init(tls_alloc.allocator(), process.io, .{
        .cert_path = paths.TLS_CERT,
        .key_path = paths.TLS_KEY,
        .min_version = .TLS_1_3,
    });

    var server = zix.Http3.Server.init(Routes.dispatch, .{
        .io = process.io,
        .allocator = std.heap.smp_allocator,
        .ip = "::",
        .port = 8443,
        .workers = 0,
        .dispatch_model = .EPOLL,
        .tls = &tls,
        //
        .public_dir = paths.DATA_DIR,
        .public_dir_cache_ttl_ms = 30 * 1000,
        //
        .max_streams = 1024,
    });
    defer server.deinit();

    try server.run();
}
