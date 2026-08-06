// Test runner for zix.Http2 h2c across the dispatch models (one binary per model). Spawns the
// server, speaks prior-knowledge h2c (preface + SETTINGS + HEADERS GET /), asserts a HEADERS frame
// with :status 200, kills server.
//
// Invoked by `zig build test-runner-http2-<model>`.
// argv[1]: server binary path, argv[2]: label, argv[3]: port.

const std = @import("std");
const zix = @import("zix");
const common = @import("common.zig");
const fd_io = zix.utils.fd_io;

// --------------------------------------------------------- //

pub fn main(process: std.process.Init) void {
    var arg_iter = common.argsIterator(process.minimal.args);
    _ = arg_iter.skip();
    const server_path = arg_iter.next() orelse {
        std.debug.print("FAIL http2: missing server path\n", .{});
        std.process.exit(1);
    };
    const label = arg_iter.next() orelse {
        std.debug.print("FAIL http2: missing label\n", .{});
        std.process.exit(1);
    };

    if (common.skipDispatchOffPlatform(label)) return;
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
    const Http2 = zix.Http2;

    var server_child = try common.spawnServer(io, server_path);
    defer server_child.kill(io);

    try common.waitForTcpPort(io, &server_child, port, 5000);

    const addr = try std.Io.net.IpAddress.parse("127.0.0.1", port);
    var stream = try addr.connect(io, .{ .mode = .stream, .protocol = .tcp });
    defer stream.close(io);
    const fd = stream.socket.handle;

    // Build the prior-knowledge h2c request: preface, empty SETTINGS, then HEADERS GET / on stream 1.
    var req: [512]u8 = undefined;
    var n: usize = 0;
    @memcpy(req[0..Http2.PREFACE.len], Http2.PREFACE);
    n += Http2.PREFACE.len;

    var frame_head: [Http2.FRAME_HEADER_LEN]u8 = undefined;
    Http2.encodeFrameHeader(&frame_head, .{ .length = 0, .frame_type = Http2.FRAME_TYPE_SETTINGS, .flags = 0, .stream_id = 0 });
    @memcpy(req[n..][0..frame_head.len], &frame_head);
    n += frame_head.len;

    var header_buf: [256]u8 = undefined;
    var hpack_encoder = Http2.HpackEncoder.init(&header_buf);
    try hpack_encoder.writeHeader(":method", "GET");
    try hpack_encoder.writeHeader(":path", "/");
    try hpack_encoder.writeHeader(":scheme", "http");
    try hpack_encoder.writeHeader(":authority", "localhost");
    const hblock = hpack_encoder.encoded();
    Http2.encodeFrameHeader(&frame_head, .{ .length = @intCast(hblock.len), .frame_type = Http2.FRAME_TYPE_HEADERS, .flags = Http2.FLAG_END_HEADERS | Http2.FLAG_END_STREAM, .stream_id = 1 });
    @memcpy(req[n..][0..frame_head.len], &frame_head);
    n += frame_head.len;
    @memcpy(req[n..][0..hblock.len], hblock);
    n += hblock.len;

    try fdWriteAll(fd, req[0..n]);

    // Read response frames until a HEADERS frame carries :status 200.
    var recv_accum: [16384]u8 = undefined;
    var recv_len: usize = 0;
    var rounds: usize = 0;
    while (rounds < 64) : (rounds += 1) {
        const got = try fdReadOnce(fd, recv_accum[recv_len..]);
        if (got == 0) return error.ConnectionClosed;
        recv_len += got;

        var off: usize = 0;
        while (off + Http2.FRAME_HEADER_LEN <= recv_len) {
            const frame = Http2.parseFrameHeader(recv_accum[off..][0..Http2.FRAME_HEADER_LEN]);
            const total = Http2.FRAME_HEADER_LEN + @as(usize, frame.length);
            if (off + total > recv_len) break;

            const payload = recv_accum[off + Http2.FRAME_HEADER_LEN .. off + total];
            if (frame.frame_type == Http2.FRAME_TYPE_HEADERS) {
                var hpack_decoder = Http2.HpackDecoder.init();
                var hdrs: [Http2.MAX_HEADERS]Http2.Header = undefined;
                var scratch: [4096]u8 = undefined;
                const header_count = try hpack_decoder.decode(payload, &hdrs, &scratch);
                for (hdrs[0..header_count]) |h| {
                    if (std.mem.eql(u8, h.name, ":status") and std.mem.eql(u8, h.value, "200")) return;
                }
            }
            off += total;
        }
        if (off >= recv_len) {
            recv_len = 0;
        } else if (off > 0) {
            std.mem.copyForwards(u8, recv_accum[0 .. recv_len - off], recv_accum[off..recv_len]);
            recv_len -= off;
        }
    }

    return error.NoStatus200;
}

fn fdWriteAll(fd: std.posix.fd_t, bytes: []const u8) !void {
    return fd_io.writeAll(fd, bytes);
}

fn fdReadOnce(fd: std.posix.fd_t, buf: []u8) !usize {
    return fd_io.readOnce(fd, buf);
}
