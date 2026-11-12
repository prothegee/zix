//! TLZ crypto rsa PrivateKey
//!
//! ### file: src/tlz/src/crypto/rsa/PrivateKey.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! A parsed two-prime RSA private key and its two signature operations:
//! PKCS#1 v1.5 (TLS 1.2) and PSS (TLS 1.3 rsa_pss_rsae_sha256), RFC 8017.
//!
//! ### note:
//!
//! Every value is copied into owned fixed buffers, so the key holds no external
//! memory and is safe to store by value. The PSS salt comes from the caller, so a
//! signature is deterministic given its inputs.
//!
//! ---------------------------------------------------------
//!
//! ### licenses:
//!
//! - BSD-3-Clause
//!
//! ### copyright:
//!
//! - (c) Prana Ron // @prothegee // prothegee@pm.me
//!
//! ### contributors:
//!
//! - Prana Ron // @prothegee // prothegee@pm.me
//!

const std = @import("std");
const rsa = @import("../rsa.zig");
const crt = @import("crt.zig");
const DerReader = @import("../DerReader.zig");

const Sha256 = std.crypto.hash.sha2.Sha256;
const Modulus = rsa.Modulus;
const MAX_MODULUS_LEN = rsa.MAX_MODULUS_LEN;
const MAX_PRIME_LEN = rsa.MAX_PRIME_LEN;

// --------------------------------------------------------- //
// Fields:

/// The modulus n, big-endian, leading zeros stripped.
n_buf: [MAX_MODULUS_LEN]u8 = undefined,
n_len: usize = 0,
/// The private exponent d, big-endian.
d_buf: [MAX_MODULUS_LEN]u8 = undefined,
d_len: usize = 0,
/// The CRT factors (RFC 8017 3.2 second form) were parsed. When false, signing
/// falls back to the plain m ^ d mod n path.
has_crt: bool = false,
/// The CRT prime p.
p_buf: [MAX_PRIME_LEN]u8 = undefined,
p_len: usize = 0,
/// The CRT prime q.
q_buf: [MAX_PRIME_LEN]u8 = undefined,
q_len: usize = 0,
/// The CRT exponent dP = d mod (p - 1).
dp_buf: [MAX_PRIME_LEN]u8 = undefined,
dp_len: usize = 0,
/// The CRT exponent dQ = d mod (q - 1).
dq_buf: [MAX_PRIME_LEN]u8 = undefined,
dq_len: usize = 0,
/// The CRT coefficient qInv = q^-1 mod p.
qinv_buf: [MAX_PRIME_LEN]u8 = undefined,
qinv_len: usize = 0,

const Self = @This();

// --------------------------------------------------------- //
// Private:

/// The parse path: the DER cursor plus this module's own errors.
const ParseInner = DerReader.Error || ParseError;

/// The sign paths: the RSA primitives plus this module's own errors.
const SignInner = rsa.Error || SignError;

fn signError(err: SignInner) SignError {
    @branchHint(.cold);

    return switch (err) {
        error.Tlz_Rsa_InvalidKey => error.Tlz_RsaPrivateKey_InvalidKey,
        error.Tlz_Rsa_MessageTooLong => error.Tlz_RsaPrivateKey_MessageTooLong,
        error.Tlz_RsaPrivateKey_InvalidKey,
        error.Tlz_RsaPrivateKey_MessageTooLong,
        => |own| own,
    };
}

fn fromDerInner(der: []const u8, is_pkcs8: bool) ParseInner!Self {
    var inner = der;

    if (is_pkcs8) {
        var outer: DerReader = .{ .buf = der };
        try outer.expectTag(DerReader.TAG_SEQUENCE);
        _ = try outer.readLen();
        try outer.skipElement(DerReader.TAG_INTEGER);
        try outer.skipElement(DerReader.TAG_SEQUENCE);
        try outer.expectTag(DerReader.TAG_OCTET_STRING);

        const inner_len = try outer.readLen();
        inner = try outer.readBytes(inner_len);
    }

    var reader: DerReader = .{ .buf = inner };
    try reader.expectTag(DerReader.TAG_SEQUENCE);
    _ = try reader.readLen();
    try reader.skipElement(DerReader.TAG_INTEGER);

    const modulus_bytes = try reader.readInteger();
    _ = try reader.readInteger();
    const exponent_bytes = try reader.readInteger();

    if (modulus_bytes.len > MAX_MODULUS_LEN or exponent_bytes.len > MAX_MODULUS_LEN) {
        return error.Tlz_RsaPrivateKey_InvalidKey;
    }

    var key: Self = .{
        .n_len = modulus_bytes.len,
        .d_len = exponent_bytes.len,
    };
    @memcpy(key.n_buf[0..modulus_bytes.len], modulus_bytes);
    @memcpy(key.d_buf[0..exponent_bytes.len], exponent_bytes);

    key.loadCrt(&reader);

    return key;
}

