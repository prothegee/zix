//! zix fix router — comptime route dispatch for FIX application messages.

const std = @import("std");
const core = @import("core.zig");
const Field = core.Field;
const FixContext = core.FixContext;
const FixRoute = core.FixRoute;
const wallClockNs = core.wallClockNs;

// --------------------------------------------------------- //

/// Comptime FIX application message router.
/// Routes are dispatched via inline for — zero overhead vs hand-written if/else.
/// Session messages (A, 0, 1, 5) are not dispatched. Only application MsgTypes are routed.
///
/// Usage:
/// ```zig
/// const r = zix.Fix.Router(&[_]zix.Fix.Route{
///     .{ .msg_type = "D", .handler = handleOrder },
///     .{ .msg_type = "F", .handler = handleCancel, .timeout_ms = 500 },
/// });
/// // pass r.routes to Server.init for server-level dispatch, or call r.dispatch directly.
/// ```
///
/// Param:
/// routes - []const FixRoute (comptime-known route table)
pub fn FixRouter(comptime routes: []const FixRoute) type {
    return struct {
        /// Runtime-accessible slice of the comptime route table.
        pub const route_slice: []const FixRoute = routes;

        /// Dispatch fields to the matching route handler.
        /// If no route matches, the message is silently ignored.
        ///
        /// Param:
        /// fields - []const Field (parsed fields from the received FIX message)
        /// ctx - *FixContext (per-connection context)
        /// server_timeout_ms - u32 (server-wide handler timeout; 0 = disabled)
        pub fn dispatch(fields: []const Field, ctx: *FixContext, server_timeout_ms: u32) void {
            const msgtype = core.getField(fields, .MsgType) orelse return;
            inline for (routes) |route| {
                if (std.mem.eql(u8, msgtype, route.msg_type)) {
                    const effective_ms = blk: {
                        const a = route.timeout_ms;
                        const b = server_timeout_ms;
                        break :blk if (a > 0 and b > 0) @min(a, b) else if (a > 0) a else b;
                    };
                    if (effective_ms > 0) {
                        ctx.deadline_ns = wallClockNs() + @as(u64, effective_ms) * std.time.ns_per_ms;
                    }
                    route.handler(fields, ctx);
                    return;
                }
            }
        }
    };
}

// --------------------------------------------------------- //

test "zix fix router: dispatch calls the matching handler" {
    const called = struct {
        var count: u32 = 0;
        fn handler(_: []const core.Field, _: *core.FixContext) void {
            count += 1;
        }
    };

    const R = FixRouter(&[_]FixRoute{
        .{ .msg_type = "D", .handler = called.handler },
    });

    var seq: u32 = 1;
    var ctx = FixContext{
        .sender_comp_id = "CLIENT",
        .target_comp_id = "SERVER",
        ._fd = 0,
        ._seq_out = &seq,
    };

    const fields = [_]Field{
        .{ .tag = .MsgType, .value = "D" },
        .{ .tag = .Symbol, .value = "AAPL" },
    };
    R.dispatch(&fields, &ctx, 0);
    try std.testing.expectEqual(@as(u32, 1), called.count);
}

test "zix fix router: no match leaves handler uncalled" {
    const called = struct {
        var count: u32 = 0;
        fn handler(_: []const core.Field, _: *core.FixContext) void {
            count += 1;
        }
    };
    called.count = 0;

    const R = FixRouter(&[_]FixRoute{
        .{ .msg_type = "D", .handler = called.handler },
    });

    var seq: u32 = 1;
    var ctx = FixContext{
        .sender_comp_id = "CLIENT",
        .target_comp_id = "SERVER",
        ._fd = 0,
        ._seq_out = &seq,
    };

    const fields = [_]Field{.{ .tag = .MsgType, .value = "F" }};
    R.dispatch(&fields, &ctx, 0);
    try std.testing.expectEqual(@as(u32, 0), called.count);
}

test "zix fix router: route timeout sets deadline_ns" {
    const noop = struct {
        fn handler(_: []const core.Field, _: *core.FixContext) void {}
    };

    const R = FixRouter(&[_]FixRoute{
        .{ .msg_type = "D", .handler = noop.handler, .timeout_ms = 100 },
    });

    var seq: u32 = 1;
    var ctx = FixContext{
        .sender_comp_id = "CLIENT",
        .target_comp_id = "SERVER",
        .deadline_ns = null,
        ._fd = 0,
        ._seq_out = &seq,
    };

    const fields = [_]Field{.{ .tag = .MsgType, .value = "D" }};
    R.dispatch(&fields, &ctx, 0);
    try std.testing.expect(ctx.deadline_ns != null);
}
