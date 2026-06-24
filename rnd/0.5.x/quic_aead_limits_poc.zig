//! QUIC AEAD usage limits plus constant-time tamper rejection PoC, phase C4 (http3-plan.md):
//! RFC 9001 section 6.6 (Limits on AEAD Usage) and 9.5 (Header Protection Timing Side Channels).
//!
//! Note:
//! - C1 to C3 proved the crypto is byte-exact. C4 closes Layer C with the two safety rules that
//!   bound how long a key may be used. Unlike C1 to C3 these are not Appendix-A byte vectors:
//!   section 6.6 fixes normative limit constants, and 9.5 fixes a behavioral property (tamper
//!   detection must be authenticated and side-channel free). So the oracle is the RFC normative
//!   text plus std.crypto's constant-time authenticated decrypt, not a published packet.
//! - Section 6.6 (confidentiality): an endpoint MUST initiate a key update before sending more
//!   packets under one key than the AEAD's confidentiality limit permits. (integrity): it MUST
//!   count received packets that fail authentication and, on reaching the integrity limit, close
//!   with AEAD_LIMIT_REACHED. The limits checked here are AES-128-GCM / AES-256-GCM (2^23 send,
//!   2^52 forge) and ChaCha20-Poly1305 (send limit disregarded, 2^36 forge), the three AEADs zix
//!   offers. AES-128-CCM (2^21.5) is not offered.
//! - Section 9.5: removing header protection, recovering the packet number, and removing packet
//!   protection MUST happen together with no timing side channel. A flipped bit anywhere under the
//!   authentication MUST be rejected, and the rejection feeds the integrity counter rather than
//!   short-circuiting. std.crypto's AEAD decrypt does the tag check in constant time (no early-out),
//!   and std.crypto.timing_safe.eql is the constant-time primitive for any manual token compare.
//!
//! Run:    zig run rnd/0.5.x/quic_aead_limits_poc.zig
//! Verify: bash rnd/0.5.x/verify-quic-aead-limits.sh

const std = @import("std");

const Aes128Gcm = std.crypto.aead.aes_gcm.Aes128Gcm;

// --------------------------------------------------------------- //

/// The AEAD functions QUIC version 1 uses with the TLS 1.3 cipher suites zix offers (RFC 9001 5.3).
const AeadId = enum { aes_128_gcm, aes_256_gcm, chacha20_poly1305 };

/// ChaCha20-Poly1305's confidentiality limit exceeds the 2^62 maximum packet number, so RFC 9001
/// 6.6 says it can be disregarded. The sentinel never trips the send-side check.
const confidentiality_disregarded: u64 = std.math.maxInt(u64);

/// The confidentiality limit (RFC 9001 6.6): the number of packets that may be encrypted under one
/// key before a key update is mandatory.
fn confidentialityLimit(aead: AeadId) u64 {
    return switch (aead) {
        .aes_128_gcm, .aes_256_gcm => 1 << 23,
        .chacha20_poly1305 => confidentiality_disregarded,
    };
}

/// The integrity limit (RFC 9001 6.6): the number of received packets that may fail authentication
/// across a connection before it MUST be closed with AEAD_LIMIT_REACHED.
fn integrityLimit(aead: AeadId) u64 {
    return switch (aead) {
        .aes_128_gcm, .aes_256_gcm => 1 << 52,
        .chacha20_poly1305 => 1 << 36,
    };
}

/// What the usage accounting requires of the endpoint after one packet event (RFC 9001 6.6).
const Action = enum {
    /// Within both limits, keep using the keys.
    ok,
    /// The confidentiality limit is reached: a key update MUST happen before sending more.
    initiate_key_update,
    /// The integrity limit is reached, or a key update is impossible at the confidentiality limit:
    /// close the connection with AEAD_LIMIT_REACHED.
    close_aead_limit_reached,
};

