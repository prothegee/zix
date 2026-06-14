//! http_timeout_model_bd.zig
//! Zig 0.16.1-dev.12+e2d0ed235
//!
//! Combined B + D: the recommended timeout strategy for zix.
//!
//! Two independent layers with distinct responsibilities:
//!
//!   D (network layer): ConnRegistry + timer thread
//!     Protects pool threads from slow or malicious clients that stall
//!     before or during header send. Fires shutdown(.both) on expired
//!     connections unconditionally. Handler does not need to cooperate.
//!     Deadline: CONN_TIMEOUT_MS from accept time.
//!
//!   B (handler layer): ctx.withTimeout / ctx.timedOut
//!     Gives handlers an opt-in execution budget. Handler checks
//!     ctx.timedOut() between steps and responds with 408 early.
//!     Deadline: HANDLER_TIMEOUT_MS, set globally before dispatch.
//!
//! The two layers are orthogonal:
//!   D fires if the client stalls before the handler ever starts.
//!   B fires if the handler takes too long after it starts.
//!   Both can fire independently. neither depends on the other.
//!
//! Integration notes (for src/tcp/http/server.zig):
//!   D: embed ConnRegistry in HttpServerImpl add evict() to timerLoop.
//!   B: add deadline field to Context set from config before dispatch.
//!   Config: replace response_timeout_ms with conn_timeout_ms (D) and
//!           handler_timeout_ms (B) as two distinct fields.

const std = @import("std");

// --------------------------------------------------------- //

const IP: []const u8 = "127.0.0.1";
const PORT: u16 = 9007;

// D: connection-level guard (covers slow/stalled clients).
// Fires shutdown(.both) if the full connection lifetime exceeds this.
const CONN_TIMEOUT_MS: u64 = 10_000;

// B: handler-level budget (covers slow handler execution).
// Handler checks ctx.timedOut() between steps.
const HANDLER_TIMEOUT_MS: u64 = 5_000;

// Timer tick interval for the D registry scan.
const TIMER_INTERVAL_MS: u64 = 500;

// --------------------------------------------------------- //
// Layer B: Context with deadline

pub const Context = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    stream: std.Io.net.Stream = undefined,
    deadline: ?std.Io.Clock.Timestamp = null,

    pub fn withTimeout(self: Context, ms: u64) Context {
        var c = self;
        c.deadline = std.Io.Clock.Timestamp.fromNow(
            self.io,
            std.Io.Clock.Duration{ .raw = std.Io.Duration.fromMilliseconds(@intCast(ms)), .clock = .real },
        );
        return c;
    }

    pub fn withDeadline(self: Context, ts: std.Io.Clock.Timestamp) Context {
        var c = self;
        c.deadline = ts;
        return c;
    }

    pub fn timedOut(self: Context) bool {
        const d = self.deadline orelse return false;
        return std.Io.Clock.Timestamp.now(self.io, .real).compare(.gte, d);
    }

    pub fn remainingMs(self: Context) ?u64 {
        const d = self.deadline orelse return null;
        const ms = d.durationFromNow(self.io).raw.toMilliseconds();
        return if (ms > 0) @intCast(ms) else 0;
    }
};

// --------------------------------------------------------- //
// Layer D: Connection registry + timer eviction

const ConnEntry = struct {
    stream: std.Io.net.Stream,
    deadline: std.Io.Clock.Timestamp,
    done: std.atomic.Value(bool) = .init(false),
};

const ConnRegistry = struct {
    mutex: std.Io.Mutex = .init,
    entries: std.ArrayListUnmanaged(*ConnEntry) = .empty,

    fn register(self: *ConnRegistry, entry: *ConnEntry, io: std.Io) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.entries.append(std.heap.smp_allocator, entry) catch {};
    }

    fn deregister(self: *ConnRegistry, entry: *ConnEntry, io: std.Io) void {
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

    fn evict(self: *ConnRegistry, io: std.Io) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const now = std.Io.Clock.Timestamp.now(io, .real);
        for (self.entries.items) |e| {
            if (!e.done.load(.acquire) and now.compare(.gte, e.deadline))
                e.stream.shutdown(io, .both) catch {};
        }
    }

    fn deinit(self: *ConnRegistry) void {
        self.entries.deinit(std.heap.smp_allocator);
    }
};

// --------------------------------------------------------- //
// Timer thread: drives both date cache and D eviction

var g_registry = ConnRegistry{};

fn timerLoop(io: std.Io) void {
    while (true) {
        g_registry.evict(io);
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(TIMER_INTERVAL_MS), .awake) catch break;
    }
}

// --------------------------------------------------------- //
// Example handler: uses layer B

