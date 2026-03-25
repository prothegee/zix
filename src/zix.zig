pub const Tcp = @import("tcp/Tcp.zig");

// --------------------------------------------------------- //

const std = @import("std");

// --------------------------------------------------------- //
// --------------------------------------------------------- //

test "zix tests: unit test" {
    // # zix.Tcp.Http
    std.testing.refAllDecls(@import("tcp/http/method.zig"));
    std.testing.refAllDecls(@import("tcp/http/status.zig"));
}

