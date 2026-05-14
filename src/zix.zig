//! zix
//! Zero sIX; 06;
//! A network library wirtten in zig

pub const Tcp = @import("tcp/Tcp.zig");
pub const Udp = @import("udp/Udp.zig");
pub const Http = @import("tcp/http/Http.zig");
pub const Uds = @import("uds/Uds.zig");
pub const Channel = @import("channel/Channel.zig").Channel;

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
    std.testing.refAllDecls(@import("tcp/http/request.zig"));
    std.testing.refAllDecls(@import("tcp/http/response.zig"));
    std.testing.refAllDecls(@import("tcp/http/router.zig"));
    std.testing.refAllDecls(@import("tcp/http/static.zig"));
    std.testing.refAllDecls(@import("tcp/http/upload.zig"));
    std.testing.refAllDecls(@import("tcp/http/websocket.zig"));
    std.testing.refAllDecls(@import("tcp/http/client_config.zig"));
    std.testing.refAllDecls(@import("tcp/http/client.zig"));

    // # zix.Utils
    std.testing.refAllDecls(@import("utils/file.zig"));

    // # zix.Udp
    std.testing.refAllDecls(@import("udp/config.zig"));
    std.testing.refAllDecls(@import("udp/packet.zig"));
    std.testing.refAllDecls(@import("udp/server.zig"));
    std.testing.refAllDecls(@import("udp/client.zig"));

    // # zix.Uds
    std.testing.refAllDecls(@import("uds/config.zig"));
    std.testing.refAllDecls(@import("uds/server.zig"));
    std.testing.refAllDecls(@import("uds/client.zig"));

    // # zix.Channel
    std.testing.refAllDecls(@import("channel/channel.zig"));
}
