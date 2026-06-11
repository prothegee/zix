//! gRPC PoC core: framing, status codes, path routing, content-type detection,
//! protobuf minimal codec (VARINT and LEN wire types), gRPC send functions.
//! All pub for test imports. Builds on http2_poc_core.zig (h2c direct, no TLS).
//! Run: zig run rnd/grpc_poc_server.zig

const std = @import("std");
pub const h2 = @import("http2_poc_core.zig");

pub const HandlerFn = h2.HandlerFn;
pub const Header = h2.Header;
pub const serveConn = h2.serveConn;

// ------------------------------------------------------------------ //
// gRPC status codes                                                   //
// ------------------------------------------------------------------ //

pub const GRPC_OK: u8 = 0;
pub const GRPC_CANCELLED: u8 = 1;
pub const GRPC_UNKNOWN: u8 = 2;
pub const GRPC_INVALID_ARGUMENT: u8 = 3;
pub const GRPC_DEADLINE_EXCEEDED: u8 = 4;
pub const GRPC_NOT_FOUND: u8 = 5;
pub const GRPC_ALREADY_EXISTS: u8 = 6;
pub const GRPC_PERMISSION_DENIED: u8 = 7;
pub const GRPC_RESOURCE_EXHAUSTED: u8 = 8;
pub const GRPC_FAILED_PRECONDITION: u8 = 9;
pub const GRPC_ABORTED: u8 = 10;
pub const GRPC_OUT_OF_RANGE: u8 = 11;
pub const GRPC_UNIMPLEMENTED: u8 = 12;
pub const GRPC_INTERNAL: u8 = 13;
pub const GRPC_UNAVAILABLE: u8 = 14;
pub const GRPC_DATA_LOSS: u8 = 15;
pub const GRPC_UNAUTHENTICATED: u8 = 16;

// ------------------------------------------------------------------ //
// gRPC 5-byte length prefix                                           //
// ------------------------------------------------------------------ //

pub const GrpcPrefix = struct {
    compress: bool,
    msg_len: u32,
};

pub fn readGrpcPrefix(body: []const u8) error{TooShort}!GrpcPrefix {
    if (body.len < 5) return error.TooShort;
    const msg_len: u32 = (@as(u32, body[1]) << 24) |
        (@as(u32, body[2]) << 16) |
        (@as(u32, body[3]) << 8) |
        body[4];
    return .{ .compress = body[0] != 0, .msg_len = msg_len };
}

pub fn writeGrpcPrefix(buf: *[5]u8, compress: bool, msg_len: u32) void {
    buf[0] = if (compress) 1 else 0;
    buf[1] = @intCast((msg_len >> 24) & 0xFF);
    buf[2] = @intCast((msg_len >> 16) & 0xFF);
    buf[3] = @intCast((msg_len >> 8) & 0xFF);
    buf[4] = @intCast(msg_len & 0xFF);
}

// ------------------------------------------------------------------ //
// Path routing                                                        //
// ------------------------------------------------------------------ //

pub const GrpcPath = struct {
    package_service: []const u8,
    method: []const u8,
};

pub fn parsePath(path: []const u8) ?GrpcPath {
    if (path.len < 2 or path[0] != '/') return null;
    const rest = path[1..];
    const slash = std.mem.lastIndexOfScalar(u8, rest, '/') orelse return null;
    if (slash == 0 or slash + 1 >= rest.len) return null;
    return .{
        .package_service = rest[0..slash],
        .method = rest[slash + 1 ..],
    };
}

// ------------------------------------------------------------------ //
// Content-type detection                                              //
// ------------------------------------------------------------------ //

pub const GrpcContentType = enum { PROTO, JSON, UNKNOWN };

pub fn detectContentType(headers: []const Header) GrpcContentType {
    for (headers) |h| {
        if (!std.ascii.eqlIgnoreCase(h.name, "content-type")) continue;
        if (std.mem.startsWith(u8, h.value, "application/grpc+json")) return .JSON;
        if (std.mem.startsWith(u8, h.value, "application/grpc")) return .PROTO;
    }
    return .UNKNOWN;
}

