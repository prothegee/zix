//! ZIX Http2 peer_settings
//!
//! ### file: src/zix/tcp/http2/peer_settings.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! The SETTINGS exchange: apply what the peer sent, send what this server offers.
//!
//! ### note:
//!
//! - RFC 7540 section 6.5.2: a valid SETTINGS_MAX_FRAME_SIZE is 16384 up to
//!   16777215. An out-of-range value keeps the last good one.
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
const control = @import("control.zig");
const frame = @import("frame.zig");
const HpackDecoder = @import("hpack/HpackDecoder.zig");
const ServeOpts = @import("ServeOpts.zig");

// --------------------------------------------------------- //
// Private:

fn controlError(err: control.Error) Error {
    @branchHint(.cold);

    return switch (err) {
        error.ZixHttp2_Control_BrokenPipe => Error.ZixHttp2_PeerSettings_BrokenPipe,
        error.ZixHttp2_Control_TooManySettings => Error.ZixHttp2_PeerSettings_TooManySettings,
        error.ZixHttp2_Control_UnexpectedEOF => Error.ZixHttp2_PeerSettings_UnexpectedEOF,
        error.ZixHttp2_Control_Overflow => Error.ZixHttp2_PeerSettings_Overflow,
        error.ZixHttp2_Control_BufferFull => Error.ZixHttp2_PeerSettings_BufferFull,
    };
}

// --------------------------------------------------------- //
// Public:

/// ZIX Http2 peer settings error
pub const Error = error {
    ZixHttp2_PeerSettings_BrokenPipe,
    ZixHttp2_PeerSettings_TooManySettings,
    ZixHttp2_PeerSettings_UnexpectedEOF,
    ZixHttp2_PeerSettings_Overflow,
    ZixHttp2_PeerSettings_BufferFull,
};

/// Apply peer SETTINGS parameters: the HPACK table size and the frame size
/// cap for outbound DATA.
///
/// Note:
/// - SETTINGS_INITIAL_WINDOW_SIZE is only reported back. The blocking loop
///   does not meter its sends, the mux applies it to every open stream.
///
/// Param:
/// params - []const u8 (SETTINGS payload, 6 bytes per parameter)
/// decoder - *HpackDecoder (the connection's decoder)
/// peer_max_frame_size - *u32 (updated in place)
///
/// Return:
/// - ?u32 (the last SETTINGS_INITIAL_WINDOW_SIZE in params, null when absent)
pub fn apply(params: []const u8, decoder: *HpackDecoder, peer_max_frame_size: *u32) ?u32 {
    var initial_window: ?u32 = null;
    var pos: usize = 0;

    while (pos + frame.SETTINGS_PARAM_LEN <= params.len) : (pos += frame.SETTINGS_PARAM_LEN) {
        const id = std.mem.readInt(u16, params[pos..][0..2], .big);
        const value = std.mem.readInt(u32, params[pos + 2 ..][0..4], .big);

        if (id == frame.SETTINGS_HEADER_TABLE_SIZE) {
            decoder.max_size = value;
            decoder.evictTo(value);
        }

        if (id == frame.SETTINGS_INITIAL_WINDOW_SIZE) initial_window = value;

        const in_range =
            value >= frame.DEFAULT_MAX_FRAME_SIZE and
            value <= frame.MAX_FRAME_SIZE_LIMIT;
        if (id == frame.SETTINGS_MAX_FRAME_SIZE and in_range) {
            peer_max_frame_size.* = value;
        }
    }

    return initial_window;
}