/// Per-key usage accounting for one key phase (RFC 9001 6.6). Confidentiality counts packets sent,
/// integrity counts received packets that fail authentication.
const KeyUsage = struct {
    aead: AeadId,
    encrypted_packets: u64 = 0,
    auth_failures: u64 = 0,
    key_update_possible: bool = true,

    /// Account one packet about to be sent. At the confidentiality limit a key update is mandatory
    /// before sending more, and if one is impossible the connection MUST close.
    fn onSend(self: *KeyUsage) Action {
        self.encrypted_packets += 1;

        if (self.encrypted_packets < confidentialityLimit(self.aead)) return .ok;

        return if (self.key_update_possible) .initiate_key_update else .close_aead_limit_reached;
    }

    /// Account one received packet that failed authentication. At the integrity limit the
    /// connection MUST close with AEAD_LIMIT_REACHED.
    fn onAuthFailure(self: *KeyUsage) Action {
        self.auth_failures += 1;

        return if (self.auth_failures >= integrityLimit(self.aead)) .close_aead_limit_reached else .ok;
    }
};

// --------------------------------------------------------------- //

/// Report a boolean expectation and flag a failure.
fn expect(failures: *usize, name: []const u8, ok: bool) void {
    if (ok) {
        std.debug.print("  ok    {s}\n", .{name});
    } else {
        std.debug.print("  FAIL  {s}\n", .{name});
        failures.* += 1;
    }
}

/// Report a u64 equality expectation against the RFC's normative value and flag a failure.
fn expectEq(failures: *usize, name: []const u8, actual: u64, expected: u64) void {
    if (actual == expected) {
        std.debug.print("  ok    {s}\n", .{name});
    } else {
        std.debug.print("  FAIL  {s}\n", .{name});
        std.debug.print("        want {d}\n", .{expected});
        std.debug.print("        got  {d}\n", .{actual});
        failures.* += 1;
    }
}

