//! zix
//! Zero sIX; 06;
//! A network backend library wirtten in zig

pub const Tcp = @import("tcp/Tcp.zig");
pub const Udp = @import("udp/Udp.zig");
pub const Http = @import("tcp/http/Http.zig");
pub const Http1 = @import("tcp/http1/Http1.zig");
pub const Http2 = @import("tcp/http2/Http2.zig");
pub const Grpc = @import("tcp/http2/grpc/Grpc.zig");
pub const Fix = @import("tcp/fix/Fix.zig");
pub const Uds = @import("uds/Uds.zig");
pub const Channel = @import("channel/Channel.zig").Channel;
pub const Logger = @import("logger/logger.zig").Logger;

// --------------------------------------------------------- //

pub const utils = struct {
    pub const file = @import("utils/file.zig");
};

// --------------------------------------------------------- //

const std = @import("std");

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

    // # zix.Http1
    std.testing.refAllDecls(@import("tcp/http1/core.zig"));
    std.testing.refAllDecls(@import("tcp/http1/config.zig"));
    std.testing.refAllDecls(@import("tcp/http1/server.zig"));
    std.testing.refAllDecls(@import("tcp/http1/router.zig"));

    // # zix.Http2
    std.testing.refAllDecls(@import("tcp/http2/frame.zig"));
    std.testing.refAllDecls(@import("tcp/http2/hpack.zig"));
    std.testing.refAllDecls(@import("tcp/http2/core.zig"));
    std.testing.refAllDecls(@import("tcp/http2/config.zig"));
    std.testing.refAllDecls(@import("tcp/http2/server.zig"));

    // # zix.Grpc
    std.testing.refAllDecls(@import("tcp/http2/grpc/status.zig"));
    std.testing.refAllDecls(@import("tcp/http2/grpc/frame.zig"));
    std.testing.refAllDecls(@import("tcp/http2/grpc/proto.zig"));
    std.testing.refAllDecls(@import("tcp/http2/grpc/timeout.zig"));
    std.testing.refAllDecls(@import("tcp/http2/grpc/core.zig"));
    std.testing.refAllDecls(@import("tcp/http2/grpc/config.zig"));
    std.testing.refAllDecls(@import("tcp/http2/grpc/server.zig"));
    std.testing.refAllDecls(@import("tcp/http2/grpc/client.zig"));

    // # zix.Logger
    std.testing.refAllDecls(@import("logger/logger.zig"));

    // # zix.Utils
    std.testing.refAllDecls(@import("utils/file.zig"));

    // # zix.Udp
    std.testing.refAllDecls(@import("udp/config.zig"));
    std.testing.refAllDecls(@import("udp/packet.zig"));
    std.testing.refAllDecls(@import("udp/server.zig"));
    std.testing.refAllDecls(@import("udp/client.zig"));

    // # zix.Tcp (raw)
    std.testing.refAllDecls(@import("tcp/config.zig"));
    std.testing.refAllDecls(@import("tcp/server.zig"));
    std.testing.refAllDecls(@import("tcp/client.zig"));

    // # zix.Fix
    std.testing.refAllDecls(@import("tcp/fix/core.zig"));
    std.testing.refAllDecls(@import("tcp/fix/config.zig"));
    std.testing.refAllDecls(@import("tcp/fix/server.zig"));
    std.testing.refAllDecls(@import("tcp/fix/client.zig"));

    // # zix.Uds
    std.testing.refAllDecls(@import("uds/config.zig"));
    std.testing.refAllDecls(@import("uds/server.zig"));
    std.testing.refAllDecls(@import("uds/client.zig"));

    // # zix.Channel
    std.testing.refAllDecls(@import("channel/channel.zig"));
}
