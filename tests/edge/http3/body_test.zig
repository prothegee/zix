//! Edge tests: the boundaries of the zix.Http3 request body, where the engine has to say how much of
//! a body it really has rather than hand a handler a fragment that reads like a whole one.

const std = @import("std");
const zix = @import("zix");

const h3_request = zix.Http3.request;
const h3_reassembly = zix.Http3.reassembly;
const qpack = zix.Http3.qpack;
const varint = zix.Http3.varint;

/// QPACK static-table index of `:method POST` (RFC 9204 Appendix A).
const METHOD_POST: u64 = 20;

/// How a request is put on the wire for one test case.
const RequestShape = struct {
    path: []const u8 = "/upload",
    body: []const u8 = "",
    /// How many DATA frames the body is spread over. One is what a client sending a small body does.
    data_frames: usize = 1,
    /// Whether a trailing (empty) field section follows the body, which closes the request.
    trailers: bool = false,
    /// Whether the STREAM frame ends the stream, which is how the client says it sent everything.
    fin: bool = true,
};

/// Build a decrypted 1-RTT payload carrying one request on client bidi stream 0, from the same public
/// QPACK and varint primitives a client would use.
///
/// Param:
/// out - []u8 (destination, must hold the whole packet payload)
/// shape - RequestShape (how the request is framed)
///
/// Return:
/// - []const u8 (the payload, a slice into `out`)
fn buildPayload(out: []u8, shape: RequestShape) []const u8 {
    var fields: [256]u8 = undefined;
    var fields_len: usize = 2;
    fields[0] = 0x00; // Required Insert Count 0
    fields[1] = 0x00; // Base 0
    fields_len += qpack.encodeStaticIndexedFieldLine(fields[fields_len..], METHOD_POST);
    fields_len += qpack.encodePrefixedInt(fields[fields_len..], 4, 0x50, 1); // :path literal, static name index 1
    fields_len += qpack.encodePrefixedInt(fields[fields_len..], 7, 0x00, shape.path.len);
    @memcpy(fields[fields_len..][0..shape.path.len], shape.path);
    fields_len += shape.path.len;

    var content: [4096]u8 = undefined;
    var content_len: usize = 1;
    content[0] = 0x01; // HEADERS frame
    content_len += varint.write(content[content_len..], fields_len);
    @memcpy(content[content_len..][0..fields_len], fields[0..fields_len]);
    content_len += fields_len;

    const per_frame = if (shape.data_frames == 0) 0 else shape.body.len / shape.data_frames;
    var sent: usize = 0;
    var frame_index: usize = 0;
    while (frame_index < shape.data_frames) : (frame_index += 1) {
        const last = frame_index + 1 == shape.data_frames;
        const chunk = if (last) shape.body[sent..] else shape.body[sent..][0..per_frame];

        content[content_len] = 0x00; // DATA frame
        content_len += 1;
        content_len += varint.write(content[content_len..], chunk.len);
        @memcpy(content[content_len..][0..chunk.len], chunk);
        content_len += chunk.len;
        sent += chunk.len;
    }

    if (shape.trailers) {
        content[content_len] = 0x01; // trailing field section
        content_len += 1;
        content[content_len] = 0x02; // two bytes: the field section prefix alone
        content[content_len + 1] = 0x00;
        content[content_len + 2] = 0x00;
        content_len += 3;
    }

    var pos: usize = 1;
    out[0] = if (shape.fin) 0x0b else 0x0a; // STREAM | LEN, with or without FIN
    pos += varint.write(out[pos..], 0); // stream id 0
    pos += varint.write(out[pos..], content_len);
    @memcpy(out[pos..][0..content_len], content[0..content_len]);
    pos += content_len;

    return out[0..pos];
}

