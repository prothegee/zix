//! TLZ openssl client
//!
//! ### file: src/tlz/src/openssl/client.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Start a client-side OpenSSL connection that verifies the server chain against a CA
//! file and checks the server name, then runs over the byte-driven `Connection`.
//!
//! ### note:
//!
//! `host` is a DNS name: it is sent as SNI and checked against the certificate. An
//! empty host is refused, because OpenSSL would then skip the name check.
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
const alpn = @import("../alpn.zig");

// --------------------------------------------------------- //
// Private:

/// The longest DNS name (RFC 1035 2.3.4), as text without the trailing dot.
const MAX_HOST_LEN: usize = 253;

/// Build the client context: TLS 1.2 floor, peer verification, and the CA file.
fn newContext(ca_path: []const u8) Error!*c.SSL_CTX {
    const ca_path_z = std.posix.toPosixPath(ca_path) catch |err| switch (err) {
        error.NameTooLong => return Error.Tlz_OpensslClient_PathTooLong,
    };

    const ctx = c.SSL_CTX_new(c.TLS_client_method()) orelse {
        return Error.Tlz_OpensslClient_ContextCreateFailed;
    };
    errdefer c.SSL_CTX_free(ctx);

    if (c.SSL_CTX_set_min_proto_version(ctx, c.TLS1_2_VERSION) != 1) {
        return Error.Tlz_OpensslClient_VersionSetFailed;
    }

    c.SSL_CTX_set_verify(ctx, c.SSL_VERIFY_PEER, null);

    openssl_error.clearQueue();
    if (c.SSL_CTX_load_verify_file(ctx, &ca_path_z) != 1) {
        openssl_error.clearQueue();
        return Error.Tlz_OpensslClient_CaLoadFailed;
    }

    return ctx;
}

/// Set SNI and the name the certificate must match.
fn setHost(conn: *Connection, host: []const u8) Error!void {
    if (host.len == 0) return Error.Tlz_OpensslClient_HostMissing;
    if (host.len > MAX_HOST_LEN) return Error.Tlz_OpensslClient_HostTooLong;

    var host_z: [MAX_HOST_LEN:0]u8 = @splat(0);
    @memcpy(host_z[0..host.len], host);

    const sni_ok = c.SSL_set_tlsext_host_name(conn.ssl, &host_z) == 1;
    const name_ok = c.SSL_set1_host(conn.ssl, &host_z) == 1;

    if (!sni_ok or !name_ok) {
        openssl_error.clearQueue();
        return Error.Tlz_OpensslClient_HostSetFailed;
    }
}

/// Offer the ALPN protocols, in preference order.
fn setAlpn(conn: *Connection, prefs: []const alpn.Alpn) Error!void {
    if (prefs.len == 0) return;

    var body: [alpn.MAX_PROTOCOL_LIST_LEN]u8 = undefined;
    const list = alpn.encodeProtocolList(prefs, &body) orelse {
        return Error.Tlz_OpensslClient_AlpnTooLong;
    };

    // SSL_set_alpn_protos returns 0 on success, unlike most OpenSSL calls.
    if (c.SSL_set_alpn_protos(conn.ssl, list.ptr, @intCast(list.len)) != 0) {
        return Error.Tlz_OpensslClient_AlpnSetFailed;
    }
}

/// Map an error from `Connection` into this module's set.
fn connectionError(err: Connection.Error) Error {
    @branchHint(.cold);

    return switch (err) {
        error.Tlz_OpensslConnection_SslCreateFailed => Error.Tlz_OpensslClient_SslCreateFailed,
        error.Tlz_OpensslConnection_BioCreateFailed => Error.Tlz_OpensslClient_BioCreateFailed,
        error.Tlz_OpensslConnection_BioWriteFailed => Error.Tlz_OpensslClient_BioWriteFailed,
        error.Tlz_OpensslConnection_InputTooLarge => Error.Tlz_OpensslClient_InputTooLarge,
        error.Tlz_OpensslConnection_HandshakeFailed => Error.Tlz_OpensslClient_HandshakeFailed,
        error.Tlz_OpensslConnection_PeerVerifyFailed => Error.Tlz_OpensslClient_PeerVerifyFailed,
        error.Tlz_OpensslConnection_NoProtocolNegotiated => {
            return Error.Tlz_OpensslClient_NoProtocolNegotiated;
        },
        error.Tlz_OpensslConnection_PeerClosed => Error.Tlz_OpensslClient_PeerClosed,
        error.Tlz_OpensslConnection_ReadFailed => Error.Tlz_OpensslClient_ReadFailed,
        error.Tlz_OpensslConnection_WriteFailed => Error.Tlz_OpensslClient_WriteFailed,
        error.Tlz_OpensslConnection_ShutdownFailed => Error.Tlz_OpensslClient_ShutdownFailed,
    };
}

