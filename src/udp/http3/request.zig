//! zix HTTP/3 request decode: pull :method and :path out of a decrypted 1-RTT payload.
//!
//! What:
//! - Walks the QUIC frames in the payload, finds the client request stream (a client-initiated bidi
//!   stream), parses its HTTP/3 HEADERS frame, and QPACK-decodes the :method and :path pseudo-headers
//!   from the static table and literal-with-name-reference representations (RFC 9114 / RFC 9204).
//! - Pseudo-headers precede regular fields, so the header decode returns as soon as the fields it
//!   needs are found and never has to understand the rest of the header block.
//! - Keeps the DATA frames that follow HEADERS on the same stream as the request body, plus the two
//!   facts a handler needs to trust it: how many body bytes the stream carried, and whether the
//!   client had finished sending.

const std = @import("std");

const varint = @import("varint.zig");
const qpack = @import("qpack.zig");

/// The decoded request line. Slices point into the payload (or into a Huffman-decode buffer).
pub const DecodedRequest = struct {
    method: []const u8,
    path: []const u8,
    path_huffman: bool = false,
    /// The client's `accept-encoding` value, or empty when absent. Set from the QPACK static entry 31
    /// (`gzip, deflate, br`) for the indexed form, or from the literal value for a custom one. When
    /// `accept_encoding_huffman` is set the value is still Huffman-encoded and the serve path expands it.
    accept_encoding: []const u8 = "",
    accept_encoding_huffman: bool = false,
    /// The request body, empty when the request carried none. It points into the bytes it was decoded
    /// from, so nothing is copied and the slice lives exactly as long as the fields above do.
    /// `decodeAssembledRequest` joins every DATA frame into it. The read-only decodes carry only the
    /// first, since they cannot move bytes they do not own.
    body: []const u8 = "",
    /// Every DATA byte this stream carried, HTTP/3 framing excluded. It exceeds `body.len` when the
    /// client split its body over several DATA frames and the decode could not join them: the two
    /// together are what tell a partial body from a whole one.
    body_received: u64 = 0,
    /// Whether `body` is the whole request body. True needs all three: the frame walk reached the end
    /// of the stream data cleanly, every counted DATA byte sits inside `body`, and the STREAM frame
    /// ended the stream (FIN) with nothing before it (offset 0).
    body_complete: bool = false,
};

/// A decoded request paired with the client bidi stream it arrived on, so the response goes back on
/// the same stream (RFC 9114 6.1).
pub const StreamRequest = struct {
    stream_id: u64,
    request: DecodedRequest,
};

/// One client request-stream STREAM frame out of a payload, with what it turned out to hold.
///
/// Note:
/// - `request` is set when the bytes start with a HEADERS frame this decode understands, which makes
///   them the head of a request. It is null for a continuation: the body of a request whose head
///   arrived in an earlier packet, which only means something once the two are joined.
pub const StreamPiece = struct {
    stream_id: u64,
    /// Where these bytes sit in the stream. Non-zero means bytes were sent on it before.
    offset: u64,
    /// Whether the frame ends the stream, so the client has sent everything.
    fin: bool,
    /// The raw stream bytes, as HTTP/3 frames.
    data: []const u8,
    request: ?DecodedRequest,
};

/// The most request streams the server decodes from one packet, sized to hold a path-MTU 1-RTT packet
/// densely packed with small requests. The packet is acknowledged whole, so any request left undecoded
/// would be dropped-but-acked and its stream would stall.
pub const max_requests_per_packet = 96;

/// Find and decode the request from a decrypted 1-RTT payload. Returns null if no request HEADERS are
/// present (for example a packet that only carries ACK / control-stream frames).
///
/// Note:
/// - A 1-RTT request packet typically leads with frames this module does not need (ACK, and the
///   client's control / QPACK stream setup). It walks past every frame it does not model, scanning
///   only for the client request stream, so an unmodeled frame is skipped rather than fatal.
pub fn parseRequest(payload: []const u8) ?DecodedRequest {
    var one: [1]StreamRequest = undefined;
    if (parseRequests(payload, &one) == 0) return null;

    return one[0].request;
}

