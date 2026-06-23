//! zix server-side TLS context (the loaded cert/key + validated policy, the SSL_CTX analog).
//!
//! Note:
//! - zix.Tls is sans-I/O and has no listener, so this is a CONTEXT, not a server: it holds the
//!   material the HTTP engine reads per connection, built once on the cold path. The HTTP server
//!   config attaches it by pointer (tls: ?*Tls.Context), mirroring the logger (logger: ?*Logger).
//! - Config is plain settings (what the user writes). Context is the live object (what the engine
//!   reads). init loads + validates ONCE, so the per-connection serve path sees a ready Context.
//! - Curves and ciphers are validated allow-lists: an unsupported value is a startup error, never a
//!   silent no-op. The implemented set widens as crypto lands, with no API change.

const std = @import("std");
const handshake = @import("handshake.zig");
const connection = @import("connection.zig");
const certificate = @import("certificate.zig");
const extensions = @import("extensions.zig");
const pem = @import("pem.zig");
const rsa = @import("rsa.zig");

const Alpn = extensions.Alpn;
const NamedGroup = handshake.NamedGroup;
const CipherSuite = handshake.CipherSuite;
const SigningKey = certificate.SigningKey;
const HandshakeOptions = connection.HandshakeOptions;
const EcdsaP256 = std.crypto.sign.ecdsa.EcdsaP256Sha256;
const Ed25519 = std.crypto.sign.Ed25519;

/// TLS version floor / ceiling for the bind policy. The valid range is TLS_1_2..TLS_1_3 (1.0 / 1.1
/// are deprecated by RFC 8996 and never offered). Values order numerically for min <= max checks.
pub const Version = enum(u8) {
    TLS_1_2 = 0x12,
    TLS_1_3 = 0x13,
};

/// The curves zix actually implements, server-preference order (X25519 first).
pub const default_curves = &[_]NamedGroup{ .X25519, .SECP256R1 };
/// The AEAD suites zix actually implements: AES-128-GCM for 1.3, ECDHE-ECDSA-AES128-GCM for 1.2.
pub const default_ciphers = &[_]CipherSuite{ .AES_128_GCM_SHA256, .ECDHE_ECDSA_AES128_GCM_SHA256 };

/// Server-side TLS configuration (the settings the user fills in). Plain POD, like Logger.Config.
/// Tls.Context.init reads + validates this ONCE on the cold path, then the engine reads the
/// resulting Context per connection. Omitting the optional fields yields the secure default
/// (forward secrecy + AEAD, ECDHE-only).
pub const Config = struct {
    /// PEM path to the end-entity certificate (ECDSA P-256 or Ed25519). Required.
    cert_path: []const u8,
    /// PEM path to the private key matching cert_path. Required.
    key_path: []const u8,

    /// ALPN protocols offered, in server-preference order. Empty = no ALPN.
    /// Http1: .{ .HTTP_1_1 }. Http2 over TLS: .{ .H2 } (optionally .{ .H2, .HTTP_1_1 }).
    alpn: []const Alpn = &.{},

    /// Version floor / ceiling (RFC 8446 / 5246). Valid range TLS_1_2..TLS_1_3.
    /// 1.0 / 1.1 are never offered (RFC 8996). Default = TLS 1.2 floor, 1.3 preferred.
    min_version: Version = .TLS_1_2,
    max_version: Version = .TLS_1_3,

    /// ECDHE curves in server-preference order. Validated at init: an unsupported value
    /// (P384, MLKEM768) returns error.TlsUnsupportedCurve, never a silent drop.
    curves: []const NamedGroup = default_curves,
    /// AEAD cipher suites in preference order, spanning 1.3 and 1.2. Same validate-or-reject
    /// contract: an unsupported value (AES_256, CHACHA20, any RSA suite) returns
    /// error.TlsUnsupportedCipher.
    ciphers: []const CipherSuite = default_ciphers,

    /// Honor server cipher order over the client's (nginx ssl_prefer_server_ciphers).
    /// Note: with the current single-suite-per-version set the selection is identical either way.
    prefer_server_ciphers: bool = true,

    /// HSTS max-age in SECONDS (RFC 6797). 0 = off. Enables the Strict-Transport-Security header,
    /// the recommended hardening for https. Lives here because it only has meaning over TLS.
    hsts_max_age_s: u32 = 0,
};

