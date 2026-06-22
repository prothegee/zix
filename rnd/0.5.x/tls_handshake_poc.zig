//! TLS 1.3 Layer H PoC (RFC 8446 sec 4), the handshake-flow + version-negotiation step for the
//! zix TLS 1.3 server handshake (tls-plan.md, Layer H, follows Layer K).
//!
//! Note:
//! - This proves the handshake-message layer, not the crypto (that is Layer K). It parses the
//!   real RFC 8448 ClientHello, runs version / cipher / group negotiation, serializes a
//!   ServerHello, and verifies that ServerHello is byte-for-byte the one in the trace. The
//!   RFC 8448 "Simple 1-RTT Handshake" is the deterministic oracle, the same one Layer K uses.
//! - Byte-exactness holds because the only non-deterministic ServerHello inputs (the server
//!   random and the server key_share public) are taken from the trace, so a correct serializer
//!   reproduces the wire bytes exactly.
//! - It also walks the encrypted server flight (the 657-octet EncryptedExtensions .. Finished
//!   block, recovered in Layer K) and asserts the mandated message order (8446 4.4).
//! - The negative MUST / MUST NOT cases are driven by a small ClientHello builder: a non-zero
//!   compression method (illegal_parameter), no 0x0304 in supported_versions (no TLS 1.3, the
//!   downgrade path), no cipher or group overlap (handshake_failure), a selected group with no
//!   key_share (HelloRetryRequest), and a non-PSK ClientHello missing signature_algorithms or
//!   supported_groups (missing_extension, 8446 9.2).
//! - The HelloRetryRequest special random (SHA-256 of "HelloRetryRequest", 8446 4.1.3) and the
//!   TLS 1.2 / lower downgrade sentinels (8446 4.1.3) are checked against their RFC constants.
//!
//! Run: zig run rnd/0.5.x/tls_handshake_poc.zig

const std = @import("std");

const Sha256 = std.crypto.hash.sha2.Sha256;

// --------------------------------------------------------------- //
// constants: handshake + extension + algorithm identifiers (RFC 8446 sec 4, IANA registries).

const HandshakeType = struct {
    const client_hello: u8 = 1;
    const server_hello: u8 = 2;
    const encrypted_extensions: u8 = 8;
    const certificate: u8 = 11;
    const certificate_verify: u8 = 15;
    const finished: u8 = 20;
};

const ExtensionType = struct {
    const server_name: u16 = 0x0000;
    const supported_groups: u16 = 0x000a;
    const signature_algorithms: u16 = 0x000d;
    const supported_versions: u16 = 0x002b;
    const key_share: u16 = 0x0033;
};

const CipherSuite = struct {
    const aes_128_gcm_sha256: u16 = 0x1301;
    const aes_256_gcm_sha384: u16 = 0x1302;
    const chacha20_poly1305_sha256: u16 = 0x1303;
};

const NamedGroup = struct {
    const x25519: u16 = 0x001d;
    const secp256r1: u16 = 0x0017;
    const ffdhe2048: u16 = 0x0100;
};

const tls13: u16 = 0x0304;
const tls12: u16 = 0x0303;

/// Server crypto preference order. Mandatory-to-implement first (8446 9.1).
const server_cipher_prefs = [_]u16{ CipherSuite.aes_128_gcm_sha256, CipherSuite.aes_256_gcm_sha384, CipherSuite.chacha20_poly1305_sha256 };
const server_group_prefs = [_]u16{ NamedGroup.x25519, NamedGroup.secp256r1 };

/// Fatal alert descriptions used here (8446 sec 6).
const Alert = enum(u8) {
    unexpected_message = 10,
    handshake_failure = 40,
    illegal_parameter = 47,
    protocol_version = 70,
    decode_error = 50,
    missing_extension = 109,
};

/// The HelloRetryRequest ServerHello.random, the SHA-256 of "HelloRetryRequest" (8446 4.1.3).
const want_hrr_random = "cf 21 ad 74 e5 9a 61 11 be 1d 8c 02 1e 65 b8 91 c2 a2 11 16 7a bb 8c 5e 07 9e 09 e2 c8 a8 33 9c";

