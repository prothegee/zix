//! server_lifecycle_poc.zig
//! Proof of Concept: Controlled Server Lifecycle using Atomic Flags
//! This PoC demonstrates how to avoid 'while (true)' for better stability.

const std = @import("std");

// NOTE:
// - This one is kind of attraction for the approach (in small scale)
const ServerStatus = enum(u8) {
    idle,
    running,
    stopping,
    stopped,
};

const SmartServer = struct {
    status: std.atomic.Value(ServerStatus) = std.atomic.Value(ServerStatus).init(.idle),
    active_connections: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

    pub fn start(self: *SmartServer) !void {
        self.status.store(.running, .release);
        std.debug.print("[Server] Started. Enter 's' to stop gracefully, 'f' for forced exit.\n", .{});

        // Simulating the Accept Loop
        while (self.status.load(.acquire) == .running) {
            // In a real server, this would be net_server.accept()
            // We use a small sleep to simulate waiting for a connection
            std.Thread.sleep(500 * std.time.ns_per_ms);

            if (self.status.load(.acquire) != .running) break;

            const conn_id = self.active_connections.fetchAdd(1, .monotonic);
            std.debug.print("[Accept] New connection #{d} accepted.\n", .{conn_id});

            // Simulate spawning a handler task
            _ = try std.Thread.spawn(.{}, handler, .{ self, conn_id });
        }

        std.debug.print("[Accept] Loop exited. No longer accepting new connections.\n", .{});

        // Wait for active handlers if stopping gracefully
        while (self.active_connections.load(.acquire) > 0) {
            if (self.status.load(.acquire) == .stopped) {
                std.debug.print("[Server] Force exit triggered. Dropping {d} active tasks.\n", .{self.active_connections.load(.acquire)});
                break;
            }
            std.debug.print("[Server] Waiting for {d} tasks to finish...\n", .{self.active_connections.load(.acquire)});
            std.time.sleep(1000 * std.time.ns_per_ms);
        }

        std.debug.print("[Server] Fully stopped.\n", .{});
    }

    // IDK, somehow this kinda useless, but somehow ok
    // wondering elixir beam style.

    pub fn stopGracefully(self: *SmartServer) void {
        std.debug.print("[Signal] Graceful shutdown initiated...\n", .{});
        self.status.store(.stopping, .release);
    }

    pub fn stopForced(self: *SmartServer) void {
        std.debug.print("[Signal] Forced shutdown initiated!\n", .{});
        self.status.store(.stopped, .release);
    }
};

fn handler(server: *SmartServer, id: usize) void {
    defer _ = server.active_connections.fetchSub(1, .release);

    std.debug.print("  [Handler #{d}] Processing request...\n", .{id});

    // Simulate work
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        // If the server is in 'stopped' state, we must abort immediately
        if (server.status.load(.acquire) == .stopped) {
            std.debug.print("  [Handler #{d}] ABORTED (Forced Stop).\n", .{id});
            return;
        }
        std.time.sleep(1000 * std.time.ns_per_ms);
    }

    std.debug.print("  [Handler #{d}] Finished.\n", .{id});
}

pub fn main() !void {
    var server = SmartServer{};

    // Spawn the server in a thread so we can control it from main
    const server_thread = try std.Thread.spawn(.{}, SmartServer.start, .{&server});

    // Simple CLI control loop
    const stdin = std.io.getStdIn().reader();
    var buf: [10]u8 = undefined;
    while (true) {
        const n = try stdin.read(&buf);
        if (n > 0) {
            if (buf[0] == 's') {
                server.stopGracefully();
                break;
            }
            if (buf[0] == 'f') {
                server.stopForced();
                break;
            }
        }
    }

    server_thread.join();
}
