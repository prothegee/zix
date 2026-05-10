//! http_timeout_model_d.zig
//! Zig 0.16.1-dev.12+e2d0ed235
//!
//! Option D -- Shared Timer Thread + Connection Registry
//!
//! Strategy: the server maintains a registry of active connections and their
//! deadlines. The existing timer thread (already running for the date cache)
//! calls registry.evict() each tick. evict() scans the list and calls
//! stream.shutdown(.both) on any connection whose deadline has passed.
//!
//! Compared to Option C (watchdog per connection):
//!   - One timer thread handles all connections instead of one per connection
//!   - Lower thread count under load
//!   - Eviction granularity = timer interval (500ms), not exact to the ms
//!   - More complexity: handleConnection must register/deregister; registry
//!     needs a mutex
//!
//! Covers (same as C):
//!   - Slow initial connect
//!   - Keep-alive idle gaps
//!   - Slow response drain
//!
//! Does NOT cover (same as C):
//!   - Handler blocking on non-socket I/O
//!   - Currently blocking readv() -- shutdown() affects the next read,
//!     not one already in progress
//!
//! Cost:
//!   0 extra threads (reuses timer thread).
//!   Per-accept: 2 mutex lock/unlock pairs (register + deregister).
//!   Per timer tick (500ms): 1 mutex lock + O(n) scan over active connections.
//!   Memory: one ConnEntry per active connection in smp_allocator.

const std = @import("std");

// --------------------------------------------------------- //

//
// Registry lifecycle with Option D:
//
//   Server starts
//     |
//     +-- spawn timer thread (timerLoop)
//     |
//   accept()
//     |
//     v
//   ConnEntry { stream, deadline, done=false }
//   registry.register(&entry)          <-- mutex lock/unlock
//     |
//     v
//   handleConnection loop
//     |
//     +-- receiveHead() / dispatch() / send()
//     |
//     |        [every 500ms, timer thread]
//     |        registry.evict()
//     |          for each entry:
//     |            if !done and now >= deadline:
//     |              stream.shutdown(.both)
//     |
//   loop exit
//     |
//   defer registry.deregister(&entry)  <-- marks done=true, removes from list
//     |
//   stream.close()
//

// --------------------------------------------------------- //

const IP: []const u8 = "127.0.0.1";
const PORT: u16 = 9007;
const CONN_TIMEOUT_MS: u64 = 5_000;
const TIMER_INTERVAL_MS: u64 = 500;

// --------------------------------------------------------- //

const ConnEntry = struct {
    stream: std.Io.net.Stream,
    deadline: std.Io.Clock.Timestamp,
    // Set to true by deregister() before removal.
    // evict() reads this to skip entries being concurrently removed.
    done: std.atomic.Value(bool) = .init(false),
};

const ConnRegistry = struct {
    mutex: std.Io.Mutex = .init,
    // Unordered list -- swapRemove on deregister is O(1).
    // evict() does a full O(n) scan each tick; acceptable for typical
    // connection counts (hundreds, not millions).
    entries: std.ArrayListUnmanaged(*ConnEntry) = .empty,

    fn register(self: *ConnRegistry, entry: *ConnEntry, io: std.Io) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        // Allocation failure: drop silently -- connection proceeds without
        // timeout protection rather than being rejected.
        self.entries.append(std.heap.smp_allocator, entry) catch {};
    }

    fn deregister(self: *ConnRegistry, entry: *ConnEntry, io: std.Io) void {
        // Mark done first so evict() skips this entry even if it holds the
        // mutex between our store and our removal from the list.
        entry.done.store(true, .release);

        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        for (self.entries.items, 0..) |e, i| {
            if (e == entry) {
                _ = self.entries.swapRemove(i);
                break;
            }
        }
    }

    // Called by the timer thread every TIMER_INTERVAL_MS.
    // Scans all entries and shuts down those whose deadline has passed.
    fn evict(self: *ConnRegistry, io: std.Io) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        const now = std.Io.Clock.Timestamp.now(io, .real);
        for (self.entries.items) |e| {
            if (!e.done.load(.acquire) and now.compare(.gte, e.deadline)) {
                e.stream.shutdown(io, .both) catch {};
            }
        }
    }

    fn deinit(self: *ConnRegistry) void {
        self.entries.deinit(std.heap.smp_allocator);
    }
};

// --------------------------------------------------------- //

var g_registry = ConnRegistry{};

fn timerLoop(io: std.Io) void {
    while (true) {
        // Reuse existing 500ms date-cache timer tick to drive eviction.
        // No additional thread needed.
        g_registry.evict(io);
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(TIMER_INTERVAL_MS), .awake) catch break;
    }
}

