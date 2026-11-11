//! ZIX Http2 Grpc mux settings_frame
//!
//! ### file: src/zix/tcp/http2/grpc/mux/settings_frame.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Build the server SETTINGS frame a gRPC mux connection stages after the
//! client preface.
//!
//! ### note:
//!
//! Built once per connection, so every handshake appends a ready blob.
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
const frame = @import("../../frame.zig");
const window = @import("../window.zig");
const ServeOpts = @import("../ServeOpts.zig");

// --------------------------------------------------------- //
// Private:

/// Parameters in the server SETTINGS frame.
const PARAM_COUNT: usize = 4;

// --------------------------------------------------------- //
// Public:

/// Bytes in the server SETTINGS frame: frame header plus 4 parameters.
pub const SETTINGS_FRAME_LEN: usize =
    frame.FRAME_HEADER_LEN + PARAM_COUNT * frame.SETTINGS_PARAM_LEN;

/// Encode the server SETTINGS frame, with the large gRPC stream window.
///
/// Param:
/// out - *[SETTINGS_FRAME_LEN]u8 (destination)
/// opts - ServeOpts (max_streams and max_frame_size are advertised)
///
/// Return:
/// - void
pub fn build(out: *[SETTINGS_FRAME_LEN]u8, opts: ServeOpts) void {
    const params = [PARAM_COUNT][2]u32{
        .{ frame.SETTINGS_MAX_CONCURRENT_STREAMS, @as(u32, @intCast(opts.max_streams)) },
        .{ frame.SETTINGS_INITIAL_WINDOW_SIZE, window.STREAM_WINDOW_SIZE },
        .{ frame.SETTINGS_MAX_FRAME_SIZE, opts.max_frame_size },
        .{ frame.SETTINGS_ENABLE_PUSH, 0 },
    };

    frame.encodeFrameHeader(out[0..frame.FRAME_HEADER_LEN], .{
        .length = @intCast(PARAM_COUNT * frame.SETTINGS_PARAM_LEN),
        .frame_type = frame.FRAME_TYPE_SETTINGS,
        .flags = 0,
        .stream_id = 0,
    });

    for (params, 0..) |param, index| {
        const at = frame.FRAME_HEADER_LEN + index * frame.SETTINGS_PARAM_LEN;

        std.mem.writeInt(u16, out[at..][0..2], @as(u16, @intCast(param[0])), .big);
        std.mem.writeInt(u32, out[at + 2 ..][0..4], param[1], .big);
    }
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

/// Read parameter index back as an id and value pair.
fn paramAt(out: *const [SETTINGS_FRAME_LEN]u8, index: usize) [2]u32 {
    const at = frame.FRAME_HEADER_LEN + index * frame.SETTINGS_PARAM_LEN;

    return .{
        std.mem.readInt(u16, out[at..][0..2], .big),
        std.mem.readInt(u32, out[at + 2 ..][0..4], .big),
    };
}

test "zix http2 grpc mux: settings_frame, frame is 33 bytes" {
    try std.testing.expectEqual(@as(usize, 33), SETTINGS_FRAME_LEN);
}

test "zix http2 grpc mux: settings_frame, header is a SETTINGS on stream 0" {
    var out: [SETTINGS_FRAME_LEN]u8 = undefined;
    build(&out, .{});

    const header = frame.parseFrameHeader(out[0..frame.FRAME_HEADER_LEN]);

    try std.testing.expectEqual(frame.FRAME_TYPE_SETTINGS, header.frame_type);
    try std.testing.expectEqual(@as(u8, 0), header.flags);
    try std.testing.expectEqual(@as(u31, 0), header.stream_id);
    try std.testing.expectEqual(@as(u24, 24), header.length);
}

test "zix http2 grpc mux: settings_frame, MAX_CONCURRENT_STREAMS carries max_streams" {
    var out: [SETTINGS_FRAME_LEN]u8 = undefined;
    build(&out, .{
        .max_streams = 64,
    });

    const param = paramAt(&out, 0);

    try std.testing.expectEqual(@as(u32, frame.SETTINGS_MAX_CONCURRENT_STREAMS), param[0]);
    try std.testing.expectEqual(@as(u32, 64), param[1]);
}

test "zix http2 grpc mux: settings_frame, INITIAL_WINDOW_SIZE is the gRPC stream window" {
    var out: [SETTINGS_FRAME_LEN]u8 = undefined;
    build(&out, .{});

    const param = paramAt(&out, 1);

    try std.testing.expectEqual(@as(u32, frame.SETTINGS_INITIAL_WINDOW_SIZE), param[0]);
    try std.testing.expectEqual(window.STREAM_WINDOW_SIZE, param[1]);
}

test "zix http2 grpc mux: settings_frame, MAX_FRAME_SIZE carries max_frame_size" {
    var out: [SETTINGS_FRAME_LEN]u8 = undefined;
    build(&out, .{
        .max_frame_size = 32768,
    });

    const param = paramAt(&out, 2);

    try std.testing.expectEqual(@as(u32, frame.SETTINGS_MAX_FRAME_SIZE), param[0]);
    try std.testing.expectEqual(@as(u32, 32768), param[1]);
}

test "zix http2 grpc mux: settings_frame, push is disabled" {
    var out: [SETTINGS_FRAME_LEN]u8 = undefined;
    build(&out, .{});

    const param = paramAt(&out, 3);

    try std.testing.expectEqual(@as(u32, frame.SETTINGS_ENABLE_PUSH), param[0]);
    try std.testing.expectEqual(@as(u32, 0), param[1]);
}

