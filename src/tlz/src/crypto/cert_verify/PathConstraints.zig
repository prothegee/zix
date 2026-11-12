//! TLZ crypto cert_verify PathConstraints
//!
//! ### file: src/tlz/src/crypto/cert_verify/PathConstraints.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! The path constraints of one X.509 certificate (RFC 5280 4.2): basicConstraints,
//! keyUsage keyCertSign, and whether an unknown critical extension is present.
//!
//! ### note:
//!
//! std's parsed certificate does not expose these, so `parse` walks the v3
//! extensions with the bounds-checked reader of `der_guard.zig`. The [3]
//! extensions wrapper reads as tag bitstring because its context tag number is 3.
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

const der_guard = @import("../der_guard.zig");

const Certificate = std.crypto.Certificate;
const Element = Certificate.der.Element;

// --------------------------------------------------------- //
// Fields:

/// basicConstraints cA is TRUE.
is_ca: bool = false,
/// basicConstraints pathLenConstraint, when present.
path_len: ?u32 = null,
/// The keyUsage extension is present.
has_key_usage: bool = false,
/// keyUsage allows keyCertSign.
key_cert_sign: bool = false,
/// A critical extension carries an OID tlz does not recognize.
unknown_critical: bool = false,

const Self = @This();

// --------------------------------------------------------- //
// Private:

/// Read one element with bounds checks.
fn element(bytes: []const u8, pos: usize) Error!Element {
    return der_guard.readElement(bytes, pos, bytes.len) orelse {
        return Error.Tlz_CertVerifyPathConstraints_Malformed;
    };
}

/// A BOOLEAN element is TRUE. An empty one is malformed.
fn isTrue(bytes: []const u8, boolean: Element) Error!bool {
    if (boolean.slice.end <= boolean.slice.start) {
        return Error.Tlz_CertVerifyPathConstraints_Malformed;
    }

    return bytes[boolean.slice.start] != 0;
}

/// Find the extensions SEQUENCE inside the TBSCertificate.
///
/// Return:
/// - Element (the extensions SEQUENCE)
/// - null for a v1 certificate or one without extensions
fn findExtensions(bytes: []const u8) Error!?Element {
    const certificate = try element(bytes, 0);
    const tbs = try element(bytes, certificate.slice.start);
    const version_elem = try element(bytes, tbs.slice.start);
    const is_v3 = @as(u8, @bitCast(version_elem.identifier)) == 0xa0;

    const serial = if (is_v3) try element(bytes, version_elem.slice.end) else version_elem;
    const tbs_sig = try element(bytes, serial.slice.end);
    const issuer = try element(bytes, tbs_sig.slice.end);
    const validity = try element(bytes, issuer.slice.end);
    const subject = try element(bytes, validity.slice.end);
    const spki = try element(bytes, subject.slice.end);

    if (!is_v3 or spki.slice.end >= tbs.slice.end) return null;

    const outer = try element(bytes, spki.slice.end);
    if (outer.identifier.tag != .bitstring) return null;

    return try element(bytes, outer.slice.start);
}

/// basicConstraints: OCTET STRING wraps SEQUENCE { cA BOOLEAN, pathLen INTEGER }.
fn readBasicConstraints(self: *Self, bytes: []const u8, value: Element) Error!void {
    const seq = try element(bytes, value.slice.start);
    if (seq.slice.start >= seq.slice.end) return;

    const first = try element(bytes, seq.slice.start);
    if (first.identifier.tag != .boolean) return;

    self.is_ca = try isTrue(bytes, first);
    if (first.slice.end >= seq.slice.end) return;

    const path_len = try element(bytes, first.slice.end);
    const path_len_bytes = bytes[path_len.slice.start..path_len.slice.end];
    if (path_len.identifier.tag != .integer or path_len_bytes.len > 4) return;

    var value_u32: u32 = 0;
    for (path_len_bytes) |byte| value_u32 = (value_u32 << 8) | byte;

    self.path_len = value_u32;
}

