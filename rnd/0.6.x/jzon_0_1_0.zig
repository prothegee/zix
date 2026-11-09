//! JZON 0.1.0 benchmark
//!
//! ### file: rnd/0.6.x/jzon_0_1_0.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Times every write and read strategy of the pinned jzon 0.1.0 source, plus the
//! file read rows that settle whether IO or parse dominates.
//!
//! ### note:
//!
//! Run from the repo root: `zig run -OReleaseFast rnd/0.6.x/jzon_0_1_0.zig`.
//! The source under `jzon_0_1_0/` is a copy of `src/jzon/src` at commit `1f1029c1`
//! (jzon 0.1.0). `jzon_0_2_0.zig` is this same file with only the jzon import changed,
//! so the two tables compare like for like. The file rows write one temporary file
//! under `.tmp/` and delete it at the end.
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
const jzon = @import("jzon_0_1_0/lib.zig");

// --------------------------------------------------------- //
// Private:

/// Operations one round does.
const ITERATIONS: usize = 100_000;

/// Rounds run per row. The quickest is what gets reported.
const ROUNDS: usize = 5;

/// What the harness calls itself in every heading.
const LABEL = "jzon 0.1.0";

/// Where the file rows keep their document, relative to the repo root.
const FILE_DIR = ".tmp";
const FILE_PATH = ".tmp/jzon_bench_order.json";

/// Every write path, the default first so the ratio column has a base.
const WRITES = [_]jzon.SerializeStrategy{ .STD, .GENERATED_FMT, .GENERATED, .GENERATED_VECTOR };

/// Every read path, the default first so the ratio column has a base.
const READS = [_]jzon.DeserializeStrategy{ .STD, .SCANNER, .GENERATED, .GENERATED_VECTOR };

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

/// A document and what to call it in the heading.
const Document = struct {
    what: []const u8,
    text: []const u8,
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

/// The shape that arrives off a wire: no whitespace anywhere.
const MINIFIED =
    "{\"id\":4815162342,\"customer\":\"Rekha Nair\",\"status\":\"SHIPPED\"," ++
    "\"note\":\"leave at the door\",\"tags\":[\"priority\",\"gift\"]," ++
    "\"lines\":[{\"sku\":\"AB-1\",\"qty\":2,\"price_cents\":1299}," ++
    "{\"sku\":\"CD-2\",\"qty\":1,\"price_cents\":4500}]}";

/// The same value, laid out the way a client that pretty prints sends it.
const LAID_OUT =
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

const DOCUMENTS = [_]Document{
    .{
        .what = "minified",
        .text = MINIFIED,
    },
    .{
        .what = "laid out",
        .text = LAID_OUT,
    },
};

/// What every document holds, so a parse that read less cannot go untimed.
const EXPECTED_LINES: usize = 2;

/// Nanoseconds per operation for a round that took `elapsed`.
fn perOperation(elapsed: u64) f64 {
    return @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(ITERATIONS));
}

/// Nanoseconds between two readings of the monotonic clock.
fn since(io: std.Io, started: std.Io.Timestamp) u64 {
    const ended = std.Io.Timestamp.now(io, .awake);

    return @intCast(started.durationTo(ended).nanoseconds);
}

/// Print one row: the name, ns per operation, operations per second, and the ratio.
fn printRow(name: []const u8, elapsed: u64, base_rate: f64) f64 {
    const per_op = perOperation(elapsed);
    const rate = @as(f64, std.time.ns_per_s) / per_op;
    const base = if (base_rate == 0) rate else base_rate;

    std.debug.print("{s: <18}{d: >12.0}{d: >14.0}{d: >11.2}x\n", .{
        name,
        per_op,
        rate,
        rate / base,
    });

    return rate;
}

/// Print a table heading.
fn printHeading(what: []const u8, unit: []const u8) void {
    std.debug.print("{s}, {s}: {d} per round, quickest of {d} rounds\n\n", .{
        LABEL,
        what,
        ITERATIONS,
        ROUNDS,
    });
    std.debug.print("{s: <18}{s: >12}{s: >14}{s: >12}\n", .{
        "row",
        unit,
        "ops/s",
        "vs first",
    });
}

/// Render the order ITERATIONS times, ROUNDS times over, and keep the quickest round.
fn timeWrite(io: std.Io, comptime strategy: jzon.SerializeStrategy) !u64 {
    var buf: [512]u8 = undefined;

    // One render before the clock starts warms the path.
    _ = try jzon.serialize(&buf, ORDER, .{ .strategy = strategy });

    var best: u64 = std.math.maxInt(u64);

    for (0..ROUNDS) |_| {
        const started = std.Io.Timestamp.now(io, .awake);

        for (0..ITERATIONS) |_| {
            const len = try jzon.serialize(&buf, ORDER, .{ .strategy = strategy });
            std.mem.doNotOptimizeAway(len);
            std.mem.doNotOptimizeAway(&buf);
        }

        best = @min(best, since(io, started));
    }

    return best;
}

