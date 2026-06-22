//! TLS 1.2 handshake PoC (RFC 5246 + 5288, ECDHE-ECDSA): the genuinely-new 1.2 crypto, not the
//! message byte-layout (that is mechanical, cross-checked vs openssl at integration). Three pieces:
//!   1. ServerKeyExchange signature over client_random ++ server_random ++ ECDHE params.
//!   2. the PRF key schedule: master_secret -> key_block -> the server Finished verify_data.
//!   3. the ECDHE pre_master (secp256r1 shared X), feeding 2.
//! Closes with an AEAD round trip on the derived keys, tying P + R12 + H12 together. Layer H12 of
//! tls12-plan.md.
//!
//! Run: `zig test rnd/0.5.x/tls12_handshake_poc.zig`

const std = @import("std");

const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const Sha256 = std.crypto.hash.sha2.Sha256;
const Ecdsa = std.crypto.sign.ecdsa.EcdsaP256Sha256;
const P256 = std.crypto.ecc.P256;
const Aes128Gcm = std.crypto.aead.aes_gcm.Aes128Gcm;
const mac_len = HmacSha256.mac_length;

// --------------------------------------------------------------- //
// PRF (RFC 5246 5), same as tls12_prf_poc.zig (kept inline so this PoC stands alone)

fn pSha256(out: []u8, secret: []const u8, seed: []const u8) void {
    var a: [mac_len]u8 = undefined;
    HmacSha256.create(&a, seed, secret);

    var off: usize = 0;
    while (off < out.len) {
        var block: [mac_len]u8 = undefined;
        var ctx = HmacSha256.init(secret);
        ctx.update(&a);
        ctx.update(seed);
        ctx.final(&block);

        const take = @min(mac_len, out.len - off);
        @memcpy(out[off .. off + take], block[0..take]);
        off += take;

        if (off < out.len) {
            var next: [mac_len]u8 = undefined;
            HmacSha256.create(&next, &a, secret);
            a = next;
        }
    }
}

fn prf(out: []u8, secret: []const u8, label: []const u8, seed: []const u8) void {
    var label_seed: [256]u8 = undefined;
    @memcpy(label_seed[0..label.len], label);
    @memcpy(label_seed[label.len .. label.len + seed.len], seed);

    pSha256(out, secret, label_seed[0 .. label.len + seed.len]);
}

// --------------------------------------------------------------- //
// 1.2 key schedule (RFC 5246 6.3, 8.1, 7.4.9) over the PRF

/// master_secret = PRF(pre_master, "master secret", client_random ++ server_random), 48 bytes.
fn masterSecret(pre_master: []const u8, client_random: [32]u8, server_random: [32]u8) [48]u8 {
    var seed: [64]u8 = undefined;
    @memcpy(seed[0..32], &client_random);
    @memcpy(seed[32..64], &server_random);

    var out: [48]u8 = undefined;
    prf(&out, pre_master, "master secret", &seed);

    return out;
}

/// AES-128-GCM key material from key_block = PRF(master, "key expansion", server_random ++
/// client_random). GCM has no MAC keys, so the block is 2x16 write_key + 2x4 write_IV = 40 bytes.
const KeyMaterial = struct {
    client_write_key: [16]u8,
    server_write_key: [16]u8,
    client_write_iv: [4]u8,
    server_write_iv: [4]u8,
};

fn keyMaterial(master: [48]u8, client_random: [32]u8, server_random: [32]u8) KeyMaterial {
    var seed: [64]u8 = undefined;
    @memcpy(seed[0..32], &server_random); // server_random FIRST for key expansion
    @memcpy(seed[32..64], &client_random);

    var block: [40]u8 = undefined;
    prf(&block, &master, "key expansion", &seed);

    var km: KeyMaterial = undefined;
    @memcpy(&km.client_write_key, block[0..16]);
    @memcpy(&km.server_write_key, block[16..32]);
    @memcpy(&km.client_write_iv, block[32..36]);
    @memcpy(&km.server_write_iv, block[36..40]);

    return km;
}

/// server Finished verify_data = PRF(master, "server finished", SHA256(handshake_messages))[0..12].
fn serverFinished(master: [48]u8, transcript: []const u8) [12]u8 {
    var hash: [32]u8 = undefined;
    Sha256.hash(transcript, &hash, .{});

    var out: [12]u8 = undefined;
    prf(&out, &master, "server finished", &hash);

    return out;
}

// --------------------------------------------------------------- //
// ECDHE pre_master (secp256r1): the X coordinate of the shared point (RFC 4492)

fn p256Scalar(seed: [32]u8) [32]u8 {
    var wide: [48]u8 = std.mem.zeroes([48]u8);
    @memcpy(wide[16..48], &seed);

    return P256.scalar.Scalar.fromBytes48(wide, .big).toBytes(.big);
}

fn ecdheShared(my_scalar: [32]u8, peer_public: []const u8) ![32]u8 {
    const peer = try P256.fromSec1(peer_public);
    const shared = try peer.mul(my_scalar, .big);

    return shared.affineCoordinates().x.toBytes(.big);
}

