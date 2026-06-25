//! zix HTTP/3 request decode: pull :method and :path out of a decrypted 1-RTT payload.
//!
//! What:
//! - Walks the QUIC frames in the payload, finds the client request stream (a client-initiated bidi
//!   stream), parses its HTTP/3 HEADERS frame, and QPACK-decodes the :method and :path pseudo-headers
//!   from the static table and literal-with-name-reference representations (RFC 9114 / RFC 9204).
//! - Pseudo-headers precede regular fields, so the decode returns as soon as both are found and never
//!   has to understand the rest of the header block.

const std = @import("std");

const varint = @import("varint.zig");
const qpack = @import("qpack.zig");

/// The decoded request line. Slices point into the payload (or into a Huffman-decode buffer).
pub const DecodedRequest = struct {
    method: []const u8,
    path: []const u8,
    path_huffman: bool = false,
};

/// Find and decode the request from a decrypted 1-RTT payload. Returns null if no request HEADERS are
/// present (for example a packet that only carries ACK / control-stream frames).
///
/// Note:
/// - A 1-RTT request packet typically leads with frames this module does not need (ACK, and the
///   client's control / QPACK stream setup). It walks past every frame it does not model, scanning
///   only for the client request stream, so an unmodeled frame is skipped rather than fatal.
pub fn parseRequest(payload: []const u8) ?DecodedRequest {
    var pos: usize = 0;
    while (pos < payload.len) {
        const type_vi = varint.read(payload[pos..]) catch break;

        if (isStreamFrameType(type_vi.value)) {
            if (parseStreamFrame(payload[pos..])) |stream| {
                if (stream.id & 0x03 == 0) {
                    if (decodeRequestStream(stream.data)) |req| return req;
                }

                pos += stream.consumed;
                continue;
            }

            break;
        }

        // A frame this module does not need (ACK, MAX_DATA, NEW_CONNECTION_ID, ...). Skip it.
        const skipped = skipFrame(payload[pos..]) orelse break;
        pos += skipped;
    }

    return null;
}

/// Whether a frame type is a STREAM frame (RFC 9000 19.8): 0x08..0x0f, OFF / LEN / FIN in the low bits.
fn isStreamFrameType(frame_type: u64) bool {
    return frame_type >= 0x08 and frame_type <= 0x0f;
}

const ParsedStream = struct { id: u64, data: []const u8, consumed: usize };

/// Parse a STREAM frame, returning the stream id, the stream bytes, and how much of `buf` it used.
fn parseStreamFrame(buf: []const u8) ?ParsedStream {
    const frame_type = buf[0];
    var pos: usize = 1;

    const id = varint.read(buf[pos..]) catch return null;
    pos += id.len;

    if (frame_type & 0x04 != 0) {
        const offset = varint.read(buf[pos..]) catch return null;
        pos += offset.len;
    }

    const has_len = frame_type & 0x02 != 0;
    const length: usize = if (has_len) blk: {
        const len_vi = varint.read(buf[pos..]) catch return null;
        pos += len_vi.len;
        break :blk @intCast(len_vi.value);
    } else buf.len - pos;

    if (pos + length > buf.len) return null;

    return .{ .id = id.value, .data = buf[pos .. pos + length], .consumed = pos + length };
}

/// Read `n` consecutive varints from `start`, returning the position after them, or null if any is
/// truncated.
fn skipVarints(buf: []const u8, start: usize, n: usize) ?usize {
    var pos = start;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const v = varint.read(buf[pos..]) catch return null;
        pos += v.len;
    }

    return pos;
}

/// Skip a varint length followed by that many bytes (CRYPTO data, NEW_TOKEN token, close reason).
fn skipLenBlob(buf: []const u8, start: usize) ?usize {
    const len = varint.read(buf[start..]) catch return null;
    const end = start + len.len + @as(usize, @intCast(len.value));

    return if (end <= buf.len) end else null;
}

/// Skip any non-STREAM QUIC frame (RFC 9000 19), returning the bytes it occupied or null on a
/// truncated / unknown frame. The scan needs this to walk past everything a request packet coalesces
/// ahead of the request stream (ACK, NEW_CONNECTION_ID, MAX_STREAMS, and the rest).
fn skipFrame(buf: []const u8) ?usize {
    const type_vi = varint.read(buf) catch return null;
    const pos = type_vi.len;

    switch (type_vi.value) {
        0x00, 0x01, 0x1e => return pos, // PADDING, PING, HANDSHAKE_DONE
        0x02, 0x03 => { // ACK (0x03 adds ECN counts)
            var p = pos;
            const largest = varint.read(buf[p..]) catch return null;
            p += largest.len;
            const delay = varint.read(buf[p..]) catch return null;
            p += delay.len;
            const range_count = varint.read(buf[p..]) catch return null;
            p += range_count.len;
            const first = varint.read(buf[p..]) catch return null;
            p += first.len;

            var i: u64 = 0;
            while (i < range_count.value) : (i += 1) {
                p = skipVarints(buf, p, 2) orelse return null; // Gap, Range Length
            }
            if (type_vi.value == 0x03) p = skipVarints(buf, p, 3) orelse return null; // ECT0, ECT1, CE

            return p;
        },
        0x04 => return skipVarints(buf, pos, 3), // RESET_STREAM
        0x05, 0x11, 0x15 => return skipVarints(buf, pos, 2), // STOP_SENDING, MAX_STREAM_DATA, STREAM_DATA_BLOCKED
        0x10, 0x12, 0x13, 0x14, 0x16, 0x17, 0x19 => return skipVarints(buf, pos, 1), // MAX_DATA, MAX_STREAMS, *_BLOCKED, RETIRE_CONNECTION_ID
        0x06 => return skipLenBlob(buf, skipVarints(buf, pos, 1) orelse return null), // CRYPTO: offset then length + data
        0x07 => return skipLenBlob(buf, pos), // NEW_TOKEN: length + token
        0x18 => { // NEW_CONNECTION_ID: seq, retire, len(1), cid, reset token(16)
            const after = skipVarints(buf, pos, 2) orelse return null;
            if (after >= buf.len) return null;
            const cid_len = buf[after];
            const end = after + 1 + cid_len + 16;

            return if (end <= buf.len) end else null;
        },
        0x1a, 0x1b => return if (pos + 8 <= buf.len) pos + 8 else null, // PATH_CHALLENGE / PATH_RESPONSE
        0x1c, 0x1d => { // CONNECTION_CLOSE: error code, [frame type if 0x1c], reason length + reason
            var p = skipVarints(buf, pos, 1) orelse return null;
            if (type_vi.value == 0x1c) p = skipVarints(buf, p, 1) orelse return null;

            return skipLenBlob(buf, p);
        },
        else => return null, // STREAM is handled by the caller, an unknown / grease frame stops the scan
    }
}

