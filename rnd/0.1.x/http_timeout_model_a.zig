//! http_timeout_model_a.zig
//! Zig 0.16.1-dev.12+e2d0ed235
//!
//! Option A: Connection Max-Age Timeout (server-enforced, zero threads)
//!
//! Strategy: record a deadline once when the connection is accepted. At the
//! top of each keep-alive iteration, check the clock. If the deadline has
//! passed, break and close the connection.
//!
//! This is a CONNECTION MAX-AGE check, not a per-idle-gap timeout.
//! The deadline is fixed at accept time and never reset. It fires at the
//! first loop iteration boundary AFTER the lifetime has elapsed, meaning
//! the connection closes after the next request completes, not mid-request.
//!
//! Why not a true idle-gap timeout:
//!   The check only runs at the TOP of the loop, before receiveHead(). If the
//!   client goes idle, the server is blocked inside receiveHead() and the check
//!   cannot fire until the next request arrives. Resetting the deadline after
//!   each response (as a per-gap approach would) makes the check permanently
//!   false. The 6-second gap passes inside receiveHead(), not between checks.
//!   To interrupt a blocking read from outside the thread, use model C or D.
//!
//! Covers:
//!   - High-frequency clients that exceed the max connection age and then send
//!     another request (detected at that request's loop boundary)
//!   - Connections where no request ever arrives within the deadline (deadline
//!     fires before the first receiveHead() blocks (see model C for this)
//!
//! Does NOT cover:
//!   - A client that goes idle mid-keep-alive (deadline passes inside the
//!     blocking receiveHead(); the check runs only when receiveHead() exits)
//!   - Handler execution time or slow response drain

const std = @import("std");

// --------------------------------------------------------- //

//
// Connection lifecycle with Option A:
//
//   accept()
//     |
//     v
//   record idle_deadline = now + timeout_ms       <-- set once on accept
//     |
//     +--[ while loop ]-----------------------------+
//     |                                             |
//     |   now >= idle_deadline? --> break (close)   |
//     |                                             |
//     |   receiveHead()  <-- may block here         |
//     |                       interrupt possible    |
//     |   dispatch()                                |
//     |   reset idle_deadline = now + timeout_ms   <-- per idle gap
//     |                                             |
//     +---------------------------------------------+
//     |
//   stream.close()
//

// --------------------------------------------------------- //

const IP: []const u8 = "127.0.0.1";
const PORT: u16 = 9007;
const IDLE_TIMEOUT_MS: u64 = 5_000;

// --------------------------------------------------------- //

fn handleConnection(stream: std.Io.net.Stream, io: std.Io) void {
    defer stream.close(io);

    var buf_read: [4096]u8 = undefined;
    var buf_write: [4096]u8 = undefined;
    var conn_reader = stream.reader(io, &buf_read);
    var conn_writer = stream.writer(io, &buf_write);
    var http_server = std.http.Server.init(&conn_reader.interface, &conn_writer.interface);

    const timeout_dur = std.Io.Clock.Duration{ .raw = std.Io.Duration.fromMilliseconds(IDLE_TIMEOUT_MS), .clock = .real };

    // Deadline is fixed at accept time, never reset.
    // This is a connection max-age check, not a per-idle-gap check.
    const deadline = std.Io.Clock.Timestamp.fromNow(io, timeout_dur);

    while (true) {
        // Fire at the first loop boundary AFTER the connection lifetime has elapsed.
        // If the client is idle, this check cannot fire until receiveHead() returns.
        if (std.Io.Clock.Timestamp.now(io, .real).compare(.gte, deadline)) break;

        var inner_req = http_server.receiveHead() catch |err| {
            if (err == error.HttpConnectionClosing) break;
            if (err == error.ConnectionResetByPeer) break;
            break;
        };

        inner_req.respond("ok", .{}) catch {};
    }
}

// --------------------------------------------------------- //

// Config integration: rename response_timeout_ms -> idle_timeout_ms
// to be honest about what it actually covers.
//
// pub const HttpServerConfig = struct {
//     ...
//     idle_timeout_ms: u32 = 30_000,
//     ...
// };
//
// In handleConnection, replace IDLE_TIMEOUT_MS with cfg.idle_timeout_ms.
// Skip the deadline check entirely when idle_timeout_ms == 0.

// --------------------------------------------------------- //

pub fn main(process: std.process.Init) !void {
    const io = process.io;

    const addr = try std.Io.net.IpAddress.resolve(io, IP, PORT);
    var net_server = try addr.listen(io, .{ .mode = .stream, .reuse_address = true });
    defer net_server.deinit(io);

    std.debug.print("model-a: listening on {s}:{d}\n", .{ IP, PORT });

    while (true) {
        const stream = net_server.accept(io) catch continue;
        handleConnection(stream, io);
    }
}

//
// How to test Model A: Connection Max-Age Timeout
//
// Step 1: run the server.
//   zig run rnd/http_timeout_model_a.zig
//
// Step 2: send two requests with a gap longer than IDLE_TIMEOUT_MS between them.
//   (printf "GET / HTTP/1.1\r\nHost: localhost\r\nConnection: keep-alive\r\n\r\n"; sleep 6; \
//    printf "GET / HTTP/1.1\r\nHost: localhost\r\n\r\n") | nc localhost 9007
//
//   Expected: first request returns "ok". The 6s gap passes inside receiveHead().
//   When the second request arrives, receiveHead() returns, respond() runs, then
//   the loop checks the deadline (now > T+5s) and breaks. Connection closes after
//   the second response, not before.
//
// What is being verified:
//   The deadline is a connection max-age, not a per-idle-gap timer.
//   It fires at the first loop iteration boundary after the lifetime elapsed,
//   which means the connection closes after the next completed request.
//   A client that goes permanently idle holds the thread in receiveHead()
//   indefinitely. Use model C or D to handle that case.
