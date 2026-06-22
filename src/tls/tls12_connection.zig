//! TLS 1.2 server handshake (RFC 5246 + 5288, ECDHE-ECDSA, AES-128-GCM). Sans-I/O, two phases:
//!   - serverFlight1: consume ClientHello, emit ServerHello + Certificate + ServerKeyExchange +
//!     ServerHelloDone (plaintext), and return the State (randoms, server ephemeral, running
//!     transcript) needed to finish.
//!   - serverFinish: consume ClientKeyExchange + the encrypted client Finished, derive the keys,
//!     verify the client Finished, emit ChangeCipherSpec + the encrypted server Finished, and
//!     return the post-handshake Connection.
//! Composes the verified blocks: tls12_prf (key schedule), tls12_record (AEAD), tls12_version
//! (downgrade sentinel), plus secp256r1 ECDHE and an ECDSA-signed ServerKeyExchange. The 1.3 path
//! (connection.zig) is untouched. Cross-version branch + serve-loop wiring land separately, and the
//! RFC wire-correctness is gated by an openssl -tls1_2 cross-check (verify-tls12.md), not this file.

const std = @import("std");
const wire = @import("wire.zig");
const handshake = @import("handshake.zig");
const prf = @import("tls12_prf.zig");
const record = @import("tls12_record.zig");
const version = @import("tls12_version.zig");

const P256 = std.crypto.ecc.P256;
const EcdsaP256 = std.crypto.sign.ecdsa.EcdsaP256Sha256;
const Sha256 = std.crypto.hash.sha2.Sha256;

const cipher_ecdhe_ecdsa_aes128_gcm: u16 = 0xC02B;
const named_curve_secp256r1: u16 = 0x0017;
const sig_ecdsa_secp256r1_sha256: u16 = 0x0403;

const hs_server_hello: u8 = 2;
const hs_certificate: u8 = 11;
const hs_server_key_exchange: u8 = 12;
const hs_server_hello_done: u8 = 14;
const hs_client_key_exchange: u8 = 16;
const hs_finished: u8 = 20;

const content_handshake: u8 = 22;
const version_tls_1_2: u16 = 0x0303;

/// Caller-supplied identity + per-connection randomness (fresh in production, fixed in tests).
pub const HandshakeOptions = struct {
    certificate_der: []const u8,
    signing_key: EcdsaP256.KeyPair,
    server_eph_secret: [32]u8,
    server_random: [32]u8,
};

/// Carried from flight 1 into finish: the randoms, the server ephemeral scalar, and the running
/// handshake transcript hash.
pub const State = struct {
    client_random: [32]u8,
    server_random: [32]u8,
    server_eph_scalar: [32]u8,
    transcript: Sha256,
};

pub const Flight1 = struct {
    to_send: []const u8,
    state: State,
};

pub const FinishResult = struct {
    to_send: []const u8,
    connection: Connection,
};

/// Post-handshake keys + per-direction sequence numbers (both start at 1, after the seq-0 Finished).
pub const Connection = struct {
    km: prf.KeyMaterial,
    server_seq: u64 = 1,
    client_seq: u64 = 1,

    pub fn writeAppData(self: *Connection, plaintext: []const u8, out: []u8) []const u8 {
        const rec = record.protect(out, plaintext, 23, self.km.server_write_key, self.km.server_write_iv, self.server_seq);
        self.server_seq += 1;

        return rec;
    }

    pub fn readAppData(self: *Connection, rec: []const u8, out: []u8) record.Error![]const u8 {
        const plain = try record.deprotect(out, rec, self.km.client_write_key, self.km.client_write_iv, self.client_seq);
        self.client_seq += 1;

        return plain;
    }
};

// --------------------------------------------------------------- //

fn reduceP256Scalar(seed: [32]u8) [32]u8 {
    var wide: [48]u8 = std.mem.zeroes([48]u8);
    @memcpy(wide[16..48], &seed);

    return P256.scalar.Scalar.fromBytes48(wide, .big).toBytes(.big);
}