/// Decode every client request stream in a decrypted 1-RTT payload, in arrival order, capturing the
/// stream id of each. A connection multiplexes many requests, each on its own client-initiated bidi
/// stream, and one packet can coalesce several. The scan walks past every non-request frame.
///
/// Param:
/// payload - []const u8 (the decrypted 1-RTT payload)
/// out - []StreamRequest (destination, decoding stops once it is full)
///
/// Return:
/// - usize (the number of request streams decoded into `out`)
pub fn parseRequests(payload: []const u8, out: []StreamRequest) usize {
    var pieces: [max_requests_per_packet]StreamPiece = undefined;
    const limit = @min(out.len, pieces.len);
    const piece_count = parseStreamPieces(payload, pieces[0..limit]);

    var count: usize = 0;
    for (pieces[0..piece_count]) |piece| {
        const decoded = piece.request orelse continue;

        out[count] = .{ .stream_id = piece.stream_id, .request = decoded };
        count += 1;
    }

    return count;
}

/// Walk every client request-stream STREAM frame in a decrypted 1-RTT payload, in arrival order,
/// decoding the ones that carry a request head. The scan walks past every non-STREAM frame.
///
/// Note:
/// - This is what the serve path uses, because a request with a body does not arrive whole: a client
///   commonly sends its HEADERS frame in one packet and its DATA frame in the next, and the second
///   frame decodes to no request at all on its own. Handing back both kinds lets the caller join them.
///
/// Param:
/// payload - []const u8 (the decrypted 1-RTT payload)
/// out - []StreamPiece (destination, the walk stops once it is full)
///
/// Return:
/// - usize (the number of pieces written into `out`)
pub fn parseStreamPieces(payload: []const u8, out: []StreamPiece) usize {
    var count: usize = 0;
    var pos: usize = 0;
    while (pos < payload.len and count < out.len) {
        const type_vi = varint.read(payload[pos..]) catch break;

        if (isStreamFrameType(type_vi.value)) {
            const stream = parseStreamFrame(payload[pos..]) orelse break;

            // A client-initiated bidi stream (id mod 4 == 0) carries a request (RFC 9000 2.1).
            if (stream.id & 0x03 == 0) {
                // A head only decodes at the start of the stream. Past that the bytes are a body,
                // which is a continuation whatever they happen to look like.
                const at_start = stream.offset == 0;
                out[count] = .{
                    .stream_id = stream.id,
                    .offset = stream.offset,
                    .fin = stream.fin,
                    .data = stream.data,
                    .request = if (at_start) decodeStreamRequest(stream.data, stream.fin) else null,
                };
                count += 1;
            }

            pos += stream.consumed;
            continue;
        }

        // A frame this module does not need (ACK, MAX_DATA, NEW_CONNECTION_ID, ...). Skip it.
        const skipped = skipFrame(payload[pos..]) orelse break;
        pos += skipped;
    }

    return count;
}

/// Decode a request out of the bytes of one request stream, from its start.
///
/// Note:
/// - Used for both shapes: the stream bytes of a single packet, and the bytes a caller reassembled
///   across packets. `ended` is what the caller knows about the client being finished (the FIN bit on
///   the last frame), and it is what a whole body ultimately depends on.
///
/// Param:
/// stream_data - []const u8 (request-stream bytes from offset 0, as HTTP/3 frames)
/// ended - bool (whether the client has ended the stream)
///
/// Return:
/// - DecodedRequest
/// - null when the bytes carry no HEADERS frame this decode understands
pub fn decodeStreamRequest(stream_data: []const u8, ended: bool) ?DecodedRequest {
    var decoded = decodeRequestStream(stream_data) orelse return null;
    decoded.body_complete = decoded.body_complete and ended;

    return decoded;
}