/// Downgrade sentinels for ServerHello.random when a 1.3-capable server negotiates lower (8446 4.1.3).
const downgrade_tls12 = "44 4f 57 4e 47 52 44 01";
const downgrade_below = "44 4f 57 4e 47 52 44 00";

// --------------------------------------------------------------- //
// vectors: the RFC 8448 sec 3 ClientHello, ServerHello, server flight, and the derived parts.

const client_hello = hx(
    \\01 00 00 c0 03 03 cb 34 ec b1 e7 81 63 ba 1c 38 c6 da cb 19 6a 6d ff a2 1a 8d 99 12 ec 18 a2 ef 62 83 02 4d ec e7
    \\00 00 06 13 01 13 03 13 02 01 00 00 91 00 00 00 0b 00 09 00 00 06 73 65 72 76 65 72 ff 01 00 01 00 00 0a 00 14 00
    \\12 00 1d 00 17 00 18 00 19 01 00 01 01 01 02 01 03 01 04 00 23 00 00 00 33 00 26 00 24 00 1d 00 20 99 38 1d e5 60
    \\e4 bd 43 d2 3d 8e 43 5a 7d ba fe b3 c0 6e 51 c1 3c ae 4d 54 13 69 1e 52 9a af 2c 00 2b 00 03 02 03 04 00 0d 00 20
    \\00 1e 04 03 05 03 06 03 02 03 08 04 08 05 08 06 04 01 05 01 06 01 02 01 04 02 05 02 06 02 02 02 00 2d 00 02 01 01
    \\00 1c 00 02 40 01
);

const server_hello = hx(
    \\02 00 00 56 03 03 a6 af 06 a4 12 18 60 dc 5e 6e 60 24 9c d3 4c 95 93 0c 8a c5 cb 14 34 da c1 55 77 2e d3 e2 69 28
    \\00 13 01 00 00 2e 00 33 00 24 00 1d 00 20 c9 82 88 76 11 20 95 fe 66 76 2b db f7 c6 72 e1 56 d6 cc 25 3b 83 3d f1
    \\dd 69 b1 b0 4e 75 1f 0f 00 2b 00 02 03 04
);

/// The decrypted server flight (EncryptedExtensions, Certificate, CertificateVerify, Finished).
const server_flight = hx(
    \\08 00 00 24 00 22 00 0a 00 14 00 12 00 1d 00 17 00 18 00 19 01 00 01 01 01 02 01 03 01 04 00 1c 00 02 40 01 00 00
    \\00 00 0b 00 01 b9 00 00 01 b5 00 01 b0 30 82 01 ac 30 82 01 15 a0 03 02 01 02 02 01 02 30 0d 06 09 2a 86 48 86 f7
    \\0d 01 01 0b 05 00 30 0e 31 0c 30 0a 06 03 55 04 03 13 03 72 73 61 30 1e 17 0d 31 36 30 37 33 30 30 31 32 33 35 39
    \\5a 17 0d 32 36 30 37 33 30 30 31 32 33 35 39 5a 30 0e 31 0c 30 0a 06 03 55 04 03 13 03 72 73 61 30 81 9f 30 0d 06
    \\09 2a 86 48 86 f7 0d 01 01 01 05 00 03 81 8d 00 30 81 89 02 81 81 00 b4 bb 49 8f 82 79 30 3d 98 08 36 39 9b 36 c6
    \\98 8c 0c 68 de 55 e1 bd b8 26 d3 90 1a 24 61 ea fd 2d e4 9a 91 d0 15 ab bc 9a 95 13 7a ce 6c 1a f1 9e aa 6a f9 8c
    \\7c ed 43 12 09 98 e1 87 a8 0e e0 cc b0 52 4b 1b 01 8c 3e 0b 63 26 4d 44 9a 6d 38 e2 2a 5f da 43 08 46 74 80 30 53
    \\0e f0 46 1c 8c a9 d9 ef bf ae 8e a6 d1 d0 3e 2b d1 93 ef f0 ab 9a 80 02 c4 74 28 a6 d3 5a 8d 88 d7 9f 7f 1e 3f 02
    \\03 01 00 01 a3 1a 30 18 30 09 06 03 55 1d 13 04 02 30 00 30 0b 06 03 55 1d 0f 04 04 03 02 05 a0 30 0d 06 09 2a 86
    \\48 86 f7 0d 01 01 0b 05 00 03 81 81 00 85 aa d2 a0 e5 b9 27 6b 90 8c 65 f7 3a 72 67 17 06 18 a5 4c 5f 8a 7b 33 7d
    \\2d f7 a5 94 36 54 17 f2 ea e8 f8 a5 8c 8f 81 72 f9 31 9c f3 6b 7f d6 c5 5b 80 f2 1a 03 01 51 56 72 60 96 fd 33 5e
    \\5e 67 f2 db f1 02 70 2e 60 8c ca e6 be c1 fc 63 a4 2a 99 be 5c 3e b7 10 7c 3c 54 e9 b9 eb 2b d5 20 3b 1c 3b 84 e0
    \\a8 b2 f7 59 40 9b a3 ea c9 d9 1d 40 2d cc 0c c8 f8 96 12 29 ac 91 87 b4 2b 4d e1 00 00 0f 00 00 84 08 04 00 80 5a
    \\74 7c 5d 88 fa 9b d2 e5 5a b0 85 a6 10 15 b7 21 1f 82 4c d4 84 14 5a b3 ff 52 f1 fd a8 47 7b 0b 7a bc 90 db 78 e2
    \\d3 3a 5c 14 1a 07 86 53 fa 6b ef 78 0c 5e a2 48 ee aa a7 85 c4 f3 94 ca b6 d3 0b be 8d 48 59 ee 51 1f 60 29 57 b1
    \\54 11 ac 02 76 71 45 9e 46 44 5c 9e a5 8c 18 1e 81 8e 95 b8 c3 fb 0b f3 27 84 09 d3 be 15 2a 3d a5 04 3e 06 3d da
    \\65 cd f5 ae a2 0d 53 df ac d4 2f 74 f3 14 00 00 20 9b 9b 14 1d 90 63 37 fb d2 cb dc e7 1d f4 de da 4a b4 2c 30 95
    \\72 cb 7f ff ee 54 54 b7 8f 07 18
);

