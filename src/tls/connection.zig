//! TLS 1.3 server connection: the sans-I/O handshake + record state machine (RFC 8446).
//!
//! Note:
//! - No socket calls. `serverHandshake` consumes a ClientHello and produces the bytes to send
//!   (ServerHello plaintext record, a legacy ChangeCipherSpec, then the encrypted flight) and a
//!   Connection holding the post-handshake keys. The caller (the engine or example) owns the fd
//!   read/write loop, so this fits blocking and non-blocking dispatch alike.
//! - Randomness (the ephemeral key and ServerHello random) is injected by the caller, so the
//!   handshake is deterministic and unit-testable against the RFC 8448 trace.
//! - Composes the verified layers: handshake (H), extensions (X), certificate (C), key_schedule
//!   + record (K).

const std = @import("std");
const wire = @import("wire.zig");
const key_schedule = @import("key_schedule.zig");
const record = @import("record.zig");
const handshake = @import("handshake.zig");
const extensions = @import("extensions.zig");
const certificate = @import("certificate.zig");
const alert = @import("alert.zig");

const X25519 = std.crypto.dh.X25519;
const P256 = std.crypto.ecc.P256;
const EcdsaP256 = std.crypto.sign.ecdsa.EcdsaP256Sha256;
const NamedGroup = handshake.NamedGroup;
const Secret = key_schedule.Secret;

const ccs_record = [_]u8{ 20, 0x03, 0x03, 0x00, 0x01, 0x01 };

/// Inputs the caller supplies to drive one server handshake. The cert + key select the identity,
/// the ephemeral secret + random are freshly generated per connection (or trace values in tests).
pub const HandshakeOptions = struct {
    certificate_der: []const u8,
    signing_key: EcdsaP256.KeyPair,
    ephemeral_secret: [32]u8,
    server_random: [32]u8,
    /// Server ALPN preference order (RFC 7301). Empty disables ALPN (no extension emitted).
    /// The first entry that the client also offered is selected and echoed in EncryptedExtensions.
    alpn_prefs: []const extensions.Alpn = &.{},
};

/// Post-handshake connection state: the application + handshake keys and per-key sequence
/// numbers needed to read the client Finished and exchange application records.
pub const Connection = struct {
    server_app_key: [record.key_length]u8,
    server_app_iv: [record.iv_length]u8,
    client_app_key: [record.key_length]u8,
    client_app_iv: [record.iv_length]u8,
    client_hs_key: [record.key_length]u8,
    client_hs_iv: [record.iv_length]u8,
    client_finished_key: Secret,
    transcript_through_server_finished: Secret,
    server_app_seq: u64 = 0,
    client_app_seq: u64 = 0,

    /// Encrypt application data into a record under the server application key.
    pub fn writeAppData(self: *Connection, plaintext: []const u8, out: []u8) []const u8 {
        const rec = record.protect(out, plaintext, .APPLICATION_DATA, self.server_app_key, self.server_app_iv, self.server_app_seq);
        self.server_app_seq += 1;

        return rec;
    }

    /// Decrypt one client application record. Returns the plaintext (the inner content type is
    /// stripped). A non-application inner type surfaces as decode_error to the caller.
    pub fn readAppData(self: *Connection, rec: []const u8, out: []u8) record.Error![]const u8 {
        const opened = try record.deprotect(out, rec, self.client_app_key, self.client_app_iv, self.client_app_seq);
        self.client_app_seq += 1;
        if (opened.inner_type != .APPLICATION_DATA) return error.Decode;

        return opened.data;
    }

    /// Emit an encrypted close_notify alert (level warning, description 0) under the server key.
    pub fn closeNotify(self: *Connection, out: []u8) []const u8 {
        const rec = record.protect(out, &[_]u8{ 1, 0 }, .ALERT, self.server_app_key, self.server_app_iv, self.server_app_seq);
        self.server_app_seq += 1;

        return rec;
    }

    /// Deprotect + verify the client Finished record (RFC 8446 4.4.4), seq 0 under the client
    /// handshake key. Mismatch is the decrypt_error condition.
    pub fn verifyClientFinished(self: *const Connection, rec: []const u8) !void {
        var plain: [512]u8 = undefined;
        const opened = try record.deprotect(&plain, rec, self.client_hs_key, self.client_hs_iv, 0);
        if (opened.inner_type != .HANDSHAKE or opened.data.len < 4 + key_schedule.hash_length) return error.ClientFinishedMismatch;

        const expected = certificate.finishedVerifyData(self.client_finished_key, self.transcript_through_server_finished);
        if (!std.mem.eql(u8, opened.data[4 .. 4 + key_schedule.hash_length], &expected)) return error.ClientFinishedMismatch;
    }
};