fn slowHandler(req: *std.http.Server.Request, ctx: *Context) !void {
    // Step 1: simulate 3s of work.
    std.Io.sleep(ctx.io, std.Io.Duration.fromMilliseconds(3_000), .real) catch {};
    if (ctx.timedOut()) {
        std.debug.print("model-bd: handler timed out after step 1\n", .{});
        return req.respond("timeout", .{ .status = .request_timeout });
    }

    // Step 2: simulate another 3s of work (total 6s > 5s budget).
    std.Io.sleep(ctx.io, std.Io.Duration.fromMilliseconds(3_000), .real) catch {};
    if (ctx.timedOut()) {
        std.debug.print("model-bd: handler timed out after step 2\n", .{});
        return req.respond("timeout", .{ .status = .request_timeout });
    }

    std.debug.print("model-bd: handler completed within deadline\n", .{});
    try req.respond("ok", .{});
}

// --------------------------------------------------------- //
// handleConnection: wires both layers

fn handleConnection(stream: std.Io.net.Stream, io: std.Io, allocator: std.mem.Allocator) void {
    defer stream.close(io);

    // Layer D: register with the connection registry.
    // If the client stalls before or during header send, the timer thread
    // fires shutdown(.both) after CONN_TIMEOUT_MS.
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
            if (err == error.ReadFailed) break; // shutdown(.both) from layer D
            break;
        };

        // Layer B: set a global handler deadline before dispatch.
        // Handler checks ctx.timedOut() between expensive steps.
        var ctx = Context{ .io = io, .allocator = allocator, .stream = stream };
        ctx = ctx.withTimeout(HANDLER_TIMEOUT_MS);

        slowHandler(&inner_req, &ctx) catch {};
    }
}

// --------------------------------------------------------- //

pub fn main(process: std.process.Init) !void {
    const io = process.io;
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();

    const addr = try std.Io.net.IpAddress.resolve(io, IP, PORT);
    var net_server = try addr.listen(io, .{ .mode = .stream, .reuse_address = true });
    defer net_server.deinit(io);

    const timer = try std.Thread.spawn(.{}, timerLoop, .{io});
    defer timer.detach();

    std.debug.print("model-bd: listening on {s}:{d} (conn={d}ms, handler={d}ms)\n", .{
        IP, PORT, CONN_TIMEOUT_MS, HANDLER_TIMEOUT_MS,
    });

    while (true) {
        const stream = net_server.accept(io) catch continue;
        handleConnection(stream, io, arena.allocator());
    }

    g_registry.deinit();
}

//
// How to test Model BD: Combined B + D
//
// Note: main() is single-threaded (one connection at a time). Run each
// test independently. Do not connect two clients simultaneously.
//
// Test 1: Layer D (slow client, connection-level guard)
//
//   zig run rnd/http_timeout_model_bd.zig
//
//   nc localhost 9007
//   (send nothing and wait)
//   Expected: nc exits within ~10.5s (CONN_TIMEOUT_MS + up to 500ms jitter)
//
//   time nc localhost 9007
//   Expected: real ~10.0s to 10.5s
//
// Test 2: Layer B (slow handler, execution budget)
//
//   zig run rnd/http_timeout_model_bd.zig
//
//   printf "GET / HTTP/1.1\r\nHost: localhost\r\n\r\n" | nc localhost 9007
//   Expected: HTTP 408 after ~5s, stderr "model-bd: handler timed out after step 2"
//
// Test 3: Both layers independent (D fires before B gets a chance)
//
//   Set CONN_TIMEOUT_MS = 2_000 (less than HANDLER_TIMEOUT_MS = 5_000).
//   Send a valid HTTP request. Layer D shuts down the connection before the
//   handler finishes step 1. receiveHead() or the send inside respond() fails
//   with ReadFailed, connection closes. Handler may or may not complete.
//
//   zig run rnd/http_timeout_model_bd.zig
//   printf "GET / HTTP/1.1\r\nHost: localhost\r\n\r\n" | nc localhost 9007
//   Expected: connection closes abruptly before a response is received.
//
// Test 4: Normal request (both layers idle)
//
//   zig run rnd/http_timeout_model_bd.zig
//
//   Reduce both sleeps in slowHandler to 1_000ms each (total 2s < 5s budget).
//   curl http://localhost:9007/
//   Expected: "ok" in ~2s. Neither D nor B fires.
//
// What is being verified:
//   D and B are orthogonal. D guards the network layer (before handler starts).
//   B guards the handler layer (after handler starts). Setting CONN_TIMEOUT_MS
//   lower than HANDLER_TIMEOUT_MS means D can preempt an in-flight handler.
//   In production, CONN_TIMEOUT_MS should be >= HANDLER_TIMEOUT_MS to avoid this.
