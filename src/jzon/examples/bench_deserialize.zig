//! JZON example bench_deserialize
//!
//! ### file: src/jzon/examples/bench_deserialize.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! What each read path costs on one record: every JSON strategy on a minified and a
//! laid-out document, ZON in both layouts, and reading a real file against parsing it.
//!
//! ### note:
//!
//! Build with `-Doptimize=ReleaseFast`. A Debug build measures the safety checks
//! rather than the paths. The quickest of ROUNDS is reported, not the mean. The arena
//! reset sits inside the timed loop, because a worker pays it per request. The file
//! rows read `examples/order.json` and `examples/order.zon`, so run it from
//! `src/jzon`. Build with `zig build example-bench_deserialize -Doptimize=ReleaseFast`
//! from `src/jzon`, then run `./zig-out/bin/jzon-example-bench_deserialize-<arch>-<os>-fast`.
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

/// Parses one round does.
const ITERATIONS: usize = 100_000;

/// Rounds run per row. The quickest is what gets reported.
const ROUNDS: usize = 5;

/// The JSON file the file rows read.
const JSON_PATH = "examples/order.json";

/// The ZON file the file rows read.
const ZON_PATH = "examples/order.zon";

/// The largest file the file rows read.
const MAX_FILE_BYTES = 4096;

/// Every JSON read path, the default first so the ratio column has a base.
const STRATEGIES = [_]jzon.json.DeserializeStrategy{
    .STD,
    .SCANNER,
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

/// The shape that arrives off a wire: no whitespace anywhere.
const JSON_MINIFIED =
    "{\"id\":4815162342,\"customer\":\"Rekha Nair\",\"status\":\"SHIPPED\"," ++
    "\"note\":\"leave at the door\",\"tags\":[\"priority\",\"gift\"]," ++
    "\"lines\":[{\"sku\":\"AB-1\",\"qty\":2,\"price_cents\":1299}," ++
    "{\"sku\":\"CD-2\",\"qty\":1,\"price_cents\":4500}]}";

/// The same value, laid out the way a client that pretty prints sends it.
const JSON_LAID_OUT =
    \\{
    \\  "id": 4815162342,
    \\  "customer": "Rekha Nair",
    \\  "status": "SHIPPED",
    \\  "note": "leave at the door",
    \\  "tags": ["priority", "gift"],
    \\  "lines": [
    \\    {"sku": "AB-1", "qty": 2, "price_cents": 1299},
    \\    {"sku": "CD-2", "qty": 1, "price_cents": 4500}
    \\  ]
    \\}
;

/// The same value as ZON on one line.
const ZON_COMPACT =
    ".{ .id = 4815162342, .customer = \"Rekha Nair\", .status = .SHIPPED, " ++
    ".note = \"leave at the door\", .tags = .{ \"priority\", \"gift\" }, " ++
    ".lines = .{ .{ .sku = \"AB-1\", .qty = 2, .price_cents = 1299 }, " ++
    ".{ .sku = \"CD-2\", .qty = 1, .price_cents = 4500 } } }";

/// What every document holds, so a parse that read less cannot go untimed.
const EXPECTED_LINES: usize = 2;

/// Which format and path a timed row parses with.
const Parse = union(enum) {
    JSON: jzon.json.DeserializeStrategy,
    ZON,
};

/// Nanoseconds since `started` on the monotonic clock.
fn since(io: std.Io, started: std.Io.Timestamp) u64 {
    const ended = std.Io.Timestamp.now(io, .awake);

    return @intCast(started.durationTo(ended).nanoseconds);
}

/// Parse a document once.
fn parseOnce(allocator: std.mem.Allocator, src: []const u8, comptime parse: Parse) !Order {
    return switch (parse) {
        .JSON => |strategy| jzon.json.deserialize(Order, allocator, src, .{
            .strategy = strategy,
        }),
        .ZON => jzon.zon.deserialize(Order, allocator, src, .{}),
    };
}

/// Parse a document ITERATIONS times, ROUNDS times over.
///
/// Return:
/// - u64 (nanoseconds the quickest round took)
/// - error.WrongShape when the parse did not read the whole document
fn timeParse(
    io: std.Io,
    arena: *std.heap.ArenaAllocator,
    src: []const u8,
    comptime parse: Parse,
) !u64 {
    // One parse before the clock starts warms the code path and proves the path
    // reads the whole document.
    {
        defer _ = arena.reset(.retain_capacity);

        const order = try parseOnce(arena.allocator(), src, parse);
        if (order.lines.len != EXPECTED_LINES) return error.WrongShape;
    }

    var best: u64 = std.math.maxInt(u64);

    for (0..ROUNDS) |_| {
        const started = std.Io.Timestamp.now(io, .awake);

        for (0..ITERATIONS) |_| {
            const order = try parseOnce(arena.allocator(), src, parse);
            std.mem.doNotOptimizeAway(&order);

            _ = arena.reset(.retain_capacity);
        }

        best = @min(best, since(io, started));
    }

    return best;
}

/// Read a file ITERATIONS times, ROUNDS times over, parsing each read when asked.
///
/// Return:
/// - u64 (nanoseconds the quickest round took)
fn timeFile(
    io: std.Io,
    arena: *std.heap.ArenaAllocator,
    path: []const u8,
    comptime parse: ?Parse,
) !u64 {
    const cwd = std.Io.Dir.cwd();
    var best: u64 = std.math.maxInt(u64);

    for (0..ROUNDS) |_| {
        const started = std.Io.Timestamp.now(io, .awake);

        for (0..ITERATIONS) |_| {
            const limit: std.Io.Limit = .limited(MAX_FILE_BYTES);
            const src = try cwd.readFileAlloc(io, path, arena.allocator(), limit);
            std.mem.doNotOptimizeAway(src.ptr);

            if (parse) |chosen| {
                const order = try parseOnce(arena.allocator(), src, chosen);
                std.mem.doNotOptimizeAway(&order);
            }

            _ = arena.reset(.retain_capacity);
        }

        best = @min(best, since(io, started));
    }

    return best;
}

/// Print a table heading.
fn printHeading(what: []const u8, size: usize) void {
    std.debug.print("{s} ({d} bytes): {d} parses per round, quickest of {d} rounds\n\n", .{
        what,
        size,
        ITERATIONS,
        ROUNDS,
    });
    std.debug.print("{s: <24}{s: >12}{s: >14}{s: >12}\n", .{
        "path",
        "ns/op",
        "ops/s",
        "vs first",
    });
}

/// Print one row and hand back its rate, so the first row can be the base.
fn printRow(name: []const u8, elapsed: u64, base_rate: f64) f64 {
    const per_op = @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(ITERATIONS));
    const rate = @as(f64, std.time.ns_per_s) / per_op;
    const base = if (base_rate == 0) rate else base_rate;

    std.debug.print("{s: <24}{d: >12.0}{d: >14.0}{d: >11.2}x\n", .{
        name,
        per_op,
        rate,
        rate / base,
    });

    return rate;
}

