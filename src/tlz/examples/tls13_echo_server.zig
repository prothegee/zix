//! TLZ example tls13_echo_server
//!
//! ### file: src/tlz/examples/tls13_echo_server.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! A TLS 1.3 echo server over TCP: one handshake per connection, then every record
//! the client sends comes back unchanged until the client closes.
//!
//! ### note:
//!
//! The certificate and key are a self-signed `localhost` test fixture. Never use them
//! for a real server. Connections are served one at a time, to keep the flow plain.
//! Build with `zig build example-tls13_echo_server` from `src/tlz`, run it, then run
//! the `tls13_echo_client` example (or `openssl s_client -connect 127.0.0.1:8443`).
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

const EcdsaP256 = std.crypto.sign.ecdsa.EcdsaP256Sha256;

// --------------------------------------------------------- //
// Private:

/// Self-signed ECDSA P-256 certificate for `localhost`, valid 2026-06-22 to 2036-06-19.
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

/// The private scalar of the key that signs `CERT_PEM`.
const KEY_SCALAR_HEX = "0b76f7f1c7bf6e20029ddb566795e58da5ba63ffbdb914bf699bfbed3147d32c";

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

/// The record type of a ChangeCipherSpec. A TLS 1.3 client may send one before its
/// Finished for middlebox compatibility (RFC 8446 D.4), and it carries nothing.
const CONTENT_TYPE_CHANGE_CIPHER_SPEC: u8 = 20;

/// The record type of a plaintext handshake record (the ClientHello).
const CONTENT_TYPE_HANDSHAKE: u8 = 22;

/// The next record that is not a compatibility ChangeCipherSpec.
fn readRecordSkipCcs(reader: *std.Io.Reader, buf: []u8) ![]const u8 {
    while (true) {
        const rec = try readRecord(reader, buf);

        if (rec[0] != CONTENT_TYPE_CHANGE_CIPHER_SPEC) return rec;
    }
}

/// The server signing key, rebuilt from `KEY_SCALAR_HEX`.
fn serverKey() !EcdsaP256.KeyPair {
    var scalar: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&scalar, KEY_SCALAR_HEX);

    return EcdsaP256.KeyPair.fromSecretKey(try EcdsaP256.SecretKey.fromBytes(scalar));
}

/// 32 fresh random bytes, for a hello random or an ephemeral secret.
fn randomBytes(io: std.Io) [32]u8 {
    var bytes: [32]u8 = undefined;
    io.random(&bytes);

    return bytes;
}

/// Run one connection: the handshake, then echo until the client closes.
///
/// Param:
/// io - std.Io (the I/O the stream runs on)
/// stream - std.Io.net.Stream (the accepted connection)
/// cert_der - []const u8 (the server certificate)
///
/// Return:
/// - void when the client closed cleanly
/// - an error when the handshake or a record fails
fn serveConnection(io: std.Io, stream: std.Io.net.Stream, cert_der: []const u8) !void {
    var read_buf: [MAX_RECORD]u8 = undefined;
    var write_buf: [MAX_RECORD]u8 = undefined;
    var stream_reader = stream.reader(io, &read_buf);
    var stream_writer = stream.writer(io, &write_buf);
    const reader = &stream_reader.interface;
    const writer = &stream_writer.interface;

    var record_buf: [MAX_RECORD]u8 = undefined;
    const hello_record = try readRecord(reader, &record_buf);
    if (hello_record[0] != CONTENT_TYPE_HANDSHAKE) return error.NotHandshake;

    var flight_buf: [4096]u8 = undefined;
    var server = tlz.serverHandshake(.{
        .certificate_der = cert_der,
        .signing_key = .{ .ecdsa_p256 = try serverKey() },
        .ephemeral_secret = randomBytes(io),
        .server_random = randomBytes(io),
    }, hello_record[RECORD_HEADER_LEN..], &flight_buf) catch |err| {
        // Tell the client why, when the error has a matching alert
        var alert_buf: [tlz.FATAL_RECORD_LEN]u8 = undefined;
        if (tlz.alertRecordForError(&alert_buf, err)) |alert_record| {
            try sendAll(writer, alert_record);
        }

        return err;
    };

    try sendAll(writer, server.to_send);
    try server.connection.verifyClientFinished(try readRecordSkipCcs(reader, &record_buf));

    std.debug.print("handshake done\n", .{});

    var plain_buf: [MAX_RECORD]u8 = undefined;
    var sealed_buf: [MAX_RECORD]u8 = undefined;

    while (true) {
        // A peer that drops the socket without close_notify ends the echo the same way
        const rec = readRecord(reader, &record_buf) catch |err| switch (err) {
            error.EndOfStream => return,
            else => return err,
        };
        const data = server.connection.readAppData(rec, &plain_buf) catch |err| switch (err) {
            error.Tlz_ServerConnection_PeerClosed => {
                try sendAll(writer, server.connection.closeNotify(&sealed_buf));

                return;
            },
            else => return err,
        };

        std.debug.print("echo: {s}\n", .{data});

        try sendAll(writer, server.connection.writeAppData(data, &sealed_buf));
    }
}

// --------------------------------------------------------- //
// Public:

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const address = try std.Io.net.IpAddress.parse(SERVER_ADDRESS, SERVER_PORT);

    var cert_buf: [1024]u8 = undefined;
    const cert_der = try tlz.pemToDer(&cert_buf, CERT_PEM);

    var listener = try address.listen(io, .{
        .reuse_address = true,
    });
    defer listener.deinit(io);

    std.debug.print("tlz echo server on {s}:{d}\n", .{ SERVER_ADDRESS, SERVER_PORT });

    while (true) {
        const stream = try listener.accept(io);
        defer stream.close(io);

        serveConnection(io, stream, cert_der) catch |err| {
            std.debug.print("connection ended: {t}\n", .{err});
        };
    }
}

