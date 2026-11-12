//! TLZ handshake
//!
//! ### file: src/tlz/src/handshake.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! TLS 1.3 server handshake messages (RFC 8446 section 4): parse a ClientHello,
//! negotiate version, cipher, and group, and serialize the ServerHello or the
//! HelloRetryRequest.
//!
//! ### note:
//!
//! Key schedule and record protection live in `key_schedule.zig` and `record.zig`.
//! The ServerHello bytes are checked against the RFC 8448 trace in the tests below.
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
const Reader = @import("wire/Reader.zig");
const Writer = @import("wire/Writer.zig");
const Alert = @import("alert/description.zig").Alert;
const HandshakeType = @import("handshake/handshake_type.zig").HandshakeType;
const ClientHello = @import("handshake/ClientHello.zig");
const ServerHelloParams = @import("handshake/ServerHelloParams.zig");
const CipherSuite = @import("cipher_suite.zig").CipherSuite;
const NamedGroup = @import("named_group.zig").NamedGroup;
const ExtensionType = @import("extension_type.zig").ExtensionType;

// --------------------------------------------------------- //
// Private:

/// The parse path: this module's own errors plus the wire reader.
const Inner = Error || Reader.Error;

fn parseClientHelloInner(bytes: []const u8) Inner!ClientHello {
    var reader: Reader = .{ .buf = bytes };

    if (try reader.readU8() != @intFromEnum(HandshakeType.CLIENT_HELLO)) {
        return Error.Tlz_Handshake_IllegalParameter;
    }

    _ = try reader.readU24();

    const legacy_version = try reader.readU16();
    const random = try reader.readBytes(32);
    const session_id_len = try reader.readU8();
    const session_id = try reader.readBytes(session_id_len);

    const cipher_suites_len = try reader.readU16();
    const cipher_suites = try reader.readBytes(cipher_suites_len);

    const compression_len = try reader.readU8();
    const compression = try reader.readBytes(compression_len);
    if (compression_len != 1 or compression[0] != 0) {
        return Error.Tlz_Handshake_IllegalParameter;
    }

    var hello: ClientHello = .{
        .legacy_version = legacy_version,
        .random = undefined,
        .session_id = session_id,
        .cipher_suites = cipher_suites,
    };
    @memcpy(&hello.random, random);

    const extensions_len = try reader.readU16();
    const extensions = try reader.readBytes(extensions_len);
    try parseClientExtensions(&hello, extensions);

    return hello;
}

fn parseClientExtensions(hello: *ClientHello, extensions: []const u8) Inner!void {
    var reader: Reader = .{ .buf = extensions };

    while (reader.remaining() >= 4) {
        const ext_type: ExtensionType = @enumFromInt(try reader.readU16());
        const ext_len = try reader.readU16();
        const ext_data = try reader.readBytes(ext_len);

        switch (ext_type) {
            .SUPPORTED_VERSIONS => try parseSupportedVersions(hello, ext_data),
            .SUPPORTED_GROUPS => {
                hello.has_supported_groups = true;
                hello.supported_groups = try readU16Vector(ext_data);
            },
            .SIGNATURE_ALGORITHMS => {
                hello.has_signature_algorithms = true;
                hello.signature_schemes = try readU16Vector(ext_data);
            },
            .APPLICATION_LAYER_PROTOCOL_NEGOTIATION => hello.alpn = ext_data,
            .KEY_SHARE => try parseKeyShare(hello, ext_data),
            .SERVER_NAME => try parseServerName(hello, ext_data),
            else => {},
        }
    }
}

/// Read the body of a vector with a u16 length prefix.
fn readU16Vector(ext_data: []const u8) Inner![]const u8 {
    var reader: Reader = .{ .buf = ext_data };
    const list_len = try reader.readU16();

    return reader.readBytes(list_len);
}

fn parseSupportedVersions(hello: *ClientHello, ext_data: []const u8) Inner!void {
    var reader: Reader = .{ .buf = ext_data };
    const list_len = try reader.readU8();
    const list = try reader.readBytes(list_len);

    var list_reader: Reader = .{ .buf = list };
    while (list_reader.remaining() >= 2) {
        if (try list_reader.readU16() == VERSION_TLS_1_3) hello.offers_tls13 = true;
    }
}

