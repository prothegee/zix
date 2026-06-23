// Test runner for zix.Http1 over TLS 1.3 with an Ed25519 server cert (examples/tls/tls_http1_ed25519.zig).
// The std-backed zix.Http.Client cannot verify an Ed25519 server cert, so this drives the NATIVE
// zix.Tls client (which offers + verifies the ed25519 signature scheme), trusts the fixture cert
// (chain + hostname), sends an https/1.1 GET over the encrypted ClientConnection, and asserts the
// response carries 200 + body + the HSTS header. No curl, no openssl.
//
// Invoked by `zig build test-runner-tls-http1-ed25519`.
// argv[1]: server binary path, argv[2]: label, argv[3]: port.

const std = @import("std");
const zix = @import("zix");
const common = @import("common.zig");

const Tls = zix.Tls;
const linux = std.os.linux;
const posix = std.posix;

const WAIT_MS: u64 = 5000;
const CA_PATH = "examples/tls/certs/ed25519_cert.pem";
const EXPECTED_BODY: []const u8 = "hello over tls 1.3 (ed25519)";

// --------------------------------------------------------- //

pub fn main(process: std.process.Init) void {
    var arg_iter = std.process.Args.Iterator.init(process.minimal.args);
    _ = arg_iter.skip();
    const server_path = arg_iter.next() orelse {
        std.debug.print("FAIL tls-http1-ed25519: missing server path\n", .{});
        std.process.exit(1);
    };
    const label = arg_iter.next() orelse {
        std.debug.print("FAIL tls-http1-ed25519: missing label\n", .{});
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

    // TLS 1.3 handshake via the native zix.Tls client (offers ecdsa + ed25519 sig schemes).
    var rnd: [64]u8 = undefined;
    _ = linux.getrandom(&rnd, rnd.len, 0);
    var ch_buf: [600]u8 = undefined;
    const started = try Tls.Client.start(.{ .client_random = rnd[0..32].*, .ephemeral_secret = rnd[32..64].* }, &ch_buf);
    var state = started.state;

    try writeRecord(fd, 22, started.client_hello);

    var flight_buf: [8192]u8 = undefined;
    var flen: usize = 0;
    for (0..3) |_| flen += try readRecordInto(fd, flight_buf[flen..]);

    var fin_buf: [256]u8 = undefined;
    var finished = try Tls.Client.finish(&state, flight_buf[0..flen], &fin_buf);

    // trust the Ed25519 server cert: chain to the fixture anchor + hostname (RFC 5280 / 6125).
    try verifyServerTrust(io, &finished);

    try writeAll(fd, finished.client_finished);

    // https/1.1 GET over the encrypted connection.
    const req = "GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";
    var send_buf: [512]u8 = undefined;
    try writeAll(fd, finished.connection.writeAppData(req, &send_buf));

    // read response records, decrypt, accumulate plaintext until the body arrives or the peer closes.
    var acc: [8192]u8 = undefined;
    var acc_len: usize = 0;
    var rounds: usize = 0;
    while (rounds < 32) : (rounds += 1) {
        var rec_buf: [17 * 1024]u8 = undefined;
        const rec_len = readRecordInto(fd, &rec_buf) catch break;
        if (rec_buf[0] != 23) continue; // application_data only

        var dec: [17 * 1024]u8 = undefined;
        const plain = finished.connection.readAppData(rec_buf[0..rec_len], &dec) catch break; // close_notify ends it
        if (acc_len + plain.len > acc.len) break;
        @memcpy(acc[acc_len..][0..plain.len], plain);
        acc_len += plain.len;

        if (std.mem.indexOf(u8, acc[0..acc_len], EXPECTED_BODY) != null) break;
    }

    const response = acc[0..acc_len];
    if (std.mem.indexOf(u8, response, " 200 ") == null) return error.UnexpectedStatus;
    if (std.mem.indexOf(u8, response, EXPECTED_BODY) == null) return error.UnexpectedBody;
    if (std.mem.indexOf(u8, response, "Strict-Transport-Security") == null) return error.MissingHsts;
}

// --------------------------------------------------------------- //

fn verifyServerTrust(io: std.Io, finished: *const Tls.Client.FinishResult) !void {
    var pem_buf: [8192]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&pem_buf);
    const cert_pem = try std.Io.Dir.cwd().readFileAlloc(io, CA_PATH, fba.allocator(), .limited(8192));

    var der_buf: [Tls.Client.max_server_cert_der]u8 = undefined;
    const anchor_der = try Tls.pemToDer(&der_buf, cert_pem);

    try finished.verifyServerCert(anchor_der, "localhost", nowSec());
}

fn nowSec() i64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.REALTIME, &ts);

    return ts.sec;
}

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
        if (rc == 0) return error.WriteFailed;
        written += rc;
    }
}
