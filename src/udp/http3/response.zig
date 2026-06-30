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
///
/// Return:
/// - true when the frame was written
/// - false when it does not fit in `out` from `pos` (nothing is written, `pos` is unchanged)
fn writeStreamFrame(out: []u8, pos: *usize, stream_id: u64, fin: bool, data: []const u8) bool {
    const frame_len = 1 + varint.encodedLen(stream_id) + varint.encodedLen(data.len) + data.len;
    if (pos.* + frame_len > out.len) return false;

    out[pos.*] = 0x0a | @as(u8, if (fin) 0x01 else 0); // STREAM (0x08) | LEN (0x02) | optional FIN
    pos.* += 1;
    pos.* += varint.write(out[pos.*..], stream_id);
    pos.* += varint.write(out[pos.*..], data.len);
    @memcpy(out[pos.*..][0..data.len], data);
    pos.* += data.len;

    return true;
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
///
/// Return:
/// - usize (the number of bytes written)
/// - null when the content does not fit in `out` (nothing is written)
fn buildRequestStreamContent(out: []u8, status: u16, body: []const u8) ?usize {
    // HEADERS frame: type 0x01, length, then the field section (RIC 0, Base 0, indexed :status).
    var fields: [16]u8 = undefined;
    var fp: usize = 0;
    fields[fp] = 0x00; // Required Insert Count 0
    fp += 1;
    fields[fp] = 0x00; // Base 0
    fp += 1;
    fp += statusIndexedFieldLine(fields[fp..], status);

    const headers_len = 1 + varint.encodedLen(fp) + fp;
    const data_len = 1 + varint.encodedLen(body.len) + body.len;
    if (headers_len + data_len > out.len) return null;

    var p: usize = 0;
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

/// Build the HTTP/3 response stream prefix: the HEADERS frame (`:status`) plus the DATA frame header
/// (type + body length) that the body bytes follow. The body itself is not copied here: a large body
/// is streamed straight out of the handler's slice, so only this short prefix is materialized.
///
/// Return:
/// - usize (the prefix length written into `out`)
/// - null when the prefix does not fit in `out`
pub fn buildStreamPrefix(out: []u8, status: u16, body_len: usize) ?usize {
    var fields: [16]u8 = undefined;
    var fp: usize = 0;
    fields[fp] = 0x00; // Required Insert Count 0
    fp += 1;
    fields[fp] = 0x00; // Base 0
    fp += 1;
    fp += statusIndexedFieldLine(fields[fp..], status);

    const headers_len = 1 + varint.encodedLen(fp) + fp;
    const data_header_len = 1 + varint.encodedLen(body_len);
    if (headers_len + data_header_len > out.len) return null;

    var p: usize = 0;
    out[p] = 0x01; // HEADERS frame type
    p += 1;
    p += varint.write(out[p..], fp);
    @memcpy(out[p..][0..fp], fields[0..fp]);
    p += fp;

    out[p] = 0x00; // DATA frame type
    p += 1;
    p += varint.write(out[p..], body_len);

    return p;
}

/// Build an ACK-only 1-RTT payload acknowledging packets 0..largest (RFC 9000 19.3): one contiguous
/// range. Returns 0 when there is nothing to acknowledge.
pub fn buildAck(out: []u8, ack_largest: ?u64) usize {
    const largest = ack_largest orelse return 0;

    const ack_len = 1 + varint.encodedLen(largest) + 1 + 1 + varint.encodedLen(largest);
    if (ack_len > out.len) return 0;

    var p: usize = 0;
    out[p] = 0x02; // ACK frame type
    p += 1;
    p += varint.write(out[p..], largest); // Largest Acknowledged
    p += varint.write(out[p..], 0); // ACK Delay
    p += varint.write(out[p..], 0); // ACK Range Count
    p += varint.write(out[p..], largest); // First ACK Range (largest down to 0)

    return p;
}

/// Build a MAX_STREAMS frame for bidirectional streams (RFC 9000 19.11, type 0x12): raise the
/// cumulative number of client-initiated bidi (request) streams the peer may open. A connection
/// advertises a one-time allowance in the handshake, so without periodic MAX_STREAMS the client stalls
/// once it is spent. Returns 0 when the frame does not fit in `out` (nothing is written).
pub fn buildMaxStreams(out: []u8, max_streams: u64) usize {
    const frame_len = 1 + varint.encodedLen(max_streams);
    if (frame_len > out.len) return 0;

    out[0] = 0x12; // MAX_STREAMS (bidirectional)
    var p: usize = 1;
    p += varint.write(out[p..], max_streams);

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
/// The one-shot and terminal frames a response packet may carry around the request-stream content.
///
/// Note:
/// - `handshake_done` and `control` belong on the first 1-RTT response of a connection only. The
///   server control stream (SETTINGS) and HANDSHAKE_DONE are sent once. Later per-stream responses
///   leave both false so they carry just the ACK and the request-stream HEADERS / DATA.
pub const Framing = struct {
    handshake_done: bool = true,
    control: bool = true,
    close: bool = false,
    /// When set, a MAX_STREAMS (bidi) frame raising the client's request-stream credit to this
    /// cumulative value rides this packet (RFC 9000 19.11). Set only when replenishment is due.
    max_streams_bidi: ?u64 = null,
};

/// Build the full 1-RTT payload (QUIC frames) for one HTTP/3 response on `stream_id`.
///
/// Param:
/// out - []u8 (destination for the frame payload, sealed into a 1-RTT packet by the caller)
/// stream_id - u64 (the client bidi stream the request arrived on, the response uses the same id)
/// status - u16 (the HTTP status code)
/// body - []const u8 (the response body)
/// ack_largest - ?u64 (largest client 1-RTT packet number to acknowledge, or null for no ACK)
/// framing - Framing (which one-shot / terminal frames to include)
///
/// Return:
/// - usize (the number of bytes written)
/// - null when the response does not fit in `out` (the v1 single-packet limit, caller falls back)
pub fn buildResponse(out: []u8, stream_id: u64, status: u16, body: []const u8, ack_largest: ?u64, framing: Framing) ?usize {
    // ACK the client's 1-RTT packets so it stops retransmitting (RFC 9000 19.3).
    var p: usize = buildAck(out, ack_largest);

    // HANDSHAKE_DONE (RFC 9001 7.5): confirm the handshake to the client so it finalizes the
    // connection rather than waiting. First response of the connection only.
    if (framing.handshake_done) {
        if (p + 1 > out.len) return null;
        out[p] = 0x1e;
        p += 1;
    }

    // Server control stream: the stream type (0x00) followed by an empty SETTINGS frame (0x04, 0).
    if (framing.control) {
        const control_content = [_]u8{ 0x00, 0x04, 0x00 };
        if (!writeStreamFrame(out, &p, server_control_stream, false, &control_content)) return null;
    }

    // MAX_STREAMS (RFC 9000 19.11): extend the client's request-stream credit so a long-lived
    // connection does not stall once its one-time handshake allowance is spent. Rides this packet only
    // when replenishment is due.
    if (framing.max_streams_bidi) |max_streams| {
        const written = buildMaxStreams(out[p..], max_streams);
        if (written == 0) return null;

        p += written;
    }

    // The response on the request stream, with FIN.
    var content: [1024]u8 = undefined;
    const content_len = buildRequestStreamContent(&content, status, body) orelse return null;
    if (!writeStreamFrame(out, &p, stream_id, true, content[0..content_len])) return null;

    // Application CONNECTION_CLOSE (RFC 9000 19.19, type 0x1d): H3_NO_ERROR with an empty reason, so
    // the client finalizes the connection after the response instead of waiting.
    if (framing.close) {
        const close_len = 1 + varint.encodedLen(0x0100) + varint.encodedLen(0);
        if (p + close_len > out.len) return null;

        out[p] = 0x1d; // CONNECTION_CLOSE (application)
        p += 1;
        p += varint.write(out[p..], 0x0100); // H3_NO_ERROR
        p += varint.write(out[p..], 0); // Reason Phrase Length
    }

    return p;
}

// --------------------------------------------------------------- //
// --------------------------------------------------------------- //

test "zix test: response carries control SETTINGS and a HEADERS/DATA reply" {
    var out: [1024]u8 = undefined;
    const len = buildResponse(&out, 0, 200, "hi", null, .{}).?;
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

test "zix test: response with ack and close carries both frames" {
    var out: [1024]u8 = undefined;
    const len = buildResponse(&out, 0, 200, "hi", 3, .{ .close = true }).?;
    const payload = out[0..len];

    // Leads with an ACK frame: type 0x02, largest 3, delay 0, range count 0, first range 3.
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x02, 0x03, 0x00, 0x00, 0x03 }, payload[0..5]);

    // Ends with an application CONNECTION_CLOSE (0x1d) carrying H3_NO_ERROR (0x0100 = varint 4100).
    try std.testing.expect(std.mem.indexOf(u8, payload, &[_]u8{ 0x1d, 0x41, 0x00, 0x00 }) != null);
}

test "zix test: buildMaxStreams encodes a bidi MAX_STREAMS frame, buildResponse rides it" {
    // The frame is type 0x12 then the cumulative limit as a varint (192 = 0x40c0 two-byte varint).
    var frame: [8]u8 = undefined;
    const len = buildMaxStreams(&frame, 192);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x12, 0x40, 0xc0 }, frame[0..len]);

    // A small destination that cannot hold the frame reports 0 and writes nothing.
    var tiny: [1]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), buildMaxStreams(&tiny, 192));

    // A response with max_streams_bidi set carries the 0x12 frame, a lean response without it does not.
    var out: [1024]u8 = undefined;
    const with = buildResponse(&out, 4, 200, "hi", null, .{ .handshake_done = false, .control = false, .max_streams_bidi = 192 }).?;
    try std.testing.expect(std.mem.indexOf(u8, out[0..with], &[_]u8{ 0x12, 0x40, 0xc0 }) != null);

    var out2: [1024]u8 = undefined;
    const without = buildResponse(&out2, 4, 200, "hi", null, .{ .handshake_done = false, .control = false }).?;
    try std.testing.expect(std.mem.indexOf(u8, out2[0..without], &[_]u8{0x12}) == null);
}

