//! ZIX Http2 Grpc frame reply block
//!
//! ### file: src/zix/tcp/http2/grpc/frame/reply_block.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! HPACK blocks for the two common gRPC replies, encoded once at comptime:
//! the initial HEADERS for the default content-type, and the OK trailer.
//!
//! ### note:
//!
//! The blocks come from the real HpackEncoder, so they are byte-identical to
//! what the dynamic path would encode.
//!
//! ---------------------------------------------------------
//!
//! ### licenses:
//!
//! - BSD-3-Clause
//!
//! ### copyright:
//!
//! - (c) Prana Ron // @prothegee // prothegee@pm.me
//!
//! ### contributors:
//!
//! - Prana Ron // @prothegee // prothegee@pm.me
//!

const std = @import("std");

const HpackEncoder = @import("../../hpack/HpackEncoder.zig");

// --------------------------------------------------------- //
// Private:

/// Comptime scratch for one cached block.
const BLOCK_SCRATCH: usize = 128;

/// Encode the given headers at comptime and return the block as an array.
fn encodeBlock(comptime headers: []const [2][]const u8) []const u8 {
    comptime {
        var buf: [BLOCK_SCRATCH]u8 = undefined;
        var encoder = HpackEncoder.init(&buf);

        for (headers) |header| {
            encoder.writeHeader(header[0], header[1]) catch |err| switch (err) {
                else => @compileError("reply block does not fit BLOCK_SCRATCH"),
            };
        }

        const block = encoder.encoded();
        var out: [block.len]u8 = undefined;
        @memcpy(&out, block);

        const final = out;
        return &final;
    }
}

// --------------------------------------------------------- //
// Public:

/// The default gRPC content-type.
pub const GRPC_CONTENT_TYPE = "application/grpc+proto";

/// Initial response HEADERS block: `:status 200`, `content-type` GRPC_CONTENT_TYPE.
pub const HEADERS_PROTO_BLOCK: []const u8 = encodeBlock(&.{
    .{ ":status", "200" },
    .{ "content-type", GRPC_CONTENT_TYPE },
});

/// OK trailer block: `grpc-status 0`, no message.
pub const TRAILER_OK_BLOCK: []const u8 = encodeBlock(&.{
    .{ "grpc-status", "0" },
});

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const HpackDecoder = @import("../../hpack/HpackDecoder.zig");
const Header = @import("../../hpack/Header.zig");

/// Decode a block and return how many headers it held.
fn testDecode(block: []const u8, headers: []Header, scratch: []u8) !usize {
    var decoder = HpackDecoder.init();

    return decoder.decode(block, headers, scratch);
}

test "zix http2 grpc frame: reply_block, HEADERS_PROTO_BLOCK decodes to status 200" {
    var headers: [8]Header = undefined;
    var scratch: [256]u8 = undefined;

    const count = try testDecode(HEADERS_PROTO_BLOCK, &headers, &scratch);

    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expectEqualStrings(":status", headers[0].name);
    try std.testing.expectEqualStrings("200", headers[0].value);
}

test "zix http2 grpc frame: reply_block, HEADERS_PROTO_BLOCK carries the default content-type" {
    var headers: [8]Header = undefined;
    var scratch: [256]u8 = undefined;

    _ = try testDecode(HEADERS_PROTO_BLOCK, &headers, &scratch);

    try std.testing.expectEqualStrings("content-type", headers[1].name);
    try std.testing.expectEqualStrings(GRPC_CONTENT_TYPE, headers[1].value);
}

test "zix http2 grpc frame: reply_block, HEADERS_PROTO_BLOCK matches the dynamic encoder" {
    var buf: [BLOCK_SCRATCH]u8 = undefined;
    var encoder = HpackEncoder.init(&buf);
    try encoder.writeHeader(":status", "200");
    try encoder.writeHeader("content-type", GRPC_CONTENT_TYPE);

    try std.testing.expectEqualSlices(u8, encoder.encoded(), HEADERS_PROTO_BLOCK);
}

test "zix http2 grpc frame: reply_block, TRAILER_OK_BLOCK decodes to grpc-status 0" {
    var headers: [8]Header = undefined;
    var scratch: [256]u8 = undefined;

    const count = try testDecode(TRAILER_OK_BLOCK, &headers, &scratch);

    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expectEqualStrings("grpc-status", headers[0].name);
    try std.testing.expectEqualStrings("0", headers[0].value);
}

test "zix http2 grpc frame: reply_block, TRAILER_OK_BLOCK matches the dynamic encoder" {
    var buf: [BLOCK_SCRATCH]u8 = undefined;
    var encoder = HpackEncoder.init(&buf);
    try encoder.writeHeader("grpc-status", "0");

    try std.testing.expectEqualSlices(u8, encoder.encoded(), TRAILER_OK_BLOCK);
}

