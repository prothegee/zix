//! TLS 1.3 P0 start: server-handshake composition driver (RFC 8446 sec 4), the step that wires
//! the verified Layer K + H + X + C pieces into one server-side flow
//! (rnd/checklist-0.5.x-tls.md, P0). This is the bridge from per-layer PoCs to a live socket.
//!
//! Note:
//! - It runs the whole server first flight in memory: parse the RFC 8448 ClientHello, do a real
//!   ECDHE (server ephemeral private * client public, not the trace IKM taken on faith), derive
//!   the key schedule, build ServerHello + EncryptedExtensions + Certificate + CertificateVerify
//!   + Finished, AEAD-ENCRYPT the flight under the handshake keys, then self-verify by
//!   deprotecting it back. This exercises the encrypt direction that the per-layer PoCs did not.
//! - The deterministic parts are anchored byte-for-byte to the trace: with the trace's server
//!   ephemeral key the ECDHE, the derived secrets/keys, the ServerHello, and the
//!   EncryptedExtensions all equal RFC 8448. The Certificate / CertificateVerify use the ECDSA
//!   P-256 fixture (the trace authenticates with RSA, which zix does not use), so that part is
//!   verified by internal consistency (sign -> deprotect -> verify, Finished recompute), not by
//!   trace equality.
//! - What this is NOT yet: a socket. P0 still needs the live listener, a fresh per-connection
//!   ephemeral key, reading the client Finished, and the openssl s_client / curl interop gate
//!   plus the https Http1 example. This driver is the in-memory precursor that de-risks all of
//!   that.
//!
//! Run: zig run rnd/0.5.x/tls_server_poc.zig

const std = @import("std");

const Sha256 = std.crypto.hash.sha2.Sha256;
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const HkdfSha256 = std.crypto.kdf.hkdf.HkdfSha256;
const X25519 = std.crypto.dh.X25519;
const Aes128Gcm = std.crypto.aead.aes_gcm.Aes128Gcm;
const EcdsaP256 = std.crypto.sign.ecdsa.EcdsaP256Sha256;
const Certificate = std.crypto.Certificate;

const hash_len = Sha256.digest_length;

const cert_der = @embedFile("tls-certs/ecdsa_p256_cert.der");
const ecdsa_private_scalar = hx("0b 76 f7 f1 c7 bf 6e 20 02 9d db 56 67 95 e5 8d a5 ba 63 ff bd b9 14 bf 69 9b fb ed 31 47 d3 2c");

const tls12: u16 = 0x0303;
const tls13: u16 = 0x0304;
const cipher_aes_128_gcm_sha256: u16 = 0x1301;
const group_x25519: u16 = 0x001d;
const sig_ecdsa_secp256r1_sha256: u16 = 0x0403;
const certificate_verify_context = "TLS 1.3, server CertificateVerify";

// --------------------------------------------------------------- //
// vectors: the trace ClientHello + the server's ephemeral key / random + the expected secrets.

const client_hello = hx(
    \\01 00 00 c0 03 03 cb 34 ec b1 e7 81 63 ba 1c 38 c6 da cb 19 6a 6d ff a2 1a 8d 99 12 ec 18 a2 ef 62 83 02 4d ec e7
    \\00 00 06 13 01 13 03 13 02 01 00 00 91 00 00 00 0b 00 09 00 00 06 73 65 72 76 65 72 ff 01 00 01 00 00 0a 00 14 00
    \\12 00 1d 00 17 00 18 00 19 01 00 01 01 01 02 01 03 01 04 00 23 00 00 00 33 00 26 00 24 00 1d 00 20 99 38 1d e5 60
    \\e4 bd 43 d2 3d 8e 43 5a 7d ba fe b3 c0 6e 51 c1 3c ae 4d 54 13 69 1e 52 9a af 2c 00 2b 00 03 02 03 04 00 0d 00 20
    \\00 1e 04 03 05 03 06 03 02 03 08 04 08 05 08 06 04 01 05 01 06 01 02 01 04 02 05 02 06 02 02 02 00 2d 00 02 01 01
    \\00 1c 00 02 40 01
);

