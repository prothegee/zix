//! zix
//! Zero sIX; 06;
//! A network backend library written in zig

const std = @import("std");
const builtin = @import("builtin");

/// THE ONLY SOURCE OF TRUTH for Zig SEMVER for zix source code.
///
/// Note:
/// - Do not create in other place!
pub const ZIG_SEMVER = struct {
    pub const MAJOR: usize = builtin.zig_version.major;
    pub const MINOR: usize = builtin.zig_version.minor;
    pub const PATCH: usize = builtin.zig_version.patch;
};

// --------------------------------------------------------- //

pub const Tcp = @import("tcp/Tcp.zig");
pub const Udp = @import("udp/Udp.zig");
pub const Http = @import("tcp/http/Http.zig");
pub const Http1 = @import("tcp/http1/Http1.zig");
pub const Http2 = @import("tcp/http2/Http2.zig");
pub const Http3 = @import("udp/http3/Http3.zig");
pub const Grpc = @import("tcp/http2/grpc/Grpc.zig");
pub const Fix = @import("tcp/fix/Fix.zig");
pub const Uds = @import("uds/Uds.zig");
pub const Tls = @import("tls/Tls.zig");
pub const Channel = @import("channel/Channel.zig").Channel;
pub const Logger = @import("logger/logger.zig").Logger;

// --------------------------------------------------------- //

pub const utils = struct {
    pub const file = @import("utils/file.zig");
    pub const response_cache = @import("utils/response_cache.zig");

    pub const compression = @import("utils/compression/compression.zig");
};

// --------------------------------------------------------- //
// --------------------------------------------------------- //