/// Print one table: every JSON read path over one document.
fn runJson(
    io: std.Io,
    arena: *std.heap.ArenaAllocator,
    what: []const u8,
    src: []const u8,
) !void {
    printHeading(what, src.len);

    var base: f64 = 0;

    inline for (STRATEGIES) |strategy| {
        const elapsed = try timeParse(io, arena, src, .{ .JSON = strategy });
        const rate = printRow(@tagName(strategy), elapsed, base);

        if (base == 0) base = rate;
    }

    std.debug.print("\n", .{});
}

/// Print the ZON table: one path, both layouts.
fn runZon(io: std.Io, arena: *std.heap.ArenaAllocator, laid_out: []const u8) !void {
    printHeading("zon deserialize", laid_out.len);

    const base = printRow("multiline", try timeParse(io, arena, laid_out, .ZON), 0);
    _ = printRow("compact", try timeParse(io, arena, ZON_COMPACT, .ZON), base);

    std.debug.print("\n", .{});
}

/// Print the file table for one format: parse only, read only, read and parse.
fn runFile(
    io: std.Io,
    arena: *std.heap.ArenaAllocator,
    path: []const u8,
    src: []const u8,
    comptime parse: Parse,
) !void {
    printHeading(path, src.len);

    const base = printRow("parse only", try timeParse(io, arena, src, parse), 0);
    _ = printRow("read only", try timeFile(io, arena, path, null), base);
    _ = printRow("read + parse", try timeFile(io, arena, path, parse), base);

    std.debug.print("\n", .{});
}

// --------------------------------------------------------- //
// Public:

// main takes std.process.Init for io: the clock and the file rows need it. The parse
// calls themselves touch no IO.
pub fn main(init: std.process.Init) !void {
    var arena: std.heap.ArenaAllocator = .init(std.heap.smp_allocator);
    defer arena.deinit();

    const cwd = std.Io.Dir.cwd();
    const limit: std.Io.Limit = .limited(MAX_FILE_BYTES);

    // The files are read once up front, so the parse-only rows parse the same bytes
    // the file rows read.
    const json_file = cwd.readFileAlloc(init.io, JSON_PATH, init.gpa, limit) catch |err| {
        std.debug.print("cannot read {s} ({t}), run this from src/jzon\n", .{ JSON_PATH, err });

        return err;
    };
    defer init.gpa.free(json_file);

    const zon_file = try cwd.readFileAlloc(init.io, ZON_PATH, init.gpa, limit);
    defer init.gpa.free(zon_file);

    try runJson(init.io, &arena, "json deserialize, minified", JSON_MINIFIED);
    try runJson(init.io, &arena, "json deserialize, laid out", JSON_LAID_OUT);
    try runZon(init.io, &arena, zon_file);

    try runFile(init.io, &arena, JSON_PATH, json_file, .{ .JSON = .GENERATED });
    try runFile(init.io, &arena, ZON_PATH, zon_file, .ZON);
}

