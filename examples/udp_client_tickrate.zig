// A game-client-like UDP example for udp_server_tickrate: sends this client's state
// on an interval, receives the world snapshots the server broadcasts every tick.
//
// Run several instances (each its own process) with distinct --bind-port values to
// observe the tickrate: each client receives every client's state, tickrate times
// per second, regardless of how often anyone sends.

const std = @import("std");
const zix = @import("zix");

// --------------------------------------------------------- //

// Must match the server's Packet definition exactly: same field order, same types.
// extern struct guarantees a fixed C ABI layout, required for cross-language use.
const Packet = extern struct {
    id: [16]u8,
    packet_type: i32,
    register: u32,
    position: [3]f64,
};

// --------------------------------------------------------- //

const SERVER_IP: []const u8 = "127.0.0.1";
const SERVER_PORT: u16 = 9034;
const CLIENT_BIND_PORT: u16 = 9035;
const SEND_INTERVAL_MS: u64 = 1000;

// --------------------------------------------------------- //

const MyClient = zix.Udp.Client(Packet);

// Capture struct passed by value to the concurrent receive task.
// Holds a pointer to client, valid for the process lifetime since main loops forever.
const ReceiveCapture = struct { client: *MyClient };

// Persistent receive task, runs for the client's lifetime alongside the send loop.
// Every received .packet here is one state out of the server's per-tick snapshot,
// this client's own state included.
//
// Note: this function must run in a concurrent task, not in the same loop as send().
//       Calling receiveFeedback() and send() sequentially would cause each to block the other.
fn receiveLoop(cap: ReceiveCapture) void {
    while (true) {
        const fb = cap.client.receiveFeedback() catch |err| {
            std.debug.print("recv error: {}\n", .{err});
            continue;
        };
        switch (fb) {
            .ack => std.debug.print("recv | ACK\n", .{}),
            .nack => std.debug.print("recv | NACK\n", .{}),
            .packet => |snapshot| {
                // The id field is set by the sender: its meaning is the application's responsibility.
                const id_end = std.mem.indexOfScalar(u8, &snapshot.id, 0) orelse snapshot.id.len;
                std.debug.print(
                    "recv | from={s} packet_type={d} register={d} x={d:.4} y={d:.4} z={d:.4}\n",
                    .{ snapshot.id[0..id_end], snapshot.packet_type, snapshot.register, snapshot.position[0], snapshot.position[1], snapshot.position[2] },
                );
            },
        }
    }
}

// --server-ip is example-level: the engine client parser knows --bind-ip / --bind-port /
// --server-port only. A missing value keeps SERVER_IP.
fn parseServerIp(args: std.process.Args) []const u8 {
    // std.process.Args.Iterator is POSIX-only in Zig 0.16: on Windows the flag is
    // skipped and the default applies, same as the engine's own arg handling.
    if (comptime @import("builtin").target.os.tag == .windows) return SERVER_IP;

    var it = std.process.Args.Iterator.init(args);
    _ = it.skip();
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--server-ip")) {
            if (it.next()) |value| return value;
        }
    }

    return SERVER_IP;
}

// Usage (build once, then run the binary, every flag optional):
// zig build example-udp_client_tickrate
// ./zig-out/bin/udp_client_tickrate --bind-ip 127.0.0.1 --bind-port 9035 --server-ip 127.0.0.1 --server-port 9034
// ./zig-out/bin/udp_client_tickrate --bind-port 9036
//
// --bind-ip / --bind-port / --server-port are engine flags (allow_args), --server-ip
// is read by this example. Each extra instance needs its own --bind-port.
pub fn main(process: std.process.Init) !void {
    const io = process.io;

    var client = try MyClient.init(.{
        .ip = parseServerIp(process.minimal.args),
        .server_port = SERVER_PORT,
        .bind_port = CLIENT_BIND_PORT,
        .allow_args = true, // engine reads --bind-ip / --bind-port / --server-port
        .endianness = .LITTLE, // must match the server, else silent data corruption
    }, io, process.minimal.args);
    defer client.deinit();

    // Spawn the receive loop as a concurrent task so it runs alongside the send loop.
    // receiveFeedback() is blocking: without concurrency it would stall the send loop.
    _ = io.concurrent(receiveLoop, .{ReceiveCapture{ .client = &client }}) catch |err| {
        std.debug.print("recv task spawn error: {}\n", .{err});
    };

    // PRNG seeded from clock, used here only for example position data.
    // In real usage, populate the packet fields from your application's data source.
    const prng_ts = std.Io.Clock.Timestamp.now(io, .awake);
    const prng_seed: u64 = @truncate(@as(u128, @bitCast(@as(i128, prng_ts.raw.nanoseconds))));
    var prng = std.Random.DefaultPrng.init(prng_seed);
    const rng = prng.random();

    // Build the client's identity in the id field.
    // The server does not set or modify this field: it is the sender's responsibility.
    // Here we embed the bind port so each running instance is distinguishable in logs.
    var my_id: [16]u8 = @splat(0);
    _ = std.fmt.bufPrint(&my_id, "client-{d}", .{client.config.bind_port}) catch {};

    while (true) {
        const state = Packet{
            .id = my_id,
            .packet_type = 1,
            .register = 42,
            // Random position in [-1.0, 1.0) representing movement (example data only).
            .position = .{
                rng.float(f64) * 2.0 - 1.0,
                rng.float(f64) * 2.0 - 1.0,
                rng.float(f64) * 2.0 - 1.0,
            },
        };

        client.send(state) catch |err| {
            std.debug.print("send error: {}\n", .{err});
        };

        std.debug.print(
            "sent | packet_type={d} register={d} x={d:.4} y={d:.4} z={d:.4}\n",
            .{ state.packet_type, state.register, state.position[0], state.position[1], state.position[2] },
        );

        try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(@as(i64, @intCast(SEND_INTERVAL_MS))), .awake);
    }
}