fn parseServerName(hello: *ClientHello, ext_data: []const u8) Inner!void {
    var reader: Reader = .{ .buf = ext_data };
    _ = try reader.readU16();
    _ = try reader.readU8();

    const name_len = try reader.readU16();
    hello.sni = try reader.readBytes(name_len);
}

fn parseKeyShare(hello: *ClientHello, ext_data: []const u8) Inner!void {
    const shares = try readU16Vector(ext_data);

    var reader: Reader = .{ .buf = shares };
    while (reader.remaining() >= 4) {
        const group: NamedGroup = @enumFromInt(try reader.readU16());
        const key_exchange_len = try reader.readU16();
        const key_exchange = try reader.readBytes(key_exchange_len);

        if (hello.key_share_count < hello.key_share_groups.len) {
            hello.key_share_groups[hello.key_share_count] = group;
            hello.key_share_count += 1;
        }

        if (group == .X25519) hello.x25519_share = key_exchange;
        if (group == .SECP256R1) hello.secp256r1_share = key_exchange;
    }
}

/// Map a parse failure to the fatal alert it triggers.
fn parseAlert(err: Inner) Alert {
    @branchHint(.cold);

    return switch (err) {
        error.Tlz_Handshake_IllegalParameter => .ILLEGAL_PARAMETER,
        error.Tlz_WireReader_Truncated => .DECODE_ERROR,
    };
}

fn pickCipher(hello: *const ClientHello) ?CipherSuite {
    for (SERVER_CIPHER_PREFS) |suite| {
        if (hello.offersCipher(suite)) return suite;
    }

    return null;
}

/// Pick the first configured curve the client also offered (server preference order).
fn pickGroup(hello: *const ClientHello, group_prefs: []const NamedGroup) ?NamedGroup {
    for (group_prefs) |group| {
        if (hello.offersGroup(group)) return group;
    }

    return null;
}

/// Write the ServerHello frame up to the extensions block: type, length, legacy
/// version, random, session id, cipher, and null compression.
///
/// Return:
/// - usize (the u24 length marker to patch once the message is written)
fn writeServerHelloHead(
    writer: *Writer,
    random: []const u8,
    session_id: []const u8,
    cipher: CipherSuite,
) usize {
    writer.writeU8(@intFromEnum(HandshakeType.SERVER_HELLO));
    const header = writer.placeU24();

    writer.writeU16(VERSION_TLS_1_2);
    writer.writeBytes(random);
    writer.writeU8(@intCast(session_id.len));
    writer.writeBytes(session_id);
    writer.writeU16(@intFromEnum(cipher));
    writer.writeU8(0);

    return header;
}

fn writeSupportedVersions(writer: *Writer) void {
    writer.writeU16(@intFromEnum(ExtensionType.SUPPORTED_VERSIONS));
    const supported_versions = writer.placeU16();
    writer.writeU16(VERSION_TLS_1_3);
    writer.patchU16(supported_versions);
}

// --------------------------------------------------------- //
// Public:

/// The ways a ClientHello parse fails. `parseClientHello` turns each into an alert.
pub const Error = error{
    Tlz_Handshake_IllegalParameter,
};

/// legacy_version on the wire (RFC 8446 4.1.2): TLS 1.2 in the record and hello.
pub const VERSION_TLS_1_2: u16 = 0x0303;

/// TLS 1.3, carried only in supported_versions (RFC 8446 4.2.1).
pub const VERSION_TLS_1_3: u16 = 0x0304;

/// Server cipher preference order (RFC 8446 9.1).
///
/// Note:
/// - Only TLS_AES_128_GCM_SHA256 is listed. The key schedule is SHA-256 throughout,
///   so negotiate never picks a suite the connection layer cannot run.
pub const SERVER_CIPHER_PREFS = [_]CipherSuite{.AES_128_GCM_SHA256};

/// Server group preference order: both implemented groups, X25519 first.
pub const SERVER_GROUP_PREFS = [_]NamedGroup{
    .X25519,
    .SECP256R1,
};

