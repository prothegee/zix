//! TLZ openssl Connection
//!
//! ### file: src/tlz/src/openssl/Connection.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! One OpenSSL `SSL` over a memory BIO pair. Bytes in, bytes out, like the native
//! `Connection`: the caller owns the socket and moves the bytes.
//!
//! ### note:
//!
//! OpenSSL can queue more output than `out` holds (a large flight, an alert after a
//! failure, a session ticket after a read). Check `pendingLen` and call `drain` until
//! it is 0 before waiting on the peer.
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
const Alpn = @import("../alpn.zig").Alpn;

// --------------------------------------------------------- //
// Fields:

/// The OpenSSL connection. It owns both BIOs below, `deinit` frees all three.
ssl: *c.SSL,
/// Bytes received from the peer are written here, OpenSSL reads them.
network_in: *c.BIO,
/// OpenSSL writes the bytes to send here, `drain` reads them.
network_out: *c.BIO,

const Self = @This();

// --------------------------------------------------------- //
// Private:

/// Build one connection on `ctx`, in server or client mode.
fn init(ctx: *c.SSL_CTX, is_server: bool) Error!Self {
    const ssl = c.SSL_new(ctx) orelse return Error.Tlz_OpensslConnection_SslCreateFailed;
    errdefer c.SSL_free(ssl);

    const network_in = c.BIO_new(c.BIO_s_mem()) orelse {
        return Error.Tlz_OpensslConnection_BioCreateFailed;
    };
    const network_out = c.BIO_new(c.BIO_s_mem()) orelse {
        _ = c.BIO_free(network_in);
        return Error.Tlz_OpensslConnection_BioCreateFailed;
    };

    c.SSL_set_bio(ssl, network_in, network_out);
    if (is_server) c.SSL_set_accept_state(ssl) else c.SSL_set_connect_state(ssl);

    return .{
        .ssl = ssl,
        .network_in = network_in,
        .network_out = network_out,
    };
}

/// Hand received bytes to OpenSSL.
fn feed(self: *Self, incoming: []const u8) Error!void {
    if (incoming.len == 0) return;
    if (incoming.len > std.math.maxInt(c_int)) return Error.Tlz_OpensslConnection_InputTooLarge;

    const written = c.BIO_write(self.network_in, incoming.ptr, @intCast(incoming.len));
    if (written != @as(c_int, @intCast(incoming.len))) {
        return Error.Tlz_OpensslConnection_BioWriteFailed;
    }
}

/// Map a failed `SSL_do_handshake` to this module's error.
fn handshakeError(self: *Self, rc: c_int) Error {
    @branchHint(.cold);

    switch (c.SSL_get_error(self.ssl, rc)) {
        c.SSL_ERROR_ZERO_RETURN => {
            openssl_error.clearQueue();
            return Error.Tlz_OpensslConnection_PeerClosed;
        },
        else => {},
    }

    if (c.SSL_get_verify_result(self.ssl) != c.X509_V_OK) {
        openssl_error.clearQueue();
        return Error.Tlz_OpensslConnection_PeerVerifyFailed;
    }

    const no_alpn = openssl_error.drainMatch(c.ERR_LIB_SSL, &.{
        c.SSL_R_NO_APPLICATION_PROTOCOL,
        c.SSL_R_TLSV1_ALERT_NO_APPLICATION_PROTOCOL,
    });
    if (no_alpn) return Error.Tlz_OpensslConnection_NoProtocolNegotiated;

    return Error.Tlz_OpensslConnection_HandshakeFailed;
}

/// True when a failed call only waits for more bytes from the peer.
fn wantsIo(self: *Self, rc: c_int) bool {
    return switch (c.SSL_get_error(self.ssl, rc)) {
        c.SSL_ERROR_WANT_READ, c.SSL_ERROR_WANT_WRITE => true,
        else => false,
    };
}

// --------------------------------------------------------- //
// Public:

pub const Error = error{
    Tlz_OpensslConnection_SslCreateFailed,
    Tlz_OpensslConnection_BioCreateFailed,
    Tlz_OpensslConnection_BioWriteFailed,
    Tlz_OpensslConnection_InputTooLarge,
    Tlz_OpensslConnection_HandshakeFailed,
    Tlz_OpensslConnection_PeerVerifyFailed,
    Tlz_OpensslConnection_NoProtocolNegotiated,
    Tlz_OpensslConnection_PeerClosed,
    Tlz_OpensslConnection_ReadFailed,
    Tlz_OpensslConnection_WriteFailed,
    Tlz_OpensslConnection_ShutdownFailed,
};

/// Build one server-side connection on an OpenSSL server context.
///
/// Param:
/// ctx - *c.SSL_CTX (the server context, kept alive by OpenSSL while the connection lives)
///
/// Return:
/// - Self
/// - Error when OpenSSL cannot allocate the `SSL` or a BIO
pub fn initServer(ctx: *c.SSL_CTX) Error!Self {
    return init(ctx, true);
}