/// Decode a request out of a buffer the caller owns, joining its DATA frames into one body.
///
/// Note:
/// - Same decode as `decodeStreamRequest`, with one difference that matters for anything larger than
///   a small upload: a client writes a long body as several DATA frames, and this joins their
///   payloads into a single slice instead of delivering the first and reporting the rest as missing.
/// - The join happens inside `stream_data`, so the caller must own those bytes. The reassembly pool
///   does, its slots are the worker's own. The decrypted packet payload does NOT: the serve path
///   walks it again afterwards for flow-control accounting, so that path uses `decodeStreamRequest`.
/// - Every payload moves backwards by at least the frame header it leaves behind (two bytes), so the
///   move never overwrites a byte the walk has not read yet.
///
/// Param:
/// stream_data - []u8 (request-stream bytes from offset 0, as HTTP/3 frames, owned by the caller)
/// ended - bool (whether the client has ended the stream)
///
/// Return:
/// - DecodedRequest (its `body` slices `stream_data`)
/// - null when the bytes carry no HEADERS frame this decode understands
pub fn decodeAssembledRequest(stream_data: []u8, ended: bool) ?DecodedRequest {
    var decoded: DecodedRequest = undefined;
    var have_headers = false;
    var walk = FrameWalk{ .total = stream_data.len };

    // Where the joined body starts, and where the next payload lands behind it.
    var body_start: usize = 0;
    var body_end: usize = 0;

    while (walk.next(stream_data)) |frame| {
        const is_data = frame.kind == 0x00;

        // A frame cut short, because the buffer filled before the client finished. Its bytes are
        // still body bytes when it is a DATA frame, so they are joined and counted like any other:
        // what makes the difference is that `walk.intact` has gone false, so nothing calls it whole.
        if (frame.cut and !(is_data and have_headers)) break;

        switch (frame.kind) {
            0x01 => { // HEADERS
                // A second field section is the trailers, which close the request (RFC 9114 4.1).
                if (have_headers) break;

                decoded = decodeHeaders(stream_data[frame.start..][0..frame.len]) orelse return null;
                have_headers = true;
            },
            0x00 => { // DATA
                // DATA before HEADERS is H3_FRAME_UNEXPECTED, and there is no request to attach it to.
                if (!have_headers) return null;

                if (decoded.body_received == 0) {
                    body_start = frame.start;
                    body_end = frame.start;
                }

                std.mem.copyForwards(u8, stream_data[body_end..][0..frame.len], stream_data[frame.start..][0..frame.len]);
                body_end += frame.len;
                decoded.body_received += frame.len;
            },
            else => {}, // A frame this decode does not model (a grease frame, a reserved type).
        }

        if (frame.cut) break;
    }

    if (!have_headers) return null;

    decoded.body = stream_data[body_start..body_end];
    decoded.body_complete = walk.intact and ended;

    return decoded;
}

/// Sum the STREAM-frame payload bytes in a decrypted 1-RTT payload, across every stream (bidi and
/// uni: connection-level flow control counts them all, RFC 9000 4.1). Feeds replenishMaxData so the
/// server keeps the client's MAX_DATA credit ahead of what it consumes.
pub fn streamBytes(payload: []const u8) u64 {
    var total: u64 = 0;
    var pos: usize = 0;

    while (pos < payload.len) {
        const type_vi = varint.read(payload[pos..]) catch break;

        if (isStreamFrameType(type_vi.value)) {
            const stream = parseStreamFrame(payload[pos..]) orelse break;
            total += stream.data.len;
            pos += stream.consumed;
            continue;
        }

        const skipped = skipFrame(payload[pos..]) orelse break;
        pos += skipped;
    }

    return total;
}

/// Whether a frame type is a STREAM frame (RFC 9000 19.8): 0x08..0x0f, OFF / LEN / FIN in the low bits.
pub fn isStreamFrameType(frame_type: u64) bool {
    return frame_type >= 0x08 and frame_type <= 0x0f;
}

pub const ParsedStream = struct {
    id: u64,
    data: []const u8,
    consumed: usize,
    /// Where `data` starts within the stream (RFC 9000 19.8 OFF bit). Zero means this frame carries the
    /// beginning of the stream, so nothing was sent on it before.
    offset: u64 = 0,
    /// Whether the frame ends the stream (the FIN bit): the peer sends nothing more on it.
    fin: bool = false,
};