pub fn main() !void {
    var failures: usize = 0;

    std.debug.print("RFC 9001 6.6: confidentiality limits (packets sent per key)\n", .{});
    expectEq(&failures, "aes-128-gcm confidentiality = 2^23", confidentialityLimit(.aes_128_gcm), 1 << 23);
    expectEq(&failures, "aes-256-gcm confidentiality = 2^23", confidentialityLimit(.aes_256_gcm), 1 << 23);
    expect(&failures, "chacha20-poly1305 confidentiality disregarded", confidentialityLimit(.chacha20_poly1305) == confidentiality_disregarded);

    std.debug.print("RFC 9001 6.6: integrity limits (received packets that fail auth)\n", .{});
    expectEq(&failures, "aes-128-gcm integrity = 2^52", integrityLimit(.aes_128_gcm), 1 << 52);
    expectEq(&failures, "aes-256-gcm integrity = 2^52", integrityLimit(.aes_256_gcm), 1 << 52);
    expectEq(&failures, "chacha20-poly1305 integrity = 2^36", integrityLimit(.chacha20_poly1305), 1 << 36);

    std.debug.print("RFC 9001 6.6: send-side accounting (confidentiality)\n", .{});

    // Below the limit the keys keep being used. Just under the cap, the next send is still ok.
    var send_usage = KeyUsage{ .aead = .aes_128_gcm, .encrypted_packets = (1 << 23) - 2 };
    expect(&failures, "below confidentiality limit -> ok", send_usage.onSend() == .ok);

    // At the cap, a key update is mandatory before sending more.
    expect(&failures, "at confidentiality limit -> initiate key update", send_usage.onSend() == .initiate_key_update);

    // If a key update is impossible at the cap, the connection MUST close.
    var stuck_usage = KeyUsage{ .aead = .aes_128_gcm, .encrypted_packets = (1 << 23) - 1, .key_update_possible = false };
    expect(&failures, "confidentiality limit, no key update -> close", stuck_usage.onSend() == .close_aead_limit_reached);

    // ChaCha20-Poly1305 never trips the send-side limit.
    var chacha_usage = KeyUsage{ .aead = .chacha20_poly1305, .encrypted_packets = 1 << 40 };
    expect(&failures, "chacha20 huge send count -> ok", chacha_usage.onSend() == .ok);

    std.debug.print("RFC 9001 6.6: receive-side accounting (integrity)\n", .{});

    // Below the integrity limit, a forged packet is ignored and the connection lives on.
    var recv_usage = KeyUsage{ .aead = .aes_128_gcm, .auth_failures = (1 << 52) - 2 };
    expect(&failures, "below integrity limit -> ok", recv_usage.onAuthFailure() == .ok);

    // Reaching the integrity limit MUST close with AEAD_LIMIT_REACHED.
    expect(&failures, "at integrity limit -> close (AEAD_LIMIT_REACHED)", recv_usage.onAuthFailure() == .close_aead_limit_reached);

    std.debug.print("RFC 9001 9.5: constant-time authenticated tamper rejection\n", .{});

    // Seal a packet with AES-128-GCM: AAD models the unprotected header, the rest is the payload.
    const key: [16]u8 = @splat(0x2b);
    const nonce: [12]u8 = @splat(0x39);
    const header = "short-header";
    const plaintext = "PING-frame-payload";

    var ciphertext: [plaintext.len]u8 = undefined;
    var tag: [Aes128Gcm.tag_length]u8 = undefined;
    Aes128Gcm.encrypt(&ciphertext, &tag, plaintext, header, nonce, key);

    // A valid packet decrypts back to the plaintext through the constant-time tag check.
    var recovered: [plaintext.len]u8 = undefined;
    Aes128Gcm.decrypt(&recovered, &ciphertext, tag, header, nonce, key) catch {};
    expect(&failures, "valid packet decrypts to plaintext", std.mem.eql(u8, &recovered, plaintext));

    // A one-bit flip in the tag MUST be rejected. The decrypt does the compare in constant time.
    var tampered_tag = tag;
    tampered_tag[0] ^= 0x01;
    const tag_rejected = std.meta.isError(Aes128Gcm.decrypt(&recovered, &ciphertext, tampered_tag, header, nonce, key));
    expect(&failures, "flipped tag bit -> rejected", tag_rejected);

    // A flip in the ciphertext (the protected payload) MUST be rejected.
    var tampered_ct = ciphertext;
    tampered_ct[0] ^= 0x01;
    const ct_rejected = std.meta.isError(Aes128Gcm.decrypt(&recovered, &tampered_ct, tag, header, nonce, key));
    expect(&failures, "flipped ciphertext bit -> rejected", ct_rejected);

    // A flip in the associated data (the header that header protection covers) MUST be rejected.
    const ad_rejected = std.meta.isError(Aes128Gcm.decrypt(&recovered, &ciphertext, tag, "Short-header", nonce, key));
    expect(&failures, "flipped header (AAD) bit -> rejected", ad_rejected);

    // A rejected packet feeds the integrity counter rather than tearing down on the first failure.
    var tamper_usage = KeyUsage{ .aead = .aes_128_gcm };
    if (std.meta.isError(Aes128Gcm.decrypt(&recovered, &ciphertext, tampered_tag, header, nonce, key))) {
        _ = tamper_usage.onAuthFailure();
    }
    expect(&failures, "rejected packet increments integrity counter", tamper_usage.auth_failures == 1);

    // The constant-time primitive for any manual token compare (stateless reset, retry tag).
    const token_a: [16]u8 = @splat(0xa5);
    var token_b: [16]u8 = @splat(0xa5);
    expect(&failures, "timing_safe.eql equal tokens match", std.crypto.timing_safe.eql([16]u8, token_a, token_b));

    token_b[15] ^= 0x01;
    expect(&failures, "timing_safe.eql one-bit diff fails", !std.crypto.timing_safe.eql([16]u8, token_a, token_b));

    std.debug.print("\n", .{});
    if (failures == 0) {
        std.debug.print("PASS: all RFC 9001 6.6 + 9.5 checks hold\n", .{});
    } else {
        std.debug.print("FAIL: {d} check(s) failed\n", .{failures});
        std.process.exit(1);
    }
}
