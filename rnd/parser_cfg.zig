//! Parser PoC: CFG (INI-style sections, hand-written parser).
//!
//! Note:
//! - There is no std .cfg parser, so this is a hand-written line scanner. The format
//!   is one `[record]` section per record followed by `key=value` lines:
//!     [record]
//!     id=1
//!     name=foo_0
//!     score=0.5
//!     active=true
//!   Records are separated by a blank line. A new `[record]` header flushes the
//!   record being built, and the last record is flushed at end of input.
//! - The `name` value is duped into the parse allocator, so the parsed records own
//!   their strings independent of the input buffer (matching the json/zon PoCs).
//!
//! Run: zig run rnd/parser_cfg.zig
//! Run (smaller set first): zig run rnd/parser_cfg.zig -- 10000

const std = @import("std");
const common = @import("parser_common.zig");

const ParseError = error{
    UnknownKey,
    MissingSection,
    OutOfMemory,
    InvalidNumber,
    InvalidBool,
};

/// Serialize `count` records as INI sections into `w`.
fn generate(w: *std.Io.Writer, count: usize) !void {
    var i: usize = 0;
    while (i < count) : (i += 1) {
        try w.print("[record]\nid={d}\nname=foo_{d}\nscore={d}\nactive={}\n\n", .{ i + 1, i, common.scoreOf(i), common.activeOf(i) });
    }
}

fn parseBool(value: []const u8) ParseError!bool {
    if (std.mem.eql(u8, value, "true")) return true;
    if (std.mem.eql(u8, value, "false")) return false;

    return error.InvalidBool;
}

/// Parse the INI-style input into a freshly allocated slice of records.
fn parse(allocator: std.mem.Allocator, input: []const u8) ParseError![]common.Record {
    var list: std.ArrayList(common.Record) = .empty;

    var current: common.Record = undefined;
    var in_record = false;

    var lines = std.mem.splitScalar(u8, input, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;

        if (std.mem.eql(u8, line, "[record]")) {
            if (in_record) try list.append(allocator, current);

            current = .{ .id = 0, .name = "", .score = 0, .active = false };
            in_record = true;

            continue;
        }

        const eq = std.mem.indexOfScalar(u8, line, '=') orelse return error.UnknownKey;
        const key = line[0..eq];
        const value = line[eq + 1 ..];

        if (!in_record) return error.MissingSection;

        if (std.mem.eql(u8, key, "id")) {
            current.id = std.fmt.parseInt(u64, value, 10) catch return error.InvalidNumber;
        } else if (std.mem.eql(u8, key, "name")) {
            current.name = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "score")) {
            current.score = std.fmt.parseFloat(f64, value) catch return error.InvalidNumber;
        } else if (std.mem.eql(u8, key, "active")) {
            current.active = try parseBool(value);
        } else {
            return error.UnknownKey;
        }
    }

    if (in_record) try list.append(allocator, current);

    return list.toOwnedSlice(allocator);
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
    const records = try parse(parse_alloc, input);
    const parse_ns = common.nowNs() - start_ns;

    std.debug.assert(records.len == count);
    std.debug.assert(records[count - 1].id == count);

    common.report("cfg", count, input.len, parse_ns, counter.peak);
}