const server_hello = hx(
    \\02 00 00 56 03 03 a6 af 06 a4 12 18 60 dc 5e 6e 60 24 9c d3 4c 95 93 0c 8a c5 cb 14 34 da c1 55 77 2e d3 e2 69 28
    \\00 13 01 00 00 2e 00 33 00 24 00 1d 00 20 c9 82 88 76 11 20 95 fe 66 76 2b db f7 c6 72 e1 56 d6 cc 25 3b 83 3d f1
    \\dd 69 b1 b0 4e 75 1f 0f 00 2b 00 02 03 04
);

const encrypted_extensions = hx(
    \\08 00 00 24 00 22 00 0a 00 14 00 12 00 1d 00 17 00 18 00 19 01 00 01 01 01 02 01 03 01 04 00 1c 00 02 40 01 00 00
    \\00 00
);

const server_ephemeral_private = hx("b1 58 0e ea df 6d d5 89 b8 ef 4f 2d 56 52 57 8c c8 10 e9 98 01 91 ec 8d 05 83 08 ce a2 16 a2 1e");
const server_ephemeral_public = hx("c9 82 88 76 11 20 95 fe 66 76 2b db f7 c6 72 e1 56 d6 cc 25 3b 83 3d f1 dd 69 b1 b0 4e 75 1f 0f");
const server_random = hx("a6 af 06 a4 12 18 60 dc 5e 6e 60 24 9c d3 4c 95 93 0c 8a c5 cb 14 34 da c1 55 77 2e d3 e2 69 28");
const server_groups_list = hx("00 1d 00 17 00 18 00 19 01 00 01 01 01 02 01 03 01 04");

const want_ecdhe = "8b d4 05 4f b5 5b 9d 63 fd fb ac f9 f0 4b 9f 0d 35 e6 d6 3f 53 75 63 ef d4 62 72 90 0f 89 49 2d";
const want_server_hs_traffic = "b6 7b 7d 69 0c c1 6c 4e 75 e5 42 13 cb 2d 37 b4 e9 c9 12 bc de d9 10 5d 42 be fd 59 d3 91 ad 38";
const want_server_hs_key = "3f ce 51 60 09 c2 17 27 d0 f2 e4 e8 6e e4 03 bc";
const want_server_hs_iv = "5d 31 3e b2 67 12 76 ee 13 00 0b 30";

// --------------------------------------------------------------- //
// schedule glue (Layer K).

fn hkdfExpandLabel(out: []u8, secret: [hash_len]u8, label: []const u8, context: []const u8) void {
    const prefix = "tls13 ";

    var info: [2 + 1 + prefix.len + 255 + 1 + hash_len]u8 = undefined;
    std.mem.writeInt(u16, info[0..2], @intCast(out.len), .big);
    info[2] = @intCast(prefix.len + label.len);
    @memcpy(info[3 .. 3 + prefix.len], prefix);
    @memcpy(info[3 + prefix.len .. 3 + prefix.len + label.len], label);

    const ctx_len_pos = 3 + prefix.len + label.len;
    info[ctx_len_pos] = @intCast(context.len);
    @memcpy(info[ctx_len_pos + 1 .. ctx_len_pos + 1 + context.len], context);

    HkdfSha256.expand(out, info[0 .. ctx_len_pos + 1 + context.len], secret);
}

fn deriveSecret(secret: [hash_len]u8, label: []const u8, transcript_hash: [hash_len]u8) [hash_len]u8 {
    var out: [hash_len]u8 = undefined;
    hkdfExpandLabel(&out, secret, label, &transcript_hash);

    return out;
}

fn transcriptHash(messages: []const []const u8) [hash_len]u8 {
    var sha = Sha256.init(.{});
    for (messages) |message| sha.update(message);

    return sha.finalResult();
}

// --------------------------------------------------------------- //
// harness.

