//! zix http2 namespace: HTTP/2 h2c server (no std.http in frame path).

const frame_mod = @import("frame.zig");
const hpack_mod = @import("hpack.zig");
const core_mod = @import("core.zig");
const config_mod = @import("config.zig");
const mux_mod = @import("mux.zig");

// --------------------------------------------------------- //

pub const Server = @import("server.zig").Http2Server;
pub const ServerConfig = config_mod.Http2ServerConfig;
pub const DispatchModel = @import("../config.zig").DispatchModel;
pub const HandlerFn = core_mod.HandlerFn;
pub const Route = core_mod.Route;
pub const RouteKind = core_mod.RouteKind;
pub const Router = core_mod.Router;
pub const ServeOpts = core_mod.ServeOpts;
pub const serveConn = core_mod.serveConn;

pub const Header = hpack_mod.Header;
pub const HpackEncoder = hpack_mod.HpackEncoder;
pub const HpackDecoder = hpack_mod.HpackDecoder;
pub const HpackEntry = hpack_mod.HpackEntry;
pub const huffEncode = hpack_mod.huffEncode;
pub const huffDecode = hpack_mod.huffDecode;

pub const FrameHeader = frame_mod.FrameHeader;
pub const readFrameHeader = frame_mod.readFrameHeader;
pub const parseFrameHeader = frame_mod.parseFrameHeader;
pub const writeFrameHeader = frame_mod.writeFrameHeader;
pub const encodeFrameHeader = frame_mod.encodeFrameHeader;
pub const fdWriteAll = frame_mod.fdWriteAll;
pub const recvExact = frame_mod.recvExact;
pub const sendResponse = frame_mod.sendResponse;
pub const sendResponseEncoded = frame_mod.sendResponseEncoded;
/// Flow-controlled response send for large, caller-owned bodies (paces by WINDOW_UPDATE). See
/// mux.sendResponseStream: the body must outlive the stream.
pub const sendResponseStream = mux_mod.sendResponseStream;
pub const sendSettings = frame_mod.sendSettings;
pub const sendSettingsAck = frame_mod.sendSettingsAck;
pub const sendPingAck = frame_mod.sendPingAck;
pub const sendGoaway = frame_mod.sendGoaway;
pub const sendRstStream = frame_mod.sendRstStream;
pub const sendWindowUpdate = frame_mod.sendWindowUpdate;

pub const PREFACE = frame_mod.PREFACE;
pub const FRAME_HEADER_LEN = frame_mod.FRAME_HEADER_LEN;

pub const FRAME_TYPE_DATA: u8 = frame_mod.FRAME_TYPE_DATA;
pub const FRAME_TYPE_HEADERS: u8 = frame_mod.FRAME_TYPE_HEADERS;
pub const FRAME_TYPE_PRIORITY: u8 = frame_mod.FRAME_TYPE_PRIORITY;
pub const FRAME_TYPE_RST_STREAM: u8 = frame_mod.FRAME_TYPE_RST_STREAM;
pub const FRAME_TYPE_SETTINGS: u8 = frame_mod.FRAME_TYPE_SETTINGS;
pub const FRAME_TYPE_PUSH_PROMISE: u8 = frame_mod.FRAME_TYPE_PUSH_PROMISE;
pub const FRAME_TYPE_PING: u8 = frame_mod.FRAME_TYPE_PING;
pub const FRAME_TYPE_GOAWAY: u8 = frame_mod.FRAME_TYPE_GOAWAY;
pub const FRAME_TYPE_WINDOW_UPDATE: u8 = frame_mod.FRAME_TYPE_WINDOW_UPDATE;
pub const FRAME_TYPE_CONTINUATION: u8 = frame_mod.FRAME_TYPE_CONTINUATION;

pub const FLAG_END_STREAM: u8 = frame_mod.FLAG_END_STREAM;
pub const FLAG_END_HEADERS: u8 = frame_mod.FLAG_END_HEADERS;
pub const FLAG_PADDED: u8 = frame_mod.FLAG_PADDED;
pub const FLAG_PRIORITY: u8 = frame_mod.FLAG_PRIORITY;
pub const FLAG_ACK: u8 = frame_mod.FLAG_ACK;

pub const ERR_NO_ERROR: u32 = frame_mod.ERR_NO_ERROR;
pub const ERR_PROTOCOL_ERROR: u32 = frame_mod.ERR_PROTOCOL_ERROR;
pub const ERR_INTERNAL_ERROR: u32 = frame_mod.ERR_INTERNAL_ERROR;
pub const ERR_FLOW_CONTROL_ERROR: u32 = frame_mod.ERR_FLOW_CONTROL_ERROR;
pub const ERR_SETTINGS_TIMEOUT: u32 = frame_mod.ERR_SETTINGS_TIMEOUT;
pub const ERR_STREAM_CLOSED: u32 = frame_mod.ERR_STREAM_CLOSED;
pub const ERR_FRAME_SIZE_ERROR: u32 = frame_mod.ERR_FRAME_SIZE_ERROR;
pub const ERR_REFUSED_STREAM: u32 = frame_mod.ERR_REFUSED_STREAM;
pub const ERR_CANCEL: u32 = frame_mod.ERR_CANCEL;
pub const ERR_COMPRESSION_ERROR: u32 = frame_mod.ERR_COMPRESSION_ERROR;
pub const ERR_CONNECT_ERROR: u32 = frame_mod.ERR_CONNECT_ERROR;
pub const ERR_ENHANCE_YOUR_CALM: u32 = frame_mod.ERR_ENHANCE_YOUR_CALM;
pub const ERR_INADEQUATE_SECURITY: u32 = frame_mod.ERR_INADEQUATE_SECURITY;
pub const ERR_HTTP_1_1_REQUIRED: u32 = frame_mod.ERR_HTTP_1_1_REQUIRED;

pub const SETTINGS_HEADER_TABLE_SIZE: u16 = frame_mod.SETTINGS_HEADER_TABLE_SIZE;
pub const SETTINGS_ENABLE_PUSH: u16 = frame_mod.SETTINGS_ENABLE_PUSH;
pub const SETTINGS_MAX_CONCURRENT_STREAMS: u16 = frame_mod.SETTINGS_MAX_CONCURRENT_STREAMS;
pub const SETTINGS_INITIAL_WINDOW_SIZE: u16 = frame_mod.SETTINGS_INITIAL_WINDOW_SIZE;
pub const SETTINGS_MAX_FRAME_SIZE: u16 = frame_mod.SETTINGS_MAX_FRAME_SIZE;
pub const SETTINGS_MAX_HEADER_LIST_SIZE: u16 = frame_mod.SETTINGS_MAX_HEADER_LIST_SIZE;

pub const DEFAULT_INITIAL_WINDOW: u32 = frame_mod.DEFAULT_INITIAL_WINDOW;
pub const DEFAULT_MAX_FRAME_SIZE: u32 = frame_mod.DEFAULT_MAX_FRAME_SIZE;
pub const MAX_HEADERS: usize = frame_mod.MAX_HEADERS;
pub const MAX_PAYLOAD: usize = frame_mod.MAX_PAYLOAD;

pub const HPACK_STATIC = hpack_mod.HPACK_STATIC;
