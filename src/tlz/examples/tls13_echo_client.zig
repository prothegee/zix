//! TLZ example tls13_echo_client
//!
//! ### file: src/tlz/examples/tls13_echo_client.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! A TLS 1.3 client over TCP: connect to the echo server, check its certificate, send
//! a few lines, print what comes back, then close cleanly.
//!
//! ### note:
//!
//! The trust anchor is the self-signed `localhost` test fixture the echo server uses.
//! Never trust it outside this example. Start the `tls13_echo_server` example first.
//! Build with `zig build example-tls13_echo_client` from `src/tlz`.
//!
//! ---------------------------------------------------------
//!
//! ### licenses:
//!
//! - BSD-3-Clause
//!
//! ### copyright:
//!
//! - (c) Prana Ron // @prothegee // prothegee@pm.me
//!
//! ### contributors:
//!
//! - Prana Ron // @prothegee // prothegee@pm.me
//!

const std = @import("std");
const tlz = @import("tlz");

// --------------------------------------------------------- //
// Private:

/// The server certificate, trusted as is: self-signed ECDSA P-256 for `localhost`,
/// valid 2026-06-22 to 2036-06-19.
const CERT_PEM =
    \\-----BEGIN CERTIFICATE-----
    \\MIIB1DCCAXugAwIBAgIUeibuSR8JGsfJFPSoEMHs5xNAJXQwCgYIKoZIzj0EAwIw
    \\KjESMBAGA1UEAwwJbG9jYWxob3N0MRQwEgYDVQQKDAt6aXgtdGxzLXBvYzAeFw0y
    \\NjA2MjIxMjU0MjBaFw0zNjA2MTkxMjU0MjBaMCoxEjAQBgNVBAMMCWxvY2FsaG9z
    \\dDEUMBIGA1UECgwLeml4LXRscy1wb2MwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNC
    \\AATCoBIbKYrJzTiSAOeNlOe94cx82AdHlfq0+Rl5nUD9wjHFqQmQrIxhZq5HLzP3
    \\T87Ql/Ltt7ihl0vmakqwfyU7o38wfTAdBgNVHQ4EFgQUw04dCjakOUdwm1OeFt0C
    \\E6pBlqowHwYDVR0jBBgwFoAUw04dCjakOUdwm1OeFt0CE6pBlqowDwYDVR0TAQH/
    \\BAUwAwEB/zAaBgNVHREEEzARgglsb2NhbGhvc3SHBH8AAAEwDgYDVR0PAQH/BAQD
    \\AgeAMAoGCCqGSM49BAMCA0cAMEQCIAsBLxGdubldmQvEgstj6PgeM3oIY0kE5Mr1
    \\E9wQyKqDAiAv3+ef9tVAPnU93yqlJnGSO4osKBJry/GWvW+37LyxTg==
    \\-----END CERTIFICATE-----
    \\
;

/// The name the client expects the certificate to carry.
const HOST = "localhost";

/// The lines the client sends, one record each.
const MESSAGES = [_][]const u8{
    "hello tlz",
    "one more line",
};

/// Where the echo server listens.
const SERVER_ADDRESS = "127.0.0.1";
const SERVER_PORT: u16 = 8443;

/// The byte length of a TLS record header: type, version, length.
const RECORD_HEADER_LEN = 5;

/// The largest whole record either side reads.
const MAX_RECORD = tlz.MAX_RECORD_WIRE;

/// Read one whole record (header included) into `buf`.
///
/// Param:
/// reader - *std.Io.Reader (the socket reader)
/// buf - []u8 (holds the record, at least `MAX_RECORD` bytes)
///
/// Return:
/// - []const u8 (the record, a view into `buf`)
/// - error.EndOfStream when the peer closed the socket
/// - error.RecordTooLarge when the record does not fit `buf`
fn readRecord(reader: *std.Io.Reader, buf: []u8) ![]const u8 {
    try reader.readSliceAll(buf[0..RECORD_HEADER_LEN]);

    const body_len = std.mem.readInt(u16, buf[3..5], .big);
    const record_len = RECORD_HEADER_LEN + body_len;
    if (record_len > buf.len) return error.RecordTooLarge;

    try reader.readSliceAll(buf[RECORD_HEADER_LEN..record_len]);

    return buf[0..record_len];
}

