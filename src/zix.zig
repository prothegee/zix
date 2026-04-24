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

// --------------------------------------------------------- //

const std = @import("std");

// --------------------------------------------------------- //
// --------------------------------------------------------- //

test "zix tests: unit test" {
    // # zix.Tcp.Http
    std.testing.refAllDecls(@import("tcp/http/method.zig"));
    std.testing.refAllDecls(@import("tcp/http/status.zig"));
    std.testing.refAllDecls(@import("tcp/http/content.zig"));
}
