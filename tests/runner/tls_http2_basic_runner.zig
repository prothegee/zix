// Test runner for zix.Http2 over TLS 1.3 (examples/tls/tls_http2_basic.zig).
// Spawns the h2 https server, connects with the NATIVE zix.Tls client (offering ALPN h2), then
// speaks minimal HTTP/2 over the TLS ClientConnection (preface + SETTINGS + HEADERS GET /) using
// zix.Http2 frame + HPACK primitives, and asserts the response carries :status 200. No curl.
//
// Invoked by `zig build test-runner-tls-http2`.
// argv[1]: server binary path, argv[2]: label, argv[3]: port.

const std = @import("std");
const zix = @import("zix");
const common = @import("common.zig");

const Tls = zix.Tls;
const Http2 = zix.Http2;
const linux = std.os.linux;
const posix = std.posix;

const WAIT_MS: u64 = 5000;

// --------------------------------------------------------- //

pub fn main(process: std.process.Init) void {
    var arg_iter = std.process.Args.Iterator.init(process.minimal.args);
    _ = arg_iter.skip();
    const server_path = arg_iter.next() orelse {
        std.debug.print("FAIL tls-http2: missing server path\n", .{});
        std.process.exit(1);
    };
    const label = arg_iter.next() orelse {
        std.debug.print("FAIL tls-http2: missing label\n", .{});
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

    const addr = try std.Io.net.IpAddress.parse("127.0.0.1", port);
    var stream = try addr.connect(io, .{ .mode = .stream, .protocol = .tcp });
    defer stream.close(io);
    const fd = stream.socket.handle;

    // TLS 1.3 handshake via the native zix.Tls client, offering ALPN h2.
    var rnd: [64]u8 = undefined;
    _ = linux.getrandom(&rnd, rnd.len, 0);
    var ch_buf: [600]u8 = undefined;
    const started = try Tls.Client.start(.{ .client_random = rnd[0..32].*, .ephemeral_secret = rnd[32..64].*, .alpn = &.{.H2} }, &ch_buf);
    var state = started.state;

    try writeRecord(fd, 22, started.client_hello);

    // server flight: ServerHello + ChangeCipherSpec + the encrypted flight (3 records).
    var flight_buf: [8192]u8 = undefined;
    var flen: usize = 0;
    for (0..3) |_| flen += try readRecordInto(fd, flight_buf[flen..]);

    var fin_buf: [256]u8 = undefined;
    var finished = try Tls.Client.finish(&state, flight_buf[0..flen], &fin_buf);
    if (finished.alpn != Tls.Alpn.H2) return error.AlpnNotH2;
    try writeAll(fd, finished.client_finished);

    // build the h2 request (preface + empty SETTINGS + HEADERS GET /) as one plaintext buffer.
    var req: [512]u8 = undefined;
    var n: usize = 0;
    @memcpy(req[0..Http2.PREFACE.len], Http2.PREFACE);
    n += Http2.PREFACE.len;

    var fh: [Http2.FRAME_HEADER_LEN]u8 = undefined;
    Http2.encodeFrameHeader(&fh, .{ .length = 0, .frame_type = Http2.FRAME_TYPE_SETTINGS, .flags = 0, .stream_id = 0 });
    @memcpy(req[n..][0..fh.len], &fh);
    n += fh.len;

    var hbuf: [256]u8 = undefined;
    var enc = Http2.HpackEncoder.init(&hbuf);
    try enc.writeHeader(":method", "GET");
    try enc.writeHeader(":path", "/");
    try enc.writeHeader(":scheme", "https");
    try enc.writeHeader(":authority", "localhost");
    const hblock = enc.encoded();

    Http2.encodeFrameHeader(&fh, .{ .length = @intCast(hblock.len), .frame_type = Http2.FRAME_TYPE_HEADERS, .flags = Http2.FLAG_END_HEADERS | Http2.FLAG_END_STREAM, .stream_id = 1 });
    @memcpy(req[n..][0..fh.len], &fh);
    n += fh.len;
    @memcpy(req[n..][0..hblock.len], hblock);
    n += hblock.len;

    var send_buf: [1024]u8 = undefined;
    try writeAll(fd, finished.connection.writeAppData(req[0..n], &send_buf));

    // read the response: decrypt records, parse frames, look for :status 200 on a HEADERS frame.
    var acc: [16384]u8 = undefined;
    var acc_len: usize = 0;
    var rounds: usize = 0;
    while (rounds < 64) : (rounds += 1) {
        var rec_buf: [17 * 1024]u8 = undefined;
        const rec_len = try readRecordInto(fd, &rec_buf);
        if (rec_buf[0] != 23) continue; // application_data only

        var dec: [17 * 1024]u8 = undefined;
        const plain = try finished.connection.readAppData(rec_buf[0..rec_len], &dec);
        @memcpy(acc[acc_len..][0..plain.len], plain);
        acc_len += plain.len;

        var off: usize = 0;
        while (off + Http2.FRAME_HEADER_LEN <= acc_len) {
            const frame = Http2.parseFrameHeader(acc[off..][0..Http2.FRAME_HEADER_LEN]);
            const total = Http2.FRAME_HEADER_LEN + @as(usize, frame.length);
            if (off + total > acc_len) break; // frame not fully arrived yet

            const payload = acc[off + Http2.FRAME_HEADER_LEN .. off + total];
            if (frame.frame_type == Http2.FRAME_TYPE_HEADERS) {
                var hdec = Http2.HpackDecoder.init();
                var hdrs: [Http2.MAX_HEADERS]Http2.Header = undefined;
                var scratch: [4096]u8 = undefined;
                const cnt = try hdec.decode(payload, &hdrs, &scratch);
                for (hdrs[0..cnt]) |h| {
                    if (std.mem.eql(u8, h.name, ":status") and std.mem.eql(u8, h.value, "200")) return;
                }
            }
            off += total;
        }
        if (off > 0 and off < acc_len) {
            std.mem.copyForwards(u8, acc[0 .. acc_len - off], acc[off..acc_len]);
            acc_len -= off;
        } else if (off >= acc_len) {
            acc_len = 0;
        }
    }

    return error.NoStatus200;
}

// --------------------------------------------------------------- //

fn writeRecord(fd: posix.fd_t, content_type: u8, msg: []const u8) !void {
    var header: [5]u8 = undefined;
    header[0] = content_type;
    header[1] = 0x03;
    header[2] = 0x03;
    std.mem.writeInt(u16, header[3..5], @intCast(msg.len), .big);
    try writeAll(fd, &header);
    try writeAll(fd, msg);
}

fn readRecordInto(fd: posix.fd_t, buf: []u8) !usize {
    try readAll(fd, buf[0..5]);
    const len = std.mem.readInt(u16, buf[3..5], .big);
    try readAll(fd, buf[5 .. 5 + len]);

    return 5 + len;
}

fn readAll(fd: posix.fd_t, buf: []u8) !void {
    var read: usize = 0;
    while (read < buf.len) {
        const rc = linux.read(fd, buf[read..].ptr, buf.len - read);
        switch (posix.errno(rc)) {
            .SUCCESS => {},
            .INTR => continue,
            else => return error.ReadFailed,
        }
        if (rc == 0) return error.ConnectionClosed;
        read += rc;
    }
}

fn writeAll(fd: posix.fd_t, bytes: []const u8) !void {
    var written: usize = 0;
    while (written < bytes.len) {
        const rc = linux.write(fd, bytes[written..].ptr, bytes.len - written);
        switch (posix.errno(rc)) {
            .SUCCESS => {},
            .INTR => continue,
            else => return error.WriteFailed,
        }
        written += rc;
    }
}
