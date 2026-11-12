//! TLZ context Context
//!
//! ### file: src/tlz/src/context/Context.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! The live server TLS context: the loaded certificate and signing key plus the
//! validated policy, built once and read per connection.
//!
//! ### note:
//!
//! tlz has no listener, so this is a context, not a server. `init` loads and checks
//! everything on the cold path. The slices from Config (alpn, curves, ciphers) are
//! borrowed and must outlive the Context.
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
const pem = @import("../crypto/pem.zig");
const der_guard = @import("../crypto/der_guard.zig");
const rsa = @import("../crypto/rsa.zig");
const RsaPrivateKey = @import("../crypto/rsa/PrivateKey.zig");
const HandshakeOptions = @import("../connection/HandshakeOptions.zig");
const SigningKey = @import("../crypto/certificate/signing_key.zig").SigningKey;
const Version = @import("version.zig").Version;
const Alpn = @import("../alpn.zig").Alpn;
const NamedGroup = @import("../named_group.zig").NamedGroup;
const CipherSuite = @import("../cipher_suite.zig").CipherSuite;

const EcdsaP256 = std.crypto.sign.ecdsa.EcdsaP256Sha256;
const Ed25519 = std.crypto.sign.Ed25519;

// --------------------------------------------------------- //
// Fields:

allocator: std.mem.Allocator,
/// The end-entity certificate DER, owned and freed by deinit.
cert_der: []u8,
/// The signing key matching the certificate key type.
signing_key: SigningKey,
alpn: []const Alpn,
curves: []const NamedGroup,
ciphers: []const CipherSuite,
min_version: Version,
max_version: Version,
prefer_server_ciphers: bool,
hsts_max_age_s: u32,

const Self = @This();

// --------------------------------------------------------- //
// Private:

/// The widest PEM file read. A chain or key past this is a configuration mistake.
const PEM_MAX_BYTES: usize = 1 << 20;

/// DER decode buffer for one certificate or key. An RSA PKCS#8 key is the largest.
const DER_BUF: usize = 4096;

/// The smallest RSA modulus accepted, in bytes (RSA-2048).
const RSA_MIN_MODULUS_LEN: usize = 256;

/// Which PEM file a read failure belongs to.
const PemFile = enum {
    CERT,
    KEY,
};

fn configError(err: Config.Error) Error {
    @branchHint(.cold);

    return switch (err) {
        error.Tlz_ContextConfig_NoCurves => Error.Tlz_Context_NoCurves,
        error.Tlz_ContextConfig_NoCiphers => Error.Tlz_Context_NoCiphers,
        error.Tlz_ContextConfig_UnsupportedCurve => Error.Tlz_Context_UnsupportedCurve,
        error.Tlz_ContextConfig_UnsupportedCipher => Error.Tlz_Context_UnsupportedCipher,
        error.Tlz_ContextConfig_InvalidVersionRange => Error.Tlz_Context_InvalidVersionRange,
        error.Tlz_ContextConfig_MissingCipherForVersion => {
            return Error.Tlz_Context_MissingCipherForVersion;
        },
        error.Tlz_ContextConfig_MissingCurveForTls12 => Error.Tlz_Context_MissingCurveForTls12,
    };
}

fn decodeError(err: pem.DecodeError) Error {
    @branchHint(.cold);

    return switch (err) {
        error.Tlz_Pem_Invalid => error.Tlz_Context_InvalidPem,
        error.Tlz_Pem_BufferTooSmall => error.Tlz_Context_PemTooLarge,
    };
}

