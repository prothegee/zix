//! JZON example zon_file
//!
//! ### file: src/jzon/examples/zon_file.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Real `.zon` files in and out: read `examples/order.zon` and `build.zig.zon` into
//! typed records, write a changed order back to a file, and read it again.
//!
//! ### note:
//!
//! jzon reads and writes slices, not files. The file is read once with `std.Io`, then
//! the slice is parsed, and a render is written once. Paths are relative, so run it
//! from `src/jzon`. The written file lands in `.tmp/` and is kept to be opened after
//! the run. Build with `zig build example-zon_file` from `src/jzon`, then run
//! `./zig-out/bin/jzon-example-zon_file-<arch>-<os>-<mode>`.
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

/// The order this example reads, shipped next to it.
const INPUT_PATH = "examples/order.zon";

/// The package manifest, read as a typed record.
const PACKAGE_PATH = "build.zig.zon";

/// Where the written file goes. `.tmp/` is ignored by git.
const OUTPUT_DIR = ".tmp";

/// The written file.
const OUTPUT_PATH = ".tmp/jzon_example_order.zon";

/// The largest file this example reads.
const MAX_FILE_BYTES = 64 * 1024;

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

/// The parts of `build.zig.zon` this example wants. Any other key is skipped.
const Package = struct {
    const Name = enum { jzon };

    const Semver = struct {
        major: u32,
        minor: u32,
        patch: u32,
    };

    name: Name,
    version: []const u8,
    semver: Semver,
    fingerprint: u64,
    minimum_zig_version: []const u8,
    paths: []const []const u8,
};

/// Read a whole file, saying where to run from when it is not there.
fn readFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const cwd = std.Io.Dir.cwd();

    return cwd.readFileAlloc(io, path, allocator, .limited(MAX_FILE_BYTES)) catch |err| {
        std.debug.print("cannot read {s} ({t}), run this from src/jzon\n", .{ path, err });

        return err;
    };
}

/// Print the fields of an order.
fn describe(order: Order) void {
    std.debug.print("  id {d}, customer {s}, status {t}, note {s}\n", .{
        order.id,
        order.customer,
        order.status,
        order.note orelse "(none)",
    });
    std.debug.print("  {d} tags, {d} lines\n", .{
        order.tags.len,
        order.lines.len,
    });
}

/// Read the shipped order file into a typed record.
fn readOrderFile(io: std.Io, allocator: std.mem.Allocator) !Order {
    const text = try readFile(io, allocator, INPUT_PATH);
    const order = try jzon.zon.deserialize(Order, allocator, text, .{});

    std.debug.print("read {s} ({d} bytes):\n", .{ INPUT_PATH, text.len });
    describe(order);
    std.debug.print("\n", .{});

    return order;
}

/// Change the order, write it to a file, and read the file back.
fn writeAndReadBack(io: std.Io, allocator: std.mem.Allocator, order: Order) !void {
    var changed = order;
    changed.status = .CANCELLED;
    changed.note = null;

    var buf: [4 * 1024]u8 = undefined;
    const len = try jzon.zon.serialize(&buf, changed, .{});

    // The render ends at the closing brace. A file ends with a line feed.
    if (len == buf.len) return error.NoSpaceLeft;

    buf[len] = '\n';
    const written = buf[0 .. len + 1];

    const cwd = std.Io.Dir.cwd();

    try cwd.createDirPath(io, OUTPUT_DIR);
    try cwd.writeFile(io, .{
        .sub_path = OUTPUT_PATH,
        .data = written,
    });

    std.debug.print("wrote {s} ({d} bytes):\n{s}\n", .{
        OUTPUT_PATH,
        written.len,
        written,
    });

    const text = try readFile(io, allocator, OUTPUT_PATH);
    const back = try jzon.zon.deserialize(Order, allocator, text, .{});

    std.debug.print("read it back:\n", .{});
    describe(back);
    std.debug.print("\n", .{});

    const compact_len = try jzon.zon.serialize(&buf, back, .{ .layout = .COMPACT });

    std.debug.print("the same order, COMPACT:\n{s}\n\n", .{buf[0..compact_len]});
}

/// Read the package manifest as a typed record, skipping keys it does not declare.
fn readPackageFile(io: std.Io, allocator: std.mem.Allocator) !void {
    const text = try readFile(io, allocator, PACKAGE_PATH);
    const package = try jzon.zon.deserialize(Package, allocator, text, .{ .unknown = .SKIP });

    std.debug.print("read {s}:\n", .{PACKAGE_PATH});
    std.debug.print("  name .{t}, version {s}, zig {s}\n", .{
        package.name,
        package.version,
        package.minimum_zig_version,
    });
    std.debug.print("  semver {d}.{d}.{d}, fingerprint 0x{x}\n", .{
        package.semver.major,
        package.semver.minor,
        package.semver.patch,
        package.fingerprint,
    });

    std.debug.print("  paths:", .{});
    for (package.paths) |path| std.debug.print(" {s}", .{path});
    std.debug.print("\n\n", .{});
}

/// Hand a parse a file body with a mistake in it, and read what `lastFailure` says.
fn readABrokenDocument(allocator: std.mem.Allocator) void {
    const broken = ".{ .id = 1, .customer = \"Ada\", .status = .GONE }";

    if (jzon.zon.deserialize(Order, allocator, broken, .{})) |order| {
        std.debug.print("unexpected: read order {d}\n", .{order.id});
    } else |err| {
        const failure = jzon.lastFailure();

        std.debug.print("a broken document reports {t}: '{s}' at byte {d}\n", .{
            err,
            failure.field,
            failure.offset,
        });
    }
}

// --------------------------------------------------------- //
// Public:

// main takes std.process.Init for io: the file reads and writes need it. The parse
// and render calls themselves touch no IO.
pub fn main(init: std.process.Init) !void {
    var arena: std.heap.ArenaAllocator = .init(init.gpa);
    defer arena.deinit();

    const allocator = arena.allocator();

    const order = try readOrderFile(init.io, allocator);

    try writeAndReadBack(init.io, allocator, order);
    try readPackageFile(init.io, allocator);

    readABrokenDocument(allocator);
}

