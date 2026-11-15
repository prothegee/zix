//! TLZ openssl Context
//!
//! ### file: src/tlz/src/openssl/Context.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Server-side OpenSSL context (`SSL_CTX`), built from the same `Config` as the native
//! `Context`: certificate, key, ALPN, and the version range.
//!
//! ### note:
//!
//! Only `cert_path`, `key_path`, `alpn`, `min_version`, and `max_version` apply here.
//! Curves and ciphers keep the OpenSSL defaults.
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
const c = @import("c.zig").raw;
const openssl_error = @import("error.zig");
const Connection = @import("Connection.zig");
const Config = @import("../context/Config.zig");
const Version = @import("../context/version.zig").Version;
const alpn = @import("../alpn.zig");

// --------------------------------------------------------- //
// Fields:

allocator: std.mem.Allocator,
/// The OpenSSL server context. Freed by `deinit`.
ctx: *c.SSL_CTX,
/// The server ALPN list read by the select callback: byte 0 is the list length, then
/// the ProtocolNameList body. Empty when no ALPN is configured.
alpn_list: []u8,

const Self = @This();

// --------------------------------------------------------- //
// Private:

/// Map a tlz version to the OpenSSL protocol version constant.
fn protoVersion(version: Version) c_long {
    return switch (version) {
        .TLS_1_2 => c.TLS1_2_VERSION,
        .TLS_1_3 => c.TLS1_3_VERSION,
    };
}

/// ALPN select callback (RFC 7301 3.2): pick the first server protocol the client also
/// offers. No overlap is a fatal no_application_protocol alert, like the native server.
fn selectAlpn(
    ssl: ?*c.SSL,
    out: [*c][*c]const u8,
    out_len: [*c]u8,
    client_list: [*c]const u8,
    client_len: c_uint,
    arg: ?*anyopaque,
) callconv(.c) c_int {
    _ = ssl;

    const server_list: [*]const u8 = @ptrCast(arg orelse return c.SSL_TLSEXT_ERR_NOACK);
    const rc = c.SSL_select_next_proto(
        @ptrCast(out),
        out_len,
        server_list + 1,
        server_list[0],
        client_list,
        client_len,
    );

    if (rc != c.OPENSSL_NPN_NEGOTIATED) return c.SSL_TLSEXT_ERR_ALERT_FATAL;

    return c.SSL_TLSEXT_ERR_OK;
}

/// Load the certificate chain and the key, then check they match.
fn loadCertAndKey(ctx: *c.SSL_CTX, config: Config) Error!void {
    const cert_path = std.posix.toPosixPath(config.cert_path) catch |err| switch (err) {
        error.NameTooLong => return Error.Tlz_OpensslContext_PathTooLong,
    };
    const key_path = std.posix.toPosixPath(config.key_path) catch |err| switch (err) {
        error.NameTooLong => return Error.Tlz_OpensslContext_PathTooLong,
    };

    openssl_error.clearQueue();
    if (c.SSL_CTX_use_certificate_chain_file(ctx, &cert_path) != 1) {
        openssl_error.clearQueue();
        return Error.Tlz_OpensslContext_CertLoadFailed;
    }

    if (c.SSL_CTX_use_PrivateKey_file(ctx, &key_path, c.SSL_FILETYPE_PEM) != 1) {
        const mismatch = openssl_error.drainMatch(c.ERR_LIB_X509, &.{
            c.X509_R_KEY_VALUES_MISMATCH,
        });
        if (mismatch) return Error.Tlz_OpensslContext_KeyMismatch;

        return Error.Tlz_OpensslContext_KeyLoadFailed;
    }

    if (c.SSL_CTX_check_private_key(ctx) != 1) {
        openssl_error.clearQueue();
        return Error.Tlz_OpensslContext_KeyMismatch;
    }
}

/// Set the protocol version range.
fn setVersions(ctx: *c.SSL_CTX, config: Config) Error!void {
    if (@intFromEnum(config.min_version) > @intFromEnum(config.max_version)) {
        return Error.Tlz_OpensslContext_InvalidVersionRange;
    }

    const min_ok = c.SSL_CTX_set_min_proto_version(ctx, protoVersion(config.min_version));
    const max_ok = c.SSL_CTX_set_max_proto_version(ctx, protoVersion(config.max_version));

    if (min_ok != 1 or max_ok != 1) return Error.Tlz_OpensslContext_VersionSetFailed;
}

