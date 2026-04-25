//! zix
//! A micro net-frame-work
//! to compliment your system in network implementation.

pub const Tcp = @import("tcp/Tcp.zig");

// --------------------------------------------------------- //

pub const HttpServerConfig = @import("tcp/http/config.zig").HttpServerConfig;
pub const HttpServer = @import("tcp/http/server.zig").HttpServer;
pub const Request = @import("tcp/http/request.zig").Request;
pub const Response = @import("tcp/http/response.zig").Response;
pub const Context = @import("tcp/http/context.zig").Context;
pub const HandlerFn = @import("tcp/http/router.zig").HandlerFn;
pub const HttpHeader = @import("tcp/http/response.zig").HttpHeader;
pub const HttpContentType = @import("tcp/http/content.zig").Type;
pub const HeaderSize = @import("tcp/http/response.zig").HeaderSize;
pub const MultipartParser = @import("tcp/http/upload.zig").MultipartParser;
pub const MultipartField = @import("tcp/http/upload.zig").MultipartField;
pub const WebSocket = @import("tcp/http/websocket.zig");

pub const utils = struct {
    pub const file = @import("utils/file.zig");
};

// --------------------------------------------------------- //

const std = @import("std");

// --------------------------------------------------------- //
// --------------------------------------------------------- //

test "zix tests: unit test" {
    // # zix.Tcp.Http
    std.testing.refAllDecls(@import("tcp/http/method.zig"));
    std.testing.refAllDecls(@import("tcp/http/status.zig"));
    std.testing.refAllDecls(@import("tcp/http/content.zig"));
    std.testing.refAllDecls(@import("tcp/http/request.zig"));
    std.testing.refAllDecls(@import("tcp/http/response.zig"));
    std.testing.refAllDecls(@import("tcp/http/router.zig"));
    std.testing.refAllDecls(@import("tcp/http/static.zig"));
    std.testing.refAllDecls(@import("tcp/http/upload.zig"));
    std.testing.refAllDecls(@import("tcp/http/websocket.zig"));

    // # zix.Utils
    std.testing.refAllDecls(@import("utils/file.zig"));
}