/// Read the optional CRT factors that follow d. On any miss (absent, malformed, or
/// wider than a supported prime) the key keeps `has_crt` false.
fn loadCrt(self: *Self, reader: *DerReader) void {
    var factors: [5][]const u8 = undefined;

    for (&factors) |*factor| {
        factor.* = reader.readInteger() catch |err| switch (err) {
            error.Tlz_DerReader_Malformed => return,
        };

        if (factor.len > MAX_PRIME_LEN) return;
    }

    copyFactor(&self.p_buf, &self.p_len, factors[0]);
    copyFactor(&self.q_buf, &self.q_len, factors[1]);
    copyFactor(&self.dp_buf, &self.dp_len, factors[2]);
    copyFactor(&self.dq_buf, &self.dq_len, factors[3]);
    copyFactor(&self.qinv_buf, &self.qinv_len, factors[4]);

    self.has_crt = true;
}

fn copyFactor(buf: *[MAX_PRIME_LEN]u8, len: *usize, factor: []const u8) void {
    @memcpy(buf[0..factor.len], factor);
    len.* = factor.len;
}

fn parseModulus(bytes: []const u8) SignError!Modulus {
    return Modulus.fromBytes(bytes, .big) catch |err| switch (err) {
        else => error.Tlz_RsaPrivateKey_InvalidKey,
    };
}

fn parseFe(mod: Modulus, bytes: []const u8) SignError!Modulus.Fe {
    return Modulus.Fe.fromBytes(mod, bytes, .big) catch |err| switch (err) {
        else => error.Tlz_RsaPrivateKey_InvalidKey,
    };
}

fn writeFe(value: Modulus.Fe, out: []u8) SignError!void {
    value.toBytes(out, .big) catch |err| switch (err) {
        else => return error.Tlz_RsaPrivateKey_InvalidKey,
    };
}

fn signPkcs1v15Inner(self: *const Self, message: []const u8, out: []u8) SignInner![]const u8 {
    const key_len = self.size();

    var digest: [rsa.HASH_LEN]u8 = undefined;
    Sha256.hash(message, &digest, .{});

    var em_buf: [MAX_MODULUS_LEN]u8 = undefined;
    const em = em_buf[0..key_len];
    try rsa.emsaPkcs1V15(digest, em);

    if (self.fastCrt(em, out[0..key_len])) |sig| return sig;

    if (self.has_crt) {
        const mod_n = try parseModulus(self.modulus());

        return self.rsaspCrt(mod_n, em, out[0..key_len]);
    }

    return rsa.rsasp1(self.modulus(), self.privateExponent(), em, out[0..key_len]);
}

fn signPssInner(
    self: *const Self,
    message: []const u8,
    salt: [rsa.PSS_SALT_LEN]u8,
    out: []u8,
) SignInner![]const u8 {
    const key_len = self.size();
    if (key_len == 0 or self.n_buf[0] == 0) return error.Tlz_RsaPrivateKey_InvalidKey;

    const em_bits = key_len * 8 - @clz(self.n_buf[0]) - 1;

    var em_buf: [MAX_MODULUS_LEN]u8 = undefined;
    const em_len = (em_bits + 7) / 8;
    const em = em_buf[0..em_len];
    try rsa.emsaPssEncode(message, salt, em_bits, em);

    if (self.fastCrt(em, out[0..key_len])) |sig| return sig;

    const mod_n = try parseModulus(self.modulus());
    if (self.has_crt) return self.rsaspCrt(mod_n, em, out[0..key_len]);

    return rsa.rsasp1WithModulus(mod_n, self.privateExponent(), em, out[0..key_len]);
}