// --------------------------------------------------------- //
// Public:

pub const Error = error{
    Tlz_OpensslClient_ContextCreateFailed,
    Tlz_OpensslClient_PathTooLong,
    Tlz_OpensslClient_CaLoadFailed,
    Tlz_OpensslClient_VersionSetFailed,
    Tlz_OpensslClient_HostMissing,
    Tlz_OpensslClient_HostTooLong,
    Tlz_OpensslClient_HostSetFailed,
    Tlz_OpensslClient_AlpnTooLong,
    Tlz_OpensslClient_AlpnSetFailed,
    Tlz_OpensslClient_SslCreateFailed,
    Tlz_OpensslClient_BioCreateFailed,
    Tlz_OpensslClient_BioWriteFailed,
    Tlz_OpensslClient_InputTooLarge,
    Tlz_OpensslClient_HandshakeFailed,
    Tlz_OpensslClient_PeerVerifyFailed,
    Tlz_OpensslClient_NoProtocolNegotiated,
    Tlz_OpensslClient_PeerClosed,
    Tlz_OpensslClient_ReadFailed,
    Tlz_OpensslClient_WriteFailed,
    Tlz_OpensslClient_ShutdownFailed,
};

/// Start one client connection that verifies the server chain and name.
///
/// Note:
/// - The first `handshake(&.{}, out)` on the result writes the ClientHello.
/// - A chain or name failure surfaces from `handshake` as `PeerVerifyFailed`.
///
/// Param:
/// ca_path - []const u8 (PEM file with the trust anchors for the server chain)
/// host - []const u8 (the server DNS name, sent as SNI and checked in the certificate)
/// alpn_prefs - []const alpn.Alpn (the protocols to offer, empty means no ALPN)
///
/// Usage:
/// ```zig
/// var conn = try client.connect("ca.pem", "example.com", &.{.H2});
/// defer conn.deinit();
///
/// const hello = try conn.handshake(&.{}, &out);
/// // send hello, read the server flight into `flight`, then:
/// const finished = try conn.handshake(flight, &out);
/// ```
///
/// Return:
/// - Connection (not yet handshaken)
/// - Error when the CA file, the host, or the ALPN list cannot be set
pub fn connect(
    ca_path: []const u8,
    host: []const u8,
    alpn_prefs: []const alpn.Alpn,
) Error!Connection {
    const ctx = try newContext(ca_path);
    // The connection holds its own reference to the context.
    defer c.SSL_CTX_free(ctx);

    var conn = Connection.initClient(ctx) catch |err| return connectionError(err);
    errdefer conn.deinit();

    try setHost(&conn, host);
    try setAlpn(&conn, alpn_prefs);

    return conn;
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const Context = @import("Context.zig");

/// Self-signed ECDSA P-256 CN=localhost, SAN localhost and 127.0.0.1.
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

/// Self-signed CN=other-ca, unrelated to `EC_CERT_PEM`.
const OTHER_CA_PEM =
    \\-----BEGIN CERTIFICATE-----
    \\MIIBezCCASGgAwIBAgIUTaYJ1qhPgdTIR47E2VriXitEadMwCgYIKoZIzj0EAwIw
    \\EzERMA8GA1UEAwwIb3RoZXItY2EwHhcNMjYxMTE1MDg1ODU3WhcNMzYxMTEyMDg1
    \\ODU3WjATMREwDwYDVQQDDAhvdGhlci1jYTBZMBMGByqGSM49AgEGCCqGSM49AwEH
    \\A0IABDtcl5ftA5Ne9jeR2O8/OZ9wmnbolm09uL7ZRVUFTowmrFudAgb/ML43MYby
    \\f8Owsv9igJDVHduvNBuj3ld0QEqjUzBRMB0GA1UdDgQWBBSbhcQaSw9NacVBZEz5
    \\PrGFtsi1WjAfBgNVHSMEGDAWgBSbhcQaSw9NacVBZEz5PrGFtsi1WjAPBgNVHRMB
    \\Af8EBTADAQH/MAoGCCqGSM49BAMCA0gAMEUCIQDrF84d+nLMBLhpSCKhpX45NPwI
    \\piwXwXc0pU4mWJkC7wIgDj21v+lrR31yh8/cQpW2Q7Kf7dcgMzVDZIeCR8iptHo=
    \\-----END CERTIFICATE-----
    \\
;

/// Handshake rounds before a loopback is called stuck.
const MAX_ROUNDS: usize = 8;

/// Paths of the files `Fixture` writes, inside the testing tmp dir.
const Fixture = struct {
    tmp: std.testing.TmpDir,
    cert_buf: [256]u8 = undefined,
    key_buf: [256]u8 = undefined,
    other_ca_buf: [256]u8 = undefined,

    fn init() !Fixture {
        var fixture: Fixture = .{
            .tmp = std.testing.tmpDir(.{}),
        };
        errdefer fixture.tmp.cleanup();

        try fixture.write("cert.pem", EC_CERT_PEM);
        try fixture.write("key.pem", EC_KEY_PEM);
        try fixture.write("other_ca.pem", OTHER_CA_PEM);

        return fixture;
    }

    fn deinit(self: *Fixture) void {
        self.tmp.cleanup();
    }

    fn write(self: *Fixture, name: []const u8, data: []const u8) !void {
        try self.tmp.dir.writeFile(std.testing.io, .{
            .sub_path = name,
            .data = data,
        });
    }

    fn path(self: *const Fixture, buf: []u8, name: []const u8) ![]const u8 {
        return std.fmt.bufPrint(buf, ".zig-cache/tmp/{s}/{s}", .{
            self.tmp.sub_path,
            name,
        });
    }

    fn certPath(self: *Fixture) ![]const u8 {
        return self.path(&self.cert_buf, "cert.pem");
    }

    fn keyPath(self: *Fixture) ![]const u8 {
        return self.path(&self.key_buf, "key.pem");
    }

    fn otherCaPath(self: *Fixture) ![]const u8 {
        return self.path(&self.other_ca_buf, "other_ca.pem");
    }
};

/// Move handshake bytes between both ends until both are done.
fn runHandshake(client_conn: *Connection, server_conn: *Connection) !void {
    var client_buf: [16 * 1024]u8 = undefined;
    var server_buf: [16 * 1024]u8 = undefined;

    var client_out = try client_conn.handshake(&.{}, &client_buf);

    for (0..MAX_ROUNDS) |_| {
        const server_out = try server_conn.handshake(client_out, &server_buf);
        client_out = try client_conn.handshake(server_out, &client_buf);

        if (client_conn.handshakeDone() and server_conn.handshakeDone()) return;
    }

    return error.TestUnexpectedResult;
}

test "tlz openssl: client, handshake with a trusted server completes" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var context = try Context.init(std.testing.allocator, .{
        .cert_path = try fixture.certPath(),
        .key_path = try fixture.keyPath(),
    });
    defer context.deinit();
    var server_conn = try context.newConnection();
    defer server_conn.deinit();
    var client_conn = try connect(try fixture.certPath(), "localhost", &.{});
    defer client_conn.deinit();

    try runHandshake(&client_conn, &server_conn);

    try std.testing.expect(client_conn.handshakeDone());
}

