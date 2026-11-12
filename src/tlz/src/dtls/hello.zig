//! TLZ dtls hello
//!
//! ### file: src/tlz/src/dtls/hello.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! DTLS ClientHello and HelloVerifyRequest codec (RFC 6347 4.2.1).
//!
//! ### note:
//!
//! The version in a HelloVerifyRequest is DTLS 1.0 by convention, even from a 1.2
//! server (RFC 6347 4.2.1). It is not version negotiation, and a client must not
//! read it as such. Parsing borrows, it copies nothing but the fixed-size random.
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
const Reader = @import("../wire/Reader.zig");
const Writer = @import("../wire/Writer.zig");
const record = @import("record.zig");

// --------------------------------------------------------- //
// Private:

/// The parse path: this module's own errors plus the wire reader.
const Inner = Error || Reader.Error;

fn innerError(err: Inner) Error {
    @branchHint(.cold);

    return switch (err) {
        error.Tlz_WireReader_Truncated => Error.Tlz_DtlsHello_Truncated,
        error.Tlz_DtlsHello_Truncated => Error.Tlz_DtlsHello_Truncated,
        error.Tlz_DtlsHello_BadHello => Error.Tlz_DtlsHello_BadHello,
    };
}

fn parseClientHelloInner(body: []const u8) Inner!ClientHello {
    var reader: Reader = .{ .buf = body };

    const client_version = try reader.readU16();
    const random = try reader.readBytes(32);

    const session_id_len = try reader.readU8();
    if (session_id_len > MAX_SESSION_ID_LEN) return Error.Tlz_DtlsHello_BadHello;

    const session_id = try reader.readBytes(session_id_len);
    const cookie = try reader.readBytes(try reader.readU8());

    const suites_len = try reader.readU16();
    if (suites_len == 0 or suites_len % 2 != 0) return Error.Tlz_DtlsHello_BadHello;

    const cipher_suites = try reader.readBytes(suites_len);

    const compression_len = try reader.readU8();
    if (compression_len == 0) return Error.Tlz_DtlsHello_BadHello;

    const compression_methods = try reader.readBytes(compression_len);

    // Extensions are optional in DTLS 1.2, a hello may end after compression methods.
    var extensions: []const u8 = "";
    if (reader.remaining() >= 2) extensions = try reader.readBytes(try reader.readU16());

    return .{
        .client_version = client_version,
        .random = random[0..32].*,
        .session_id = session_id,
        .cookie = cookie,
        .cipher_suites = cipher_suites,
        .compression_methods = compression_methods,
        .extensions = extensions,
        .body = body,
    };
}

fn parseHelloVerifyRequestInner(body: []const u8) Reader.Error![]const u8 {
    var reader: Reader = .{ .buf = body };
    _ = try reader.readU16();

    return reader.readBytes(try reader.readU8());
}

// --------------------------------------------------------- //
// Public:

pub const ClientHello = @import("hello/ClientHello.zig");

/// What `writeHelloVerifyRequestBody` and `writeClientHelloBody` can raise.
pub const WriteError = error{
    Tlz_DtlsHello_BadHello,
};

pub const Error = WriteError || error{
    Tlz_DtlsHello_Truncated,
};

/// Longest cookie a server may issue (RFC 6347 4.2.1).
pub const MAX_COOKIE_LEN: usize = 255;

/// Longest session id in a ClientHello (RFC 5246 7.4.1.2).
pub const MAX_SESSION_ID_LEN: usize = 32;

/// Parse a DTLS ClientHello body, the bytes after the handshake header.
///
/// Param:
/// body - []const u8 (handshake message body, header already stripped)
///
/// Return:
/// - ClientHello (borrowing `body`)
/// - Error.Tlz_DtlsHello_Truncated when the bytes run out mid-field
/// - Error.Tlz_DtlsHello_BadHello when a field is outside its allowed size
pub fn parseClientHello(body: []const u8) Error!ClientHello {
    return parseClientHelloInner(body) catch |err| innerError(err);
}

