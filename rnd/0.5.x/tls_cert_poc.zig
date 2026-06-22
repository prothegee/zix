//! TLS 1.3 Layer C PoC (RFC 8446 sec 4.4), the certificate / CertificateVerify / Finished step
//! for the zix TLS 1.3 server handshake (rnd/checklist-0.5.x-tls.md, Layer C, follows K + H).
//!
//! Note:
//! - This is the first layer that uses the cert fixtures (rnd/0.5.x/tls-certs) rather than the
//!   RFC 8448 trace alone, since the trace authenticates with an RSA cert and zix signs with
//!   ECDSA P-256 / Ed25519 (no RSA). The Finished step is still pinned to the trace.
//! - Certificate (4.4.2): builds the TLS 1.3 Certificate handshake message wrapping the embedded
//!   DER, parses it back (empty request_context, end-entity first, empty entry extensions), and
//!   parses the DER with std.crypto.Certificate to confirm X.509v3 + an EC public key. The
//!   digitalSignature key-usage extension presence is checked by its DER OID (id-ce-keyUsage).
//! - CertificateVerify (4.4.3): builds the signed content (the 64-octet 0x20 pad, the context
//!   string "TLS 1.3, server CertificateVerify", a 0x00 separator, then the transcript hash),
//!   asserts that structure, then does an ECDSA P-256 sign + verify round trip with the fixture
//!   key and shows a tampered transcript fails verification (the decrypt_error trigger). ECDSA is
//!   not byte-deterministic, so verification (not a fixed signature) is the gate.
//! - Finished (4.4.4): derives finished_key = HKDF-Expand-Label(server hs traffic, "finished")
//!   and computes verify_data = HMAC(finished_key, Transcript-Hash(CH..CertificateVerify)),
//!   checked byte-for-byte against the RFC 8448 server Finished (deterministic oracle), plus a
//!   tampered-transcript mismatch.
//!
//! Run: zig run rnd/0.5.x/tls_cert_poc.zig

const std = @import("std");

const Sha256 = std.crypto.hash.sha2.Sha256;
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const HkdfSha256 = std.crypto.kdf.hkdf.HkdfSha256;
const EcdsaP256 = std.crypto.sign.ecdsa.EcdsaP256Sha256;
const Certificate = std.crypto.Certificate;

const hash_len = Sha256.digest_length;

/// The server end-entity certificate, DER, ECDSA P-256 with a critical digitalSignature
/// keyUsage (rnd/0.5.x/tls-certs/ecdsa_p256_cert.der).
const cert_der = @embedFile("tls-certs/ecdsa_p256_cert.der");

/// The matching private scalar, extracted from ecdsa_p256_key.pem (openssl ec -text).
const ecdsa_private_scalar = hx("0b 76 f7 f1 c7 bf 6e 20 02 9d db 56 67 95 e5 8d a5 ba 63 ff bd b9 14 bf 69 9b fb ed 31 47 d3 2c");

const handshake_certificate: u8 = 11;
const handshake_certificate_verify: u8 = 15;

/// id-ce-keyUsage OID body (2.5.29.15), the bytes following the 06 03 OID header in DER.
const key_usage_oid = [_]u8{ 0x55, 0x1d, 0x0f };

/// CertificateVerify context string for a server signature (RFC 8446 4.4.3).
const certificate_verify_context = "TLS 1.3, server CertificateVerify";

// --------------------------------------------------------------- //
// vectors: RFC 8448 sec 3, the transcript messages + the Finished oracle (reused from Layer K).

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