/// The CRT factors as slices for `crt.zig`.
fn crtFactors(self: *const Self) crt.Factors {
    return .{
        .p = self.primeP(),
        .q = self.primeQ(),
        .dp = self.expDp(),
        .dq = self.expDq(),
        .qinv = self.coeffQinv(),
    };
}

/// The fixed-width CRT sign for RSA-2048/3072/4096 keys.
///
/// Return:
/// - []const u8 (the signature, `sig`)
/// - null when the key has no CRT factors or no fast path, so the caller takes the
///   std.crypto.ff path
fn fastCrt(self: *const Self, em: []const u8, sig: []u8) ?[]const u8 {
    if (!self.has_crt or sig.len != 2 * self.p_len) return null;

    const key_factors = self.crtFactors();
    if (!crt.supports(key_factors, em.len)) return null;

    return crt.rsasp(key_factors, em, sig);
}

/// RSASP1 through the Chinese Remainder Theorem (RFC 8017 5.1.2 second form): two
/// half-width modexps over p and q instead of one full-width modexp.
///
/// Param:
/// mod_n - Modulus (the parsed public modulus, reused)
/// em - []const u8 (the encoded message, below n)
/// sig - []u8 (the signature, exactly size() bytes)
///
/// Return:
/// - []const u8 (`sig`)
/// - SignInner error when a factor is malformed
fn rsaspCrt(self: *const Self, mod_n: Modulus, em: []const u8, sig: []u8) SignInner![]const u8 {
    const key_len = sig.len;
    const mod_p = try parseModulus(self.primeP());
    const mod_q = try parseModulus(self.primeQ());

    // m reduced into each prime field, then m1 = m^dP mod p, m2 = m^dQ mod q
    const m_n = try parseFe(mod_n, em);
    const m_p = mod_p.reduce(m_n.v);
    const m_q = mod_q.reduce(m_n.v);

    const s_p = try rsa.crtHalf(mod_p, m_p, self.expDp());
    const s_q = try rsa.crtHalf(mod_q, m_q, self.expDq());

    // coeff_h = (s_p - s_q) * qInv mod p
    const s_q_mod_p = mod_p.reduce(s_q.v);
    const diff = mod_p.sub(s_p, s_q_mod_p);
    const qinv = try parseFe(mod_p, self.coeffQinv());
    const coeff_h = mod_p.mul(diff, qinv);

    // sig = s_q + q * coeff_h. Both terms are below n, so the n-field math is exact
    var h_buf: [MAX_MODULUS_LEN]u8 = undefined;
    try writeFe(coeff_h, h_buf[0..key_len]);
    var sq_buf: [MAX_MODULUS_LEN]u8 = undefined;
    try writeFe(s_q, sq_buf[0..key_len]);

    const h_n = try parseFe(mod_n, h_buf[0..key_len]);
    const s_q_n = try parseFe(mod_n, sq_buf[0..key_len]);
    const q_n = try parseFe(mod_n, self.primeQ());

    const qh = mod_n.mul(q_n, h_n);
    const signature_fe = mod_n.add(s_q_n, qh);
    try writeFe(signature_fe, sig);

    return sig;
}

// --------------------------------------------------------- //
// Public:

pub const Error = error{
    Tlz_RsaPrivateKey_InvalidKey,
    Tlz_RsaPrivateKey_MessageTooLong,
};

/// The part of Error `fromDer` can return.
pub const ParseError = error{
    Tlz_RsaPrivateKey_InvalidKey,
};

/// The part of Error the sign calls can return.
pub const SignError = Error;

/// Parse a two-prime RSAPrivateKey, unwrapping the PKCS#8 PrivateKeyInfo first when
/// `is_pkcs8`.
///
/// Note:
/// - PKCS#8 (RFC 5208): SEQUENCE { version, AlgorithmIdentifier, OCTET STRING }.
///   The OCTET STRING holds the PKCS#1 key.
/// - PKCS#1 (RFC 8017 A.1.2): SEQUENCE { version, n, e, d, p, q, dp, dq, qinv }.
///   n and d are kept, plus the CRT factors when present.
///
/// Param:
/// der - []const u8 (the decoded key DER)
/// is_pkcs8 - bool (true for PKCS#8, false for a bare PKCS#1 RSAPrivateKey)
///
/// Return:
/// - Self (owns every byte it holds)
/// - Error.Tlz_RsaPrivateKey_InvalidKey when the DER is malformed or too wide
pub fn fromDer(der: []const u8, is_pkcs8: bool) ParseError!Self {
    return fromDerInner(der, is_pkcs8) catch |err| switch (err) {
        error.Tlz_DerReader_Malformed => error.Tlz_RsaPrivateKey_InvalidKey,
        error.Tlz_RsaPrivateKey_InvalidKey => |own| own,
    };
}