// --------------------------------------------------------------- //
// ServerKeyExchange signature (RFC 5246 7.4.3): ECDSA over cr ++ sr ++ server ECDHE params

fn signServerKeyExchange(key: Ecdsa.KeyPair, client_random: [32]u8, server_random: [32]u8, params: []const u8) !Ecdsa.Signature {
    var msg: [320]u8 = undefined;
    @memcpy(msg[0..32], &client_random);
    @memcpy(msg[32..64], &server_random);
    @memcpy(msg[64 .. 64 + params.len], params);

    return key.sign(msg[0 .. 64 + params.len], null);
}

// --------------------------------------------------------------- //
// --------------------------------------------------------------- //

test "tls12 handshake: ServerKeyExchange signature verifies, tamper fails" {
    var scalar: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&scalar, "0b76f7f1c7bf6e20029ddb566795e58da5ba63ffbdb914bf699bfbed3147d32c");
    const key = try Ecdsa.KeyPair.fromSecretKey(try Ecdsa.SecretKey.fromBytes(scalar));

    var cr: [32]u8 = undefined;
    @memset(&cr, 0xC1);
    var sr: [32]u8 = undefined;
    @memset(&sr, 0x52);
    // params: curve_type named_curve(3) ++ secp256r1(0x0017) ++ a 65-byte uncompressed point
    const ephemeral = p256Scalar(@splat(0x09));
    const point = (try P256.basePoint.mul(ephemeral, .big)).toUncompressedSec1();
    var params: [4 + 65]u8 = undefined;
    params[0] = 3;
    std.mem.writeInt(u16, params[1..3], 0x0017, .big);
    params[3] = 65;
    @memcpy(params[4..], &point);

    const sig = try signServerKeyExchange(key, cr, sr, &params);

    var msg: [320]u8 = undefined;
    @memcpy(msg[0..32], &cr);
    @memcpy(msg[32..64], &sr);
    @memcpy(msg[64 .. 64 + params.len], &params);
    try sig.verify(msg[0 .. 64 + params.len], key.public_key);

    msg[64] ^= 0x01; // tamper a param byte
    try std.testing.expectError(error.SignatureVerificationFailed, sig.verify(msg[0 .. 64 + params.len], key.public_key));
}

test "tls12 handshake: ECDHE -> master -> keys, both sides agree + Finished is 12B deterministic" {
    var cr: [32]u8 = undefined;
    @memset(&cr, 0x11);
    var sr: [32]u8 = undefined;
    @memset(&sr, 0x22);

    // client + server ephemerals, exchange publics, derive the same pre_master (RFC 4492 ECDHE).
    const c = p256Scalar(@splat(0x33));
    const s = p256Scalar(@splat(0x44));
    const c_pub = (try P256.basePoint.mul(c, .big)).toUncompressedSec1();
    const s_pub = (try P256.basePoint.mul(s, .big)).toUncompressedSec1();

    const pre_server = try ecdheShared(s, &c_pub);
    const pre_client = try ecdheShared(c, &s_pub);
    try std.testing.expectEqualSlices(u8, &pre_server, &pre_client);

    const master = masterSecret(&pre_server, cr, sr);
    try std.testing.expectEqual(@as(usize, 48), master.len);

    // Finished verify_data: 12 bytes and a pure function of (master, transcript).
    const transcript = "fake handshake transcript bytes";
    const fin1 = serverFinished(master, transcript);
    const fin2 = serverFinished(master, transcript);
    try std.testing.expectEqual(@as(usize, 12), fin1.len);
    try std.testing.expectEqualSlices(u8, &fin1, &fin2);
}

test "tls12 handshake: derived GCM keys do an AEAD round trip (P + R12 + H12)" {
    var cr: [32]u8 = undefined;
    @memset(&cr, 0xAA);
    var sr: [32]u8 = undefined;
    @memset(&sr, 0xBB);
    const pre_master: [32]u8 = @splat(0x5A);

    const master = masterSecret(&pre_master, cr, sr);
    const km = keyMaterial(master, cr, sr);

    // server_write_key + server_write_iv must be usable AES-128-GCM material.
    var nonce: [12]u8 = undefined;
    @memcpy(nonce[0..4], &km.server_write_iv);
    @memset(nonce[4..], 0); // explicit-nonce part, fixed here
    const plaintext = "application data over tls 1.2";

    var ct: [64]u8 = undefined;
    var tag: [16]u8 = undefined;
    Aes128Gcm.encrypt(ct[0..plaintext.len], &tag, plaintext, "", nonce, km.server_write_key);

    var back: [64]u8 = undefined;
    try Aes128Gcm.decrypt(back[0..plaintext.len], ct[0..plaintext.len], tag, "", nonce, km.server_write_key);
    try std.testing.expectEqualSlices(u8, plaintext, back[0..plaintext.len]);
}
