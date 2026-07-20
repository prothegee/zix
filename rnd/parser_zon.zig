//! Parser PoC: ZON (std.zon, Zig Object Notation), read/write file I/O benchmark.
//!
//! Note:
//! - One record lives at `rnd/parser_zon_read.zon` (bootstrapped once if missing),
//!   an anonymous struct `.{ .id = ..., .tags = .{ "a", "b" }, ... }`. The read
//!   phase opens, reads, and parses that file `iterations` times (real file I/O
//!   every time) with std.zon.parse.fromSliceAlloc, appending each parsed record
//!   into one held []Record. The write phase then serializes each held record back
//!   out, one at a time, to `rnd/parser_zon_write.zon` (truncated every iteration).
//!   Shared harness in parser_common.zig.
//! - fromSliceAlloc (not fromSlice) is required because the result contains
//!   pointers (`name`, `tags`, and each tag string). ZON parsing first builds a
//!   full std.zig.Ast of the source, so the AST itself dominates the per-read cost.
//!   That is a real property of the format: ZON is a config notation, not a
//!   bulk-data one.
//! - The source must be sentinel-terminated ([:0]const u8). readFileAllocOptions
//!   appends the sentinel itself, so the file on disk holds plain text, no trailing
//!   0 byte required.
//!
//! Run: zig run rnd/parser_zon.zig
//! Run (smaller set first): zig run rnd/parser_zon.zig -- 10000

const std = @import("std");
const common = @import("parser_common.zig");

const read_path = "rnd/parser_zon_read.zon";
const write_path = "rnd/parser_zon_write.zon";

/// Serialize one record as a ZON anonymous struct into `writer`.
fn writeRecord(writer: *std.Io.Writer, record: common.Record) !void {
    try writer.print(".{{.id={d},.name=\"{s}\",.score={d},.active={},.tags=.{{", .{ record.id, record.name, record.score, record.active });

    for (record.tags, 0..) |tag, idx| {
        if (idx != 0) try writer.writeByte(',');
        try writer.print("\"{s}\"", .{tag});
    }

    try writer.writeAll("}}");
}

/// Serialize `record` and write it to `path`, truncating any existing file.
fn writeRecordToFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8, record: common.Record) !usize {
    var writer_buf = std.Io.Writer.Allocating.init(allocator);
    try writeRecord(&writer_buf.writer, record);

    const bytes = writer_buf.writer.buffer[0..writer_buf.writer.end];
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });

    return bytes.len;
}

/// Open, read, and parse one record from `path`.
fn readRecordFromFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !struct { record: common.Record, bytes: usize } {
    const source = try std.Io.Dir.cwd().readFileAllocOptions(io, path, allocator, .limited(1 << 16), .of(u8), 0);
    const record = try std.zon.parse.fromSliceAlloc(common.Record, allocator, source, null, .{});

    return .{ .record = record, .bytes = source.len };
}

pub fn main(process: std.process.Init) !void {
    const io = process.io;
    const iterations = common.countFromArgs(process);

    try common.sleepSeconds(io, 5);

    if (std.Io.Dir.cwd().access(io, read_path, .{})) |_| {} else |_| {
        var boot_arena = std.heap.ArenaAllocator.init(common.base_allocator);
        defer boot_arena.deinit();

        _ = try writeRecordToFile(io, boot_arena.allocator(), read_path, try common.sampleRecord(boot_arena.allocator()));
    }

    var read_counter = common.CountingAllocator{ .child = common.base_allocator };
    var read_arena = std.heap.ArenaAllocator.init(read_counter.allocator());
    defer read_arena.deinit();

    const read_alloc = if (common.use_arena) read_arena.allocator() else read_counter.allocator();

    var records: std.ArrayList(common.Record) = .empty;
    try records.ensureTotalCapacity(read_alloc, iterations);

    var read_bytes: usize = 0;
    var i: usize = 0;
    const read_start_ns = common.nowNs();
    while (i < iterations) : (i += 1) {
        const result = try readRecordFromFile(io, read_alloc, read_path);
        std.mem.doNotOptimizeAway(result.record.id);

        read_bytes += result.bytes;
        records.appendAssumeCapacity(result.record);
    }
    const read_ns = common.nowNs() - read_start_ns;

    std.debug.assert(records.items.len == iterations);
    common.report("zon", "read", iterations, read_bytes, read_ns, read_counter.peak);

    try common.sleepSeconds(io, 5);

    var write_counter = common.CountingAllocator{ .child = common.base_allocator };
    var write_arena = std.heap.ArenaAllocator.init(write_counter.allocator());
    defer write_arena.deinit();

    const write_alloc = if (common.use_arena) write_arena.allocator() else write_counter.allocator();

    var write_bytes: usize = 0;
    i = 0;
    const write_start_ns = common.nowNs();
    while (i < iterations) : (i += 1) {
        write_bytes += try writeRecordToFile(io, write_alloc, write_path, records.items[i]);
    }
    const write_ns = common.nowNs() - write_start_ns;

    common.report("zon", "write", iterations, write_bytes, write_ns, write_counter.peak);
}