fn ecdheSharedX(my_scalar: [32]u8, peer_public: []const u8) ![32]u8 {
    const peer = try P256.fromSec1(peer_public);
    const shared = try peer.mul(my_scalar, .big);

    return shared.affineCoordinates().x.toBytes(.big);
}

/// Phase 1: ClientHello -> ServerHello + Certificate + ServerKeyExchange + ServerHelloDone, as one
/// plaintext handshake record. The downgrade sentinel is planted when the client was 1.3-capable.
pub fn serverFlight1(opts: HandshakeOptions, client_hello: []const u8, out: []u8) !Flight1 {
    const parsed = handshake.parseClientHello(client_hello);
    if (parsed != .ok) return error.ClientHelloInvalid;
    const hello = parsed.ok;

    var state: State = undefined;
    state.client_random = hello.random;
    state.server_random = opts.server_random;
    if (hello.offers_tls13) version.applyDowngradeSentinel(&state.server_random, .TLS_1_2);
    state.server_eph_scalar = reduceP256Scalar(opts.server_eph_secret);
    state.transcript = Sha256.init(.{});
    state.transcript.update(client_hello);

    const server_point = (try P256.basePoint.mul(state.server_eph_scalar, .big)).toUncompressedSec1();

    var w = wire.Writer{ .buf = out };
    w.writeU8(content_handshake);
    w.writeU16(version_tls_1_2);
    const rec_len = w.placeU16();
    const body_start = w.len;

    writeServerHello(&w, state.server_random, hello.session_id);
    writeCertificate(&w, opts.certificate_der);
    try writeServerKeyExchange(&w, opts.signing_key, state.client_random, state.server_random, &server_point);
    w.writeU8(hs_server_hello_done);
    w.writeU24(0);

    state.transcript.update(w.buf[body_start..w.len]);
    w.patchU16(rec_len);

    return .{ .to_send = w.slice(), .state = state };
}

fn writeServerHello(w: *wire.Writer, server_random: [32]u8, session_id: []const u8) void {
    w.writeU8(hs_server_hello);
    const header = w.placeU24();

    w.writeU16(version_tls_1_2);
    w.writeBytes(&server_random);
    w.writeU8(@intCast(session_id.len));
    w.writeBytes(session_id);
    w.writeU16(cipher_ecdhe_ecdsa_aes128_gcm);
    w.writeU8(0); // null compression
    w.writeU16(0); // no extensions (renegotiation_info / ec_point_formats added at integration)

    w.patchU24(header);
}

fn writeCertificate(w: *wire.Writer, der: []const u8) void {
    w.writeU8(hs_certificate);
    const header = w.placeU24();
    const list = w.placeU24();
    const cert = w.placeU24();

    w.writeBytes(der);

    w.patchU24(cert);
    w.patchU24(list);
    w.patchU24(header);
}

fn writeServerKeyExchange(w: *wire.Writer, key: EcdsaP256.KeyPair, client_random: [32]u8, server_random: [32]u8, point: []const u8) !void {
    w.writeU8(hs_server_key_exchange);
    const header = w.placeU24();
    const params_start = w.len;

    w.writeU8(3); // ECCurveType named_curve
    w.writeU16(named_curve_secp256r1);
    w.writeU8(@intCast(point.len));
    w.writeBytes(point);
    const params = w.buf[params_start..w.len];

    // signature over client_random ++ server_random ++ params (RFC 5246 7.4.3).
    var signed: [32 + 32 + 70]u8 = undefined;
    @memcpy(signed[0..32], &client_random);
    @memcpy(signed[32..64], &server_random);
    @memcpy(signed[64 .. 64 + params.len], params);
    const sig = try key.sign(signed[0 .. 64 + params.len], null);

    var der_buf: [EcdsaP256.Signature.der_encoded_length_max]u8 = undefined;
    const der = sig.toDer(&der_buf);

    w.writeU16(sig_ecdsa_secp256r1_sha256);
    const sig_len = w.placeU16();
    w.writeBytes(der);
    w.patchU16(sig_len);

    w.patchU24(header);
}

