//! zix HTTP/3 1-RTT response framing (RFC 9114).
//!
//! What:
//! - Builds the QUIC 1-RTT payload for a minimal HTTP/3 response: opens the server control stream
//!   with a SETTINGS frame (required first frame, RFC 9114 6.2.1), and sends a HEADERS frame
//!   (`:status`, QPACK-encoded) plus a DATA frame (the body) on the request stream with FIN.
//! - The response uses only the QPACK static table (no dynamic table), so the field section prefix
//!   is Required Insert Count 0 / Base 0 (two zero bytes).

const std = @import("std");

const varint = @import("varint.zig");
const qpack = @import("qpack.zig");

/// The server-initiated unidirectional control stream id (RFC 9000 2.1: server uni ids are 3, 7, ...).
const server_control_stream: u64 = 3;

/// Write a STREAM frame (RFC 9000 19.8) at offset 0 with an explicit length. `fin` sets the FIN bit.
fn writeStreamFrame(out: []u8, pos: *usize, stream_id: u64, fin: bool, data: []const u8) void {
    out[pos.*] = 0x0a | @as(u8, if (fin) 0x01 else 0); // STREAM (0x08) | LEN (0x02) | optional FIN
    pos.* += 1;
    pos.* += varint.write(out[pos.*..], stream_id);
    pos.* += varint.write(out[pos.*..], data.len);
    @memcpy(out[pos.*..][0..data.len], data);
    pos.* += data.len;
}

/// The QPACK indexed field line for a `:status` value from the static table (RFC 9204 Appendix A
/// entries 24..28). Falls back to 200 for an unlisted status.
fn statusIndexedFieldLine(out: []u8, status: u16) usize {
    const index: u64 = switch (status) {
        103 => 24,
        200 => 25,
        304 => 26,
        404 => 27,
        503 => 28,
        else => 25,
    };

    return qpack.encodeStaticIndexedFieldLine(out, index);
}

/// Build the response content for the request stream: a HEADERS frame carrying `:status`, then a DATA
/// frame carrying the body (RFC 9114 7.2.1 / 7.2.2).
fn buildRequestStreamContent(out: []u8, status: u16, body: []const u8) usize {
    var p: usize = 0;

    // HEADERS frame: type 0x01, length, then the field section (RIC 0, Base 0, indexed :status).
    var fields: [16]u8 = undefined;
    var fp: usize = 0;
    fields[fp] = 0x00; // Required Insert Count 0
    fp += 1;
    fields[fp] = 0x00; // Base 0
    fp += 1;
    fp += statusIndexedFieldLine(fields[fp..], status);

    out[p] = 0x01; // HEADERS frame type
    p += 1;
    p += varint.write(out[p..], fp);
    @memcpy(out[p..][0..fp], fields[0..fp]);
    p += fp;

    // DATA frame: type 0x00, length, body.
    out[p] = 0x00; // DATA frame type
    p += 1;
    p += varint.write(out[p..], body.len);
    @memcpy(out[p..][0..body.len], body);
    p += body.len;

    return p;
}

/// Build the full 1-RTT payload (QUIC frames) for one HTTP/3 response.
///
/// Param:
/// out - []u8 (destination for the frame payload, sealed into a 1-RTT packet by the caller)
/// request_stream_id - u64 (the client bidi stream the request arrived on)
/// status - u16 (the HTTP status code)
/// body - []const u8 (the response body)
///
/// Return:
/// - usize (the number of bytes written)
pub fn buildResponse(out: []u8, request_stream_id: u64, status: u16, body: []const u8) usize {
    var p: usize = 0;

    // HANDSHAKE_DONE (RFC 9001 7.5): confirm the handshake to the client so it finalizes the
    // connection rather than waiting.
    out[p] = 0x1e;
    p += 1;

    // Server control stream: the stream type (0x00) followed by an empty SETTINGS frame (0x04, 0).
    const control_content = [_]u8{ 0x00, 0x04, 0x00 };
    writeStreamFrame(out, &p, server_control_stream, false, &control_content);

    // The response on the request stream, with FIN.
    var content: [1024]u8 = undefined;
    const content_len = buildRequestStreamContent(&content, status, body);
    writeStreamFrame(out, &p, request_stream_id, true, content[0..content_len]);

    return p;
}

// --------------------------------------------------------------- //
// --------------------------------------------------------------- //

test "zix test: response carries control SETTINGS and a HEADERS/DATA reply" {
    var out: [1024]u8 = undefined;
    const len = buildResponse(&out, 0, 200, "hi");
    const payload = out[0..len];

    // HANDSHAKE_DONE, then a STREAM frame on the server control stream (id 3) carrying the control
    // type + SETTINGS.
    try std.testing.expectEqual(@as(u8, 0x1e), payload[0]); // HANDSHAKE_DONE
    try std.testing.expectEqual(@as(u8, 0x0a), payload[1]); // STREAM, LEN, no FIN
    try std.testing.expectEqual(@as(u8, 3), payload[2]); // stream id 3
    try std.testing.expectEqual(@as(u8, 3), payload[3]); // content length 3
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x04, 0x00 }, payload[4..7]);

    // Then a STREAM frame on stream 0 with FIN, containing HEADERS (:status 200 = 0xd9) and DATA.
    try std.testing.expectEqual(@as(u8, 0x0b), payload[7]); // STREAM, LEN, FIN
    try std.testing.expect(std.mem.indexOf(u8, payload, &[_]u8{ 0x01, 0x03, 0x00, 0x00, 0xd9 }) != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "hi") != null);
}