/// Read one PEM file. Four causes get four names, so a permission problem and a
/// path typo do not read the same.
fn readPem(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    file: PemFile,
) Error![]u8 {
    const limit: std.Io.Limit = .limited(PEM_MAX_BYTES);

    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, limit) catch |err| switch (err) {
        error.FileNotFound => switch (file) {
            .CERT => Error.Tlz_Context_CertFileNotFound,
            .KEY => Error.Tlz_Context_KeyFileNotFound,
        },
        error.IsDir => switch (file) {
            .CERT => Error.Tlz_Context_CertPathIsDirectory,
            .KEY => Error.Tlz_Context_KeyPathIsDirectory,
        },
        error.StreamTooLong => switch (file) {
            .CERT => Error.Tlz_Context_CertFileTooLarge,
            .KEY => Error.Tlz_Context_KeyFileTooLarge,
        },
        error.OutOfMemory => Error.Tlz_Context_OutOfMemory,
        else => switch (file) {
            .CERT => Error.Tlz_Context_CertFileUnreadable,
            .KEY => Error.Tlz_Context_KeyFileUnreadable,
        },
    };
}

fn ecdsaKey(key_der: []const u8) Error!SigningKey {
    const scalar = pem.ecdsaScalarFromSec1(key_der) catch |err| switch (err) {
        error.Tlz_Pem_InvalidKey => return error.Tlz_Context_InvalidKey,
    };
    const secret_key = EcdsaP256.SecretKey.fromBytes(scalar) catch |err| switch (err) {
        else => return Error.Tlz_Context_InvalidKey,
    };
    const key_pair = EcdsaP256.KeyPair.fromSecretKey(secret_key) catch |err| switch (err) {
        else => return Error.Tlz_Context_InvalidKey,
    };

    return .{ .ecdsa_p256 = key_pair };
}

fn ed25519Key(key_der: []const u8) Error!SigningKey {
    const seed = pem.ed25519SeedFromPkcs8(key_der) catch |err| switch (err) {
        error.Tlz_Pem_InvalidKey => return error.Tlz_Context_InvalidKey,
    };
    const key_pair = Ed25519.KeyPair.generateDeterministic(seed) catch |err| switch (err) {
        else => return Error.Tlz_Context_InvalidKey,
    };

    return .{ .ed25519 = key_pair };
}

/// An RSA key signs CertificateVerify with rsa_pss_rsae_sha256, so it needs TLS 1.3.
fn rsaKey(key_der: []const u8, key_pem: []const u8) Error!SigningKey {
    const is_pkcs8 = std.mem.find(u8, key_pem, "BEGIN RSA PRIVATE KEY") == null;
    const key = RsaPrivateKey.fromDer(key_der, is_pkcs8) catch |err| switch (err) {
        error.Tlz_RsaPrivateKey_InvalidKey => return error.Tlz_Context_InvalidKey,
    };
    if (key.size() < RSA_MIN_MODULUS_LEN) return Error.Tlz_Context_RsaKeyTooSmall;

    return .{ .rsa = key };
}

/// Pick the signing key that matches the certificate key type.
fn signingKeyFor(
    cert_der: []const u8,
    key_der: []const u8,
    key_pem: []const u8,
) Error!SigningKey {
    const cert: std.crypto.Certificate = .{
        .buffer = cert_der,
        .index = 0,
    };
    if (!der_guard.isSafeCertificate(cert_der)) {
        return Error.Tlz_Context_CertificateMalformed;
    }

    const parsed = cert.parse() catch |err| switch (err) {
        else => return Error.Tlz_Context_CertificateMalformed,
    };

    return switch (parsed.pub_key_algo) {
        .X9_62_id_ecPublicKey => ecdsaKey(key_der),
        .curveEd25519 => ed25519Key(key_der),
        .rsaEncryption => rsaKey(key_der, key_pem),
        else => Error.Tlz_Context_UnsupportedCertificateKey,
    };
}

// --------------------------------------------------------- //
// Public:

/// The plain settings `init` reads.
pub const Config = @import("Config.zig");

