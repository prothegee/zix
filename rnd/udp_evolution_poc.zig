//! udp_evolution_poc.zig
//! Implementation reflecting Lifecycle Control and Explicit Management.

const std = @import("std");

const Status = enum(u8) { idle, running, stopping, stopped };

const Packet = struct {
    data: [1024]u8,
    len: usize,
    from: std.Io.net.IpAddress,
};

// Context with explicit naming to avoid "magic" lifetime confusion.
const Context = struct {
    io: std.Io,
    // Explicitly named for the single-packet lifecycle.
    packet_arena: std.mem.Allocator,
    server: *UdpServer,
};

const HandlerFn = *const fn (ctx: *Context, pkt: *const Packet) anyerror!void;

const UdpServer = struct {
    status: std.atomic.Value(Status) = std.atomic.Value(Status).init(.idle),
    socket: ?std.Io.net.Socket = null,
    handler: HandlerFn,

    // Inits server with a provided handler.
    pub fn init(handler: HandlerFn) UdpServer {
        return .{ .handler = handler };
    }

    // Stops the loop via atomic flag.
    pub fn stop(self: *UdpServer) void {
        self.status.store(.stopping, .release);
    }

    // Main loop reflecting GMOD-2 and UDP Rethink.
    pub fn run(self: *UdpServer, io: std.Io, ip: []const u8, port: u16) !void {
        const addr = try std.Io.net.IpAddress.parse(ip, port);
        const socket = try addr.bind(io, .{ .mode = .dgram, .protocol = .udp });
        self.socket = socket;
        defer socket.close(io);

        self.status.store(.running, .release);
        std.debug.print("zix-poc: listening on {s}:{d}\n", .{ ip, port });

        // Using a short timeout to allow the atomic check to "breathe".
        const poll_timeout: std.Io.Timeout = .{ .duration = .{
            .raw = std.Io.Duration.fromMilliseconds(500),
            .clock = .real,
        } };

        var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
        defer arena.deinit();

        // RE-EVALUATED LOOP: Checks status instead of 'true'.
        while (self.status.load(.acquire) == .running) {
            _ = arena.reset(.retain_capacity);
            var buf: [1024]u8 = undefined;

            // receiveTimeout returns error.Timeout if no packets arrive.
            const msg = socket.receiveTimeout(io, &buf, poll_timeout) catch |err| {
                if (err == error.Timeout) {
                    std.debug.print("poc: timeout (auto-stopping for test)\n", .{});
                    self.stop();
                    continue;
                }
                return err;
            };

            const pkt = Packet{
                .data = buf,
                .len = msg.data.len,
                .from = msg.from,
            };

            var ctx = Context{
                .io = io,
                .packet_arena = arena.allocator(),
                .server = self,
            };

            // Process packet.
            try self.handler(&ctx, &pkt);
        }

        self.status.store(.stopped, .release);
        std.debug.print("zix-poc: server stopped cleanly.\n", .{});
    }
};

// -- Usage Example --

fn echoHandler(ctx: *Context, pkt: *const Packet) !void {
    // Explicit use of packet_arena.
    const msg = try ctx.packet_arena.dupe(u8, pkt.data[0..pkt.len]);
    std.debug.print("poc: received '{s}' from {}\n", .{ msg, pkt.from });

    // Logic: stop if we receive "shutdown".
    if (std.mem.eql(u8, msg, "shutdown")) {
        ctx.server.stop();
    }
}

pub fn main(process: std.process.Init) !void {
    var server = UdpServer.init(echoHandler);
    try server.run(process.io, "127.0.0.1", 9999);
}