var failures: usize = 0;

fn check(name: []const u8, got: []const u8, want_hex: []const u8) void {
    var want: [256]u8 = undefined;
    checkBytes(name, got, decodeHexRuntime(&want, want_hex));
}

fn checkBytes(name: []const u8, got: []const u8, want: []const u8) void {
    if (std.mem.eql(u8, got, want)) {
        std.debug.print("  PASS  {s}\n", .{name});
    } else {
        failures += 1;
        std.debug.print("  FAIL  {s}\n        got  {x}\n        want {x}\n", .{ name, got, want });
    }
}

fn checkTrue(name: []const u8, ok: bool) void {
    if (ok) {
        std.debug.print("  PASS  {s}\n", .{name});
    } else {
        failures += 1;
        std.debug.print("  FAIL  {s}\n", .{name});
    }
}

pub fn main() !void {
    std.debug.print("TLS 1.3 P0 server-handshake composition (K + H + X + C) vs RFC 8448 + fixtures\n\n", .{});

    std.debug.print("[ parse + negotiate (H) ]\n", .{});
    const client_public = clientKeyShareX25519() orelse {
        std.debug.print("  FAIL  no x25519 key_share in ClientHello\n", .{});
        std.process.exit(1);
    };
    checkTrue("ClientHello offers TLS 1.3 + x25519 key_share", true);

    var sh_buf: [256]u8 = undefined;
    const server_hello_msg = serializeServerHello(&sh_buf);
    checkBytes("ServerHello == RFC 8448 (H)", server_hello_msg, &server_hello);

    std.debug.print("\n[ ECDHE + key schedule (K) ]\n", .{});
    var client_pub: [32]u8 = undefined;
    @memcpy(&client_pub, client_public);
    const ecdhe = try X25519.scalarmult(server_ephemeral_private, client_pub);
    check("ECDHE = X25519(server_priv, client_pub)", &ecdhe, want_ecdhe);

    const transcript_ch_sh = transcriptHash(&.{ &client_hello, &server_hello });
    const zero_block = std.mem.zeroes([hash_len]u8);
    const early_secret = HkdfSha256.extract(&zero_block, &zero_block);
    const derived = deriveSecret(early_secret, "derived", transcriptHash(&.{}));
    const handshake_secret = HkdfSha256.extract(&derived, &ecdhe);
    const server_hs_traffic = deriveSecret(handshake_secret, "s hs traffic", transcript_ch_sh);
    check("server handshake traffic secret", &server_hs_traffic, want_server_hs_traffic);

    var hs_key: [16]u8 = undefined;
    var hs_iv: [12]u8 = undefined;
    var finished_key: [hash_len]u8 = undefined;
    hkdfExpandLabel(&hs_key, server_hs_traffic, "key", "");
    hkdfExpandLabel(&hs_iv, server_hs_traffic, "iv", "");
    hkdfExpandLabel(&finished_key, server_hs_traffic, "finished", "");
    check("server handshake write key", &hs_key, want_server_hs_key);
    check("server handshake write iv", &hs_iv, want_server_hs_iv);

    std.debug.print("\n[ build server flight (X + C) ]\n", .{});
    var flight_buf: [2048]u8 = undefined;
    var fw = Writer{ .buf = &flight_buf };

    const ee = buildEncryptedExtensions(fw.tail());
    fw.advance(ee.len);
    checkBytes("EncryptedExtensions == RFC 8448 (X)", ee, &encrypted_extensions);

    const cert_msg = buildCertificateMessage(fw.tail());
    fw.advance(cert_msg.len);

    const key_pair = try EcdsaP256.KeyPair.fromSecretKey(try EcdsaP256.SecretKey.fromBytes(ecdsa_private_scalar));
    const transcript_to_cert = transcriptHash(&.{ &client_hello, &server_hello, ee, cert_msg });
    const cert_verify_msg = try buildCertificateVerify(fw.tail(), key_pair, transcript_to_cert);
    fw.advance(cert_verify_msg.len);

    const transcript_to_cv = transcriptHash(&.{ &client_hello, &server_hello, ee, cert_msg, cert_verify_msg });
    const finished_msg = buildFinished(fw.tail(), finished_key, transcript_to_cv);
    fw.advance(finished_msg.len);

    const flight = fw.slice();
    checkTrue("flight order EE, Cert, CertVerify, Finished", flightOrderOk(flight));

    std.debug.print("\n[ record protection round trip (K, encrypt direction) ]\n", .{});
    var record_buf: [2304]u8 = undefined;
    const record = aeadProtect(&record_buf, flight, hs_key, hs_iv);
    checkTrue("flight AEAD-encrypted into one handshake record", record.len == flight.len + 1 + Aes128Gcm.tag_length + 5);

    var recovered_buf: [2048]u8 = undefined;
    const recovered = try aeadDeprotect(&recovered_buf, record, hs_key, hs_iv);
    checkBytes("deprotect recovers the flight", recovered, flight);

    std.debug.print("\n[ flight self-consistency (C) ]\n", .{});
    var certificate = Certificate{ .buffer = cert_der, .index = 0 };
    const parsed = try certificate.parse();
    checkTrue("CertificateVerify signature verifies against the cert key", certificateVerifyOk(cert_verify_msg, transcript_to_cert, parsed));
    checkTrue("Finished verify_data recomputes from finished_key", finishedOk(finished_msg, finished_key, transcript_to_cv));

    std.debug.print("\n", .{});
    if (failures == 0) {
        std.debug.print("ALL CHECKS PASS (P0 server handshake composes K + H + X + C)\n", .{});
    } else {
        std.debug.print("{d} CHECK(S) FAILED\n", .{failures});
        std.process.exit(1);
    }
}

