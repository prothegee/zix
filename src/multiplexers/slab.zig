//! Shared demand-paging primitives for the per-worker EPOLL/URING connection
//! tables. Per ADR-042 the per-engine tables stay per-engine, only these
//! byte-identical primitives are shared.
//!
//! Two ideas, both about letting Linux demand-paging do the work:
//! - A connection slots array is mmap'd (kernel-zeroed, demand-paged) instead of
//!   allocated and memset, so an untouched slot costs no physical memory. The std
//!   allocators scribble 0xAA over fresh memory in safe builds, so they cannot be
//!   used where a slot is read before it is written.
//! - A closed connection's slab pages are handed back to the OS, so resident
//!   memory tracks live connections, not the lifetime high-water of fd indices.

const std = @import("std");

/// mmap a zero-filled, demand-paged slots array of `count` elements of T. Works
/// for an inline-struct slot (zero == empty) or a pointer slot (zero == null).
///
/// Param:
/// T - type (the slot element type)
/// count - usize (how many slots)
///
/// Return:
/// - []T (page-aligned, all zero, demand-paged)
pub fn mapZeroedSlots(comptime T: type, count: usize) ![]T {
    const mapped = try std.posix.mmap(
        null,
        count * @sizeOf(T),
        .{ .READ = true, .WRITE = true },
        .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
        -1,
        0,
    );

    return std.mem.bytesAsSlice(T, mapped);
}

/// Unmap a slots array obtained from mapZeroedSlots.
pub fn unmapSlots(slots: anytype) void {
    std.posix.munmap(@alignCast(std.mem.sliceAsBytes(slots)));
}

/// Return the slab pages backing a closed connection to the OS, so resident
/// memory tracks live connections instead of the lifetime high-water of fd
/// indices touched. The slab is anonymous demand-paged memory, so the next first
/// touch on a reused fd faults a fresh zero page.
///
/// Note:
/// - MADV_DONTNEED needs a page-aligned range, so only the pages fully covered
///   by the slice are advised. With a page-aligned slab base and a page-multiple
///   buf_size that is the whole slice.
/// - Best-effort: a failed advise is ignored, the slot is reusable either way.
///
/// Param:
/// buf - []u8 (the connection slab slice handed out by the table alloc)
///
/// Return:
/// - void
pub fn releaseSlabPages(buf: []u8) void {
    const page = std.heap.page_size_min;
    const base = @intFromPtr(buf.ptr);
    const start = std.mem.alignForward(usize, base, page);
    const end = std.mem.alignBackward(usize, base + buf.len, page);
    if (end <= start) return;

    const ptr: [*]align(std.heap.page_size_min) u8 = @ptrFromInt(start);
    std.posix.madvise(ptr, end - start, std.posix.MADV.DONTNEED) catch {};
}

test "slab: mapZeroedSlots returns zeroed, releaseSlabPages re-zeros" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;

    // Pointer slots come back all null (zero bits).
    const ptr_slots = try mapZeroedSlots(?*u8, 4096);
    defer unmapSlots(ptr_slots);
    for (ptr_slots) |p| try std.testing.expectEqual(@as(?*u8, null), p);

    // releaseSlabPages hands an anonymous page back, so the next read is zero.
    const page = std.heap.page_size_min;
    const mem = try std.heap.page_allocator.alloc(u8, page * 2);
    defer std.heap.page_allocator.free(mem);

    @memset(mem, 0xAA);
    releaseSlabPages(mem);

    try std.testing.expectEqual(@as(u8, 0), mem[0]);
    try std.testing.expectEqual(@as(u8, 0), mem[page]);
}