/// The modulus n, big-endian.
///
/// Return:
/// - []const u8
pub fn modulus(self: *const Self) []const u8 {
    return self.n_buf[0..self.n_len];
}

/// The private exponent d, big-endian.
///
/// Return:
/// - []const u8
pub fn privateExponent(self: *const Self) []const u8 {
    return self.d_buf[0..self.d_len];
}

/// The CRT prime p, big-endian.
///
/// Return:
/// - []const u8
pub fn primeP(self: *const Self) []const u8 {
    return self.p_buf[0..self.p_len];
}

/// The CRT prime q, big-endian.
///
/// Return:
/// - []const u8
pub fn primeQ(self: *const Self) []const u8 {
    return self.q_buf[0..self.q_len];
}

/// The CRT exponent dP, big-endian.
///
/// Return:
/// - []const u8
pub fn expDp(self: *const Self) []const u8 {
    return self.dp_buf[0..self.dp_len];
}

/// The CRT exponent dQ, big-endian.
///
/// Return:
/// - []const u8
pub fn expDq(self: *const Self) []const u8 {
    return self.dq_buf[0..self.dq_len];
}

/// The CRT coefficient qInv, big-endian.
///
/// Return:
/// - []const u8
pub fn coeffQinv(self: *const Self) []const u8 {
    return self.qinv_buf[0..self.qinv_len];
}

/// The modulus byte length, which is also the signature length.
///
/// Return:
/// - usize
pub fn size(self: *const Self) usize {
    return self.n_len;
}

/// Sign with EMSA-PKCS1-v1_5 over SHA-256 (RFC 8017 8.2.1). Deterministic.
///
/// Param:
/// message - []const u8 (the bytes to sign, hashed here)
/// out - []u8 (at least size() bytes)
///
/// Return:
/// - []const u8 (the signature, size() bytes of `out`)
/// - Error.Tlz_RsaPrivateKey_MessageTooLong when the modulus is too small
/// - Error.Tlz_RsaPrivateKey_InvalidKey when a key value is malformed
pub fn signPkcs1v15(self: *const Self, message: []const u8, out: []u8) SignError![]const u8 {
    return self.signPkcs1v15Inner(message, out) catch |err| signError(err);
}