const server_flight = hx(
    \\08 00 00 24 00 22 00 0a 00 14 00 12 00 1d 00 17 00 18 00 19 01 00 01 01 01 02 01 03 01 04 00 1c 00 02 40 01 00 00
    \\00 00 0b 00 01 b9 00 00 01 b5 00 01 b0 30 82 01 ac 30 82 01 15 a0 03 02 01 02 02 01 02 30 0d 06 09 2a 86 48 86 f7
    \\0d 01 01 0b 05 00 30 0e 31 0c 30 0a 06 03 55 04 03 13 03 72 73 61 30 1e 17 0d 31 36 30 37 33 30 30 31 32 33 35 39
    \\5a 17 0d 32 36 30 37 33 30 30 31 32 33 35 39 5a 30 0e 31 0c 30 0a 06 03 55 04 03 13 03 72 73 61 30 81 9f 30 0d 06
    \\09 2a 86 48 86 f7 0d 01 01 01 05 00 03 81 8d 00 30 81 89 02 81 81 00 b4 bb 49 8f 82 79 30 3d 98 08 36 39 9b 36 c6
    \\98 8c 0c 68 de 55 e1 bd b8 26 d3 90 1a 24 61 ea fd 2d e4 9a 91 d0 15 ab bc 9a 95 13 7a ce 6c 1a f1 9e aa 6a f9 8c
    \\7c ed 43 12 09 98 e1 87 a8 0e e0 cc b0 52 4b 1b 01 8c 3e 0b 63 26 4d 44 9a 6d 38 e2 2a 5f da 43 08 46 74 80 30 53
    \\0e f0 46 1c 8c a9 d9 ef bf ae 8e a6 d1 d0 3e 2b d1 93 ef f0 ab 9a 80 02 c4 74 28 a6 d3 5a 8d 88 d7 9f 7f 1e 3f 02
    \\03 01 00 01 a3 1a 30 18 30 09 06 03 55 1d 13 04 02 30 00 30 0b 06 03 55 1d 0f 04 04 03 02 05 a0 30 0d 06 09 2a 86
    \\48 86 f7 0d 01 01 0b 05 00 03 81 81 00 85 aa d2 a0 e5 b9 27 6b 90 8c 65 f7 3a 72 67 17 06 18 a5 4c 5f 8a 7b 33 7d
    \\2d f7 a5 94 36 54 17 f2 ea e8 f8 a5 8c 8f 81 72 f9 31 9c f3 6b 7f d6 c5 5b 80 f2 1a 03 01 51 56 72 60 96 fd 33 5e
    \\5e 67 f2 db f1 02 70 2e 60 8c ca e6 be c1 fc 63 a4 2a 99 be 5c 3e b7 10 7c 3c 54 e9 b9 eb 2b d5 20 3b 1c 3b 84 e0
    \\a8 b2 f7 59 40 9b a3 ea c9 d9 1d 40 2d cc 0c c8 f8 96 12 29 ac 91 87 b4 2b 4d e1 00 00 0f 00 00 84 08 04 00 80 5a
    \\74 7c 5d 88 fa 9b d2 e5 5a b0 85 a6 10 15 b7 21 1f 82 4c d4 84 14 5a b3 ff 52 f1 fd a8 47 7b 0b 7a bc 90 db 78 e2
    \\d3 3a 5c 14 1a 07 86 53 fa 6b ef 78 0c 5e a2 48 ee aa a7 85 c4 f3 94 ca b6 d3 0b be 8d 48 59 ee 51 1f 60 29 57 b1
    \\54 11 ac 02 76 71 45 9e 46 44 5c 9e a5 8c 18 1e 81 8e 95 b8 c3 fb 0b f3 27 84 09 d3 be 15 2a 3d a5 04 3e 06 3d da
    \\65 cd f5 ae a2 0d 53 df ac d4 2f 74 f3 14 00 00 20 9b 9b 14 1d 90 63 37 fb d2 cb dc e7 1d f4 de da 4a b4 2c 30 95
    \\72 cb 7f ff ee 54 54 b7 8f 07 18
);

const server_hs_traffic = hx("b6 7b 7d 69 0c c1 6c 4e 75 e5 42 13 cb 2d 37 b4 e9 c9 12 bc de d9 10 5d 42 be fd 59 d3 91 ad 38");
const want_finished_key = "00 8d 3b 66 f8 16 ea 55 9f 96 b5 37 e8 85 c3 1f c0 68 bf 49 2c 65 2f 01 f2 88 a1 d8 cd c1 9f c8";
const want_finished_verify_data = "9b 9b 14 1d 90 63 37 fb d2 cb dc e7 1d f4 de da 4a b4 2c 30 95 72 cb 7f ff ee 54 54 b7 8f 07 18";