/// Parse a STREAM frame, returning the stream id, the stream bytes, and how much of `buf` it used.
pub fn parseStreamFrame(buf: []const u8) ?ParsedStream {
    const frame_type = buf[0];
    var pos: usize = 1;

    const id = varint.read(buf[pos..]) catch return null;
    pos += id.len;

    var offset: u64 = 0;
    if (frame_type & 0x04 != 0) {
        const offset_vi = varint.read(buf[pos..]) catch return null;
        pos += offset_vi.len;
        offset = offset_vi.value;
    }

    const has_len = frame_type & 0x02 != 0;
    const length: usize = if (has_len) blk: {
        const len_vi = varint.read(buf[pos..]) catch return null;
        pos += len_vi.len;
        break :blk @intCast(len_vi.value);
    } else buf.len - pos;

    if (pos + length > buf.len) return null;

    return .{
        .id = id.value,
        .data = buf[pos .. pos + length],
        .consumed = pos + length,
        .offset = offset,
        .fin = frame_type & 0x01 != 0,
    };
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
pub fn skipFrame(buf: []const u8) ?usize {
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

/// Parse the HTTP/3 frames of a request stream: the first HEADERS frame gives the request line, the
/// DATA frames after it give the body (RFC 9114 4.1).
///
/// Note:
/// - A malformed or truncated frame ends the walk instead of failing the request, once HEADERS is in
///   hand: the request line is real and answerable, the body is simply not whole, which
///   `body_complete` reports. Before HEADERS there is nothing to answer, so it stays a null.
/// - Only the first DATA frame is delivered as `body`, because separate frames are not adjacent in the
///   stream (each carries its own header) and joining them would need a copy. Every frame is still
///   counted into `body_received`, so a split body is detectable rather than silently short.
/// One HTTP/3 frame out of a request stream, given as offsets rather than a slice so a caller holding
/// the bytes as mutable can move payloads around while it reads them.
const Frame = struct {
    /// The HTTP/3 frame type (RFC 9114 7.2): 0x00 DATA, 0x01 HEADERS.
    kind: u64,
    /// Where the frame payload starts in the stream bytes.
    start: usize,
    /// Payload bytes present. For a cut frame this is what arrived, not what the frame declared.
    len: usize,
    /// Whether the frame ran past the bytes that arrived.
    cut: bool = false,
};

/// Walk the HTTP/3 frames of a request stream. Shared by both decodes so they agree on what a frame
/// is, what a cut frame is, and when the walk has stopped trusting the bytes.
const FrameWalk = struct {
    total: usize,
    pos: usize = 0,
    /// False once a frame header failed to read or a frame ran past the bytes that arrived. A request
    /// is never whole after that, whatever the frames before it held.
    intact: bool = true,

    fn next(self: *FrameWalk, stream: []const u8) ?Frame {
        if (self.pos >= self.total) return null;

        const type_vi = varint.read(stream[self.pos..]) catch {
            self.intact = false;

            return null;
        };
        var at = self.pos + type_vi.len;

        const len_vi = varint.read(stream[at..]) catch {
            self.intact = false;

            return null;
        };
        at += len_vi.len;

        const declared: usize = @intCast(len_vi.value);
        if (at + declared > self.total) {
            self.intact = false;
            self.pos = self.total;

            return .{ .kind = type_vi.value, .start = at, .len = self.total - at, .cut = true };
        }

        self.pos = at + declared;

        return .{ .kind = type_vi.value, .start = at, .len = declared };
    }
};

fn decodeRequestStream(stream_data: []const u8) ?DecodedRequest {
    var decoded: DecodedRequest = undefined;
    var have_headers = false;
    var walk = FrameWalk{ .total = stream_data.len };

    while (walk.next(stream_data)) |frame| {
        const frame_data = stream_data[frame.start..][0..frame.len];

        // A frame cut short, because the datagram was or because reassembly ran out of room. The
        // bytes of a cut DATA frame are still body bytes, so they are delivered and counted: what
        // makes the difference is that the request is no longer marked whole.
        if (frame.cut) {
            if (frame.kind == 0x00 and have_headers) {
                if (decoded.body.len == 0) decoded.body = frame_data;
                decoded.body_received += frame_data.len;
            }

            break;
        }

        switch (frame.kind) {
            0x01 => { // HEADERS
                // A second field section is the trailers, which close the request (RFC 9114 4.1), so
                // the walk is done and whatever body came before it is whole.
                if (have_headers) break;

                decoded = decodeHeaders(frame_data) orelse return null;
                have_headers = true;
            },
            0x00 => { // DATA
                // DATA before HEADERS is H3_FRAME_UNEXPECTED, and there is no request to attach it to.
                if (!have_headers) return null;

                if (decoded.body.len == 0) decoded.body = frame_data;
                decoded.body_received += frame_data.len;
            },
            else => {}, // A frame this decode does not model (a grease frame, a reserved type).
        }
    }

    if (!have_headers) return null;

    // What this layer can vouch for: the frames read out whole, and the body it hands over holds every
    // byte it counted. parseRequests adds the stream-level end signal on top.
    decoded.body_complete = walk.intact and decoded.body.len == decoded.body_received;

    return decoded;
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
    var accept_encoding: []const u8 = "";
    var accept_encoding_huffman = false;

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
                    if (std.mem.eql(u8, entry.name, "accept-encoding")) accept_encoding = entry.value;
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
                    if (std.mem.eql(u8, entry.name, "accept-encoding")) {
                        accept_encoding = lit.value;
                        accept_encoding_huffman = lit.huffman;
                    }
                }
            }
        } else {
            // A representation this minimal decoder does not model. The pseudo-headers and the
            // static-referenced regular fields it needs come first, so what remains does not matter.
            break;
        }

        // accept-encoding is a regular field (after the pseudo-headers), so the scan continues past
        // :method and :path to reach it, stopping once all three are in hand.
        if (method.len != 0 and path.len != 0 and accept_encoding.len != 0) break;
    }

    if (method.len == 0 or path.len == 0) return null;

    return .{
        .method = method,
        .path = path,
        .path_huffman = path_huffman,
        .accept_encoding = accept_encoding,
        .accept_encoding_huffman = accept_encoding_huffman,
    };
}

