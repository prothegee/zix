//! TLS 1.2 PRF PoC (RFC 5246 section 5): P_SHA256 + the TLS 1.2 PRF, checked against the canonical
//! 100-byte SHA-256 known-answer vector. This de-risks the 1.2 key schedule: the master_secret, the
//! key_block, and the Finished verify_data all ride on this PRF (distinct from the 1.3 HKDF
//! schedule). First layer of tls12-plan.md.
//!
//! Run: `zig test rnd/0.5.x/tls12_prf_poc.zig`

const std = @import("std");

const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const mac_len = HmacSha256.mac_length;

/// P_SHA256(secret, seed) (RFC 5246 5): the data expansion function.
/// A(0) = seed, A(i) = HMAC(secret, A(i-1)), output = HMAC(secret, A(1)+seed) || HMAC(secret, A(2)+seed) || ...
/// Fills the whole of `out`, truncating the last HMAC block as needed.
fn pSha256(out: []u8, secret: []const u8, seed: []const u8) void {
    var a: [mac_len]u8 = undefined;
    HmacSha256.create(&a, seed, secret); // A(1) = HMAC(secret, seed)

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
            HmacSha256.create(&next, &a, secret); // A(i+1) = HMAC(secret, A(i))
            a = next;
        }
    }
}

/// TLS 1.2 PRF for the SHA-256 suites (RFC 5246 5): PRF(secret, label, seed) = P_SHA256(secret, label ++ seed).
/// `label` and `seed` together must fit the internal buffer (the real callers pass a short label plus
/// the two 32-byte randoms, well under the bound).
fn prf(out: []u8, secret: []const u8, label: []const u8, seed: []const u8) void {
    var label_seed: [256]u8 = undefined;
    @memcpy(label_seed[0..label.len], label);
    @memcpy(label_seed[label.len .. label.len + seed.len], seed);

    pSha256(out, secret, label_seed[0 .. label.len + seed.len]);
}

// --------------------------------------------------------------- //
// --------------------------------------------------------------- //

test "tls12 prf: P_SHA256 100-byte known-answer vector" {
    var secret: [16]u8 = undefined;
    _ = try std.fmt.hexToBytes(&secret, "9bbe436ba940f017b17652849a71db35");
    var seed: [16]u8 = undefined;
    _ = try std.fmt.hexToBytes(&seed, "a0ba9f936cda311827a6f796ffd5198c");

    var expected: [100]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected, "e3f229ba727be17b8d122620557cd453c2aab21d07c3d495329b52d4e61edb5a6b301791e90d35c9c9a46b4e14baf9af0fa022f7077def17abfd3797c0564bab4fbc91666e9def9b97fce34f796789baa48082d122ee42c5a72e5a5110fff70187347b66");

    var out: [100]u8 = undefined;
    prf(&out, &secret, "test label", &seed);

    try std.testing.expectEqualSlices(u8, &expected, &out);
}
