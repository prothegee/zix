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

/// Send initial response HEADERS (:status 200, content-type). No END_STREAM.
pub fn sendGrpcHeaders(fd: std.posix.fd_t, stream_id: u31, content_type: []const u8) !void {
    var hdr_buf: [512]u8 = undefined;
    var hpack_enc = h2.HpackEncoder.init(&hdr_buf);
    try hpack_enc.writeHeader(":status", "200");
    try hpack_enc.writeHeader("content-type", content_type);
    const hblock = hpack_enc.encoded();

    try h2.writeFrameHeader(fd, .{
        .length = @intCast(hblock.len),
        .frame_type = h2.FT_HEADERS,
        .flags = h2.FLAG_END_HEADERS,
        .stream_id = stream_id,
    });
    try h2.fdWriteAll(fd, hblock);
}

/// Send one DATA frame with 5-byte gRPC prefix. No END_STREAM.
pub fn sendGrpcData(fd: std.posix.fd_t, stream_id: u31, message: []const u8) !void {
    var prefix: [5]u8 = undefined;
    writeGrpcPrefix(&prefix, false, @intCast(message.len));

    try h2.writeFrameHeader(fd, .{
        .length = @intCast(5 + message.len),
        .frame_type = h2.FT_DATA,
        .flags = 0,
        .stream_id = stream_id,
    });
    try h2.fdWriteAll(fd, &prefix);
    try h2.fdWriteAll(fd, message);
}

/// Send trailer HEADERS (grpc-status, grpc-message). FLAG_END_STREAM.
pub fn sendGrpcTrailer(fd: std.posix.fd_t, stream_id: u31, grpc_status: u8, grpc_message: []const u8) !void {
    var hdr_buf: [512]u8 = undefined;
    var hpack_enc = h2.HpackEncoder.init(&hdr_buf);
    var status_str: [4]u8 = undefined;
    const status_s = std.fmt.bufPrint(&status_str, "{d}", .{grpc_status}) catch "0";
    try hpack_enc.writeHeader("grpc-status", status_s);
    if (grpc_message.len > 0) try hpack_enc.writeHeader("grpc-message", grpc_message);
    const hblock = hpack_enc.encoded();

    try h2.writeFrameHeader(fd, .{
        .length = @intCast(hblock.len),
        .frame_type = h2.FT_HEADERS,
        .flags = h2.FLAG_END_HEADERS | h2.FLAG_END_STREAM,
        .stream_id = stream_id,
    });
    try h2.fdWriteAll(fd, hblock);
}

/// Send trailers-only error response (no DATA frame). Includes :status 200 and content-type per gRPC spec.
pub fn sendGrpcError(fd: std.posix.fd_t, stream_id: u31, grpc_status: u8, grpc_message: []const u8) !void {
    var hdr_buf: [512]u8 = undefined;
    var hpack_enc = h2.HpackEncoder.init(&hdr_buf);
    try hpack_enc.writeHeader(":status", "200");
    try hpack_enc.writeHeader("content-type", "application/grpc+proto");
    var status_str: [4]u8 = undefined;
    const status_s = std.fmt.bufPrint(&status_str, "{d}", .{grpc_status}) catch "0";
    try hpack_enc.writeHeader("grpc-status", status_s);
    if (grpc_message.len > 0) try hpack_enc.writeHeader("grpc-message", grpc_message);
    const hblock = hpack_enc.encoded();

    try h2.writeFrameHeader(fd, .{
        .length = @intCast(hblock.len),
        .frame_type = h2.FT_HEADERS,
        .flags = h2.FLAG_END_HEADERS | h2.FLAG_END_STREAM,
        .stream_id = stream_id,
    });
    try h2.fdWriteAll(fd, hblock);
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //

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
