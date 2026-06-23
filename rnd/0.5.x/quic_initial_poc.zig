//! QUIC Initial packet protection PoC, phase C1 (http3-plan.md): RFC 9001 section 5 plus the
//! Appendix A worked example.
//!
//! Note:
//! - This is the deterministic crypto bottom of the HTTP/3 stack. RFC 9001 Appendix A publishes a
//!   complete worked example (Initial secrets, per-level key / iv / hp, and a byte-exact protected
//!   client Initial packet), so every value here is checked against the RFC text itself. That makes
//!   the RFC the oracle, the same in-file-vector approach used for the TLS 1.3 key schedule against
//!   RFC 8448. No external tool reproduces these exact packets (live QUIC uses random connection IDs).
//! - The cryptography is std.crypto: HKDF-SHA256 (kdf.hkdf), AES-128-GCM (aead.aes_gcm), and AES-128
//!   in ECB mode (core.aes) for the header-protection mask. The RFC 9001 wiring (the "quic key" /
//!   "quic iv" / "quic hp" labels, the nonce = iv XOR packet-number rule, the header sample / mask)
//!   is authored here.
//! - HKDF-Expand-Label is the TLS 1.3 one (RFC 8446 7.1, the "tls13 " prefix). It is reproduced here
//!   so the PoC stays standalone. The shipped engine reuses src/tls/key_schedule.zig verbatim.
//!
//! Run:    zig run rnd/0.5.x/quic_initial_poc.zig
//! Verify: bash rnd/0.5.x/verify-quic-initial.sh

const std = @import("std");

const HkdfSha256 = std.crypto.kdf.hkdf.HkdfSha256;
const Sha256 = std.crypto.hash.sha2.Sha256;
const Aes128 = std.crypto.core.aes.Aes128;
const Aes128Gcm = std.crypto.aead.aes_gcm.Aes128Gcm;

const hash_length = Sha256.digest_length;

/// A schedule secret, one SHA-256 block wide.
const Secret = [hash_length]u8;

/// The QUIC version 1 Initial salt (RFC 9001 5.2).
const initial_salt = [_]u8{ 0x38, 0x76, 0x2c, 0xf7, 0xf5, 0x59, 0x34, 0xb3, 0x4d, 0x17, 0x9a, 0xe6, 0xa4, 0xc8, 0x0c, 0xad, 0xcc, 0xbb, 0x7f, 0x0a };

// --------------------------------------------------------------- //

/// HKDF-Expand-Label (RFC 8446 7.1): the "tls13 " prefix, the bare label, and a context.
///
/// Param:
/// out - []u8 (filled in place, its length is the requested output width)
/// secret - the pseudorandom key
/// label - the bare label, without the "tls13 " prefix (e.g. "quic key")
/// context - the context bytes, empty for the QUIC key derivations
fn expandLabel(out: []u8, secret: Secret, label: []const u8, context: []const u8) void {
    const prefix = "tls13 ";

    var info: [2 + 1 + prefix.len + 255 + 1 + hash_length]u8 = undefined;
    std.mem.writeInt(u16, info[0..2], @intCast(out.len), .big);
    info[2] = @intCast(prefix.len + label.len);
    @memcpy(info[3 .. 3 + prefix.len], prefix);
    @memcpy(info[3 + prefix.len .. 3 + prefix.len + label.len], label);

    const context_pos = 3 + prefix.len + label.len;
    info[context_pos] = @intCast(context.len);
    @memcpy(info[context_pos + 1 .. context_pos + 1 + context.len], context);

    HkdfSha256.expand(out, info[0 .. context_pos + 1 + context.len], secret);
}

/// The per-direction packet-protection material for one encryption level (RFC 9001 5.1).
const PacketKeys = struct {
    key: [16]u8,
    iv: [12]u8,
    hp: [16]u8,

    /// Derive key / iv / hp from a traffic secret via HKDF-Expand-Label (RFC 9001 5.1).
    fn fromSecret(secret: Secret) PacketKeys {
        var keys: PacketKeys = undefined;
        expandLabel(&keys.key, secret, "quic key", "");
        expandLabel(&keys.iv, secret, "quic iv", "");
        expandLabel(&keys.hp, secret, "quic hp", "");

        return keys;
    }
};

