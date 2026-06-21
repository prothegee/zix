// Test runner for the zix.Http1 over-large request-body drain (EPOLL + URING).
// Spawns the server, then on one keep-alive connection pipelines an over-large
// POST (body larger than max_recv_buf) immediately followed by a GET. The engine
// answers the POST, drains the remaining body off the socket, then must serve the
// pipelined GET. A correct drain consumes exactly the declared body, so the GET
// response only arrives in sync when the drain neither over- nor under-read.
// Kills the server on exit.
//
// Invoked by `zig build test-runner-http1-drain-<model>`.
// argv[1]: server binary path. argv[2]: label. argv[3]: port.
//
// Note:
// - The drain only exists on the EPOLL and URING dispatch models. ASYNC, POOL,
//   and MIXED truncate an over-large body instead, so they are not wired here.
// - Pipelining the GET behind the body is the point: it is the bytes the drain
//   must leave on the socket, so it directly checks the conn.drain cap.

const std = @import("std");
const common = @import("common.zig");
const linux = std.os.linux;

const WAIT_MS: u64 = 5000;
const RECV_TIMEOUT_S: isize = 4;

/// Request-body length. Larger than the example's max_recv_buf (16 KiB) so the
/// body cannot be buffered whole, forcing the engine onto the drain path.
const BODY_LEN: usize = 100 * 1024;

const EXPECTED_BODY: []const u8 = "Hello, World!";

// --------------------------------------------------------- //

pub fn main(process: std.process.Init) void {
    var arg_iter = std.process.Args.Iterator.init(process.minimal.args);
    _ = arg_iter.skip();
    const server_path = arg_iter.next() orelse {
        std.debug.print("FAIL http1-drain: missing server path\n", .{});
        std.process.exit(1);
    };
    const label = arg_iter.next() orelse {
        std.debug.print("FAIL http1-drain: missing label\n", .{});
        std.process.exit(1);
    };
    const port_str = arg_iter.next() orelse {
        std.debug.print("FAIL {s}: missing port\n", .{label});
        std.process.exit(1);
    };
    const port = std.fmt.parseInt(u16, port_str, 10) catch {
        std.debug.print("FAIL {s}: invalid port\n", .{label});
        std.process.exit(1);
    };

    run(process.io, server_path, port) catch |err| {
        std.debug.print("FAIL {s}: {}\n", .{ label, err });
        std.process.exit(1);
    };
    common.printPass(label);
}

fn run(io: std.Io, server_path: []const u8, port: u16) !void {
    var server_child = try common.spawnServer(io, server_path);
    defer server_child.kill(io);

    try common.waitForTcpPort(io, &server_child, port, WAIT_MS);

    const addr = std.Io.net.IpAddress.parse("127.0.0.1", port) catch return error.BadAddress;
    const stream = try addr.connect(io, .{ .mode = .stream, .protocol = .tcp });
    defer stream.close(io);
    const fd = stream.socket.handle;

    setRecvTimeout(fd);

    // Pipeline the over-large POST and the follow-up GET back to back, before
    // reading any response. The POST body exceeds max_recv_buf, so the engine
    // answers it and drains the remainder. The GET is the bytes that follow the
    // body on the wire: it parses correctly only when the drain stopped exactly
    // at the body end.
    try sendLargePost(fd);
    try sendGet(fd);

    var reader = Reader{ .fd = fd };
    try reader.expectResponse();
    try reader.expectResponse();
}

// --------------------------------------------------------- //

/// Bound a blocking read so a desynchronized connection fails the runner
/// instead of hanging it. Best-effort: a kernel without SO_RCVTIMEO is a no-op.
fn setRecvTimeout(fd: std.posix.fd_t) void {
    var tv = linux.timeval{ .sec = RECV_TIMEOUT_S, .usec = 0 };
    std.posix.setsockopt(fd, std.posix.SOL.SOCKET, linux.SO.RCVTIMEO, std.mem.asBytes(&tv)) catch {};
}

fn sendLargePost(fd: std.posix.fd_t) !void {
    var head_buf: [128]u8 = undefined;
    const head = try std.fmt.bufPrint(&head_buf, "POST / HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: {d}\r\n\r\n", .{BODY_LEN});
    try writeAll(fd, head);

    var chunk: [8192]u8 = undefined;
    @memset(&chunk, 'A');

    var sent: usize = 0;
    while (sent < BODY_LEN) {
        const n = @min(chunk.len, BODY_LEN - sent);
        try writeAll(fd, chunk[0..n]);
        sent += n;
    }
}

fn sendGet(fd: std.posix.fd_t) !void {
    try writeAll(fd, "GET / HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n");
}

/// A buffered response reader over one keep-alive connection. Holds bytes across
/// calls so a response that arrives coalesced with the next is not lost.
const Reader = struct {
    fd: std.posix.fd_t,
    buf: [8192]u8 = undefined,
    len: usize = 0,
    pos: usize = 0,

    /// Read one HTTP/1.1 response and assert it is 200 with the expected body.
    /// Consumes exactly the header plus the declared Content-Length, so the next
    /// call resumes at the following response.
    fn expectResponse(self: *Reader) !void {
        const header_end: usize = blk: {
            while (true) {
                if (std.mem.indexOf(u8, self.buf[self.pos..self.len], "\r\n\r\n")) |rel| break :blk self.pos + rel + 4;

                try self.fill();
            }
        };

        const head = self.buf[self.pos..header_end];
        if (!std.mem.startsWith(u8, head, "HTTP/1.1 200")) return error.UnexpectedStatus;

        const content_length = parseContentLength(head) orelse return error.NoContentLength;
        const body_end = header_end + content_length;

        while (self.len < body_end) try self.fill();

        const body = self.buf[header_end..body_end];
        if (!std.mem.eql(u8, body, EXPECTED_BODY)) return error.UnexpectedBody;

        self.pos = body_end;
    }

    fn fill(self: *Reader) !void {
        if (self.len == self.buf.len) return error.ResponseTooLarge;

        const n = std.posix.read(self.fd, self.buf[self.len..]) catch return error.ReadFailed;
        if (n == 0) return error.ConnectionClosed;
        self.len += n;
    }
};

// --------------------------------------------------------- //

fn writeAll(fd: std.posix.fd_t, data: []const u8) !void {
    var written: usize = 0;
    while (written < data.len) {
        const rc = std.posix.system.write(fd, data[written..].ptr, data.len - written);
        switch (std.posix.errno(rc)) {
            .SUCCESS => {
                const n: usize = @intCast(rc);
                if (n == 0) return error.BrokenPipe;
                written += n;
            },
            .INTR => continue,
            else => return error.BrokenPipe,
        }
    }
}

fn parseContentLength(head: []const u8) ?usize {
    var it = std.mem.splitSequence(u8, head, "\r\n");
    _ = it.next();

    while (it.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        if (std.ascii.eqlIgnoreCase(name, "content-length")) {
            return std.fmt.parseInt(usize, std.mem.trim(u8, line[colon + 1 ..], " \t"), 10) catch null;
        }
    }

    return null;
}
