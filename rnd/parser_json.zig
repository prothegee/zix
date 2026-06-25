//! Parser PoC: JSON (std.json).
//!
//! Note:
//! - Generates 1,000,000 records as a JSON array, then parses with
//!   std.json.parseFromSlice into []common.Record and reports parse time,
//!   throughput, and peak parse-time memory. Shared harness in parser_common.zig.
//! - std.json dupes every string, so the parsed result owns its `name` bytes
//!   independent of the input buffer.
//!
//! Run: zig run rnd/parser_json.zig
//! Run (smaller set first): zig run rnd/parser_json.zig -- 10000

const std = @import("std");
const common = @import("parser_common.zig");

/// Serialize `count` records as a JSON array into `w`.
fn generate(w: *std.Io.Writer, count: usize) !void {
    try w.writeByte('[');

    var i: usize = 0;
    while (i < count) : (i += 1) {
        if (i != 0) try w.writeByte(',');

        try w.print("{{\"id\":{d},\"name\":\"foo_{d}\",\"score\":{d},\"active\":{}}}", .{ i + 1, i, common.scoreOf(i), common.activeOf(i) });
    }

    try w.writeByte(']');
}

pub fn main(process: std.process.Init) !void {
    const count = common.countFromArgs(process);

    var gen_arena = std.heap.ArenaAllocator.init(common.base_allocator);
    defer gen_arena.deinit();

    var aw = std.Io.Writer.Allocating.init(gen_arena.allocator());
    try generate(&aw.writer, count);

    const input = aw.writer.buffer[0..aw.writer.end];

    var counter = common.CountingAllocator{ .child = common.base_allocator };
    var parse_arena = std.heap.ArenaAllocator.init(counter.allocator());
    defer parse_arena.deinit();

    const parse_alloc = if (common.use_arena) parse_arena.allocator() else counter.allocator();

    const start_ns = common.nowNs();
    const parsed = try std.json.parseFromSlice([]common.Record, parse_alloc, input, .{});
    const parse_ns = common.nowNs() - start_ns;

    std.debug.assert(parsed.value.len == count);
    std.debug.assert(parsed.value[count - 1].id == count);

    common.report("json", count, input.len, parse_ns, counter.peak);
}