pub const HandshakeResult = struct {
    connection: Connection,
    /// The bytes to send to the client (ServerHello record, ChangeCipherSpec, encrypted flight).
    to_send: []const u8,
    /// The ALPN protocol selected from the client offer and the server prefs, null when ALPN was
    /// not used (no server prefs, or the client offered none). The engine dispatches on this.
    alpn: ?extensions.Alpn = null,
};

/// Drive the server side of a TLS 1.3 handshake from a ClientHello, producing the server flight
/// and the post-handshake Connection. Sans-I/O: the caller transmits `to_send` and feeds back
/// the client Finished + application records.
pub fn serverHandshake(opts: HandshakeOptions, client_hello: []const u8, out: []u8) !HandshakeResult {
    const parsed = handshake.parseClientHello(client_hello);
    if (parsed != .ok) return alertToError(parsed.alert);
    const hello = parsed.ok;

    // Negotiate version, cipher, and group (RFC 8446 4.1.1, 9.1). The key_exchange material is
    // computed after the group is known, so pass an empty placeholder here.
    const negotiated = switch (handshake.negotiate(&hello, &.{})) {
        .server_hello => |params| params,
        // Single-flight only for now: emitting a HelloRetryRequest (RFC 8446 4.1.4) and sending
        // alert records (Layer A) are tracked separately. In practice clients offer an X25519 or
        // secp256r1 key_share, so HRR does not trigger.
        .hello_retry_request => return error.HelloRetryRequestUnsupported,
        .legacy_version => return error.UnsupportedTlsVersion,
        .alert => |a| return alertToError(a),
    };

    // The key schedule is SHA-256 / AES-128-GCM only (server_cipher_prefs). negotiate() cannot
    // pick another suite, this guards that invariant.
    if (negotiated.cipher != .AES_128_GCM_SHA256) return error.UnsupportedCipher;

    // ALPN: select one protocol when the server has prefs and the client offered a list.
    // A client offer with no overlap is the no_application_protocol condition (RFC 7301 3.2).
    var selected_alpn: ?extensions.Alpn = null;
    if (opts.alpn_prefs.len > 0) {
        if (hello.alpn) |client_alpn| {
            selected_alpn = extensions.negotiateAlpn(client_alpn, opts.alpn_prefs) orelse return error.NoApplicationProtocol;
        }
    }

    const client_share = switch (negotiated.group) {
        .X25519 => hello.x25519_share orelse return error.MissingKeyShare,
        .SECP256R1 => hello.secp256r1_share orelse return error.MissingKeyShare,
        else => return error.UnsupportedGroup,
    };
    const kex = try computeKeyExchange(negotiated.group, opts.ephemeral_secret, client_share);
    const ecdhe = kex.shared;

    var transcript = key_schedule.Transcript.init();
    transcript.update(client_hello);

    var writer = wire.Writer{ .buf = out };

    // ServerHello as a plaintext handshake record.
    const server_hello = handshake.serializeServerHello(writer.buf[writer.len + 5 ..], &opts.server_random, hello.session_id, .{
        .cipher = negotiated.cipher,
        .group = negotiated.group,
        .key_exchange = kex.server_public[0..kex.server_public_len],
    });
    transcript.update(server_hello);
    writeRecordHeader(&writer, 22, server_hello.len);
    writer.len += server_hello.len;

    writer.writeBytes(&ccs_record);

    // handshake key schedule from the transcript through ServerHello.
    const zero = std.mem.zeroes(Secret);
    const empty_hash = key_schedule.Transcript.init().current();
    const early = key_schedule.HkdfSha256.extract(&zero, &zero);
    const derived = key_schedule.deriveSecret(early, "derived", empty_hash);
    const handshake_secret = key_schedule.HkdfSha256.extract(&derived, &ecdhe);

    const transcript_ch_sh = transcript.current();
    const server_hs_traffic = key_schedule.deriveSecret(handshake_secret, "s hs traffic", transcript_ch_sh);
    const client_hs_traffic = key_schedule.deriveSecret(handshake_secret, "c hs traffic", transcript_ch_sh);

    var server_hs_key: [16]u8 = undefined;
    var server_hs_iv: [12]u8 = undefined;
    var connection: Connection = undefined;
    key_schedule.expandLabel(&server_hs_key, server_hs_traffic, "key", "");
    key_schedule.expandLabel(&server_hs_iv, server_hs_traffic, "iv", "");
    key_schedule.expandLabel(&connection.client_hs_key, client_hs_traffic, "key", "");
    key_schedule.expandLabel(&connection.client_hs_iv, client_hs_traffic, "iv", "");
    connection.client_finished_key = certificate.finishedKey(client_hs_traffic);
    const server_finished_key = certificate.finishedKey(server_hs_traffic);

    // build the flight: EncryptedExtensions, Certificate, CertificateVerify, Finished.
    var flight_buf: [4096]u8 = undefined;
    var flight = wire.Writer{ .buf = &flight_buf };

    const ee = extensions.buildEncryptedExtensions(flight.buf[flight.len..], .{ .alpn_selected = selected_alpn });
    flight.len += ee.len;
    transcript.update(ee);

    const cert_msg = certificate.buildCertificate(flight.buf[flight.len..], opts.certificate_der);
    flight.len += cert_msg.len;
    transcript.update(cert_msg);

    const cert_verify = try certificate.buildCertificateVerify(flight.buf[flight.len..], opts.signing_key, transcript.current());
    flight.len += cert_verify.len;
    transcript.update(cert_verify);

    const finished = certificate.buildFinished(flight.buf[flight.len..], server_finished_key, transcript.current());
    flight.len += finished.len;
    transcript.update(finished);

    const flight_record = record.protect(writer.buf[writer.len..], flight.slice(), .HANDSHAKE, server_hs_key, server_hs_iv, 0);
    writer.len += flight_record.len;

    // application key schedule from the transcript through the server Finished.
    connection.transcript_through_server_finished = transcript.current();
    const derived_master = key_schedule.deriveSecret(handshake_secret, "derived", empty_hash);
    const master = key_schedule.HkdfSha256.extract(&derived_master, &zero);
    const server_ap_traffic = key_schedule.deriveSecret(master, "s ap traffic", connection.transcript_through_server_finished);
    const client_ap_traffic = key_schedule.deriveSecret(master, "c ap traffic", connection.transcript_through_server_finished);
    key_schedule.expandLabel(&connection.server_app_key, server_ap_traffic, "key", "");
    key_schedule.expandLabel(&connection.server_app_iv, server_ap_traffic, "iv", "");
    key_schedule.expandLabel(&connection.client_app_key, client_ap_traffic, "key", "");
    key_schedule.expandLabel(&connection.client_app_iv, client_ap_traffic, "iv", "");
    connection.server_app_seq = 0;
    connection.client_app_seq = 0;

    return .{ .connection = connection, .to_send = writer.slice(), .alpn = selected_alpn };
}

