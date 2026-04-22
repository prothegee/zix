const std = @import("std");

pub const Context = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    response_sent: bool = false,
};