test "zix test: a body larger than the buffer returns null, never overflows" {
    // A body that cannot fit the single-packet buffer must report null, not write past `out`.
    var big: [4096]u8 = undefined;
    @memset(&big, 'x');

    var out: [2048]u8 = undefined;
    try std.testing.expect(buildResponse(&out, 0, 200, &big, null, .{}) == null);

    // The content builder reports the same overflow against its own destination.
    var content: [1024]u8 = undefined;
    try std.testing.expect(buildRequestStreamContent(&content, 200, &big) == null);

    // A body that just fits is still built.
    var small: [16]u8 = undefined;
    @memset(&small, 'y');
    try std.testing.expect(buildResponse(&out, 0, 200, &small, null, .{}) != null);
}

test "zix test: lean framing carries only the request stream, no HANDSHAKE_DONE or control" {
    var out: [1024]u8 = undefined;
    const len = buildResponse(&out, 4, 200, "hi", null, .{ .handshake_done = false, .control = false }).?;
    const payload = out[0..len];

    // No HANDSHAKE_DONE (0x1e) and no control stream (id 3) frame: the first byte is the request
    // STREAM frame with FIN (0x0b) on stream 4.
    try std.testing.expectEqual(@as(u8, 0x0b), payload[0]); // STREAM, LEN, FIN
    try std.testing.expectEqual(@as(u8, 4), payload[1]); // stream id 4
    try std.testing.expect(std.mem.indexOf(u8, payload, &[_]u8{0x1e}) == null);
}

test "zix test: buildStreamPrefix emits HEADERS then a DATA header sized to the body" {
    var out: [32]u8 = undefined;
    const len = buildStreamPrefix(&out, 200, 200000).?;
    const prefix = out[0..len];

    // HEADERS frame: type 0x01, length 3, RIC 0, Base 0, :status 200 (0xd9).
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x01, 0x03, 0x00, 0x00, 0xd9 }, prefix[0..5]);

    // DATA frame header: type 0x00 then the body length as a varint (200000 = 0x80030d40).
    try std.testing.expectEqual(@as(u8, 0x00), prefix[5]);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x80, 0x03, 0x0d, 0x40 }, prefix[6..10]);
}

test "zix test: writeStreamFrame refuses a frame that would overflow the buffer" {
    var out: [8]u8 = undefined;
    var pos: usize = 0;
    const data = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };

    try std.testing.expect(!writeStreamFrame(&out, &pos, 0, true, &data));
    try std.testing.expectEqual(@as(usize, 0), pos); // nothing written, pos unchanged
}
