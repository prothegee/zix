//! http_timeout_model_b.zig
//! Zig 0.16.1-dev.12+e2d0ed235
//!
//! Option B -- Context Deadline (cooperative, handler-level)
//!
//! Strategy: add a deadline field to Context. The server optionally sets a
//! global deadline from config before dispatch. Handlers opt in by calling
//! ctx.withTimeout() or checking ctx.timedOut() between steps.
//!
//! Covers:
//!   - Handler execution time when the handler checks ctx.timedOut()
//!   - Any multi-step handler that wants to abort early and send 408
//!
//! Does NOT cover:
//!   - receiveHead() blocking (handler has not started yet)
//!   - Blocking I/O inside a handler (std.Io.sleep, DB, file) -- the handler
//!     will not be interrupted, it notices only on the next explicit check
//!   - Keep-alive idle gaps (use Option A alongside for that)
//!
//! Why cooperative:
//!   There is no cross-platform way to cancel a running Zig function from
//!   outside. The handler must poll the deadline. This mirrors Go's
//!   context.Context pattern.

const std = @import("std");

// --------------------------------------------------------- //

//
// Handler execution with Option B:
//
//   dispatch(req, res, ctx)
//     |
//     v
//   handler starts
//     |
//     +-- step 1: do work
//     |
//     +-- ctx.timedOut()? --> yes --> res.setStatus(408), return
//     |
//     +-- step 2: do more work
//     |
//     +-- ctx.timedOut()? --> yes --> res.setStatus(408), return
//     |
//     +-- res.sendJson(...)
//
//   The server can also set ctx.deadline before calling dispatch,
//   making every handler subject to a global response timeout without
//   any per-handler code change -- handlers that never call timedOut()
//   simply ignore the deadline.
//

// --------------------------------------------------------- //

const IP: []const u8 = "127.0.0.1";
const PORT: u16 = 9007;
const HANDLER_TIMEOUT_MS: u64 = 5_000;

// --------------------------------------------------------- //

pub const Context = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    stream: std.Io.net.Stream = undefined,

    // null = no deadline set, timer check is a no-op
    deadline: ?std.Io.Clock.Timestamp = null,

    // Returns a copy of this context with a deadline set ms from now.
    // Does not modify the original -- caller stores the returned value.
    pub fn withTimeout(self: Context, ms: u64) Context {
        var c = self;
        const dur = std.Io.Clock.Duration{ .raw = std.Io.Duration.fromMilliseconds(@intCast(ms)), .clock = .real };
        c.deadline = std.Io.Clock.Timestamp.fromNow(self.io, dur);
        return c;
    }

    // Returns a copy of this context with an absolute deadline.
    pub fn withDeadline(self: Context, ts: std.Io.Clock.Timestamp) Context {
        var c = self;
        c.deadline = ts;
        return c;
    }

    // True if the deadline has passed. Always false when no deadline is set.
    pub fn timedOut(self: Context) bool {
        const d = self.deadline orelse return false;
        return std.Io.Clock.Timestamp.now(self.io, .real).compare(.gte, d);
    }

    // Milliseconds remaining until the deadline. null if no deadline is set.
    // Returns 0 if the deadline has already passed.
    pub fn remainingMs(self: Context) ?u64 {
        const d = self.deadline orelse return null;
        const dur = d.durationFromNow(self.io);
        const ms = dur.raw.toMilliseconds();
        return if (ms > 0) @intCast(ms) else 0;
    }
};

// --------------------------------------------------------- //