fn writeRecordHeader(writer: *wire.Writer, content_type: u8, length: usize) void {
    writer.writeU8(content_type);
    writer.writeU16(0x0303);
    writer.writeU16(@intCast(length));
}

/// The ephemeral ECDHE result for one handshake: the server public to put in the ServerHello
/// key_share (32 bytes for X25519, 65 for secp256r1 uncompressed) and the 32-byte shared secret.
const KeyExchange = struct {
    server_public: [65]u8,
    server_public_len: usize,
    shared: [32]u8,
};

/// Run the server side of ECDHE for the negotiated group (RFC 8446 7.4, 8422). The ephemeral
/// secret is injected (fresh per connection in production, a trace value in tests). For secp256r1
/// the shared secret is the X coordinate of the shared point (RFC 8446 7.4.2).
fn computeKeyExchange(group: NamedGroup, ephemeral_secret: [32]u8, client_public: []const u8) !KeyExchange {
    switch (group) {
        .X25519 => {
            if (client_public.len != 32) return error.BadKeyShare;

            var client_pub: [32]u8 = undefined;
            @memcpy(&client_pub, client_public);
            const server_public = try X25519.recoverPublicKey(ephemeral_secret);
            const shared = try X25519.scalarmult(ephemeral_secret, client_pub);

            var kex = KeyExchange{ .server_public = undefined, .server_public_len = 32, .shared = shared };
            @memcpy(kex.server_public[0..32], &server_public);

            return kex;
        },
        .SECP256R1 => {
            const scalar = reduceP256Scalar(ephemeral_secret);
            const server_point = try P256.basePoint.mul(scalar, .big);
            const client_point = try P256.fromSec1(client_public);
            const shared_point = try client_point.mul(scalar, .big);

            return .{
                .server_public = server_point.toUncompressedSec1(),
                .server_public_len = 65,
                .shared = shared_point.affineCoordinates().x.toBytes(.big),
            };
        },
        else => return error.UnsupportedGroup,
    }
}