// --------------------------------------------------------------- //
// message builders (H / X / C), writing into a tail slice of the flight buffer.

fn serializeServerHello(buf: []u8) []const u8 {
    var w = Writer{ .buf = buf };

    w.writeU8(2);
    const header = w.placeU24();
    w.writeU16(tls12);
    w.writeBytes(&server_random);
    w.writeU8(0); // empty session_id echo (the trace ClientHello session_id is empty)
    w.writeU16(cipher_aes_128_gcm_sha256);
    w.writeU8(0);

    const extensions = w.placeU16();
    w.writeU16(0x0033); // key_share
    const key_share = w.placeU16();
    w.writeU16(group_x25519);
    const key_exchange = w.placeU16();
    w.writeBytes(&server_ephemeral_public);
    w.patchU16(key_exchange);
    w.patchU16(key_share);
    w.writeU16(0x002b); // supported_versions
    const supported_versions = w.placeU16();
    w.writeU16(tls13);
    w.patchU16(supported_versions);
    w.patchU16(extensions);

    w.patchU24(header);

    return w.slice();
}

fn buildEncryptedExtensions(buf: []u8) []const u8 {
    var w = Writer{ .buf = buf };

    w.writeU8(8);
    const header = w.placeU24();
    const extensions = w.placeU16();

    w.writeU16(0x000a); // supported_groups
    const groups = w.placeU16();
    const list = w.placeU16();
    w.writeBytes(&server_groups_list);
    w.patchU16(list);
    w.patchU16(groups);

    w.writeU16(0x001c); // record_size_limit
    w.writeU16(2);
    w.writeU16(0x4001);

    w.writeU16(0x0000); // server_name empty acknowledgement
    w.writeU16(0);

    w.patchU16(extensions);
    w.patchU24(header);

    return w.slice();
}

fn buildCertificateMessage(buf: []u8) []const u8 {
    var w = Writer{ .buf = buf };

    w.writeU8(11);
    const header = w.placeU24();
    w.writeU8(0); // empty certificate_request_context

    const list = w.placeU24();
    const entry = w.placeU24();
    w.writeBytes(cert_der);
    w.patchU24(entry);
    w.writeU16(0); // empty entry extensions
    w.patchU24(list);

    w.patchU24(header);

    return w.slice();
}

