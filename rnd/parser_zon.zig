//! Parser PoC: ZON (std.zon, Zig Object Notation).
//!
//! Note:
//! - Generates 1,000,000 records as a ZON anonymous tuple of structs, then parses
//!   with std.zon.parse.fromSliceAlloc into []common.Record and reports parse time,
//!   throughput, and peak parse-time memory. Shared harness in parser_common.zig.
//! - fromSliceAlloc (not fromSlice) is required because the result contains pointers
//!   (the `name` slice). ZON parsing first builds a full std.zig.Ast of the source,
//!   so for a 1,000,000-element tuple the AST itself dominates the memory peak. That
//!   is a real property of the format: ZON is a config notation, not a bulk-data one.
//! - The source must be sentinel-terminated ([:0]const u8), so a trailing 0 byte is
//!   appended after generation.
//!
//! Run: zig run rnd/parser_zon.zig
//! Run (smaller set first): zig run rnd/parser_zon.zig -- 10000

const std = @import("std");
const common = @import("parser_common.zig");

/// Serialize `count` records as a ZON tuple `.{ .{ .id = ... }, ... }` into `w`.
fn generate(w: *std.Io.Writer, count: usize) !void {
    try w.writeAll(".{");

    var i: usize = 0;
    while (i < count) : (i += 1) {
        if (i != 0) try w.writeByte(',');

        try w.print(".{{.id={d},.name=\"foo_{d}\",.score={d},.active={}}}", .{ i + 1, i, common.scoreOf(i), common.activeOf(i) });
    }

    try w.writeByte('}');
}

pub fn main(process: std.process.Init) !void {
    const count = common.countFromArgs(process);

    var gen_arena = std.heap.ArenaAllocator.init(common.base_allocator);
    defer gen_arena.deinit();

    var aw = std.Io.Writer.Allocating.init(gen_arena.allocator());
    try generate(&aw.writer, count);
    try aw.writer.writeByte(0);

    const written = aw.writer.buffer[0..aw.writer.end];
    const source: [:0]const u8 = written[0 .. written.len - 1 :0];

    var counter = common.CountingAllocator{ .child = common.base_allocator };
    var parse_arena = std.heap.ArenaAllocator.init(counter.allocator());
    defer parse_arena.deinit();

    const parse_alloc = if (common.use_arena) parse_arena.allocator() else counter.allocator();

    const start_ns = common.nowNs();
    const records = try std.zon.parse.fromSliceAlloc([]common.Record, parse_alloc, source, null, .{});
    const parse_ns = common.nowNs() - start_ns;

    std.debug.assert(records.len == count);
    std.debug.assert(records[count - 1].id == count);

    common.report("zon", count, source.len, parse_ns, counter.peak);
}
