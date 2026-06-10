//! UDP PoC Server — rnd only, not part of src/
//! Zig 0.16.x
//!
//! Usage: zig run rnd/udp_server.zig -- [--port <port>]
//!        --port  bind port (default: 9100)
//!
//! Note: concurrency model uses process.Init / io.concurrent()
//!       should be configurable later (e.g. std.Thread.spawn for constrained envs)
//!
//! Note: endianness is native-endian
//!       must be explicitly configured for cross-language support later

const std = @import("std");

// --------------------------------------------------------- //

// Note: native-endian layout, must match client and any foreign client (Go, C++, Rust, etc.)
// Note: 'packet_type' maps to `int type` in spec — 'type' is a Zig keyword
const TestPacket = extern struct {
    id: [16]u8,
    packet_type: i32,
    register: u32,
    position: [3]f64,
};

// --------------------------------------------------------- //

// NOTE (src/): port must be governed by an explicit mode, represented as enum(u8):
//   - CONFIGURABLE: port is passed via CLI args, exit with error.PortNotConfigured if args absent
//   - REQUIRED: port is set manually in the config struct, exit with error.PortNotConfigured if unset (0)
//   Both modes fail if the port is not provided — the distinction is the source, not the behavior.
//   No silent defaults in either mode. Enforces "explicit over implicit."
const ServerConfig = struct {
    ip: []const u8 = "127.0.0.1",
    port: u16 = 9100,
    auto_ack: bool = false, // send 0x06 ACK byte back to sender on success
    error_report: bool = false, // send 0x15 NACK byte back to sender on bad packet
    // Note: if auto_echo is true, echoes the received packet as-is back to sender only
    //       feedback shape (e.g. result struct) should be configurable later
    auto_echo: bool = false,
    // Note: if broadcast is true, relays the received packet to ALL connected clients
    //       server stamps the sender's connection index into the id field before relaying —
    //       receivers use the id to distinguish which peer sent the data
    broadcast: bool = true,
};

// --------------------------------------------------------- //

// Note: UDP has no connection state — the server cannot know a client is gone until silence.
//       Disconnect detection is purely timeout-based. Worst-case detection delay is
//       DISCONNECT_TIMEOUT_MS + POLL_TIMEOUT_MS (currently ~7s). Lower DISCONNECT_TIMEOUT_MS
//       to reduce the window, there is no OS-level signal to hook into (unlike TCP FIN).
const DISCONNECT_TIMEOUT_MS: i64 = 5000;
const POLL_TIMEOUT_MS: i64 = 2000;

// Explicit cap for broadcast snapshot — avoids heap allocation in PacketTask.
// In src/: use a heap-allocated slice (arena per packet) to remove the hard limit.
// SECURITY: clients beyond this cap are silently excluded from receiving broadcasts.
const MAX_BROADCAST_CLIENTS: usize = 64;

// --------------------------------------------------------- //

// Captures all state needed by processPacket — copy semantics, safe across concurrent tasks.
// Note: socket handle is shared across concurrent tasks, send on UDP is kernel-atomic per datagram
// Note: peers[] is a snapshot of connected client addresses taken at receive time
//       avoids sharing the mutable ClientRecord list across concurrent tasks
// PERF: peers[MAX_BROADCAST_CLIENTS] is copied by value into every PacketTask — grows with
//       IpAddress size * MAX_BROADCAST_CLIENTS, reduce cap or switch to heap slice in src/
const PacketTask = struct {
    buf: [@sizeOf(TestPacket)]u8,
    from: std.Io.net.IpAddress,
    socket: std.Io.net.Socket,
    io: std.Io,
    config: ServerConfig,
    peers: [MAX_BROADCAST_CLIENTS]std.Io.net.IpAddress,
    n_peers: usize,
    sender_index: usize,
};

// Note: index is a monotonic connection counter assigned at first packet from this address.
//       It is a PoC-only identity — not stable across reconnects, not collision-safe.
// Note: when identifying clients, how the id is structured, validated, and scoped is the
//       application's responsibility. The transport layer only assigns a transient index.
const ClientRecord = struct {
    from: std.Io.net.IpAddress,
    last_seen: std.Io.Clock.Timestamp,
    index: usize,
};

// --------------------------------------------------------- //

fn fmtAddr(from: std.Io.net.IpAddress, buf: []u8) []const u8 {
    return switch (from) {
        .ip4 => |a| std.fmt.bufPrint(buf, "{d}.{d}.{d}.{d}:{d}", .{
            a.bytes[0], a.bytes[1], a.bytes[2], a.bytes[3], a.port,
        }) catch "?",
        .ip6 => "ipv6",
    };
}

fn checkDisconnections(clients: *std.array_list.Managed(ClientRecord), now: std.Io.Clock.Timestamp) void {
    var i: usize = 0;
    while (i < clients.items.len) {
        const elapsed_ms = std.Io.Clock.Timestamp.durationTo(clients.items[i].last_seen, now).raw.toMilliseconds();
        if (elapsed_ms >= DISCONNECT_TIMEOUT_MS) {
            var buf: [64]u8 = undefined;
            const addr_str = fmtAddr(clients.items[i].from, &buf);
            const idx = clients.items[i].index;
            _ = clients.swapRemove(i);
            std.debug.print("client disconnected: {s} [index: {d}, connected: {d}]\n", .{ addr_str, idx, clients.items.len });
        } else {
            i += 1;
        }
    }
}

