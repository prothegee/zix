//! GET /ws : upgrade the connection, then hand it to the engine's echo loop.
//!
//! Note:
//! - Nothing is cached. Echo is per connection, so there is nothing to share
//!   between them.

const std = @import("std");
const zix = @import("zix");

// --------------------------------------------------------- //

pub const PATH = "/ws";

// --------------------------------------------------------- //

/// Echo one text or binary frame back to its sender.
///
/// Note:
/// - Ping and close are answered by the engine before this runs.
fn onFrame(fd: std.posix.fd_t, opcode: u8, payload: []const u8) void {
    zix.Http1.WebSocket.sendFD(fd, @enumFromInt(opcode), payload) catch {};
}

// --------------------------------------------------------- //

pub fn RESPONSE(req: *zix.Http1.Request, res: *zix.Http1.Response, _: *zix.Http1.Context) !void {
    const upgrade = req.header("upgrade") orelse "";
    const key = req.header("sec-websocket-key");

    if (!std.ascii.eqlIgnoreCase(upgrade, "websocket") or key == null) {
        res.setStatus(.BAD_REQUEST);

        try res.send("not a websocket upgrade request");
        return;
    }

    zix.Http1.WebSocket.serve(req.fd, key.?, onFrame) catch {
        res.setStatus(.INTERNAL_SERVER_ERROR);

        try res.send("handshake failed");
        return;
    };
}