pub const Error = error{
    Tlz_Context_NoCurves,
    Tlz_Context_NoCiphers,
    Tlz_Context_UnsupportedCurve,
    Tlz_Context_UnsupportedCipher,
    Tlz_Context_InvalidVersionRange,
    Tlz_Context_MissingCipherForVersion,
    Tlz_Context_MissingCurveForTls12,
    Tlz_Context_UnsupportedCertificateKey,
    Tlz_Context_CertificateMalformed,
    Tlz_Context_CertFileNotFound,
    Tlz_Context_CertFileTooLarge,
    Tlz_Context_CertFileUnreadable,
    Tlz_Context_CertPathIsDirectory,
    Tlz_Context_KeyFileNotFound,
    Tlz_Context_KeyFileTooLarge,
    Tlz_Context_KeyFileUnreadable,
    Tlz_Context_KeyPathIsDirectory,
    Tlz_Context_InvalidPem,
    Tlz_Context_PemTooLarge,
    Tlz_Context_InvalidKey,
    Tlz_Context_RsaKeyTooSmall,
    Tlz_Context_OutOfMemory,
};

/// Load the certificate and key, detect the key type, and check the policy.
///
/// Param:
/// allocator - std.mem.Allocator (owns the certificate DER copy)
/// io - std.Io (reads the PEM files)
/// config - Config (the settings, checked here)
///
/// Return:
/// - Self
/// - Error.Tlz_Context_NoCurves (and the other policy members) on a bad policy
/// - Error.Tlz_Context_CertFileNotFound or KeyFileNotFound when a path does not exist
/// - Error.Tlz_Context_CertFileUnreadable or KeyFileUnreadable when the read fails
/// - Error.Tlz_Context_CertPathIsDirectory or KeyPathIsDirectory for a directory
/// - Error.Tlz_Context_CertFileTooLarge or KeyFileTooLarge past 1 MiB
/// - Error.Tlz_Context_UnsupportedCertificateKey for another key type
pub fn init(allocator: std.mem.Allocator, io: std.Io, config: Config) Error!Self {
    config.validate() catch |err| return configError(err);

    const cert_pem = try readPem(allocator, io, config.cert_path, .CERT);
    defer allocator.free(cert_pem);

    var cert_der_buf: [DER_BUF]u8 = undefined;
    const cert_der_view = pem.pemToDer(&cert_der_buf, cert_pem) catch |err| {
        return decodeError(err);
    };
    const cert_der = allocator.dupe(u8, cert_der_view) catch |err| switch (err) {
        error.OutOfMemory => return Error.Tlz_Context_OutOfMemory,
    };
    errdefer allocator.free(cert_der);

    const key_pem = try readPem(allocator, io, config.key_path, .KEY);
    defer allocator.free(key_pem);

    var key_der_buf: [DER_BUF]u8 = undefined;
    const key_der = pem.pemToDer(&key_der_buf, key_pem) catch |err| return decodeError(err);
    const signing_key = try signingKeyFor(cert_der, key_der, key_pem);

    return .{
        .allocator = allocator,
        .cert_der = cert_der,
        .signing_key = signing_key,
        .alpn = config.alpn,
        .curves = config.curves,
        .ciphers = config.ciphers,
        .min_version = config.min_version,
        .max_version = config.max_version,
        .prefer_server_ciphers = config.prefer_server_ciphers,
        .hsts_max_age_s = config.hsts_max_age_s,
    };
}

/// Free the certificate DER.
///
/// Return:
/// - void
pub fn deinit(self: *Self) void {
    self.allocator.free(self.cert_der);
}

/// The per-connection handshake options: the context supplies the identity and
/// policy, the caller supplies fresh randoms.
///
/// Param:
/// ephemeral_secret - [32]u8 (the ECDHE private key)
/// server_random - [32]u8 (the ServerHello random)
/// pss_salt - [rsa.PSS_SALT_LEN]u8 (read only by an RSA key)
///
/// Return:
/// - HandshakeOptions
pub fn handshakeOptions(
    self: *const Self,
    ephemeral_secret: [32]u8,
    server_random: [32]u8,
    pss_salt: [rsa.PSS_SALT_LEN]u8,
) HandshakeOptions {
    return .{
        .certificate_der = self.cert_der,
        .signing_key = self.signing_key,
        .ephemeral_secret = ephemeral_secret,
        .server_random = server_random,
        .pss_salt = pss_salt,
        .alpn_prefs = self.alpn,
        .group_prefs = self.curves,
    };
}