/// Build the length prefixed server ALPN list the select callback reads.
fn buildAlpnList(allocator: std.mem.Allocator, prefs: []const alpn.Alpn) Error![]u8 {
    if (prefs.len == 0) return &.{};

    var body: [alpn.MAX_PROTOCOL_LIST_LEN]u8 = undefined;
    const list = alpn.encodeProtocolList(prefs, &body) orelse {
        return Error.Tlz_OpensslContext_AlpnTooLong;
    };

    const owned = allocator.alloc(u8, 1 + list.len) catch |err| switch (err) {
        error.OutOfMemory => return Error.Tlz_OpensslContext_OutOfMemory,
    };

    owned[0] = @intCast(list.len);
    @memcpy(owned[1..], list);

    return owned;
}

/// Map an error from `Connection` into this module's set.
fn connectionError(err: Connection.Error) Error {
    @branchHint(.cold);

    return switch (err) {
        error.Tlz_OpensslConnection_SslCreateFailed => Error.Tlz_OpensslContext_SslCreateFailed,
        error.Tlz_OpensslConnection_BioCreateFailed => Error.Tlz_OpensslContext_BioCreateFailed,
        error.Tlz_OpensslConnection_BioWriteFailed => Error.Tlz_OpensslContext_BioWriteFailed,
        error.Tlz_OpensslConnection_InputTooLarge => Error.Tlz_OpensslContext_InputTooLarge,
        error.Tlz_OpensslConnection_HandshakeFailed => Error.Tlz_OpensslContext_HandshakeFailed,
        error.Tlz_OpensslConnection_PeerVerifyFailed => {
            return Error.Tlz_OpensslContext_PeerVerifyFailed;
        },
        error.Tlz_OpensslConnection_NoProtocolNegotiated => {
            return Error.Tlz_OpensslContext_NoProtocolNegotiated;
        },
        error.Tlz_OpensslConnection_PeerClosed => Error.Tlz_OpensslContext_PeerClosed,
        error.Tlz_OpensslConnection_ReadFailed => Error.Tlz_OpensslContext_ReadFailed,
        error.Tlz_OpensslConnection_WriteFailed => Error.Tlz_OpensslContext_WriteFailed,
        error.Tlz_OpensslConnection_ShutdownFailed => Error.Tlz_OpensslContext_ShutdownFailed,
    };
}

// --------------------------------------------------------- //
// Public:

pub const Error = error{
    Tlz_OpensslContext_ContextCreateFailed,
    Tlz_OpensslContext_PathTooLong,
    Tlz_OpensslContext_CertLoadFailed,
    Tlz_OpensslContext_KeyLoadFailed,
    Tlz_OpensslContext_KeyMismatch,
    Tlz_OpensslContext_InvalidVersionRange,
    Tlz_OpensslContext_VersionSetFailed,
    Tlz_OpensslContext_AlpnTooLong,
    Tlz_OpensslContext_OutOfMemory,
    Tlz_OpensslContext_SslCreateFailed,
    Tlz_OpensslContext_BioCreateFailed,
    Tlz_OpensslContext_BioWriteFailed,
    Tlz_OpensslContext_InputTooLarge,
    Tlz_OpensslContext_HandshakeFailed,
    Tlz_OpensslContext_PeerVerifyFailed,
    Tlz_OpensslContext_NoProtocolNegotiated,
    Tlz_OpensslContext_PeerClosed,
    Tlz_OpensslContext_ReadFailed,
    Tlz_OpensslContext_WriteFailed,
    Tlz_OpensslContext_ShutdownFailed,
};