/// Build a payload carrying only body bytes for a stream already opened: one STREAM frame at `offset`
/// holding a DATA frame, ending the stream.
fn buildBodyPayload(out: []u8, offset: u64, body: []const u8) []const u8 {
    var frame: [max_body_bytes + 16]u8 = undefined;
    var frame_len: usize = 1;
    frame[0] = 0x00; // DATA frame
    frame_len += varint.write(frame[frame_len..], body.len);
    @memcpy(frame[frame_len..][0..body.len], body);
    frame_len += body.len;

    var pos: usize = 1;
    out[0] = 0x0f; // STREAM | OFF | LEN | FIN
    pos += varint.write(out[pos..], 0); // stream id 0
    pos += varint.write(out[pos..], offset);
    pos += varint.write(out[pos..], frame_len);
    @memcpy(out[pos..][0..frame_len], frame[0..frame_len]);
    pos += frame_len;

    return out[0..pos];
}

/// The largest body these tests put on the wire: one past a default-sized reassembly slot, which is
/// the boundary they exist to pin.
const max_body_bytes: usize = h3_reassembly.default_stream_bytes + 1024;

/// Decode the one request a built payload carries.
fn decodeOne(payload: []const u8) h3_request.DecodedRequest {
    return h3_request.parseRequest(payload).?;
}

/// The one request-stream frame a built payload carries.
fn onlyPiece(payload: []const u8) h3_request.StreamPiece {
    var pieces: [2]h3_request.StreamPiece = undefined;

    std.debug.assert(h3_request.parseStreamPieces(payload, &pieces) == 1);

    return pieces[0];
}

/// A pool sized the way a worker's is by default.
fn defaultPool() !h3_reassembly.Pool {
    return h3_reassembly.Pool.init(std.testing.allocator, h3_reassembly.default_pending_streams, h3_reassembly.default_stream_bytes);
}

/// Run one head packet and one body packet through a fresh pool, as the engine does, and decode what
/// comes out. Null when the pool is still waiting for more.
fn joinTwoPackets(pool: *h3_reassembly.Pool, head: []const u8, body: []const u8) ?h3_request.DecodedRequest {
    const cid = zix.Http3.demux.ConnId.fromSlice(&[_]u8{ 4, 4, 4, 4, 4, 4, 4, 4 });

    const head_piece = onlyPiece(head);
    _ = pool.feed(1_000, &cid, head_piece.stream_id, head_piece.offset, head_piece.data, head_piece.fin);

    const body_piece = onlyPiece(body);
    const slot = switch (pool.feed(1_100, &cid, body_piece.stream_id, body_piece.offset, body_piece.data, body_piece.fin)) {
        .ready => |ready| ready,
        else => return null,
    };

    var decoded = h3_request.decodeStreamRequest(slot.assembled(), true) orelse return null;
    if (slot.dropped != 0) {
        decoded.body_received += slot.dropped;
        decoded.body_complete = false;
    }

    return decoded;
}

// --------------------------------------------------------- //

test "zix edge: Http3 reads an empty DATA frame as a body that arrived whole" {
    // A client that sends a body frame with nothing in it has still finished: zero bytes is the whole
    // body, not a body that fell short.
    var buf: [512]u8 = undefined;
    const payload = buildPayload(&buf, .{ .body = "", .data_frames = 1 });

    const decoded = decodeOne(payload);
    try std.testing.expectEqual(@as(usize, 0), decoded.body.len);
    try std.testing.expectEqual(@as(u64, 0), decoded.body_received);
    try std.testing.expect(decoded.body_complete);
}

test "zix edge: Http3 delivers a body that fills the rest of the datagram" {
    // A single DATA frame near the path-MTU limit, the largest body one packet can carry.
    var body: [1000]u8 = @splat('z');
    var buf: [2048]u8 = undefined;
    const payload = buildPayload(&buf, .{ .body = &body });

    const decoded = decodeOne(payload);
    try std.testing.expectEqual(@as(usize, body.len), decoded.body.len);
    try std.testing.expectEqualSlices(u8, &body, decoded.body);
    try std.testing.expectEqual(@as(u64, body.len), decoded.body_received);
    try std.testing.expect(decoded.body_complete);
}

