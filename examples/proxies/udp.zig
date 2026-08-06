//! udp.zig: the upstream behind the zixer udp forward demo. Port: 9113
//!
//! A typed udp server that echoes every packet back to its sender. Behind the
//! forward, the sender it sees is zixer's per-flow socket, not the client, so
//! one client flow looks like one distinct peer to this backend.
//!
//! Site file: examples/proxies/sites/udp.cfg (edge port 9112)
//!
//! Run:
//! zig build zixer-example-udp
//! ./zig-out/bin/zixer-example-udp-<arch>-<os>
//!
//! Through the proxy, with the udp client example aimed at the edge port:
//! ./zig-out/bin/zix-example-udp_client-<arch>-<os> --server-port 9112

const std = @import("std");
const zix = @import("zix");

// --------------------------------------------------------- //

// Must match the client's Packet definition exactly: same field order, same
// types. extern struct guarantees a fixed C ABI layout. This is the same
// definition examples/udp_client.zig uses, so that client can drive this demo.
const Packet = extern struct {
    id: [16]u8,
    packet_type: i32,
    register: u32,
    position: [3]f64,
};

// --------------------------------------------------------- //

const IP: []const u8 = "127.0.0.1";
const PORT: u16 = 9113;

const MyServer = zix.Udp.Server(Packet);

pub fn main(process: std.process.Init) !void {
    // allow_args false: the port stays PORT, so the site cfg upstream address
    // is always the address this backend is on.
    var server = try MyServer.init(.{
        .io = process.io,
        .allocator = std.heap.smp_allocator,
        .ip = IP,
        .port = PORT,
        .allow_args = false,
        .dispatch_model = .ASYNC, // the typed server is one async loop
        .endianness = .LITTLE, // must match the client
        .broadcast = false,
        .auto_ack = false,
        .auto_echo = true, // echo each packet back to whoever sent it
        .error_report = false,
        .conn_timeout_ms = 5000,
        .poll_timeout_ms = 2000,
    }, process.minimal.args);
    defer server.deinit();

    try server.run();
}
