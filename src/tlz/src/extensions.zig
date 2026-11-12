//! TLZ extensions
//!
//! ### file: src/tlz/src/extensions.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! TLS 1.3 server extensions: ALPN selection (RFC 7301), SNI validation (RFC 6066),
//! and the EncryptedExtensions message (RFC 8446 section 4.3.1).
//!
//! ### note:
//!
//! ClientHello extension parsing lives in `handshake.zig`. The EncryptedExtensions
//! bytes are checked against the RFC 8448 trace in the tests below.
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
const Alpn = @import("alpn.zig").Alpn;
const ExtensionType = @import("extension_type.zig").ExtensionType;
const HandshakeType = @import("handshake/handshake_type.zig").HandshakeType;
const EncryptedExtensionsOptions = @import("extensions/EncryptedExtensionsOptions.zig");

// --------------------------------------------------------- //
// Private:

/// NameType host_name in a ServerNameList (RFC 6066 3).
const SERVER_NAME_TYPE_HOST_NAME: u8 = 0;

/// Read the inner list of a u16-prefixed vector.
fn readU16Vector(bytes: []const u8) Reader.Error![]const u8 {
    var reader: Reader = .{ .buf = bytes };
    const list_len = try reader.readU16();

    return reader.readBytes(list_len);
}

/// Look for one protocol in a ProtocolNameList.
fn listHasProtocol(list: []const u8, candidate: Alpn) bool {
    var reader: Reader = .{ .buf = list };

    while (reader.remaining() >= 1) {
        const name = readProtocolName(&reader) catch |err| switch (err) {
            error.Tlz_WireReader_Truncated => return false,
        };

        if (std.mem.eql(u8, name, candidate.token())) return true;
    }

    return false;
}

fn readProtocolName(reader: *Reader) Reader.Error![]const u8 {
    const name_len = try reader.readU8();

    return reader.readBytes(name_len);
}

/// Count host_name entries in a ServerNameList.
fn countHostNames(server_name_list: []const u8) Reader.Error!usize {
    var reader: Reader = .{ .buf = try readU16Vector(server_name_list) };
    var host_names: usize = 0;

    while (reader.remaining() >= 3) {
        const name_type = try reader.readU8();
        const name_len = try reader.readU16();
        _ = try reader.readBytes(name_len);

        if (name_type == SERVER_NAME_TYPE_HOST_NAME) host_names += 1;
    }

    return host_names;
}

/// Reject a ServerNameList carrying more than one host_name (RFC 6066 3, MUST NOT).
///
/// Param:
/// server_name_list - []const u8 (the server_name extension body)
///
/// Return:
/// - null when the list is valid
/// - Alert.DECODE_ERROR when the list is truncated
/// - Alert.ILLEGAL_PARAMETER when more than one host_name is listed
fn validateSni(server_name_list: []const u8) ?Alert {
    const host_names = countHostNames(server_name_list) catch |err| switch (err) {
        error.Tlz_WireReader_Truncated => return .DECODE_ERROR,
    };

    if (host_names > 1) return .ILLEGAL_PARAMETER;

    return null;
}

/// Write one extension holding a u16-prefixed list.
fn writeListExtension(writer: *Writer, ext_type: ExtensionType, body: []const u8) void {
    writer.writeU16(@intFromEnum(ext_type));
    const ext = writer.placeU16();
    const list = writer.placeU16();
    writer.writeBytes(body);
    writer.patchU16(list);
    writer.patchU16(ext);
}

// --------------------------------------------------------- //
// Public:

/// Select one protocol from the client list, in server preference order
/// (RFC 7301 3.2).
///
/// Param:
/// client_protocols - []const u8 (the ALPN extension body from the ClientHello)
/// prefs - []const Alpn (the server order, first wins)
///
/// Return:
/// - Alpn (the selected protocol)
/// - null when there is no overlap or the list is malformed. The caller turns it
///   into a no_application_protocol alert.
pub fn negotiateAlpn(client_protocols: []const u8, prefs: []const Alpn) ?Alpn {
    const list = readU16Vector(client_protocols) catch |err| switch (err) {
        error.Tlz_WireReader_Truncated => return null,
    };

    for (prefs) |candidate| {
        if (listHasProtocol(list, candidate)) return candidate;
    }

    return null;
}