/// Derive the client and server Initial secrets from the client's Destination Connection ID
/// (RFC 9001 5.2): HKDF-Extract under the version-1 salt, then HKDF-Expand-Label "client in" /
/// "server in".
fn initialSecrets(dcid: []const u8) struct { initial: Secret, client: Secret, server: Secret } {
    const initial = HkdfSha256.extract(&initial_salt, dcid);

    var client: Secret = undefined;
    var server: Secret = undefined;
    expandLabel(&client, initial, "client in", "");
    expandLabel(&server, initial, "server in", "");

    return .{ .initial = initial, .client = client, .server = server };
}

/// Build the AEAD nonce (RFC 9001 5.3): the 62-bit packet number, left-padded to the IV width,
/// XORed with the IV.
fn aeadNonce(iv: [12]u8, packet_number: u64) [12]u8 {
    var nonce = iv;
    var pn_bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &pn_bytes, packet_number, .big);

    for (0..8) |i| nonce[12 - 8 + i] ^= pn_bytes[i];

    return nonce;
}

/// Compute the header-protection mask (RFC 9001 5.4.1): mask = AES-ECB(hp, sample).
fn headerMask(hp: [16]u8, sample: [16]u8) [16]u8 {
    var mask: [16]u8 = undefined;
    Aes128.initEnc(hp).encrypt(&mask, &sample);

    return mask;
}

// --------------------------------------------------------------- //

/// Decode a hex literal (no separators) into a freshly allocated byte slice.
fn hex(allocator: std.mem.Allocator, comptime text: []const u8) ![]u8 {
    const bytes = try allocator.alloc(u8, text.len / 2);
    _ = try std.fmt.hexToBytes(bytes, text);

    return bytes;
}

