//! WebRTC check body: one whole data channel session against a running zix answerer.
//!
//! What:
//! - Spawns the echo server, dials it through webrtc_client, and asserts the message came back
//!   unchanged. Shared by the standalone runner and by all_runner, so both exercise the same path.
//!
//! Note:
//! - The dialing side binds its own port, and each caller passes a different one, so two checks
//!   running at the same time never contend for it.

const std = @import("std");
const common = @import("common.zig");
const webrtc_client = @import("webrtc_client.zig");

const SERVER_IP: []const u8 = "127.0.0.1";
/// The dialer's own port for this check. Outside the range the examples use.
const BIND_PORT: u16 = 9196;
/// UDP has no connection handshake to poll, so the server gets a fixed moment to bind.
const WAIT_MS: i64 = 600;

const MESSAGE: []const u8 = "webrtc-datachannel-ping";

/// Run one data channel session against the echo server.
///
/// Param:
/// io - std.Io
/// server_path - []const u8 (the echo server binary)
/// port - u16 (where it listens)
///
/// Return:
/// - void
/// - error.EchoMismatch when the answerer sent back something else
/// - error.SessionTimeout when the session never reached an open channel
pub fn runWebrtc(io: std.Io, server_path: []const u8, port: u16) !void {
    var server_child = try common.spawnServer(io, server_path);
    defer server_child.kill(io);

    try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(WAIT_MS), .awake);

    var echo_buf: [256]u8 = undefined;
    const echo = try webrtc_client.echoOnce(io, SERVER_IP, port, BIND_PORT, MESSAGE, &echo_buf);

    if (!std.mem.eql(u8, echo, MESSAGE)) return error.EchoMismatch;
}
