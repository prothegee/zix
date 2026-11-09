//! JZON example serialize
//!
//! ### file: src/jzon/examples/serialize.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! A typed value into JSON text, in a buffer the caller owns, through every write
//! strategy.
//!
//! ### note:
//!
//! A render allocates nothing. It is handed a buffer and returns how many bytes it
//! used. A value that does not fit is `Jzon_Serialize_NoSpaceLeft`, never a bigger
//! buffer. Every strategy renders the same bytes, so picking one is a cost decision.
//! Build with `zig build example-serialize` from `src/jzon`, then run
//! `./zig-out/bin/jzon-example-serialize-<arch>-<os>-<mode>`.
//!
//! ---------------------------------------------------------
//!
//! ### licenses:
//!
//! - BSD-3-Clause
//!
//! ### copyright:
//!
//! - (c) Prana Ron // @prothegee // prothegee@pm.me
//!
//! ### contributors:
//!
//! - Prana Ron // @prothegee // prothegee@pm.me
//!

const std = @import("std");
const jzon = @import("jzon");

// --------------------------------------------------------- //
// Private:

/// Every write path, so one value can be rendered through all of them.
const STRATEGIES = [_]jzon.json.SerializeStrategy{
    .STD,
    .GENERATED_FMT,
    .GENERATED,
    .GENERATED_VECTOR,
};

const Status = enum { PENDING, SHIPPED, CANCELLED };

const Line = struct {
    sku: []const u8,
    qty: u32,
    price_cents: i64,
};

const Order = struct {
    id: u64,
    customer: []const u8,
    status: Status,
    note: ?[]const u8 = null,
    tags: []const []const u8,
    lines: []const Line,
};

const ORDER: Order = .{
    .id = 4815162342,
    .customer = "Rekha Nair",
    .status = .SHIPPED,
    .note = "leave at the door",
    .tags = &.{ "priority", "gift" },
    .lines = &.{
        .{
            .sku = "AB-1",
            .qty = 2,
            .price_cents = 1299,
        },
        .{
            .sku = "CD-2",
            .qty = 1,
            .price_cents = 4500,
        },
    },
};

/// Render the order the way a caller who has made no choice gets it.
fn renderWithTheDefault() !void {
    var buf: [512]u8 = undefined;

    const len = try jzon.json.serialize(&buf, ORDER, .{});

    std.debug.print("default strategy, {d} bytes:\n{s}\n\n", .{ len, buf[0..len] });
}

/// Render the same order through every path and check the bytes agree.
fn renderThroughEveryStrategy() !void {
    var expected: [512]u8 = undefined;
    const expected_len = try jzon.json.serialize(&expected, ORDER, .{});

    inline for (STRATEGIES) |strategy| {
        var buf: [512]u8 = undefined;
        const len = try jzon.json.serialize(&buf, ORDER, .{ .strategy = strategy });

        std.debug.print("{t}: {d} bytes, same bytes as the default: {}\n", .{
            strategy,
            len,
            std.mem.eql(u8, expected[0..expected_len], buf[0..len]),
        });
    }

    std.debug.print("\n", .{});
}

/// Render an unset optional, which is written as `null`.
fn renderAnUnsetOptional() !void {
    var order = ORDER;
    order.note = null;

    var buf: [512]u8 = undefined;
    const len = try jzon.json.serialize(&buf, order, .{ .strategy = .GENERATED });

    std.debug.print("an unset optional is written as null:\n{s}\n\n", .{buf[0..len]});
}

/// Hand a render less room than the value needs.
fn renderIntoABufferTooSmall() void {
    var buf: [16]u8 = undefined;

    if (jzon.json.serialize(&buf, ORDER, .{})) |len| {
        std.debug.print("unexpected: {d} bytes rendered into {d}\n", .{ len, buf.len });
    } else |err| {
        std.debug.print("a buffer of {d} bytes reports {t}\n", .{ buf.len, err });
        std.debug.print("no length comes back, so the buffer holds no readable value\n", .{});
    }
}

// --------------------------------------------------------- //
// Public:

// main takes no std.process.Init because a render touches no IO and no allocator.
pub fn main() !void {
    try renderWithTheDefault();
    try renderThroughEveryStrategy();
    try renderAnUnsetOptional();

    renderIntoABufferTooSmall();
}