/// The server ephemeral x25519 public (the ServerHello key_share) and random, from the trace.
const server_x25519_public = hx("c9 82 88 76 11 20 95 fe 66 76 2b db f7 c6 72 e1 56 d6 cc 25 3b 83 3d f1 dd 69 b1 b0 4e 75 1f 0f");
const server_random = hx("a6 af 06 a4 12 18 60 dc 5e 6e 60 24 9c d3 4c 95 93 0c 8a c5 cb 14 34 da c1 55 77 2e d3 e2 69 28");

const want_client_share = "99 38 1d e5 60 e4 bd 43 d2 3d 8e 43 5a 7d ba fe b3 c0 6e 51 c1 3c ae 4d 54 13 69 1e 52 9a af 2c";
const want_client_random = "cb 34 ec b1 e7 81 63 ba 1c 38 c6 da cb 19 6a 6d ff a2 1a 8d 99 12 ec 18 a2 ef 62 83 02 4d ec e7";

// --------------------------------------------------------------- //
// reader: a bounds-checked cursor over a byte slice (TLS wire decode).

const DecodeError = error{Truncated};

const Reader = struct {
    buf: []const u8,
    pos: usize = 0,

    fn readU8(self: *Reader) DecodeError!u8 {
        if (self.pos + 1 > self.buf.len) return error.Truncated;

        const value = self.buf[self.pos];
        self.pos += 1;

        return value;
    }

    fn readU16(self: *Reader) DecodeError!u16 {
        if (self.pos + 2 > self.buf.len) return error.Truncated;

        const value = std.mem.readInt(u16, self.buf[self.pos..][0..2], .big);
        self.pos += 2;

        return value;
    }

    fn readU24(self: *Reader) DecodeError!u32 {
        if (self.pos + 3 > self.buf.len) return error.Truncated;

        const b = self.buf[self.pos..][0..3];
        self.pos += 3;

        return (@as(u32, b[0]) << 16) | (@as(u32, b[1]) << 8) | b[2];
    }

    fn readBytes(self: *Reader, n: usize) DecodeError![]const u8 {
        if (self.pos + n > self.buf.len) return error.Truncated;

        const slice = self.buf[self.pos .. self.pos + n];
        self.pos += n;

        return slice;
    }

    fn remaining(self: *const Reader) usize {
        return self.buf.len - self.pos;
    }
};