/// The HelloRetryRequest marker in ServerHello.random (RFC 8446 4.1.3): the SHA-256
/// of "HelloRetryRequest". A ServerHello with this random is a HelloRetryRequest.
pub const HELLO_RETRY_REQUEST_RANDOM = [32]u8{
    0xCF, 0x21, 0xAD, 0x74, 0xE5, 0x9A, 0x61, 0x11,
    0xBE, 0x1D, 0x8C, 0x02, 0x1E, 0x65, 0xB8, 0x91,
    0xC2, 0xA2, 0x11, 0x16, 0x7A, 0xBB, 0x8C, 0x5E,
    0x07, 0x9E, 0x09, 0xE2, 0xC8, 0xA8, 0x33, 0x9C,
};

/// A parsed ClientHello, or the fatal alert the bytes trigger.
pub const ParseResult = union(enum) {
    ok: ClientHello,
    alert: Alert,
};

/// Negotiation outcome.
///
/// Note:
/// - The lower_case tags follow the internal control-flow enum style, not the
///   public wire enum style.
pub const Outcome = union(enum) {
    server_hello: ServerHelloParams,
    hello_retry_request: NamedGroup,
    legacy_version,
    alert: Alert,
};

/// Parse a ClientHello message into its fields.
///
/// Param:
/// bytes - []const u8 (the whole handshake message, header included)
///
/// Return:
/// - ParseResult.ok (slices are views into `bytes`)
/// - ParseResult.alert ILLEGAL_PARAMETER on a wrong type or a bad compression list
/// - ParseResult.alert DECODE_ERROR on truncated input
pub fn parseClientHello(bytes: []const u8) ParseResult {
    const hello = parseClientHelloInner(bytes) catch |err| return .{
        .alert = parseAlert(err),
    };

    return .{ .ok = hello };
}

/// Negotiate version, cipher, and group from a parsed ClientHello (RFC 8446 4.1.1, 9.1).
///
/// Param:
/// hello - *const ClientHello (the parsed hello)
/// key_exchange - []const u8 (the server key share, carried into the result)
/// group_prefs - []const NamedGroup (the configured curve order, first wins)
///
/// Return:
/// - Outcome.server_hello when a ServerHello can be sent right away
/// - Outcome.hello_retry_request when the picked group has no client key share
/// - Outcome.legacy_version when the client does not offer TLS 1.3
/// - Outcome.alert MISSING_EXTENSION or HANDSHAKE_FAILURE otherwise
pub fn negotiate(
    hello: *const ClientHello,
    key_exchange: []const u8,
    group_prefs: []const NamedGroup,
) Outcome {
    if (!hello.offers_tls13) return .legacy_version;

    if (!hello.has_signature_algorithms or !hello.has_supported_groups) {
        return .{ .alert = .MISSING_EXTENSION };
    }

    const cipher = pickCipher(hello) orelse return .{ .alert = .HANDSHAKE_FAILURE };
    const group = pickGroup(hello, group_prefs) orelse return .{ .alert = .HANDSHAKE_FAILURE };

    if (!hello.hasKeyShare(group)) return .{ .hello_retry_request = group };

    return .{
        .server_hello = .{
            .cipher = cipher,
            .group = group,
            .key_exchange = key_exchange,
        },
    };
}

/// Serialize a ServerHello message (RFC 8446 4.1.3).
///
/// Param:
/// buf - []u8 (the destination, sized for the whole message)
/// random - []const u8 (the 32-byte server random)
/// session_id - []const u8 (the client legacy_session_id, echoed)
/// params - ServerHelloParams (what negotiate picked)
///
/// Return:
/// - []const u8 (the wire message, a view into `buf`)
pub fn serializeServerHello(
    buf: []u8,
    random: []const u8,
    session_id: []const u8,
    params: ServerHelloParams,
) []const u8 {
    var writer: Writer = .{ .buf = buf };
    const header = writeServerHelloHead(&writer, random, session_id, params.cipher);

    const extensions = writer.placeU16();

    writer.writeU16(@intFromEnum(ExtensionType.KEY_SHARE));
    const key_share = writer.placeU16();
    writer.writeU16(@intFromEnum(params.group));
    const key_exchange = writer.placeU16();
    writer.writeBytes(params.key_exchange);
    writer.patchU16(key_exchange);
    writer.patchU16(key_share);

    writeSupportedVersions(&writer);

    writer.patchU16(extensions);
    writer.patchU24(header);

    return writer.slice();
}

