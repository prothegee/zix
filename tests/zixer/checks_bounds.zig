//! Client side of the bounds demo row: the client budget and the connection
//! limit.
//!
//! These go over raw sockets rather than a zix client, because two of the three
//! answers are what an edge sends a connection that never finished a request,
//! or never started one.
//!
//! The order matters. Both earlier checks end with the edge closing the
//! connection, and an edge releases the slot before it closes the socket, so
//! reading to end of stream is proof the slot is back before the limit check
//! starts filling the table.

const std = @import("std");

const wire = @import("runner_wire");

/// Connections held open to fill the site's client_conn_limit.
const HELD_CONNS: usize = 4;
/// Longest reply any of these checks reads.
const REPLY_MAX: usize = 8 * 1024;
/// Longest request any of these checks writes.
const REQUEST_MAX: usize = 128;

// --------------------------------------------------------- //

/// Bounds row: a request inside the budget is served as usual, a head that
/// never finishes is answered 408, and one connection past the limit is
/// refused with 503.
pub fn runBounds(io: std.Io, port: u16) !void {
    try requestInsideTheBudget(io, port);
    try partialHeadTimesOut(io, port);
    try pastTheLimitIsRefused(io, port);
}

// --------------------------------------------------------- //

/// A request that stays inside the budget: the bound is a ceiling, not a change
/// to how an ordinary request is served.
fn requestInsideTheBudget(io: std.Io, port: u16) !void {
    var stream = try connect(io, port);
    defer stream.close(io);

    var request_buf: [REQUEST_MAX]u8 = undefined;
    const request = try std.fmt.bufPrint(
        &request_buf,
        "GET / HTTP/1.1\r\nHost: 127.0.0.1:{d}\r\nConnection: close\r\n\r\n",
        .{port},
    );
    try wire.tlsWriteAll(stream.socket.handle, request);

    var reply_buf: [REPLY_MAX]u8 = undefined;
    const reply = try wire.readUntilClose(stream.socket.handle, &reply_buf);

    if (!std.mem.startsWith(u8, reply, "HTTP/1.1 200")) return error.ZixUnexpectedStatus;
    if (std.mem.indexOf(u8, reply, "upstream: proxies/bounds") == null) return error.NotFromUpstream;
}

/// A head that stops halfway: the edge takes the read side away once the budget
/// is gone, and answers 408 instead of holding the connection open.
fn partialHeadTimesOut(io: std.Io, port: u16) !void {
    var stream = try connect(io, port);
    defer stream.close(io);

    var request_buf: [REQUEST_MAX]u8 = undefined;
    const partial = try std.fmt.bufPrint(&request_buf, "GET / HTTP/1.1\r\nHost: 127.0.0.1:{d}\r\n", .{port});
    try wire.tlsWriteAll(stream.socket.handle, partial);

    var reply_buf: [REPLY_MAX]u8 = undefined;
    const reply = try wire.readUntilClose(stream.socket.handle, &reply_buf);

    if (!std.mem.startsWith(u8, reply, "HTTP/1.1 408")) return error.NoTimeoutStatus;
}

/// One connection past client_conn_limit is refused before it sends a byte.
///
/// Note:
/// - Every held connection completes an exchange first. A connection that has
///   only been accepted may not have reached the edge's admit yet, and the
///   refusal would then land on the wrong socket.
fn pastTheLimitIsRefused(io: std.Io, port: u16) !void {
    var held: [HELD_CONNS]std.Io.net.Stream = undefined;
    var open_count: usize = 0;
    defer {
        for (held[0..open_count]) |stream| stream.close(io);
    }

    while (open_count < HELD_CONNS) {
        held[open_count] = try connect(io, port);
        open_count += 1;

        var request_buf: [REQUEST_MAX]u8 = undefined;
        const request = try std.fmt.bufPrint(&request_buf, "GET / HTTP/1.1\r\nHost: 127.0.0.1:{d}\r\n\r\n", .{port});
        try wire.tlsWriteAll(held[open_count - 1].socket.handle, request);

        var reply_buf: [REPLY_MAX]u8 = undefined;
        const got = try wire.readOnceBounded(held[open_count - 1].socket.handle, &reply_buf);
        if (!std.mem.startsWith(u8, reply_buf[0..got], "HTTP/1.1 200")) return error.HeldConnectionRefused;
    }

    var refused = try connect(io, port);
    defer refused.close(io);

    var reply_buf: [REPLY_MAX]u8 = undefined;
    const reply = try wire.readUntilClose(refused.socket.handle, &reply_buf);

    if (!std.mem.startsWith(u8, reply, "HTTP/1.1 503")) return error.LimitNotEnforced;
    if (std.mem.indexOf(u8, reply, "connection_limit_reached") == null) return error.NoProxyStatus;
}

// --------------------------------------------------------- //

/// One cleartext connection to the edge.
fn connect(io: std.Io, port: u16) !std.Io.net.Stream {
    const addr = try std.Io.net.IpAddress.parse("127.0.0.1", port);

    return addr.connect(io, .{ .mode = .stream, .protocol = .tcp });
}