test "tlz openssl: client, default range negotiates TLS 1.3" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var context = try Context.init(std.testing.allocator, .{
        .cert_path = try fixture.certPath(),
        .key_path = try fixture.keyPath(),
    });
    defer context.deinit();
    var server_conn = try context.newConnection();
    defer server_conn.deinit();
    var client_conn = try connect(try fixture.certPath(), "localhost", &.{});
    defer client_conn.deinit();

    try runHandshake(&client_conn, &server_conn);

    try std.testing.expectEqual(@as(c_int, c.TLS1_3_VERSION), c.SSL_version(client_conn.ssl));
}

test "tlz openssl: client, server with a TLS 1.2 ceiling negotiates TLS 1.2" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var context = try Context.init(std.testing.allocator, .{
        .cert_path = try fixture.certPath(),
        .key_path = try fixture.keyPath(),
        .max_version = .TLS_1_2,
    });
    defer context.deinit();
    var server_conn = try context.newConnection();
    defer server_conn.deinit();
    var client_conn = try connect(try fixture.certPath(), "localhost", &.{});
    defer client_conn.deinit();

    try runHandshake(&client_conn, &server_conn);

    try std.testing.expectEqual(@as(c_int, c.TLS1_2_VERSION), c.SSL_version(client_conn.ssl));
}

test "tlz openssl: client, application data reaches the server" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var context = try Context.init(std.testing.allocator, .{
        .cert_path = try fixture.certPath(),
        .key_path = try fixture.keyPath(),
    });
    defer context.deinit();
    var server_conn = try context.newConnection();
    defer server_conn.deinit();
    var client_conn = try connect(try fixture.certPath(), "localhost", &.{});
    defer client_conn.deinit();
    try runHandshake(&client_conn, &server_conn);
    var wire: [4096]u8 = undefined;
    var plain: [4096]u8 = undefined;

    const records = try client_conn.writeAppData("ping", &wire);
    const received = try server_conn.readAppData(records, &plain);

    try std.testing.expectEqualStrings("ping", received);
}

