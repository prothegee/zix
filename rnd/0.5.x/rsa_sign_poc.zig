//! RSA signing PoC, phase R1 (rsa-plan.md): EMSA-PKCS1-v1_5 over SHA-256 plus RSASP1.
//!
//! Note:
//! - This is the deterministic signer. EMSA-PKCS1-v1_5 (RFC 8017 9.2) produces a fixed encoded
//!   message for a given key and input, so the output must be byte-identical to
//!   `openssl dgst -sha256 -sign`. That byte-exact match is the gate (verify-rsa.sh step 3).
//! - The bignum is not authored here: std provides the constant-time modular exponentiation via
//!   std.crypto.ff.Modulus.powWithEncodedExponent (the same routine std RSA verify uses, only
//!   driven with the private exponent). This PoC authors the padding and calls that routine.
//! - The private key is passed as raw modulus / private-exponent hex on argv because DER key
//!   parsing is a later phase (R3). Once R3 lands the signer reads the key file directly.
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
//! Run: zig run rnd/0.5.x/rsa_sign_poc.zig -- <n_hex> <d_hex> <message> <sig_out_path>

const std = @import("std");

const Sha256 = std.crypto.hash.sha2.Sha256;

/// Upper bound on the modulus size this PoC accepts (RSA-4096). RSA-2048 keys use a subset.
const max_modulus_bits = 4096;

const Modulus = std.crypto.ff.Modulus(max_modulus_bits);

/// DigestInfo DER prefix for SHA-256 (RFC 8017 9.2, the T value is this prefix then the 32 hash bytes).
const sha256_digestinfo_prefix = [_]u8{
    0x30, 0x31, 0x30, 0x0d, 0x06, 0x09, 0x60, 0x86,
    0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01, 0x05,
    0x00, 0x04, 0x20,
};

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

    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(message, &digest, .{});

    var em_buf: [max_modulus_bits / 8]u8 = undefined;
    const em = em_buf[0..k];
    try emsaPkcs1V15(digest, em);

    var sig_buf: [max_modulus_bits / 8]u8 = undefined;
    const sig = sig_buf[0..k];
    try rsasp1(n_bytes, d_bytes, em, sig);

    const cwd = std.Io.Dir.cwd();
    const file = try cwd.createFile(io, out_path, .{});
    defer file.close(io);

    var write_buf: [max_modulus_bits / 8]u8 = undefined;
    var writer = file.writer(io, &write_buf);
    try writer.interface.writeAll(sig);
    try writer.interface.flush();
}

/// Encode the SHA-256 digest as an EMSA-PKCS1-v1_5 message (RFC 8017 9.2).
///
/// Note:
/// - EM = 0x00 || 0x01 || PS || 0x00 || T, where PS is at least eight 0xff octets and T is the
///   DigestInfo prefix followed by the digest. The whole buffer is filled with 0xff first so PS
///   is already correct, then only the fixed positions are overwritten.
///
/// Param:
/// digest - [32]u8 (the SHA-256 hash of the message)
/// em - []u8 (the output buffer, length k, the modulus byte length)
///
/// Return:
/// - void
/// - error.IntendedEncodedMessageLengthTooShort if k cannot hold the padding plus T
fn emsaPkcs1V15(digest: [Sha256.digest_length]u8, em: []u8) !void {
    const t_len = sha256_digestinfo_prefix.len + Sha256.digest_length;
    if (em.len < t_len + 11) return error.IntendedEncodedMessageLengthTooShort;

    @memset(em, 0xff);
    em[0] = 0x00;
    em[1] = 0x01;
    em[em.len - t_len - 1] = 0x00;

    @memcpy(em[em.len - t_len ..][0..sha256_digestinfo_prefix.len], &sha256_digestinfo_prefix);
    @memcpy(em[em.len - Sha256.digest_length ..][0..Sha256.digest_length], &digest);
}

/// RSASP1 signature primitive (RFC 8017 5.2.1): s = m ^ d mod n, then I2OSP to k bytes.
///
/// Note:
/// - The modular exponentiation is std.crypto.ff, which is constant time with respect to the
///   private exponent, so this primitive does not leak d.
///
/// Param:
/// n_bytes - []const u8 (the modulus, big-endian)
/// d_bytes - []const u8 (the private exponent, big-endian)
/// em - []const u8 (the encoded message, length k)
/// sig - []u8 (the output buffer, length k)
///
/// Return:
/// - void
fn rsasp1(n_bytes: []const u8, d_bytes: []const u8, em: []const u8, sig: []u8) !void {
    const modulus = try Modulus.fromBytes(n_bytes, .big);
    const m_fe = try Modulus.Fe.fromBytes(modulus, em, .big);

    const s_fe = try modulus.powWithEncodedExponent(m_fe, d_bytes, .big);

    try s_fe.toBytes(sig, .big);
}
