//! JZON example unknown_keys
//!
//! ### file: src/jzon/examples/unknown_keys.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! A key the type does not declare: `.REJECT` against `.SKIP`, in JSON and ZON.
//!
//! ### note:
//!
//! `.REJECT` (the default) calls the document wrong for this type. `.SKIP` steps
//! over the key and its whole value, however deep it nests, and reads the rest.
//! `.SKIP` forgives keys the type does not want, never keys it is owed, so a missing
//! field still fails. Build with `zig build example-unknown_keys` from `src/jzon`,
//! then run `./zig-out/bin/jzon-example-unknown_keys-<arch>-<os>-<mode>`.
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

/// Every read path, so both answers can be shown on all of them.
const STRATEGIES = [_]jzon.json.DeserializeStrategy{
    .STD,
    .SCANNER,
    .GENERATED,
    .GENERATED_VECTOR,
};

const Status = enum { PENDING, SHIPPED, CANCELLED };

const Order = struct {
    id: u64,
    customer: []const u8,
    status: Status,
};

/// The document this build's type was written for.
const KNOWN = "{\"id\":7,\"customer\":\"Rekha Nair\",\"status\":\"SHIPPED\"}";

/// The same order from a sender that carries more: a flat extra field, a nested
/// object, and an array of objects. None of it is declared by `Order`.
const EXTENDED =
    "{\"id\":7,\"customer\":\"Rekha Nair\",\"channel\":\"mobile\"," ++
    "\"address\":{\"city\":\"Bandung\",\"geo\":{\"lat\":-6.9,\"lon\":107.6}}," ++
    "\"history\":[{\"at\":\"2026-01-01\",\"was\":\"PENDING\"}]," ++
    "\"status\":\"SHIPPED\"}";

/// The extended document with the field the type is owed taken out of it.
const OWED = "{\"id\":7,\"channel\":\"mobile\",\"status\":\"SHIPPED\"}";

/// The extended order as ZON.
const EXTENDED_ZON =
    \\.{
    \\    .id = 7,
    \\    .customer = "Rekha Nair",
    \\    .channel = "mobile",
    \\    .address = .{
    \\        .city = "Bandung",
    \\        .geo = .{
    \\            .lat = -6.9,
    \\            .lon = 107.6,
    \\        },
    \\    },
    \\    .history = .{
    \\        .{
    \\            .at = "2026-01-01",
    \\            .was = .PENDING,
    \\        },
    \\    },
    \\    .status = .SHIPPED,
    \\}
;

/// Print how one parse went.
fn report(label: []const u8, mode: jzon.json.Unknown, outcome: anytype) void {
    if (outcome) |order| {
        std.debug.print("{s} under {t}: order {d} for {s}, {t}\n", .{
            label,
            mode,
            order.id,
            order.customer,
            order.status,
        });
    } else |err| {
        std.debug.print("{s} under {t}: {t} (field '{s}')\n", .{
            label,
            mode,
            err,
            jzon.lastFailure().field,
        });
    }
}

/// Read one JSON document under one answer and print how it went.
fn readJson(
    allocator: std.mem.Allocator,
    label: []const u8,
    src: []const u8,
    comptime mode: jzon.json.Unknown,
) void {
    report(label, mode, jzon.json.deserialize(Order, allocator, src, .{ .unknown = mode }));
}

/// Read the ZON document under one answer and print how it went.
fn readZon(allocator: std.mem.Allocator, comptime mode: jzon.json.Unknown) void {
    const outcome = jzon.zon.deserialize(Order, allocator, EXTENDED_ZON, .{ .unknown = mode });

    report("extended zon", mode, outcome);
}

/// Show that the answer holds whichever JSON read path runs.
fn readEveryStrategy(arena: *std.heap.ArenaAllocator) !void {
    inline for (STRATEGIES) |strategy| {
        defer _ = arena.reset(.retain_capacity);

        const refused = jzon.json.deserialize(Order, arena.allocator(), EXTENDED, .{
            .strategy = strategy,
            .unknown = .REJECT,
        });
        const skipped = try jzon.json.deserialize(Order, arena.allocator(), EXTENDED, .{
            .strategy = strategy,
            .unknown = .SKIP,
        });

        if (refused) |order| {
            std.debug.print("{t}: unexpected, REJECT read order {d}\n", .{ strategy, order.id });
        } else |err| {
            std.debug.print("{t}: REJECT gives {t}, SKIP reads order {d}\n", .{
                strategy,
                err,
                skipped.id,
            });
        }
    }
}

// --------------------------------------------------------- //
// Public:

// main takes no std.process.Init because a parse touches no IO. It only needs an
// allocator.
pub fn main() !void {
    var arena: std.heap.ArenaAllocator = .init(std.heap.smp_allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    // A document the type was written for reads under both answers.
    readJson(allocator, "known", KNOWN, .REJECT);
    readJson(allocator, "known", KNOWN, .SKIP);

    // A document carrying more than the type declares is where they part.
    readJson(allocator, "extended", EXTENDED, .REJECT);
    readJson(allocator, "extended", EXTENDED, .SKIP);
    readZon(allocator, .REJECT);
    readZon(allocator, .SKIP);

    // Skipping forgives the extra key and still reports the missing one.
    readJson(allocator, "owed", OWED, .REJECT);
    readJson(allocator, "owed", OWED, .SKIP);
    std.debug.print("\n", .{});

    _ = arena.reset(.retain_capacity);

    try readEveryStrategy(&arena);
}