/// Serialize a HelloRetryRequest (RFC 8446 4.1.4): a ServerHello with the HRR random,
/// supported_versions, and a key_share naming only the group the client must retry
/// with (no key bytes).
///
/// Param:
/// buf - []u8 (the destination, sized for the whole message)
/// session_id - []const u8 (the client legacy_session_id, echoed)
/// cipher - CipherSuite (the negotiated suite)
/// group - NamedGroup (the group the client must send a key share for)
///
/// Return:
/// - []const u8 (the wire message, a view into `buf`)
pub fn serializeHelloRetryRequest(
    buf: []u8,
    session_id: []const u8,
    cipher: CipherSuite,
    group: NamedGroup,
) []const u8 {
    var writer: Writer = .{ .buf = buf };
    const header = writeServerHelloHead(
        &writer,
        &HELLO_RETRY_REQUEST_RANDOM,
        session_id,
        cipher,
    );

    const extensions = writer.placeU16();

    writeSupportedVersions(&writer);

    writer.writeU16(@intFromEnum(ExtensionType.KEY_SHARE));
    const key_share = writer.placeU16();
    writer.writeU16(@intFromEnum(group));
    writer.patchU16(key_share);

    writer.patchU16(extensions);
    writer.patchU24(header);

    return writer.slice();
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

/// The RFC 8448 simple 1-RTT ClientHello.
const RFC8448_CLIENT_HELLO_HEX =
    "010000c00303cb34ecb1e78163ba1c38c6dacb196a6dffa21a8d9912ec18a2ef6283024dece70000" ++
    "06130113031302010000910000000b0009000006736572766572ff01000100000a00140012001d00" ++
    "17001800190100010101020103010400230000003300260024001d002099381de560e4bd43d23d8e" ++
    "435a7dbafeb3c06e51c13cae4d5413691e529aaf2c002b0003020304000d0020001e040305030603" ++
    "020308040805080604010501060102010402050206020202002d00020101001c00024001";

/// The RFC 8448 simple 1-RTT ServerHello.
const RFC8448_SERVER_HELLO_HEX =
    "020000560303a6af06a4121860dc5e6e60249cd34c95930c8ac5cb1434dac155772ed3e269280013" ++
    "0100002e00330024001d0020c9828876112095fe66762bdbf7c672e156d6cc253b833df1dd69b1b0" ++
    "4e751f0f002b00020304";

const RFC8448_SERVER_RANDOM_HEX =
    "a6af06a4121860dc5e6e60249cd34c95930c8ac5cb1434dac155772ed3e26928";

const RFC8448_SERVER_PUBLIC_HEX =
    "c9828876112095fe66762bdbf7c672e156d6cc253b833df1dd69b1b04e751f0f";

fn rfc8448ClientHello() ![196]u8 {
    var out: [196]u8 = undefined;
    _ = try std.fmt.hexToBytes(&out, RFC8448_CLIENT_HELLO_HEX);

    return out;
}

/// Write a ClientHello head: type, length marker, version, zero random, empty
/// session id, one AES-128-GCM suite, null compression.
///
/// Return:
/// - usize (the u24 length marker)
fn writeTestHelloHead(writer: *Writer) usize {
    writer.writeU8(@intFromEnum(HandshakeType.CLIENT_HELLO));
    const header = writer.placeU24();

    writer.writeU16(VERSION_TLS_1_2);
    writer.writeBytes(&std.mem.zeroes([32]u8));
    writer.writeU8(0);
    writer.writeU16(2);
    writer.writeU16(@intFromEnum(CipherSuite.AES_128_GCM_SHA256));
    writer.writeU8(1);
    writer.writeU8(0);

    return header;
}

test "tlz: handshake, RFC 8448 ClientHello parses" {
    const client_hello = try rfc8448ClientHello();

    const parsed = parseClientHello(&client_hello);

    try std.testing.expect(parsed == .ok);
    try std.testing.expect(parsed.ok.offers_tls13);
    try std.testing.expect(parsed.ok.has_signature_algorithms);
    try std.testing.expect(parsed.ok.has_supported_groups);
    try std.testing.expect(parsed.ok.hasKeyShare(.X25519));
    try std.testing.expectEqualStrings("server", parsed.ok.sni orelse "");
}

test "tlz: handshake, RFC 8448 negotiate picks AES-128-GCM and X25519" {
    const client_hello = try rfc8448ClientHello();
    const hello = parseClientHello(&client_hello).ok;

    const outcome = negotiate(&hello, &.{}, &SERVER_GROUP_PREFS);

    try std.testing.expect(outcome == .server_hello);
    try std.testing.expectEqual(CipherSuite.AES_128_GCM_SHA256, outcome.server_hello.cipher);
    try std.testing.expectEqual(NamedGroup.X25519, outcome.server_hello.group);
}

test "tlz: handshake, RFC 8448 ServerHello is byte exact" {
    const client_hello = try rfc8448ClientHello();
    var expected: [90]u8 = undefined;
    var server_random: [32]u8 = undefined;
    var server_public: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected, RFC8448_SERVER_HELLO_HEX);
    _ = try std.fmt.hexToBytes(&server_random, RFC8448_SERVER_RANDOM_HEX);
    _ = try std.fmt.hexToBytes(&server_public, RFC8448_SERVER_PUBLIC_HEX);

    const hello = parseClientHello(&client_hello).ok;
    const outcome = negotiate(&hello, &server_public, &SERVER_GROUP_PREFS);
    var buf: [256]u8 = undefined;
    const server_hello = serializeServerHello(
        &buf,
        &server_random,
        hello.session_id,
        outcome.server_hello,
    );

    try std.testing.expectEqualSlices(u8, &expected, server_hello);
}

