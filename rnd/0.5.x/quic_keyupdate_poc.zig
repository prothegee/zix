//! QUIC ChaCha20-Poly1305 short-header protection plus key update PoC, phase C3 (http3-plan.md):
//! RFC 9001 section 5.4.4 + 6.1 plus the Appendix A.5 worked example.
//!
//! Note:
//! - C1 proved AES-128-GCM long-header (Initial) protection. C3 proves the other AEAD QUIC mandates,
//!   AEAD_CHACHA20_POLY1305, on a short-header (1-RTT) packet, and the key-update secret derivation.
//!   ChaCha20-Poly1305 differs from AES-GCM in two places: the AEAD itself, and the header-protection
//!   mask (RFC 9001 5.4.4 runs ChaCha20 over the sample instead of AES-ECB). Both are exercised here.
//! - Key update (6.1): the next-generation secret is HKDF-Expand-Label(secret, "quic ku", "", 32).
//!   Appendix A.5 publishes the `ku` value, so the derivation is checked against the RFC. Retaining
//!   the old keys and tracking two receive-key sets across a phase flip is connection state, not a
//!   cryptographic vector, so it lives in the engine (Layer Q), not in this deterministic PoC.
//! - RFC 9001 Appendix A.5 publishes a complete worked example (application secret, the four derived
//!   values, the protected short-header packet), so the RFC is the oracle, the same in-file-vector
//!   approach as C1 / C2. No external tool reproduces these exact bytes.
//! - The cryptography is std.crypto: HKDF-SHA256 (kdf.hkdf), ChaCha20-Poly1305 (aead.chacha_poly),
//!   and the IETF ChaCha20 stream (stream.chacha) for the header-protection mask. HKDF-Expand-Label
//!   is reproduced here so the PoC stays standalone, the engine reuses src/tls/key_schedule.zig.
//!
//! Run:    zig run rnd/0.5.x/quic_keyupdate_poc.zig
//! Verify: bash rnd/0.5.x/verify-quic-keyupdate.sh

const std = @import("std");

const HkdfSha256 = std.crypto.kdf.hkdf.HkdfSha256;
const Sha256 = std.crypto.hash.sha2.Sha256;
const ChaCha20IETF = std.crypto.stream.chacha.ChaCha20IETF;
const ChaCha20Poly1305 = std.crypto.aead.chacha_poly.ChaCha20Poly1305;

const hash_length = Sha256.digest_length;

/// A schedule secret, one SHA-256 block wide.
const Secret = [hash_length]u8;

// --------------------------------------------------------------- //

/// HKDF-Expand-Label (RFC 8446 7.1): the "tls13 " prefix, the bare label, and a context.
///
/// Param:
/// out - []u8 (filled in place, its length is the requested output width)
/// secret - the pseudorandom key
/// label - the bare label, without the "tls13 " prefix (e.g. "quic ku")
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

/// The ChaCha20-Poly1305 packet-protection material for one encryption level (RFC 9001 5.1). Unlike
/// the AES variant, the key and hp key are 32 bytes wide.
const PacketKeys = struct {
    key: [32]u8,
    iv: [12]u8,
    hp: [32]u8,

    /// Derive key / iv / hp from a traffic secret via HKDF-Expand-Label (RFC 9001 5.1).
    fn fromSecret(secret: Secret) PacketKeys {
        var keys: PacketKeys = undefined;
        expandLabel(&keys.key, secret, "quic key", "");
        expandLabel(&keys.iv, secret, "quic iv", "");
        expandLabel(&keys.hp, secret, "quic hp", "");

        return keys;
    }
};