// --------------------------------------------------------------- //
// --------------------------------------------------------------- //

fn hexBytes(comptime text: []const u8) [text.len / 2]u8 {
    var out: [text.len / 2]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, text) catch unreachable;

    return out;
}

/// The HEADERS frame the body tests reuse: 17 bytes on the wire (frame type 0x01, length 0x0f, then a
/// 15-byte field section) carrying :method POST as indexed static line 20 (0xd4) and :path /baseline2
/// as a literal with name reference (0x51, non-Huffman length 0x0a).
const post_headers_frame = "010f" ++ "0000" ++ "d4" ++ "510a" ++ "2f626173656c696e6532";

/// A DATA frame carrying the two bytes "20" (frame type 0x00, length 0x02), 4 bytes on the wire.
const data_frame_20 = "0002" ++ "3230";

test "zix http3: streamBytes sums stream payloads across streams, skipping non-stream frames" {
    // ACK (skipped, charges nothing), a 17-byte request STREAM on bidi stream 0, then a 3-byte
    // STREAM on client uni stream 2: connection-level flow control counts both (RFC 9000 4.1).
    const payload = hexBytes("0200000000" ++ "0a0011" ++ "010f" ++ "0000" ++ "d1" ++ "510a" ++ "2f626173656c696e6532" ++ "0a0203" ++ "000400");
    try std.testing.expectEqual(@as(u64, 20), streamBytes(&payload));

    // A payload with no STREAM frame charges nothing.
    const ack_only = hexBytes("0200000000");
    try std.testing.expectEqual(@as(u64, 0), streamBytes(&ack_only));
}

test "zix http3: parseRequest decodes method and path past a leading ACK" {
    // ACK (0x02, largest 0, skipped) then STREAM frame on stream 0 carrying a HEADERS frame:
    // field section prefix 0000, :method GET as an indexed static line (0xd1), :path /baseline2 as a
    // literal-with-name-reference (0x51 = static name index 1, 0x0a = non-Huffman length 10).
    const payload = hexBytes("0200000000" ++ "0a0011" ++ "010f" ++ "0000" ++ "d1" ++ "510a" ++ "2f626173656c696e6532");

    const decoded = parseRequest(&payload).?;
    try std.testing.expectEqualSlices(u8, "GET", decoded.method);
    try std.testing.expectEqualSlices(u8, "/baseline2", decoded.path);
    try std.testing.expect(!decoded.path_huffman);
}

test "zix http3: parseRequest captures accept-encoding from the indexed static entry" {
    // Like the test above but the HEADERS field section adds accept-encoding as an indexed static line
    // (0xdf = static index 31, value "gzip, deflate, br"). Field section is now 16 bytes (0x10), so the
    // HEADERS frame is 0x12 and the STREAM length 0x12. The scan runs past :method / :path to reach it.
    const payload = hexBytes("0200000000" ++ "0a0012" ++ "0110" ++ "0000" ++ "d1" ++ "510a" ++ "2f626173656c696e6532" ++ "df");

    const decoded = parseRequest(&payload).?;
    try std.testing.expectEqualSlices(u8, "GET", decoded.method);
    try std.testing.expectEqualSlices(u8, "/baseline2", decoded.path);
    try std.testing.expectEqualSlices(u8, "gzip, deflate, br", decoded.accept_encoding);
    try std.testing.expect(!decoded.accept_encoding_huffman);
}

test "zix http3: parseRequest leaves accept-encoding empty when the client sends none" {
    // The original request shape (no accept-encoding field): the value stays empty, and the serve path
    // then falls back to an identity response.
    const payload = hexBytes("0200000000" ++ "0a0011" ++ "010f" ++ "0000" ++ "d1" ++ "510a" ++ "2f626173656c696e6532");

    const decoded = parseRequest(&payload).?;
    try std.testing.expectEqual(@as(usize, 0), decoded.accept_encoding.len);
}

test "zix http3: parseRequest returns null when no request stream is present" {
    // A packet with only an ACK frame: nothing to decode.
    try std.testing.expect(parseRequest(&hexBytes("0200000000")) == null);
}