/// Build one client-side connection on an OpenSSL client context.
///
/// Param:
/// ctx - *c.SSL_CTX (the client context, kept alive by OpenSSL while the connection lives)
///
/// Return:
/// - Self
/// - Error when OpenSSL cannot allocate the `SSL` or a BIO
pub fn initClient(ctx: *c.SSL_CTX) Error!Self {
    return init(ctx, false);
}

/// Free the `SSL` and both BIOs.
pub fn deinit(self: *Self) void {
    c.SSL_free(self.ssl);
    self.* = undefined;
}

/// Bytes OpenSSL has queued to send.
///
/// Return:
/// - usize
pub fn pendingLen(self: *const Self) usize {
    return c.BIO_ctrl_pending(self.network_out);
}

/// Move queued output into `out`.
///
/// Param:
/// out - []u8 (the output buffer)
///
/// Return:
/// - []const u8 (the bytes to send, empty when nothing is queued)
pub fn drain(self: *Self, out: []u8) []const u8 {
    const cap: c_int = @intCast(@min(out.len, std.math.maxInt(c_int)));
    if (cap == 0) return out[0..0];

    const read = c.BIO_read(self.network_out, out.ptr, cap);
    if (read <= 0) return out[0..0];

    return out[0..@intCast(read)];
}

/// Run one handshake step: take the peer bytes, then hand back the bytes to send.
///
/// Note:
/// - A client starts with an empty `incoming`, which produces the ClientHello.
/// - After an error, an alert may still be queued: `drain` it to tell the peer.
///
/// Param:
/// incoming - []const u8 (the bytes read from the peer, may be empty)
/// out - []u8 (the output buffer)
///
/// Return:
/// - []const u8 (the bytes to send, may be empty while waiting on the peer)
/// - Error when the handshake fails or the peer closes
pub fn handshake(self: *Self, incoming: []const u8, out: []u8) Error![]const u8 {
    try self.feed(incoming);

    openssl_error.clearQueue();
    const rc = c.SSL_do_handshake(self.ssl);

    if (rc != 1 and !self.wantsIo(rc)) return self.handshakeError(rc);

    return self.drain(out);
}

/// True once the handshake is complete.
///
/// Return:
/// - bool
pub fn handshakeDone(self: *const Self) bool {
    return c.SSL_is_init_finished(self.ssl) == 1;
}

/// The ALPN protocol both sides agreed on.
///
/// Return:
/// - Alpn
/// - null when no protocol was negotiated
pub fn selectedAlpn(self: *const Self) ?Alpn {
    var data: [*c]const u8 = null;
    var len: c_uint = 0;

    c.SSL_get0_alpn_selected(self.ssl, &data, &len);
    if (data == null or len == 0) return null;

    const name = data[0..len];
    for (std.enums.values(Alpn)) |protocol| {
        if (std.mem.eql(u8, name, protocol.token())) return protocol;
    }

    return null;
}

/// Seal application data into records.
///
/// Param:
/// plaintext - []const u8 (the data to send)
/// out - []u8 (the output buffer for the records)
///
/// Return:
/// - []const u8 (the records to send, empty when `plaintext` is empty)
/// - Error when OpenSSL refuses the write
pub fn writeAppData(self: *Self, plaintext: []const u8, out: []u8) Error![]const u8 {
    if (plaintext.len == 0) return out[0..0];
    if (plaintext.len > std.math.maxInt(c_int)) return Error.Tlz_OpensslConnection_InputTooLarge;

    openssl_error.clearQueue();
    const rc = c.SSL_write(self.ssl, plaintext.ptr, @intCast(plaintext.len));

    if (rc <= 0) {
        openssl_error.clearQueue();
        return Error.Tlz_OpensslConnection_WriteFailed;
    }

    return self.drain(out);
}

/// Open received records into application data.
///
/// Param:
/// rec - []const u8 (the bytes read from the peer)
/// out - []u8 (the output buffer for the plaintext)
///
/// Return:
/// - []const u8 (the plaintext, empty when a full record has not arrived yet)
/// - Error when the record is bad or the peer sent close_notify
pub fn readAppData(self: *Self, rec: []const u8, out: []u8) Error![]const u8 {
    try self.feed(rec);

    const cap: c_int = @intCast(@min(out.len, std.math.maxInt(c_int)));
    if (cap == 0) return out[0..0];

    openssl_error.clearQueue();
    const rc = c.SSL_read(self.ssl, out.ptr, cap);

    if (rc > 0) return out[0..@intCast(rc)];

    if (self.wantsIo(rc)) return out[0..0];

    if (c.SSL_get_error(self.ssl, rc) == c.SSL_ERROR_ZERO_RETURN) {
        openssl_error.clearQueue();
        return Error.Tlz_OpensslConnection_PeerClosed;
    }

    openssl_error.clearQueue();
    return Error.Tlz_OpensslConnection_ReadFailed;
}