/// Phase 2: ClientKeyExchange + the encrypted client Finished -> derive keys, verify the client
/// Finished, emit ChangeCipherSpec + the encrypted server Finished, return the Connection.
pub fn serverFinish(state: *State, client_key_exchange: []const u8, client_finished_record: []const u8, out: []u8) !FinishResult {
    var r = wire.Reader{ .buf = client_key_exchange };
    if (try r.readU8() != hs_client_key_exchange) return error.UnexpectedMessage;
    _ = try r.readU24();
    const point_len = try r.readU8();
    const client_point = try r.readBytes(point_len);

    state.transcript.update(client_key_exchange);

    const pre_master = try ecdheSharedX(state.server_eph_scalar, client_point);
    const master = prf.masterSecret(&pre_master, state.client_random, state.server_random);
    const km = prf.keyMaterial(master, state.client_random, state.server_random);

    // verify the client Finished (encrypted under the client key, seq 0), transcript = CH..CKE.
    const expected = prf.finishedFromHash(master, "client finished", transcriptHash(state));
    var cf_plain: [64]u8 = undefined;
    const cf = try record.deprotect(&cf_plain, client_finished_record, km.client_write_key, km.client_write_iv, 0);
    if (cf.len < 16 or cf[0] != hs_finished) return error.UnexpectedMessage;
    if (!std.mem.eql(u8, cf[4..16], &expected)) return error.ClientFinishedMismatch;

    state.transcript.update(cf);

    // server Finished over CH..clientFinished.
    const server_vd = prf.finishedFromHash(master, "server finished", transcriptHash(state));
    var fin_msg: [16]u8 = undefined;
    fin_msg[0] = hs_finished;
    fin_msg[1] = 0;
    fin_msg[2] = 0;
    fin_msg[3] = 12;
    @memcpy(fin_msg[4..16], &server_vd);

    // ChangeCipherSpec record (plaintext) then the encrypted Finished record (outer type handshake).
    out[0] = 20; // change_cipher_spec
    out[1] = 0x03;
    out[2] = 0x03;
    out[3] = 0x00;
    out[4] = 0x01;
    out[5] = 0x01;
    const enc = record.protect(out[6..], &fin_msg, content_handshake, km.server_write_key, km.server_write_iv, 0);

    return .{ .to_send = out[0 .. 6 + enc.len], .connection = .{ .km = km } };
}

fn transcriptHash(state: *const State) [32]u8 {
    var copy = state.transcript;
    var hash: [32]u8 = undefined;
    copy.final(&hash);

    return hash;
}

// --------------------------------------------------------------- //
// --------------------------------------------------------------- //

