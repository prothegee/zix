//! zix HTTP/3 application handler surface.
//!
//! What:
//! - The request / response shapes the application handler sees, and the `HandlerFn` type the server
//!   facade bakes at comptime. The QUIC / packet machinery is internal: the handler works at the HTTP
//!   request level, the same altitude as the other zix engines.

const std = @import("std");

const response = @import("response.zig");

/// The content coding a handler may set on its response body (`res.content_encoding`). Re-exported from
/// the wire layer so a handler names it as `zix.Http3.ContentEncoding` without reaching into internals.
pub const ContentEncoding = response.ContentEncoding;

/// A decoded HTTP/3 request handed to the application handler. The slices point into the engine's
/// per-connection decode buffer and are valid only for the duration of the handler call.
pub const Request = struct {
    method: []const u8,
    path: []const u8,
    authority: []const u8 = "",
    body: []const u8 = "",
    /// The client's `accept-encoding` value, or empty when it sent none. A handler negotiates a
    /// pre-compressed body against it (for example serving a `.br` variant when it contains `br`) and
    /// sets `res.content_encoding` to match.
    accept_encoding: []const u8 = "",
};

/// The response the handler fills. The body is copied into the engine's send path after the handler
/// returns, so it may point at handler-owned or static memory.
pub const Response = struct {
    status: u16 = 200,
    body: []const u8 = "",
    /// Content type. A handler may set it, but the v1 HTTP/3 response path does not emit it on the
    /// wire yet (only `:status` and `content-encoding` are QPACK-encoded). Kept for the handler API
    /// and for when it is wired.
    content_type: []const u8 = "text/plain",

    /// The content coding of `body`. When not identity the serve path emits a `content-encoding`
    /// response header (RFC 9114 4.1). The handler owns the coding: `body` must already be encoded
    /// with it (the engine never compresses on the send path).
    content_encoding: ContentEncoding = .identity,

    /// Set the HTTP status code.
    pub fn setStatus(self: *Response, status: u16) void {
        self.status = status;
    }

    /// Set the response body.
    pub fn send(self: *Response, body: []const u8) void {
        self.body = body;
    }

    /// Set the content coding of the body (the handler must have encoded `body` accordingly).
    pub fn setContentEncoding(self: *Response, encoding: ContentEncoding) void {
        self.content_encoding = encoding;
    }
};

/// The application request handler, baked into the server type at comptime.
pub const HandlerFn = *const fn (req: *const Request, res: *Response) void;

// --------------------------------------------------------------- //
// --------------------------------------------------------------- //

fn echoHandler(req: *const Request, res: *Response) void {
    res.setStatus(200);
    res.send(req.path);
}

// A handler that serves a pre-compressed brotli variant when the client accepts br, else identity: the
// content-negotiation shape the static routes use.
fn negotiateHandler(req: *const Request, res: *Response) void {
    if (std.mem.indexOf(u8, req.accept_encoding, "br") != null) {
        res.setContentEncoding(.br);
        res.send("<brotli-bytes>");
    } else {
        res.send("<identity-bytes>");
    }
}

test "zix http3: Response setters and handler shape" {
    const req = Request{ .method = "GET", .path = "/hello", .authority = "example.com" };
    var res = Response{};
    echoHandler(&req, &res);

    try std.testing.expectEqual(@as(u16, 200), res.status);
    try std.testing.expectEqualSlices(u8, "/hello", res.body);
    try std.testing.expectEqualSlices(u8, "text/plain", res.content_type);
    try std.testing.expectEqual(ContentEncoding.identity, res.content_encoding);
}

test "zix http3: a handler negotiates content-encoding off the request accept-encoding" {
    var br_res = Response{};
    negotiateHandler(&.{ .method = "GET", .path = "/x", .accept_encoding = "gzip, deflate, br" }, &br_res);
    try std.testing.expectEqual(ContentEncoding.br, br_res.content_encoding);
    try std.testing.expectEqualSlices(u8, "<brotli-bytes>", br_res.body);

    var plain_res = Response{};
    negotiateHandler(&.{ .method = "GET", .path = "/x" }, &plain_res);
    try std.testing.expectEqual(ContentEncoding.identity, plain_res.content_encoding);
}