// ------------------------------------------------------------------ //
// gRPC send functions (3-step gRPC wire protocol)                    //
// ------------------------------------------------------------------ //

// Step 1: initial HEADERS: :status 200, content-type. No END_STREAM.
pub fn sendGrpcHeaders(fd: std.posix.fd_t, sid: u31, content_type: []const u8) !void {
    var hdr_buf: [512]u8 = undefined;
    var enc = h2.HpackEncoder.init(&hdr_buf);
    try enc.writeHeader(":status", "200");
    try enc.writeHeader("content-type", content_type);
    const hblock = enc.encoded();
    try h2.writeFrameHeader(fd, .{
        .length = @intCast(hblock.len),
        .frame_type = h2.FT_HEADERS,
        .flags = h2.FLAG_END_HEADERS,
        .stream_id = sid,
    });
    try h2.fdWriteAll(fd, hblock);
}

// Step 2: DATA frame: 5-byte gRPC prefix + message bytes. No END_STREAM.
pub fn sendGrpcData(fd: std.posix.fd_t, sid: u31, msg: []const u8) !void {
    var prefix: [5]u8 = undefined;
    writeGrpcPrefix(&prefix, false, @intCast(msg.len));
    try h2.writeFrameHeader(fd, .{
        .length = @intCast(5 + msg.len),
        .frame_type = h2.FT_DATA,
        .flags = 0,
        .stream_id = sid,
    });
    try h2.fdWriteAll(fd, &prefix);
    try h2.fdWriteAll(fd, msg);
}

// Step 3: trailer HEADERS: grpc-status, optional grpc-message. FLAG_END_STREAM.
pub fn sendGrpcTrailer(fd: std.posix.fd_t, sid: u31, grpc_status: u8, grpc_message: []const u8) !void {
    var hdr_buf: [512]u8 = undefined;
    var enc = h2.HpackEncoder.init(&hdr_buf);
    var status_str: [4]u8 = undefined;
    const status_s = std.fmt.bufPrint(&status_str, "{d}", .{grpc_status}) catch "0";
    try enc.writeHeader("grpc-status", status_s);
    if (grpc_message.len > 0)
        try enc.writeHeader("grpc-message", grpc_message);
    const hblock = enc.encoded();
    try h2.writeFrameHeader(fd, .{
        .length = @intCast(hblock.len),
        .frame_type = h2.FT_HEADERS,
        .flags = h2.FLAG_END_HEADERS | h2.FLAG_END_STREAM,
        .stream_id = sid,
    });
    try h2.fdWriteAll(fd, hblock);
}

// Trailers-only error response: no DATA frame. HTTP :status is always 200 for gRPC.
pub fn sendGrpcError(fd: std.posix.fd_t, sid: u31, grpc_status: u8, grpc_message: []const u8) !void {
    var hdr_buf: [512]u8 = undefined;
    var enc = h2.HpackEncoder.init(&hdr_buf);
    try enc.writeHeader(":status", "200");
    var status_str: [4]u8 = undefined;
    const status_s = std.fmt.bufPrint(&status_str, "{d}", .{grpc_status}) catch "0";
    try enc.writeHeader("grpc-status", status_s);
    if (grpc_message.len > 0)
        try enc.writeHeader("grpc-message", grpc_message);
    const hblock = enc.encoded();
    try h2.writeFrameHeader(fd, .{
        .length = @intCast(hblock.len),
        .frame_type = h2.FT_HEADERS,
        .flags = h2.FLAG_END_HEADERS | h2.FLAG_END_STREAM,
        .stream_id = sid,
    });
    try h2.fdWriteAll(fd, hblock);
}

// ------------------------------------------------------------------ //
// Protobuf minimal codec (VARINT=0 and LEN=2 wire types)             //
// ------------------------------------------------------------------ //

pub const WT_VARINT: u3 = 0;
pub const WT_I64: u3 = 1;
pub const WT_LEN: u3 = 2;
pub const WT_I32: u3 = 5;

