//! zix http context

const std = @import("std");

pub const Context = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    response_sent: bool = false,
    /// Raw TCP stream, available for WebSocket upgrade handlers.
    /// Normal HTTP handlers should not use this directly.
    stream: std.Io.net.Stream = undefined,
    /// Optional handler deadline set by the server from config.handler_timeout_ms.
    /// Null when handler_timeout_ms == 0 (disabled). Use withTimeout / timedOut.
    deadline: ?std.Io.Clock.Timestamp = null,

    /// Return a copy of ctx with deadline set to now + ms.
    /// Call before dispatching to a slow handler; check timedOut() between steps.
    pub fn withTimeout(self: Context, ms: u64) Context {
        var c = self;
        c.deadline = std.Io.Clock.Timestamp.fromNow(
            self.io,
            std.Io.Clock.Duration{ .raw = std.Io.Duration.fromMilliseconds(@intCast(ms)), .clock = .real },
        );
        return c;
    }

    /// Return a copy of ctx with an explicit deadline timestamp.
    pub fn withDeadline(self: Context, ts: std.Io.Clock.Timestamp) Context {
        var c = self;
        c.deadline = ts;
        return c;
    }

    /// Returns true when the deadline has passed. Always false when deadline is null.
    /// Does not cancel or interrupt anything. Handlers must check this explicitly.
    pub fn timedOut(self: Context) bool {
        const d = self.deadline orelse return false;
        return std.Io.Clock.Timestamp.now(self.io, .real).compare(.gte, d);
    }
};

// --------------------------------------------------------- //

test "zix test: Context.timedOut -- null deadline always false" {
    // io is intentionally undefined: timedOut() must short-circuit on null deadline
    // without touching io at all.
    const ctx = Context{ .io = undefined, .allocator = std.testing.allocator };
    try std.testing.expect(!ctx.timedOut());
}
