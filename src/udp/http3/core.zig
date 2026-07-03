//! zix HTTP/3 application handler surface.
//!
//! What:
//! - The request / response shapes the application handler sees, and the `HandlerFn` type the server
//!   facade bakes at comptime. The QUIC / packet machinery is internal: the handler works at the HTTP
//!   request level, the same altitude as the other zix engines.

const std = @import("std");

/// A decoded HTTP/3 request handed to the application handler. The slices point into the engine's
/// per-connection decode buffer and are valid only for the duration of the handler call.
pub const Request = struct {
    method: []const u8,
    path: []const u8,
    authority: []const u8 = "",
    body: []const u8 = "",
};

/// The response the handler fills. The body is copied into the engine's send path after the handler
/// returns, so it may point at handler-owned or static memory.
pub const Response = struct {
    status: u16 = 200,
    body: []const u8 = "",
    /// Content type. A handler may set it, but the v1 HTTP/3 response path does not emit it on the
    /// wire yet (only `:status` is QPACK-encoded). Kept for the handler API and for when it is wired.
    content_type: []const u8 = "text/plain",

    /// Set the HTTP status code.
    pub fn setStatus(self: *Response, status: u16) void {
        self.status = status;
    }

    /// Set the response body.
    pub fn send(self: *Response, body: []const u8) void {
        self.body = body;
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

test "zix test: Response setters and handler shape" {
    const req = Request{ .method = "GET", .path = "/hello", .authority = "example.com" };
    var res = Response{};
    echoHandler(&req, &res);

    try std.testing.expectEqual(@as(u16, 200), res.status);
    try std.testing.expectEqualSlices(u8, "/hello", res.body);
    try std.testing.expectEqualSlices(u8, "text/plain", res.content_type);
}