/// Errors init can raise from the policy (beyond the I/O / parse errors of loading the PEM files).
pub const ConfigError = error{
    TlsNoCurves,
    TlsNoCiphers,
    TlsUnsupportedCurve,
    TlsUnsupportedCipher,
    TlsInvalidVersionRange,
    TlsMissingCipherForVersion,
    TlsMissingCurveForTls12,
    UnsupportedCertificateKey,
};

/// The live context: the loaded certificate + signing key and the validated policy the engine
/// reads per connection. Build with init, release with deinit. Attach by pointer to the HTTP
/// server config (tls: ?*Tls.Context).
pub const Context = struct {
    allocator: std.mem.Allocator,
    /// DER end-entity certificate, owned (freed by deinit).
    cert_der: []u8,
    /// The signing identity matching the certificate's key type (ECDSA P-256 or Ed25519).
    signing_key: SigningKey,
    alpn: []const Alpn,
    curves: []const NamedGroup,
    ciphers: []const CipherSuite,
    min_version: Version,
    max_version: Version,
    prefer_server_ciphers: bool,
    hsts_max_age_s: u32,

    /// Load the cert + key, detect the key type, and validate the policy. Cold path, called once at
    /// startup. The slices in config (alpn / curves / ciphers) are borrowed, so they must outlive
    /// the Context (a string literal or the zixer parser's arena, both outlive it).
    ///
    /// Param:
    /// allocator - std.mem.Allocator (owns the duplicated cert DER)
    /// io - std.Io (reads the PEM files)
    /// config - Config (the settings, validated here)
    ///
    /// Return:
    /// - Context
    /// - ConfigError on an unhonorable policy, or the PEM read / parse errors
    pub fn init(allocator: std.mem.Allocator, io: std.Io, config: Config) !Context {
        try validate(config);

        const cert_pem = try std.Io.Dir.cwd().readFileAlloc(io, config.cert_path, allocator, .limited(1 << 20));
        defer allocator.free(cert_pem);
        var cert_der_buf: [4096]u8 = undefined;
        const cert_der_view = try pem.pemToDer(&cert_der_buf, cert_pem);

        const cert_der = try allocator.dupe(u8, cert_der_view);
        errdefer allocator.free(cert_der);

        const key_pem = try std.Io.Dir.cwd().readFileAlloc(io, config.key_path, allocator, .limited(1 << 20));
        defer allocator.free(key_pem);
        var key_der_buf: [4096]u8 = undefined; // RSA PKCS#8 DER is far larger than an EC key
        const key_der = try pem.pemToDer(&key_der_buf, key_pem);

        // The signing key matches the certificate's key type: ECDSA P-256 (SEC1), Ed25519 (PKCS#8),
        // or RSA (PKCS#1 or PKCS#8). An RSA key signs CertificateVerify with rsa_pss_rsae_sha256, so
        // it requires TLS 1.3 (the 1.2 ServerKeyExchange path is ECDSA-only).
        const cert_parsed = try (std.crypto.Certificate{ .buffer = cert_der, .index = 0 }).parse();
        const signing_key: SigningKey = switch (cert_parsed.pub_key_algo) {
            .X9_62_id_ecPublicKey => .{ .ecdsa_p256 = try EcdsaP256.KeyPair.fromSecretKey(try EcdsaP256.SecretKey.fromBytes(try pem.ecdsaScalarFromSec1(key_der))) },
            .curveEd25519 => .{ .ed25519 = try Ed25519.KeyPair.generateDeterministic(try pem.ed25519SeedFromPkcs8(key_der)) },
            .rsaEncryption => blk: {
                const is_pkcs8 = std.mem.indexOf(u8, key_pem, "BEGIN RSA PRIVATE KEY") == null;
                const key = try rsa.PrivateKey.fromDer(key_der, is_pkcs8);
                if (key.size() < 256) return error.RsaKeyTooSmall; // RSA-2048 minimum

                break :blk .{ .rsa = key };
            },
            else => return error.UnsupportedCertificateKey,
        };

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

    pub fn deinit(self: *Context) void {
        self.allocator.free(self.cert_der);
    }

    /// Build the per-connection handshake options from the context plus the freshly generated
    /// ephemeral secret + server random + PSS salt. The serve path supplies the randoms (they differ
    /// per connection), the context supplies the cert / key / alpn / curve policy. The salt is only
    /// consumed by an RSA signing key, the ECDSA / Ed25519 paths ignore it.
    pub fn handshakeOptions(self: *const Context, ephemeral_secret: [32]u8, server_random: [32]u8, pss_salt: [rsa.pss_salt_len]u8) HandshakeOptions {
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

    /// Whether the TLS 1.3 path is offered under this policy (ceiling reaches 1.3).
    pub fn allowsTls13(self: *const Context) bool {
        return self.max_version == .TLS_1_3;
    }

    /// Whether the TLS 1.2 path is offered under this policy (floor is 1.2).
    pub fn allowsTls12(self: *const Context) bool {
        return self.min_version == .TLS_1_2;
    }
};

/// I/O-free policy validation (the honesty boundary). Rejects any curve / cipher the engine cannot
/// honor and any version range it cannot serve, so a configured field is never silently ignored.
pub fn validate(config: Config) ConfigError!void {
    if (config.curves.len == 0) return error.TlsNoCurves;
    if (config.ciphers.len == 0) return error.TlsNoCiphers;

    for (config.curves) |curve| {
        if (!isImplementedCurve(curve)) return error.TlsUnsupportedCurve;
    }
    for (config.ciphers) |cipher| {
        if (!isImplementedCipher(cipher)) return error.TlsUnsupportedCipher;
    }

    if (@intFromEnum(config.min_version) > @intFromEnum(config.max_version)) return error.TlsInvalidVersionRange;

    // Each offered version needs its suite (and 1.2 ECDHE needs secp256r1) present in the lists.
    if (config.max_version == .TLS_1_3 and !contains(CipherSuite, config.ciphers, .AES_128_GCM_SHA256)) {
        return error.TlsMissingCipherForVersion;
    }
    if (config.min_version == .TLS_1_2) {
        if (!contains(CipherSuite, config.ciphers, .ECDHE_ECDSA_AES128_GCM_SHA256)) return error.TlsMissingCipherForVersion;
        if (!contains(NamedGroup, config.curves, .SECP256R1)) return error.TlsMissingCurveForTls12;
    }
}

fn isImplementedCurve(curve: NamedGroup) bool {
    return curve == .X25519 or curve == .SECP256R1;
}

fn isImplementedCipher(cipher: CipherSuite) bool {
    return cipher == .AES_128_GCM_SHA256 or cipher == .ECDHE_ECDSA_AES128_GCM_SHA256;
}

fn contains(comptime T: type, list: []const T, value: T) bool {
    for (list) |item| {
        if (item == value) return true;
    }

    return false;
}

// --------------------------------------------------------------- //
// --------------------------------------------------------------- //

test "zix test: tls context, default config validates" {
    try validate(.{ .cert_path = "c", .key_path = "k" });
}

test "zix test: tls context, unsupported curve is rejected" {
    try std.testing.expectError(error.TlsUnsupportedCurve, validate(.{
        .cert_path = "c",
        .key_path = "k",
        .curves = &.{ .X25519, @enumFromInt(0x4588) }, // a curve zix does not implement (e.g. MLKEM768)
    }));
}

test "zix test: tls context, unsupported cipher is rejected" {
    try std.testing.expectError(error.TlsUnsupportedCipher, validate(.{
        .cert_path = "c",
        .key_path = "k",
        .ciphers = &.{ .AES_128_GCM_SHA256, .CHACHA20_POLY1305_SHA256, .ECDHE_ECDSA_AES128_GCM_SHA256 },
    }));
}

test "zix test: tls context, empty curves / ciphers rejected" {
    try std.testing.expectError(error.TlsNoCurves, validate(.{ .cert_path = "c", .key_path = "k", .curves = &.{} }));
    try std.testing.expectError(error.TlsNoCiphers, validate(.{ .cert_path = "c", .key_path = "k", .ciphers = &.{} }));
}

test "zix test: tls context, inverted version range rejected" {
    try std.testing.expectError(error.TlsInvalidVersionRange, validate(.{
        .cert_path = "c",
        .key_path = "k",
        .min_version = .TLS_1_3,
        .max_version = .TLS_1_2,
    }));
}

test "zix test: tls context, version requires its suite present" {
    // 1.3-only policy missing the 1.3 suite.
    try std.testing.expectError(error.TlsMissingCipherForVersion, validate(.{
        .cert_path = "c",
        .key_path = "k",
        .min_version = .TLS_1_3,
        .max_version = .TLS_1_3,
        .ciphers = &.{.ECDHE_ECDSA_AES128_GCM_SHA256},
    }));

    // 1.2 floor without secp256r1 (1.2 ECDHE needs it).
    try std.testing.expectError(error.TlsMissingCurveForTls12, validate(.{
        .cert_path = "c",
        .key_path = "k",
        .curves = &.{.X25519},
    }));
}

test "zix test: tls context, single-version policies validate" {
    // 1.3 only.
    try validate(.{
        .cert_path = "c",
        .key_path = "k",
        .min_version = .TLS_1_3,
        .max_version = .TLS_1_3,
        .ciphers = &.{.AES_128_GCM_SHA256},
        .curves = &.{.X25519},
    });

    // 1.2 only.
    try validate(.{
        .cert_path = "c",
        .key_path = "k",
        .min_version = .TLS_1_2,
        .max_version = .TLS_1_2,
        .ciphers = &.{.ECDHE_ECDSA_AES128_GCM_SHA256},
        .curves = &.{.SECP256R1},
    });
}

test "zix test: tls context, version range gates the serve path" {
    // A Context built directly (no I/O) to test the pure allowsTls12 / allowsTls13 helpers that the
    // serve path uses to force the 1.2 path (ceiling 1.2) or refuse a 1.2 client (floor 1.3).
    const base = Context{
        .allocator = std.testing.allocator,
        .cert_der = &.{},
        .signing_key = undefined,
        .alpn = &.{},
        .curves = default_curves,
        .ciphers = default_ciphers,
        .min_version = .TLS_1_2,
        .max_version = .TLS_1_3,
        .prefer_server_ciphers = true,
        .hsts_max_age_s = 0,
    };

    // both versions (default): 1.2 and 1.3 paths both allowed.
    try std.testing.expect(base.allowsTls12());
    try std.testing.expect(base.allowsTls13());

    // floor 1.3: the serve path refuses a 1.2-only client.
    var floor_13 = base;
    floor_13.min_version = .TLS_1_3;
    try std.testing.expect(!floor_13.allowsTls12());
    try std.testing.expect(floor_13.allowsTls13());

    // ceiling 1.2: the serve path never takes the 1.3 path.
    var ceil_12 = base;
    ceil_12.max_version = .TLS_1_2;
    try std.testing.expect(ceil_12.allowsTls12());
    try std.testing.expect(!ceil_12.allowsTls13());
}