/// Sign with EMSA-PSS over SHA-256 and MGF1 (RFC 8017 8.1.1, rsa_pss_rsae_sha256).
///
/// Param:
/// message - []const u8 (the bytes to sign, hashed here)
/// salt - [rsa.PSS_SALT_LEN]u8 (the random salt, 32 bytes)
/// out - []u8 (at least size() bytes)
///
/// Return:
/// - []const u8 (the signature, size() bytes of `out`)
/// - Error.Tlz_RsaPrivateKey_MessageTooLong when the modulus is too small
/// - Error.Tlz_RsaPrivateKey_InvalidKey when a key value is malformed
pub fn signPss(
    self: *const Self,
    message: []const u8,
    salt: [rsa.PSS_SALT_LEN]u8,
    out: []u8,
) SignError![]const u8 {
    return self.signPssInner(message, salt, out) catch |err| signError(err);
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const pem = @import("../pem.zig");
const std_rsa_verify = @import("../std_rsa_verify.zig");

const StdRsa = std.crypto.Certificate.rsa;

/// A deterministic RSA-2048 PKCS#8 key (openssl genpkey).
const FIXTURE_PKCS8_PEM =
    \\-----BEGIN PRIVATE KEY-----
    \\MIIEvgIBADANBgkqhkiG9w0BAQEFAASCBKgwggSkAgEAAoIBAQDiK/ullhGBT/Mj
    \\s1cQ3b7xqIAtHwMjuTxnUne42qU3cUrEeH2/jWjXjEeBMBqt8TYp1FVpDg+u2DGU
    \\Jada+rtFsPVZkD/07HUGXYfya6hwdwOqwjm+fdI+jIIpM+N1t6Ln+eV75GIu8KEr
    \\uRQVTsR3Rz8uMcIN/apvXP1Tus2Y2ZIhAKX9vk2DvL6+7gCLzK0wJmdQ34aGEw89
    \\MRfQLVmTpFvZSJ2B81dxY+IdgbshiZbbn76pzdH4TvxIOwDpUxW16qY7VXZErMtR
    \\S9jnavMpIB1sTkZLKZyIkowWqeeVWIQG85RreOwiEYywRUYnhI44YBxf0Xmgr1x6
    \\CnJ3atxDAgMBAAECggEACaafz9KF/7MWKG1UJ0OXDL/IbGR44VLbqXsC4c/uod2D
    \\N7v+fah+k0gImxIe6VI0IffOBzQS5j6SawRqTj8Js7EX3xEBMaXPXoyqKuV+JAJo
    \\FSbBiQfca0/alACDUbgayvRGXxGBQQiCkBePLFOWnZJcN0/nPGqZFbRtmN+NO1rk
    \\zTD46uKfBAFMKZLbWrK8plECMfea5h+/ysnfhpZXv5nAXuPY6cvwgDTZvphQdB4l
    \\4mjAtuI6oEYUL4CVga1NE57vC02RxJBwylmxznJyJcRdLl52kSgOMU3xV9isrrZT
    \\88s9Ds5ZxtGqaWUmbF+pHW1wxzTmJhrCXxEGtsrmAQKBgQD5u1KiuTlPnnVgIRfT
    \\thzF5pBp6Ynwbw/Q0SMkF/E7yxkPDdLWMY43WIikRj9IyfDnIRxdGEBkprF7/Sm/
    \\ehGVGRDNNT3eRaZ04jLP/EbksO9hF49ro/FlHSaaVrDSAsW3F8HBp8NQC9Sgpdlf
    \\XwnxZsP35wpISF1hWV5be0yWAQKBgQDn2UYCjGCRFdBNdsqxbgGemPBu60/U0leE
    \\T8xg42jN6tO2j0vesKp83NFcAl71NYh7rl8G+WnFJ3DgrjrFAPbTa6VJdnNnpjV+
    \\3o2CSqSTAReFM2khRIZodCbQ3Ad/6P00RnahpciBemQsQKeyGRMrhrkBZbiPIWch
    \\LgBIniOaQwKBgGcmxsVL+K44Z4cjZDIgoNXlnHUC7+UOGtxH5ln8QbpO87TSIuoy
    \\YeneeeJQ2cb5EraFaK/TWpW4fMsYEOx0QVrylYwNl9Z9snnJDO/35liD9PyHvMfb
    \\WdRILC/H6xVz67Lq7y9MWlJv8I3Cs3y/Rt4dcoitOAQPT/Lr9RuYXFQBAoGBAM0U
    \\QXsrlJeBRhnfQ/eiKMiS28ohVyIXVNZyh4QEY8YRO2g2ZJP8jTGZWY8bgcdArRNJ
    \\8ECJCegctRnow49TBQGKLFBI+Ffsi1FHpsBjKiPmSVnHWezVYlaut07z8aZQ/vfo
    \\hDMEI9Fz43vJTQyaZXyQ1MDJq3DfyQtuV03ko/VlAoGBAJiRuT9T8EQO0gJoaS6g
    \\W/+g7A+JUZnqIrCiL9JAaWzOy4TdKtEgbDQsLH1NfVclcnti5C/6wlCqvPcSQtF/
    \\ZGgEuI4ajyq60Un5tOiB1rbJ5sahSLgpM21Ph6kkC6nxTuKfRPpu1+L92SFZBFrX
    \\sIWllpzoV5pFqYoMGir8MZfp
    \\-----END PRIVATE KEY-----
;

const FIXTURE_MESSAGE = "zix rsa fixture, rfc 8017";

const FIXTURE_MODULUS_HEX =
    "e22bfba59611814ff323b35710ddbef1a8802d1f0323b93c675277b8daa537714ac4787dbf8d68d7" ++
    "8c4781301aadf13629d455690e0faed8319425a75afabb45b0f559903ff4ec75065d87f26ba87077" ++
    "03aac239be7dd23e8c822933e375b7a2e7f9e57be4622ef0a12bb914154ec477473f2e31c20dfdaa" ++
    "6f5cfd53bacd98d9922100a5fdbe4d83bcbebeee008bccad30266750df8686130f3d3117d02d5993" ++
    "a45bd9489d81f3577163e21d81bb218996db9fbea9cdd1f84efc483b00e95315b5eaa63b557644ac" ++
    "cb514bd8e76af329201d6c4e464b299c88928c16a9e795588406f3946b78ec22118cb0454627848e" ++
    "38601c5fd179a0af5c7a0a72776adc43";

/// The openssl PKCS#1 v1.5 signature over FIXTURE_MESSAGE.
const FIXTURE_V15_SIG_HEX =
    "de026c6dec3aaec2bc96e8bc2a940d3bd3d9ad40f8118f463b9ee9d528a736e8abd5c2eee17737d5" ++
    "2c097126849fe9f076971339a1412074afdc7dc47b6a2d76577fd9d300f82a55d80f74f6feb2f851" ++
    "b913a7d7b2c72de9183d868bbf1fd848d4283bcd6e6a1ca7c47e04d274b129249b96cc0b6557081f" ++
    "a0abb03b00cdd48c91ec57780d15921aaccd116cf7bde01a039412720702d3bb3c486d16cbccce4a" ++
    "3ac27d6a5d90779f3c57b5403a91e6235c5787bb814cde48cfc818ef005489a57035abd582ad96da" ++
    "e9e87c1f294ec68fd4dadd25395f90da7f35d096d3181e8c62303d12f51bb416df5d70c61bf5e41e" ++
    "6381f56910b5c03593cf5b2f55e064c9";

fn loadFixtureKey() !Self {
    var der_buf: [4096]u8 = undefined;
    const der = try pem.pemToDer(&der_buf, FIXTURE_PKCS8_PEM);

    return fromDer(der, true);
}

fn fixturePublicKey() !StdRsa.PublicKey {
    var n_bytes: [256]u8 = undefined;
    _ = try std.fmt.hexToBytes(&n_bytes, FIXTURE_MODULUS_HEX);
    const e_bytes = [_]u8{ 0x01, 0x00, 0x01 };

    return StdRsa.PublicKey.fromBytes(&e_bytes, &n_bytes);
}

test "tlz crypto rsa: PrivateKey, PKCS#8 parse gives the expected modulus" {
    var expected_n: [256]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected_n, FIXTURE_MODULUS_HEX);

    const key = try loadFixtureKey();

    try std.testing.expectEqual(@as(usize, 256), key.size());
    try std.testing.expectEqualSlices(u8, &expected_n, key.modulus());
}