test "zix http3: parseRequests decodes two coalesced requests with their stream ids" {
    // Two STREAM frames in one packet: stream 0 (GET /baseline2) then stream 4 (GET /baseline2),
    // each a HEADERS frame with field section prefix 0000, :method GET (0xd1), :path literal.
    const one = "0a0011" ++ "010f" ++ "0000" ++ "d1" ++ "510a" ++ "2f626173656c696e6532";
    const two = "0a0411" ++ "010f" ++ "0000" ++ "d1" ++ "510a" ++ "2f626173656c696e6532";
    const payload = hexBytes("0200000000" ++ one ++ two);

    var reqs: [4]StreamRequest = undefined;
    const count = parseRequests(&payload, &reqs);

    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expectEqual(@as(u64, 0), reqs[0].stream_id);
    try std.testing.expectEqual(@as(u64, 4), reqs[1].stream_id);
    try std.testing.expectEqualSlices(u8, "GET", reqs[1].request.method);
    try std.testing.expectEqualSlices(u8, "/baseline2", reqs[1].request.path);
}

test "zix http3: parseStreamFrame reports the end-of-stream bit and the stream offset" {
    // 0x0b is STREAM | LEN | FIN on stream 0 at offset 0, the shape a client uses for a request that
    // fits one packet.
    const with_fin = hexBytes("0b0002" ++ "3230");
    const ended = parseStreamFrame(&with_fin).?;
    try std.testing.expect(ended.fin);
    try std.testing.expectEqual(@as(u64, 0), ended.offset);
    try std.testing.expectEqualSlices(u8, "20", ended.data);

    // 0x0e is STREAM | OFF | LEN with no FIN: a continuation the client will add to.
    const continuation = hexBytes("0e000802" ++ "3232");
    const more = parseStreamFrame(&continuation).?;
    try std.testing.expect(!more.fin);
    try std.testing.expectEqual(@as(u64, 8), more.offset);
    try std.testing.expectEqualSlices(u8, "22", more.data);
}

test "zix http3: parseRequest delivers the DATA frame body of a POST, request whole" {
    // STREAM | LEN | FIN on stream 0, 21 bytes: the 17-byte HEADERS frame then a 4-byte DATA frame.
    const payload = hexBytes("0200000000" ++ "0b0015" ++ post_headers_frame ++ data_frame_20);

    const decoded = parseRequest(&payload).?;
    try std.testing.expectEqualSlices(u8, "POST", decoded.method);
    try std.testing.expectEqualSlices(u8, "/baseline2", decoded.path);
    try std.testing.expectEqualSlices(u8, "20", decoded.body);
    try std.testing.expectEqual(@as(u64, 2), decoded.body_received);
    try std.testing.expect(decoded.body_complete);
}

test "zix http3: parseRequest hands over a body the client has not finished, no FIN" {
    // The same request with 0x0a (STREAM | LEN, no FIN): the bytes are real, but the client may still
    // send more on this stream, so the body must not be reported as whole.
    const payload = hexBytes("0200000000" ++ "0a0015" ++ post_headers_frame ++ data_frame_20);

    const decoded = parseRequest(&payload).?;
    try std.testing.expectEqualSlices(u8, "20", decoded.body);
    try std.testing.expectEqual(@as(u64, 2), decoded.body_received);
    try std.testing.expect(!decoded.body_complete);
}

test "zix http3: parseRequest counts every DATA frame but delivers the first, split body" {
    // Two DATA frames ("20" then "22"), 25 bytes of stream data. They are not adjacent on the wire, so
    // only the first is handed over, and the count is what tells the handler bytes are missing.
    const payload = hexBytes("0200000000" ++ "0b0019" ++ post_headers_frame ++ data_frame_20 ++ "0002" ++ "3232");

    const decoded = parseRequest(&payload).?;
    try std.testing.expectEqualSlices(u8, "20", decoded.body);
    try std.testing.expectEqual(@as(u64, 4), decoded.body_received);
    try std.testing.expect(!decoded.body_complete);
}

test "zix http3: parseRequest reports a GET with no body as whole" {
    // HEADERS and nothing else, the stream ended: there is no body and nothing to fall short of.
    const payload = hexBytes("0200000000" ++ "0b0011" ++ "010f" ++ "0000" ++ "d1" ++ "510a" ++ "2f626173656c696e6532");

    const decoded = parseRequest(&payload).?;
    try std.testing.expectEqual(@as(usize, 0), decoded.body.len);
    try std.testing.expectEqual(@as(u64, 0), decoded.body_received);
    try std.testing.expect(decoded.body_complete);
}

