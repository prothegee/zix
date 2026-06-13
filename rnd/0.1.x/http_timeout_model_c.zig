//! http_timeout_model_c.zig
//! Zig 0.16.1-dev.12+e2d0ed235
//!
//! Option C: Watchdog Thread per Connection
//!
//! Strategy: for each accepted connection, spawn one OS thread (the watchdog).
//! The watchdog sleeps for timeout_ms. If the connection has not finished by
//! then, it calls stream.shutdown(.both), which causes the next read or write
//! on that socket to return an error. The pool thread's receiveHead() or
//! send() sees the error and breaks out of the keep-alive loop.
//!
//! Covers:
//!   - Slow initial connect (client connects but stalls sending headers)
//!   - Slow header send (mid-receiveHead hang, unblocked on next read attempt
//!     after shutdown)
//!   - Keep-alive idle gaps
//!   - Slow response drain (client not consuming response body)
//!
//! Does NOT cover:
//!   - Handler blocking on non-socket I/O (std.Io.sleep, DB, file read):
//!     shutdown() does not interrupt a running handler that is not doing
//!     socket I/O. The handler finishes, then the next receiveHead() fails.
//!   - A currently blocking readv() on Linux: shutdown() does not interrupt
//!     a thread already blocked in readv(). It affects the *next* read.
//!     (POSIX does not guarantee interruption of in-progress syscalls.)
//!
//! Cost:
//!   One extra OS thread per active connection. At 100 concurrent connections
//!   that is 100 watchdog threads sleeping simultaneously (cheap: each consumes
//!   a stack and a futex but no CPU).

const std = @import("std");

// --------------------------------------------------------- //

//
// Per-connection lifecycle with Option C:
//
//   accept()
//     |
//     v
//   WatchdogCtx { stream, done=false, timeout_ms }
//     |
//     +-- std.Thread.spawn(watchdog)
//     |     |
//     |     +-- sleep(timeout_ms)
//     |     |
//     |     +-- done? --> yes --> exit (connection finished normally)
//     |          no  --> stream.shutdown(.both) --> exit
//     |
//     v
//   handleConnection loop
//     |
//     +-- receiveHead() (may be unblocked by shutdown)
//     +-- dispatch()
//     +-- send()        (may fail if client slow and shutdown fired)
//     |
//   loop exit
//     |
//   defer: done.store(true)   <-- cancels watchdog if still sleeping
//          wdog_thread.join()
//     |
//   stream.close()
//

// --------------------------------------------------------- //

const IP: []const u8 = "127.0.0.1";
const PORT: u16 = 9007;
const CONN_TIMEOUT_MS: u64 = 5_000;

// --------------------------------------------------------- //

const WatchdogCtx = struct {
    stream: std.Io.net.Stream,
    io: std.Io,
    timeout_ms: u64,
    done: std.atomic.Value(bool) = .init(false),
};

fn watchdog(w: *WatchdogCtx) void {
    // Sleep for the full connection timeout window.
    std.Io.sleep(w.io, std.Io.Duration.fromMilliseconds(@intCast(w.timeout_ms)), .real) catch {};

    // If the connection finished before the timeout, done is already true.
    if (w.done.load(.acquire)) return;

    // Shutdown both directions: signals the peer with a FIN/RST and causes
    // the next read/write on this fd to return an error in the pool thread.
    // Note: this does not close the fd, stream.close() is deferred in
    // handleConnection and runs after the loop exits.
    w.stream.shutdown(w.io, .both) catch {};
}

// --------------------------------------------------------- //

