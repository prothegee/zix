//! TLZ handshake ClientHello
//!
//! ### file: src/tlz/src/handshake/ClientHello.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! The parsed ClientHello fields the server needs (RFC 8446 section 4.1.2), plus
//! lookups over the offered lists.
//!
//! ### note:
//!
//! Every slice is a view into the ClientHello bytes, so those bytes must outlive
//! this record.
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
const CipherSuite = @import("../cipher_suite.zig").CipherSuite;
const NamedGroup = @import("../named_group.zig").NamedGroup;
const SignatureScheme = @import("../signature_scheme.zig").SignatureScheme;

// --------------------------------------------------------- //
// Fields:

/// legacy_version from the hello body.
legacy_version: u16,
/// The 32-byte client random.
random: [32]u8,
/// legacy_session_id, echoed back in the ServerHello.
session_id: []const u8,
/// The raw cipher_suites list body, each entry a u16.
cipher_suites: []const u8,
/// supported_versions lists TLS 1.3.
offers_tls13: bool = false,
/// The signature_algorithms extension is present.
has_signature_algorithms: bool = false,
/// The supported_groups extension is present.
has_supported_groups: bool = false,
/// The raw NamedGroupList body, each entry a u16.
supported_groups: []const u8 = &.{},
/// The raw SignatureSchemeList body (RFC 8446 4.2.3), each entry a u16.
/// Empty when not offered.
signature_schemes: []const u8 = &.{},
/// The groups that carry a key_share entry, in offer order.
key_share_groups: [MAX_KEY_SHARE_GROUPS]NamedGroup = undefined,
/// How many entries of `key_share_groups` are set.
key_share_count: usize = 0,
/// The X25519 key share bytes, when offered.
x25519_share: ?[]const u8 = null,
/// The secp256r1 key share bytes, when offered.
secp256r1_share: ?[]const u8 = null,
/// The host_name from server_name, when offered.
sni: ?[]const u8 = null,
/// The raw ProtocolNameList body of the ALPN extension (RFC 7301), null when not
/// offered.
alpn: ?[]const u8 = null,

const Self = @This();

// --------------------------------------------------------- //
// Private:

/// Scan a list of u16 code points for one value.
///
/// Param:
/// list - []const u8 (the raw list body, each entry a big-endian u16)
/// value - u16 (the code point to find)
///
/// Return:
/// - bool
fn listHasU16(list: []const u8, value: u16) bool {
    var reader: Reader = .{ .buf = list };

    while (reader.remaining() >= 2) {
        const entry = reader.readU16() catch |err| switch (err) {
            error.Tlz_WireReader_Truncated => return false,
        };

        if (entry == value) return true;
    }

    return false;
}

// --------------------------------------------------------- //
// Public:

/// The cap on key_share groups kept from one ClientHello. Extra entries are skipped.
pub const MAX_KEY_SHARE_GROUPS: usize = 16;

/// The client offered this cipher suite.
///
/// Param:
/// suite - CipherSuite (the suite to look for)
///
/// Return:
/// - bool
pub fn offersCipher(self: *const Self, suite: CipherSuite) bool {
    return listHasU16(self.cipher_suites, @intFromEnum(suite));
}

/// The client listed this group in supported_groups.
///
/// Param:
/// group - NamedGroup (the group to look for)
///
/// Return:
/// - bool
pub fn offersGroup(self: *const Self, group: NamedGroup) bool {
    return listHasU16(self.supported_groups, @intFromEnum(group));
}

/// The client sent a key_share entry for this group.
///
/// Param:
/// group - NamedGroup (the group to look for)
///
/// Return:
/// - bool
pub fn hasKeyShare(self: *const Self, group: NamedGroup) bool {
    for (self.key_share_groups[0..self.key_share_count]) |offered| {
        if (offered == group) return true;
    }

    return false;
}

/// The client offered this scheme in signature_algorithms (RFC 8446 4.2.3). The
/// server checks it before signing CertificateVerify with its key.
///
/// Param:
/// scheme - SignatureScheme (the scheme to look for)
///
/// Return:
/// - bool
pub fn offersSignatureScheme(self: *const Self, scheme: SignatureScheme) bool {
    return listHasU16(self.signature_schemes, @intFromEnum(scheme));
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

fn emptyHello() Self {
    return .{
        .legacy_version = 0x0303,
        .random = std.mem.zeroes([32]u8),
        .session_id = &.{},
        .cipher_suites = &.{},
    };
}

test "tlz handshake: ClientHello, offersSignatureScheme finds an offered scheme" {
    const schemes = [_]u8{ 0x04, 0x03, 0x08, 0x07 };
    var hello = emptyHello();
    hello.signature_schemes = &schemes;

    try std.testing.expect(hello.offersSignatureScheme(.ECDSA_SECP256R1_SHA256));
    try std.testing.expect(hello.offersSignatureScheme(.ED25519));
}

test "tlz handshake: ClientHello, offersSignatureScheme skips a scheme not offered" {
    const schemes = [_]u8{ 0x04, 0x03, 0x08, 0x07 };
    var hello = emptyHello();
    hello.signature_schemes = &schemes;

    try std.testing.expect(!hello.offersSignatureScheme(.RSA_PKCS1_SHA256));
    try std.testing.expect(!hello.offersSignatureScheme(@enumFromInt(0x0203)));
}

test "tlz handshake: ClientHello, offersSignatureScheme without the extension is false" {
    const hello = emptyHello();

    try std.testing.expect(!hello.offersSignatureScheme(.ECDSA_SECP256R1_SHA256));
}

test "tlz handshake: ClientHello, offersCipher finds an offered suite" {
    const suites = [_]u8{ 0x13, 0x02, 0x13, 0x01 };
    var hello = emptyHello();
    hello.cipher_suites = &suites;

    try std.testing.expect(hello.offersCipher(.AES_128_GCM_SHA256));
    try std.testing.expect(!hello.offersCipher(.CHACHA20_POLY1305_SHA256));
}

test "tlz handshake: ClientHello, offersCipher ignores a trailing odd byte" {
    const suites = [_]u8{ 0x13, 0x02, 0x13 };
    var hello = emptyHello();
    hello.cipher_suites = &suites;

    try std.testing.expect(hello.offersCipher(.AES_256_GCM_SHA384));
    try std.testing.expect(!hello.offersCipher(.AES_128_GCM_SHA256));
}

test "tlz handshake: ClientHello, offersGroup finds an offered group" {
    const groups = [_]u8{ 0x00, 0x1d };
    var hello = emptyHello();
    hello.supported_groups = &groups;

    try std.testing.expect(hello.offersGroup(.X25519));
    try std.testing.expect(!hello.offersGroup(.SECP256R1));
}

test "tlz handshake: ClientHello, hasKeyShare reads only the counted entries" {
    var hello = emptyHello();
    hello.key_share_groups[0] = .X25519;
    hello.key_share_groups[1] = .SECP256R1;
    hello.key_share_count = 1;

    try std.testing.expect(hello.hasKeyShare(.X25519));
    try std.testing.expect(!hello.hasKeyShare(.SECP256R1));
}

test "tlz handshake: ClientHello, hasKeyShare with no shares is false" {
    const hello = emptyHello();

    try std.testing.expect(!hello.hasKeyShare(.X25519));
}