// --------------------------------------------------------------- //
// writer: append into a caller buffer with deferred length patching (TLS wire encode).

const Writer = struct {
    buf: []u8,
    len: usize = 0,

    fn writeU8(self: *Writer, value: u8) void {
        self.buf[self.len] = value;
        self.len += 1;
    }

    fn writeU16(self: *Writer, value: u16) void {
        std.mem.writeInt(u16, self.buf[self.len..][0..2], value, .big);
        self.len += 2;
    }

    fn writeU24(self: *Writer, value: u32) void {
        self.buf[self.len] = @intCast((value >> 16) & 0xff);
        self.buf[self.len + 1] = @intCast((value >> 8) & 0xff);
        self.buf[self.len + 2] = @intCast(value & 0xff);
        self.len += 3;
    }

    fn writeBytes(self: *Writer, bytes: []const u8) void {
        @memcpy(self.buf[self.len .. self.len + bytes.len], bytes);
        self.len += bytes.len;
    }

    /// Reserve a u16 length field, returning its index to patch once the body is written.
    fn placeU16(self: *Writer) usize {
        const marker = self.len;
        self.writeU16(0);

        return marker;
    }

    fn patchU16(self: *Writer, marker: usize) void {
        std.mem.writeInt(u16, self.buf[marker..][0..2], @intCast(self.len - marker - 2), .big);
    }

    /// Reserve a u24 length field (the handshake-message header length).
    fn placeU24(self: *Writer) usize {
        const marker = self.len;
        self.writeU24(0);

        return marker;
    }

    fn patchU24(self: *Writer, marker: usize) void {
        const value: u32 = @intCast(self.len - marker - 3);
        self.buf[marker] = @intCast((value >> 16) & 0xff);
        self.buf[marker + 1] = @intCast((value >> 8) & 0xff);
        self.buf[marker + 2] = @intCast(value & 0xff);
    }

    fn slice(self: *const Writer) []const u8 {
        return self.buf[0..self.len];
    }
};

// --------------------------------------------------------------- //
// parse: ClientHello -> fields + extension presence (8446 4.1.2).

const ParseError = error{ Truncated, IllegalParameter };

const ClientHello = struct {
    legacy_version: u16,
    random: [32]u8,
    session_id: []const u8,
    cipher_suites: []const u8,
    offers_tls13: bool = false,
    has_signature_algorithms: bool = false,
    has_supported_groups: bool = false,
    supported_groups: []const u8 = &.{},
    key_share_groups: [16]u16 = undefined,
    key_share_count: usize = 0,
    x25519_share: ?[]const u8 = null,
    sni: ?[]const u8 = null,

    fn offersGroup(self: *const ClientHello, group: u16) bool {
        var r = Reader{ .buf = self.supported_groups };
        while (r.remaining() >= 2) {
            const g = r.readU16() catch return false;
            if (g == group) return true;
        }

        return false;
    }

    fn hasKeyShare(self: *const ClientHello, group: u16) bool {
        for (self.key_share_groups[0..self.key_share_count]) |g| {
            if (g == group) return true;
        }

        return false;
    }

    fn offersCipher(self: *const ClientHello, suite: u16) bool {
        var r = Reader{ .buf = self.cipher_suites };
        while (r.remaining() >= 2) {
            const c = r.readU16() catch return false;
            if (c == suite) return true;
        }

        return false;
    }
};

const ParseResult = union(enum) {
    ok: ClientHello,
    alert: Alert,
};

fn parseClientHello(bytes: []const u8) ParseResult {
    const ch = parseClientHelloInner(bytes) catch |err| return .{ .alert = switch (err) {
        error.IllegalParameter => .illegal_parameter,
        error.Truncated => .decode_error,
    } };

    return .{ .ok = ch };
}

