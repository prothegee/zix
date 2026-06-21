// Runner for channel_ipc_a and channel_ipc_b examples.
// Spawns Process A (listens on /tmp/zix_ipc.sock), waits for the socket to appear,
// spawns Process B (connects to A), lets them exchange for 1.5 seconds, then kills both.
//
// Invoked by `zig build test-runner-channel-ipc`.
// argv[1]: channel_ipc_a binary path
// argv[2]: channel_ipc_b binary path
// argv[3]: label

const std = @import("std");
const common = @import("common.zig");

const IPC_SOCK_PATH: []const u8 = "/tmp/zix_ipc.sock";
const WAIT_MS: u64 = 5000;
const EXCHANGE_MS: u64 = 1500;

// --------------------------------------------------------- //

pub fn main(process: std.process.Init) void {
    var arg_iter = std.process.Args.Iterator.init(process.minimal.args);
    _ = arg_iter.skip();
    const ipc_a_path = arg_iter.next() orelse {
        std.debug.print("FAIL: missing ipc_a path\n", .{});
        std.process.exit(1);
    };
    const ipc_b_path = arg_iter.next() orelse {
        std.debug.print("FAIL: missing ipc_b path\n", .{});
        std.process.exit(1);
    };
    const label = arg_iter.next() orelse {
        std.debug.print("FAIL: missing label\n", .{});
        std.process.exit(1);
    };

    run(process.io, ipc_a_path, ipc_b_path) catch |err| {
        std.debug.print("FAIL {s}: {}\n", .{ label, err });
        std.process.exit(1);
    };
    common.printPass(label);
}

fn run(io: std.Io, ipc_a_path: []const u8, ipc_b_path: []const u8) !void {
    std.Io.Dir.deleteFileAbsolute(io, IPC_SOCK_PATH) catch {};

    var child_a = try common.spawnServer(io, ipc_a_path);
    defer child_a.kill(io);

    try common.waitForUdsSocket(io, IPC_SOCK_PATH, WAIT_MS);

    var child_b = try common.spawnServer(io, ipc_b_path);
    defer child_b.kill(io);

    try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(EXCHANGE_MS), .awake);
}