/// Write a HelloVerifyRequest body: server_version and the cookie.
///
/// Param:
/// out - []u8 (at least 3 + cookie.len bytes)
/// cookie - []const u8 (the cookie to send)
///
/// Return:
/// - []const u8 (the body, borrowing `out`)
/// - Error.Tlz_DtlsHello_BadHello when the cookie is over MAX_COOKIE_LEN
pub fn writeHelloVerifyRequestBody(out: []u8, cookie: []const u8) WriteError![]const u8 {
    if (cookie.len > MAX_COOKIE_LEN) return WriteError.Tlz_DtlsHello_BadHello;

    var writer: Writer = .{ .buf = out };
    writer.writeU16(record.VERSION_DTLS_1_0);
    writer.writeU8(@intCast(cookie.len));
    writer.writeBytes(cookie);

    return writer.slice();
}

/// Read the cookie out of a HelloVerifyRequest body.
///
/// Param:
/// body - []const u8 (handshake message body, header already stripped)
///
/// Return:
/// - []const u8 (the cookie, borrowing `body`)
/// - Error.Tlz_DtlsHello_Truncated when the bytes run out mid-field
pub fn parseHelloVerifyRequestBody(body: []const u8) Error![]const u8 {
    return parseHelloVerifyRequestInner(body) catch |err| switch (err) {
        error.Tlz_WireReader_Truncated => Error.Tlz_DtlsHello_Truncated,
    };
}

