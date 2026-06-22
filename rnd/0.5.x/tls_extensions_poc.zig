//! TLS 1.3 Layer X PoC (RFC 8446 4.2, 4.3.1, RFC 7301 ALPN, RFC 6066 SNI), the server-side
//! extension handling step (tls-plan.md, Layer X, follows K + H + C).
//!
//! Note:
//! - Layer H already parses the client extensions. This layer is the server SIDE: building the
//!   EncryptedExtensions message, ALPN selection, and the SNI acknowledgement, plus the MUST NOT
//!   guards (no unoffered extension, exactly one ALPN protocol, no-overlap fatal alert).
//! - EncryptedExtensions is verified byte-for-byte against the RFC 8448 trace EE (the first
//!   handshake message of the server flight): supported_groups echo, record_size_limit echo, and
//!   an empty server_name acknowledgement. That trace offers no ALPN, so ALPN is exercised
//!   structurally on a synthetic client (select exactly one ProtocolName, carried in EE).
//! - "no extension the client did not offer" (4.3.1) is checked by parsing the trace ClientHello
//!   offered set and asserting every extension the server emits in EE was offered.
//! - ALPN no overlap MUST be fatal no_application_protocol(120) (7301 3.2). SNI MUST NOT carry
//!   more than one name per type (6066 3), a duplicate is rejected illegal_parameter.
//!
//! Run: zig run rnd/0.5.x/tls_extensions_poc.zig

const std = @import("std");

const ExtensionType = struct {
    const server_name: u16 = 0x0000;
    const supported_groups: u16 = 0x000a;
    const application_layer_protocol_negotiation: u16 = 0x0010;
    const record_size_limit: u16 = 0x001c;
};

const handshake_encrypted_extensions: u8 = 8;
const server_name_type_host_name: u8 = 0;

const Alert = enum(u8) {
    illegal_parameter = 47,
    decode_error = 50,
    no_application_protocol = 120,
};

/// Server ALPN preference order, the https selectable ids (7301 3.1).
const server_alpn_prefs = [_][]const u8{ "h2", "http/1.1" };

// --------------------------------------------------------------- //
// vectors: the RFC 8448 trace ClientHello + EncryptedExtensions, and the echoed values.

const client_hello = hx(
    \\01 00 00 c0 03 03 cb 34 ec b1 e7 81 63 ba 1c 38 c6 da cb 19 6a 6d ff a2 1a 8d 99 12 ec 18 a2 ef 62 83 02 4d ec e7
    \\00 00 06 13 01 13 03 13 02 01 00 00 91 00 00 00 0b 00 09 00 00 06 73 65 72 76 65 72 ff 01 00 01 00 00 0a 00 14 00
    \\12 00 1d 00 17 00 18 00 19 01 00 01 01 01 02 01 03 01 04 00 23 00 00 00 33 00 26 00 24 00 1d 00 20 99 38 1d e5 60
    \\e4 bd 43 d2 3d 8e 43 5a 7d ba fe b3 c0 6e 51 c1 3c ae 4d 54 13 69 1e 52 9a af 2c 00 2b 00 03 02 03 04 00 0d 00 20
    \\00 1e 04 03 05 03 06 03 02 03 08 04 08 05 08 06 04 01 05 01 06 01 02 01 04 02 05 02 06 02 02 02 00 2d 00 02 01 01
    \\00 1c 00 02 40 01
);

/// The trace EncryptedExtensions: supported_groups, record_size_limit, empty server_name ack.
const encrypted_extensions = hx(
    \\08 00 00 24 00 22 00 0a 00 14 00 12 00 1d 00 17 00 18 00 19 01 00 01 01 01 02 01 03 01 04 00 1c 00 02 40 01 00 00
    \\00 00
);

/// The server supported_groups list body echoed into EE (9 groups, RFC 8448).
const server_groups_list = hx("00 1d 00 17 00 18 00 19 01 00 01 01 01 02 01 03 01 04");
const record_size_limit_value: u16 = 0x4001;

const want_alpn_h2_extension = "00 10 00 05 00 03 02 68 32";

// --------------------------------------------------------------- //
// EncryptedExtensions build (RFC 8446 4.3.1).