fn parseClientHelloInner(bytes: []const u8) ParseError!ClientHello {
    var r = Reader{ .buf = bytes };

    if (try r.readU8() != HandshakeType.client_hello) return error.IllegalParameter;
    _ = try r.readU24();

    const legacy_version = try r.readU16();
    const random = try r.readBytes(32);
    const session_id_len = try r.readU8();
    const session_id = try r.readBytes(session_id_len);

    const cipher_suites_len = try r.readU16();
    const cipher_suites = try r.readBytes(cipher_suites_len);

    const compression_len = try r.readU8();
    const compression = try r.readBytes(compression_len);
    if (compression_len != 1 or compression[0] != 0) return error.IllegalParameter;

    var ch = ClientHello{
        .legacy_version = legacy_version,
        .random = undefined,
        .session_id = session_id,
        .cipher_suites = cipher_suites,
    };
    @memcpy(&ch.random, random);

    const extensions_len = try r.readU16();
    const extensions = try r.readBytes(extensions_len);
    try parseClientExtensions(&ch, extensions);

    return ch;
}

fn parseClientExtensions(ch: *ClientHello, extensions: []const u8) ParseError!void {
    var r = Reader{ .buf = extensions };
    while (r.remaining() >= 4) {
        const ext_type = try r.readU16();
        const ext_len = try r.readU16();
        const ext_data = try r.readBytes(ext_len);

        switch (ext_type) {
            ExtensionType.supported_versions => {
                var er = Reader{ .buf = ext_data };
                const list_len = try er.readU8();
                const list = try er.readBytes(list_len);
                var lr = Reader{ .buf = list };
                while (lr.remaining() >= 2) {
                    if (try lr.readU16() == tls13) ch.offers_tls13 = true;
                }
            },
            ExtensionType.supported_groups => {
                ch.has_supported_groups = true;
                var er = Reader{ .buf = ext_data };
                const list_len = try er.readU16();
                ch.supported_groups = try er.readBytes(list_len);
            },
            ExtensionType.signature_algorithms => ch.has_signature_algorithms = true,
            ExtensionType.key_share => try parseKeyShare(ch, ext_data),
            ExtensionType.server_name => {
                var er = Reader{ .buf = ext_data };
                _ = try er.readU16();
                _ = try er.readU8();
                const name_len = try er.readU16();
                ch.sni = try er.readBytes(name_len);
            },
            else => {},
        }
    }
}

fn parseKeyShare(ch: *ClientHello, ext_data: []const u8) ParseError!void {
    var er = Reader{ .buf = ext_data };
    const shares_len = try er.readU16();
    const shares = try er.readBytes(shares_len);

    var sr = Reader{ .buf = shares };
    while (sr.remaining() >= 4) {
        const group = try sr.readU16();
        const ke_len = try sr.readU16();
        const ke = try sr.readBytes(ke_len);

        if (ch.key_share_count < ch.key_share_groups.len) {
            ch.key_share_groups[ch.key_share_count] = group;
            ch.key_share_count += 1;
        }
        if (group == NamedGroup.x25519) ch.x25519_share = ke;
    }
}

// --------------------------------------------------------------- //
// negotiate: version, cipher, group selection (8446 4.1.1, 4.2.1, 9.1).

const ServerHelloParams = struct {
    cipher: u16,
    group: u16,
    key_exchange: []const u8,
};

const Outcome = union(enum) {
    server_hello: ServerHelloParams,
    hello_retry_request: u16,
    legacy_version,
    alert: Alert,
};

fn negotiate(ch: *const ClientHello, key_exchange: []const u8) Outcome {
    if (!ch.offers_tls13) return .legacy_version;

    if (!ch.has_signature_algorithms or !ch.has_supported_groups) return .{ .alert = .missing_extension };

    const cipher = pickCipher(ch) orelse return .{ .alert = .handshake_failure };
    const group = pickGroup(ch) orelse return .{ .alert = .handshake_failure };

    if (!ch.hasKeyShare(group)) return .{ .hello_retry_request = group };

    return .{ .server_hello = .{ .cipher = cipher, .group = group, .key_exchange = key_exchange } };
}

fn pickCipher(ch: *const ClientHello) ?u16 {
    for (server_cipher_prefs) |suite| {
        if (ch.offersCipher(suite)) return suite;
    }

    return null;
}

fn pickGroup(ch: *const ClientHello) ?u16 {
    for (server_group_prefs) |group| {
        if (ch.offersGroup(group)) return group;
    }

    return null;
}

// --------------------------------------------------------------- //
// serialize: ServerHello (8446 4.1.3).