// Example handler: opt-in timeout check between steps.
fn slowHandler(req: *std.http.Server.Request, ctx: *Context) !void {
    const tctx = ctx.withTimeout(HANDLER_TIMEOUT_MS);

    // Simulate step 1.
    std.Io.sleep(ctx.io, std.Io.Duration.fromMilliseconds(3_000), .real) catch {};

    if (tctx.timedOut()) {
        std.debug.print("model-b: timed out after step 1\n", .{});
        try req.respond("timeout", .{ .status = .request_timeout });
        return;
    }

    // Simulate step 2.
    std.Io.sleep(ctx.io, std.Io.Duration.fromMilliseconds(3_000), .real) catch {};

    if (tctx.timedOut()) {
        std.debug.print("model-b: timed out after step 2\n", .{});
        try req.respond("timeout", .{ .status = .request_timeout });
        return;
    }

    std.debug.print("model-b: completed within deadline\n", .{});
    try req.respond("ok", .{});
}

// --------------------------------------------------------- //

fn handleConnection(stream: std.Io.net.Stream, io: std.Io, allocator: std.mem.Allocator) void {
    defer stream.close(io);

    var buf_read: [4096]u8 = undefined;
    var buf_write: [4096]u8 = undefined;
    var conn_reader = stream.reader(io, &buf_read);
    var conn_writer = stream.writer(io, &buf_write);
    var http_server = std.http.Server.init(&conn_reader.interface, &conn_writer.interface);

    while (true) {
        var inner_req = http_server.receiveHead() catch |err| {
            if (err == error.HttpConnectionClosing) break;
            if (err == error.ConnectionResetByPeer) break;
            break;
        };
        var ctx = Context{ .io = io, .allocator = allocator, .stream = stream };

        // Server-level global deadline: set before dispatch so every handler
        // is subject to it without per-handler code. Handlers that never call
        // ctx.timedOut() ignore it silently.
        ctx = ctx.withTimeout(HANDLER_TIMEOUT_MS);

        slowHandler(&inner_req, &ctx) catch {};
    }
}

// --------------------------------------------------------- //

// Config integration: keep response_timeout_ms as the global handler deadline.
//
// Before dispatch:
//   if (cfg.response_timeout_ms > 0)
//       ctx = ctx.withTimeout(cfg.response_timeout_ms);
//
// Handlers that care about the deadline call ctx.timedOut().
// Handlers that do not care get no overhead (null check is a branch on null).

// --------------------------------------------------------- //

pub fn main(process: std.process.Init) !void {
    const io = process.io;
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();

    const addr = try std.Io.net.IpAddress.resolve(io, IP, PORT);
    var net_server = try addr.listen(io, .{ .mode = .stream, .reuse_address = true });
    defer net_server.deinit(io);

    std.debug.print("model-b: listening on {s}:{d}\n", .{ IP, PORT });

    while (true) {
        const stream = net_server.accept(io) catch continue;
        handleConnection(stream, io, arena.allocator());
    }
}

//
// How to test Model B -- Context Deadline (cooperative handler)
//
// No changes needed. The handler is already wired and the constants are
// set so that step 2 crosses the deadline:
//   HANDLER_TIMEOUT_MS = 5_000   (5s total budget)
//   step 1 sleep       = 3_000ms (within budget)
//   step 2 sleep       = 3_000ms (3+3 = 6s, exceeds budget)
//
// Step 1: run the server.
//   zig run rnd/http_timeout_model_b.zig
//
// Step 2: connect from another terminal.
//   printf "GET / HTTP/1.1\r\nHost: localhost\r\n\r\n" | nc localhost 9007
//
//   (curl also works but will hang waiting for an HTTP response since
//   slowHandler only prints to stderr and does not write a response body.)
//
// Step 3: watch stderr output on the server terminal after ~5s.
//   Expected: "model-b: handler timed out after step 2"
//
// To observe the success path (handler finishes within deadline):
//   Reduce one of the sleep durations so both fit within 5s, e.g.:
//     std.Io.sleep(ctx.io, std.Io.Duration.fromMilliseconds(2_000), .real) catch {};
//   Expected: "model-b: handler completed within deadline"
//
// What is being verified:
//   The deadline is NOT enforced by the library -- the handler must call
//   ctx.timedOut() itself. Blocking ops (sleep, DB, file) inside the handler
//   run to completion regardless the check only fires at explicit poll points.
