// Runner for self-terminating channel examples (channel_basic, channel_pipeline,
// channel_worker_pool). Spawns the program and waits for it to exit with code 0.
//
// Invoked by `zig build test-runner-channel-<name>`.
// argv[1]: channel binary path
// argv[2]: label

const std = @import("std");
const common = @import("common.zig");

const TIMEOUT_MS: u64 = 30000;

// --------------------------------------------------------- //

pub fn main(process: std.process.Init) void {
    var arg_iter = std.process.Args.Iterator.init(process.minimal.args);
    _ = arg_iter.skip();
    const server_path = arg_iter.next() orelse {
        std.debug.print("FAIL: missing binary path\n", .{});
        std.process.exit(1);
    };
    const label = arg_iter.next() orelse {
        std.debug.print("FAIL: missing label\n", .{});
        std.process.exit(1);
    };

    run(process.io, server_path) catch |err| {
        std.debug.print("FAIL {s}: {}\n", .{ label, err });
        std.process.exit(1);
    };
    common.printPass(label);
}

fn run(io: std.Io, binary_path: []const u8) !void {
    var child = try common.spawnServer(io, binary_path);

    const term = try child.wait(io);

    switch (term) {
        .exited => |code| {
            if (code != 0) return error.NonZeroExit;
        },
        .signal, .stopped, .unknown => return error.UnexpectedTermination,
    }

    _ = TIMEOUT_MS;
}
