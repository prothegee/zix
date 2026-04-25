//! zix http context

const std = @import("std");

pub const Context = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    response_sent: bool = false,
    /// Raw TCP stream — available for WebSocket upgrade handlers.
    /// Normal HTTP handlers should not use this directly.
    stream: std.Io.net.Stream = undefined,
};