/// Build the server context: load the certificate and key, set the version range and
/// the ALPN preferences.
///
/// Param:
/// allocator - std.mem.Allocator (owns the ALPN list until `deinit`)
/// config - Config (the same config as the native `Context`)
///
/// Return:
/// - Self
/// - Error when a file cannot be loaded, the key does not match, or the policy is bad
pub fn init(allocator: std.mem.Allocator, config: Config) Error!Self {
    const ctx = c.SSL_CTX_new(c.TLS_server_method()) orelse {
        return Error.Tlz_OpensslContext_ContextCreateFailed;
    };
    errdefer c.SSL_CTX_free(ctx);

    try setVersions(ctx, config);
    try loadCertAndKey(ctx, config);

    const alpn_list = try buildAlpnList(allocator, config.alpn);
    errdefer allocator.free(alpn_list);

    if (alpn_list.len > 0) c.SSL_CTX_set_alpn_select_cb(ctx, selectAlpn, alpn_list.ptr);

    return .{
        .allocator = allocator,
        .ctx = ctx,
        .alpn_list = alpn_list,
    };
}

/// Free the OpenSSL context and the ALPN list.
///
/// Note:
/// - A `Connection` still alive keeps the `SSL_CTX` alive, but not the ALPN list.
///   Free every connection first.
pub fn deinit(self: *Self) void {
    c.SSL_CTX_free(self.ctx);
    self.allocator.free(self.alpn_list);
    self.* = undefined;
}

/// Start one server-side connection on this context.
///
/// Return:
/// - Connection
/// - Error when OpenSSL cannot allocate the connection
pub fn newConnection(self: *const Self) Error!Connection {
    return Connection.initServer(self.ctx) catch |err| connectionError(err);
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

/// A P-256 key that does not sign `EC_CERT_PEM`.
const OTHER_EC_KEY_PEM =
    \\-----BEGIN EC PRIVATE KEY-----
    \\MHcCAQEEII+Ip4AL2sNZZ4efLRKzU8UTxQYHVLUYKTnQcnW+PmsWoAoGCCqGSM49
    \\AwEHoUQDQgAEg2+E61adwgYEeai5r/Ehj9eI7ogoOMOjTNWiHaqRrjEFaQ776uWO
    \\dS2aqU1wWyAHLo0DjjU/Lc5rC0DpLUTq2A==
    \\-----END EC PRIVATE KEY-----
    \\
;

/// Path of a file inside a testing tmp dir, relative to the working directory.
fn tmpPath(buf: []u8, tmp: *const std.testing.TmpDir, name: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, ".zig-cache/tmp/{s}/{s}", .{
        tmp.sub_path,
        name,
    });
}

/// Write `cert_pem` and `key_pem` into `tmp` as cert.pem and key.pem.
fn writePair(tmp: *std.testing.TmpDir, cert_pem: []const u8, key_pem: []const u8) !void {
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "cert.pem",
        .data = cert_pem,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "key.pem",
        .data = key_pem,
    });
}

test "tlz openssl: Context, init loads an ECDSA P-256 certificate and key" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writePair(&tmp, EC_CERT_PEM, EC_KEY_PEM);
    var cert_buf: [256]u8 = undefined;
    var key_buf: [256]u8 = undefined;

    var context = try init(std.testing.allocator, .{
        .cert_path = try tmpPath(&cert_buf, &tmp, "cert.pem"),
        .key_path = try tmpPath(&key_buf, &tmp, "key.pem"),
    });
    defer context.deinit();

    try std.testing.expectEqual(@as(usize, 0), context.alpn_list.len);
}

test "tlz openssl: Context, init keeps the ALPN list length prefixed" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writePair(&tmp, EC_CERT_PEM, EC_KEY_PEM);
    var cert_buf: [256]u8 = undefined;
    var key_buf: [256]u8 = undefined;

    var context = try init(std.testing.allocator, .{
        .cert_path = try tmpPath(&cert_buf, &tmp, "cert.pem"),
        .key_path = try tmpPath(&key_buf, &tmp, "key.pem"),
        .alpn = &.{.H2},
    });
    defer context.deinit();

    try std.testing.expectEqualSlices(u8, "\x03\x02h2", context.alpn_list);
}

