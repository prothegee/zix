// Usage:
// zig run examples/udp_raw_echo.zig -- --port 9064
//
// A raw-bytes UDP echo server (ADR-049). Unlike zix.Udp.Server(Packet), there is no fixed packet
// struct: the handler receives the datagram bytes as-is, the peer address, and a Sink to reply
// through. Replies are coalesced and leave as one sendmmsg per received batch.
//
// Test it with the standard udp client tools, for example:
//   printf 'hello' | nc -u -w1 127.0.0.1 9064

const std = @import("std");
const zix = @import("zix");

// --------------------------------------------------------- //

const SERVER_IP: []const u8 = "127.0.0.1";
const SERVER_PORT: u16 = 9064;

// --------------------------------------------------------- //

// The raw handler: echo the datagram straight back to its sender.
// No struct decoding, no endianness, no auto-ack. You own the bytes.
fn handler(datagram: []const u8, peer: *const std.Io.net.IpAddress, sink: *zix.Udp.Sink) void {
    _ = peer;
    sink.reply(datagram);
}

const EchoServer = zix.Udp.Raw(handler);

pub fn main(process: std.process.Init) !void {
    const io = process.io;

    var server = try EchoServer.init(.{
        .io = io,
        .allocator = std.heap.smp_allocator,
        .ip = SERVER_IP,
        .port = SERVER_PORT,
        .port_mode = .REQUIRED,

        // Dispatch model selects the worker shape, shown explicitly even though .ASYNC is the
        // default. .ASYNC / .POOL / .MIXED run a single recvmmsg worker. .EPOLL / .URING run one
        // SO_REUSEPORT worker per CPU (per-core shared-nothing, the kernel load-balances datagrams).
        .dispatch_model = .ASYNC,

        // Batched syscalls: up to 32 datagrams per recvmmsg, replies coalesced per sendmmsg.
        .recv_batch = 32,
        .send_batch = 32,

        // Variable-length datagrams up to the common Ethernet MTU.
        .max_recv_buf = 1500,
    });
    defer server.deinit();

    try server.run();
}
