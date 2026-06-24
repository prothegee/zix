//! zix.Http3 namespace: a pure-Zig HTTP/3 (QUIC) server on the zix.Udp datagram substrate.
//!
//! What:
//! - Re-exports the public surface: the `Http3(handler)` server type, the request / response shapes,
//!   the server config, and the shared DispatchModel. The QUIC / TLS / QPACK machinery is internal.

const server = @import("server.zig");
const core = @import("core.zig");
const Config = @import("config.zig");

/// The HTTP/3 server type, bound to a comptime handler.
pub const Http3 = server.Http3;
/// The application request handler type.
pub const HandlerFn = core.HandlerFn;
/// A decoded HTTP/3 request.
pub const Request = core.Request;
/// The response the handler fills.
pub const Response = core.Response;
/// The HTTP/3 server config.
pub const ServerConfig = Config.Http3ServerConfig;
/// The dispatch model, shared with the rest of the engine family (ADR-050).
pub const DispatchModel = Config.DispatchModel;
