//! ZIX Http2
//!
//! ### file: src/zix/tcp/http2/Http2.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Zix Http2 namespace: the h2c server and its frame and HPACK helpers.
//!
//! ### note:
//!
//! n/a
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
const frame = @import("frame.zig");
const router = @import("router.zig");
const cache = @import("cache.zig");
const control = @import("control.zig");
const reader = @import("reader.zig");
const writer = @import("writer.zig");
const huffman = @import("hpack/huffman.zig");

// --------------------------------------------------------- //
// Public:

pub const Server = @import("Server.zig");
pub const ServerConfig = @import("Config.zig");
pub const DispatchModel = @import("../../shared/dispatch.zig").Model;
pub const HandlerFn = @import("handler.zig").HandlerFn;
pub const Route = router.Route;
pub const RouteKind = router.RouteKind;
pub const Router = router.Router;
pub const Request = @import("Request.zig");
pub const Response = @import("Response.zig");
pub const Context = @import("Context.zig");
pub const ServeOpts = @import("ServeOpts.zig");
pub const serveConn = @import("serve.zig").serveConn;

/// Per-worker response cache, opt-in via ServerConfig.response_cache. A
/// handler serves a hit with serveCached and stores its reply with
/// sendCachedFD, both keyed by the current request.
pub const serveCached = cache.serveCached;
pub const sendCachedFD = cache.sendCachedFD;
pub const cacheTtl = cache.cacheTtl;

pub const Header = @import("hpack/Header.zig");
pub const HpackEncoder = @import("hpack/HpackEncoder.zig");
pub const HpackDecoder = @import("hpack/HpackDecoder.zig");
/// Static and dynamic table entry, the same type as Header.
pub const HpackEntry = Header;
pub const huffEncode = huffman.huffEncode;
pub const huffDecode = huffman.huffDecode;
pub const HPACK_STATIC = @import("hpack/static_table.zig").HPACK_STATIC;

pub const FrameHeader = @import("FrameHeader.zig");
pub const parseFrameHeader = frame.parseFrameHeader;
pub const encodeFrameHeader = frame.encodeFrameHeader;
pub const readFrameHeader = reader.readFrameHeader;
pub const recvExact = reader.recvExact;
pub const writeFrameHeaderFD = writer.writeFrameHeaderFD;
pub const writeAllFD = writer.writeAllFD;
pub const sendResponseFD = writer.sendResponseFD;
pub const sendResponseEncodedFD = writer.sendResponseEncodedFD;
/// Flow-controlled response send for large, caller-owned bodies (paced by
/// WINDOW_UPDATE). The body must outlive the stream.
pub const sendResponseStreamFD = @import("mux/send_stream.zig").sendResponseStreamFD;
pub const sendSettingsFD = control.sendSettingsFD;
pub const sendSettingsAckFD = control.sendSettingsAckFD;
pub const sendPingAckFD = control.sendPingAckFD;
pub const sendGoawayFD = control.sendGoawayFD;
pub const sendRstStreamFD = control.sendRstStreamFD;
pub const sendWindowUpdateFD = control.sendWindowUpdateFD;

pub const PREFACE = frame.PREFACE;
pub const FRAME_HEADER_LEN = frame.FRAME_HEADER_LEN;
pub const FRAME_PAYLOAD_SLACK = frame.FRAME_PAYLOAD_SLACK;
pub const HPACK_ENCODE_SCRATCH = frame.HPACK_ENCODE_SCRATCH;

pub const FRAME_TYPE_DATA: u8 = frame.FRAME_TYPE_DATA;
pub const FRAME_TYPE_HEADERS: u8 = frame.FRAME_TYPE_HEADERS;
pub const FRAME_TYPE_PRIORITY: u8 = frame.FRAME_TYPE_PRIORITY;
pub const FRAME_TYPE_RST_STREAM: u8 = frame.FRAME_TYPE_RST_STREAM;
pub const FRAME_TYPE_SETTINGS: u8 = frame.FRAME_TYPE_SETTINGS;
pub const FRAME_TYPE_PUSH_PROMISE: u8 = frame.FRAME_TYPE_PUSH_PROMISE;
pub const FRAME_TYPE_PING: u8 = frame.FRAME_TYPE_PING;
pub const FRAME_TYPE_GOAWAY: u8 = frame.FRAME_TYPE_GOAWAY;
pub const FRAME_TYPE_WINDOW_UPDATE: u8 = frame.FRAME_TYPE_WINDOW_UPDATE;
pub const FRAME_TYPE_CONTINUATION: u8 = frame.FRAME_TYPE_CONTINUATION;

pub const FLAG_END_STREAM: u8 = frame.FLAG_END_STREAM;
pub const FLAG_END_HEADERS: u8 = frame.FLAG_END_HEADERS;
pub const FLAG_PADDED: u8 = frame.FLAG_PADDED;
pub const FLAG_PRIORITY: u8 = frame.FLAG_PRIORITY;
pub const FLAG_ACK: u8 = frame.FLAG_ACK;