test "zix edge: Http3 reports a body split across DATA frames as short, never as whole" {
    // The frames are not adjacent on the wire, so only the first is delivered. The count is what keeps
    // this from reading as a complete four-byte body, which is the failure that would be silent.
    var buf: [512]u8 = undefined;
    const payload = buildPayload(&buf, .{ .body = "2022", .data_frames = 2 });

    const decoded = decodeOne(payload);
    try std.testing.expectEqualSlices(u8, "20", decoded.body);
    try std.testing.expectEqual(@as(u64, 4), decoded.body_received);
    try std.testing.expect(!decoded.body_complete);
}

test "zix edge: Http3 keeps a body whole when trailers close the request" {
    // A trailing field section after the body is legal (RFC 9114 4.1) and ends the request, so the
    // body before it is everything the client sent.
    var buf: [512]u8 = undefined;
    const payload = buildPayload(&buf, .{ .body = "20", .trailers = true });

    const decoded = decodeOne(payload);
    try std.testing.expectEqualSlices(u8, "20", decoded.body);
    try std.testing.expectEqual(@as(u64, 2), decoded.body_received);
    try std.testing.expect(decoded.body_complete);
}

test "zix edge: Http3 joins a body that arrives in a second packet, up to the ceiling" {
    // The head in one packet, a body that fits in the next: the request comes out whole, which is the
    // shape every real client sends.
    var head_buf: [512]u8 = undefined;
    const head = buildPayload(&head_buf, .{ .fin = false });

    var body_bytes: [1024]u8 = @splat('y');
    var body_buf: [2048]u8 = undefined;
    const body = buildBodyPayload(&body_buf, onlyPiece(head).data.len, &body_bytes);

    var pool = try defaultPool();
    defer pool.deinit(std.testing.allocator);

    const decoded = joinTwoPackets(&pool, head, body).?;

    try std.testing.expectEqual(@as(usize, body_bytes.len), decoded.body.len);
    try std.testing.expectEqualSlices(u8, &body_bytes, decoded.body);
    try std.testing.expectEqual(@as(u64, body_bytes.len), decoded.body_received);
    try std.testing.expect(decoded.body_complete);
}

test "zix edge: Http3 answers a body past the configured stream size short, and says it is cut" {
    // One byte past what a default-sized slot holds. The handler is answered rather than left
    // hanging, with the bytes that fit and a count that is not smaller than what really arrived.
    var head_buf: [512]u8 = undefined;
    const head = buildPayload(&head_buf, .{ .fin = false });

    var body_bytes: [max_body_bytes]u8 = @splat('y');
    var body_buf: [max_body_bytes + 64]u8 = undefined;
    const body = buildBodyPayload(&body_buf, onlyPiece(head).data.len, &body_bytes);

    var pool = try defaultPool();
    defer pool.deinit(std.testing.allocator);

    const decoded = joinTwoPackets(&pool, head, body).?;

    try std.testing.expect(decoded.body.len < body_bytes.len);
    try std.testing.expect(decoded.body_received >= body_bytes.len);
    try std.testing.expect(!decoded.body_complete);

    // What is delivered is the front of the body, not a scrambled window of it.
    try std.testing.expectEqualSlices(u8, body_bytes[0..decoded.body.len], decoded.body);
}