/// Parse the HTTP/3 frames of a request stream, decoding the first HEADERS frame.
fn decodeRequestStream(stream_data: []const u8) ?DecodedRequest {
    var pos: usize = 0;
    while (pos < stream_data.len) {
        const type_vi = varint.read(stream_data[pos..]) catch return null;
        pos += type_vi.len;

        const len_vi = varint.read(stream_data[pos..]) catch return null;
        pos += len_vi.len;

        const frame_len: usize = @intCast(len_vi.value);
        if (pos + frame_len > stream_data.len) return null;

        const frame_data = stream_data[pos .. pos + frame_len];
        pos += frame_len;

        if (type_vi.value == 0x01) return decodeHeaders(frame_data); // HEADERS
    }

    return null;
}

/// QPACK-decode a HEADERS field section enough to recover :method and :path (RFC 9204 4.5).
fn decodeHeaders(section: []const u8) ?DecodedRequest {
    var pos: usize = 0;

    // Encoded Field Section Prefix: Required Insert Count (8-bit prefix) + Base (7-bit prefix).
    const ric = qpack.decodePrefixedInt(section[pos..], 8) catch return null;
    pos += ric.len;
    const base = qpack.decodePrefixedInt(section[pos..], 7) catch return null;
    pos += base.len;

    var method: []const u8 = "";
    var path: []const u8 = "";
    var path_huffman = false;

    while (pos < section.len) {
        const lead = section[pos];

        if (lead & 0x80 != 0) {
            // Indexed Field Line (static or dynamic).
            const idx = qpack.decodeIndexedFieldLine(section[pos..]) catch return null;
            pos += idx.len;

            if (idx.static) {
                if (qpack.staticEntry(idx.index)) |entry| {
                    if (std.mem.eql(u8, entry.name, ":method")) method = entry.value;
                    if (std.mem.eql(u8, entry.name, ":path")) path = entry.value;
                }
            }
        } else if (lead & 0xc0 == 0x40) {
            // Literal Field Line with Name Reference.
            const lit = qpack.decodeLiteralNameRef(section[pos..]) catch return null;
            pos += lit.len;

            if (lit.static) {
                if (qpack.staticEntry(lit.name_index)) |entry| {
                    if (std.mem.eql(u8, entry.name, ":method")) method = lit.value;
                    if (std.mem.eql(u8, entry.name, ":path")) {
                        path = lit.value;
                        path_huffman = lit.huffman;
                    }
                }
            }
        } else {
            // A representation this minimal decoder does not model. Pseudo-headers come first, so if
            // :method and :path are already in hand the rest does not matter.
            break;
        }

        if (method.len != 0 and path.len != 0) break;
    }

    if (method.len == 0 or path.len == 0) return null;

    return .{ .method = method, .path = path, .path_huffman = path_huffman };
}

// --------------------------------------------------------------- //
// --------------------------------------------------------------- //

fn h(comptime text: []const u8) [text.len / 2]u8 {
    var out: [text.len / 2]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, text) catch unreachable;

    return out;
}

test "zix test: parseRequest decodes method and path past a leading ACK" {
    // ACK (0x02, largest 0, skipped) then STREAM frame on stream 0 carrying a HEADERS frame:
    // field section prefix 0000, :method GET as an indexed static line (0xd1), :path /baseline2 as a
    // literal-with-name-reference (0x51 = static name index 1, 0x0a = non-Huffman length 10).
    const payload = h("0200000000" ++ "0a0011" ++ "010f" ++ "0000" ++ "d1" ++ "510a" ++ "2f626173656c696e6532");

    const decoded = parseRequest(&payload).?;
    try std.testing.expectEqualSlices(u8, "GET", decoded.method);
    try std.testing.expectEqualSlices(u8, "/baseline2", decoded.path);
    try std.testing.expect(!decoded.path_huffman);
}

test "zix test: parseRequest returns null when no request stream is present" {
    // A packet with only an ACK frame: nothing to decode.
    try std.testing.expect(parseRequest(&h("0200000000")) == null);
}
