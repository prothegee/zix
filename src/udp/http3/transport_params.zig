//! zix HTTP/3 client transport parameter parsing (RFC 9000 18).
//!
//! What:
//! - The server must respect the flow control limits the client advertises before sending a response.
//!   The client carries them in the quic_transport_parameters TLS extension (type 0x39) inside its
//!   ClientHello. This pulls out the two limits the response path needs and skips the rest.
//!
//! Note:
//! - A client-initiated bidirectional stream (the request stream) is, from the client's view, locally
//!   initiated. So the limit the server must respect when sending the response on it is the client's
//!   initial_max_stream_data_bidi_local (0x05), plus the connection-wide initial_max_data (0x04).

const std = @import("std");

const varint = @import("varint.zig");

/// The quic_transport_parameters TLS extension type (RFC 9001 8.2).
pub const extension_type: u16 = 0x0039;

/// The client flow control limits the response path needs. Absent parameters default to 0 (no credit),
/// so the caller treats a client that advertised nothing as having granted nothing.
pub const TransportParams = struct {
    /// Connection-level send limit: total stream data the server may send (param 0x04).
    initial_max_data: u64 = 0,
    /// Per-stream send limit for the request stream the server replies on (param 0x05, the client's
    /// initial_max_stream_data_bidi_local).
    initial_max_stream_data_bidi_local: u64 = 0,
};

/// Parse the body of the quic_transport_parameters extension (RFC 9000 18.1): a sequence of
/// (id, length, value) entries, each varint-framed. Unknown ids are skipped. Integer parameters carry
/// a varint value.
pub fn parse(ext_body: []const u8) TransportParams {
    var params = TransportParams{};
    var pos: usize = 0;
    while (pos < ext_body.len) {
        const id = varint.read(ext_body[pos..]) catch break;
        pos += id.len;

        const length = varint.read(ext_body[pos..]) catch break;
        pos += length.len;

        const value_len: usize = @intCast(length.value);
        if (pos + value_len > ext_body.len) break;

        const value = ext_body[pos .. pos + value_len];
        pos += value_len;

        switch (id.value) {
            0x04 => params.initial_max_data = varintValue(value) orelse params.initial_max_data,
            0x05 => params.initial_max_stream_data_bidi_local = varintValue(value) orelse params.initial_max_stream_data_bidi_local,
            else => {},
        }
    }

    return params;
}

/// Find and parse the client's quic_transport_parameters extension in a ClientHello handshake message.
/// Returns null when the extension is absent (a minimal test client sends none).
pub fn fromClientHello(client_hello: []const u8) ?TransportParams {
    const ext = findExtension(client_hello, extension_type) orelse return null;

    return parse(ext);
}

/// Read a transport parameter's integer value (a single varint, RFC 9000 18.1).
fn varintValue(value: []const u8) ?u64 {
    const v = varint.read(value) catch return null;

    return v.value;
}

/// Walk a ClientHello (RFC 8446 4.1.2) to its extension list and return the body of `want_type`, or
/// null when the message is malformed or the extension is absent.
fn findExtension(client_hello: []const u8, want_type: u16) ?[]const u8 {
    // Handshake header: msg_type(1, CLIENT_HELLO = 0x01) + length(3).
    if (client_hello.len < 4 or client_hello[0] != 0x01) return null;
    var pos: usize = 4;

    // legacy_version(2) + random(32).
    pos += 2 + 32;
    if (pos >= client_hello.len) return null;

    // legacy_session_id: length(1) + bytes.
    const sid_len = client_hello[pos];
    pos += 1 + sid_len;
    if (pos + 2 > client_hello.len) return null;

    // cipher_suites: length(2) + bytes.
    const cs_len = std.mem.readInt(u16, client_hello[pos..][0..2], .big);
    pos += 2 + cs_len;
    if (pos + 1 > client_hello.len) return null;

    // legacy_compression_methods: length(1) + bytes.
    const cm_len = client_hello[pos];
    pos += 1 + cm_len;
    if (pos + 2 > client_hello.len) return null;

    // extensions: length(2) + entries.
    const ext_total = std.mem.readInt(u16, client_hello[pos..][0..2], .big);
    pos += 2;
    const ext_end = pos + ext_total;
    if (ext_end > client_hello.len) return null;

    while (pos + 4 <= ext_end) {
        const ext_type = std.mem.readInt(u16, client_hello[pos..][0..2], .big);
        const ext_len = std.mem.readInt(u16, client_hello[pos + 2 ..][0..2], .big);
        pos += 4;
        if (pos + ext_len > ext_end) return null;

        if (ext_type == want_type) return client_hello[pos .. pos + ext_len];

        pos += ext_len;
    }

    return null;
}

// --------------------------------------------------------------- //
// --------------------------------------------------------------- //

fn h(comptime text: []const u8) [text.len / 2]u8 {
    var out: [text.len / 2]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, text) catch unreachable;

    return out;
}

test "zix test: parse extracts initial_max_data and initial_max_stream_data_bidi_local" {
    // Three params: 0x04 = 1048576 (varint c0..00100000), 0x05 = 262144 (varint 80040000),
    // 0x08 = 100 (varint 4064, skipped). Each entry is id, length, value.
    const body = h("04" ++ "04" ++ "80100000" ++ "05" ++ "04" ++ "80040000" ++ "08" ++ "02" ++ "4064");
    const params = parse(&body);

    try std.testing.expectEqual(@as(u64, 1048576), params.initial_max_data);
    try std.testing.expectEqual(@as(u64, 262144), params.initial_max_stream_data_bidi_local);
}

test "zix test: parse defaults absent parameters to zero" {
    // Only initial_max_data present, the per-stream limit defaults to 0.
    const body = h("04" ++ "04" ++ "80100000");
    const params = parse(&body);

    try std.testing.expectEqual(@as(u64, 1048576), params.initial_max_data);
    try std.testing.expectEqual(@as(u64, 0), params.initial_max_stream_data_bidi_local);
}

// A 32-byte all-zero random, as the 64 hex chars the ClientHello test fixtures embed.
const zero_random = "0000000000000000000000000000000000000000000000000000000000000000";

test "zix test: fromClientHello returns null without the extension" {
    // A ClientHello with no extensions at all: handshake header + version + random + empty session id
    // + one cipher suite + null compression + empty extension list.
    const client_hello = h("01" ++ "00002d" ++ "0303" ++ zero_random ++ "00" ++ "0002" ++ "1301" ++ "01" ++ "00" ++ "0000");

    try std.testing.expect(fromClientHello(&client_hello) == null);
}

test "zix test: fromClientHello finds and parses the transport parameters extension" {
    // Same ClientHello shape, now with one extension: type 0x0039, length 6, body = {0x04, len 4,
    // value 1048576}.
    const ext_body = "04" ++ "04" ++ "80100000";
    const ext = "0039" ++ "0006" ++ ext_body;
    const client_hello = h("01" ++ "000037" ++ "0303" ++ zero_random ++ "00" ++ "0002" ++ "1301" ++ "01" ++ "00" ++ "000a" ++ ext);

    const params = fromClientHello(&client_hello).?;
    try std.testing.expectEqual(@as(u64, 1048576), params.initial_max_data);
}