test "zix tests: unit test" {
    // # zix.Http
    std.testing.refAllDecls(@import("tcp/http/method.zig"));
    std.testing.refAllDecls(@import("tcp/http/status.zig"));
    std.testing.refAllDecls(@import("tcp/http/content.zig"));
    std.testing.refAllDecls(@import("tcp/http/parser.zig"));
    std.testing.refAllDecls(@import("tcp/http/context.zig"));
    std.testing.refAllDecls(@import("tcp/http/request.zig"));
    std.testing.refAllDecls(@import("tcp/http/response.zig"));
    std.testing.refAllDecls(@import("tcp/http/router.zig"));
    std.testing.refAllDecls(@import("tcp/http/static.zig"));
    std.testing.refAllDecls(@import("tcp/http/upload.zig"));
    std.testing.refAllDecls(@import("tcp/http/websocket.zig"));
    std.testing.refAllDecls(@import("tcp/http/client_config.zig"));
    std.testing.refAllDecls(@import("tcp/http/client.zig"));
    std.testing.refAllDecls(@import("tcp/http/h2_client.zig"));
    std.testing.refAllDecls(@import("tcp/http/server.zig"));
    std.testing.refAllDecls(@import("tcp/http/sse_client.zig"));
    std.testing.refAllDecls(@import("tcp/http/ws_client.zig"));

    // # zix.Http1
    std.testing.refAllDecls(@import("tcp/http1/core.zig"));
    std.testing.refAllDecls(@import("tcp/http1/config.zig"));
    std.testing.refAllDecls(@import("tcp/http1/server.zig"));
    std.testing.refAllDecls(@import("tcp/http1/dispatch/common.zig"));
    std.testing.refAllDecls(@import("tcp/http1/dispatch/async.zig"));
    std.testing.refAllDecls(@import("tcp/http1/dispatch/pool.zig"));
    std.testing.refAllDecls(@import("tcp/http1/dispatch/mixed.zig"));
    std.testing.refAllDecls(@import("tcp/http1/dispatch/epoll.zig"));
    std.testing.refAllDecls(@import("tcp/http1/dispatch/uring.zig"));
    std.testing.refAllDecls(@import("tcp/http1/router.zig"));
    std.testing.refAllDecls(@import("tcp/http1/websocket.zig"));

    // # zix.Tls (TLS 1.3 layer)
    std.testing.refAllDecls(@import("tls/wire.zig"));
    std.testing.refAllDecls(@import("tls/key_schedule.zig"));
    std.testing.refAllDecls(@import("tls/record.zig"));
    std.testing.refAllDecls(@import("tls/alert.zig"));
    std.testing.refAllDecls(@import("tls/handshake.zig"));
    std.testing.refAllDecls(@import("tls/extensions.zig"));
    std.testing.refAllDecls(@import("tls/certificate.zig"));
    std.testing.refAllDecls(@import("tls/connection.zig"));
    std.testing.refAllDecls(@import("tls/pem.zig"));
    std.testing.refAllDecls(@import("tls/rsa.zig"));
    std.testing.refAllDecls(@import("tls/context.zig"));
    std.testing.refAllDecls(@import("tcp/tls/h2_terminator.zig"));
    std.testing.refAllDecls(@import("tcp/http1/tls_serve.zig"));

    // # zix.Tls (TLS 1.2 building blocks: PRF schedule, record, version select)
    std.testing.refAllDecls(@import("tls/tls12_prf.zig"));
    std.testing.refAllDecls(@import("tls/tls12_record.zig"));
    std.testing.refAllDecls(@import("tls/tls12_version.zig"));
    std.testing.refAllDecls(@import("tls/tls12_connection.zig"));
    std.testing.refAllDecls(@import("tls/client.zig"));
    std.testing.refAllDecls(@import("tls/tls12_client.zig"));
    std.testing.refAllDecls(@import("tls/cert_verify.zig"));

    // # zix.io_uring (shared ring runtime, .URING dispatch model)
    std.testing.refAllDecls(@import("multiplexers/ring.zig"));
    std.testing.refAllDecls(@import("multiplexers/slab.zig"));

    // # zix.Http2
    std.testing.refAllDecls(@import("tcp/http2/frame.zig"));
    std.testing.refAllDecls(@import("tcp/http2/hpack.zig"));
    std.testing.refAllDecls(@import("tcp/http2/core.zig"));
    std.testing.refAllDecls(@import("tcp/http2/mux.zig"));
    std.testing.refAllDecls(@import("tcp/http2/config.zig"));
    std.testing.refAllDecls(@import("tcp/http2/server.zig"));
    std.testing.refAllDecls(@import("tcp/http2/dispatch/epoll.zig"));
    std.testing.refAllDecls(@import("tcp/http2/dispatch/uring.zig"));
    std.testing.refAllDecls(@import("tcp/http2/tls_serve.zig"));

    // # zix.Grpc
    std.testing.refAllDecls(@import("tcp/http2/grpc/status.zig"));
    std.testing.refAllDecls(@import("tcp/http2/grpc/frame.zig"));
    std.testing.refAllDecls(@import("tcp/http2/grpc/proto.zig"));
    std.testing.refAllDecls(@import("tcp/http2/grpc/timeout.zig"));
    std.testing.refAllDecls(@import("tcp/http2/grpc/core.zig"));
    std.testing.refAllDecls(@import("tcp/http2/grpc/config.zig"));
    std.testing.refAllDecls(@import("tcp/http2/grpc/server.zig"));
    std.testing.refAllDecls(@import("tcp/http2/grpc/tls_serve.zig"));
    std.testing.refAllDecls(@import("tcp/http2/grpc/client.zig"));

    // # zix.Logger
    std.testing.refAllDecls(@import("logger/logger.zig"));

    // # zix.Utils
    std.testing.refAllDecls(@import("utils/file.zig"));
    std.testing.refAllDecls(@import("utils/response_cache.zig"));
    std.testing.refAllDecls(@import("utils/compression/flate.zig"));
    std.testing.refAllDecls(@import("utils/compression/compression.zig"));

    // # zix.Udp
    std.testing.refAllDecls(@import("udp/config.zig"));
    std.testing.refAllDecls(@import("udp/packet.zig"));
    std.testing.refAllDecls(@import("udp/server.zig"));
    std.testing.refAllDecls(@import("udp/client.zig"));
    std.testing.refAllDecls(@import("udp/datagram.zig"));
    std.testing.refAllDecls(@import("udp/core.zig"));
    std.testing.refAllDecls(@import("udp/raw.zig"));
    std.testing.refAllDecls(@import("udp/dispatch/common.zig"));
    std.testing.refAllDecls(@import("udp/dispatch/async.zig"));
    std.testing.refAllDecls(@import("udp/dispatch/pool.zig"));
    std.testing.refAllDecls(@import("udp/dispatch/mixed.zig"));
    std.testing.refAllDecls(@import("udp/dispatch/epoll.zig"));
    std.testing.refAllDecls(@import("udp/dispatch/uring.zig"));

    // # zix.Http3
    std.testing.refAllDecls(@import("udp/http3/crypto.zig"));
    std.testing.refAllDecls(@import("udp/http3/varint.zig"));
    std.testing.refAllDecls(@import("udp/http3/packet.zig"));
    std.testing.refAllDecls(@import("udp/http3/frame.zig"));
    std.testing.refAllDecls(@import("udp/http3/stream.zig"));
    std.testing.refAllDecls(@import("udp/http3/flow.zig"));
    std.testing.refAllDecls(@import("udp/http3/close.zig"));
    std.testing.refAllDecls(@import("udp/http3/recovery.zig"));
    std.testing.refAllDecls(@import("udp/http3/h3.zig"));
    std.testing.refAllDecls(@import("udp/http3/qpack.zig"));
    std.testing.refAllDecls(@import("udp/http3/qpack_dynamic.zig"));
    std.testing.refAllDecls(@import("udp/http3/tls.zig"));
    std.testing.refAllDecls(@import("udp/http3/protection.zig"));
    std.testing.refAllDecls(@import("udp/http3/serverhello.zig"));
    std.testing.refAllDecls(@import("udp/http3/keyschedule.zig"));
    std.testing.refAllDecls(@import("udp/http3/flight.zig"));
    std.testing.refAllDecls(@import("udp/http3/response.zig"));
    std.testing.refAllDecls(@import("udp/http3/router.zig"));
    std.testing.refAllDecls(@import("udp/http3/request.zig"));
    std.testing.refAllDecls(@import("udp/http3/config.zig"));
    std.testing.refAllDecls(@import("udp/http3/core.zig"));
    std.testing.refAllDecls(@import("udp/http3/demux.zig"));
    std.testing.refAllDecls(@import("udp/http3/connection.zig"));
    std.testing.refAllDecls(@import("udp/http3/server.zig"));
    std.testing.refAllDecls(@import("udp/http3/dispatch/common.zig"));
    std.testing.refAllDecls(@import("udp/http3/dispatch/async.zig"));
    std.testing.refAllDecls(@import("udp/http3/dispatch/pool.zig"));
    std.testing.refAllDecls(@import("udp/http3/dispatch/mixed.zig"));
    std.testing.refAllDecls(@import("udp/http3/dispatch/epoll.zig"));
    std.testing.refAllDecls(@import("udp/http3/dispatch/uring.zig"));
    std.testing.refAllDecls(@import("udp/http3/Http3.zig"));

    // # zix.Tcp (raw)
    std.testing.refAllDecls(@import("tcp/config.zig"));
    std.testing.refAllDecls(@import("tcp/server.zig"));
    std.testing.refAllDecls(@import("tcp/client.zig"));

    // # zix.Fix
    std.testing.refAllDecls(@import("tcp/fix/core.zig"));
    std.testing.refAllDecls(@import("tcp/fix/config.zig"));
    std.testing.refAllDecls(@import("tcp/fix/server.zig"));
    std.testing.refAllDecls(@import("tcp/fix/client.zig"));
    std.testing.refAllDecls(@import("tcp/fix/router.zig"));

    // # zix.Uds
    std.testing.refAllDecls(@import("uds/config.zig"));
    std.testing.refAllDecls(@import("uds/server.zig"));
    std.testing.refAllDecls(@import("uds/client.zig"));

    // # zix.Channel
    std.testing.refAllDecls(@import("channel/channel.zig"));
}
