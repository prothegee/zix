// Usage:
// zig run examples/udp_server.zig -- --port 9054
//
// The --port flag is only read when allow_args is true. With allow_args false (the default),
// args are ignored and the port is taken from SERVER_PORT below.
//
// To observe broadcast: run two or more udp_client instances simultaneously.
// Each client will receive packets relayed from all other connected clients.

const std = @import("std");
const zix = @import("zix");

// --------------------------------------------------------- //

// The packet type is defined by the application, not by zix.
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
const SERVER_PORT: u16 = 9054;

// Logger config: uncomment this section to add logger
// const LOG_DIR: []const u8  = "./logs";
// const LOG_FILE: []const u8 = "udp";

// fn createLogDir(io: std.Io) void {
//     std.Io.Dir.cwd().createDirPath(io, LOG_DIR) catch {};
// }

// --------------------------------------------------------- //

const MyServer = zix.Udp.Server(Packet);

pub fn main(process: std.process.Init) !void {
    const io = process.io;

    // Uncomment this to add logger (console only, no save_path means no file output):
    // var logger = try zix.Logger.init(std.heap.smp_allocator, .{
    //     .console           = .ALWAYS,
    //     .console_min_level = .INFO,
    // });
    // defer logger.deinit();

    // Uncomment this to add logger with file output (createLogDir must run first):
    // createLogDir(io);
    // var logger = try zix.Logger.init(std.heap.smp_allocator, .{
    //     .save_path      = LOG_DIR,
    //     .save_file      = LOG_FILE,
    //     .save_min_level = .INFO,
    //     .console        = .ALWAYS,
    // });
    // defer logger.deinit();

    // allow_args false: args ignored, port taken from SERVER_PORT. Set true to read --ip / --port.
    var server = try MyServer.init(.{
        .io = io,
        .allocator = std.heap.smp_allocator,
        .ip = SERVER_IP,
        .port = SERVER_PORT,
        .allow_args = false,
        .dispatch_model = .ASYNC, // typed Server is single async loop, only .ASYNC applies
        .endianness = .LITTLE, // must match all clients
        .broadcast = true, // relay each received packet to all connected clients
        .auto_ack = false, // send 0x06 ACK to sender on receipt
        .auto_echo = false, // echo packet back to sender only
        .error_report = false, // send 0x15 NACK on wrong-size datagram
        .conn_timeout_ms = 5000, // silence before a client is treated as disconnected
        .poll_timeout_ms = 2000, // disconnect-check interval
        // .logger = &logger, // uncomment to wire logger
    }, process.minimal.args);
    defer server.deinit();

    try server.run();
}