/// Send this server's SETTINGS frame.
///
/// Param:
/// fd - std.posix.fd_t (the connection)
/// opts - ServeOpts (max_streams and max_frame_size are advertised)
///
/// Return:
/// - void when the frame was sent
/// - error.ZixHttp2_PeerSettings_BrokenPipe on a write error
pub fn sendServerSettings(fd: std.posix.fd_t, opts: ServeOpts) Error!void {
    return control.sendSettingsFD(fd, &.{
        .{ frame.SETTINGS_MAX_CONCURRENT_STREAMS, @as(u32, @intCast(opts.max_streams)) },
        .{ frame.SETTINGS_INITIAL_WINDOW_SIZE, frame.DEFAULT_INITIAL_WINDOW },
        .{ frame.SETTINGS_MAX_FRAME_SIZE, opts.max_frame_size },
        .{ frame.SETTINGS_ENABLE_PUSH, 0 },
    }) catch |err| controlError(err);
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const builtin = @import("builtin");
const pair = @import("../../utils/socket/pair.zig");

test "zix http2: peer_settings, apply takes a valid max frame size" {
    var decoder = HpackDecoder.init();
    var peer_max: u32 = frame.DEFAULT_MAX_FRAME_SIZE;
    const params = [_]u8{ 0x00, 0x05, 0x00, 0x00, 0x80, 0x00 };

    _ = apply(&params, &decoder, &peer_max);

    try std.testing.expectEqual(@as(u32, 32 * 1024), peer_max);
}

test "zix http2: peer_settings, apply out of range keeps the last value" {
    var decoder = HpackDecoder.init();
    var peer_max: u32 = frame.DEFAULT_MAX_FRAME_SIZE;
    const params = [_]u8{ 0x00, 0x05, 0x00, 0x00, 0x00, 0x10 };

    _ = apply(&params, &decoder, &peer_max);

    try std.testing.expectEqual(frame.DEFAULT_MAX_FRAME_SIZE, peer_max);
}

test "zix http2: peer_settings, apply sets the HPACK table size" {
    var decoder = HpackDecoder.init();
    var peer_max: u32 = frame.DEFAULT_MAX_FRAME_SIZE;
    const params = [_]u8{ 0x00, 0x01, 0x00, 0x00, 0x00, 0x80 };

    _ = apply(&params, &decoder, &peer_max);

    try std.testing.expectEqual(@as(usize, 128), decoder.max_size);
}

test "zix http2: peer_settings, apply reports the initial window size" {
    var decoder = HpackDecoder.init();
    var peer_max: u32 = frame.DEFAULT_MAX_FRAME_SIZE;
    const params = [_]u8{ 0x00, 0x04, 0x00, 0x01, 0x00, 0x00 };

    const initial_window = apply(&params, &decoder, &peer_max);

    try std.testing.expectEqual(@as(?u32, 0x10000), initial_window);
}

test "zix http2: peer_settings, apply without an initial window reports null" {
    var decoder = HpackDecoder.init();
    var peer_max: u32 = frame.DEFAULT_MAX_FRAME_SIZE;

    try std.testing.expect(apply("", &decoder, &peer_max) == null);
}

test "zix http2: peer_settings, apply ignores a trailing partial parameter" {
    var decoder = HpackDecoder.init();
    var peer_max: u32 = frame.DEFAULT_MAX_FRAME_SIZE;
    const params = [_]u8{ 0x00, 0x05, 0x00, 0x00, 0x80 };

    _ = apply(&params, &decoder, &peer_max);

    try std.testing.expectEqual(frame.DEFAULT_MAX_FRAME_SIZE, peer_max);
}

test "zix http2: peer_settings, sendServerSettings writes one SETTINGS frame" {
    if (comptime builtin.target.os.tag != .linux) return;

    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    try sendServerSettings(fds[1], .{});

    var head: [frame.FRAME_HEADER_LEN]u8 = undefined;
    _ = try std.posix.read(fds[0], &head);
    const header = frame.parseFrameHeader(&head);

    try std.testing.expectEqual(frame.FRAME_TYPE_SETTINGS, header.frame_type);
    try std.testing.expectEqual(@as(u24, 4 * frame.SETTINGS_PARAM_LEN), header.length);
}

test "zix http2: peer_settings, sendServerSettings on a closed fd is BrokenPipe" {
    if (comptime builtin.target.os.tag != .linux) return;

    const result = sendServerSettings(-1, .{});

    try std.testing.expectError(Error.ZixHttp2_PeerSettings_BrokenPipe, result);
}

