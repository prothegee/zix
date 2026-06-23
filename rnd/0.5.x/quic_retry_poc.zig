//! QUIC Retry integrity tag PoC, phase C2 (http3-plan.md): RFC 9001 section 5.8 plus the
//! Appendix A.4 worked example.
//!
//! Note:
//! - The Retry Integrity Tag lets a client discard a corrupted or spoofed Retry: only an entity
//!   that saw the client Initial (and so knows the Original Destination Connection ID) can compute
//!   it. It is AEAD-AES-128-GCM over the Retry Pseudo-Packet, with empty plaintext, so the 16-byte
//!   ciphertext tag is the whole output. RFC 9001 Appendix A.4 publishes the vector, so the RFC is
//!   the oracle, the same approach as the C1 Initial vectors.
//! - Two things are checked: the fixed version-1 key / nonce are themselves derived from a published
//!   secret via HKDF-Expand-Label "quic key" / "quic iv" (5.8), and the tag those produce over the
//!   pseudo-packet matches A.4 byte-exact (which reconstructs the full Retry packet).
//! - The cryptography is std.crypto (HKDF-SHA256, AES-128-GCM). HKDF-Expand-Label (the TLS 1.3
//!   "tls13 " form) is reproduced here so the PoC stays standalone; the engine reuses
//!   src/tls/key_schedule.zig.
//!
//! Run:    zig run rnd/0.5.x/quic_retry_poc.zig
//! Verify: bash rnd/0.5.x/verify-quic-retry.sh

const std = @import("std");

const HkdfSha256 = std.crypto.kdf.hkdf.HkdfSha256;
const Sha256 = std.crypto.hash.sha2.Sha256;
const Aes128Gcm = std.crypto.aead.aes_gcm.Aes128Gcm;

const hash_length = Sha256.digest_length;

/// A schedule secret, one SHA-256 block wide.
const Secret = [hash_length]u8;

// --------------------------------------------------------------- //

/// HKDF-Expand-Label (RFC 8446 7.1): the "tls13 " prefix, the bare label, and a context.
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

/// Compute the Retry Integrity Tag (RFC 9001 5.8): AEAD-AES-128-GCM with empty plaintext over the
/// Retry Pseudo-Packet as associated data.
///
/// Param:
/// key - [16]u8 (the fixed version-1 Retry key)
/// nonce - [12]u8 (the fixed version-1 Retry nonce)
/// pseudo_packet - the associated data (ODCID Length + ODCID + Retry packet without its tag)
///
/// Return:
/// - [16]u8 (the integrity tag)
fn retryTag(key: [16]u8, nonce: [12]u8, pseudo_packet: []const u8) [16]u8 {
    var tag: [Aes128Gcm.tag_length]u8 = undefined;
    var ciphertext: [0]u8 = undefined;
    Aes128Gcm.encrypt(&ciphertext, &tag, &[_]u8{}, pseudo_packet, nonce, key);

    return tag;
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

    std.debug.print("RFC 9001 section 5.8: Retry key / nonce derivation\n", .{});

    // The published secret the version-1 Retry key and nonce are derived from (RFC 9001 5.8).
    var retry_secret: Secret = undefined;
    _ = try std.fmt.hexToBytes(&retry_secret, "d9c9943e6101fd200021506bcc02814c73030f25c79d71ce876eca876e6fca8e");

    var key: [16]u8 = undefined;
    var nonce: [12]u8 = undefined;
    expandLabel(&key, retry_secret, "quic key", "");
    expandLabel(&nonce, retry_secret, "quic iv", "");

    check(&failures, "retry key", &key, "be0c690b9f66575a1d766b54e368c84e");
    check(&failures, "retry nonce", &nonce, "461599d35d632bf2239825bb");

    std.debug.print("RFC 9001 Appendix A.4: Retry integrity tag\n", .{});

    // The Original Destination Connection ID: the client-chosen DCID from the A.2 Initial. Its
    // length prefixes the pseudo-packet.
    const odcid = try hex(arena, "8394c8f03e515708");

    // The transmitted Retry packet without its 16-byte integrity tag (RFC 9001 A.4): first byte,
    // version, DCID Len 0, SCID Len 8 + SCID, then the Retry Token "token".
    const retry_no_tag = try hex(arena, "ff000000010008f067a5502a4262b5746f6b656e");

    // The Retry Pseudo-Packet (5.8): ODCID Length, ODCID, then the Retry packet without the tag.
    const pseudo = try arena.alloc(u8, 1 + odcid.len + retry_no_tag.len);
    pseudo[0] = @intCast(odcid.len);
    @memcpy(pseudo[1 .. 1 + odcid.len], odcid);
    @memcpy(pseudo[1 + odcid.len ..], retry_no_tag);

    const tag = retryTag(key, nonce, pseudo);
    check(&failures, "retry integrity tag", &tag, "04a265ba2eff4d829058fb3f0f2496ba");

    // The full transmitted Retry packet is the header (no tag) followed by the tag.
    const packet = try arena.alloc(u8, retry_no_tag.len + tag.len);
    @memcpy(packet[0..retry_no_tag.len], retry_no_tag);
    @memcpy(packet[retry_no_tag.len..], &tag);
    check(&failures, "full retry packet", packet, "ff000000010008f067a5502a4262b5746f6b656e04a265ba2eff4d829058fb3f0f2496ba");

    std.debug.print("\n", .{});
    if (failures == 0) {
        std.debug.print("PASS: all RFC 9001 Retry vectors match\n", .{});
    } else {
        std.debug.print("FAIL: {d} vector(s) mismatched\n", .{failures});
        std.process.exit(1);
    }
}