/// Parse `src` ITERATIONS times, ROUNDS times over, and keep the quickest round.
///
/// Note:
/// - The arena is reset after every parse, which is what a worker pays per request.
fn timeRead(
    io: std.Io,
    arena: *std.heap.ArenaAllocator,
    src: []const u8,
    comptime strategy: jzon.DeserializeStrategy,
) !u64 {
    // One parse before the clock starts warms the path and proves it reads the
    // whole document.
    {
        defer _ = arena.reset(.retain_capacity);

        const order = try jzon.deserialize(Order, arena.allocator(), src, .{
            .strategy = strategy,
        });
        if (order.lines.len != EXPECTED_LINES) return error.WrongShape;
    }

    var best: u64 = std.math.maxInt(u64);

    for (0..ROUNDS) |_| {
        const started = std.Io.Timestamp.now(io, .awake);

        for (0..ITERATIONS) |_| {
            const order = try jzon.deserialize(Order, arena.allocator(), src, .{
                .strategy = strategy,
            });
            std.mem.doNotOptimizeAway(&order);

            _ = arena.reset(.retain_capacity);
        }

        best = @min(best, since(io, started));
    }

    return best;
}

/// Read the document file ITERATIONS times, ROUNDS times over, parsing each read
/// when `parse` is set.
fn timeFile(
    io: std.Io,
    arena: *std.heap.ArenaAllocator,
    comptime parse: bool,
) !u64 {
    const cwd = std.Io.Dir.cwd();
    var best: u64 = std.math.maxInt(u64);

    for (0..ROUNDS) |_| {
        const started = std.Io.Timestamp.now(io, .awake);

        for (0..ITERATIONS) |_| {
            const src = try cwd.readFileAlloc(io, FILE_PATH, arena.allocator(), .limited(4096));
            std.mem.doNotOptimizeAway(src.ptr);

            if (parse) {
                const order = try jzon.deserialize(Order, arena.allocator(), src, .{
                    .strategy = .GENERATED,
                });
                std.mem.doNotOptimizeAway(&order);
            }

            _ = arena.reset(.retain_capacity);
        }

        best = @min(best, since(io, started));
    }

    return best;
}

/// Print the write table.
fn runWrites(io: std.Io) !void {
    printHeading("serialize", "ns/render");

    var base: f64 = 0;

    inline for (WRITES) |strategy| {
        const rate = printRow(@tagName(strategy), try timeWrite(io, strategy), base);

        if (base == 0) base = rate;
    }

    std.debug.print("\n", .{});
}

/// Print one read table: every read path over one document.
fn runReads(io: std.Io, arena: *std.heap.ArenaAllocator, document: Document) !void {
    const what = try std.fmt.allocPrint(std.heap.smp_allocator, "deserialize {s} ({d} B)", .{
        document.what,
        document.text.len,
    });
    defer std.heap.smp_allocator.free(what);

    printHeading(what, "ns/parse");

    var base: f64 = 0;

    inline for (READS) |strategy| {
        const rate = printRow(
            @tagName(strategy),
            try timeRead(io, arena, document.text, strategy),
            base,
        );

        if (base == 0) base = rate;
    }

    std.debug.print("\n", .{});
}

/// Print the file table: what reading the document costs next to parsing it.
fn runFile(io: std.Io, arena: *std.heap.ArenaAllocator) !void {
    const cwd = std.Io.Dir.cwd();

    try cwd.createDirPath(io, FILE_DIR);
    try cwd.writeFile(io, .{
        .sub_path = FILE_PATH,
        .data = MINIFIED,
    });
    defer cwd.deleteFile(io, FILE_PATH) catch |err| switch (err) {
        // Best effort: a leftover file under .tmp/ is rewritten on the next run.
        else => {},
    };

    printHeading("file IO against parse, minified, .GENERATED", "ns/op");

    const parse_only = try timeRead(io, arena, MINIFIED, .GENERATED);
    const base = printRow("parse only", parse_only, 0);

    _ = printRow("read only", try timeFile(io, arena, false), base);
    _ = printRow("read + parse", try timeFile(io, arena, true), base);

    std.debug.print("\n", .{});
}

// --------------------------------------------------------- //
// Public:

// main takes std.process.Init for io: the clock and the file rows need it. The
// render and parse calls themselves touch no IO.
pub fn main(process: std.process.Init) !void {
    var arena: std.heap.ArenaAllocator = .init(std.heap.smp_allocator);
    defer arena.deinit();

    try runWrites(process.io);

    for (DOCUMENTS) |document| {
        try runReads(process.io, &arena, document);
    }

    try runFile(process.io, &arena);
}