fn processPacket(task: PacketTask) void {
    const pkt: TestPacket = @bitCast(task.buf);

    var addr_buf: [64]u8 = undefined;
    std.debug.print(
        "recv from={s} [index: {d}] | packet_type={d} register={d} x={d:.4} y={d:.4} z={d:.4}\n",
        .{ fmtAddr(task.from, &addr_buf), task.sender_index, pkt.packet_type, pkt.register, pkt.position[0], pkt.position[1], pkt.position[2] },
    );

    if (task.config.auto_ack) {
        task.socket.send(task.io, &task.from, &[_]u8{0x06}) catch |err| {
            std.debug.print("ack error: {}\n", .{err});
        };
    }

    if (task.config.auto_echo) {
        task.socket.send(task.io, &task.from, &task.buf) catch |err| {
            std.debug.print("echo error: {}\n", .{err});
        };
    }

    if (task.config.broadcast) {
        // stamp sender's connection index into id field so receivers can differentiate peers
        var stamped: TestPacket = @bitCast(task.buf);
        stamped.id = [_]u8{0} ** 16;
        _ = std.fmt.bufPrint(&stamped.id, "client-{d}", .{task.sender_index}) catch {};

        // SECURITY: no sender validation — any client (including spoofed IPs) can trigger
        //           a broadcast to all peers, a single bad actor can flood all connected clients
        // PERF: N sequential send() syscalls per packet at high client count + packet rate
        //       this becomes a bottleneck — in src/ consider batching or a dedicated relay thread
        for (task.peers[0..task.n_peers]) |*peer| {
            task.socket.send(task.io, peer, std.mem.asBytes(&stamped)) catch |err| {
                std.debug.print("broadcast error: {}\n", .{err});
            };
        }
    }
}

// --------------------------------------------------------- //

pub fn main(process: std.process.Init) !void {
    const io = process.io;
    var config: ServerConfig = .{};

    var args_it = std.process.Args.Iterator.init(process.minimal.args);
    _ = args_it.skip();
    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--port")) {
            if (args_it.next()) |val| {
                config.port = std.fmt.parseInt(u16, val, 10) catch config.port;
            }
        }
    }

    const addr = try std.Io.net.IpAddress.parse(config.ip, config.port);
    const socket = try addr.bind(io, .{ .mode = .dgram, .protocol = .udp });
    defer socket.close(io);

    std.debug.print("zix udp server: listening on {s}:{d}\n", .{ config.ip, config.port });

    var clients = std.array_list.Managed(ClientRecord).init(std.heap.smp_allocator);
    defer clients.deinit();

    const poll_timeout: std.Io.Timeout = .{ .duration = .{
        .raw = std.Io.Duration.fromMilliseconds(POLL_TIMEOUT_MS),
        .clock = .awake,
    } };

    var last_check = std.Io.Clock.Timestamp.now(io, .awake);
    var next_index: usize = 1; // monotonic counter; 1-based for readable log output

    while (true) {
        var buf: [@sizeOf(TestPacket)]u8 = undefined;

        const msg = socket.receiveTimeout(io, &buf, poll_timeout) catch |err| {
            if (err == error.Timeout) {
                const now = std.Io.Clock.Timestamp.now(io, .awake);
                checkDisconnections(&clients, now);
                last_check = now;
                continue;
            }
            std.debug.print("receive error: {}\n", .{err});
            continue;
        };

        // overflow / size guard — drop any datagram that isn't exactly TestPacket
        if (msg.flags.trunc or msg.data.len != @sizeOf(TestPacket)) {
            if (config.error_report) socket.send(io, &msg.from, &[_]u8{0x15}) catch {};
            std.debug.print("drop: expected {d} bytes, got {d} trunc={}\n", .{ @sizeOf(TestPacket), msg.data.len, msg.flags.trunc });
            continue;
        }

        const now = std.Io.Clock.Timestamp.now(io, .awake);

        // track connected clients, capture sender_index for the task
        var sender_index: usize = 0;
        var known = false;
        for (clients.items) |*r| {
            if (r.from.eql(&msg.from)) {
                r.last_seen = now;
                sender_index = r.index;
                known = true;
                break;
            }
        }
        if (!known) {
            sender_index = next_index;
            next_index += 1;
            clients.append(.{ .from = msg.from, .last_seen = now, .index = sender_index }) catch {};
            var addr_buf: [64]u8 = undefined;
            std.debug.print("client connected: {s} [index: {d}, connected: {d}]\n", .{ fmtAddr(msg.from, &addr_buf), sender_index, clients.items.len });
        }

        // rate-limited disconnect check even when packets arrive rapidly
        if (std.Io.Clock.Timestamp.durationTo(last_check, now).raw.toMilliseconds() >= POLL_TIMEOUT_MS) {
            checkDisconnections(&clients, now);
            last_check = now;
        }

        // snapshot connected client addresses for broadcast — safe to pass by value to concurrent task
        var peers: [MAX_BROADCAST_CLIENTS]std.Io.net.IpAddress = undefined;
        const n_peers = @min(clients.items.len, MAX_BROADCAST_CLIENTS);
        for (0..n_peers) |i| peers[i] = clients.items[i].from;

        const task = PacketTask{
            .buf = buf,
            .from = msg.from,
            .socket = socket,
            .io = io,
            .config = config,
            .peers = peers,
            .n_peers = n_peers,
            .sender_index = sender_index,
        };

        _ = io.concurrent(processPacket, .{task}) catch |err| {
            std.debug.print("concurrent error: {}\n", .{err});
            processPacket(task); // fallback: inline — blocks receive loop
        };
    }
}
