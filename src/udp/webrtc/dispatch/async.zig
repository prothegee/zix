//! zix WebRTC ASYNC dispatch: the portable single-worker loop, on every target zix builds for.
//!
//! What:
//! - One socket, one thread, and one peer table. Receive a datagram, give it to the peer it came
//!   from, send back whatever that produced, then look at the deadlines nobody's datagram
//!   answered.
//!
//! Note:
//! - The wait is bounded, and that is the whole reason this engine exists. A loop that parks in
//!   receive until the next datagram cannot retransmit a DTLS flight into silence, and a peer that
//!   lost the server's flight would wait forever for one that never comes again.
//! - Readiness first, then a plain receive. A timed std.Io receive races the receive against a
//!   timer, which needs the Io to run both, and the Windows backend answers
//!   error.ConcurrencyUnavailable for a socket receive submitted that way.

const std = @import("std");

const Config = @import("../config.zig");
const WebrtcServerConfig = Config.WebrtcServerConfig;
const common = @import("common.zig");
const connection = @import("../connection.zig");
const core = @import("../core.zig");
const socket_poll = @import("../../../utils/socket_poll.zig");
const table = @import("../table.zig");

/// Run the WebRTC server with a single worker on the calling thread.
///
/// Param:
/// handler - comptime core.HandlerFn
/// config - WebrtcServerConfig (already validated by the server)
///
/// Return:
/// - !void, blocking until the socket cannot be worked with
pub fn runAsync(comptime handler: core.HandlerFn, config: WebrtcServerConfig) !void {
    const io = config.io;

    const socket = try common.bindSocket(config);
    defer socket.close(io);

    var peers = try table.Table.init(config.allocator, config.max_peers);
    defer peers.deinit();

    const recv_buf = try config.allocator.alloc(u8, config.max_recv_buf);
    defer config.allocator.free(recv_buf);

    const send_buf = try config.allocator.alloc(u8, common.sendBufBytes(config));
    defer config.allocator.free(send_buf);

    const options = common.optionsFrom(config);
    const start = std.Io.Clock.Timestamp.now(io, .awake);

    common.logSystem(config, "listening on {s}:{d} (single worker)", .{ config.ip, config.port });

    while (true) {
        const before_ms = common.elapsedMs(start, std.Io.Clock.Timestamp.now(io, .awake));
        const budget_ms = common.waitMs(&peers, before_ms, config);

        const ready = socket_poll.waitReady(socket.handle, socket_poll.READABLE, budget_ms) catch |err| {
            common.logSystem(config, "poll error: {s}", .{@errorName(err)});

            continue;
        };

        const now_ms = common.elapsedMs(start, std.Io.Clock.Timestamp.now(io, .awake));

        if (ready) receiveOne(handler, &peers, socket, config, options, recv_buf, send_buf, now_ms);

        // Deadlines are only worth walking when the wait ran out, or when one of them has actually
        // come due. Under steady traffic neither is true and the walk is skipped.
        const due = if (peers.earliestDeadline()) |at_ms| at_ms <= now_ms else false;

        if (!ready or due) common.sweepPeers(handler, &peers, now_ms, socket, config, send_buf);
    }
}

/// Take one datagram off the socket and give it to the peer it came from.
fn receiveOne(
    comptime handler: core.HandlerFn,
    peers: *table.Table,
    socket: std.Io.net.Socket,
    config: WebrtcServerConfig,
    options: connection.Options,
    recv_buf: []u8,
    send_buf: []u8,
    now_ms: u64,
) void {
    const message = socket.receive(config.io, recv_buf) catch |err| {
        common.logSystem(config, "receive error: {s}", .{@errorName(err)});

        return;
    };

    // A datagram the buffer could not hold is one no layer below can parse, and every layer here
    // is authenticated, so guessing at the missing bytes is not an option.
    if (message.flags.trunc) {
        common.logSystem(config, "dropped a datagram larger than max_recv_buf ({d})", .{config.max_recv_buf});

        return;
    }

    const peer = peers.find(message.from) orelse open: {
        const opened = peers.acquire(message.from, options, common.drawSecrets(), now_ms) catch |err| {
            common.logSystem(config, "could not open a peer: {s}", .{@errorName(err)});

            return;
        };

        break :open opened orelse {
            common.logSystem(config, "peer table is full ({d}), dropping a datagram from a new address", .{peers.live});

            return;
        };
    };

    const outcome = peer.handle(message.data, now_ms) catch |err| {
        common.logSystem(config, "peer raised {s}", .{@errorName(err)});

        return;
    };

    if (outcome.dead) {
        _ = peers.release(message.from);

        return;
    }

    if (outcome.established) common.logSystem(config, "peer completed the dtls handshake", .{});

    common.drainPeer(handler, peer, now_ms, socket, config, send_buf);
}
