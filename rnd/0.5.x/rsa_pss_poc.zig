//! RSA signing PoC, phase R2 (rsa-plan.md): EMSA-PSS over SHA-256 with MGF1, plus RSASP1.
//!
//! Note:
//! - This is the randomized signer (rsa_pss_rsae_sha256, the TLS 1.3 RSA CertificateVerify scheme).
//!   EMSA-PSS (RFC 8017 9.1) injects a random salt, so two correct signatures over the same message
//!   differ. The gate is therefore "openssl verifies it" plus a reverse round-trip, not a byte match
//!   (verify-rsa.sh step 4).
//! - Salt length equals the hash length (32), matching openssl rsa_pss_saltlen:32.
//! - As in the v1.5 PoC the bignum is std.crypto.ff and the key is raw modulus / exponent hex on
//!   argv. DER key parsing is a later phase (R3).
//!
//! Usage:
//! ```zig
//! // argv: <n_hex> <d_hex> <message> <sig_out_path>
//! //   n_hex - RSA modulus, big-endian hex (512 hex chars for RSA-2048)
//! //   d_hex - RSA private exponent, big-endian hex
//! //   message - the bytes to sign (hashed with SHA-256 internally)
//! //   sig_out_path - where the raw signature (k bytes) is written
//! ```
//!
//! Run: zig run rnd/0.5.x/rsa_pss_poc.zig -- <n_hex> <d_hex> <message> <sig_out_path>

const std = @import("std");

const Sha256 = std.crypto.hash.sha2.Sha256;

/// Upper bound on the modulus size this PoC accepts (RSA-4096). RSA-2048 keys use a subset.
const max_modulus_bits = 4096;

const Modulus = std.crypto.ff.Modulus(max_modulus_bits);

const hash_len = Sha256.digest_length;

/// Salt length for rsa_pss_rsae_sha256 (equals the hash length).
const salt_len = hash_len;

pub fn main(process: std.process.Init) !void {
    const io = process.io;

    var arg_iter = std.process.Args.Iterator.init(process.minimal.args);
    _ = arg_iter.skip();

    const n_hex = arg_iter.next() orelse return error.UsageNeedsFourArgs;
    const d_hex = arg_iter.next() orelse return error.UsageNeedsFourArgs;
    const message = arg_iter.next() orelse return error.UsageNeedsFourArgs;
    const out_path = arg_iter.next() orelse return error.UsageNeedsFourArgs;

    var n_buf: [max_modulus_bits / 8]u8 = undefined;
    var d_buf: [max_modulus_bits / 8]u8 = undefined;
    const n_bytes = try std.fmt.hexToBytes(&n_buf, n_hex);
    const d_bytes = try std.fmt.hexToBytes(&d_buf, d_hex);

    const k = n_bytes.len;

    const modulus = try Modulus.fromBytes(n_bytes, .big);
    const mod_bits = modulus.bits();

    var em_buf: [max_modulus_bits / 8]u8 = undefined;
    const em_len = std.math.divCeil(usize, mod_bits - 1, 8) catch unreachable;
    const em = em_buf[0..em_len];
    try emsaPssEncode(message, mod_bits - 1, em);

    var sig_buf: [max_modulus_bits / 8]u8 = undefined;
    const sig = sig_buf[0..k];
    try rsasp1(modulus, d_bytes, em, sig);

    const cwd = std.Io.Dir.cwd();
    const file = try cwd.createFile(io, out_path, .{});
    defer file.close(io);

    var write_buf: [max_modulus_bits / 8]u8 = undefined;
    var writer = file.writer(io, &write_buf);
    try writer.interface.writeAll(sig);
    try writer.interface.flush();
}

/// Encode a message as EMSA-PSS (RFC 8017 9.1.1) with a random salt.
///
/// Note:
/// - M' = (eight 0x00) || mHash || salt, H = Hash(M'). DB = PS || 0x01 || salt, masked with
///   MGF1(H). The leftmost (8 * emLen - emBits) bits of the first masked octet are cleared, then
///   EM = maskedDB || H || 0xbc.
///
/// Param:
/// message - []const u8 (the bytes to sign)
/// em_bits - usize (the maximal bit length of the integer OS2IP(EM), which is modBits - 1)
/// em - []u8 (the output buffer, length ceil(em_bits / 8))
///
/// Return:
/// - void
/// - error.EncodingError if the modulus is too small for the salt and hash
fn emsaPssEncode(message: []const u8, em_bits: usize, em: []u8) !void {
    var m_hash: [hash_len]u8 = undefined;
    Sha256.hash(message, &m_hash, .{});

    const em_len = em.len;
    if (em_len < hash_len + salt_len + 2) return error.EncodingError;

    var salt: [salt_len]u8 = undefined;
    _ = std.os.linux.getrandom(&salt, salt.len, 0);

    var h_input: [8 + hash_len + salt_len]u8 = undefined;
    @memset(h_input[0..8], 0x00);
    @memcpy(h_input[8..][0..hash_len], &m_hash);
    @memcpy(h_input[8 + hash_len ..][0..salt_len], &salt);

    var h: [hash_len]u8 = undefined;
    Sha256.hash(&h_input, &h, .{});

    const db_len = em_len - hash_len - 1;
    const db = em[0..db_len];
    @memset(db, 0x00);
    db[db_len - salt_len - 1] = 0x01;
    @memcpy(db[db_len - salt_len ..][0..salt_len], &salt);

    var db_mask: [max_modulus_bits / 8]u8 = undefined;
    mgf1(&h, db_mask[0..db_len]);
    for (db, 0..) |*byte, i| byte.* ^= db_mask[i];

    const clear_bits = 8 * em_len - em_bits;
    db[0] &= @as(u8, 0xff) >> @intCast(clear_bits);

    @memcpy(em[db_len..][0..hash_len], &h);
    em[em_len - 1] = 0xbc;
}

/// MGF1 mask generation function (RFC 8017 B.2.1) with SHA-256.
///
/// Param:
/// seed - []const u8 (the seed, here the hash H)
/// out - []u8 (the mask buffer to fill)
///
/// Return:
/// - void
fn mgf1(seed: []const u8, out: []u8) void {
    var counter: u32 = 0;
    var pos: usize = 0;
    while (pos < out.len) : (counter += 1) {
        var c: [4]u8 = undefined;
        std.mem.writeInt(u32, &c, counter, .big);

        var digest: [hash_len]u8 = undefined;
        var hasher = Sha256.init(.{});
        hasher.update(seed);
        hasher.update(&c);
        hasher.final(&digest);

        const take = @min(hash_len, out.len - pos);
        @memcpy(out[pos..][0..take], digest[0..take]);
        pos += take;
    }
}

/// RSASP1 signature primitive (RFC 8017 5.2.1): s = m ^ d mod n, then I2OSP to k bytes.
///
/// Param:
/// modulus - Modulus (the RSA modulus n, already parsed)
/// d_bytes - []const u8 (the private exponent, big-endian)
/// em - []const u8 (the encoded message)
/// sig - []u8 (the output buffer, length k)
///
/// Return:
/// - void
fn rsasp1(modulus: Modulus, d_bytes: []const u8, em: []const u8, sig: []u8) !void {
    const m_fe = try Modulus.Fe.fromBytes(modulus, em, .big);

    const s_fe = try modulus.powWithEncodedExponent(m_fe, d_bytes, .big);

    try s_fe.toBytes(sig, .big);
}
