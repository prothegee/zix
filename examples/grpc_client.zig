//! gRPC h2c client example.
//! Demonstrates unary and streaming calls against the grpc_server_1_async example.
//!
//! Run (server must be running on port 8083):
//! zig build example-grpc_client

const std = @import("std");
const zix = @import("zix");

// --------------------------------------------------------- //

pub fn main(process: std.process.Init) !void {
    const io = process.io;

    std.debug.print("connecting to grpc server at 127.0.0.1:8083\n", .{});

    var client = try zix.Grpc.Client.connect(.{ .ip = "127.0.0.1", .port = 8083 }, io);
    defer client.deinit();

    std.debug.print("connected\n", .{});

    // Unary call: SayHello
    {
        var buf: [256]u8 = undefined;
        const resp = client.unary(
            "/helloworld.Greeter/SayHello",
            "application/grpc+proto",
            "world",
            &buf,
        ) catch |e| {
            std.debug.print("unary error: {}\n", .{e});
            return;
        };
        std.debug.print("unary response: {s}\n", .{resp});
    }

    // Server streaming (send 3 messages, expect 3 echoes)
    {
        const sid = try client.openStream("/helloworld.Greeter/Echo", "application/grpc+proto");
        try client.sendMessage(sid, "alpha");
        try client.sendMessage(sid, "beta");
        try client.sendMessage(sid, "gamma");
        try client.endStream(sid);

        std.debug.print("streaming echoes:\n", .{});
        var buf: [256]u8 = undefined;
        var final_status: ?zix.Grpc.Status = null;
        while (true) {
            const r = client.recvResponse(sid, &buf) catch break;
            switch (r) {
                .data => |d| std.debug.print("  recv: {s}\n", .{d}),
                .status => |stream_status| {
                    std.debug.print("  status: {d} ({s})\n", .{ @intFromEnum(stream_status), @tagName(stream_status) });
                    final_status = stream_status;
                    break;
                },
            }
        }

        if (final_status != .OK) return error.StreamFailed;
    }
}