/// Reduce 32 random bytes to a valid (non-zero, in-range) P-256 scalar. fromBytes48 reduces mod n,
/// so a zero-extended 256-bit seed maps uniformly enough for an ephemeral key.
fn reduceP256Scalar(seed: [32]u8) [32]u8 {
    var wide: [48]u8 = std.mem.zeroes([48]u8);
    @memcpy(wide[16..48], &seed);

    return P256.scalar.Scalar.fromBytes48(wide, .big).toBytes(.big);
}

/// Map a negotiation / parse alert to the error the caller surfaces. Sending the actual alert
/// record to the peer is Layer A (RFC 8446 sec 6), tracked separately.
fn alertToError(a: alert.Alert) anyerror {
    return switch (a) {
        .MISSING_EXTENSION => error.MissingExtension,
        .HANDSHAKE_FAILURE => error.HandshakeFailure,
        .ILLEGAL_PARAMETER => error.IllegalParameter,
        .DECODE_ERROR => error.DecodeError,
        else => error.HandshakeFailure,
    };
}

// --------------------------------------------------------------- //
// --------------------------------------------------------------- //

test "zix test: connection, server flight from RFC 8448 ClientHello" {
    var client_hello: [196]u8 = undefined;
    _ = try std.fmt.hexToBytes(&client_hello, "010000c00303cb34ecb1e78163ba1c38c6dacb196a6dffa21a8d9912ec18a2ef6283024dece7000006130113031302010000910000000b0009000006736572766572ff01000100000a00140012001d0017001800190100010101020103010400230000003300260024001d002099381de560e4bd43d23d8e435a7dbafeb3c06e51c13cae4d5413691e529aaf2c002b0003020304000d0020001e040305030603020308040805080604010501060102010402050206020202002d00020101001c00024001");

    var server_hello: [90]u8 = undefined;
    _ = try std.fmt.hexToBytes(&server_hello, "020000560303a6af06a4121860dc5e6e60249cd34c95930c8ac5cb1434dac155772ed3e2692800130100002e00330024001d0020c9828876112095fe66762bdbf7c672e156d6cc253b833df1dd69b1b04e751f0f002b00020304");

    var ephemeral_secret: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&ephemeral_secret, "b1580eeadf6dd589b8ef4f2d5652578cc810e9980191ec8d058308cea216a21e");
    var server_random: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&server_random, "a6af06a4121860dc5e6e60249cd34c95930c8ac5cb1434dac155772ed3e26928");
    var scalar: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&scalar, "0b76f7f1c7bf6e20029ddb566795e58da5ba63ffbdb914bf699bfbed3147d32c");
    const key_pair = try EcdsaP256.KeyPair.fromSecretKey(try EcdsaP256.SecretKey.fromBytes(scalar));

    const dummy_der = [_]u8{ 0x30, 0x03, 0x01, 0x02, 0x03 };

    var out: [4096]u8 = undefined;
    const result = try serverHandshake(.{
        .certificate_der = &dummy_der,
        .signing_key = key_pair,
        .ephemeral_secret = ephemeral_secret,
        .server_random = server_random,
    }, &client_hello, &out);

    // record 1: ServerHello plaintext handshake record, byte-exact vs the trace.
    var r = wire.Reader{ .buf = result.to_send };
    try std.testing.expectEqual(@as(u8, 22), try r.readU8());
    _ = try r.readU16();
    const sh_len = try r.readU16();
    try std.testing.expectEqualSlices(u8, &server_hello, try r.readBytes(sh_len));

    // record 2: legacy ChangeCipherSpec.
    try std.testing.expectEqual(@as(u8, 20), try r.readU8());
    _ = try r.readU16();
    const ccs_len = try r.readU16();
    try std.testing.expectEqualSlices(u8, &[_]u8{0x01}, try r.readBytes(ccs_len));

    // record 3: encrypted flight. With trace inputs the server handshake key is the trace key, so
    // deprotect it and confirm the inner handshake messages are EE, Certificate, CertVerify, Finished.
    try std.testing.expectEqual(@as(u8, 23), try r.readU8());
    _ = try r.readU16();
    const flight_len = try r.readU16();
    const flight_record = result.to_send[r.pos - 5 .. r.pos + flight_len];

    var hs_key: [16]u8 = undefined;
    _ = try std.fmt.hexToBytes(&hs_key, "3fce516009c21727d0f2e4e86ee403bc");
    var hs_iv: [12]u8 = undefined;
    _ = try std.fmt.hexToBytes(&hs_iv, "5d313eb2671276ee13000b30");

    var plain: [4096]u8 = undefined;
    const opened = try record.deprotect(&plain, flight_record, hs_key, hs_iv, 0);
    try std.testing.expectEqual(record.ContentType.HANDSHAKE, opened.inner_type);

    var fr = wire.Reader{ .buf = opened.data };
    const expected_types = [_]u8{ 8, 11, 15, 20 };
    for (expected_types) |want| {
        try std.testing.expectEqual(want, try fr.readU8());
        const len = try fr.readU24();
        _ = try fr.readBytes(len);
    }
    try std.testing.expectEqual(@as(usize, 0), fr.remaining());
}

