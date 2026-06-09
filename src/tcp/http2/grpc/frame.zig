//! gRPC 5-byte message prefix codec and gRPC frame send functions.

const std = @import("std");
const h2 = @import("../Http2.zig");

// --------------------------------------------------------- //

/// gRPC length-prefix header size: 1 compress flag + 4 message length bytes.
pub const grpc_prefix_len: usize = 5;

/// gRPC 5-byte length-prefix header.
pub const GrpcPrefix = struct {
    compress: bool,
    msg_len: u32,
};

/// Parse the 5-byte gRPC prefix from the start of body.
pub fn readGrpcPrefix(body: []const u8) error{TooShort}!GrpcPrefix {
    if (body.len < grpc_prefix_len) return error.TooShort;
    const msg_len = std.mem.readInt(u32, body[1..grpc_prefix_len], .big);
    return .{ .compress = body[0] != 0, .msg_len = msg_len };
}

/// Write a 5-byte gRPC prefix into buf.
pub fn writeGrpcPrefix(buf: *[grpc_prefix_len]u8, compress: bool, msg_len: u32) void {
    buf[0] = if (compress) 1 else 0;
    std.mem.writeInt(u32, buf[1..grpc_prefix_len], msg_len, .big);
}

// --------------------------------------------------------- //

/// The default gRPC content-type. Its response HEADERS block is the same on every call, so it
/// is HPACK-encoded once at comptime and memcpy'd on the hot path instead of re-encoded.
pub const GRPC_CONTENT_TYPE = "application/grpc+proto";

/// Comptime HPACK block for the initial response HEADERS (:status 200, content-type proto).
const HEADERS_PROTO_BLOCK = blk: {
    var buf: [128]u8 = undefined;
    var enc = h2.HpackEncoder.init(&buf);
    enc.writeHeader(":status", "200") catch unreachable;
    enc.writeHeader("content-type", GRPC_CONTENT_TYPE) catch unreachable;
    const encoded = enc.encoded();

    var out: [encoded.len]u8 = undefined;
    @memcpy(&out, encoded);
    break :blk out;
};

/// Comptime HPACK block for the OK trailer (grpc-status: 0, no message), the common close.
const TRAILER_OK_BLOCK = blk: {
    var buf: [64]u8 = undefined;
    var enc = h2.HpackEncoder.init(&buf);
    enc.writeHeader("grpc-status", "0") catch unreachable;
    const encoded = enc.encoded();

    var out: [encoded.len]u8 = undefined;
    @memcpy(&out, encoded);
    break :blk out;
};

/// Stamp a HEADERS frame header (with stream_id and flags) plus a precomputed HPACK block into
/// out. Return: bytes written.
fn emitCachedHeaders(out: []u8, stream_id: u31, flags: u8, block: []const u8) usize {
    var fh: [9]u8 = undefined;
    h2.encodeFrameHeader(&fh, .{
        .length = @intCast(block.len),
        .frame_type = h2.FT_HEADERS,
        .flags = flags,
        .stream_id = stream_id,
    });
    @memcpy(out[0..9], &fh);
    @memcpy(out[9..][0..block.len], block);
    return 9 + block.len;
}

/// Encode initial response HEADERS (:status 200, content-type) into out. No END_STREAM.
/// The default gRPC content-type takes a precomputed block (no HPACK encode on the hot path).
/// Return:
/// - bytes written into out.
pub fn buildGrpcHeaders(out: []u8, stream_id: u31, content_type: []const u8) usize {
    if (std.mem.eql(u8, content_type, GRPC_CONTENT_TYPE)) {
        return emitCachedHeaders(out, stream_id, h2.FLAG_END_HEADERS, &HEADERS_PROTO_BLOCK);
    }

    var hdr_buf: [512]u8 = undefined;
    var hpack_enc = h2.HpackEncoder.init(&hdr_buf);
    hpack_enc.writeHeader(":status", "200") catch return 0;
    hpack_enc.writeHeader("content-type", content_type) catch return 0;
    const hblock = hpack_enc.encoded();

    var fh: [9]u8 = undefined;
    h2.encodeFrameHeader(&fh, .{
        .length = @intCast(hblock.len),
        .frame_type = h2.FT_HEADERS,
        .flags = h2.FLAG_END_HEADERS,
        .stream_id = stream_id,
    });
    @memcpy(out[0..9], &fh);
    @memcpy(out[9..][0..hblock.len], hblock);
    return 9 + hblock.len;
}

