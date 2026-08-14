// A game-server-like UDP example: clients send their state whenever they want, the
// server keeps only the latest state per client, and a fixed tick loop broadcasts a
// world snapshot (every stored state, one datagram each) to every connected client
// once per tick. Tickrate is snapshots per second: 64 and 128 are common rates.
//
// The receive path is zix.Udp.Raw, the tick loop is this example's own concurrent
// task. Both share the client registry under a mutex, the tick loop holds the lock
// only while copying the slots, never while sending.
//
// To observe: run two or more udp_client_tickrate instances with distinct
// --bind-port values. Each receives every client's state, tickrate times per second.

const std = @import("std");
const zix = @import("zix");

// --------------------------------------------------------- //

// Must match the client's Packet definition exactly: same field order, same types.
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
const DEFAULT_TICKRATE: u32 = 64;
// One registry slot per connected client, a full registry drops new senders.
const MAX_CLIENTS: usize = 64;
// Milliseconds of silence before a client slot is freed (same default as zix.Udp.Server).
const CONN_TIMEOUT_MS: i64 = 5000;

// --------------------------------------------------------- //

const ClientSlot = struct {
    used: bool = false,
    addr: std.Io.net.IpAddress = undefined,
    state: [@sizeOf(Packet)]u8 = undefined,
    last_seen: std.Io.Clock.Timestamp = undefined,
};

// Shared between the receive handler and the tick task. The mutex guards every slot
// access. io and tick_ns are set once in main before the server runs.
const World = struct {
    mutex: std.Io.Mutex = .init,
    slots: [MAX_CLIENTS]ClientSlot = @splat(ClientSlot{}),
    io: std.Io = undefined,
    tick_ns: u64 = 0,
};

var world: World = .{};

// The receive path: store the sender's latest state, nothing is sent from here (the
// tick loop is the only sender, so the sink stays unused). A datagram that is not
// exactly Packet-sized is dropped, same guard as the typed server.
fn handler(datagram: []const u8, peer: *const std.Io.net.IpAddress, sink: *zix.Udp.Sink) void {
    _ = sink;

    if (datagram.len != @sizeOf(Packet)) return;

    const now = std.Io.Clock.Timestamp.now(world.io, .awake);

    world.mutex.lockUncancelable(world.io);
    defer world.mutex.unlock(world.io);

    // known client: refresh state and last_seen
    for (&world.slots) |*slot| {
        if (slot.used and slot.addr.eql(peer)) {
            @memcpy(&slot.state, datagram);
            slot.last_seen = now;

            return;
        }
    }

    // new client: claim the first free slot, a full registry drops the datagram
    for (&world.slots) |*slot| {
        if (!slot.used) {
            slot.used = true;
            slot.addr = peer.*;
            slot.last_seen = now;
            @memcpy(&slot.state, datagram);

            return;
        }
    }
}

const TickServer = zix.Udp.Raw(handler);

// Capture struct passed by value to the concurrent tick task. The socket is the tick
// loop's own send socket (the engine owns the receive socket and does not expose it).
const TickCapture = struct { io: std.Io, socket: std.Io.net.Socket };

// The tick loop: every 1/tickrate seconds, prune silent clients, copy the live slots
// under the lock, then send every state to every client outside the lock.
fn tickLoop(cap: TickCapture) void {
    const io = cap.io;

    var receivers: [MAX_CLIENTS]std.Io.net.IpAddress = undefined;
    var states: [MAX_CLIENTS][@sizeOf(Packet)]u8 = undefined;

    while (true) {
        std.Io.sleep(io, std.Io.Duration.fromNanoseconds(@intCast(world.tick_ns)), .awake) catch return;

        const now = std.Io.Clock.Timestamp.now(io, .awake);

        // copy window: keep the lock only while reading the slots
        var count: usize = 0;
        world.mutex.lockUncancelable(io);
        for (&world.slots) |*slot| {
            if (!slot.used) continue;
            if (std.Io.Clock.Timestamp.durationTo(slot.last_seen, now).raw.toMilliseconds() >= CONN_TIMEOUT_MS) {
                slot.used = false;
                continue;
            }
            receivers[count] = slot.addr;
            states[count] = slot.state;
            count += 1;
        }
        world.mutex.unlock(io);

        if (count == 0) continue;

        // one world snapshot per tick: every live state goes to every live client
        for (receivers[0..count]) |*receiver| {
            for (states[0..count]) |*state| {
                cap.socket.send(io, receiver, state) catch {};
            }
        }
    }
}

// --tickrate is example-level: the engine has no tick concept (--ip / --port stay
// engine-parsed). A missing, zero, or unparseable value falls back to DEFAULT_TICKRATE.
fn parseTickrate(args: std.process.Args) u32 {
    // std.process.Args.Iterator is POSIX-only in Zig 0.16: on Windows the flag is
    // skipped and the default applies, same as the engine's own arg handling.
    if (comptime @import("builtin").target.os.tag == .windows) return DEFAULT_TICKRATE;

    var it = std.process.Args.Iterator.init(args);
    _ = it.skip();
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--tickrate")) {
            if (it.next()) |value| {
                const parsed = std.fmt.parseInt(u32, value, 10) catch return DEFAULT_TICKRATE;

                return if (parsed == 0) DEFAULT_TICKRATE else parsed;
            }
        }
    }

    return DEFAULT_TICKRATE;
}

// Usage (build once, then run the binary, every flag optional):
// zig build example-udp_server_tickrate
// ./zig-out/bin/udp_server_tickrate --ip 127.0.0.1 --port 9034 --tickrate 64
// ./zig-out/bin/udp_server_tickrate --tickrate 128
//
// --ip / --port are engine flags (allow_args), --tickrate is read by this example.
pub fn main(process: std.process.Init) !void {
    const io = process.io;

    const tickrate = parseTickrate(process.minimal.args);

    var server = try TickServer.init(.{
        .io = io,
        .allocator = std.heap.smp_allocator,
        .ip = SERVER_IP,
        .port = SERVER_PORT,
        .allow_args = true, // engine reads --ip / --port
        .dispatch_model = .ASYNC, // portable single worker, .EPOLL / .URING are Linux-only
    }, process.minimal.args);
    defer server.deinit();

    world.io = io;
    world.tick_ns = 1_000_000_000 / @as(u64, tickrate);

    // The tick loop sends from its own socket, bound to the server ip with port 0 so
    // the kernel picks a free source port. Clients receive on their bound port and do
    // not filter by source, so snapshots from this socket reach them.
    const send_addr = try std.Io.net.IpAddress.parse(server.config.ip, 0);
    const send_socket = try send_addr.bind(io, .{ .mode = .dgram, .protocol = .udp });
    defer send_socket.close(io);

    _ = io.concurrent(tickLoop, .{TickCapture{ .io = io, .socket = send_socket }}) catch |err| {
        std.log.err("tick task spawn error: {}", .{err});

        return err;
    };

    std.log.info("tickrate {d} (one snapshot every {d} ns)", .{ tickrate, world.tick_ns });

    try server.run();
}
