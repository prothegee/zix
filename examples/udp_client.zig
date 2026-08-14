// Run multiple instances with different --bind-port values to observe broadcast.
// Each client will receive packets relayed from all other connected clients.

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
const SERVER_PORT: u16 = 9054;
const CLIENT_BIND_PORT: u16 = 9056;
const SEND_INTERVAL_MS: u64 = 1000;

// --------------------------------------------------------- //

const MyClient = zix.Udp.Client(Packet);

// Capture struct passed by value to the concurrent receive task.
// Holds a pointer to client, valid for the process lifetime since main loops forever.
const ReceiveCapture = struct { client: *MyClient };

// Persistent receive task, runs for the client's lifetime alongside the send loop.
// Yields FeedbackResult(Packet): .ack, .nack, or .packet (echo or broadcast relay).
//
// Note: this function must run in a concurrent task, not in the same loop as send().
//       Calling receiveFeedback() and send() sequentially would cause each to block the other.
fn receiveLoop(cap: ReceiveCapture) void {
    while (true) {
        const feedback = cap.client.receiveFeedback() catch |err| {
            std.debug.print("recv error: {}\n", .{err});
            continue;
        };
        switch (feedback) {
            .ack => std.debug.print("recv | ACK\n", .{}),
            .nack => std.debug.print("recv | NACK\n", .{}),
            .packet => |relayed| {
                // The id field is set by the sender: its meaning is the application's responsibility.
                // With broadcast enabled on the server, this packet originated from another client.
                const id_end = std.mem.indexOfScalar(u8, &relayed.id, 0) orelse relayed.id.len;
                std.debug.print(
                    "recv | from={s} packet_type={d} register={d} x={d:.4} y={d:.4} z={d:.4}\n",
                    .{ relayed.id[0..id_end], relayed.packet_type, relayed.register, relayed.position[0], relayed.position[1], relayed.position[2] },
                );
            },
        }
    }
}

// --------------------------------------------------------- //

// Usage (build once, then run the binary, every flag optional):
// zig build example-udp_client
// ./zig-out/bin/udp_client --bind-port 9056 --server-port 9054
// ./zig-out/bin/udp_client --bind-port 9057 --server-port 9054
//
// --bind-ip / --bind-port / --server-port are engine flags (allow_args). A missing
// flag keeps the default. Each extra instance needs its own --bind-port.
pub fn main(process: std.process.Init) !void {
    const io = process.io;

    var client = try MyClient.init(.{
        .ip = SERVER_IP,
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
    // Use a stable, unique value per client (user ID, device serial, session token, etc.).
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