// Encode value as unsigned varint into buf. Returns bytes written.
pub fn encodeVarint(buf: []u8, value: u64) usize {
    var v = value;
    var pos: usize = 0;
    while (v >= 0x80) {
        buf[pos] = @intCast((v & 0x7F) | 0x80);
        pos += 1;
        v >>= 7;
    }
    buf[pos] = @intCast(v);
    return pos + 1;
}

pub fn decodeVarint(buf: []const u8) error{ UnexpectedEOF, VarintOverflow }!struct { value: u64, consumed: usize } {
    var val: u64 = 0;
    var shift: u6 = 0;
    var i: usize = 0;
    while (i < buf.len) {
        const b = buf[i];
        i += 1;
        val |= (@as(u64, b & 0x7F)) << shift;
        if ((b & 0x80) == 0) return .{ .value = val, .consumed = i };
        if (shift > 56) return error.VarintOverflow;
        shift += 7;
    }
    return error.UnexpectedEOF;
}

// Encode LEN field (string or bytes). Tag = (field_number << 3) | 2. Returns bytes written.
pub fn encodeString(field_number: u32, s: []const u8, buf: []u8) usize {
    const tag: u64 = (@as(u64, field_number) << 3) | WT_LEN;
    var pos = encodeVarint(buf, tag);
    pos += encodeVarint(buf[pos..], @as(u64, s.len));
    @memcpy(buf[pos..][0..s.len], s);
    return pos + s.len;
}

// Encode VARINT field (int32, sign-extended to u64 for negative values). Returns bytes written.
pub fn encodeInt32(field_number: u32, val: i32, buf: []u8) usize {
    const tag: u64 = (@as(u64, field_number) << 3) | WT_VARINT;
    var pos = encodeVarint(buf, tag);
    pos += encodeVarint(buf[pos..], @bitCast(@as(i64, val)));
    return pos;
}

pub const ProtoField = struct {
    field_number: u32,
    wire_type: u3,
    payload: []const u8,
    value_u64: u64,
};

pub const MessageReader = struct {
    buf: []const u8,
    pos: usize,

    pub fn init(buf: []const u8) MessageReader {
        return .{ .buf = buf, .pos = 0 };
    }

    pub fn next(self: *MessageReader) !?ProtoField {
        if (self.pos >= self.buf.len) return null;
        const tag_r = try decodeVarint(self.buf[self.pos..]);
        self.pos += tag_r.consumed;
        const wire_type: u3 = @intCast(tag_r.value & 0x07);
        const field_number: u32 = @intCast(tag_r.value >> 3);

        switch (wire_type) {
            0 => {
                const r = try decodeVarint(self.buf[self.pos..]);
                self.pos += r.consumed;
                return .{ .field_number = field_number, .wire_type = wire_type, .payload = &.{}, .value_u64 = r.value };
            },
            1 => {
                if (self.pos + 8 > self.buf.len) return error.UnexpectedEOF;
                const data = self.buf[self.pos..][0..8];
                self.pos += 8;
                return .{ .field_number = field_number, .wire_type = wire_type, .payload = data, .value_u64 = 0 };
            },
            2 => {
                const len_r = try decodeVarint(self.buf[self.pos..]);
                self.pos += len_r.consumed;
                const data_len: usize = @intCast(len_r.value);
                if (self.pos + data_len > self.buf.len) return error.UnexpectedEOF;
                const data = self.buf[self.pos..][0..data_len];
                self.pos += data_len;
                return .{ .field_number = field_number, .wire_type = wire_type, .payload = data, .value_u64 = 0 };
            },
            5 => {
                if (self.pos + 4 > self.buf.len) return error.UnexpectedEOF;
                const data = self.buf[self.pos..][0..4];
                self.pos += 4;
                return .{ .field_number = field_number, .wire_type = wire_type, .payload = data, .value_u64 = 0 };
            },
            else => return error.UnknownWireType,
        }
    }
};
