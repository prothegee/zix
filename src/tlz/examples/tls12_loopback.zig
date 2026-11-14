//! TLZ example tls12_loopback
//!
//! ### file: src/tlz/examples/tls12_loopback.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! A full TLS 1.2 handshake (ECDHE-ECDSA) between the tlz client and the tlz server in
//! memory, then one message each way. No socket: the bytes move through local buffers.
//!
//! ### note:
//!
//! The certificate and key are a self-signed `localhost` test fixture. Never use them
//! for a real server. Build with `zig build example-tls12_loopback` from `src/tlz`.
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

/// The name the client expects the certificate to carry.
const HOST = "localhost";

const CLIENT_MESSAGE = "ping over tls 1.2";
const SERVER_MESSAGE = "pong over tls 1.2";

/// The byte length of a TLS record header: type, version, length.
const RECORD_HEADER_LEN = 5;

/// The next whole record (header included) from records packed back to back.
/// `pos` moves past the record it returns.
fn nextRecord(bytes: []const u8, pos: *usize) ![]const u8 {
    const rest = bytes[pos.*..];
    if (rest.len < RECORD_HEADER_LEN) return error.Truncated;

    const body_len = std.mem.readInt(u16, rest[3..5], .big);
    const record_len = RECORD_HEADER_LEN + body_len;
    if (rest.len < record_len) return error.Truncated;

    pos.* += record_len;

    return rest[0..record_len];
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

// --------------------------------------------------------- //
// Public:

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const now_sec = std.Io.Timestamp.now(io, .real).toSeconds();

    var cert_buf: [1024]u8 = undefined;
    const cert_der = try tlz.pemToDer(&cert_buf, CERT_PEM);

    // Flight 1, client: the ClientHello
    var hello_buf: [256]u8 = undefined;
    const started = tlz.Client12.start(.{
        .client_random = randomBytes(io),
        .ephemeral_secret = randomBytes(io),
    }, &hello_buf);
    var client_state = started.state;

    // Flight 2, server: ServerHello, Certificate, ServerKeyExchange, ServerHelloDone
    var flight1_buf: [4096]u8 = undefined;
    const flight1 = try tlz.Server12.serverFlight1(.{
        .certificate_der = cert_der,
        .signing_key = try serverKey(),
        .server_eph_secret = randomBytes(io),
        .server_random = randomBytes(io),
    }, started.client_hello, &flight1_buf);
    var server_state = flight1.state;

    // Flight 3, client: ClientKeyExchange, ChangeCipherSpec, Finished
    var client_flight_buf: [512]u8 = undefined;
    const client_done = try tlz.Client12.finish(
        &client_state,
        flight1.to_send,
        &client_flight_buf,
    );

    try client_done.verifyServerCert(cert_der, HOST, now_sec);

    var client_pos: usize = 0;
    const key_exchange_record = try nextRecord(client_done.to_send, &client_pos);
    _ = try nextRecord(client_done.to_send, &client_pos);
    const client_finished_record = try nextRecord(client_done.to_send, &client_pos);

    // Flight 4, server: ChangeCipherSpec and Finished
    var server_flight_buf: [256]u8 = undefined;
    var server_done = try tlz.Server12.serverFinish(
        &server_state,
        key_exchange_record[RECORD_HEADER_LEN..],
        client_finished_record,
        &server_flight_buf,
    );

    var server_pos: usize = 0;
    _ = try nextRecord(server_done.to_send, &server_pos);
    const server_finished_record = try nextRecord(server_done.to_send, &server_pos);

    var client = client_done.connection;
    try client.verifyServerFinished(
        server_finished_record,
        client_done.expected_server_finished,
    );

    std.debug.print("TLS 1.2 handshake done\n", .{});

    // Application data, one record each way
    var to_server_buf: [256]u8 = undefined;
    var to_client_buf: [256]u8 = undefined;
    var server_plain: [256]u8 = undefined;
    var client_plain: [256]u8 = undefined;

    const to_server = client.writeAppData(CLIENT_MESSAGE, &to_server_buf);
    const to_client = server_done.connection.writeAppData(SERVER_MESSAGE, &to_client_buf);

    const server_got = try server_done.connection.readAppData(to_server, &server_plain);
    const client_got = try client.readAppData(to_client, &client_plain);

    std.debug.print("server read: {s}\n", .{server_got});
    std.debug.print("client read: {s}\n", .{client_got});
}