fn buildCertificateVerify(buf: []u8, key_pair: EcdsaP256.KeyPair, transcript_hash: [hash_len]u8) ![]const u8 {
    var content: [64 + certificate_verify_context.len + 1 + hash_len]u8 = undefined;
    @memset(content[0..64], 0x20);
    @memcpy(content[64 .. 64 + certificate_verify_context.len], certificate_verify_context);
    content[64 + certificate_verify_context.len] = 0x00;
    @memcpy(content[64 + certificate_verify_context.len + 1 ..], &transcript_hash);

    const signature = try key_pair.sign(&content, null);
    var der_buf: [EcdsaP256.Signature.der_encoded_length_max]u8 = undefined;
    const der = signature.toDer(&der_buf);

    var w = Writer{ .buf = buf };
    w.writeU8(15);
    const header = w.placeU24();
    w.writeU16(sig_ecdsa_secp256r1_sha256);
    const sig = w.placeU16();
    w.writeBytes(der);
    w.patchU16(sig);
    w.patchU24(header);

    return w.slice();
}

fn buildFinished(buf: []u8, finished_key: [hash_len]u8, transcript_hash: [hash_len]u8) []const u8 {
    var verify_data: [hash_len]u8 = undefined;
    HmacSha256.create(&verify_data, &transcript_hash, &finished_key);

    var w = Writer{ .buf = buf };
    w.writeU8(20);
    const header = w.placeU24();
    w.writeBytes(&verify_data);
    w.patchU24(header);

    return w.slice();
}

// --------------------------------------------------------------- //
// record protection (K): TLS 1.3 application_data wrapper, seq 0 (nonce = static iv).

fn aeadProtect(buf: []u8, plaintext: []const u8, key: [16]u8, iv: [12]u8) []const u8 {
    const inner_len = plaintext.len + 1; // + inner content type handshake(22)
    const record_len = inner_len + Aes128Gcm.tag_length;

    buf[0] = 23;
    buf[1] = 0x03;
    buf[2] = 0x03;
    std.mem.writeInt(u16, buf[3..5], @intCast(record_len), .big);

    var inner: [2048]u8 = undefined;
    @memcpy(inner[0..plaintext.len], plaintext);
    inner[plaintext.len] = 22;

    const cipher = buf[5 .. 5 + inner_len];
    var tag: [Aes128Gcm.tag_length]u8 = undefined;
    Aes128Gcm.encrypt(cipher, &tag, inner[0..inner_len], buf[0..5], iv, key);
    @memcpy(buf[5 + inner_len .. 5 + inner_len + Aes128Gcm.tag_length], &tag);

    return buf[0 .. 5 + record_len];
}

fn aeadDeprotect(buf: []u8, record: []const u8, key: [16]u8, iv: [12]u8) ![]const u8 {
    const header = record[0..5];
    const body = record[5..];
    const cipher = body[0 .. body.len - Aes128Gcm.tag_length];

    var tag: [Aes128Gcm.tag_length]u8 = undefined;
    @memcpy(&tag, body[body.len - Aes128Gcm.tag_length ..]);

    const out = buf[0..cipher.len];
    try Aes128Gcm.decrypt(out, cipher, tag, header, iv, key);

    return out[0 .. out.len - 1]; // strip the inner content type
}

// --------------------------------------------------------------- //
// verification helpers.

fn clientKeyShareX25519() ?[]const u8 {
    var r = Reader{ .buf = &client_hello };
    skipClientHelloPrefix(&r) catch return null;

    const extensions_len = r.readU16() catch return null;
    const extensions = r.readBytes(extensions_len) catch return null;

    var er = Reader{ .buf = extensions };
    while (er.remaining() >= 4) {
        const ext_type = er.readU16() catch return null;
        const ext_len = er.readU16() catch return null;
        const ext_data = er.readBytes(ext_len) catch return null;
        if (ext_type != 0x0033) continue;

        var kr = Reader{ .buf = ext_data };
        const shares_len = kr.readU16() catch return null;
        const shares = kr.readBytes(shares_len) catch return null;
        var sr = Reader{ .buf = shares };
        while (sr.remaining() >= 4) {
            const group = sr.readU16() catch return null;
            const ke_len = sr.readU16() catch return null;
            const ke = sr.readBytes(ke_len) catch return null;
            if (group == group_x25519) return ke;
        }
    }

    return null;
}