// --------------------------------------------------------------- //
// schedule glue reused from Layer K (RFC 8446 7.1).

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
    std.debug.print("TLS 1.3 Layer C certificate / CertificateVerify / Finished vs RFC 8448 + fixtures\n\n", .{});

    std.debug.print("[ Certificate message (4.4.2) ]\n", .{});
    var cert_msg_buf: [1024]u8 = undefined;
    const cert_msg = buildCertificateMessage(&cert_msg_buf, cert_der);
    try checkCertificateMessage(cert_msg, cert_der);

    var certificate = Certificate{ .buffer = cert_der, .index = 0 };
    const parsed = try certificate.parse();
    checkTrue("certificate parses as X.509v3", parsed.version == .v3);
    checkTrue("public key algorithm is EC (ecPublicKey)", std.meta.activeTag(parsed.pub_key_algo) == .X9_62_id_ecPublicKey);
    checkTrue("digitalSignature keyUsage extension present (OID 2.5.29.15)", std.mem.indexOf(u8, cert_der, &key_usage_oid) != null);

    std.debug.print("\n[ CertificateVerify (4.4.3) ]\n", .{});
    const transcript_to_certificate = transcriptHash(&.{ &client_hello, &server_hello, server_flight[0..flightOffsetAfter(handshake_certificate)] });

    var content_buf: [256]u8 = undefined;
    const content = buildCertificateVerifyContent(&content_buf, transcript_to_certificate);
    checkContentStructure(content, transcript_to_certificate);

    const key_pair = try EcdsaP256.KeyPair.fromSecretKey(try EcdsaP256.SecretKey.fromBytes(ecdsa_private_scalar));
    checkBytes("fixture key matches the certificate public key", &key_pair.public_key.toUncompressedSec1(), parsed.slice(parsed.pub_key_slice));

    const signature = try key_pair.sign(content, null);
    const verify_ok = if (signature.verify(content, key_pair.public_key)) true else |_| false;
    checkTrue("ECDSA P-256 sign + verify round trip", verify_ok);

    var tampered: [256]u8 = undefined;
    @memcpy(tampered[0..content.len], content);
    tampered[content.len - 1] ^= 0x01;
    const tamper_rejected = if (signature.verify(tampered[0..content.len], key_pair.public_key)) false else |_| true;
    checkTrue("tampered transcript fails verify (decrypt_error)", tamper_rejected);

    std.debug.print("\n[ Finished (4.4.4) ]\n", .{});
    var finished_key: [hash_len]u8 = undefined;
    hkdfExpandLabel(&finished_key, server_hs_traffic, "finished", "");
    check("finished_key = Expand-Label(server hs traffic, \"finished\")", &finished_key, want_finished_key);

    const transcript_to_certificate_verify = transcriptHash(&.{ &client_hello, &server_hello, server_flight[0..flightOffsetAfter(handshake_certificate_verify)] });

    var verify_data: [hash_len]u8 = undefined;
    HmacSha256.create(&verify_data, &transcript_to_certificate_verify, &finished_key);
    check("Finished verify_data == RFC 8448 server Finished", &verify_data, want_finished_verify_data);

    var bad_transcript = transcript_to_certificate_verify;
    bad_transcript[0] ^= 0x01;
    var bad_verify_data: [hash_len]u8 = undefined;
    HmacSha256.create(&bad_verify_data, &bad_transcript, &finished_key);
    checkTrue("tampered transcript -> verify_data mismatch (decrypt_error)", !std.mem.eql(u8, &bad_verify_data, &verify_data));

    std.debug.print("\n", .{});
    if (failures == 0) {
        std.debug.print("ALL CHECKS PASS (Layer C conformant vs RFC 8448 + fixtures)\n", .{});
    } else {
        std.debug.print("{d} CHECK(S) FAILED\n", .{failures});
        std.process.exit(1);
    }
}

// --------------------------------------------------------------- //
// Certificate message build + parse (RFC 8446 4.4.2).

fn buildCertificateMessage(buf: []u8, der: []const u8) []const u8 {
    var w = Writer{ .buf = buf };

    w.writeU8(handshake_certificate);
    const header = w.placeU24();

    w.writeU8(0); // certificate_request_context: empty for a server certificate

    const certificate_list = w.placeU24();
    const entry = w.placeU24(); // cert_data length
    w.writeBytes(der);
    w.patchU24(entry);
    w.writeU16(0); // entry extensions: empty
    w.patchU24(certificate_list);

    w.patchU24(header);

    return w.slice();
}

fn checkCertificateMessage(msg: []const u8, der: []const u8) !void {
    var r = Reader{ .buf = msg };

    checkTrue("handshake type Certificate(11)", try r.readU8() == handshake_certificate);
    _ = try r.readU24();

    const context_len = try r.readU8();
    checkTrue("certificate_request_context empty", context_len == 0);

    const list_len = try r.readU24();
    checkTrue("certificate_list non-empty", list_len > 0);

    const entry_len = try r.readU24();
    const entry = try r.readBytes(entry_len);
    checkBytes("end-entity cert_data == fixture DER", entry, der);

    const ext_len = try r.readU16();
    checkTrue("end-entity entry extensions empty", ext_len == 0);
}

/// Offset in server_flight just past the handshake message of the given type (8446 4.4).
fn flightOffsetAfter(message_type: u8) usize {
    var r = Reader{ .buf = &server_flight };
    while (r.remaining() >= 4) {
        const this_type = r.readU8() catch break;
        const len = r.readU24() catch break;
        _ = r.readBytes(len) catch break;
        if (this_type == message_type) return r.pos;
    }

    return server_flight.len;
}

// --------------------------------------------------------------- //
// CertificateVerify content (RFC 8446 4.4.3).

fn buildCertificateVerifyContent(buf: []u8, transcript_hash: [hash_len]u8) []const u8 {
    var w = Writer{ .buf = buf };

    var i: usize = 0;
    while (i < 64) : (i += 1) w.writeU8(0x20);
    w.writeBytes(certificate_verify_context);
    w.writeU8(0x00);
    w.writeBytes(&transcript_hash);

    return w.slice();
}

fn checkContentStructure(content: []const u8, transcript_hash: [hash_len]u8) void {
    var pad_ok = true;
    for (content[0..64]) |b| {
        if (b != 0x20) pad_ok = false;
    }
    checkTrue("content: 64-octet 0x20 pad", pad_ok);
    checkBytes("content: server context string", content[64 .. 64 + certificate_verify_context.len], certificate_verify_context);
    checkTrue("content: 0x00 separator", content[64 + certificate_verify_context.len] == 0x00);
    checkBytes("content: trailing transcript hash", content[64 + certificate_verify_context.len + 1 ..], &transcript_hash);
}

// --------------------------------------------------------------- //
// reader / writer (shared shape with the other PoCs).

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
};

// --------------------------------------------------------------- //
// hex helpers.

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