test "tlz crypto rsa: PrivateKey, PKCS#8 parse loads the CRT factors" {
    const key = try loadFixtureKey();

    try std.testing.expect(key.has_crt);
    try std.testing.expectEqual(@as(usize, 128), key.primeP().len);
    try std.testing.expectEqual(@as(usize, 128), key.primeQ().len);
}

test "tlz crypto rsa: PrivateKey, PKCS#1 v1.5 sign is byte exact with openssl" {
    var expected_sig: [256]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected_sig, FIXTURE_V15_SIG_HEX);
    const key = try loadFixtureKey();
    var sig_buf: [MAX_MODULUS_LEN]u8 = undefined;

    const sig = try key.signPkcs1v15(FIXTURE_MESSAGE, &sig_buf);

    try std.testing.expectEqualSlices(u8, &expected_sig, sig);
}

test "tlz crypto rsa: PrivateKey, PKCS#1 v1.5 signature verifies with std" {
    const key = try loadFixtureKey();
    const public_key = try fixturePublicKey();
    var sig_buf: [MAX_MODULUS_LEN]u8 = undefined;

    const sig = try key.signPkcs1v15(FIXTURE_MESSAGE, &sig_buf);

    try std_rsa_verify.verifyPkcs1v15(256, sig[0..256], FIXTURE_MESSAGE, public_key, Sha256);
}