/// Compare `actual` against the RFC's expected hex, report, and flag a failure.
fn check(failures: *usize, name: []const u8, actual: []const u8, comptime expected_hex: []const u8) void {
    var expected: [expected_hex.len / 2]u8 = undefined;
    _ = std.fmt.hexToBytes(&expected, expected_hex) catch unreachable;

    if (actual.len == expected.len and std.mem.eql(u8, actual, &expected)) {
        std.debug.print("  ok    {s}\n", .{name});
    } else {
        std.debug.print("  FAIL  {s}\n", .{name});
        std.debug.print("        want {s}\n", .{expected_hex});
        std.debug.print("        got  {x}\n", .{actual});
        failures.* += 1;
    }
}

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var failures: usize = 0;

    std.debug.print("RFC 9001 Appendix A.1: Initial secrets and keys\n", .{});

    // The client's Destination Connection ID for the worked example (RFC 9001 A.1).
    const dcid = try hex(arena, "8394c8f03e515708");
    const secrets = initialSecrets(dcid);

    check(&failures, "initial_secret", &secrets.initial, "7db5df06e7a69e432496adedb00851923595221596ae2ae9fb8115c1e9ed0a44");
    check(&failures, "client_initial_secret", &secrets.client, "c00cf151ca5be075ed0ebfb5c80323c42d6b7db67881289af4008f1f6c357aea");
    check(&failures, "server_initial_secret", &secrets.server, "3c199828fd139efd216c155ad844cc81fb82fa8d7446fa7d78be803acdda951b");

    const client_keys = PacketKeys.fromSecret(secrets.client);
    check(&failures, "client key", &client_keys.key, "1f369613dd76d5467730efcbe3b1a22d");
    check(&failures, "client iv", &client_keys.iv, "fa044b2f42a3fd3b46fb255c");
    check(&failures, "client hp", &client_keys.hp, "9f50449e04a0e810283a1e9933adedd2");

    const server_keys = PacketKeys.fromSecret(secrets.server);
    check(&failures, "server key", &server_keys.key, "cf3a5331653c364c88f0f379b6067e37");
    check(&failures, "server iv", &server_keys.iv, "0ac1493ca1905853b0bba03e");
    check(&failures, "server hp", &server_keys.hp, "c206b8d9b9f0f37644430b490eeaa314");

    std.debug.print("RFC 9001 Appendix A.2: client Initial packet protection\n", .{});

    // The unprotected long header (RFC 9001 A.2): type / version / DCID len + DCID / SCID len /
    // token-length varint (empty) / length varint / 4-byte packet number 2. The packet number sits
    // at offset 18 (the empty Token Length field is what an Initial packet adds over a plain long
    // header).
    const header = try hex(arena, "c300000001088394c8f03e5157080000449e00000002");
    const pn_offset: usize = 18;
    const pn_length: usize = 4;
    const packet_number: u64 = 2;

    // The unprotected payload: the CRYPTO frame (type 06, offset 00, length varint 40f1 = 241 bytes
    // of TLS ClientHello) padded with PADDING (zero bytes) to the 1162-byte payload the RFC fixes.
    const crypto_frame = try hex(arena, "060040f1010000ed0303ebf8fa56f12939b9584a3896472ec40bb863cfd3e868" ++
        "04fe3a47f06a2b69484c000004130113020100" ++ "00c000000010000e00000b6578" ++
        "616d706c652e636f6dff01000100000a00080006001d00170018001000070005" ++
        "04616c706e000500050100000000003300260024001d00209370b2c9caa47fba" ++
        "baf4559fedba753de171fa71f50f1ce15d43e994ec74d748002b000302030400" ++
        "0d0010000e0403050306030203080408050806002d00020101001c0002400100" ++
        "3900320408ffffffffffffffff05048000ffff07048000ffff08011001048000" ++
        "75300901100f088394c8f03e5157080604" ++ "8000ffff");

    const payload_len: usize = 1162;
    const payload = try arena.alloc(u8, payload_len);
    @memset(payload, 0);
    @memcpy(payload[0..crypto_frame.len], crypto_frame);

    // AEAD-seal the payload: nonce = iv XOR packet number, AAD = the unprotected header.
    const nonce = aeadNonce(client_keys.iv, packet_number);

    const ciphertext = try arena.alloc(u8, payload_len);
    var tag: [Aes128Gcm.tag_length]u8 = undefined;
    Aes128Gcm.encrypt(ciphertext, &tag, payload, header, nonce, client_keys.key);

    // Header protection: sample 16 bytes at pn_offset + 4, mask via AES-ECB(hp, sample).
    const sample_start = pn_offset + 4 - header.len;
    var sample: [16]u8 = undefined;
    @memcpy(&sample, ciphertext[sample_start .. sample_start + 16]);
    check(&failures, "sample", &sample, "d1b1c98dd7689fb8ec11d242b123dc9b");

    const mask = headerMask(client_keys.hp, sample);
    check(&failures, "mask[0..5]", mask[0..5], "437b9aec36");

    const protected_header = try arena.dupe(u8, header);
    protected_header[0] ^= mask[0] & 0x0f;

    for (0..pn_length) |i| protected_header[pn_offset + i] ^= mask[1 + i];

    check(&failures, "protected header", protected_header, "c000000001088394c8f03e5157080000449e7b9aec34");

    // The full protected packet: protected header, then the ciphertext, then the 16-byte tag.
    const packet = try arena.alloc(u8, protected_header.len + ciphertext.len + tag.len);
    @memcpy(packet[0..protected_header.len], protected_header);
    @memcpy(packet[protected_header.len .. protected_header.len + ciphertext.len], ciphertext);
    @memcpy(packet[protected_header.len + ciphertext.len ..], &tag);

    // The RFC publishes the first 16 bytes and the trailing tag; check both ends of the packet.
    check(&failures, "protected packet head", packet[0..16], "c000000001088394c8f03e5157080000");
    check(&failures, "protected packet tag", packet[packet.len - 16 ..], "e221af44860018ab0856972e194cd934");

    std.debug.print("\n", .{});
    if (failures == 0) {
        std.debug.print("PASS: all RFC 9001 Appendix A vectors match\n", .{});
    } else {
        std.debug.print("FAIL: {d} vector(s) mismatched\n", .{failures});
        std.process.exit(1);
    }
}
