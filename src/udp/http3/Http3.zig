//! zix.Http3 namespace: a pure-Zig HTTP/3 (QUIC) server on the zix.Udp datagram substrate.
//!
//! What:
//! - Re-exports the public surface: the `Http3(handler)` server type, the request / response shapes,
//!   the server config, and the shared DispatchModel. The QUIC / TLS / QPACK machinery is internal.

const server = @import("server.zig");
const core = @import("core.zig");
const Config = @import("config.zig");
const router = @import("router.zig");

/// The HTTP/3 server type, bound to a comptime handler.
pub const Http3 = server.Http3;
/// The application request handler type.
pub const HandlerFn = core.HandlerFn;
/// A decoded HTTP/3 request.
pub const Request = core.Request;
/// The response the handler fills.
pub const Response = core.Response;
/// The content coding a handler sets on its response body (`res.content_encoding`).
pub const ContentEncoding = core.ContentEncoding;
/// The HTTP/3 server config.
pub const ServerConfig = Config.Http3ServerConfig;
/// The dispatch model, shared with the rest of the engine family (ADR-050).
pub const DispatchModel = Config.DispatchModel;
/// The comptime router, mirroring zix.Http1 / zix.Http2.
pub const Router = router.Router;
/// A single route entry for the router.
pub const Route = router.Route;
/// Look up a path parameter captured by a PARAM route.
pub const pathParam = router.pathParam;

// Low-level QUIC / TLS / QPACK primitives, exposed so a peer (a hand-rolled client, a test harness)
// can build the other side of the wire. This mirrors how zix.Http2 exposes its frame / HPACK
// primitives: the server is the product, these are the building blocks under it.
pub const crypto = @import("crypto.zig");
pub const protection = @import("protection.zig");
pub const keyschedule = @import("keyschedule.zig");
pub const qpack = @import("qpack.zig");
pub const huffman = @import("huffman.zig");
pub const packet = @import("packet.zig");
pub const varint = @import("varint.zig");
pub const frame = @import("frame.zig");
/// TLS 1.3 key schedule the QUIC handshake reuses (transcript hash, HKDF derive).
pub const tls_key_schedule = @import("../../tls/key_schedule.zig");