/// Encode the 9-byte DATA frame header plus the 5-byte gRPC prefix into out (14 bytes).
/// The caller appends the message payload after these 14 bytes.
/// Return:
/// - bytes written into out (always 14).
pub fn buildGrpcDataHeader(out: []u8, stream_id: u31, msg_len: usize) usize {
    var fh: [9]u8 = undefined;
    h2.encodeFrameHeader(&fh, .{
        .length = @intCast(5 + msg_len),
        .frame_type = h2.FT_DATA,
        .flags = 0,
        .stream_id = stream_id,
    });
    @memcpy(out[0..9], &fh);
    writeGrpcPrefix(out[9..14], false, @intCast(msg_len));
    return 14;
}

/// Encode trailer HEADERS (grpc-status, grpc-message) into out. FLAG_END_STREAM.
/// Return:
/// - bytes written into out.
pub fn buildGrpcTrailer(out: []u8, stream_id: u31, grpc_status: u8, grpc_message: []const u8) usize {
    if (grpc_status == 0 and grpc_message.len == 0) {
        return emitCachedHeaders(out, stream_id, h2.FLAG_END_HEADERS | h2.FLAG_END_STREAM, &TRAILER_OK_BLOCK);
    }

    var hdr_buf: [512]u8 = undefined;
    var hpack_enc = h2.HpackEncoder.init(&hdr_buf);
    var status_str: [4]u8 = undefined;
    const status_s = std.fmt.bufPrint(&status_str, "{d}", .{grpc_status}) catch "0";
    hpack_enc.writeHeader("grpc-status", status_s) catch return 0;
    if (grpc_message.len > 0) hpack_enc.writeHeader("grpc-message", grpc_message) catch return 0;
    const hblock = hpack_enc.encoded();

    var fh: [9]u8 = undefined;
    h2.encodeFrameHeader(&fh, .{
        .length = @intCast(hblock.len),
        .frame_type = h2.FT_HEADERS,
        .flags = h2.FLAG_END_HEADERS | h2.FLAG_END_STREAM,
        .stream_id = stream_id,
    });
    @memcpy(out[0..9], &fh);
    @memcpy(out[9..][0..hblock.len], hblock);
    return 9 + hblock.len;
}

/// Encode a trailers-only error response (no DATA frame) into out.
/// Includes :status 200 and content-type per gRPC spec.
/// Return:
/// - bytes written into out.
pub fn buildGrpcError(out: []u8, stream_id: u31, grpc_status: u8, grpc_message: []const u8) usize {
    var hdr_buf: [512]u8 = undefined;
    var hpack_enc = h2.HpackEncoder.init(&hdr_buf);
    hpack_enc.writeHeader(":status", "200") catch return 0;
    hpack_enc.writeHeader("content-type", "application/grpc+proto") catch return 0;
    var status_str: [4]u8 = undefined;
    const status_s = std.fmt.bufPrint(&status_str, "{d}", .{grpc_status}) catch "0";
    hpack_enc.writeHeader("grpc-status", status_s) catch return 0;
    if (grpc_message.len > 0) hpack_enc.writeHeader("grpc-message", grpc_message) catch return 0;
    const hblock = hpack_enc.encoded();

    var fh: [9]u8 = undefined;
    h2.encodeFrameHeader(&fh, .{
        .length = @intCast(hblock.len),
        .frame_type = h2.FT_HEADERS,
        .flags = h2.FLAG_END_HEADERS | h2.FLAG_END_STREAM,
        .stream_id = stream_id,
    });
    @memcpy(out[0..9], &fh);
    @memcpy(out[9..][0..hblock.len], hblock);
    return 9 + hblock.len;
}

/// Send initial response HEADERS (:status 200, content-type). No END_STREAM.
pub fn sendGrpcHeaders(fd: std.posix.fd_t, stream_id: u31, content_type: []const u8) !void {
    var buf: [600]u8 = undefined;
    const n = buildGrpcHeaders(&buf, stream_id, content_type);
    try h2.fdWriteAll(fd, buf[0..n]);
}

/// Send one DATA frame with 5-byte gRPC prefix. No END_STREAM.
pub fn sendGrpcData(fd: std.posix.fd_t, stream_id: u31, message: []const u8) !void {
    var head: [14]u8 = undefined;
    _ = buildGrpcDataHeader(&head, stream_id, message.len);

    try h2.fdWriteAll(fd, &head);
    try h2.fdWriteAll(fd, message);
}

/// Send trailer HEADERS (grpc-status, grpc-message). FLAG_END_STREAM.
pub fn sendGrpcTrailer(fd: std.posix.fd_t, stream_id: u31, grpc_status: u8, grpc_message: []const u8) !void {
    var buf: [600]u8 = undefined;
    const n = buildGrpcTrailer(&buf, stream_id, grpc_status, grpc_message);
    try h2.fdWriteAll(fd, buf[0..n]);
}