test "tlz openssl: client, application data reaches the client" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var context = try Context.init(std.testing.allocator, .{
        .cert_path = try fixture.certPath(),
        .key_path = try fixture.keyPath(),
    });
    defer context.deinit();
    var server_conn = try context.newConnection();
    defer server_conn.deinit();
    var client_conn = try connect(try fixture.certPath(), "localhost", &.{});
    defer client_conn.deinit();
    try runHandshake(&client_conn, &server_conn);
    var wire: [4096]u8 = undefined;
    var plain: [4096]u8 = undefined;

    const records = try server_conn.writeAppData("pong", &wire);
    const received = try client_conn.readAppData(records, &plain);

    try std.testing.expectEqualStrings("pong", received);
}

test "tlz openssl: client, half a record reads as empty" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var context = try Context.init(std.testing.allocator, .{
        .cert_path = try fixture.certPath(),
        .key_path = try fixture.keyPath(),
    });
    defer context.deinit();
    var server_conn = try context.newConnection();
    defer server_conn.deinit();
    var client_conn = try connect(try fixture.certPath(), "localhost", &.{});
    defer client_conn.deinit();
    try runHandshake(&client_conn, &server_conn);
    var wire: [4096]u8 = undefined;
    var plain: [4096]u8 = undefined;

    const records = try client_conn.writeAppData("ping", &wire);
    const half = records.len / 2;

    try std.testing.expectEqual(@as(usize, 0), (try server_conn.readAppData(
        records[0..half],
        &plain,
    )).len);
    try std.testing.expectEqualStrings("ping", try server_conn.readAppData(
        records[half..],
        &plain,
    ));
}

test "tlz openssl: client, close_notify reads as PeerClosed" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var context = try Context.init(std.testing.allocator, .{
        .cert_path = try fixture.certPath(),
        .key_path = try fixture.keyPath(),
    });
    defer context.deinit();
    var server_conn = try context.newConnection();
    defer server_conn.deinit();
    var client_conn = try connect(try fixture.certPath(), "localhost", &.{});
    defer client_conn.deinit();
    try runHandshake(&client_conn, &server_conn);
    var wire: [4096]u8 = undefined;
    var plain: [4096]u8 = undefined;

    const alert = try client_conn.closeNotify(&wire);

    try std.testing.expectError(
        Connection.Error.Tlz_OpensslConnection_PeerClosed,
        server_conn.readAppData(alert, &plain),
    );
}

test "tlz openssl: client, both sides offering h2 negotiate h2" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var context = try Context.init(std.testing.allocator, .{
        .cert_path = try fixture.certPath(),
        .key_path = try fixture.keyPath(),
        .alpn = &.{ .H2, .HTTP_1_1 },
    });
    defer context.deinit();
    var server_conn = try context.newConnection();
    defer server_conn.deinit();
    var client_conn = try connect(try fixture.certPath(), "localhost", &.{ .HTTP_1_1, .H2 });
    defer client_conn.deinit();

    try runHandshake(&client_conn, &server_conn);

    try std.testing.expectEqual(alpn.Alpn.H2, client_conn.selectedAlpn().?);
}

test "tlz openssl: client, server ALPN order wins over the client order" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var context = try Context.init(std.testing.allocator, .{
        .cert_path = try fixture.certPath(),
        .key_path = try fixture.keyPath(),
        .alpn = &.{ .HTTP_1_1, .H2 },
    });
    defer context.deinit();
    var server_conn = try context.newConnection();
    defer server_conn.deinit();
    var client_conn = try connect(try fixture.certPath(), "localhost", &.{ .H2, .HTTP_1_1 });
    defer client_conn.deinit();

    try runHandshake(&client_conn, &server_conn);

    try std.testing.expectEqual(alpn.Alpn.HTTP_1_1, server_conn.selectedAlpn().?);
}

test "tlz openssl: client, without a client ALPN offer selects none" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var context = try Context.init(std.testing.allocator, .{
        .cert_path = try fixture.certPath(),
        .key_path = try fixture.keyPath(),
        .alpn = &.{.H2},
    });
    defer context.deinit();
    var server_conn = try context.newConnection();
    defer server_conn.deinit();
    var client_conn = try connect(try fixture.certPath(), "localhost", &.{});
    defer client_conn.deinit();

    try runHandshake(&client_conn, &server_conn);

    try std.testing.expect(server_conn.selectedAlpn() == null);
}

