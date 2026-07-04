//! zix http1 namespace

const core = @import("core.zig");
const router = @import("router.zig");

// --------------------------------------------------------- //

pub const Server = @import("server.zig").Server;
pub const ServerConfig = @import("config.zig").Http1ServerConfig;
pub const DispatchModel = @import("../config.zig").DispatchModel;

pub const HandlerFn = core.HandlerFn;
pub const RawFn = core.RawFn;
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

pub const cacheLookup = core.cacheLookup;
pub const cacheStore = core.cacheStore;
pub const cacheLookupEncoded = core.cacheLookupEncoded;
pub const cacheStoreEncoded = core.cacheStoreEncoded;
pub const sendGzipCachedFD = core.sendGzipCachedFD;
pub const sendWithCacheFD = core.sendWithCacheFD;
pub const cacheTtl = core.cacheTtl;
pub const ResponseCache = @import("../../utils/response_cache.zig").ResponseCache;

pub const writeAllFD = core.writeAllFD;
pub const flushPending = core.flushPending;
pub const beginStream = core.beginStream;
pub const sendSimpleFD = core.sendSimpleFD;
pub const sendSimpleNoBodyFD = core.sendSimpleNoBodyFD;
pub const sendJsonFD = core.sendJsonFD;
pub const sendGzipFD = core.sendGzipFD;
pub const sendNegotiateCachedFD = core.sendNegotiateCachedFD;
pub const sendChunkedStartFD = core.sendChunkedStartFD;
pub const sendChunkFD = core.sendChunkFD;
pub const sendChunkedEndFD = core.sendChunkedEndFD;
pub const sendRangeFD = core.sendRangeFD;
pub const send100ContinueFD = core.send100ContinueFD;