/// Derive the next-generation traffic secret for a key update (RFC 9001 6.1):
/// secret_<n+1> = HKDF-Expand-Label(secret_<n>, "quic ku", "", 32).
fn nextKeyUpdateSecret(secret: Secret) Secret {
    var next: Secret = undefined;
    expandLabel(&next, secret, "quic ku", "");

    return next;
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

/// Compute the ChaCha20-based header-protection mask (RFC 9001 5.4.4): the first 4 bytes of the
/// sample are the little-endian block counter, the remaining 12 bytes are the nonce, and the mask is
/// ChaCha20 run over five zero bytes.
fn headerMask(hp: [32]u8, sample: [16]u8) [5]u8 {
    const counter = std.mem.readInt(u32, sample[0..4], .little);
    const nonce: [12]u8 = sample[4..16].*;

    var mask: [5]u8 = undefined;
    const zeros: [5]u8 = @splat(0);
    ChaCha20IETF.xor(&mask, &zeros, counter, hp, nonce);

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

    std.debug.print("RFC 9001 Appendix A.5: ChaCha20-Poly1305 key derivation\n", .{});

    // The application write secret for the worked example (RFC 9001 A.5).
    var secret: Secret = undefined;
    _ = try std.fmt.hexToBytes(&secret, "9ac312a7f877468ebe69422748ad00a15443f18203a07d6060f688f30f21632b");

    const keys = PacketKeys.fromSecret(secret);
    check(&failures, "key", &keys.key, "c6d98ff3441c3fe1b2182094f69caa2ed4b716b65488960a7a984979fb23e1c8");
    check(&failures, "iv", &keys.iv, "e0459b3474bdd0e44a41c144");
    check(&failures, "hp", &keys.hp, "25a282b9e82f06f21f488917a4fc8f1b73573685608597d0efcb076b0ab7a7a4");

    // Key update (6.1): the secret used after keys are rolled. A.5 publishes it as `ku`.
    const ku = nextKeyUpdateSecret(secret);
    check(&failures, "key-update secret (quic ku)", &ku, "1223504755036d556342ee9361d253421a826c9ecdf3c7148684b36b714881f9");

    std.debug.print("RFC 9001 Appendix A.5: short-header packet protection\n", .{});

    // The minimal short-header packet: an empty Destination Connection ID, a single PING frame
    // (payload 0x01), packet number 654360564 encoded on 3 bytes (RFC 9001 A.5).
    const packet_number: u64 = 654360564;
    const pn_length: usize = 3;
    const header = try hex(arena, "4200bff4");
    const plaintext = try hex(arena, "01");

    // AEAD-seal: nonce = iv XOR packet number, AAD = the unprotected header. The published payload
    // ciphertext is the 1-byte ciphertext followed by the 16-byte tag.
    const nonce = aeadNonce(keys.iv, packet_number);
    check(&failures, "nonce", &nonce, "e0459b3474bdd0e46d417eb0");

    const ciphertext = try arena.alloc(u8, plaintext.len);
    var tag: [ChaCha20Poly1305.tag_length]u8 = undefined;
    ChaCha20Poly1305.encrypt(ciphertext, &tag, plaintext, header, nonce, keys.key);

    const sealed = try arena.alloc(u8, ciphertext.len + tag.len);
    @memcpy(sealed[0..ciphertext.len], ciphertext);
    @memcpy(sealed[ciphertext.len..], &tag);
    check(&failures, "payload ciphertext", sealed, "655e5cd55c41f69080575d7999c25a5bfb");

    // Header protection: one byte is skipped, so the 16-byte sample starts at offset 1 of the sealed
    // payload (RFC 9001 A.5). The mask is ChaCha20-based, not AES-ECB.
    var sample: [16]u8 = undefined;
    @memcpy(&sample, sealed[1 .. 1 + 16]);
    check(&failures, "sample", &sample, "5e5cd55c41f69080575d7999c25a5bfb");

    const mask = headerMask(keys.hp, sample);
    check(&failures, "mask", &mask, "aefefe7d03");

    // Apply the mask: a short header masks the low 5 bits of the first byte (RFC 9001 5.4.1), then
    // the packet-number bytes.
    const protected_header = try arena.dupe(u8, header);
    protected_header[0] ^= mask[0] & 0x1f;

    for (0..pn_length) |i| protected_header[1 + i] ^= mask[1 + i];

    check(&failures, "protected header", protected_header, "4cfe4189");

    // The full protected packet: protected header, then the sealed payload.
    const packet = try arena.alloc(u8, protected_header.len + sealed.len);
    @memcpy(packet[0..protected_header.len], protected_header);
    @memcpy(packet[protected_header.len..], sealed);
    check(&failures, "protected packet", packet, "4cfe4189655e5cd55c41f69080575d7999c25a5bfb");

    std.debug.print("\n", .{});
    if (failures == 0) {
        std.debug.print("PASS: all RFC 9001 Appendix A.5 vectors match\n", .{});
    } else {
        std.debug.print("FAIL: {d} vector(s) mismatched\n", .{failures});
        std.process.exit(1);
    }
}