test "tlz openssl: Context, init with a missing certificate is CertLoadFailed" {
    try std.testing.expectError(
        Error.Tlz_OpensslContext_CertLoadFailed,
        init(std.testing.allocator, .{
            .cert_path = "tlz-openssl-does-not-exist-cert.pem",
            .key_path = "tlz-openssl-does-not-exist-key.pem",
        }),
    );
}

test "tlz openssl: Context, init with a certificate that is not PEM is CertLoadFailed" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writePair(&tmp, "not a certificate\n", EC_KEY_PEM);
    var cert_buf: [256]u8 = undefined;
    var key_buf: [256]u8 = undefined;

    try std.testing.expectError(
        Error.Tlz_OpensslContext_CertLoadFailed,
        init(std.testing.allocator, .{
            .cert_path = try tmpPath(&cert_buf, &tmp, "cert.pem"),
            .key_path = try tmpPath(&key_buf, &tmp, "key.pem"),
        }),
    );
}

test "tlz openssl: Context, init with a missing key is KeyLoadFailed" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writePair(&tmp, EC_CERT_PEM, EC_KEY_PEM);
    var cert_buf: [256]u8 = undefined;

    try std.testing.expectError(
        Error.Tlz_OpensslContext_KeyLoadFailed,
        init(std.testing.allocator, .{
            .cert_path = try tmpPath(&cert_buf, &tmp, "cert.pem"),
            .key_path = "tlz-openssl-does-not-exist-key.pem",
        }),
    );
}

test "tlz openssl: Context, init with a key of another certificate is KeyMismatch" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writePair(&tmp, EC_CERT_PEM, OTHER_EC_KEY_PEM);
    var cert_buf: [256]u8 = undefined;
    var key_buf: [256]u8 = undefined;

    try std.testing.expectError(
        Error.Tlz_OpensslContext_KeyMismatch,
        init(std.testing.allocator, .{
            .cert_path = try tmpPath(&cert_buf, &tmp, "cert.pem"),
            .key_path = try tmpPath(&key_buf, &tmp, "key.pem"),
        }),
    );
}

test "tlz openssl: Context, init with min above max is InvalidVersionRange" {
    try std.testing.expectError(
        Error.Tlz_OpensslContext_InvalidVersionRange,
        init(std.testing.allocator, .{
            .cert_path = "unused.pem",
            .key_path = "unused.pem",
            .min_version = .TLS_1_3,
            .max_version = .TLS_1_2,
        }),
    );
}

test "tlz openssl: Context, init with a path past PATH_MAX is PathTooLong" {
    const long_path: [std.posix.PATH_MAX + 1]u8 = @splat('a');

    try std.testing.expectError(
        Error.Tlz_OpensslContext_PathTooLong,
        init(std.testing.allocator, .{
            .cert_path = &long_path,
            .key_path = "unused.pem",
        }),
    );
}

test "tlz openssl: Context, init with a TLS 1.3 floor sets the OpenSSL minimum" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writePair(&tmp, EC_CERT_PEM, EC_KEY_PEM);
    var cert_buf: [256]u8 = undefined;
    var key_buf: [256]u8 = undefined;

    var context = try init(std.testing.allocator, .{
        .cert_path = try tmpPath(&cert_buf, &tmp, "cert.pem"),
        .key_path = try tmpPath(&key_buf, &tmp, "key.pem"),
        .min_version = .TLS_1_3,
    });
    defer context.deinit();

    try std.testing.expectEqual(
        @as(c_long, c.TLS1_3_VERSION),
        c.SSL_CTX_get_min_proto_version(context.ctx),
    );
}

test "tlz openssl: Context, newConnection starts a server connection" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writePair(&tmp, EC_CERT_PEM, EC_KEY_PEM);
    var cert_buf: [256]u8 = undefined;
    var key_buf: [256]u8 = undefined;
    var context = try init(std.testing.allocator, .{
        .cert_path = try tmpPath(&cert_buf, &tmp, "cert.pem"),
        .key_path = try tmpPath(&key_buf, &tmp, "key.pem"),
    });
    defer context.deinit();

    var conn = try context.newConnection();
    defer conn.deinit();

    try std.testing.expectEqual(@as(c_int, 1), c.SSL_is_server(conn.ssl));
}