/// keyUsage: OCTET STRING wraps BIT STRING { unused bits, usage }. keyCertSign is
/// bit 5 (0x04 in the first usage byte).
fn readKeyUsage(self: *Self, bytes: []const u8, value: Element) Error!void {
    self.has_key_usage = true;

    const bit_string = try element(bytes, value.slice.start);
    const content = bytes[bit_string.slice.start..bit_string.slice.end];

    if (content.len >= 2 and (content[1] & 0x04) != 0) self.key_cert_sign = true;
}

fn parseInner(bytes: []const u8) Error!Self {
    var out: Self = .{};
    const extensions = try findExtensions(bytes) orelse return out;

    var pos = extensions.slice.start;
    while (pos < extensions.slice.end) {
        const extension = try element(bytes, pos);
        pos = extension.slice.end;

        const oid = try element(bytes, extension.slice.start);
        const crit_elem = try element(bytes, oid.slice.end);
        const has_critical = crit_elem.identifier.tag == .boolean;
        const critical = has_critical and try isTrue(bytes, crit_elem);
        const value = if (has_critical)
            try element(bytes, crit_elem.slice.end)
        else
            crit_elem;

        const ext_id = Certificate.parseExtensionId(bytes, oid) catch |err| switch (err) {
            error.CertificateHasUnrecognizedObjectId => {
                if (critical) out.unknown_critical = true;

                continue;
            },
            error.CertificateFieldHasWrongDataType => {
                return Error.Tlz_CertVerifyPathConstraints_Malformed;
            },
        };

        switch (ext_id) {
            .basic_constraints => try out.readBasicConstraints(bytes, value),
            .key_usage => try out.readKeyUsage(bytes, value),
            else => {},
        }
    }

    return out;
}

// --------------------------------------------------------- //
// Public:

pub const Error = error{
    Tlz_CertVerifyPathConstraints_Malformed,
};