/// Write the close_notify alert.
///
/// Param:
/// out - []u8 (the output buffer)
///
/// Return:
/// - []const u8 (the alert record to send)
/// - Error when the connection cannot be shut down (for example mid-handshake)
pub fn closeNotify(self: *Self, out: []u8) Error![]const u8 {
    openssl_error.clearQueue();
    const rc = c.SSL_shutdown(self.ssl);

    if (rc < 0) {
        openssl_error.clearQueue();
        return Error.Tlz_OpensslConnection_ShutdownFailed;
    }

    return self.drain(out);
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

/// A bare TLS context for tests that only need an `SSL`, with no certificate.
fn testContext() !*c.SSL_CTX {
    return c.SSL_CTX_new(c.TLS_method()) orelse error.TestUnexpectedResult;
}

test "tlz openssl: Connection, initServer is not done before a handshake" {
    const ctx = try testContext();
    defer c.SSL_CTX_free(ctx);

    var conn = try initServer(ctx);
    defer conn.deinit();

    try std.testing.expect(!conn.handshakeDone());
}

test "tlz openssl: Connection, initClient first step writes a ClientHello record" {
    const ctx = try testContext();
    defer c.SSL_CTX_free(ctx);
    var conn = try initClient(ctx);
    defer conn.deinit();
    var out: [4096]u8 = undefined;

    const hello = try conn.handshake(&.{}, &out);

    try std.testing.expect(hello.len > 5);
    try std.testing.expectEqual(@as(u8, 0x16), hello[0]);
}

test "tlz openssl: Connection, server step without peer bytes waits" {
    const ctx = try testContext();
    defer c.SSL_CTX_free(ctx);
    var conn = try initServer(ctx);
    defer conn.deinit();
    var out: [64]u8 = undefined;

    const sent = try conn.handshake(&.{}, &out);

    try std.testing.expectEqual(@as(usize, 0), sent.len);
}

test "tlz openssl: Connection, server step on garbage bytes is HandshakeFailed" {
    const ctx = try testContext();
    defer c.SSL_CTX_free(ctx);
    var conn = try initServer(ctx);
    defer conn.deinit();
    var out: [64]u8 = undefined;

    try std.testing.expectError(
        Error.Tlz_OpensslConnection_HandshakeFailed,
        conn.handshake("GET / HTTP/1.1\r\n\r\n", &out),
    );
}

test "tlz openssl: Connection, drain with an empty buffer is empty" {
    const ctx = try testContext();
    defer c.SSL_CTX_free(ctx);
    var conn = try initClient(ctx);
    defer conn.deinit();
    var out: [0]u8 = undefined;

    _ = try conn.handshake(&.{}, &out);

    try std.testing.expectEqual(@as(usize, 0), conn.drain(&out).len);
}

test "tlz openssl: Connection, drain hands out a flight larger than out in parts" {
    const ctx = try testContext();
    defer c.SSL_CTX_free(ctx);
    var conn = try initClient(ctx);
    defer conn.deinit();
    var small: [16]u8 = undefined;

    const first = try conn.handshake(&.{}, &small);
    const left = conn.pendingLen();

    try std.testing.expectEqual(small.len, first.len);
    try std.testing.expect(left > 0);
    try std.testing.expectEqual(@min(left, small.len), conn.drain(&small).len);
}

test "tlz openssl: Connection, selectedAlpn before a handshake is null" {
    const ctx = try testContext();
    defer c.SSL_CTX_free(ctx);
    var conn = try initServer(ctx);
    defer conn.deinit();

    try std.testing.expect(conn.selectedAlpn() == null);
}

test "tlz openssl: Connection, writeAppData with empty plaintext is empty" {
    const ctx = try testContext();
    defer c.SSL_CTX_free(ctx);
    var conn = try initServer(ctx);
    defer conn.deinit();
    var out: [64]u8 = undefined;

    try std.testing.expectEqual(@as(usize, 0), (try conn.writeAppData("", &out)).len);
}

test "tlz openssl: Connection, readAppData with an empty buffer is empty" {
    const ctx = try testContext();
    defer c.SSL_CTX_free(ctx);
    var conn = try initServer(ctx);
    defer conn.deinit();
    var out: [0]u8 = undefined;

    try std.testing.expectEqual(@as(usize, 0), (try conn.readAppData("", &out)).len);
}

test "tlz openssl: Connection, closeNotify mid-handshake is ShutdownFailed" {
    const ctx = try testContext();
    defer c.SSL_CTX_free(ctx);
    var conn = try initClient(ctx);
    defer conn.deinit();
    var out: [4096]u8 = undefined;

    _ = try conn.handshake(&.{}, &out);

    try std.testing.expectError(
        Error.Tlz_OpensslConnection_ShutdownFailed,
        conn.closeNotify(&out),
    );
}