fn serializeServerHello(buf: []u8, random: []const u8, session_id: []const u8, params: ServerHelloParams) []const u8 {
    var w = Writer{ .buf = buf };

    w.writeU8(HandshakeType.server_hello);
    const header = w.placeU24();

    w.writeU16(tls12);
    w.writeBytes(random);
    w.writeU8(@intCast(session_id.len));
    w.writeBytes(session_id);
    w.writeU16(params.cipher);
    w.writeU8(0);

    const extensions = w.placeU16();

    w.writeU16(ExtensionType.key_share);
    const key_share = w.placeU16();
    w.writeU16(params.group);
    const key_exchange = w.placeU16();
    w.writeBytes(params.key_exchange);
    w.patchU16(key_exchange);
    w.patchU16(key_share);

    w.writeU16(ExtensionType.supported_versions);
    const supported_versions = w.placeU16();
    w.writeU16(tls13);
    w.patchU16(supported_versions);

    w.patchU16(extensions);
    w.patchU24(header);

    return w.slice();
}

// --------------------------------------------------------------- //
// builder: assemble a ClientHello for the negative MUST cases.

const BuildOptions = struct {
    versions: []const u16 = &.{tls13},
    ciphers: []const u16 = &.{CipherSuite.aes_128_gcm_sha256},
    groups: ?[]const u16 = &.{NamedGroup.x25519},
    key_share_groups: []const u16 = &.{NamedGroup.x25519},
    include_signature_algorithms: bool = true,
    compression: []const u8 = &.{0},
};

fn keyExchangeLen(group: u16) usize {
    return switch (group) {
        NamedGroup.secp256r1 => 65,
        else => 32,
    };
}

fn buildClientHello(buf: []u8, opts: BuildOptions) []const u8 {
    const zero_random = std.mem.zeroes([32]u8);
    const zero_key = std.mem.zeroes([65]u8);

    var w = Writer{ .buf = buf };
    w.writeU8(HandshakeType.client_hello);
    const header = w.placeU24();

    w.writeU16(tls12);
    w.writeBytes(&zero_random);
    w.writeU8(0);

    const cipher_suites = w.placeU16();
    for (opts.ciphers) |c| w.writeU16(c);
    w.patchU16(cipher_suites);

    w.writeU8(@intCast(opts.compression.len));
    w.writeBytes(opts.compression);

    const extensions = w.placeU16();

    w.writeU16(ExtensionType.supported_versions);
    const supported_versions = w.placeU16();
    w.writeU8(@intCast(opts.versions.len * 2));
    for (opts.versions) |v| w.writeU16(v);
    w.patchU16(supported_versions);

    if (opts.groups) |groups| {
        w.writeU16(ExtensionType.supported_groups);
        const supported_groups = w.placeU16();
        const group_list = w.placeU16();
        for (groups) |g| w.writeU16(g);
        w.patchU16(group_list);
        w.patchU16(supported_groups);
    }

    w.writeU16(ExtensionType.key_share);
    const key_share = w.placeU16();
    const client_shares = w.placeU16();
    for (opts.key_share_groups) |g| {
        w.writeU16(g);
        const ke = w.placeU16();
        w.writeBytes(zero_key[0..keyExchangeLen(g)]);
        w.patchU16(ke);
    }
    w.patchU16(client_shares);
    w.patchU16(key_share);

    if (opts.include_signature_algorithms) {
        w.writeU16(ExtensionType.signature_algorithms);
        const sig_algs = w.placeU16();
        const sig_list = w.placeU16();
        w.writeU16(0x0403);
        w.patchU16(sig_list);
        w.patchU16(sig_algs);
    }

    w.patchU16(extensions);
    w.patchU24(header);

    return w.slice();
}

// --------------------------------------------------------------- //
// harness: PASS / FAIL per assertion, mismatches counted and reported.

var failures: usize = 0;

fn check(name: []const u8, got: []const u8, want_hex: []const u8) void {
    var want: [256]u8 = undefined;
    checkBytes(name, got, decodeHexRuntime(&want, want_hex));
}