test "zix http3: parseStreamPieces reports a frame past the stream start as a continuation" {
    // 0x0f is STREAM | OFF | LEN | FIN at offset 8: bytes were sent on this stream before this frame.
    // Whatever these bytes look like they are a body, not a request head, so nothing is decoded out of
    // them here. The serve path joins them to the head that arrived earlier.
    const payload = hexBytes("0f000815" ++ post_headers_frame ++ data_frame_20);

    var pieces: [2]StreamPiece = undefined;
    try std.testing.expectEqual(@as(usize, 1), parseStreamPieces(&payload, &pieces));
    try std.testing.expectEqual(@as(u64, 8), pieces[0].offset);
    try std.testing.expect(pieces[0].fin);
    try std.testing.expect(pieces[0].request == null);
    try std.testing.expectEqual(@as(usize, 21), pieces[0].data.len);

    // The same bytes are no request on their own, which is what a continuation means.
    try std.testing.expect(parseRequest(&payload) == null);
}

test "zix http3: parseStreamPieces hands back the head and the continuation of one request" {
    // The shape a client puts on the wire for a POST: the HEADERS frame with the stream left open,
    // then the body at the offset the head ended on, ending the stream.
    const head = "0a0011" ++ "010f" ++ "0000" ++ "d4" ++ "510a" ++ "2f626173656c696e6532";
    const body = "0f001104" ++ data_frame_20;
    const payload = hexBytes(head ++ body);

    var pieces: [4]StreamPiece = undefined;
    try std.testing.expectEqual(@as(usize, 2), parseStreamPieces(&payload, &pieces));

    // The head decodes, but nothing about it is servable yet: the client has not finished.
    const decoded = pieces[0].request.?;
    try std.testing.expectEqualSlices(u8, "POST", decoded.method);
    try std.testing.expectEqual(@as(usize, 0), decoded.body.len);
    try std.testing.expect(!decoded.body_complete);

    // The continuation carries the body bytes and the end of the stream.
    try std.testing.expect(pieces[1].request == null);
    try std.testing.expectEqual(@as(u64, 17), pieces[1].offset);
    try std.testing.expect(pieces[1].fin);
    try std.testing.expectEqualSlices(u8, &hexBytes(data_frame_20), pieces[1].data);
}

test "zix http3: decodeStreamRequest reads a request out of reassembled stream bytes" {
    // What the serve path holds once it has joined the two frames above: the same bytes, contiguous,
    // with the client known to have finished.
    const assembled = hexBytes(post_headers_frame ++ data_frame_20);

    const decoded = decodeStreamRequest(&assembled, true).?;
    try std.testing.expectEqualSlices(u8, "POST", decoded.method);
    try std.testing.expectEqualSlices(u8, "/baseline2", decoded.path);
    try std.testing.expectEqualSlices(u8, "20", decoded.body);
    try std.testing.expectEqual(@as(u64, 2), decoded.body_received);
    try std.testing.expect(decoded.body_complete);

    // The same bytes with the client not finished are the same request, minus the promise.
    const open_stream = decodeStreamRequest(&assembled, false).?;
    try std.testing.expectEqualSlices(u8, "20", open_stream.body);
    try std.testing.expect(!open_stream.body_complete);
}

test "zix http3: decodeAssembledRequest joins a body the client wrote as several DATA frames" {
    // Three DATA frames on one stream, which is what a client does with any body larger than its
    // write buffer. Read-only, the first is all a handler could be given and the rest reads as
    // missing. Joined in the buffer the worker owns, it is one body.
    var assembled = hexBytes(post_headers_frame ++ data_frame_20 ++ "0002" ++ "3232" ++ "0003" ++ "343536");

    const decoded = decodeAssembledRequest(&assembled, true).?;
    try std.testing.expectEqualSlices(u8, "POST", decoded.method);
    try std.testing.expectEqualSlices(u8, "/baseline2", decoded.path);
    try std.testing.expectEqualSlices(u8, "2022456", decoded.body);
    try std.testing.expectEqual(@as(u64, 7), decoded.body_received);
    try std.testing.expect(decoded.body_complete);
}

test "zix http3: decodeAssembledRequest leaves the request line intact while it joins the body" {
    // The join moves body bytes backwards over the frame headers it drops, and the method and path
    // sit in front of all of it. Reading them after the move is what proves nothing was overwritten.
    var assembled = hexBytes(post_headers_frame ++ data_frame_20 ++ "0002" ++ "3232");

    const decoded = decodeAssembledRequest(&assembled, true).?;
    try std.testing.expectEqualSlices(u8, "POST", decoded.method);
    try std.testing.expectEqualSlices(u8, "/baseline2", decoded.path);
    try std.testing.expectEqualSlices(u8, "2022", decoded.body);

    // The body is a slice of the buffer, not a copy out of it.
    try std.testing.expect(@intFromPtr(decoded.body.ptr) >= @intFromPtr(&assembled));
    try std.testing.expect(@intFromPtr(decoded.body.ptr) + decoded.body.len <= @intFromPtr(&assembled) + assembled.len);
}

