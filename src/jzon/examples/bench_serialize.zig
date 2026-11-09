//! JZON example bench_serialize
//!
//! ### file: src/jzon/examples/bench_serialize.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! What each write path costs on one record: every JSON strategy, then both ZON
//! layouts, in ns per render against the JSON default's rate.
//!
//! ### note:
//!
//! Build with `-Doptimize=ReleaseFast`. A Debug build measures the safety checks
//! rather than the paths. The quickest of ROUNDS is reported, not the mean. Every
//! JSON path is checked to render the same bytes before any timing, so the table
//! compares equal work. Build with `zig build example-bench_serialize
//! -Doptimize=ReleaseFast` from `src/jzon`, then run
//! `./zig-out/bin/jzon-example-bench_serialize-<arch>-<os>-fast`.
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

/// Renders one round does.
const ITERATIONS: usize = 100_000;

/// Rounds run per row. The quickest is what gets reported.
const ROUNDS: usize = 5;

/// Room for one rendered record.
const BUFFER_BYTES = 512;

/// Every JSON write path, the default first so the ratio column has a base.
const STRATEGIES = [_]jzon.json.SerializeStrategy{
    .STD,
    .GENERATED_FMT,
    .GENERATED,
    .GENERATED_VECTOR,
};

/// Both ZON layouts.
const LAYOUTS = [_]jzon.zon.ZonOptions.Layout{
    .MULTILINE,
    .COMPACT,
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

/// Which format a timed row renders.
const Format = union(enum) {
    JSON: jzon.json.SerializeStrategy,
    ZON: jzon.zon.ZonOptions.Layout,
};

/// Nanoseconds since `started` on the monotonic clock.
fn since(io: std.Io, started: std.Io.Timestamp) u64 {
    const ended = std.Io.Timestamp.now(io, .awake);

    return @intCast(started.durationTo(ended).nanoseconds);
}

/// Render the order once in one format.
fn renderOnce(buf: []u8, comptime format: Format) !usize {
    return switch (format) {
        .JSON => |strategy| jzon.json.serialize(buf, ORDER, .{ .strategy = strategy }),
        .ZON => |layout| jzon.zon.serialize(buf, ORDER, .{ .layout = layout }),
    };
}

/// Render the order ITERATIONS times, ROUNDS times over.
///
/// Return:
/// - u64 (nanoseconds the quickest round took)
fn timeFormat(io: std.Io, comptime format: Format) !u64 {
    var buf: [BUFFER_BYTES]u8 = undefined;

    // One render before the clock starts warms the code path.
    _ = try renderOnce(&buf, format);

    var best: u64 = std.math.maxInt(u64);

    for (0..ROUNDS) |_| {
        const started = std.Io.Timestamp.now(io, .awake);

        for (0..ITERATIONS) |_| {
            const len = try renderOnce(&buf, format);
            std.mem.doNotOptimizeAway(len);
        }

        best = @min(best, since(io, started));
    }

    return best;
}

/// Print one row and hand back its rate, so the first row can be the base.
fn printRow(name: []const u8, elapsed: u64, base_rate: f64) f64 {
    const per_render = @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(ITERATIONS));
    const rate = @as(f64, std.time.ns_per_s) / per_render;
    const base = if (base_rate == 0) rate else base_rate;

    std.debug.print("{s: <20}{d: >12.0}{d: >14.0}{d: >11.2}x\n", .{
        name,
        per_render,
        rate,
        rate / base,
    });

    return rate;
}

/// Check every JSON path renders the same bytes, so the table compares equal work.
fn checkPathsAgree() !void {
    var expected: [BUFFER_BYTES]u8 = undefined;
    const expected_len = try jzon.json.serialize(&expected, ORDER, .{});

    inline for (STRATEGIES) |strategy| {
        var buf: [BUFFER_BYTES]u8 = undefined;
        const len = try jzon.json.serialize(&buf, ORDER, .{ .strategy = strategy });

        if (!std.mem.eql(u8, expected[0..expected_len], buf[0..len])) {
            return error.PathsDisagree;
        }
    }

    std.debug.print("every JSON path renders the same {d} bytes\n\n", .{expected_len});
}

// --------------------------------------------------------- //
// Public:

// main takes std.process.Init for io: the monotonic clock comes from it. The renders
// themselves touch no IO and no allocator.
pub fn main(init: std.process.Init) !void {
    try checkPathsAgree();

    std.debug.print("serialize: {d} renders per round, quickest of {d} rounds\n\n", .{
        ITERATIONS,
        ROUNDS,
    });
    std.debug.print("{s: <20}{s: >12}{s: >14}{s: >12}\n", .{
        "path",
        "ns/render",
        "renders/s",
        "vs default",
    });

    var base: f64 = 0;

    inline for (STRATEGIES) |strategy| {
        const elapsed = try timeFormat(init.io, .{ .JSON = strategy });
        const rate = printRow("json " ++ @tagName(strategy), elapsed, base);

        if (base == 0) base = rate;
    }

    inline for (LAYOUTS) |layout| {
        const elapsed = try timeFormat(init.io, .{ .ZON = layout });

        _ = printRow("zon " ++ @tagName(layout), elapsed, base);
    }
}

