//! Shared harness for the parser PoCs (parser_json / _zon / _cfg / _toml).
//!
//! Note:
//! - Each PoC keeps ONE record on disk at `rnd/parser_<fmt>_read.<ext>` (bootstrapped
//!   once if missing) and repeatedly opens, reads, and parses it `iterations` times
//!   (default 1,000,000, real file I/O every time, not a cached in-memory reparse).
//!   The parsed records are appended into one held []Record, then written back out,
//!   one at a time, to `rnd/parser_<fmt>_write.<ext>` (also real file I/O, truncated
//!   every iteration). Read and write are timed and reported separately.
//! - Only the read loop and the write loop run under the counting allocator, each
//!   with its own arena, so the reported peak is that phase's footprint alone.
//!   Bootstrap memory is NOT counted.
//! - Memory backing: an ArenaAllocator over `smp_allocator` by default (USE_ARENA),
//!   wrapped by CountingAllocator. Arena models how zix uses memory per request
//!   (parse, use, then free the whole arena at once). Flip USE_ARENA to false to
//!   benchmark the plain general-purpose smp_allocator instead (real per-allocation
//!   free, so the peak reflects the true live set rather than the arena high-water
//!   mark).
//!
//! Run: this file is the shared harness, not runnable on its own. Run each PoC:
//!   zig run rnd/parser_json.zig
//!   zig run rnd/parser_zon.zig
//!   zig run rnd/parser_cfg.zig
//!   zig run rnd/parser_toml.zig
//! Pass a smaller iteration count as argv[1] to validate first (default 1,000,000):
//!   zig run rnd/parser_json.zig -- 10000
//! Switch the parse allocator by editing `use_arena` below (true = arena, false =
//!   plain smp_allocator). No -Doptimize is set, so these are debug-build numbers.

const std = @import("std");

/// Default iteration count (records read and written). Override with argv[1]
/// (e.g. `zig run ... -- 10000`) to validate on a smaller set before the full run.
pub const default_count: usize = 1_000_000;

/// Backing allocator for the read and write loops. See the file note for the trade-off.
pub const use_arena = true;

/// General-purpose base under both the arena and the counter.
pub const base_allocator = std.heap.smp_allocator;

/// One record. All four formats serialize and parse this shape.
pub const Record = struct {
    id: u64,
    name: []const u8,
    score: f64,
    active: bool,
    tags: [][]const u8,
};

/// The single record every format bootstraps, reads, and writes back. `allocator`
/// owns `name` and every `tags` entry, so an arena is expected.
pub fn sampleRecord(allocator: std.mem.Allocator) !Record {
    const tag_values = [_][]const u8{ "urgent", "verified", "retail" };

    var tags = try allocator.alloc([]const u8, tag_values.len);
    for (tag_values, 0..) |value, idx| tags[idx] = try allocator.dupe(u8, value);

    return .{
        .id = 1,
        .name = try allocator.dupe(u8, "foo_0"),
        .score = 0.5,
        .active = true,
        .tags = tags,
    };
}

/// Sleep for `secs` seconds on the awake (monotonic) clock, used to give a clean
/// boundary between the read and write phases when observing process memory
/// externally.
pub fn sleepSeconds(io: std.Io, secs: u64) !void {
    try std.Io.sleep(io, .{ .nanoseconds = @as(i96, @intCast(secs)) * std.time.ns_per_s }, .awake);
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

/// Print one comparable result line for a format's read or write phase.
///
/// Param:
/// label - []const u8 (format name, e.g. "json")
/// phase - []const u8 ("read" or "write")
/// count - usize (iterations, one record each)
/// total_bytes - usize (sum of bytes moved across all iterations)
/// elapsed_ns - u64 (phase wall time in nanoseconds)
/// peak_bytes - usize (CountingAllocator high-water mark during the phase)
pub fn report(label: []const u8, phase: []const u8, count: usize, total_bytes: usize, elapsed_ns: u64, peak_bytes: usize) void {
    const mib = @as(f64, @floatFromInt(total_bytes)) / (1024.0 * 1024.0);
    const ms = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0;
    const secs = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0;
    const throughput = if (secs > 0) mib / secs else 0;
    const peak_mib = @as(f64, @floatFromInt(peak_bytes)) / (1024.0 * 1024.0);

    std.debug.print("{s:<5} {s:<5} {d:>9} recs  bytes={d:>8.1} MiB  time={d:>9.2} ms  {d:>7.0} MiB/s  peak={d:>7.1} MiB\n", .{ label, phase, count, mib, ms, throughput, peak_mib });
}