test "zix http3: decodeAssembledRequest still reports a cut trailing DATA frame as short" {
    // The last frame declares 16 bytes and 2 arrived, which is what the slot filling up looks like.
    // The joined body keeps everything real, and the request is not called whole.
    var assembled = hexBytes(post_headers_frame ++ data_frame_20 ++ "0010" ++ "3232");

    const decoded = decodeAssembledRequest(&assembled, true).?;
    try std.testing.expectEqualSlices(u8, "2022", decoded.body);
    try std.testing.expectEqual(@as(u64, 4), decoded.body_received);
    try std.testing.expect(!decoded.body_complete);
}

test "zix http3: decodeAssembledRequest keeps the body whole across a trailing field section" {
    // Trailers close the request (RFC 9114 4.1), so the joined body before them is everything sent.
    var assembled = hexBytes(post_headers_frame ++ data_frame_20 ++ "0002" ++ "3232" ++ "01020000");

    const decoded = decodeAssembledRequest(&assembled, true).?;
    try std.testing.expectEqualSlices(u8, "2022", decoded.body);
    try std.testing.expectEqual(@as(u64, 4), decoded.body_received);
    try std.testing.expect(decoded.body_complete);
}

test "zix http3: decodeAssembledRequest agrees with the read-only decode on a single-frame body" {
    // The common shape must not change just because it took the joining path: same body, same counts.
    var assembled = hexBytes(post_headers_frame ++ data_frame_20);
    const read_only = decodeStreamRequest(&assembled, true).?;
    const joined = decodeAssembledRequest(&assembled, true).?;

    try std.testing.expectEqualSlices(u8, read_only.body, joined.body);
    try std.testing.expectEqual(read_only.body_received, joined.body_received);
    try std.testing.expectEqual(read_only.body_complete, joined.body_complete);
}

test "zix http3: decodeAssembledRequest refuses a stream whose DATA frame precedes its HEADERS" {
    var assembled = hexBytes(data_frame_20 ++ post_headers_frame);

    try std.testing.expect(decodeAssembledRequest(&assembled, true) == null);
}

test "zix http3: parseRequest delivers a cut DATA frame short instead of dropping or trusting it" {
    // 0x09 is STREAM | FIN with no length, so the stream runs to the end of the payload. The DATA frame
    // declares 16 bytes and only 2 are there, which is what a cut-off datagram looks like: the request
    // line is answerable, the two bytes are real body bytes and are handed over, and FIN alone must not
    // call the result whole.
    const payload = hexBytes("0900" ++ post_headers_frame ++ "0010" ++ "3230");

    const decoded = parseRequest(&payload).?;
    try std.testing.expectEqualSlices(u8, "POST", decoded.method);
    try std.testing.expectEqualSlices(u8, "20", decoded.body);
    try std.testing.expectEqual(@as(u64, 2), decoded.body_received);
    try std.testing.expect(!decoded.body_complete);
}

test "zix http3: parseRequest refuses a stream whose DATA frame precedes its HEADERS" {
    // DATA before HEADERS is H3_FRAME_UNEXPECTED (RFC 9114 4.1). There is no request line to answer
    // with, so the stream decodes to nothing rather than to a request with a stray body.
    const payload = hexBytes("0b0015" ++ data_frame_20 ++ post_headers_frame);

    try std.testing.expect(parseRequest(&payload) == null);
}

test "zix http3: parseRequests gives each coalesced request its own body" {
    // One datagram, two requests: a POST with a body on stream 0 and a bodyless GET on stream 4. The
    // body must land on the stream that carried it and nowhere else.
    const post = "0b0015" ++ post_headers_frame ++ data_frame_20;
    const get = "0b0411" ++ "010f" ++ "0000" ++ "d1" ++ "510a" ++ "2f626173656c696e6532";
    const payload = hexBytes(post ++ get);

    var reqs: [4]StreamRequest = undefined;
    const count = parseRequests(&payload, &reqs);

    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expectEqualSlices(u8, "20", reqs[0].request.body);
    try std.testing.expect(reqs[0].request.body_complete);

    try std.testing.expectEqual(@as(usize, 0), reqs[1].request.body.len);
    try std.testing.expectEqual(@as(u64, 0), reqs[1].request.body_received);
    try std.testing.expect(reqs[1].request.body_complete);
}