test "tlz crypto rsa: PrivateKey, PSS signature verifies with std" {
    const key = try loadFixtureKey();
    const public_key = try fixturePublicKey();
    const salt: [rsa.PSS_SALT_LEN]u8 = @splat(0x5a);
    var sig_buf: [MAX_MODULUS_LEN]u8 = undefined;

    const sig = try key.signPss(FIXTURE_MESSAGE, salt, &sig_buf);

    try std_rsa_verify.verifyPss(256, sig[0..256], FIXTURE_MESSAGE, public_key, Sha256);
}

test "tlz crypto rsa: PrivateKey, PSS CRT sign equals the plain path" {
    const key = try loadFixtureKey();
    var plain_key = key;
    plain_key.has_crt = false;
    const salt: [rsa.PSS_SALT_LEN]u8 = @splat(0x5a);
    var crt_buf: [MAX_MODULUS_LEN]u8 = undefined;
    var plain_buf: [MAX_MODULUS_LEN]u8 = undefined;

    const crt_sig = try key.signPss(FIXTURE_MESSAGE, salt, &crt_buf);
    const plain_sig = try plain_key.signPss(FIXTURE_MESSAGE, salt, &plain_buf);

    try std.testing.expectEqualSlices(u8, plain_sig, crt_sig);
}

test "tlz crypto rsa: PrivateKey, PKCS#1 v1.5 CRT sign equals the plain path" {
    const key = try loadFixtureKey();
    var plain_key = key;
    plain_key.has_crt = false;
    var crt_buf: [MAX_MODULUS_LEN]u8 = undefined;
    var plain_buf: [MAX_MODULUS_LEN]u8 = undefined;

    const crt_sig = try key.signPkcs1v15(FIXTURE_MESSAGE, &crt_buf);
    const plain_sig = try plain_key.signPkcs1v15(FIXTURE_MESSAGE, &plain_buf);

    try std.testing.expectEqualSlices(u8, plain_sig, crt_sig);
}

test "tlz crypto rsa: PrivateKey, tampered message fails std verify" {
    const key = try loadFixtureKey();
    const public_key = try fixturePublicKey();
    var sig_buf: [MAX_MODULUS_LEN]u8 = undefined;

    const sig = try key.signPkcs1v15(FIXTURE_MESSAGE, &sig_buf);

    try std.testing.expectError(
        std_rsa_verify.Error.Tlz_StdRsaVerify_InvalidSignature,
        std_rsa_verify.verifyPkcs1v15(256, sig[0..256], "tampered message", public_key, Sha256),
    );
}

test "tlz crypto rsa: PrivateKey, empty DER is an invalid key" {
    try std.testing.expectError(Error.Tlz_RsaPrivateKey_InvalidKey, fromDer(&.{}, true));
}

test "tlz crypto rsa: PrivateKey, PKCS#8 DER read as PKCS#1 is an invalid key" {
    var der_buf: [4096]u8 = undefined;
    const der = try pem.pemToDer(&der_buf, FIXTURE_PKCS8_PEM);

    try std.testing.expectError(Error.Tlz_RsaPrivateKey_InvalidKey, fromDer(der, false));
}

test "tlz crypto rsa: PrivateKey, key without CRT factors signs on the plain path" {
    // SEQUENCE { version 0, n 33, e 3, d 7 }: no CRT factors follow
    const der = [_]u8{
        0x30, 0x0c, 0x02, 0x01, 0x00, 0x02, 0x01, 0x21,
        0x02, 0x01, 0x03, 0x02, 0x01, 0x07,
    };

    const key = try fromDer(&der, false);

    try std.testing.expect(!key.has_crt);
    try std.testing.expectEqualSlices(u8, &[_]u8{0x21}, key.modulus());
}

test "tlz crypto rsa: PrivateKey, signing with a tiny modulus is too long" {
    const der = [_]u8{
        0x30, 0x0c, 0x02, 0x01, 0x00, 0x02, 0x01, 0x21,
        0x02, 0x01, 0x03, 0x02, 0x01, 0x07,
    };
    const key = try fromDer(&der, false);
    var sig_buf: [MAX_MODULUS_LEN]u8 = undefined;

    try std.testing.expectError(
        Error.Tlz_RsaPrivateKey_MessageTooLong,
        key.signPkcs1v15("message", &sig_buf),
    );
}