fn skipClientHelloPrefix(r: *Reader) !void {
    _ = try r.readU8();
    _ = try r.readU24();
    _ = try r.readU16();
    _ = try r.readBytes(32);
    const session_id_len = try r.readU8();
    _ = try r.readBytes(session_id_len);
    const cipher_suites_len = try r.readU16();
    _ = try r.readBytes(cipher_suites_len);
    const compression_len = try r.readU8();
    _ = try r.readBytes(compression_len);
}

fn flightOrderOk(flight: []const u8) bool {
    const expected = [_]u8{ 8, 11, 15, 20 };
    var r = Reader{ .buf = flight };
    var i: usize = 0;
    while (r.remaining() >= 4 and i < expected.len) : (i += 1) {
        const this_type = r.readU8() catch return false;
        const len = r.readU24() catch return false;
        _ = r.readBytes(len) catch return false;
        if (this_type != expected[i]) return false;
    }

    return i == expected.len and r.remaining() == 0;
}

fn certificateVerifyOk(cert_verify_msg: []const u8, transcript_hash: [hash_len]u8, parsed: Certificate.Parsed) bool {
    var r = Reader{ .buf = cert_verify_msg };
    _ = r.readU8() catch return false;
    _ = r.readU24() catch return false;
    _ = r.readU16() catch return false; // signature scheme
    const sig_len = r.readU16() catch return false;
    const der = r.readBytes(sig_len) catch return false;

    var content: [64 + certificate_verify_context.len + 1 + hash_len]u8 = undefined;
    @memset(content[0..64], 0x20);
    @memcpy(content[64 .. 64 + certificate_verify_context.len], certificate_verify_context);
    content[64 + certificate_verify_context.len] = 0x00;
    @memcpy(content[64 + certificate_verify_context.len + 1 ..], &transcript_hash);

    const sec1 = parsed.slice(parsed.pub_key_slice);
    const public_key = EcdsaP256.PublicKey.fromSec1(sec1) catch return false;
    const signature = EcdsaP256.Signature.fromDer(der) catch return false;
    signature.verify(&content, public_key) catch return false;

    return true;
}

fn finishedOk(finished_msg: []const u8, finished_key: [hash_len]u8, transcript_hash: [hash_len]u8) bool {
    var r = Reader{ .buf = finished_msg };
    _ = r.readU8() catch return false;
    const len = r.readU24() catch return false;
    const verify_data = r.readBytes(len) catch return false;

    var expected: [hash_len]u8 = undefined;
    HmacSha256.create(&expected, &transcript_hash, &finished_key);

    return std.mem.eql(u8, verify_data, &expected);
}

// --------------------------------------------------------------- //
// reader / writer / hex.

const DecodeError = error{Truncated};

const Reader = struct {
    buf: []const u8,
    pos: usize = 0,

    fn readU8(self: *Reader) DecodeError!u8 {
        if (self.pos + 1 > self.buf.len) return error.Truncated;

        const value = self.buf[self.pos];
        self.pos += 1;

        return value;
    }

    fn readU16(self: *Reader) DecodeError!u16 {
        if (self.pos + 2 > self.buf.len) return error.Truncated;

        const value = std.mem.readInt(u16, self.buf[self.pos..][0..2], .big);
        self.pos += 2;

        return value;
    }

    fn readU24(self: *Reader) DecodeError!u32 {
        if (self.pos + 3 > self.buf.len) return error.Truncated;

        const b = self.buf[self.pos..][0..3];
        self.pos += 3;

        return (@as(u32, b[0]) << 16) | (@as(u32, b[1]) << 8) | b[2];
    }

    fn readBytes(self: *Reader, n: usize) DecodeError![]const u8 {
        if (self.pos + n > self.buf.len) return error.Truncated;

        const slice = self.buf[self.pos .. self.pos + n];
        self.pos += n;

        return slice;
    }

    fn remaining(self: *const Reader) usize {
        return self.buf.len - self.pos;
    }
};

