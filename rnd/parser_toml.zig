//! Parser PoC: TOML (hand-written parser, no std support), read/write file I/O
//! benchmark.
//!
//! Note:
//! - There is no std TOML parser, so this is a hand-written line scanner, scoped
//!   to exactly the shape this PoC needs (one flat table, one string field, one
//!   array-of-strings field, no nested tables, no dates, no multi-line strings).
//!   Not a spec-complete TOML implementation. The format is a single `[record]`
//!   table followed by `key = value` lines:
//!     [record]
//!     id = 1
//!     name = "foo_0"
//!     score = 0.5
//!     active = true
//!     tags = ["urgent", "verified", "retail"]
//!   `tags` uses TOML's native array literal, unlike the comma-line convention the
//!   cfg PoC needs for the same field.
//! - One record lives at `rnd/parser_toml_read.toml` (bootstrapped once if
//!   missing). The read phase opens, reads, and parses that file `iterations`
//!   times (real file I/O every time), appending each parsed record into one held
//!   []Record. The write phase then serializes each held record back out, one at a
//!   time, to `rnd/parser_toml_write.toml` (truncated every iteration). Shared
//!   harness in parser_common.zig.
//! - The `name` and `tags` values are duped into the parse allocator, so the
//!   parsed record owns its strings independent of the input buffer.
//!
//! Run: zig run rnd/parser_toml.zig
//! Run (smaller set first): zig run rnd/parser_toml.zig -- 10000

const std = @import("std");
const common = @import("parser_common.zig");

const read_path = "rnd/parser_toml_read.toml";
const write_path = "rnd/parser_toml_write.toml";

const ParseError = error{
    UnknownKey,
    MissingSection,
    OutOfMemory,
    InvalidNumber,
    InvalidBool,
    InvalidString,
    InvalidArray,
};

/// Serialize one record as a TOML `[record]` table into `writer`.
fn writeRecord(writer: *std.Io.Writer, record: common.Record) !void {
    try writer.print("[record]\nid = {d}\nname = \"{s}\"\nscore = {d}\nactive = {}\ntags = [", .{ record.id, record.name, record.score, record.active });

    for (record.tags, 0..) |tag, idx| {
        if (idx != 0) try writer.writeAll(", ");
        try writer.print("\"{s}\"", .{tag});
    }

    try writer.writeAll("]\n");
}

/// Serialize `record` and write it to `path`, truncating any existing file.
fn writeRecordToFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8, record: common.Record) !usize {
    var writer_buf = std.Io.Writer.Allocating.init(allocator);
    try writeRecord(&writer_buf.writer, record);

    const bytes = writer_buf.writer.buffer[0..writer_buf.writer.end];
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });

    return bytes.len;
}

fn parseBool(value: []const u8) ParseError!bool {
    if (std.mem.eql(u8, value, "true")) return true;
    if (std.mem.eql(u8, value, "false")) return false;

    return error.InvalidBool;
}

/// Strip one pair of surrounding double quotes from `value`.
fn unquote(value: []const u8) ParseError![]const u8 {
    if (value.len < 2 or value[0] != '"' or value[value.len - 1] != '"') return error.InvalidString;

    return value[1 .. value.len - 1];
}

/// Parse a TOML array literal `["a", "b"]` into a fresh slice of duped strings.
fn parseTagArray(allocator: std.mem.Allocator, value: []const u8) ParseError![][]const u8 {
    if (value.len < 2 or value[0] != '[' or value[value.len - 1] != ']') return error.InvalidArray;

    const inner = std.mem.trim(u8, value[1 .. value.len - 1], " \t");

    var tags: std.ArrayList([]const u8) = .empty;
    if (inner.len == 0) return tags.toOwnedSlice(allocator);

    var item_it = std.mem.splitScalar(u8, inner, ',');
    while (item_it.next()) |item| {
        const trimmed = std.mem.trim(u8, item, " \t");
        const tag = try unquote(trimmed);

        try tags.append(allocator, try allocator.dupe(u8, tag));
    }

    return tags.toOwnedSlice(allocator);
}

/// Parse the TOML input into one record.
fn parse(allocator: std.mem.Allocator, input: []const u8) ParseError!common.Record {
    var record: common.Record = .{ .id = 0, .name = "", .score = 0, .active = false, .tags = &.{} };
    var seen_header = false;

    var lines = std.mem.splitScalar(u8, input, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;

        if (std.mem.eql(u8, line, "[record]")) {
            seen_header = true;
            continue;
        }

        if (!seen_header) return error.MissingSection;

        const eq_pos = std.mem.indexOfScalar(u8, line, '=') orelse return error.UnknownKey;
        const key = std.mem.trim(u8, line[0..eq_pos], " \t");
        const value = std.mem.trim(u8, line[eq_pos + 1 ..], " \t");

        if (std.mem.eql(u8, key, "id")) {
            record.id = std.fmt.parseInt(u64, value, 10) catch return error.InvalidNumber;
        } else if (std.mem.eql(u8, key, "name")) {
            record.name = try allocator.dupe(u8, try unquote(value));
        } else if (std.mem.eql(u8, key, "score")) {
            record.score = std.fmt.parseFloat(f64, value) catch return error.InvalidNumber;
        } else if (std.mem.eql(u8, key, "active")) {
            record.active = try parseBool(value);
        } else if (std.mem.eql(u8, key, "tags")) {
            record.tags = try parseTagArray(allocator, value);
        } else {
            return error.UnknownKey;
        }
    }

    if (!seen_header) return error.MissingSection;

    return record;
}

/// Open, read, and parse one record from `path`.
fn readRecordFromFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !struct { record: common.Record, bytes: usize } {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1 << 16));
    const record = try parse(allocator, bytes);

    return .{ .record = record, .bytes = bytes.len };
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
    common.report("toml", "read", iterations, read_bytes, read_ns, read_counter.peak);

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

    common.report("toml", "write", iterations, write_bytes, write_ns, write_counter.peak);
}