/// Write `bytes` and push them onto the socket.
fn sendAll(writer: *std.Io.Writer, bytes: []const u8) !void {
    try writer.writeAll(bytes);
    try writer.flush();
}

/// The record type of a plaintext handshake record (the ClientHello).
const CONTENT_TYPE_HANDSHAKE: u8 = 22;

/// The record version a TLS 1.3 ClientHello travels under (RFC 8446 5.1).
const LEGACY_RECORD_VERSION: u16 = 0x0303;

/// How many records the server flight spans: ServerHello, ChangeCipherSpec, and the
/// encrypted rest of the flight.
const SERVER_FLIGHT_RECORDS = 3;

/// 32 fresh random bytes, for the hello random or the ephemeral secret.
fn randomBytes(io: std.Io) [32]u8 {
    var bytes: [32]u8 = undefined;
    io.random(&bytes);

    return bytes;
}

/// Wrap a handshake message into one plaintext record.
fn handshakeRecord(message: []const u8, out: []u8) []const u8 {
    out[0] = CONTENT_TYPE_HANDSHAKE;
    std.mem.writeInt(u16, out[1..3], LEGACY_RECORD_VERSION, .big);
    std.mem.writeInt(u16, out[3..5], @intCast(message.len), .big);
    @memcpy(out[RECORD_HEADER_LEN..][0..message.len], message);

    return out[0 .. RECORD_HEADER_LEN + message.len];
}

// --------------------------------------------------------- //
// Public:

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const now_sec = std.Io.Timestamp.now(io, .real).toSeconds();
    const address = try std.Io.net.IpAddress.parse(SERVER_ADDRESS, SERVER_PORT);

    var cert_buf: [1024]u8 = undefined;
    const anchor_der = try tlz.pemToDer(&cert_buf, CERT_PEM);

    const stream = try address.connect(io, .{
        .mode = .stream,
    });
    defer stream.close(io);

    var read_buf: [MAX_RECORD]u8 = undefined;
    var write_buf: [MAX_RECORD]u8 = undefined;
    var stream_reader = stream.reader(io, &read_buf);
    var stream_writer = stream.writer(io, &write_buf);
    const reader = &stream_reader.interface;
    const writer = &stream_writer.interface;

    // Flight 1: the ClientHello
    var hello_buf: [512]u8 = undefined;
    var hello_record_buf: [512]u8 = undefined;
    const started = try tlz.Client.start(.{
        .client_random = randomBytes(io),
        .ephemeral_secret = randomBytes(io),
    }, &hello_buf);
    var state = started.state;

    try sendAll(writer, handshakeRecord(started.client_hello, &hello_record_buf));

    // Flight 2: the server records, back to back
    var flight_buf: [3 * MAX_RECORD]u8 = undefined;
    var flight_len: usize = 0;

    for (0..SERVER_FLIGHT_RECORDS) |_| {
        flight_len += (try readRecord(reader, flight_buf[flight_len..])).len;
    }

    // Flight 3: check the server, then send the client Finished
    var finished_buf: [256]u8 = undefined;
    var client = try tlz.Client.finish(&state, flight_buf[0..flight_len], &finished_buf);

    try client.verifyServerCert(anchor_der, HOST, now_sec);
    try sendAll(writer, client.client_finished);

    std.debug.print("handshake done with {s}:{d}\n", .{ SERVER_ADDRESS, SERVER_PORT });

    var sealed_buf: [MAX_RECORD]u8 = undefined;
    var record_buf: [MAX_RECORD]u8 = undefined;
    var plain_buf: [MAX_RECORD]u8 = undefined;

    for (MESSAGES) |message| {
        try sendAll(writer, client.connection.writeAppData(message, &sealed_buf));

        const reply = try client.connection.readAppData(
            try readRecord(reader, &record_buf),
            &plain_buf,
        );

        std.debug.print("sent: {s}, got back: {s}\n", .{ message, reply });
    }

    try sendAll(writer, client.connection.closeNotify(&sealed_buf));
}

