//! TLZ example bench_record
//!
//! ### file: src/tlz/examples/bench_record.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! What the TLS 1.3 record layer costs for full 16 KiB records under
//! TLS_AES_128_GCM_SHA256: the server seals, the client opens, in MB/s.
//!
//! ### note:
//!
//! Build with `-Doptimize=ReleaseFast`. A Debug build measures the safety checks
//! rather than the record layer. The quickest of ROUNDS is reported, not the mean.
//! The connection pair comes from a real in-memory handshake, so the numbers include
//! everything one application record does (header, inner type byte, AES-128-GCM,
//! sequence nonce). Every opened record is checked against the sent bytes before
//! any timing. The reference is `openssl speed -evp aes-128-gcm -bytes 16384`
//! (raw AEAD, no record framing). MB is 1,000,000 bytes, the same unit
//! `openssl speed` prints. Build with `zig build example-bench_record
//! -Doptimize=ReleaseFast` from `src/tlz`, then run
//! `./zig-out/bin/tlz-example-bench_record-<arch>-<os>-fast`.
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

/// Records sealed, then opened, per batch. One batch of wire records stays in memory.
const BATCH: usize = 64;

/// Batches one round does: 64 x 64 records of 16 KiB is 64 MiB of plaintext.
const BATCHES: usize = 64;

/// Rounds run per row. The quickest is what gets reported.
const ROUNDS: usize = 5;

/// The plaintext of every record: one full record, the largest TLS allows.
const PAYLOAD_BYTES = tlz.MAX_PLAINTEXT;

/// The wire size of one full record.
const RECORD_BYTES = tlz.sealedLen(PAYLOAD_BYTES);

/// The two ends of one finished in-memory TLS 1.3 handshake.
const ConnectionPair = struct {
    server: tlz.Connection,
    client: @FieldType(tlz.Client.FinishResult, "connection"),
};

/// The quickest seal and open time of all rounds.
const Timings = struct {
    seal_ns: u64,
    open_ns: u64,
};

/// Nanoseconds since `started` on the monotonic clock.
fn since(io: std.Io, started: std.Io.Timestamp) u64 {
    const ended = std.Io.Timestamp.now(io, .awake);

    return @intCast(started.durationTo(ended).nanoseconds);
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

/// Run one full in-memory handshake (same flights as `tls13_loopback`).
fn handshake(io: std.Io) !ConnectionPair {
    var cert_buf: [1024]u8 = undefined;
    const cert_der = try tlz.pemToDer(&cert_buf, CERT_PEM);

    var hello_buf: [512]u8 = undefined;
    const started = try tlz.Client.start(.{
        .client_random = randomBytes(io),
        .ephemeral_secret = randomBytes(io),
    }, &hello_buf);
    var client_state = started.state;

    var server_out: [4096]u8 = undefined;
    var server = try tlz.serverHandshake(.{
        .certificate_der = cert_der,
        .signing_key = .{ .ecdsa_p256 = try serverKey() },
        .ephemeral_secret = randomBytes(io),
        .server_random = randomBytes(io),
    }, started.client_hello, &server_out);

    var finished_buf: [256]u8 = undefined;
    const client = try tlz.Client.finish(&client_state, server.to_send, &finished_buf);

    try server.connection.verifyClientFinished(client.client_finished);

    return .{
        .server = server.connection,
        .client = client.connection,
    };
}

/// Seal BATCH records on the server end into `wire`.
fn sealBatch(pair: *ConnectionPair, payload: []const u8, wire: []u8) !void {
    for (0..BATCH) |index| {
        const out = wire[index * RECORD_BYTES ..][0..RECORD_BYTES];
        const sealed = pair.server.writeAppData(payload, out);

        if (sealed.len != RECORD_BYTES) return error.SealFailed;
    }
}

/// Open the BATCH records in `wire` on the client end.
fn openBatch(pair: *ConnectionPair, wire: []const u8, plain: []u8) !void {
    for (0..BATCH) |index| {
        const rec = wire[index * RECORD_BYTES ..][0..RECORD_BYTES];
        const opened = try pair.client.readAppData(rec, plain);

        std.mem.doNotOptimizeAway(opened.ptr);
    }
}

/// Check one batch opens back to the sent bytes, so the table times real records.
fn checkRoundTrip(pair: *ConnectionPair, payload: []const u8, wire: []u8, plain: []u8) !void {
    try sealBatch(pair, payload, wire);

    for (0..BATCH) |index| {
        const rec = wire[index * RECORD_BYTES ..][0..RECORD_BYTES];
        const opened = try pair.client.readAppData(rec, plain);

        if (!std.mem.eql(u8, payload, opened)) return error.RoundTripMismatch;
    }
}

/// Seal and open BATCHES batches, ROUNDS times over, timing each side apart.
///
/// Return:
/// - Timings (the quickest round of each side)
fn timeRecords(
    io: std.Io,
    pair: *ConnectionPair,
    payload: []const u8,
    wire: []u8,
    plain: []u8,
) !Timings {
    var best: Timings = .{
        .seal_ns = std.math.maxInt(u64),
        .open_ns = std.math.maxInt(u64),
    };

    for (0..ROUNDS) |_| {
        var seal_ns: u64 = 0;
        var open_ns: u64 = 0;

        for (0..BATCHES) |_| {
            const seal_started = std.Io.Timestamp.now(io, .awake);
            try sealBatch(pair, payload, wire);
            seal_ns += since(io, seal_started);

            const open_started = std.Io.Timestamp.now(io, .awake);
            try openBatch(pair, wire, plain);
            open_ns += since(io, open_started);
        }

        best.seal_ns = @min(best.seal_ns, seal_ns);
        best.open_ns = @min(best.open_ns, open_ns);
    }

    return best;
}

/// Print one row: us per record and MB per second of plaintext.
fn printRow(name: []const u8, elapsed: u64) void {
    const records: f64 = @floatFromInt(BATCH * BATCHES);
    const per_record_ns = @as(f64, @floatFromInt(elapsed)) / records;
    const per_record_us = per_record_ns / @as(f64, std.time.ns_per_us);
    const bytes_per_s = @as(f64, PAYLOAD_BYTES) * @as(f64, std.time.ns_per_s) / per_record_ns;

    std.debug.print("{s: <8}{d: >12.2}{d: >12.0}\n", .{
        name,
        per_record_us,
        bytes_per_s / 1_000_000,
    });
}

// --------------------------------------------------------- //
// Public:

// main takes std.process.Init for io (the clock and the handshake randoms) and gpa
// (one batch of wire records, about 1 MiB, too large for the stack).
pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var pair = try handshake(init.io);

    const wire = try allocator.alloc(u8, BATCH * RECORD_BYTES);
    defer allocator.free(wire);

    var payload: [PAYLOAD_BYTES]u8 = undefined;
    var plain: [RECORD_BYTES]u8 = undefined;
    init.io.random(&payload);

    try checkRoundTrip(&pair, &payload, wire, &plain);

    std.debug.print("record aes-128-gcm: {d} records of {d} bytes per round, " ++
        "quickest of {d} rounds\n\n", .{
        BATCH * BATCHES,
        PAYLOAD_BYTES,
        ROUNDS,
    });
    std.debug.print("{s: <8}{s: >12}{s: >12}\n", .{
        "side",
        "us/record",
        "MB/s",
    });

    const timings = try timeRecords(init.io, &pair, &payload, wire, &plain);

    printRow("seal", timings.seal_ns);
    printRow("open", timings.open_ns);
}

