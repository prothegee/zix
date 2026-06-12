//! zix http1 namespace

const core = @import("core.zig");
const router = @import("router.zig");

// --------------------------------------------------------- //

pub const Server = @import("server.zig").Server;
pub const ServerConfig = @import("config.zig").Http1ServerConfig;
pub const DispatchModel = @import("../config.zig").DispatchModel;

pub const HandlerFn = core.HandlerFn;
pub const ParsedHead = core.ParsedHead;
pub const ParseResult = core.ParseResult;
pub const Range = core.Range;
pub const ServeOpts = core.ServeOpts;
pub const ConnOutcome = core.ConnOutcome;

pub const Route = router.Route;
pub const RouteKind = router.RouteKind;
pub const Router = router.Router;
pub const PathParam = router.PathParam;
pub const pathParam = router.pathParam;

pub const WebSocket = @import("websocket.zig");
pub const WsFrameFn = core.WsFrameFn;

// --------------------------------------------------------- //

pub const setTimeout = core.setTimeout;
pub const isExpired = core.isExpired;

pub const parseHead = core.parseHead;
pub const getHeader = core.getHeader;
pub const queryParam = core.queryParam;
pub const percentDecode = core.percentDecode;
pub const parseRange = core.parseRange;

pub const fdWriteAll = core.fdWriteAll;
pub const flushPending = core.flushPending;
pub const writeSimple = core.writeSimple;
pub const writeSimpleNoBody = core.writeSimpleNoBody;
pub const writeJson = core.writeJson;
pub const writeGzip = core.writeGzip;
pub const writeChunkedStart = core.writeChunkedStart;
pub const writeChunk = core.writeChunk;
pub const writeChunkedEnd = core.writeChunkedEnd;
pub const writeRange = core.writeRange;
pub const write100Continue = core.write100Continue;