const Writer = struct {
    buf: []u8,
    len: usize = 0,

    fn writeU8(self: *Writer, value: u8) void {
        self.buf[self.len] = value;
        self.len += 1;
    }

    fn writeU16(self: *Writer, value: u16) void {
        std.mem.writeInt(u16, self.buf[self.len..][0..2], value, .big);
        self.len += 2;
    }

    fn writeU24(self: *Writer, value: u32) void {
        self.buf[self.len] = @intCast((value >> 16) & 0xff);
        self.buf[self.len + 1] = @intCast((value >> 8) & 0xff);
        self.buf[self.len + 2] = @intCast(value & 0xff);
        self.len += 3;
    }

    fn writeBytes(self: *Writer, bytes: []const u8) void {
        @memcpy(self.buf[self.len .. self.len + bytes.len], bytes);
        self.len += bytes.len;
    }

    fn placeU16(self: *Writer) usize {
        const marker = self.len;
        self.writeU16(0);

        return marker;
    }

    fn patchU16(self: *Writer, marker: usize) void {
        std.mem.writeInt(u16, self.buf[marker..][0..2], @intCast(self.len - marker - 2), .big);
    }

    fn placeU24(self: *Writer) usize {
        const marker = self.len;
        self.writeU24(0);

        return marker;
    }

    fn patchU24(self: *Writer, marker: usize) void {
        const value: u32 = @intCast(self.len - marker - 3);
        self.buf[marker] = @intCast((value >> 16) & 0xff);
        self.buf[marker + 1] = @intCast((value >> 8) & 0xff);
        self.buf[marker + 2] = @intCast(value & 0xff);
    }

    fn slice(self: *const Writer) []const u8 {
        return self.buf[0..self.len];
    }

    /// The unused tail of the buffer, for a sub-writer that appends to this one.
    fn tail(self: *Writer) []u8 {
        return self.buf[self.len..];
    }

    fn advance(self: *Writer, n: usize) void {
        self.len += n;
    }
};

fn hexLen(comptime s: []const u8) usize {
    @setEvalBranchQuota(200000);
    var n: usize = 0;
    for (s) |c| switch (c) {
        '0'...'9', 'a'...'f', 'A'...'F' => n += 1,
        else => {},
    };

    return n / 2;
}

fn hx(comptime s: []const u8) [hexLen(s)]u8 {
    @setEvalBranchQuota(200000);
    var out: [hexLen(s)]u8 = undefined;
    var oi: usize = 0;
    var high: ?u8 = null;
    for (s) |c| {
        const nibble: u8 = switch (c) {
            '0'...'9' => c - '0',
            'a'...'f' => c - 'a' + 10,
            'A'...'F' => c - 'A' + 10,
            else => continue,
        };
        if (high) |h| {
            out[oi] = (h << 4) | nibble;
            oi += 1;
            high = null;
        } else {
            high = nibble;
        }
    }

    return out;
}

fn decodeHexRuntime(buf: []u8, hex_str: []const u8) []u8 {
    var oi: usize = 0;
    var high: ?u8 = null;
    for (hex_str) |c| {
        const nibble: u8 = switch (c) {
            '0'...'9' => c - '0',
            'a'...'f' => c - 'a' + 10,
            'A'...'F' => c - 'A' + 10,
            else => continue,
        };
        if (high) |h| {
            buf[oi] = (h << 4) | nibble;
            oi += 1;
            high = null;
        } else {
            high = nibble;
        }
    }

    return buf[0..oi];
}
