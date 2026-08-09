//! Client side of the headers demo row: the two cfg header sections.
//!
//! This goes over a raw socket rather than a zix client, because one of the
//! assertions is about how many times a name appears in the response head. A
//! client that folds duplicate fields into one value would hide exactly the
//! defect the replace rule exists to prevent.

const std = @import("std");

const wire = @import("runner_wire");

/// Longest reply this check reads.
const REPLY_MAX: usize = 8 * 1024;
/// Longest request this check writes.
const REQUEST_MAX: usize = 128;

// --------------------------------------------------------- //

/// Headers row: the response head carries the site's own lines, the backend
/// received the request-leg lines with their tokens filled in, and the name the
/// site sets replaces the backend's copy instead of joining it.
pub fn runHeaders(io: std.Io, port: u16) !void {
    const addr = try std.Io.net.IpAddress.parse("127.0.0.1", port);
    var stream = try addr.connect(io, .{ .mode = .stream, .protocol = .tcp });
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

    if (!std.mem.startsWith(u8, reply, "HTTP/1.1 200")) return error.UnexpectedStatus;

    const split = std.mem.indexOf(u8, reply, "\r\n\r\n") orelse return error.NoHeadEnd;
    const head = reply[0..split];
    const body = reply[split + 4 ..];

    if (wire.headerValue(head, "x-content-type-options") == null) return error.MissingResponseHeader;

    const served_over = wire.headerValue(head, "x-served-over") orelse return error.MissingSchemeToken;
    if (!std.mem.eql(u8, served_over, "http")) return error.WrongSchemeToken;

    // The site sets a name the backend also sets, so exactly one line of it may
    // reach the client, carrying the site's value.
    if (countHeaderLines(head, "x-frame-options") != 1) return error.RelayedCopyNotDropped;
    const frame_options = wire.headerValue(head, "x-frame-options") orelse return error.MissingFrameOptions;
    if (!std.mem.eql(u8, frame_options, "DENY")) return error.OriginValueWon;

    if (std.mem.indexOf(u8, body, "upstream: proxies/headers") == null) return error.NotFromUpstream;
    if (std.mem.indexOf(u8, body, "x-real-ip: 127.0.0.1") == null) return error.UpstreamMissedClientIp;
    if (std.mem.indexOf(u8, body, "x-forwarded-proto: http") == null) return error.UpstreamMissedScheme;
    if (std.mem.indexOf(u8, body, "x-edge-tenant: proxies-demo") == null) return error.UpstreamMissedLiteral;

    var host_mark_buf: [48]u8 = undefined;
    const host_mark = try std.fmt.bufPrint(&host_mark_buf, "x-forwarded-host: 127.0.0.1:{d}", .{port});
    if (std.mem.indexOf(u8, body, host_mark) == null) return error.UpstreamMissedHost;
}

// --------------------------------------------------------- //

/// How many field lines in head carry this name.
fn countHeaderLines(head: []const u8, name: []const u8) usize {
    var seen: usize = 0;

    var line_iter = std.mem.tokenizeSequence(u8, head, "\r\n");
    while (line_iter.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " "), name)) seen += 1;
    }

    return seen;
}