test "tlz: handshake, negotiate prefers a reordered group without a key share" {
    const client_hello = try rfc8448ClientHello();
    const hello = parseClientHello(&client_hello).ok;

    const outcome = negotiate(&hello, &.{}, &[_]NamedGroup{ .SECP256R1, .X25519 });

    try std.testing.expect(outcome == .hello_retry_request);
    try std.testing.expectEqual(NamedGroup.SECP256R1, outcome.hello_retry_request);
}

test "tlz: handshake, negotiate restricted to X25519 picks it" {
    const client_hello = try rfc8448ClientHello();
    const hello = parseClientHello(&client_hello).ok;

    const outcome = negotiate(&hello, &.{}, &[_]NamedGroup{.X25519});

    try std.testing.expect(outcome == .server_hello);
    try std.testing.expectEqual(NamedGroup.X25519, outcome.server_hello.group);
}

test "tlz: handshake, negotiate with no shared group is handshake_failure" {
    const client_hello = try rfc8448ClientHello();
    const hello = parseClientHello(&client_hello).ok;

    const outcome = negotiate(&hello, &.{}, &[_]NamedGroup{@enumFromInt(0x0200)});

    try std.testing.expect(outcome == .alert);
    try std.testing.expectEqual(Alert.HANDSHAKE_FAILURE, outcome.alert);
}

test "tlz: handshake, negotiate without signature_algorithms is missing_extension" {
    const client_hello = try rfc8448ClientHello();
    var hello = parseClientHello(&client_hello).ok;
    hello.has_signature_algorithms = false;

    const outcome = negotiate(&hello, &.{}, &SERVER_GROUP_PREFS);

    try std.testing.expect(outcome == .alert);
    try std.testing.expectEqual(Alert.MISSING_EXTENSION, outcome.alert);
}

test "tlz: handshake, ClientHello captures the ALPN protocol list" {
    var buf: [256]u8 = undefined;
    var writer: Writer = .{ .buf = &buf };
    const header = writeTestHelloHead(&writer);

    const extensions = writer.placeU16();
    writer.writeU16(@intFromEnum(ExtensionType.APPLICATION_LAYER_PROTOCOL_NEGOTIATION));
    const ext = writer.placeU16();
    const list = writer.placeU16();
    writer.writeU8(2);
    writer.writeBytes("h2");
    writer.patchU16(list);
    writer.patchU16(ext);
    writer.patchU16(extensions);
    writer.patchU24(header);

    const parsed = parseClientHello(writer.slice());

    try std.testing.expect(parsed == .ok);
    try std.testing.expectEqualSlices(
        u8,
        &[_]u8{ 0x00, 0x03, 0x02, 'h', '2' },
        parsed.ok.alpn.?,
    );
}

