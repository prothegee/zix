//! TLZ example dtls_loopback
//!
//! ### file: src/tlz/examples/dtls_loopback.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! A full DTLS 1.2 handshake (cookie exchange included) between the tlz client and the
//! tlz server in memory, then one datagram each way. No socket: the datagrams move
//! through local buffers.
//!
//! ### note:
//!
//! The certificate and key are a self-signed `localhost` test fixture. Never use them
//! for a real server. Build with `zig build example-dtls_loopback` from `src/tlz`.
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

const CLIENT_MESSAGE = "ping over dtls";
const SERVER_MESSAGE = "pong over dtls";

/// The client address the server binds its cookie to.
const CLIENT_ADDRESS = "127.0.0.1";
const CLIENT_PORT: u16 = 41000;

/// The most handshake messages one server flight carries.
const MAX_FLIGHT_MESSAGES = 8;

/// The handshake body inside a single-message plaintext record (header stripped).
fn messageBody(datagram: []const u8) ![]const u8 {
    const fragment = try tlz.Dtls.record.plaintextFragment(datagram);

    return fragment[tlz.Dtls.handshake.HEADER_LEN..];
}

/// The bodies of the handshake messages packed into a flight, in arrival order.
fn collectBodies(flight: []const u8, out: *[MAX_FLIGHT_MESSAGES][]const u8) !usize {
    var records: tlz.Dtls.record.RecordIterator = .{ .datagram = flight };
    var count: usize = 0;

    while (try records.next()) |rec| {
        var fragments: tlz.Dtls.handshake.FragmentIterator = .{
            .body = try tlz.Dtls.record.plaintextFragment(rec),
        };

        while (try fragments.next()) |fragment| : (count += 1) {
            if (count == out.len) return error.TooManyMessages;

            out[count] = fragment.data;
        }
    }

    return count;
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
    const peer = try std.Io.net.IpAddress.parse(CLIENT_ADDRESS, CLIENT_PORT);

    var cert_buf: [1024]u8 = undefined;
    const cert_der = try tlz.pemToDer(&cert_buf, CERT_PEM);

    const signer: tlz.Dtls.cookie.Signer = .init(randomBytes(io));
    var client_state = tlz.Dtls.Client.start(.{
        .client_random = randomBytes(io),
        .client_eph_secret = randomBytes(io),
    });

    // Flight 1 and 2: a hello without a cookie, answered by HelloVerifyRequest
    var first_hello_buf: [512]u8 = undefined;
    var verify_buf: [512]u8 = undefined;
    const first_hello = try tlz.Dtls.Client.writeHello(&client_state, "", &first_hello_buf);
    const verify_request = try tlz.Dtls.Server.serverHelloVerifyRequest(
        &signer,
        peer,
        try tlz.Dtls.hello.parseClientHello(try messageBody(first_hello)),
        0,
        &verify_buf,
    );
    const cookie = try tlz.Dtls.hello.parseHelloVerifyRequestBody(
        try messageBody(verify_request),
    );

    // Flight 3: the hello again, now carrying the cookie
    var second_hello_buf: [512]u8 = undefined;
    const second_hello = try tlz.Dtls.Client.writeHello(
        &client_state,
        cookie,
        &second_hello_buf,
    );
    const second_body = try messageBody(second_hello);
    const second_parsed = try tlz.Dtls.hello.parseClientHello(second_body);

    if (!tlz.Dtls.Server.cookieAccepted(&signer, peer, second_parsed)) {
        return error.CookieRejected;
    }

    // Flight 4, server: ServerHello, Certificate, ServerKeyExchange, ServerHelloDone
    var server_flight_buf: [4096]u8 = undefined;
    const server_flight = try tlz.Dtls.Server.serverFlight(.{
        .certificate_der = cert_der,
        .signing_key = try serverKey(),
        .server_eph_secret = randomBytes(io),
        .server_random = randomBytes(io),
    }, second_body, &server_flight_buf);
    var server_state = server_flight.state;

    var bodies: [MAX_FLIGHT_MESSAGES][]const u8 = undefined;
    const body_count = try collectBodies(server_flight.to_send, &bodies);
    if (body_count != 4) return error.UnexpectedServerFlight;

    // Flight 5, client: ClientKeyExchange, ChangeCipherSpec, Finished
    var client_flight_buf: [1024]u8 = undefined;
    const client_done = try tlz.Dtls.Client.finish(&client_state, .{
        .server_hello = bodies[0],
        .certificate = bodies[1],
        .key_exchange = bodies[2],
        .hello_done = bodies[3],
    }, &client_flight_buf);

    var client_records: tlz.Dtls.record.RecordIterator = .{
        .datagram = client_done.to_send,
    };
    const key_exchange_record = (try client_records.next()) orelse return error.NoRecord;
    _ = try client_records.next();
    const client_finished_record = (try client_records.next()) orelse return error.NoRecord;

    // Flight 6, server: ChangeCipherSpec and Finished
    var server_done_buf: [512]u8 = undefined;
    var server_done = try tlz.Dtls.Server.serverFinish(
        &server_state,
        try messageBody(key_exchange_record),
        client_finished_record,
        &server_done_buf,
    );

    var server_records: tlz.Dtls.record.RecordIterator = .{
        .datagram = server_done.to_send,
    };
    _ = try server_records.next();
    const server_finished_record = (try server_records.next()) orelse return error.NoRecord;

    var client = client_done.connection;
    var finished_plain: [128]u8 = undefined;
    const finished = (try client.readRecord(server_finished_record, &finished_plain)) orelse
        return error.NoRecord;
    const verify_data = tlz.Dtls.Client.serverFinishedVerifyData(finished) orelse
        return error.NotFinished;

    if (!std.mem.eql(u8, verify_data, &client_done.server_verify_data)) {
        return error.ServerFinishedMismatch;
    }

    std.debug.print("DTLS 1.2 handshake done\n", .{});

    // Application data, one datagram each way
    var to_server_buf: [256]u8 = undefined;
    var to_client_buf: [256]u8 = undefined;
    var server_plain: [256]u8 = undefined;
    var client_plain: [256]u8 = undefined;

    const to_server = try client.writeAppData(CLIENT_MESSAGE, &to_server_buf);
    const to_client = try server_done.connection.writeAppData(SERVER_MESSAGE, &to_client_buf);

    const server_got = (try server_done.connection.readAppData(to_server, &server_plain)) orelse
        return error.NoRecord;
    const client_got = (try client.readRecord(to_client, &client_plain)) orelse
        return error.NoRecord;

    std.debug.print("server read: {s}\n", .{server_got});
    std.debug.print("client read: {s}\n", .{client_got});
}