/// Walk one certificate's v3 extensions and collect its path constraints.
///
/// Param:
/// bytes - []const u8 (the certificate DER)
///
/// Return:
/// - Self (all defaults for a v1 certificate or one without extensions)
/// - Error.Tlz_CertVerifyPathConstraints_Malformed when the DER is malformed
pub fn parse(bytes: []const u8) Error!Self {
    return parseInner(bytes);
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

/// Chain fixture (ECDSA P-256): root (CA, no pathlen) -> intermediate (CA, pathlen 0)
/// -> leaf (CN=localhost, not a CA).
const CHAIN_ROOT_HEX =
    "308201953082013ba003020102021440f79706c99a7008e5dda0815e4e311f9e702f51300a06082a" ++
    "8648ce3d04030230183116301406035504030c0d7a69782d746573742d726f6f74301e170d323630" ++
    "3632333037333630315a170d3336303632303037333630315a30183116301406035504030c0d7a69" ++
    "782d746573742d726f6f743059301306072a8648ce3d020106082a8648ce3d030107034200044a89" ++
    "ec0c129c506d9b1f92c5b28f9328a7b063556cd64c2d5802db0e64c456fc90219d78b6cfda100274" ++
    "23eb8c1c4a886bfe2bb9b4aa7cba9bd449f117f57c04a3633061301d0603551d0e04160414356f3a" ++
    "c248e3e2a8bb9bd047c5e6219aada7f020301f0603551d23041830168014356f3ac248e3e2a8bb9b" ++
    "d047c5e6219aada7f020300f0603551d130101ff040530030101ff300e0603551d0f0101ff040403" ++
    "020106300a06082a8648ce3d0403020348003045022100ea3bdd439b274a5d0ef7993a70f18d913e" ++
    "7840d669d1b44c9eb84149eb7ac08602203804ec5881841d3a734e4e1a05231c595b6f43a1ca3e6f" ++
    "0d0398004f85d0047e";

const CHAIN_INT_HEX =
    "3082019f30820146a00302010202140676b25f6c4f12ed9bb873f83a007db84e8f3846300a06082a" ++
    "8648ce3d04030230183116301406035504030c0d7a69782d746573742d726f6f74301e170d323630" ++
    "3632333037333630315a170d3336303632303037333630315a3020311e301c06035504030c157a69" ++
    "782d746573742d696e7465726d6564696174653059301306072a8648ce3d020106082a8648ce3d03" ++
    "010703420004247a6c91f8537ef15cf71670559138fdba0d2a1865b9b809fd1780e227b3a4a8d56c" ++
    "95e7c83311b76c2ab3861b7b1d4d1b535c8f67a5b1e8d32b54b38064c999a366306430120603551d" ++
    "130101ff040830060101ff020100300e0603551d0f0101ff040403020106301d0603551d0e041604" ++
    "14d699cb91497cc7f981bccaf6a632a1eee036d52b301f0603551d23041830168014356f3ac248e3" ++
    "e2a8bb9bd047c5e6219aada7f020300a06082a8648ce3d040302034700304402200a09dc44d96143" ++
    "05084cdc7081d7181a4497d0ee9787d2e5f8196fe7e50c50fd02203e97e6be1d67006729f38c15ca" ++
    "f116ec8b0be7cb4a101e1f9ecc71d52b435c71";

const CHAIN_LEAF_HEX =
    "308201ad30820152a003020102021472dd9fe9aa428ce22acbb7e6146231e66269a6c0300a06082a" ++
    "8648ce3d0403023020311e301c06035504030c157a69782d746573742d696e7465726d6564696174" ++
    "65301e170d3236303632333037333630315a170d3336303632303037333630315a30143112301006" ++
    "035504030c096c6f63616c686f73743059301306072a8648ce3d020106082a8648ce3d0301070342" ++
    "00047c1d5b1ca87efb392f68fb1c13da2edcc8d7eb0a173eb7ce23174a7009142da963143404d086" ++
    "34fd9a4552594d405fe87bf183c08b973ad1ab0089d43e1949bfa3763074300c0603551d130101ff" ++
    "04023000300e0603551d0f0101ff04040302078030140603551d11040d300b82096c6f63616c686f" ++
    "7374301d0603551d0e0416041460d9685b0a35acfaa9975e62a3d2660234a2ea07301f0603551d23" ++
    "041830168014d699cb91497cc7f981bccaf6a632a1eee036d52b300a06082a8648ce3d0403020349" ++
    "003046022100ee1b1fc48b0e3b3582d0fbcdbc146863263816e1b547f94aba57c25b28cd604d0221" ++
    "00c7cdba1f9e63e82ff9cc31e196711368fec9cf3f092b795402f99c28e45f5227";

fn fixture(buf: *[512]u8, comptime hex: []const u8) ![]const u8 {
    return std.fmt.hexToBytes(buf, hex);
}

test "tlz crypto cert_verify: PathConstraints, root is a CA without pathLen" {
    var buf: [512]u8 = undefined;

    const constraints = try parse(try fixture(&buf, CHAIN_ROOT_HEX));

    try std.testing.expect(constraints.is_ca);
    try std.testing.expect(constraints.key_cert_sign);
    try std.testing.expectEqual(@as(?u32, null), constraints.path_len);
}

test "tlz crypto cert_verify: PathConstraints, intermediate has pathLen zero" {
    var buf: [512]u8 = undefined;

    const constraints = try parse(try fixture(&buf, CHAIN_INT_HEX));

    try std.testing.expect(constraints.is_ca);
    try std.testing.expect(constraints.key_cert_sign);
    try std.testing.expectEqual(@as(?u32, 0), constraints.path_len);
}

test "tlz crypto cert_verify: PathConstraints, leaf is not a CA" {
    var buf: [512]u8 = undefined;

    const constraints = try parse(try fixture(&buf, CHAIN_LEAF_HEX));

    try std.testing.expect(!constraints.is_ca);
    try std.testing.expect(constraints.has_key_usage);
    try std.testing.expect(!constraints.key_cert_sign);
    try std.testing.expect(!constraints.unknown_critical);
}

test "tlz crypto cert_verify: PathConstraints, empty input is malformed" {
    try std.testing.expectError(Error.Tlz_CertVerifyPathConstraints_Malformed, parse(&.{}));
}

test "tlz crypto cert_verify: PathConstraints, truncated certificate is malformed" {
    var buf: [512]u8 = undefined;
    const leaf = try fixture(&buf, CHAIN_LEAF_HEX);

    try std.testing.expectError(
        Error.Tlz_CertVerifyPathConstraints_Malformed,
        parse(leaf[0..40]),
    );
}