const EncryptedExtensionsOptions = struct {
    groups_list: ?[]const u8 = null,
    record_size_limit: ?u16 = null,
    alpn_selected: ?[]const u8 = null,
    server_name_ack: bool = false,
};

fn buildEncryptedExtensions(buf: []u8, opts: EncryptedExtensionsOptions) []const u8 {
    var w = Writer{ .buf = buf };

    w.writeU8(handshake_encrypted_extensions);
    const header = w.placeU24();

    const extensions = w.placeU16();

    if (opts.groups_list) |groups| {
        w.writeU16(ExtensionType.supported_groups);
        const ext = w.placeU16();
        const list = w.placeU16();
        w.writeBytes(groups);
        w.patchU16(list);
        w.patchU16(ext);
    }

    if (opts.record_size_limit) |limit| {
        w.writeU16(ExtensionType.record_size_limit);
        w.writeU16(2);
        w.writeU16(limit);
    }

    if (opts.alpn_selected) |protocol| {
        w.writeU16(ExtensionType.application_layer_protocol_negotiation);
        const ext = w.placeU16();
        const list = w.placeU16();
        w.writeU8(@intCast(protocol.len));
        w.writeBytes(protocol);
        w.patchU16(list);
        w.patchU16(ext);
    }

    if (opts.server_name_ack) {
        w.writeU16(ExtensionType.server_name);
        w.writeU16(0); // empty acknowledgement (6066 3)
    }

    w.patchU16(extensions);
    w.patchU24(header);

    return w.slice();
}

// --------------------------------------------------------------- //
// ALPN (RFC 7301) + SNI (RFC 6066) server logic.

/// Select exactly one protocol from the client list in server preference order (7301 3.2).
fn negotiateAlpn(client_protocols: []const u8, prefs: []const []const u8) ?[]const u8 {
    for (prefs) |candidate| {
        var r = Reader{ .buf = client_protocols };
        const list_len = r.readU16() catch return null;
        const list = r.readBytes(list_len) catch return null;

        var lr = Reader{ .buf = list };
        while (lr.remaining() >= 1) {
            const name_len = lr.readU8() catch break;
            const name = lr.readBytes(name_len) catch break;
            if (std.mem.eql(u8, name, candidate)) return candidate;
        }
    }

    return null;
}

/// Reject a ServerNameList carrying more than one host_name (6066 3, MUST NOT).
fn validateSni(server_name_list: []const u8) ?Alert {
    var r = Reader{ .buf = server_name_list };
    const list_len = r.readU16() catch return .decode_error;
    const list = r.readBytes(list_len) catch return .decode_error;

    var lr = Reader{ .buf = list };
    var host_names: usize = 0;
    while (lr.remaining() >= 3) {
        const name_type = lr.readU8() catch return .decode_error;
        const name_len = lr.readU16() catch return .decode_error;
        _ = lr.readBytes(name_len) catch return .decode_error;
        if (name_type == server_name_type_host_name) host_names += 1;
    }

    if (host_names > 1) return .illegal_parameter;

    return null;
}

// --------------------------------------------------------------- //
// offered-set guard: every emitted EE extension MUST have been offered (4.3.1).

fn clientOfferedExtension(ext_type: u16) bool {
    const extensions = clientExtensions() catch return false;

    var r = Reader{ .buf = extensions };
    while (r.remaining() >= 4) {
        const this_type = r.readU16() catch return false;
        const len = r.readU16() catch return false;
        _ = r.readBytes(len) catch return false;
        if (this_type == ext_type) return true;
    }

    return false;
}

/// The extensions blob of the trace ClientHello (skip the fixed prefix).
fn clientExtensions() DecodeError![]const u8 {
    var r = Reader{ .buf = &client_hello };

    _ = try r.readU8();
    _ = try r.readU24();
    _ = try r.readU16();
    _ = try r.readBytes(32);
    const session_id_len = try r.readU8();
    _ = try r.readBytes(session_id_len);
    const cipher_suites_len = try r.readU16();
    _ = try r.readBytes(cipher_suites_len);
    const compression_len = try r.readU8();
    _ = try r.readBytes(compression_len);

    const extensions_len = try r.readU16();

    return r.readBytes(extensions_len);
}

