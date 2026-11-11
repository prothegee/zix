//! ZIX multiplexers cpu affinity
//!
//! ### file: src/zix/multiplexers/cpu_affinity.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! CPU count and worker pinning for the .EPOLL and .URING models, within the
//! CPUs this process may use (cgroup and taskset aware).
//!
//! ### note:
//!
//! - Pin slots list each physical core once before any SMT sibling, so a
//!   small worker count never puts two workers on one core. Without sysfs
//!   topology files the affinity mask order is kept.
//! - Off Linux, pinning does nothing and the count falls back to the
//!   machine CPU count.
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
const builtin = @import("builtin");
const linux = std.os.linux;

// --------------------------------------------------------- //
// Private:

/// Widest allowed CPU list tracked: one slot per affinity mask bit.
const MAX_CPUS: usize = 256;

/// Path buffer for /sys/devices/system/cpu/cpu<N>/topology/<leaf>.
const TOPOLOGY_PATH_BUF_SIZE: usize = 80;

/// Value buffer for one sysfs topology read: a decimal id plus a newline.
const TOPOLOGY_VALUE_BUF_SIZE: usize = 16;

/// Read one decimal value from /sys/devices/system/cpu/cpu<N>/topology/<leaf>.
///
/// Return:
/// - u32 (the parsed value)
/// - null when the file is missing or malformed
fn readTopologyValue(cpu: u32, comptime leaf: []const u8) ?u32 {
    var path_buf: [TOPOLOGY_PATH_BUF_SIZE]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(
        &path_buf,
        "/sys/devices/system/cpu/cpu{d}/topology/" ++ leaf,
        .{cpu},
        0,
    ) catch |err| switch (err) {
        error.NoSpaceLeft => return null,
    };

    const open_rc = linux.open(path, .{
        .ACCMODE = .RDONLY,
        .CLOEXEC = true,
    }, 0);
    if (linux.errno(open_rc) != .SUCCESS) return null;

    const fd: std.posix.fd_t = @intCast(open_rc);
    defer _ = linux.close(fd);

    var value_buf: [TOPOLOGY_VALUE_BUF_SIZE]u8 = undefined;
    const read_rc = linux.read(fd, &value_buf, value_buf.len);
    if (linux.errno(read_rc) != .SUCCESS) return null;

    const trimmed = std.mem.trim(u8, value_buf[0..read_rc], " \n\t");

    return std.fmt.parseInt(u32, trimmed, 10) catch |err| switch (err) {
        else => null,
    };
}

/// Physical core key of a CPU: package id in the high half, core id in the
/// low half, so SMT siblings share a key and packages never collide.
fn coreKey(cpu: u32) ?u64 {
    const package = readTopologyValue(cpu, "physical_package_id") orelse return null;
    const core_id = readTopologyValue(cpu, "core_id") orelse return null;

    return (@as(u64, package) << 32) | core_id;
}

/// List the CPUs set in mask, lowest first, up to out.len.
fn maskCpus(mask: *const linux.cpu_set_t, out: []u32) usize {
    var count: usize = 0;

    for (mask, 0..) |word, word_index| {
        var bits = word;
        while (bits != 0) : (bits &= bits - 1) {
            if (count == out.len) return count;

            out[count] = @intCast(word_index * @bitSizeOf(usize) + @ctz(bits));
            count += 1;
        }
    }

    return count;
}

/// Reorder cpu_list so each physical core appears once before any SMT
/// sibling repeats it. Order inside both groups is kept.
///
/// Param:
/// cpu_list - []u32 (allowed CPUs, reordered in place, at most MAX_CPUS)
/// keys - []const u64 (core key per cpu_list entry, same length)
///
/// Return:
/// - void
fn orderPhysicalCoresFirst(cpu_list: []u32, keys: []const u64) void {
    std.debug.assert(cpu_list.len == keys.len);
    std.debug.assert(cpu_list.len <= MAX_CPUS);

    var ordered: [MAX_CPUS]u32 = undefined;
    var ordered_len: usize = 0;

    for (keys, 0..) |key, index| {
        if (std.mem.indexOfScalar(u64, keys[0..index], key) == null) {
            ordered[ordered_len] = cpu_list[index];
            ordered_len += 1;
        }
    }

    for (keys, 0..) |key, index| {
        if (std.mem.indexOfScalar(u64, keys[0..index], key) != null) {
            ordered[ordered_len] = cpu_list[index];
            ordered_len += 1;
        }
    }

    @memcpy(cpu_list, ordered[0..cpu_list.len]);
}

fn machineCpuCount() usize {
    const count = std.Thread.getCpuCount() catch |err| switch (err) {
        else => 1,
    };

    return @max(1, count);
}

// --------------------------------------------------------- //
// Public:

/// CPUs this process may run on.
///
/// Return:
/// - usize (at least 1, the machine count when the mask cannot be read)
pub fn availableCpuCount() usize {
    if (comptime builtin.os.tag != .linux) return machineCpuCount();

    var mask: linux.cpu_set_t = undefined;
    const rc = linux.sched_getaffinity(0, @sizeOf(linux.cpu_set_t), &mask);
    if (linux.errno(rc) != .SUCCESS) return machineCpuCount();

    var count: usize = 0;
    for (mask) |word| count += @popCount(word);

    return @max(1, count);
}

/// Pin the calling thread to the pin slot of worker_id.
///
/// Note:
/// - Best effort: a failed read or set leaves the thread unpinned.
///
/// Param:
/// worker_id - usize (worker index, wraps around the allowed CPU count)
///
/// Return:
/// - void
pub fn pinToCpu(worker_id: usize) void {
    if (comptime builtin.os.tag != .linux) return;

    var mask: linux.cpu_set_t = undefined;
    const rc = linux.sched_getaffinity(0, @sizeOf(linux.cpu_set_t), &mask);
    if (linux.errno(rc) != .SUCCESS) return;

    var cpu_list: [MAX_CPUS]u32 = undefined;
    const cpu_count = maskCpus(&mask, &cpu_list);
    if (cpu_count == 0) return;

    var core_keys: [MAX_CPUS]u64 = undefined;
    var topology_known = true;
    for (cpu_list[0..cpu_count], 0..) |cpu, index| {
        core_keys[index] = coreKey(cpu) orelse {
            topology_known = false;
            break;
        };
    }
    if (topology_known) {
        orderPhysicalCoresFirst(cpu_list[0..cpu_count], core_keys[0..cpu_count]);
    }

    const target = cpu_list[worker_id % cpu_count];
    var target_mask: linux.cpu_set_t = std.mem.zeroes(linux.cpu_set_t);
    const bit: u6 = @intCast(target % @bitSizeOf(usize));
    target_mask[target / @bitSizeOf(usize)] |= @as(usize, 1) << bit;

    linux.sched_setaffinity(0, &target_mask) catch |err| switch (err) {
        // Best effort: an unpinned worker still serves.
        else => {},
    };
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "zix multiplexers: cpu_affinity, orderPhysicalCoresFirst puts distinct cores first" {
    var cpus = [_]u32{ 0, 1, 2, 3, 4, 5 };
    const keys = [_]u64{ 0, 0, 1, 1, 2, 2 };

    orderPhysicalCoresFirst(&cpus, &keys);

    try std.testing.expectEqualSlices(u32, &.{ 0, 2, 4, 1, 3, 5 }, &cpus);
}

test "zix multiplexers: cpu_affinity, orderPhysicalCoresFirst keeps order on unique keys" {
    var cpus = [_]u32{ 3, 7, 11 };
    const keys = [_]u64{ 30, 10, 20 };

    orderPhysicalCoresFirst(&cpus, &keys);

    try std.testing.expectEqualSlices(u32, &.{ 3, 7, 11 }, &cpus);
}

test "zix multiplexers: cpu_affinity, orderPhysicalCoresFirst empty list is a no-op" {
    var cpus = [_]u32{};
    const keys = [_]u64{};

    orderPhysicalCoresFirst(&cpus, &keys);

    try std.testing.expectEqual(@as(usize, 0), cpus.len);
}

test "zix multiplexers: cpu_affinity, maskCpus lists set bits lowest first" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;

    var mask: linux.cpu_set_t = std.mem.zeroes(linux.cpu_set_t);
    mask[0] = 0b1010_0001;

    var out: [8]u32 = undefined;
    const count = maskCpus(&mask, &out);

    try std.testing.expectEqualSlices(u32, &.{ 0, 5, 7 }, out[0..count]);
}

test "zix multiplexers: cpu_affinity, maskCpus stops at the out length" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;

    var mask: linux.cpu_set_t = std.mem.zeroes(linux.cpu_set_t);
    mask[0] = 0xff;

    var out: [3]u32 = undefined;

    try std.testing.expectEqual(@as(usize, 3), maskCpus(&mask, &out));
}

test "zix multiplexers: cpu_affinity, readTopologyValue missing cpu is null" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;

    try std.testing.expect(readTopologyValue(std.math.maxInt(u32), "core_id") == null);
}

test "zix multiplexers: cpu_affinity, availableCpuCount is at least 1" {
    try std.testing.expect(availableCpuCount() >= 1);
}

test "zix multiplexers: cpu_affinity, pinToCpu keeps the thread runnable" {
    const Probe = struct {
        fn run(ran: *bool) void {
            pinToCpu(0);
            ran.* = true;
        }
    };

    var ran = false;
    const thread = try std.Thread.spawn(.{}, Probe.run, .{&ran});
    thread.join();

    try std.testing.expect(ran);
}