test "zix test: tls12 connection, in-memory ECDHE-ECDSA handshake round trip" {
    // server identity (fixed scalar for determinism).
    var skey: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&skey, "0b76f7f1c7bf6e20029ddb566795e58da5ba63ffbdb914bf699bfbed3147d32c");
    const key = try EcdsaP256.KeyPair.fromSecretKey(try EcdsaP256.SecretKey.fromBytes(skey));
    const dummy_der = [_]u8{ 0x30, 0x03, 0x01, 0x02, 0x03 };

    // a minimal TLS 1.2 ClientHello (1.2-only: no supported_versions, so no downgrade sentinel).
    var ch_buf: [128]u8 = undefined;
    var cw = wire.Writer{ .buf = &ch_buf };
    cw.writeU8(1); // client_hello
    const ch_hdr = cw.placeU24();
    cw.writeU16(version_tls_1_2);
    const client_random: [32]u8 = @splat(0x11);
    cw.writeBytes(&client_random);
    cw.writeU8(0); // session_id
    cw.writeU16(2); // cipher_suites len
    cw.writeU16(cipher_ecdhe_ecdsa_aes128_gcm);
    cw.writeU8(1); // compression len
    cw.writeU8(0);
    cw.writeU16(0); // no extensions
    cw.patchU24(ch_hdr);
    const client_hello = cw.slice();

    var flight_buf: [4096]u8 = undefined;
    const flight = try serverFlight1(.{
        .certificate_der = &dummy_der,
        .signing_key = key,
        .server_eph_secret = @splat(0x22),
        .server_random = @splat(0x33),
    }, client_hello, &flight_buf);
    var state = flight.state;

    // --- play an honest client: parse the flight for the server ECDHE point + server_random ---
    const body = flight.to_send[5..];
    var br = wire.Reader{ .buf = body };
    var server_point: []const u8 = &.{};
    var server_random_seen: [32]u8 = undefined;
    while (br.remaining() >= 4) {
        const msg_type = try br.readU8();
        const msg_len = try br.readU24();
        const msg = try br.readBytes(msg_len);
        if (msg_type == hs_server_hello) {
            @memcpy(&server_random_seen, msg[2..34]); // skip version(2), take random(32)
        } else if (msg_type == hs_server_key_exchange) {
            // curve_type(1) + named_curve(2) + point_len(1) + point
            server_point = msg[4 .. 4 + msg[3]];
        }
    }
    try std.testing.expectEqual(@as(usize, 65), server_point.len);

    // client ECDHE + key schedule.
    const c_scalar = reduceP256Scalar(@splat(0x44));
    const c_point = (try P256.basePoint.mul(c_scalar, .big)).toUncompressedSec1();
    const pre = try ecdheSharedX(c_scalar, server_point);
    const master = prf.masterSecret(&pre, client_random, server_random_seen);
    const km = prf.keyMaterial(master, client_random, server_random_seen);

    // ClientKeyExchange.
    var cke: [4 + 1 + 65]u8 = undefined;
    cke[0] = hs_client_key_exchange;
    cke[1] = 0;
    cke[2] = 0;
    cke[3] = 1 + 65;
    cke[4] = 65;
    @memcpy(cke[5..], &c_point);

    // client transcript = CH ++ flight body ++ CKE -> client Finished verify_data.
    var ct = Sha256.init(.{});
    ct.update(client_hello);
    ct.update(body);
    ct.update(&cke);
    var ch_cke_hash: [32]u8 = undefined;
    {
        var copy = ct;
        copy.final(&ch_cke_hash);
    }
    const client_vd = prf.finishedFromHash(master, "client finished", ch_cke_hash);

    var cf_msg: [16]u8 = undefined;
    cf_msg[0] = hs_finished;
    cf_msg[1] = 0;
    cf_msg[2] = 0;
    cf_msg[3] = 12;
    @memcpy(cf_msg[4..16], &client_vd);

    var cf_rec_buf: [128]u8 = undefined;
    const cf_rec = record.protect(&cf_rec_buf, &cf_msg, content_handshake, km.client_write_key, km.client_write_iv, 0);

    // --- server finishes ---
    var out_buf: [256]u8 = undefined;
    var fin = try serverFinish(&state, &cke, cf_rec, &out_buf);

    // client verifies the server Finished: skip the 6-byte CCS, decrypt the rest.
    const server_fin_rec = fin.to_send[6..];
    var sf_plain: [64]u8 = undefined;
    const sf = try record.deprotect(&sf_plain, server_fin_rec, km.server_write_key, km.server_write_iv, 0);
    try std.testing.expectEqual(hs_finished, sf[0]);

    ct.update(&cf_msg); // CH..clientFinished
    var ch_cf_hash: [32]u8 = undefined;
    ct.final(&ch_cf_hash);
    const expect_server_vd = prf.finishedFromHash(master, "server finished", ch_cf_hash);
    try std.testing.expectEqualSlices(u8, &expect_server_vd, sf[4..16]);

    // application-data round trip on the established Connection.
    var app_buf: [128]u8 = undefined;
    const app_rec = fin.connection.writeAppData("hello over tls 1.2", &app_buf);
    var app_plain: [128]u8 = undefined;
    const got = try record.deprotect(&app_plain, app_rec, km.server_write_key, km.server_write_iv, 1);
    try std.testing.expectEqualSlices(u8, "hello over tls 1.2", got);
}