/// Send trailers-only error response (no DATA frame). Includes :status 200 and content-type per gRPC spec.
pub fn sendGrpcError(fd: std.posix.fd_t, stream_id: u31, grpc_status: u8, grpc_message: []const u8) !void {
    var buf: [600]u8 = undefined;
    const n = buildGrpcError(&buf, stream_id, grpc_status, grpc_message);
    try h2.fdWriteAll(fd, buf[0..n]);
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //

test "zix grpc: cached buildGrpcHeaders proto decodes to status 200 + content-type" {
    var buf: [128]u8 = undefined;
    const n = buildGrpcHeaders(&buf, 1, GRPC_CONTENT_TYPE);
    const fh = h2.parseFrameHeader(buf[0..9]);
    try std.testing.expectEqual(h2.FT_HEADERS, fh.frame_type);
    try std.testing.expectEqual(h2.FLAG_END_HEADERS, fh.flags);

    var decoder = h2.HpackDecoder.init();
    var headers: [8]h2.Header = undefined;
    var scratch: [256]u8 = undefined;
    const count = try decoder.decode(buf[9..n], &headers, &scratch);

    var saw_status = false;
    var saw_ct = false;
    for (headers[0..count]) |h| {
        if (std.mem.eql(u8, h.name, ":status") and std.mem.eql(u8, h.value, "200")) saw_status = true;
        if (std.mem.eql(u8, h.name, "content-type") and std.mem.eql(u8, h.value, GRPC_CONTENT_TYPE)) saw_ct = true;
    }
    try std.testing.expect(saw_status and saw_ct);
}

test "zix grpc: cached buildGrpcTrailer OK decodes to grpc-status 0 with END_STREAM" {
    var buf: [64]u8 = undefined;
    const n = buildGrpcTrailer(&buf, 3, 0, "");
    const fh = h2.parseFrameHeader(buf[0..9]);
    try std.testing.expectEqual(h2.FT_HEADERS, fh.frame_type);
    try std.testing.expectEqual(h2.FLAG_END_HEADERS | h2.FLAG_END_STREAM, fh.flags);

    var decoder = h2.HpackDecoder.init();
    var headers: [8]h2.Header = undefined;
    var scratch: [256]u8 = undefined;
    const count = try decoder.decode(buf[9..n], &headers, &scratch);

    var saw_status = false;
    for (headers[0..count]) |h| {
        if (std.mem.eql(u8, h.name, "grpc-status") and std.mem.eql(u8, h.value, "0")) saw_status = true;
    }
    try std.testing.expect(saw_status);
}

test "zix grpc: readGrpcPrefix too short" {
    const body = [_]u8{ 0, 0, 0 };
    try std.testing.expectError(error.TooShort, readGrpcPrefix(&body));
}

test "zix grpc: readGrpcPrefix and writeGrpcPrefix roundtrip" {
    var body: [5]u8 = undefined;
    writeGrpcPrefix(&body, false, 42);
    const p = try readGrpcPrefix(&body);
    try std.testing.expect(!p.compress);
    try std.testing.expectEqual(@as(u32, 42), p.msg_len);
}

test "zix grpc: writeGrpcPrefix compress flag set" {
    var body: [5]u8 = undefined;
    writeGrpcPrefix(&body, true, 0);
    try std.testing.expectEqual(@as(u8, 1), body[0]);
}

test "zix grpc: readGrpcPrefix exactly 5 bytes is valid" {
    var body: [5]u8 = undefined;
    writeGrpcPrefix(&body, false, 0);
    const p = try readGrpcPrefix(&body);
    try std.testing.expectEqual(@as(u32, 0), p.msg_len);
}

test "zix grpc: sendGrpcError includes content-type header" {
    const pipe_fds = try std.Io.Threaded.pipe2(.{});
    defer _ = std.posix.system.close(pipe_fds[0]);
    defer _ = std.posix.system.close(pipe_fds[1]);

    try sendGrpcError(pipe_fds[1], 1, 3, "");

    var buf: [256]u8 = undefined;
    const n = try std.posix.read(pipe_fds[0], &buf);
    const hpack_block = buf[9..n];

    var decoder = h2.HpackDecoder.init();
    var headers: [8]h2.Header = undefined;
    var scratch: [256]u8 = undefined;
    const header_count = try decoder.decode(hpack_block, &headers, &scratch);

    var found = false;
    for (headers[0..header_count]) |header| {
        if (std.mem.eql(u8, header.name, "content-type") and
            std.mem.eql(u8, header.value, "application/grpc+proto"))
        {
            found = true;
            break;
        }
    }

    try std.testing.expect(found);
}