pub const ERR_NO_ERROR: u32 = frame.ERR_NO_ERROR;
pub const ERR_PROTOCOL_ERROR: u32 = frame.ERR_PROTOCOL_ERROR;
pub const ERR_INTERNAL_ERROR: u32 = frame.ERR_INTERNAL_ERROR;
pub const ERR_FLOW_CONTROL_ERROR: u32 = frame.ERR_FLOW_CONTROL_ERROR;
pub const ERR_SETTINGS_TIMEOUT: u32 = frame.ERR_SETTINGS_TIMEOUT;
pub const ERR_STREAM_CLOSED: u32 = frame.ERR_STREAM_CLOSED;
pub const ERR_FRAME_SIZE_ERROR: u32 = frame.ERR_FRAME_SIZE_ERROR;
pub const ERR_REFUSED_STREAM: u32 = frame.ERR_REFUSED_STREAM;
pub const ERR_CANCEL: u32 = frame.ERR_CANCEL;
pub const ERR_COMPRESSION_ERROR: u32 = frame.ERR_COMPRESSION_ERROR;
pub const ERR_CONNECT_ERROR: u32 = frame.ERR_CONNECT_ERROR;
pub const ERR_ENHANCE_YOUR_CALM: u32 = frame.ERR_ENHANCE_YOUR_CALM;
pub const ERR_INADEQUATE_SECURITY: u32 = frame.ERR_INADEQUATE_SECURITY;
pub const ERR_HTTP_1_1_REQUIRED: u32 = frame.ERR_HTTP_1_1_REQUIRED;

pub const SETTINGS_HEADER_TABLE_SIZE: u16 = frame.SETTINGS_HEADER_TABLE_SIZE;
pub const SETTINGS_ENABLE_PUSH: u16 = frame.SETTINGS_ENABLE_PUSH;
pub const SETTINGS_MAX_CONCURRENT_STREAMS: u16 = frame.SETTINGS_MAX_CONCURRENT_STREAMS;
pub const SETTINGS_INITIAL_WINDOW_SIZE: u16 = frame.SETTINGS_INITIAL_WINDOW_SIZE;
pub const SETTINGS_MAX_FRAME_SIZE: u16 = frame.SETTINGS_MAX_FRAME_SIZE;
pub const SETTINGS_MAX_HEADER_LIST_SIZE: u16 = frame.SETTINGS_MAX_HEADER_LIST_SIZE;

pub const DEFAULT_INITIAL_WINDOW: u32 = frame.DEFAULT_INITIAL_WINDOW;
pub const DEFAULT_MAX_FRAME_SIZE: u32 = frame.DEFAULT_MAX_FRAME_SIZE;
/// Old name of DEFAULT_INITIAL_WINDOW, kept for callers.
pub const DEFAULT_WINDOW_SIZE: u32 = frame.DEFAULT_INITIAL_WINDOW;
/// Old name of DEFAULT_MAX_FRAME_SIZE as a usize, kept for callers.
pub const MAX_PAYLOAD: usize = frame.DEFAULT_MAX_FRAME_SIZE;
pub const MAX_HEADERS: usize = frame.MAX_HEADERS;

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

fn probeHandler(_: *Request, _: *Response, _: *Context) anyerror!void {}

test "zix http2: Http2, exposes the engine types" {
    _ = @This().Server;
    _ = @This().ServerConfig;
    _ = @This().Route;
    _ = @This().Router;
    _ = @This().Request;
    _ = @This().Response;
    _ = @This().Context;
    _ = @This().ServeOpts;
}

test "zix http2: Http2, HandlerFn takes the request trio" {
    const handler: @This().HandlerFn = probeHandler;

    try std.testing.expect(handler == &probeHandler);
}

test "zix http2: Http2, HpackEntry is the Header type" {
    try std.testing.expect(@This().HpackEntry == @This().Header);
}

test "zix http2: Http2, exposes sendResponseStreamFD" {
    try std.testing.expect(
        @This().sendResponseStreamFD == @import("mux/send_stream.zig").sendResponseStreamFD,
    );
}

test "zix http2: Http2, encodeFrameHeader round-trips through parseFrameHeader" {
    var buf: [@This().FRAME_HEADER_LEN]u8 = undefined;
    @This().encodeFrameHeader(&buf, .{
        .length = 4,
        .frame_type = @This().FRAME_TYPE_WINDOW_UPDATE,
        .flags = 0,
        .stream_id = 3,
    });

    const header = @This().parseFrameHeader(&buf);

    try std.testing.expectEqual(@as(u24, 4), header.length);
    try std.testing.expectEqual(@This().FRAME_TYPE_WINDOW_UPDATE, header.frame_type);
    try std.testing.expectEqual(@as(u31, 3), header.stream_id);
}

test "zix http2: Http2, DEFAULT_WINDOW_SIZE is 65535" {
    try std.testing.expectEqual(@as(u32, 65535), @This().DEFAULT_WINDOW_SIZE);
}

test "zix http2: Http2, MAX_PAYLOAD is 16384" {
    try std.testing.expectEqual(@as(usize, 16384), @This().MAX_PAYLOAD);
}

test "zix http2: Http2, shares the dispatch model" {
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(@This().DispatchModel.ASYNC));
}

test "zix http2: Http2, huffman round-trips a header value" {
    var encoded: [32]u8 = undefined;
    var decoded: [32]u8 = undefined;

    const encoded_len = try @This().huffEncode("www.example.com", &encoded);
    const decoded_len = try @This().huffDecode(encoded[0..encoded_len], &decoded);

    try std.testing.expectEqualStrings("www.example.com", decoded[0..decoded_len]);
}