test "tlz: handshake, unknown extension is skipped" {
    var buf: [256]u8 = undefined;
    var writer: Writer = .{ .buf = &buf };
    const header = writeTestHelloHead(&writer);

    const extensions = writer.placeU16();
    writer.writeU16(0x002c);
    const cookie_ext = writer.placeU16();
    const cookie_body = writer.placeU16();
    writer.writeBytes(&[_]u8{ 0xAA, 0xBB, 0xCC });
    writer.patchU16(cookie_body);
    writer.patchU16(cookie_ext);
    writer.writeU16(@intFromEnum(ExtensionType.SUPPORTED_VERSIONS));
    writer.writeU16(3);
    writer.writeU8(2);
    writer.writeU16(VERSION_TLS_1_3);
    writer.patchU16(extensions);
    writer.patchU24(header);

    const parsed = parseClientHello(writer.slice());

    try std.testing.expect(parsed == .ok);
    try std.testing.expect(parsed.ok.offers_tls13);
}

test "tlz: handshake, serializeHelloRetryRequest carries the HRR random" {
    var buf: [128]u8 = undefined;

    const hrr = serializeHelloRetryRequest(&buf, &.{}, .AES_128_GCM_SHA256, .X25519);

    try std.testing.expectEqual(@intFromEnum(HandshakeType.SERVER_HELLO), hrr[0]);
    try std.testing.expectEqualSlices(u8, &HELLO_RETRY_REQUEST_RANDOM, hrr[6..38]);
}

test "tlz: handshake, serializeHelloRetryRequest names only the selected group" {
    var buf: [128]u8 = undefined;
    const key_share = [_]u8{ 0x00, 0x33, 0x00, 0x02, 0x00, 0x1d };

    const hrr = serializeHelloRetryRequest(&buf, &.{}, .AES_128_GCM_SHA256, .X25519);

    try std.testing.expect(std.mem.find(u8, hrr, &key_share) != null);
}

test "tlz: handshake, compression method other than null is illegal_parameter" {
    var client_hello = try rfc8448ClientHello();
    client_hello[48] = 1;

    const parsed = parseClientHello(&client_hello);

    try std.testing.expect(parsed == .alert);
    try std.testing.expectEqual(Alert.ILLEGAL_PARAMETER, parsed.alert);
}

test "tlz: handshake, wrong message type is illegal_parameter" {
    var client_hello = try rfc8448ClientHello();
    client_hello[0] = @intFromEnum(HandshakeType.SERVER_HELLO);

    const parsed = parseClientHello(&client_hello);

    try std.testing.expect(parsed == .alert);
    try std.testing.expectEqual(Alert.ILLEGAL_PARAMETER, parsed.alert);
}

test "tlz: handshake, truncated ClientHello is decode_error" {
    const client_hello = try rfc8448ClientHello();

    const parsed = parseClientHello(client_hello[0..40]);

    try std.testing.expect(parsed == .alert);
    try std.testing.expectEqual(Alert.DECODE_ERROR, parsed.alert);
}

test "tlz: handshake, empty input is decode_error" {
    const parsed = parseClientHello(&.{});

    try std.testing.expect(parsed == .alert);
    try std.testing.expectEqual(Alert.DECODE_ERROR, parsed.alert);
}

test "tlz: handshake, ClientHello without TLS 1.3 negotiates legacy_version" {
    var client_hello = try rfc8448ClientHello();
    client_hello[146] = 0x03;
    client_hello[147] = 0x03;

    const hello = parseClientHello(&client_hello).ok;

    try std.testing.expect(!hello.offers_tls13);
    try std.testing.expect(negotiate(&hello, &.{}, &SERVER_GROUP_PREFS) == .legacy_version);
}