// --------------------------------------------------------- //

fn handleConnection(stream: std.Io.net.Stream, io: std.Io) void {
    defer stream.close(io);

    var entry = ConnEntry{
        .stream = stream,
        .deadline = std.Io.Clock.Timestamp.fromNow(
            io,
            std.Io.Clock.Duration{ .raw = std.Io.Duration.fromMilliseconds(CONN_TIMEOUT_MS), .clock = .real },
        ),
    };
    g_registry.register(&entry, io);
    defer g_registry.deregister(&entry, io);

    var buf_read: [4096]u8 = undefined;
    var buf_write: [4096]u8 = undefined;
    var conn_reader = stream.reader(io, &buf_read);
    var conn_writer = stream.writer(io, &buf_write);
    var http_server = std.http.Server.init(&conn_reader.interface, &conn_writer.interface);

    while (true) {
        var inner_req = http_server.receiveHead() catch |err| {
            if (err == error.HttpConnectionClosing) break;
            if (err == error.ConnectionResetByPeer) break;
            // ReadFailed: covers shutdown(.both) from evict() causing the
            // next read to fail.
            if (err == error.ReadFailed) break;
            break;
        };

        inner_req.respond("ok", .{}) catch {};
    }
}

// --------------------------------------------------------- //

// Integration into HttpServerImpl:
//
//   const Self = @This();
//   registry: ConnRegistry = .{},    <-- added field
//
//   fn timerLoop(io: std.Io, server: *Self) void {
//       while (true) {
//           updateDateCache(io);
//           server.registry.evict(io);   <-- added
//           std.Io.sleep(...) catch break;
//       }
//   }
//
//   fn handleConnection(..., server: *Self) void {
//       ...
//       var entry = ConnEntry{ ... };
//       server.registry.register(&entry, io);
//       defer server.registry.deregister(&entry, io);
//       ...
//   }
//
// ConnRegistry is embedded in the server struct -- no separate allocation.
// The timer thread already has a *Self pointer after the refactor, so
// passing server to timerLoop is the only signature change.

// --------------------------------------------------------- //

pub fn main(process: std.process.Init) !void {
    const io = process.io;

    const addr = try std.Io.net.IpAddress.resolve(io, IP, PORT);
    var net_server = try addr.listen(io, .{ .mode = .stream, .reuse_address = true });
    defer net_server.deinit(io);

    const timer = try std.Thread.spawn(.{}, timerLoop, .{io});
    defer timer.detach();

    std.debug.print("model-d: listening on {s}:{d}\n", .{ IP, PORT });

    while (true) {
        const stream = net_server.accept(io) catch continue;
        handleConnection(stream, io);
    }

    g_registry.deinit();
}

//
// How to test Model D -- Shared Timer Thread + Connection Registry
//
// Note: this main() loop is single-threaded -- it handles one connection at a
// time. While one client is connected, the next queues in the kernel and is
// not accepted until the current connection closes. This is a PoC limitation;
// the real server uses a pool of threads so connections run concurrently.
// Test nc and curl in separate steps, not simultaneously.
//
// Also note TIMER_INTERVAL_MS = 500, so eviction granularity is 500ms.
// A connection that expires at T+5s may be shut down anywhere between
// T+5.0s and T+5.5s depending on when the timer last ticked.
//
// Step 1: run the server.
//   zig run rnd/http_timeout_model_d.zig
//
// Test A -- slow client (never sends headers):
//   nc localhost 9007
//   (just wait; do not type anything)
//   Pressing Enter in nc sends \n which is not a complete HTTP request --
//   the server keeps waiting for \r\n\r\n; nothing is sent back. This is normal.
//   Expected: nc exits within ~5.5s (5s deadline + up to 500ms timer granularity)
//
//   Confirm timing:
//   time nc localhost 9007
//   Expected: real 0m5.0s to 0m5.5s
//
// Test B -- multiple concurrent slow clients:
//   for i in 1 2 3 4 5; do nc localhost 9007 & done
//   Expected: all 5 exit within the same ~3.5s window.
//   This shows the single timer thread evicting all of them in one scan,
//   unlike model C which would have 5 separate watchdog threads sleeping.
//
// Test C -- normal connection (completes before timeout):
//   curl http://localhost:9007/
//   Expected: responds immediately; deregister() removes the entry before
//   the timer ever sees it as expired.
//
// What is being verified:
//   One timer thread evicts all stale connections. The eviction window is
//   [deadline, deadline + TIMER_INTERVAL_MS]. For exact-ms accuracy use
//   model C instead. For lower thread count under many connections, model D
//   is preferable.
