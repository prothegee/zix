//! Shared harness for the parser PoCs (parser_json / _zon / _cfg).
//!
//! Note:
//! - The three PoCs generate the SAME 1,000,000 records (same principle data
//!   types: id u64, name string, score f64, active bool), each serialized in its
//!   own format, then parse them back and report parse time, throughput, and peak
//!   parse-time memory. This isolates the cost of each format's parser.
//! - Generation memory is NOT counted. Only the parse step runs under the counting
//!   allocator, so the reported peak is the parser's footprint alone.
//! - Memory backing: an ArenaAllocator over `smp_allocator` by default (USE_ARENA),
//!   wrapped by CountingAllocator. Arena models how zix uses memory per request
//!   (parse, use, then free the whole arena at once), and std.json already builds
//!   its own internal arena. Flip USE_ARENA to false to benchmark the plain
//!   general-purpose smp_allocator instead (real per-allocation free, so the peak
//!   reflects the true live set rather than the arena high-water mark).
//!
//! Run: this file is the shared harness, not runnable on its own. Run each PoC:
//!   zig run rnd/parser_json.zig
//!   zig run rnd/parser_zon.zig
//!   zig run rnd/parser_cfg.zig
//! Pass a smaller record count as argv[1] to validate first (default 1,000,000):
//!   zig run rnd/parser_json.zig -- 10000
//! Switch the parse allocator by editing `use_arena` below (true = arena, false =
//!   plain smp_allocator). No -Doptimize is set, so these are debug-build numbers.

const std = @import("std");

/// Default record count. Override with argv[1] (e.g. `zig run ... -- 10000`) to
/// validate on a smaller set before the full 1,000,000 run.
pub const default_count: usize = 1_000_000;

/// Backing allocator for the parse step. See the file note for the trade-off.
pub const use_arena = true;

/// General-purpose base under both the arena and the counter.
pub const base_allocator = std.heap.smp_allocator;

/// One generated record. The three formats all serialize and parse this shape.
pub const Record = struct {
    id: u64,
    name: []const u8,
    score: f64,
    active: bool,
};

/// Deterministic field values for record `i`, shared by all three generators so
/// the inputs are equivalent. score always carries a fractional part (a valid
/// float literal in every format), active alternates.
pub fn scoreOf(i: usize) f64 {
    return @as(f64, @floatFromInt(i % 1000)) + 0.5;
}

pub fn activeOf(i: usize) bool {
    return (i & 1) == 0;
}

/// Counting allocator: wraps a child allocator and tracks live bytes and the
/// high-water mark, so a PoC can report the parser's peak memory.
pub const CountingAllocator = struct {
    child: std.mem.Allocator,
    in_use: usize = 0,
    peak: usize = 0,

    pub fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn note(self: *CountingAllocator) void {
        if (self.in_use > self.peak) self.peak = self.in_use;
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));

        const ptr = self.child.rawAlloc(len, alignment, ret_addr) orelse return null;
        self.in_use += len;
        self.note();

        return ptr;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));

        if (!self.child.rawResize(memory, alignment, new_len, ret_addr)) return false;

        self.in_use = self.in_use - memory.len + new_len;
        self.note();

        return true;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));

        const ptr = self.child.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
        self.in_use = self.in_use - memory.len + new_len;
        self.note();

        return ptr;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));

        self.child.rawFree(memory, alignment, ret_addr);
        self.in_use -= memory.len;
    }
};

/// Read the record count from argv[1], falling back to `default_count`.
pub fn countFromArgs(process: std.process.Init) usize {
    var args = std.process.Args.Iterator.init(process.minimal.args);
    _ = args.skip();

    if (args.next()) |first| {
        return std.fmt.parseInt(usize, first, 10) catch default_count;
    }

    return default_count;
}

/// Monotonic clock in nanoseconds, used to time the parse step without plumbing
/// an Io instance through the PoC.
pub fn nowNs() u64 {
    var spec: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &spec);

    return @as(u64, @intCast(spec.sec)) * 1_000_000_000 + @as(u64, @intCast(spec.nsec));
}

/// Print one comparable result line for a format.
///
/// Param:
/// label - []const u8 (format name, e.g. "json")
/// count - usize (records parsed)
/// input_bytes - usize (serialized input size)
/// parse_ns - u64 (parse wall time in nanoseconds)
/// peak_bytes - usize (CountingAllocator high-water mark during parse)
pub fn report(label: []const u8, count: usize, input_bytes: usize, parse_ns: u64, peak_bytes: usize) void {
    const mib = @as(f64, @floatFromInt(input_bytes)) / (1024.0 * 1024.0);
    const ms = @as(f64, @floatFromInt(parse_ns)) / 1_000_000.0;
    const secs = @as(f64, @floatFromInt(parse_ns)) / 1_000_000_000.0;
    const throughput = if (secs > 0) mib / secs else 0;
    const peak_mib = @as(f64, @floatFromInt(peak_bytes)) / (1024.0 * 1024.0);

    std.debug.print("{s:<5} {d:>9} recs  input={d:>7.1} MiB  parse={d:>9.2} ms  {d:>7.0} MiB/s  peak={d:>7.1} MiB\n", .{ label, count, mib, ms, throughput, peak_mib });
}