fn allEmittedExtensionsOffered(ee: []const u8) bool {
    var r = Reader{ .buf = ee };
    _ = r.readU8() catch return false;
    _ = r.readU24() catch return false;
    const ext_len = r.readU16() catch return false;
    const exts = r.readBytes(ext_len) catch return false;

    var er = Reader{ .buf = exts };
    while (er.remaining() >= 4) {
        const this_type = er.readU16() catch return false;
        const len = er.readU16() catch return false;
        _ = er.readBytes(len) catch return false;
        if (!clientOfferedExtension(this_type)) return false;
    }

    return true;
}

// --------------------------------------------------------------- //
// harness.

var failures: usize = 0;

fn check(name: []const u8, got: []const u8, want_hex: []const u8) void {
    var want: [128]u8 = undefined;
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

pub fn main() !void {
    std.debug.print("TLS 1.3 Layer X extensions / ALPN / SNI vs RFC 8448 sec 3\n\n", .{});

    std.debug.print("[ EncryptedExtensions byte-exact vs trace ]\n", .{});
    var ee_buf: [256]u8 = undefined;
    const ee = buildEncryptedExtensions(&ee_buf, .{
        .groups_list = &server_groups_list,
        .record_size_limit = record_size_limit_value,
        .server_name_ack = true,
    });
    checkBytes("EncryptedExtensions == RFC 8448 EE", ee, &encrypted_extensions);
    checkTrue("EE emits only client-offered extensions (4.3.1)", allEmittedExtensionsOffered(ee));

    std.debug.print("\n[ ALPN (RFC 7301) ]\n", .{});
    const client_alpn = hx("00 0c 02 68 32 08 68 74 74 70 2f 31 2e 31"); // ["h2","http/1.1"]
    const selected = negotiateAlpn(&client_alpn, &server_alpn_prefs);
    checkTrue("selects a protocol", selected != null);
    checkBytes("selected ProtocolName == h2", selected orelse "", "h2");

    var alpn_buf: [64]u8 = undefined;
    const alpn_ee = buildEncryptedExtensions(&alpn_buf, .{ .alpn_selected = selected });
    check("ALPN extension in EE carries exactly one ProtocolName", alpn_ee[6..], want_alpn_h2_extension);

    const client_alpn_no_overlap = hx("00 07 06 73 70 64 79 2f 33"); // ["spdy/3"]
    checkTrue("no overlap -> no_application_protocol(120)", noOverlapAlert(&client_alpn_no_overlap) == .no_application_protocol);

    std.debug.print("\n[ SNI (RFC 6066) ]\n", .{});
    const sni_single = hx("00 09 00 00 06 73 65 72 76 65 72"); // one host_name "server"
    checkTrue("single host_name accepted", validateSni(&sni_single) == null);

    const sni_duplicate = hx("00 12 00 00 06 73 65 72 76 65 72 00 00 06 73 65 72 76 65 72"); // two host_names
    checkTrue("duplicate host_name -> illegal_parameter", validateSni(&sni_duplicate) == .illegal_parameter);

    std.debug.print("\n", .{});
    if (failures == 0) {
        std.debug.print("ALL CHECKS PASS (Layer X conformant vs RFC 8448)\n", .{});
    } else {
        std.debug.print("{d} CHECK(S) FAILED\n", .{failures});
        std.process.exit(1);
    }
}

/// no_application_protocol(120) when the server shares no protocol with the client (7301 3.2).
fn noOverlapAlert(client_protocols: []const u8) Alert {
    if (negotiateAlpn(client_protocols, &server_alpn_prefs) == null) return .no_application_protocol;

    return .illegal_parameter;
}

// --------------------------------------------------------------- //
// reader / writer / hex (shared shape with the other PoCs).

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

    fn placeU16(self: *Writer) usize {
        const marker = self.len;
        self.writeU16(0);

        return marker;
    }

    fn patchU16(self: *Writer, marker: usize) void {
        std.mem.writeInt(u16, self.buf[marker..][0..2], @intCast(self.len - marker - 2), .big);
    }

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
