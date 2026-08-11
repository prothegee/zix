//! Behaviour tests: what a zix.Http3 handler is given when a request carries a body, and what the
//! public decode hands the engine to build it from.

const std = @import("std");
const zix = @import("zix");

const h3_request = zix.Http3.request;
const h3_reassembly = zix.Http3.reassembly;

/// A POST on client bidi stream 0 as it arrives in a decrypted 1-RTT payload: a STREAM frame with LEN
/// and FIN (0x0b) holding a 17-byte HEADERS frame (:method POST as static index 20, :path /baseline2)
/// then a 4-byte DATA frame carrying the two bytes "20".
const post_payload_hex = "0b0015" ++ "010f" ++ "0000" ++ "d4" ++ "510a" ++ "2f626173656c696e6532" ++ "0002" ++ "3230";

/// The head of that POST with the stream left open (0x0a): the first of the two packets a client sends
/// when it writes its headers and its body separately, which is what curl does.
const post_head_payload_hex = "0a0011" ++ "010f" ++ "0000" ++ "d4" ++ "510a" ++ "2f626173656c696e6532";

/// The body of that POST: a STREAM frame at offset 17 (0x0f is STREAM | OFF | LEN | FIN) carrying the
/// DATA frame and ending the stream.
const post_body_payload_hex = "0f001104" ++ "0002" ++ "3230";

// --------------------------------------------------------- //

fn uploadHandler(req: *const zix.Http3.Request, res: *zix.Http3.Response, _: *zix.Http3.Context) anyerror!void {
    if (!req.bodyComplete()) {
        res.setStatus(400);
        res.send("incomplete body");

        return;
    }

    res.send(req.body);
}

const TestRouter = zix.Http3.Router(&[_]zix.Http3.Route{
    .{ .path = "/upload", .handler = uploadHandler },
});

fn context() zix.Http3.Context {
    return .{
        .stream_id = 0,
        .io = std.testing.io,
        .allocator = std.testing.allocator,
    };
}

// --------------------------------------------------------- //

test "zix behaviour: Http3 hands a routed handler the request body it was sent" {
    const req = zix.Http3.Request{ .method = "POST", .path = "/upload", .body = "hello", .body_received = 5 };
    var res = zix.Http3.Response{};
    var ctx = context();

    try TestRouter.dispatch(&req, &res, &ctx);

    try std.testing.expectEqual(@as(u16, 200), res.status);
    try std.testing.expectEqualStrings("hello", res.body);
}

test "zix behaviour: Http3 lets a handler refuse a body that arrived only in part" {
    // The count says five bytes came in and only two were delivered, so the handler answers 400
    // instead of parsing a fragment as if it were the whole upload.
    const req = zix.Http3.Request{ .method = "POST", .path = "/upload", .body = "he", .body_received = 5, .body_complete = false };
    var res = zix.Http3.Response{};
    var ctx = context();

    try TestRouter.dispatch(&req, &res, &ctx);

    try std.testing.expectEqual(@as(u16, 400), res.status);
    try std.testing.expectEqualStrings("incomplete body", res.body);
}

test "zix behaviour: Http3 answers a bodyless request without calling it incomplete" {
    // Nothing was sent and nothing is missing, so the handler runs its normal path and sends an empty
    // body rather than the 400.
    const req = zix.Http3.Request{ .method = "GET", .path = "/upload" };
    var res = zix.Http3.Response{};
    var ctx = context();

    try TestRouter.dispatch(&req, &res, &ctx);

    try std.testing.expectEqual(@as(u16, 200), res.status);
    try std.testing.expectEqual(@as(usize, 0), res.body.len);
}

