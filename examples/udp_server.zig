// Usage:
//   zig run examples/udp_server.zig -- --port 9100
//
// The --port flag is only read when using initArgs() (CONFIGURABLE mode).
// With init() (REQUIRED mode), the port is taken from SERVER_PORT below.
//
// To observe broadcast: run two or more udp_client instances simultaneously.
// Each client will receive packets relayed from all other connected clients.

const std = @import("std");
const zix = @import("zix");

// --------------------------------------------------------- //

// The packet type is defined by the application — not by zix.
// Must be an extern struct so the memory layout is fixed (C ABI).
// All clients and the server must use the exact same definition.
// 'packet_type' is used instead of 'type' because 'type' is a Zig keyword.
const Packet = extern struct {
    id: [16]u8,
    packet_type: i32,
    register: u32,
    position: [3]f64,
};

// --------------------------------------------------------- //

const SERVER_IP: []const u8 = "127.0.0.1";
const SERVER_PORT: u16 = 9100;

// --------------------------------------------------------- //

const MyServer = zix.Udp.Server(Packet);

pub fn main(process: std.process.Init) !void {
    const io = process.io;

    // REQUIRED mode — port is taken from SERVER_PORT, no CLI arg parsing.
    // To accept --port at runtime instead, replace with:
    //   var server = try MyServer.initArgs(.{
    //       .ip        = SERVER_IP,
    //       .port      = SERVER_PORT, // default fallback if --port is not passed
    //       .port_mode = .CONFIGURABLE,
    //       ...
    //   }, process.minimal.args);
    var server = try MyServer.init(.{
        .allocator = std.heap.smp_allocator,
        .ip = SERVER_IP,
        .port = SERVER_PORT,
        .port_mode = .REQUIRED,

        // Endianness must match all clients.
        // LITTLE is recommended for cross-language use (Go, C++, Rust).
        // Change to .BIG for network byte order (legacy/internet protocols).
        .endianness = .LITTLE,

        // Relay each received packet to all connected clients.
        // Clients use receiveFeedback() to read these relayed packets.
        // SECURITY: any connected client can trigger a broadcast — no sender validation.
        .broadcast = true,

        // Send 0x06 ACK back to sender after each successful receipt.
        // Useful for confirming delivery without echoing the full packet.
        .auto_ack = false,

        // Echo the received packet back to the sender only (not all clients).
        // Independent from broadcast — both can be true simultaneously.
        .auto_echo = false,

        // Send 0x15 NACK to sender when a datagram is the wrong size or truncated.
        .error_report = false,

        // Milliseconds of silence before treating a client as disconnected.
        // Worst-case detection delay: disconnect_timeout_ms + poll_timeout_ms.
        // There is no OS-level disconnect signal for UDP — silence is the only indicator.
        .disconnect_timeout_ms = 5000,

        // How often the receive loop checks for disconnected clients (milliseconds).
        // Lower values = faster detection but more CPU usage when idle.
        .poll_timeout_ms = 2000,
    });
    defer server.deinit();

    try server.run(io);
}