test "tlz openssl: client, ALPN with no overlap is NoProtocolNegotiated" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var context = try Context.init(std.testing.allocator, .{
        .cert_path = try fixture.certPath(),
        .key_path = try fixture.keyPath(),
        .alpn = &.{.H2},
    });
    defer context.deinit();
    var server_conn = try context.newConnection();
    defer server_conn.deinit();
    var client_conn = try connect(try fixture.certPath(), "localhost", &.{.HTTP_1_1});
    defer client_conn.deinit();

    try std.testing.expectError(
        Connection.Error.Tlz_OpensslConnection_NoProtocolNegotiated,
        runHandshake(&client_conn, &server_conn),
    );
}

test "tlz openssl: client, hostname mismatch is PeerVerifyFailed" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var context = try Context.init(std.testing.allocator, .{
        .cert_path = try fixture.certPath(),
        .key_path = try fixture.keyPath(),
    });
    defer context.deinit();
    var server_conn = try context.newConnection();
    defer server_conn.deinit();
    var client_conn = try connect(try fixture.certPath(), "example.com", &.{});
    defer client_conn.deinit();

    try std.testing.expectError(
        Connection.Error.Tlz_OpensslConnection_PeerVerifyFailed,
        runHandshake(&client_conn, &server_conn),
    );
}

test "tlz openssl: client, untrusted chain is PeerVerifyFailed" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var context = try Context.init(std.testing.allocator, .{
        .cert_path = try fixture.certPath(),
        .key_path = try fixture.keyPath(),
    });
    defer context.deinit();
    var server_conn = try context.newConnection();
    defer server_conn.deinit();
    var client_conn = try connect(try fixture.otherCaPath(), "localhost", &.{});
    defer client_conn.deinit();

    try std.testing.expectError(
        Connection.Error.Tlz_OpensslConnection_PeerVerifyFailed,
        runHandshake(&client_conn, &server_conn),
    );
}

test "tlz openssl: client, failed verify queues an alert for the server" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var context = try Context.init(std.testing.allocator, .{
        .cert_path = try fixture.certPath(),
        .key_path = try fixture.keyPath(),
    });
    defer context.deinit();
    var server_conn = try context.newConnection();
    defer server_conn.deinit();
    var client_conn = try connect(try fixture.certPath(), "example.com", &.{});
    defer client_conn.deinit();
    var out: [4096]u8 = undefined;

    runHandshake(&client_conn, &server_conn) catch |err| {
        try std.testing.expectEqual(
            Connection.Error.Tlz_OpensslConnection_PeerVerifyFailed,
            err,
        );
    };
    const alert = client_conn.drain(&out);

    try std.testing.expect(alert.len > 0);
    try std.testing.expectEqual(@as(u8, 0x15), alert[0]);
}

test "tlz openssl: client, connect with a missing CA file is CaLoadFailed" {
    try std.testing.expectError(
        Error.Tlz_OpensslClient_CaLoadFailed,
        connect("tlz-openssl-does-not-exist-ca.pem", "localhost", &.{}),
    );
}

test "tlz openssl: client, connect with a CA path past PATH_MAX is PathTooLong" {
    const long_path: [std.posix.PATH_MAX + 1]u8 = @splat('a');

    try std.testing.expectError(
        Error.Tlz_OpensslClient_PathTooLong,
        connect(&long_path, "localhost", &.{}),
    );
}

test "tlz openssl: client, connect with an empty host is HostMissing" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    try std.testing.expectError(
        Error.Tlz_OpensslClient_HostMissing,
        connect(try fixture.certPath(), "", &.{}),
    );
}

test "tlz openssl: client, connect with a host past MAX_HOST_LEN is HostTooLong" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const long_host: [MAX_HOST_LEN + 1]u8 = @splat('a');

    try std.testing.expectError(
        Error.Tlz_OpensslClient_HostTooLong,
        connect(try fixture.certPath(), &long_host, &.{}),
    );
}

test "tlz openssl: client, connect with a host at MAX_HOST_LEN is accepted" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const host: [MAX_HOST_LEN]u8 = @splat('a');

    var conn = try connect(try fixture.certPath(), &host, &.{});
    defer conn.deinit();

    try std.testing.expect(!conn.handshakeDone());
}

test "tlz openssl: client, connect sends SNI in the ClientHello" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var conn = try connect(try fixture.certPath(), "localhost", &.{});
    defer conn.deinit();
    var out: [4096]u8 = undefined;

    const hello = try conn.handshake(&.{}, &out);

    try std.testing.expect(std.mem.find(u8, hello, "localhost") != null);
}