fn checkBytes(name: []const u8, got: []const u8, want: []const u8) void {
    if (std.mem.eql(u8, got, want)) {
        std.debug.print("  PASS  {s}\n", .{name});
    } else {
        failures += 1;
        std.debug.print("  FAIL  {s}\n        got  {x}\n        want {x}\n", .{ name, got, want });
    }
}

fn checkTrue(name: []const u8, ok: bool) void {
    if (ok) {
        std.debug.print("  PASS  {s}\n", .{name});
    } else {
        failures += 1;
        std.debug.print("  FAIL  {s}\n", .{name});
    }
}

fn expectAlert(name: []const u8, outcome: Outcome, want: Alert) void {
    const ok = outcome == .alert and outcome.alert == want;
    checkTrue(name, ok);
    if (!ok) std.debug.print("        outcome {any}\n", .{outcome});
}

pub fn main() !void {
    std.debug.print("TLS 1.3 Layer H handshake flow + negotiation vs RFC 8448 sec 3/4\n\n", .{});

    std.debug.print("[ ClientHello parse ]\n", .{});
    const parsed = parseClientHello(&client_hello);
    checkTrue("ClientHello parses without alert", parsed == .ok);
    const ch = parsed.ok;
    check("legacy_version 0x0303", &u16Bytes(ch.legacy_version), "03 03");
    check("client random", &ch.random, want_client_random);
    check("SNI host == \"server\"", ch.sni orelse "", "73 65 72 76 65 72");
    checkTrue("offers TLS 1.3 (supported_versions 0x0304)", ch.offers_tls13);
    checkTrue("has signature_algorithms", ch.has_signature_algorithms);
    checkTrue("has supported_groups", ch.has_supported_groups);
    checkTrue("offered x25519 key_share", ch.hasKeyShare(NamedGroup.x25519));
    check("x25519 key_share == client public", ch.x25519_share orelse "", want_client_share);

    std.debug.print("\n[ negotiation ]\n", .{});
    const outcome = negotiate(&ch, &server_x25519_public);
    checkTrue("outcome is ServerHello", outcome == .server_hello);
    check("negotiated cipher TLS_AES_128_GCM_SHA256", &u16Bytes(outcome.server_hello.cipher), "13 01");
    check("negotiated group x25519", &u16Bytes(outcome.server_hello.group), "00 1d");

    std.debug.print("\n[ ServerHello serialize (byte-exact vs trace) ]\n", .{});
    var sh_buf: [256]u8 = undefined;
    const sh = serializeServerHello(&sh_buf, &server_random, ch.session_id, outcome.server_hello);
    checkBytes("ServerHello == RFC 8448 ServerHello", sh, &server_hello);

    std.debug.print("\n[ server flight message order (8446 4.4) ]\n", .{});
    var types_buf: [8]u8 = undefined;
    const types = collectFlightTypes(&types_buf, &server_flight);
    checkBytes("flight order EE, Cert, CertVerify, Finished", types, &[_]u8{
        HandshakeType.encrypted_extensions,
        HandshakeType.certificate,
        HandshakeType.certificate_verify,
        HandshakeType.finished,
    });

    std.debug.print("\n[ negative MUST cases (ClientHello builder) ]\n", .{});
    var build_buf: [512]u8 = undefined;

    const bad_compression = buildClientHello(&build_buf, .{ .compression = &.{1} });
    expectAlert("compression != 0 -> illegal_parameter", processClientHello(bad_compression, &server_x25519_public), .illegal_parameter);

    const no_tls13 = buildClientHello(&build_buf, .{ .versions = &.{tls12} });
    checkTrue("no 0x0304 -> not TLS 1.3 (downgrade path)", processClientHello(no_tls13, &server_x25519_public) == .legacy_version);

    const no_cipher = buildClientHello(&build_buf, .{ .ciphers = &.{0x00ff} });
    expectAlert("no cipher overlap -> handshake_failure", processClientHello(no_cipher, &server_x25519_public), .handshake_failure);

    const no_group = buildClientHello(&build_buf, .{ .groups = &.{NamedGroup.ffdhe2048}, .key_share_groups = &.{} });
    expectAlert("no group overlap -> handshake_failure", processClientHello(no_group, &server_x25519_public), .handshake_failure);

    const need_hrr = buildClientHello(&build_buf, .{ .groups = &.{NamedGroup.x25519}, .key_share_groups = &.{} });
    const hrr = processClientHello(need_hrr, &server_x25519_public);
    checkTrue("group offered but no key_share -> HelloRetryRequest", hrr == .hello_retry_request and hrr.hello_retry_request == NamedGroup.x25519);

    const no_sig = buildClientHello(&build_buf, .{ .include_signature_algorithms = false });
    expectAlert("non-PSK missing signature_algorithms -> missing_extension", processClientHello(no_sig, &server_x25519_public), .missing_extension);

    const no_groups_ext = buildClientHello(&build_buf, .{ .groups = null, .key_share_groups = &.{} });
    expectAlert("non-PSK missing supported_groups -> missing_extension", processClientHello(no_groups_ext, &server_x25519_public), .missing_extension);

    std.debug.print("\n[ RFC constants ]\n", .{});
    var hrr_random: [32]u8 = undefined;
    Sha256.hash("HelloRetryRequest", &hrr_random, .{});
    check("HelloRetryRequest random == SHA-256(\"HelloRetryRequest\")", &hrr_random, want_hrr_random);
    check("downgrade sentinel (TLS 1.2) == \"DOWNGRD\\x01\"", "DOWNGRD\x01", downgrade_tls12);
    check("downgrade sentinel (<= 1.1) == \"DOWNGRD\\x00\"", "DOWNGRD\x00", downgrade_below);

    std.debug.print("\n", .{});
    if (failures == 0) {
        std.debug.print("ALL CHECKS PASS (Layer H conformant vs RFC 8448)\n", .{});
    } else {
        std.debug.print("{d} CHECK(S) FAILED\n", .{failures});
        std.process.exit(1);
    }
}