test "zix test: connection, secp256r1 ECDHE shared secret is symmetric" {
    var a_seed: [32]u8 = undefined;
    var b_seed: [32]u8 = undefined;
    @memset(&a_seed, 0x11);
    @memset(&b_seed, 0x22);

    // b's public, then a derives ECDH(a, b_pub); b derives ECDH(b, a_pub); both must match.
    const b_point = try P256.basePoint.mul(reduceP256Scalar(b_seed), .big);
    const b_pub = b_point.toUncompressedSec1();
    const kex_a = try computeKeyExchange(.SECP256R1, a_seed, &b_pub);
    const kex_b = try computeKeyExchange(.SECP256R1, b_seed, kex_a.server_public[0..kex_a.server_public_len]);

    try std.testing.expectEqual(@as(usize, 65), kex_a.server_public_len);
    try std.testing.expectEqualSlices(u8, &kex_a.shared, &kex_b.shared);
}

test "zix test: connection, serverHandshake negotiates secp256r1 from a P-256-only ClientHello" {
    // a valid client secp256r1 key_share (a real point on the curve).
    var client_seed: [32]u8 = undefined;
    @memset(&client_seed, 0x33);
    const client_point = try P256.basePoint.mul(reduceP256Scalar(client_seed), .big);
    const client_pub = client_point.toUncompressedSec1();

    // ClientHello offering ONLY secp256r1 (group + key_share), plus the mandatory extensions.
    var ch_buf: [512]u8 = undefined;
    var w = wire.Writer{ .buf = &ch_buf };
    w.writeU8(@intFromEnum(handshake.HandshakeType.CLIENT_HELLO));
    const ch_header = w.placeU24();
    w.writeU16(handshake.VERSION_TLS_1_2);
    w.writeBytes(&std.mem.zeroes([32]u8)); // random
    w.writeU8(0); // empty session_id
    w.writeU16(2); // cipher_suites length
    w.writeU16(@intFromEnum(handshake.CipherSuite.AES_128_GCM_SHA256));
    w.writeU8(1); // compression length
    w.writeU8(0); // null compression

    const exts = w.placeU16();
    // supported_versions: [0x0304]
    w.writeU16(@intFromEnum(handshake.ExtensionType.SUPPORTED_VERSIONS));
    w.writeU16(3);
    w.writeU8(2);
    w.writeU16(handshake.VERSION_TLS_1_3);
    // signature_algorithms: [ecdsa_secp256r1_sha256] (presence is what negotiate checks)
    w.writeU16(@intFromEnum(handshake.ExtensionType.SIGNATURE_ALGORITHMS));
    w.writeU16(4);
    w.writeU16(2);
    w.writeU16(@intFromEnum(handshake.SignatureScheme.ECDSA_SECP256R1_SHA256));
    // supported_groups: [secp256r1]
    w.writeU16(@intFromEnum(handshake.ExtensionType.SUPPORTED_GROUPS));
    w.writeU16(4);
    w.writeU16(2);
    w.writeU16(@intFromEnum(handshake.NamedGroup.SECP256R1));
    // key_share: secp256r1 -> the 65-byte uncompressed point
    w.writeU16(@intFromEnum(handshake.ExtensionType.KEY_SHARE));
    const ks_ext = w.placeU16();
    const ks_list = w.placeU16();
    w.writeU16(@intFromEnum(handshake.NamedGroup.SECP256R1));
    w.writeU16(@intCast(client_pub.len));
    w.writeBytes(&client_pub);
    w.patchU16(ks_list);
    w.patchU16(ks_ext);
    w.patchU16(exts);
    w.patchU24(ch_header);

    var ephemeral_secret: [32]u8 = undefined;
    @memset(&ephemeral_secret, 0x44);
    var server_random: [32]u8 = undefined;
    @memset(&server_random, 0x55);
    var scalar: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&scalar, "0b76f7f1c7bf6e20029ddb566795e58da5ba63ffbdb914bf699bfbed3147d32c");
    const key_pair = try EcdsaP256.KeyPair.fromSecretKey(try EcdsaP256.SecretKey.fromBytes(scalar));
    const dummy_der = [_]u8{ 0x30, 0x03, 0x01, 0x02, 0x03 };

    var out: [4096]u8 = undefined;
    const result = try serverHandshake(.{
        .certificate_der = &dummy_der,
        .signing_key = key_pair,
        .ephemeral_secret = ephemeral_secret,
        .server_random = server_random,
    }, w.slice(), &out);

    // the ServerHello key_share must echo secp256r1 with a 65-byte uncompressed (0x04) point.
    var r = wire.Reader{ .buf = result.to_send };
    try std.testing.expectEqual(@as(u8, 22), try r.readU8());
    _ = try r.readU16();
    const sh_len = try r.readU16();
    const sh = try r.readBytes(sh_len);

    var hr = wire.Reader{ .buf = sh };
    _ = try hr.readU8(); // server_hello type
    _ = try hr.readU24();
    _ = try hr.readU16(); // legacy_version
    _ = try hr.readBytes(32); // random
    const sid_len = try hr.readU8();
    _ = try hr.readBytes(sid_len);
    _ = try hr.readU16(); // cipher
    _ = try hr.readU8(); // compression
    const sh_ext_len = try hr.readU16();
    const sh_exts = try hr.readBytes(sh_ext_len);

    var er = wire.Reader{ .buf = sh_exts };
    var found_key_share = false;
    while (er.remaining() >= 4) {
        const ext_type = try er.readU16();
        const ext_len = try er.readU16();
        const ext_data = try er.readBytes(ext_len);
        if (ext_type == @intFromEnum(handshake.ExtensionType.KEY_SHARE)) {
            var kr = wire.Reader{ .buf = ext_data };
            try std.testing.expectEqual(@intFromEnum(handshake.NamedGroup.SECP256R1), try kr.readU16());
            const ke_len = try kr.readU16();
            const ke = try kr.readBytes(ke_len);
            try std.testing.expectEqual(@as(usize, 65), ke.len);
            try std.testing.expectEqual(@as(u8, 0x04), ke[0]);
            found_key_share = true;
        }
    }
    try std.testing.expect(found_key_share);
}
