const std = @import("std");

// --------------------------------------------------------- //

const REQUIRED_DIRS = [_][]const u8 {
    "./.zig-cache",
    //
    "./zig-out",
};

// --------------------------------------------------------- //

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    inline for (REQUIRED_DIRS) |dir| {
        std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    }
}

