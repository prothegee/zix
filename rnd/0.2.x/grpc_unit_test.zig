//! gRPC PoC unit tests — varint codec, proto fields, 5-byte prefix, path parser,
//! content-type detection. No I/O.
//! Run: zig test rnd/grpc_unit_test.zig

const std = @import("std");
const grpc = @import("grpc_poc_core.zig");

// ------------------------------------------------------------------ //
// Varint encode                                                       //
// ------------------------------------------------------------------ //

test "varint encode: 0" {
    var buf: [10]u8 = undefined;
    const n = grpc.encodeVarint(&buf, 0);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(@as(u8, 0x00), buf[0]);
}

test "varint encode: 1" {
    var buf: [10]u8 = undefined;
    const n = grpc.encodeVarint(&buf, 1);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(@as(u8, 0x01), buf[0]);
}

test "varint encode: 128 requires two bytes" {
    var buf: [10]u8 = undefined;
    const n = grpc.encodeVarint(&buf, 128);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqual(@as(u8, 0x80), buf[0]);
    try std.testing.expectEqual(@as(u8, 0x01), buf[1]);
}

test "varint encode: 300" {
    var buf: [10]u8 = undefined;
    const n = grpc.encodeVarint(&buf, 300);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqual(@as(u8, 0xAC), buf[0]);
    try std.testing.expectEqual(@as(u8, 0x02), buf[1]);
}

// ------------------------------------------------------------------ //
// Varint decode                                                       //
// ------------------------------------------------------------------ //

test "varint decode: single byte" {
    const r = try grpc.decodeVarint(&.{42});
    try std.testing.expectEqual(@as(u64, 42), r.value);
    try std.testing.expectEqual(@as(usize, 1), r.consumed);
}

test "varint decode: 300 from two bytes" {
    const r = try grpc.decodeVarint(&.{ 0xAC, 0x02 });
    try std.testing.expectEqual(@as(u64, 300), r.value);
    try std.testing.expectEqual(@as(usize, 2), r.consumed);
}

test "varint decode: overflow returns error" {
    const buf = [_]u8{0xFF} ** 10;
    try std.testing.expectError(error.VarintOverflow, grpc.decodeVarint(&buf));
}

// ------------------------------------------------------------------ //
// Proto field encode                                                  //
// ------------------------------------------------------------------ //

test "encodeString: field 1 hello" {
    var buf: [64]u8 = undefined;
    const n = grpc.encodeString(1, "hello", &buf);
    // tag = (1 << 3) | 2 = 0x0A, len = 5 = 0x05, then "hello"
    try std.testing.expectEqual(@as(usize, 7), n);
    try std.testing.expectEqual(@as(u8, 0x0A), buf[0]);
    try std.testing.expectEqual(@as(u8, 0x05), buf[1]);
    try std.testing.expectEqualStrings("hello", buf[2..7]);
}

test "encodeInt32: field 2 value 42" {
    var buf: [16]u8 = undefined;
    const n = grpc.encodeInt32(2, 42, &buf);
    // tag = (2 << 3) | 0 = 0x10, value = 42 = 0x2A
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqual(@as(u8, 0x10), buf[0]);
    try std.testing.expectEqual(@as(u8, 0x2A), buf[1]);
}

// ------------------------------------------------------------------ //
// MessageReader                                                       //
// ------------------------------------------------------------------ //

test "MessageReader: reads string field 1" {
    var enc_buf: [32]u8 = undefined;
    const n = grpc.encodeString(1, "world", &enc_buf);

    var reader = grpc.MessageReader.init(enc_buf[0..n]);
    const field = (try reader.next()) orelse return error.NoField;
    try std.testing.expectEqual(@as(u32, 1), field.field_number);
    try std.testing.expectEqual(@as(u3, grpc.WT_LEN), field.wire_type);
    try std.testing.expectEqualStrings("world", field.payload);
    try std.testing.expect((try reader.next()) == null);
}

test "MessageReader: reads int32 field 2" {
    var enc_buf: [16]u8 = undefined;
    const n = grpc.encodeInt32(2, 7, &enc_buf);

    var reader = grpc.MessageReader.init(enc_buf[0..n]);
    const field = (try reader.next()) orelse return error.NoField;
    try std.testing.expectEqual(@as(u32, 2), field.field_number);
    try std.testing.expectEqual(@as(u3, grpc.WT_VARINT), field.wire_type);
    try std.testing.expectEqual(@as(u64, 7), field.value_u64);
    try std.testing.expect((try reader.next()) == null);
}

test "MessageReader: empty buffer returns null immediately" {
    var reader = grpc.MessageReader.init(&.{});
    try std.testing.expect((try reader.next()) == null);
}

// ------------------------------------------------------------------ //
// 5-byte gRPC prefix                                                  //
// ------------------------------------------------------------------ //

test "readGrpcPrefix: no compress len=15" {
    const data = [_]u8{ 0, 0, 0, 0, 15 } ++ [_]u8{0} ** 15;
    const p = try grpc.readGrpcPrefix(&data);
    try std.testing.expect(!p.compress);
    try std.testing.expectEqual(@as(u32, 15), p.msg_len);
}

test "writeGrpcPrefix and readGrpcPrefix roundtrip" {
    var buf: [5]u8 = undefined;
    grpc.writeGrpcPrefix(&buf, false, 1024);
    const p = try grpc.readGrpcPrefix(&buf);
    try std.testing.expect(!p.compress);
    try std.testing.expectEqual(@as(u32, 1024), p.msg_len);
}

test "readGrpcPrefix: too short returns error" {
    try std.testing.expectError(error.TooShort, grpc.readGrpcPrefix(&.{ 0, 0, 0 }));
}

// ------------------------------------------------------------------ //
// Path parser                                                         //
// ------------------------------------------------------------------ //

test "parsePath: valid /helloworld.Greeter/SayHello" {
    const p = grpc.parsePath("/helloworld.Greeter/SayHello") orelse
        return error.NullPath;
    try std.testing.expectEqualStrings("helloworld.Greeter", p.package_service);
    try std.testing.expectEqualStrings("SayHello", p.method);
}

test "parsePath: empty string returns null" {
    try std.testing.expect(grpc.parsePath("") == null);
}

test "parsePath: no service separator returns null" {
    try std.testing.expect(grpc.parsePath("/SayHello") == null);
}

// ------------------------------------------------------------------ //
// Content-type detection                                              //
// ------------------------------------------------------------------ //

test "detectContentType: proto" {
    const headers = [_]grpc.Header{
        .{ .name = "content-type", .value = "application/grpc+proto" },
    };
    try std.testing.expectEqual(grpc.GrpcContentType.PROTO, grpc.detectContentType(&headers));
}

test "detectContentType: json" {
    const headers = [_]grpc.Header{
        .{ .name = "content-type", .value = "application/grpc+json" },
    };
    try std.testing.expectEqual(grpc.GrpcContentType.JSON, grpc.detectContentType(&headers));
}

test "detectContentType: bare application/grpc treated as proto" {
    const headers = [_]grpc.Header{
        .{ .name = "content-type", .value = "application/grpc" },
    };
    try std.testing.expectEqual(grpc.GrpcContentType.PROTO, grpc.detectContentType(&headers));
}

test "detectContentType: non-grpc returns unknown" {
    const headers = [_]grpc.Header{
        .{ .name = "content-type", .value = "application/json" },
    };
    try std.testing.expectEqual(grpc.GrpcContentType.UNKNOWN, grpc.detectContentType(&headers));
}