test "zix behaviour: Http3 joins a request whose body arrives in a later packet" {
    // The two-packet shape a real client sends. Decoding each packet on its own gives a request with
    // no body and then no request at all, which is why the engine holds the first until the second
    // arrives instead of answering it.
    var head: [post_head_payload_hex.len / 2]u8 = undefined;
    _ = try std.fmt.hexToBytes(&head, post_head_payload_hex);
    var body: [post_body_payload_hex.len / 2]u8 = undefined;
    _ = try std.fmt.hexToBytes(&body, post_body_payload_hex);

    var pieces: [2]h3_request.StreamPiece = undefined;

    try std.testing.expectEqual(@as(usize, 1), h3_request.parseStreamPieces(&head, &pieces));
    const head_piece = pieces[0];
    try std.testing.expect(!head_piece.request.?.body_complete);

    try std.testing.expectEqual(@as(usize, 1), h3_request.parseStreamPieces(&body, &pieces));
    const body_piece = pieces[0];
    try std.testing.expect(body_piece.request == null);

    // Held, then completed: one request, with the body the client sent.
    var pool = try h3_reassembly.Pool.init(std.testing.allocator, h3_reassembly.default_pending_streams, h3_reassembly.default_stream_bytes);
    defer pool.deinit(std.testing.allocator);

    const cid = zix.Http3.demux.ConnId.fromSlice(&[_]u8{ 9, 8, 7, 6, 5, 4, 3, 2 });

    switch (pool.feed(1_000, &cid, head_piece.stream_id, head_piece.offset, head_piece.data, head_piece.fin)) {
        .waiting => {},
        else => return error.TestUnexpectedResult,
    }

    const slot = switch (pool.feed(1_100, &cid, body_piece.stream_id, body_piece.offset, body_piece.data, body_piece.fin)) {
        .ready => |ready| ready,
        else => return error.TestUnexpectedResult,
    };

    const decoded = h3_request.decodeStreamRequest(slot.assembled(), true).?;
    try std.testing.expectEqualStrings("POST", decoded.method);
    try std.testing.expectEqualStrings("/baseline2", decoded.path);
    try std.testing.expectEqualStrings("20", decoded.body);
    try std.testing.expect(decoded.body_complete);
}

test "zix behaviour: Http3 sizes what a handler can be given whole from the server config" {
    // Two servers, same request shape, different max_request_stream_bytes. The small one hands the
    // handler a cut body it reports as short, the large one hands it the whole upload. Nothing about
    // the request changed, so the limit is the deployment's to set rather than the engine's to fix.
    const upload = 32 * 1024;

    var small = try h3_reassembly.Pool.init(std.testing.allocator, 1, h3_reassembly.default_stream_bytes);
    defer small.deinit(std.testing.allocator);

    var large = try h3_reassembly.Pool.init(std.testing.allocator, 1, upload * 2);
    defer large.deinit(std.testing.allocator);

    const cid = zix.Http3.demux.ConnId.fromSlice(&[_]u8{ 3, 3, 3, 3, 3, 3, 3, 3 });
    const payload: [upload]u8 = @splat('u');

    switch (small.feed(1_000, &cid, 0, 0, &payload, true)) {
        .ready => |slot| try std.testing.expect(slot.dropped != 0),
        else => return error.TestUnexpectedResult,
    }

    switch (large.feed(1_000, &cid, 0, 0, &payload, true)) {
        .ready => |slot| {
            try std.testing.expectEqual(@as(u64, 0), slot.dropped);
            try std.testing.expectEqual(@as(usize, upload), slot.assembled().len);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "zix behaviour: Http3 decodes a POST body out of a 1-RTT payload" {
    var payload: [post_payload_hex.len / 2]u8 = undefined;
    _ = try std.fmt.hexToBytes(&payload, post_payload_hex);

    var reqs: [4]h3_request.StreamRequest = undefined;
    const count = h3_request.parseRequests(&payload, &reqs);

    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expectEqualStrings("POST", reqs[0].request.method);
    try std.testing.expectEqualStrings("/baseline2", reqs[0].request.path);
    try std.testing.expectEqualStrings("20", reqs[0].request.body);
    try std.testing.expectEqual(@as(u64, 2), reqs[0].request.body_received);
    try std.testing.expect(reqs[0].request.body_complete);
}