fn handleConnection(stream: std.Io.net.Stream, io: std.Io) void {
    defer stream.close(io);

    var wdog = WatchdogCtx{
        .stream = stream,
        .io = io,
        .timeout_ms = CONN_TIMEOUT_MS,
    };
    const wdog_thread = std.Thread.spawn(.{}, watchdog, .{&wdog}) catch {
        // If thread spawn fails, proceed without timeout protection.
        // Acceptable: spawn failure is an OOM/OS limit condition.
        return handleConnectionNoTimeout(stream, io);
    };
    defer {
        wdog.done.store(true, .release); // cancel watchdog if still sleeping
        wdog_thread.join();
    }

    var buf_read: [4096]u8 = undefined;
    var buf_write: [4096]u8 = undefined;
    var conn_reader = stream.reader(io, &buf_read);
    var conn_writer = stream.writer(io, &buf_write);
    var http_server = std.http.Server.init(&conn_reader.interface, &conn_writer.interface);

    while (true) {
        var inner_req = http_server.receiveHead() catch |err| {
            // HttpConnectionClosing: clean close or shutdown-induced EOF
            if (err == error.HttpConnectionClosing) break;
            if (err == error.ConnectionResetByPeer) break;
            // ReadFailed: covers shutdown(.both) causing the next read to fail
            if (err == error.ReadFailed) break;
            break;
        };

        inner_req.respond("ok", .{}) catch {};
    }

    // wdog.done = true (set in defer) before join. Watchdog exits without
    // calling shutdown() if the connection completed before the timeout.
}

fn handleConnectionNoTimeout(stream: std.Io.net.Stream, io: std.Io) void {
    defer stream.close(io);

    var buf_read: [4096]u8 = undefined;
    var buf_write: [4096]u8 = undefined;
    var conn_reader = stream.reader(io, &buf_read);
    var conn_writer = stream.writer(io, &buf_write);
    var http_server = std.http.Server.init(&conn_reader.interface, &conn_writer.interface);

    while (true) {
        const inner_req = http_server.receiveHead() catch break;
        _ = inner_req;
    }
}

// --------------------------------------------------------- //

// Thread cost estimate:
//   Default stack: 8MB virtual (not resident). With stack_size override:
//     std.Thread.spawn(.{ .stack_size = 64 * 1024 }, watchdog, .{&wdog})
//   The watchdog only calls sleep() and shutdown(), so 64KB is ample.
//   At 1000 concurrent connections: 1000 watchdog threads * 64KB = 64MB virtual.

// --------------------------------------------------------- //

pub fn main(process: std.process.Init) !void {
    const io = process.io;

    const addr = try std.Io.net.IpAddress.resolve(io, IP, PORT);
    var net_server = try addr.listen(io, .{ .mode = .stream, .reuse_address = true });
    defer net_server.deinit(io);

    std.debug.print("model-c: listening on {s}:{d}\n", .{ IP, PORT });

    while (true) {
        const stream = net_server.accept(io) catch continue;
        handleConnection(stream, io);
    }
}

//
// How to test Model C: Watchdog Thread per Connection
//
// Note: this main() loop is single-threaded, it handles one connection at a
// time. While one client is connected, the next queues in the kernel and is
// not accepted until the current connection closes. This is a PoC limitation,
// the real server uses a pool of threads so connections run concurrently.
// Test nc and curl in separate steps, not simultaneously.
//
// Step 1: run the server.
//   zig run rnd/http_timeout_model_c.zig
//
// Test A: slow client (never sends headers):
//   nc localhost 9007
//   (just wait, do not type anything)
//   Expected: nc exits after ~5s when the watchdog fires shutdown(.both)
//   Pressing Enter in nc sends \n which is not a complete HTTP request.
//   The server keeps waiting for \r\n\r\n nothing is sent back. This is normal.
//
//   Confirm timing:
//   time nc localhost 9007
//   Expected: real 0m5.0s
//
// Test B: normal connection (completes before timeout):
//   curl http://localhost:9007/
//   Expected: responds immediately, watchdog exits cleanly without calling shutdown()
//
// What is being verified:
//   The watchdog clock starts at accept(), not at first request. It covers
//   the entire connection lifetime. A connection that stalls mid-headers
//   is closed by shutdown(.both) after CONN_TIMEOUT_MS regardless of
//   whether the handler has started.
//
//   Note: shutdown(.both) signals the peer and causes the NEXT read/write
//   on the socket to return an error. It does not interrupt a readv() that
//   is already in progress on another thread (POSIX does not guarantee that).
//   In practice on Linux this works for idle connections. For a currently
//   blocking readv() the interruption is OS-dependent.