test "zix edge: Http3 delivers that same body whole once the config makes room for it" {
    // The knob is what turns the cut above into a whole body: max_request_stream_bytes sized past the
    // upload, nothing else changed. Without it the ceiling is the engine's, not the deployment's.
    var head_buf: [512]u8 = undefined;
    const head = buildPayload(&head_buf, .{ .fin = false });

    var body_bytes: [max_body_bytes]u8 = @splat('y');
    var body_buf: [max_body_bytes + 64]u8 = undefined;
    const body = buildBodyPayload(&body_buf, onlyPiece(head).data.len, &body_bytes);

    var pool = try h3_reassembly.Pool.init(std.testing.allocator, 1, max_body_bytes * 2);
    defer pool.deinit(std.testing.allocator);

    const decoded = joinTwoPackets(&pool, head, body).?;

    try std.testing.expectEqual(@as(usize, body_bytes.len), decoded.body.len);
    try std.testing.expectEqualSlices(u8, &body_bytes, decoded.body);
    try std.testing.expectEqual(@as(u64, body_bytes.len), decoded.body_received);
    try std.testing.expect(decoded.body_complete);
}

test "zix edge: Http3 extends a held stream past the credit the handshake granted it" {
    // A client may send only what the handshake allowed on one stream until the server raises the
    // limit. A held request has no reply to carry that raise, so the pool tracks it: without the
    // grant, an upload larger than the allowance stops halfway and is never answered at all.
    const allowance: u64 = 4096;

    var pool = try h3_reassembly.Pool.init(std.testing.allocator, 1, h3_reassembly.default_stream_bytes);
    defer pool.deinit(std.testing.allocator);

    const cid = zix.Http3.demux.ConnId.fromSlice(&[_]u8{ 7, 7, 7, 7, 7, 7, 7, 7 });
    var chunk: [1024]u8 = @splat('u');

    var sent: u64 = 0;
    var limit = allowance;
    while (sent < allowance * 4) : (sent += chunk.len) {
        const slot = switch (pool.feed(1_000 + sent, &cid, 0, sent, &chunk, false)) {
            .waiting => |waiting| waiting,
            else => return error.TestUnexpectedResult,
        };

        if (slot.replenishStreamData(allowance)) |granted| limit = granted;

        // The client is never asked to stop: the limit stays ahead of every byte it has sent.
        try std.testing.expect(limit >= sent + chunk.len);
    }

    try std.testing.expect(limit > allowance);
}

test "zix edge: Http3 refuses a request head it has no room to assemble rather than answering it short" {
    // Every slot busy with a request still arriving. The refusal is what the engine turns into a 503:
    // no handler is run, so no handler is handed a body that is still on its way.
    var head_buf: [512]u8 = undefined;
    const head = buildPayload(&head_buf, .{ .fin = false });
    const head_piece = onlyPiece(head);

    var pool = try h3_reassembly.Pool.init(std.testing.allocator, 1, h3_reassembly.default_stream_bytes);
    defer pool.deinit(std.testing.allocator);

    const first = zix.Http3.demux.ConnId.fromSlice(&[_]u8{ 1, 1, 1, 1, 1, 1, 1, 1 });
    const second = zix.Http3.demux.ConnId.fromSlice(&[_]u8{ 2, 2, 2, 2, 2, 2, 2, 2 });

    switch (pool.feed(1_000, &first, head_piece.stream_id, head_piece.offset, head_piece.data, head_piece.fin)) {
        .waiting => {},
        else => return error.TestUnexpectedResult,
    }

    switch (pool.feed(1_001, &second, head_piece.stream_id, head_piece.offset, head_piece.data, head_piece.fin)) {
        .refused => {},
        else => return error.TestUnexpectedResult,
    }
}

test "zix edge: Http3 will not call a body whole while the client is still sending" {
    // Same bytes, no end-of-stream bit: more may follow on this stream, so the delivered body is a
    // part of the request rather than the request.
    var buf: [512]u8 = undefined;
    const payload = buildPayload(&buf, .{ .body = "20", .fin = false });

    const decoded = decodeOne(payload);
    try std.testing.expectEqualSlices(u8, "20", decoded.body);
    try std.testing.expectEqual(@as(u64, 2), decoded.body_received);
    try std.testing.expect(!decoded.body_complete);
}