/// Write a DTLS ClientHello body with null compression and no extensions.
///
/// Param:
/// out - []u8 (destination, sized by the caller)
/// client_version - u16 (0xFEFD for DTLS 1.2)
/// random - [32]u8 (the client random)
/// session_id - []const u8 (empty for a fresh handshake)
/// cookie - []const u8 (empty on the first hello, echoed on the second)
/// cipher_suites - []const u16 (the offered suites)
///
/// Return:
/// - []const u8 (the body, borrowing `out`)
/// - Error.Tlz_DtlsHello_BadHello when the cookie or session id is over its limit
pub fn writeClientHelloBody(
    out: []u8,
    client_version: u16,
    random: [32]u8,
    session_id: []const u8,
    cookie: []const u8,
    cipher_suites: []const u16,
) WriteError![]const u8 {
    if (cookie.len > MAX_COOKIE_LEN) return WriteError.Tlz_DtlsHello_BadHello;
    if (session_id.len > MAX_SESSION_ID_LEN) return WriteError.Tlz_DtlsHello_BadHello;

    var writer: Writer = .{ .buf = out };
    writer.writeU16(client_version);
    writer.writeBytes(&random);
    writer.writeU8(@intCast(session_id.len));
    writer.writeBytes(session_id);
    writer.writeU8(@intCast(cookie.len));
    writer.writeBytes(cookie);

    writer.writeU16(@intCast(cipher_suites.len * 2));
    for (cipher_suites) |suite| writer.writeU16(suite);

    writer.writeU8(1);
    writer.writeU8(0);

    return writer.slice();
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const handshake = @import("handshake.zig");

const TEST_RANDOM: [32]u8 = @splat(0x11);
const TEST_SUITE: u16 = 0xC02B;

fn writeTestHello(out: []u8, cookie: []const u8) WriteError![]const u8 {
    return writeClientHelloBody(out, record.VERSION_DTLS_1_2, TEST_RANDOM, "", cookie, &.{
        TEST_SUITE,
    });
}

test "tlz dtls: hello, a first ClientHello carries no cookie" {
    var buf: [256]u8 = undefined;

    const hello = try parseClientHello(try writeTestHello(&buf, ""));

    try std.testing.expectEqual(record.VERSION_DTLS_1_2, hello.client_version);
    try std.testing.expectEqualSlices(u8, &TEST_RANDOM, &hello.random);
    try std.testing.expectEqual(@as(usize, 0), hello.session_id.len);
    try std.testing.expect(!hello.hasCookie());
    try std.testing.expect(hello.offersCipherSuite(TEST_SUITE));
}

test "tlz dtls: hello, the cookie field does not shift the suites" {
    var buf: [256]u8 = undefined;
    const cookie = [_]u8{0xAB};
    const body = try writeClientHelloBody(
        &buf,
        record.VERSION_DTLS_1_2,
        TEST_RANDOM,
        "",
        &cookie,
        &.{ TEST_SUITE, 0x009C },
    );

    const hello = try parseClientHello(body);

    try std.testing.expectEqualSlices(u8, &cookie, hello.cookie);
    try std.testing.expectEqual(@as(usize, 4), hello.cipher_suites.len);
    try std.testing.expect(hello.offersCipherSuite(0x009C));
}

test "tlz dtls: hello, the cookie span is stable across the two hellos" {
    var first_buf: [256]u8 = undefined;
    var second_buf: [256]u8 = undefined;
    const session_id = [_]u8{ 1, 2, 3, 4 };
    const cookie: [32]u8 = @splat(0xCD);

    const first = try parseClientHello(try writeClientHelloBody(
        &first_buf,
        record.VERSION_DTLS_1_2,
        TEST_RANDOM,
        &session_id,
        "",
        &.{TEST_SUITE},
    ));
    const second = try parseClientHello(try writeClientHelloBody(
        &second_buf,
        record.VERSION_DTLS_1_2,
        TEST_RANDOM,
        &session_id,
        &cookie,
        &.{TEST_SUITE},
    ));

    try std.testing.expectEqualSlices(u8, first.paramsForCookie(), second.paramsForCookie());
    try std.testing.expectEqual(@as(usize, 2 + 32 + 1 + 4), first.paramsForCookie().len);
}

test "tlz dtls: hello, a changed random moves the cookie span" {
    var first_buf: [256]u8 = undefined;
    var other_buf: [256]u8 = undefined;

    const first = try parseClientHello(try writeTestHello(&first_buf, ""));
    const other = try parseClientHello(try writeClientHelloBody(
        &other_buf,
        record.VERSION_DTLS_1_2,
        @splat(0x22),
        "",
        "",
        &.{TEST_SUITE},
    ));

    try std.testing.expect(!std.mem.eql(u8, first.paramsForCookie(), other.paramsForCookie()));
}

test "tlz dtls: hello, a hello without extensions parses" {
    var buf: [256]u8 = undefined;

    const hello = try parseClientHello(try writeTestHello(&buf, ""));

    try std.testing.expectEqual(@as(usize, 0), hello.extensions.len);
}

test "tlz dtls: hello, an extensions block passes through whole" {
    var buf: [256]u8 = undefined;
    const body = try writeTestHello(&buf, "");
    var writer: Writer = .{ .buf = buf[body.len..] };
    const block = writer.placeU16();
    writer.writeU16(0x000d);
    writer.writeU16(2);
    writer.writeU16(0x0403);
    writer.patchU16(block);

    const hello = try parseClientHello(buf[0 .. body.len + writer.len]);

    try std.testing.expectEqual(@as(usize, 6), hello.extensions.len);
    try std.testing.expectEqual(
        @as(u16, 0x000d),
        std.mem.readInt(u16, hello.extensions[0..2], .big),
    );
}

test "tlz dtls: hello, a cut body is truncated" {
    var buf: [256]u8 = undefined;
    const body = try writeTestHello(&buf, "");

    try std.testing.expectError(
        Error.Tlz_DtlsHello_Truncated,
        parseClientHello(body[0 .. body.len - 1]),
    );
    try std.testing.expectError(Error.Tlz_DtlsHello_Truncated, parseClientHello(body[0..10]));
    try std.testing.expectError(Error.Tlz_DtlsHello_Truncated, parseClientHello(""));
}

test "tlz dtls: hello, a session id past MAX_SESSION_ID_LEN is a bad hello" {
    var buf: [256]u8 = undefined;
    const body = try writeTestHello(&buf, "");
    buf[34] = 33;

    try std.testing.expectError(Error.Tlz_DtlsHello_BadHello, parseClientHello(body));
}

test "tlz dtls: hello, an odd suite list length is a bad hello" {
    var buf: [256]u8 = undefined;
    const body = try writeTestHello(&buf, "");
    buf[37] = 3;

    try std.testing.expectError(Error.Tlz_DtlsHello_BadHello, parseClientHello(body));
}

test "tlz dtls: hello, no compression methods is a bad hello" {
    var buf: [256]u8 = undefined;
    const body = try writeTestHello(&buf, "");
    buf[body.len - 2] = 0;

    try std.testing.expectError(
        Error.Tlz_DtlsHello_BadHello,
        parseClientHello(body[0 .. body.len - 1]),
    );
}

test "tlz dtls: hello, writeClientHelloBody refuses a long session id" {
    var buf: [256]u8 = undefined;
    const session_id: [MAX_SESSION_ID_LEN + 1]u8 = @splat(0);

    try std.testing.expectError(
        Error.Tlz_DtlsHello_BadHello,
        writeClientHelloBody(&buf, record.VERSION_DTLS_1_2, TEST_RANDOM, &session_id, "", &.{
            TEST_SUITE,
        }),
    );
}

test "tlz dtls: hello, HelloVerifyRequest round trips the cookie at DTLS 1.0" {
    const cookie: [32]u8 = @splat(0x5A);
    var buf: [64]u8 = undefined;

    const body = try writeHelloVerifyRequestBody(&buf, &cookie);

    try std.testing.expectEqual(record.VERSION_DTLS_1_0, std.mem.readInt(u16, body[0..2], .big));
    try std.testing.expectEqual(@as(usize, 2 + 1 + 32), body.len);
    try std.testing.expectEqualSlices(u8, &cookie, try parseHelloVerifyRequestBody(body));
}

test "tlz dtls: hello, a cut HelloVerifyRequest is truncated" {
    const cookie: [32]u8 = @splat(0x5A);
    var buf: [64]u8 = undefined;
    const body = try writeHelloVerifyRequestBody(&buf, &cookie);

    try std.testing.expectError(
        Error.Tlz_DtlsHello_Truncated,
        parseHelloVerifyRequestBody(body[0 .. body.len - 1]),
    );
    try std.testing.expectError(Error.Tlz_DtlsHello_Truncated, parseHelloVerifyRequestBody(""));
}

test "tlz dtls: hello, a HelloVerifyRequest cookie past MAX_COOKIE_LEN is a bad hello" {
    const too_long: [MAX_COOKIE_LEN + 1]u8 = @splat(0);
    var buf: [512]u8 = undefined;

    try std.testing.expectError(
        Error.Tlz_DtlsHello_BadHello,
        writeHelloVerifyRequestBody(&buf, &too_long),
    );
}

test "tlz dtls: hello, a whole message round trips through the handshake header" {
    var body_buf: [256]u8 = undefined;
    var message: [512]u8 = undefined;
    const body = try writeTestHello(&body_buf, "");
    var fragmenter: handshake.Fragmenter = .{
        .msg_type = .CLIENT_HELLO,
        .message_seq = 0,
        .body = body,
        .max_fragment_len = 1000,
    };

    var iterator: handshake.FragmentIterator = .{ .body = fragmenter.next(&message).? };
    const fragment = (try iterator.next()).?;
    const hello = try parseClientHello(fragment.data);

    try std.testing.expectEqual(handshake.MessageType.CLIENT_HELLO, fragment.header.msg_type);
    try std.testing.expectEqualSlices(u8, &TEST_RANDOM, &hello.random);
}

