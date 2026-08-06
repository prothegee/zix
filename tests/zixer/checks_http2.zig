//! Client side of the h2 demo rows: the http2 edge and the grpc relay.
//!
//! The http2 check speaks prior-knowledge h2c by hand, because the point is
//! that the client really is on h2 while the upstream only ever sees http1.
//! The grpc check uses the native zix client, so a real trailing status has to
//! survive the relay.

const std = @import("std");
const zix = @import("zix");

const wire = @import("runner_wire");

const Http2 = zix.Http2;

/// Reads before the h2 check gives up waiting for the status.
const MAX_ROUNDS: usize = 64;
/// Longest h2 frame batch the check reads at once.
const READ_BUF: usize = 16 * 1024;
/// Name the grpc check greets with, and the reply it must find.
const GREET_NAME: []const u8 = "runner";

// --------------------------------------------------------- //

/// http2 edge: prior-knowledge h2c preface, SETTINGS, then GET / on stream 1.
/// The scanner answers as soon as a HEADERS block carries :status 200.
///
/// Note:
/// - Every read is bounded. An edge that answers a status this scan does not
///   accept, a 502 from a failed upstream leg for instance, then goes back to
///   waiting for the next client frame: neither side speaks again, the round
///   counter never advances, and an unbounded read here would park the whole
///   table on it.
pub fn runHttp2(io: std.Io, port: u16) !void {
    const addr = try std.Io.net.IpAddress.parse("127.0.0.1", port);
    var stream = try addr.connect(io, .{ .mode = .stream, .protocol = .tcp });
    defer stream.close(io);

    const fd = stream.socket.handle;

    var request: [512]u8 = undefined;
    var len: usize = 0;

    @memcpy(request[0..Http2.PREFACE.len], Http2.PREFACE);
    len += Http2.PREFACE.len;

    var frame_head: [Http2.FRAME_HEADER_LEN]u8 = undefined;
    Http2.encodeFrameHeader(&frame_head, .{ .length = 0, .frame_type = Http2.FRAME_TYPE_SETTINGS, .flags = 0, .stream_id = 0 });
    @memcpy(request[len..][0..frame_head.len], &frame_head);
    len += frame_head.len;

    var block_buf: [256]u8 = undefined;
    var encoder = Http2.HpackEncoder.init(&block_buf);
    try encoder.writeHeader(":method", "GET");
    try encoder.writeHeader(":path", "/");
    try encoder.writeHeader(":scheme", "http");
    try encoder.writeHeader(":authority", "localhost");
    const block = encoder.encoded();

    Http2.encodeFrameHeader(&frame_head, .{
        .length = @intCast(block.len),
        .frame_type = Http2.FRAME_TYPE_HEADERS,
        .flags = Http2.FLAG_END_HEADERS | Http2.FLAG_END_STREAM,
        .stream_id = 1,
    });
    @memcpy(request[len..][0..frame_head.len], &frame_head);
    len += frame_head.len;
    @memcpy(request[len..][0..block.len], block);
    len += block.len;

    try wire.tlsWriteAll(fd, request[0..len]);

    var scanner: wire.H2Scanner = .{};
    var rounds: usize = 0;
    while (rounds < MAX_ROUNDS) : (rounds += 1) {
        var chunk: [READ_BUF]u8 = undefined;
        const got = try wire.readOnceBounded(fd, &chunk);
        if (got == 0) return error.ConnectionClosed;

        if (try scanner.push(chunk[0..got])) return;
    }

    return error.NoStatus200;
}

/// grpc relay: one unary call, whose reply message and trailing OK status both
/// have to cross the h2-to-h2 relay.
pub fn runGrpc(io: std.Io, port: u16) !void {
    var client = try zix.Grpc.Client.connect(.{ .ip = "127.0.0.1", .port = port }, io);
    defer client.deinit();

    var request_buf: [64]u8 = undefined;
    const request_len = zix.Grpc.encodeString(1, GREET_NAME, &request_buf);

    var reply_buf: [256]u8 = undefined;
    const reply = try client.unary(
        "/helloworld.Greeter/SayHello",
        "application/grpc+proto",
        request_buf[0..request_len],
        &reply_buf,
    );

    var reader = zix.Grpc.MessageReader.init(reply);
    while (reader.next() catch null) |field| {
        if (field.field_number != 1 or field.wire_type != zix.Grpc.WT_LEN) continue;
        if (std.mem.indexOf(u8, field.payload, GREET_NAME) == null) return error.UnexpectedGreeting;
        if (std.mem.indexOf(u8, field.payload, "proxies/grpc") == null) return error.NotFromUpstream;

        return;
    }

    return error.NoReplyMessage;
}