/// The policy ceiling reaches TLS 1.3.
///
/// Return:
/// - bool
pub fn allowsTls13(self: *const Self) bool {
    return self.max_version == .TLS_1_3;
}

/// The policy floor is TLS 1.2.
///
/// Return:
/// - bool
pub fn allowsTls12(self: *const Self) bool {
    return self.min_version == .TLS_1_2;
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

/// Self-signed ECDSA P-256 CN=localhost, the key below signs it.
const EC_CERT_PEM =
    \\-----BEGIN CERTIFICATE-----
    \\MIIB1DCCAXugAwIBAgIUeibuSR8JGsfJFPSoEMHs5xNAJXQwCgYIKoZIzj0EAwIw
    \\KjESMBAGA1UEAwwJbG9jYWxob3N0MRQwEgYDVQQKDAt6aXgtdGxzLXBvYzAeFw0y
    \\NjA2MjIxMjU0MjBaFw0zNjA2MTkxMjU0MjBaMCoxEjAQBgNVBAMMCWxvY2FsaG9z
    \\dDEUMBIGA1UECgwLeml4LXRscy1wb2MwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNC
    \\AATCoBIbKYrJzTiSAOeNlOe94cx82AdHlfq0+Rl5nUD9wjHFqQmQrIxhZq5HLzP3
    \\T87Ql/Ltt7ihl0vmakqwfyU7o38wfTAdBgNVHQ4EFgQUw04dCjakOUdwm1OeFt0C
    \\E6pBlqowHwYDVR0jBBgwFoAUw04dCjakOUdwm1OeFt0CE6pBlqowDwYDVR0TAQH/
    \\BAUwAwEB/zAaBgNVHREEEzARgglsb2NhbGhvc3SHBH8AAAEwDgYDVR0PAQH/BAQD
    \\AgeAMAoGCCqGSM49BAMCA0cAMEQCIAsBLxGdubldmQvEgstj6PgeM3oIY0kE5Mr1
    \\E9wQyKqDAiAv3+ef9tVAPnU93yqlJnGSO4osKBJry/GWvW+37LyxTg==
    \\-----END CERTIFICATE-----
    \\
;

const EC_KEY_PEM =
    \\-----BEGIN EC PRIVATE KEY-----
    \\MHcCAQEEIAt29/HHv24gAp3bVmeV5Y2lumP/vbkUv2mb++0xR9MsoAoGCCqGSM49
    \\AwEHoUQDQgAEwqASGymKyc04kgDnjZTnveHMfNgHR5X6tPkZeZ1A/cIxxakJkKyM
    \\YWauRy8z90/O0Jfy7be4oZdL5mpKsH8lOw==
    \\-----END EC PRIVATE KEY-----
    \\
;

fn testContext() Self {
    return .{
        .allocator = std.testing.allocator,
        .cert_der = &.{},
        .signing_key = .{ .rsa = .{} },
        .alpn = &.{},
        .curves = Config.DEFAULT_CURVES,
        .ciphers = Config.DEFAULT_CIPHERS,
        .min_version = .TLS_1_2,
        .max_version = .TLS_1_3,
        .prefer_server_ciphers = true,
        .hsts_max_age_s = 0,
    };
}

/// Path of a file inside a testing tmp dir, relative to the working directory.
fn tmpPath(buf: []u8, tmp: *const std.testing.TmpDir, name: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, ".zig-cache/tmp/{s}/{s}", .{
        tmp.sub_path,
        name,
    });
}