/// Build the EncryptedExtensions message.
///
/// Param:
/// buf - []u8 (the destination, sized for the whole message)
/// opts - EncryptedExtensionsOptions (what to emit)
///
/// Return:
/// - []const u8 (the wire message, a view into `buf`)
pub fn buildEncryptedExtensions(buf: []u8, opts: EncryptedExtensionsOptions) []const u8 {
    var writer: Writer = .{ .buf = buf };

    writer.writeU8(@intFromEnum(HandshakeType.ENCRYPTED_EXTENSIONS));
    const header = writer.placeU24();

    const extensions = writer.placeU16();

    if (opts.groups_list) |groups| {
        writeListExtension(&writer, .SUPPORTED_GROUPS, groups);
    }

    if (opts.record_size_limit) |limit| {
        writer.writeU16(@intFromEnum(ExtensionType.RECORD_SIZE_LIMIT));
        writer.writeU16(2);
        writer.writeU16(limit);
    }

    if (opts.alpn_selected) |protocol| {
        const token = protocol.token();
        var name_buf: [256]u8 = undefined;
        name_buf[0] = @intCast(token.len);
        @memcpy(name_buf[1 .. 1 + token.len], token);

        writeListExtension(
            &writer,
            .APPLICATION_LAYER_PROTOCOL_NEGOTIATION,
            name_buf[0 .. 1 + token.len],
        );
    }

    if (opts.server_name_ack) {
        // An empty acknowledgement (RFC 6066 3)
        writer.writeU16(@intFromEnum(ExtensionType.SERVER_NAME));
        writer.writeU16(0);
    }

    writer.patchU16(extensions);
    writer.patchU24(header);

    return writer.slice();
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

/// The RFC 8448 simple 1-RTT EncryptedExtensions.
const RFC8448_ENCRYPTED_EXTENSIONS_HEX =
    "080000240022000a00140012001d00170018001901000101010201030104001c0002400100000000";

const RFC8448_GROUPS_HEX = "001d00170018001901000101010201030104";

/// A client ALPN body offering ["h2", "http/1.1"].
const CLIENT_ALPN_HEX = "000c02683208687474702f312e31";

test "tlz: extensions, EncryptedExtensions is byte exact vs RFC 8448" {
    var groups: [18]u8 = undefined;
    var expected: [40]u8 = undefined;
    _ = try std.fmt.hexToBytes(&groups, RFC8448_GROUPS_HEX);
    _ = try std.fmt.hexToBytes(&expected, RFC8448_ENCRYPTED_EXTENSIONS_HEX);
    var buf: [256]u8 = undefined;

    const encrypted_extensions = buildEncryptedExtensions(&buf, .{
        .groups_list = &groups,
        .record_size_limit = 0x4001,
        .server_name_ack = true,
    });

    try std.testing.expectEqualSlices(u8, &expected, encrypted_extensions);
}

test "tlz: extensions, EncryptedExtensions with nothing set is empty" {
    var buf: [16]u8 = undefined;

    const encrypted_extensions = buildEncryptedExtensions(&buf, .{});

    try std.testing.expectEqualSlices(
        u8,
        &[_]u8{ 0x08, 0x00, 0x00, 0x02, 0x00, 0x00 },
        encrypted_extensions,
    );
}

test "tlz: extensions, EncryptedExtensions emits the selected ALPN" {
    var want: [9]u8 = undefined;
    _ = try std.fmt.hexToBytes(&want, "001000050003026832");
    var buf: [64]u8 = undefined;

    const encrypted_extensions = buildEncryptedExtensions(&buf, .{
        .alpn_selected = .H2,
    });

    try std.testing.expectEqualSlices(u8, &want, encrypted_extensions[6..]);
}

test "tlz: extensions, negotiateAlpn follows server preference" {
    var client_alpn: [14]u8 = undefined;
    _ = try std.fmt.hexToBytes(&client_alpn, CLIENT_ALPN_HEX);

    try std.testing.expectEqual(Alpn.H2, negotiateAlpn(&client_alpn, &.{ .H2, .HTTP_1_1 }).?);
    try std.testing.expectEqual(
        Alpn.HTTP_1_1,
        negotiateAlpn(&client_alpn, &.{ .HTTP_1_1, .H2 }).?,
    );
}

test "tlz: extensions, negotiateAlpn with no overlap is null" {
    var no_overlap: [9]u8 = undefined;
    _ = try std.fmt.hexToBytes(&no_overlap, "000706737064792f33");

    try std.testing.expect(negotiateAlpn(&no_overlap, &.{ .H2, .HTTP_1_1 }) == null);
}

test "tlz: extensions, negotiateAlpn with empty prefs is null" {
    var client_alpn: [14]u8 = undefined;
    _ = try std.fmt.hexToBytes(&client_alpn, CLIENT_ALPN_HEX);

    try std.testing.expect(negotiateAlpn(&client_alpn, &.{}) == null);
}

test "tlz: extensions, negotiateAlpn on a truncated list is null" {
    const truncated = [_]u8{ 0x00, 0x0c, 0x02, 'h' };

    try std.testing.expect(negotiateAlpn(&truncated, &.{.H2}) == null);
}

test "tlz: extensions, validateSni accepts a single host_name" {
    var single: [11]u8 = undefined;
    _ = try std.fmt.hexToBytes(&single, "0009000006736572766572");

    try std.testing.expect(validateSni(&single) == null);
}

test "tlz: extensions, validateSni rejects a duplicate host_name" {
    var duplicate: [20]u8 = undefined;
    _ = try std.fmt.hexToBytes(&duplicate, "0012000006736572766572000006736572766572");

    try std.testing.expectEqual(Alert.ILLEGAL_PARAMETER, validateSni(&duplicate).?);
}

test "tlz: extensions, validateSni on a truncated list is decode_error" {
    const truncated = [_]u8{ 0x00, 0x09, 0x00 };

    try std.testing.expectEqual(Alert.DECODE_ERROR, validateSni(&truncated).?);
}