/// Parse + negotiate in one step (the negative cases only need the final outcome).
fn processClientHello(bytes: []const u8, key_exchange: []const u8) Outcome {
    return switch (parseClientHello(bytes)) {
        .alert => |alert| .{ .alert = alert },
        .ok => |ch| negotiate(&ch, key_exchange),
    };
}

/// Walk a flight of handshake messages, collecting the type byte of each (8446 4.4).
fn collectFlightTypes(out: []u8, flight: []const u8) []const u8 {
    var r = Reader{ .buf = flight };
    var count: usize = 0;
    while (r.remaining() >= 4 and count < out.len) {
        out[count] = r.readU8() catch break;
        count += 1;
        const len = r.readU24() catch break;
        _ = r.readBytes(len) catch break;
    }

    return out[0..count];
}

// --------------------------------------------------------------- //
// helpers: comptime + runtime hex, small encoders, kept at the foot.

fn u16Bytes(value: u16) [2]u8 {
    var out: [2]u8 = undefined;
    std.mem.writeInt(u16, &out, value, .big);

    return out;
}

fn hexLen(comptime s: []const u8) usize {
    @setEvalBranchQuota(200000);
    var n: usize = 0;
    for (s) |c| switch (c) {
        '0'...'9', 'a'...'f', 'A'...'F' => n += 1,
        else => {},
    };

    return n / 2;
}

fn hx(comptime s: []const u8) [hexLen(s)]u8 {
    @setEvalBranchQuota(200000);
    var out: [hexLen(s)]u8 = undefined;
    var oi: usize = 0;
    var high: ?u8 = null;
    for (s) |c| {
        const nibble: u8 = switch (c) {
            '0'...'9' => c - '0',
            'a'...'f' => c - 'a' + 10,
            'A'...'F' => c - 'A' + 10,
            else => continue,
        };
        if (high) |h| {
            out[oi] = (h << 4) | nibble;
            oi += 1;
            high = null;
        } else {
            high = nibble;
        }
    }

    return out;
}

fn decodeHexRuntime(buf: []u8, hex_str: []const u8) []u8 {
    var oi: usize = 0;
    var high: ?u8 = null;
    for (hex_str) |c| {
        const nibble: u8 = switch (c) {
            '0'...'9' => c - '0',
            'a'...'f' => c - 'a' + 10,
            'A'...'F' => c - 'A' + 10,
            else => continue,
        };
        if (high) |h| {
            buf[oi] = (h << 4) | nibble;
            oi += 1;
            high = null;
        } else {
            high = nibble;
        }
    }

    return buf[0..oi];
}