test "tlz context: Context, default range allows both versions" {
    const ctx = testContext();

    try std.testing.expect(ctx.allowsTls12());
    try std.testing.expect(ctx.allowsTls13());
}

test "tlz context: Context, TLS 1.3 floor refuses TLS 1.2" {
    var ctx = testContext();
    ctx.min_version = .TLS_1_3;

    try std.testing.expect(!ctx.allowsTls12());
    try std.testing.expect(ctx.allowsTls13());
}

test "tlz context: Context, TLS 1.2 ceiling never takes TLS 1.3" {
    var ctx = testContext();
    ctx.max_version = .TLS_1_2;

    try std.testing.expect(ctx.allowsTls12());
    try std.testing.expect(!ctx.allowsTls13());
}

test "tlz context: Context, handshakeOptions carries the policy and randoms" {
    var ctx = testContext();
    ctx.alpn = &.{.H2};

    const opts = ctx.handshakeOptions(@splat(0x24), @splat(0x35), @splat(0x46));

    try std.testing.expectEqual(@as(u8, 0x24), opts.ephemeral_secret[0]);
    try std.testing.expectEqual(@as(u8, 0x35), opts.server_random[0]);
    try std.testing.expectEqual(@as(u8, 0x46), opts.pss_salt[0]);
    try std.testing.expectEqualSlices(Alpn, &.{.H2}, opts.alpn_prefs);
    try std.testing.expectEqualSlices(NamedGroup, Config.DEFAULT_CURVES, opts.group_prefs);
}

test "tlz context: Context, init with a bad policy fails before any read" {
    try std.testing.expectError(Error.Tlz_Context_NoCurves, init(
        std.testing.allocator,
        std.testing.io,
        .{
            .cert_path = "does-not-exist.pem",
            .key_path = "does-not-exist.pem",
            .curves = &.{},
        },
    ));
}

test "tlz context: Context, init with a missing certificate is not found" {
    try std.testing.expectError(Error.Tlz_Context_CertFileNotFound, init(
        std.testing.allocator,
        std.testing.io,
        .{
            .cert_path = "tlz-does-not-exist-cert.pem",
            .key_path = "tlz-does-not-exist-key.pem",
        },
    ));
}

test "tlz context: Context, init loads an ECDSA P-256 certificate and key" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "cert.pem",
        .data = EC_CERT_PEM,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "key.pem",
        .data = EC_KEY_PEM,
    });
    var cert_path_buf: [128]u8 = undefined;
    var key_path_buf: [128]u8 = undefined;

    var ctx = try init(std.testing.allocator, std.testing.io, .{
        .cert_path = try tmpPath(&cert_path_buf, &tmp, "cert.pem"),
        .key_path = try tmpPath(&key_path_buf, &tmp, "key.pem"),
    });
    defer ctx.deinit();

    try std.testing.expect(ctx.signing_key == .ecdsa_p256);
    try std.testing.expectEqual(@as(usize, 472), ctx.cert_der.len);
}

test "tlz context: Context, init with a missing key is not found" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "cert.pem",
        .data = EC_CERT_PEM,
    });
    var cert_path_buf: [128]u8 = undefined;

    try std.testing.expectError(Error.Tlz_Context_KeyFileNotFound, init(
        std.testing.allocator,
        std.testing.io,
        .{
            .cert_path = try tmpPath(&cert_path_buf, &tmp, "cert.pem"),
            .key_path = "tlz-does-not-exist-key.pem",
        },
    ));
}

test "tlz context: Context, init with a certificate that is not PEM is invalid" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "cert.pem",
        .data = "!!!! not base64 !!!!\n",
    });
    var cert_path_buf: [128]u8 = undefined;

    try std.testing.expectError(Error.Tlz_Context_InvalidPem, init(
        std.testing.allocator,
        std.testing.io,
        .{
            .cert_path = try tmpPath(&cert_path_buf, &tmp, "cert.pem"),
            .key_path = "unused.pem",
        },
    ));
}

