//! Slab memory pattern (the zix EPOLL ConnTable) built on an ArenaAllocator.
//!
//! It shows that a big contiguous array is demand-paged: reserved address space
//! is free, only touched pages cost real RAM, and a single @memset of the whole
//! array forces all of it resident. The arena only changes how you free (all at
//! once), not the demand-paging or the memset cost. Compare with the smp variant.
//!
//! Run in a release mode: zig run -OReleaseFast rnd/slab_contiguous_arena.zig
//! In Debug, Zig scribbles 0xaa over every allocation to catch undefined use,
//! which touches all pages and hides the demand-paging this demo is about.

const std = @import("std");

/// Per-connection state, stored inline in the slots array (mirrors zix Conn).
const Conn = struct {
    fd: i32 = -1,
    buf: []u8 = &.{},
    filled: usize = 0,
    drain: usize = 0,
    write_pending: []u8 = &.{},
    closing: bool = false,
};

const MAX_FD: usize = 1 << 16;
const BUF_SIZE: usize = 16 * 1024;

/// Current resident memory (real RAM in use) for this process. /proc/self/statm
/// reports counts in pages and its second field is the resident page count, so
/// multiply by the page size for bytes. Raw linux syscalls are used because the
/// std file API needs an Io instance in 0.16.
fn residentBytes() usize {
    const linux = std.os.linux;
    const fd: i32 = @intCast(linux.open("/proc/self/statm", .{ .ACCMODE = .RDONLY }, 0));
    if (fd < 0) return 0;
    defer _ = linux.close(fd);

    var buf: [128]u8 = undefined;
    const n = linux.read(fd, &buf, buf.len);
    if (n == 0 or n > buf.len) return 0;

    var it = std.mem.tokenizeScalar(u8, buf[0..n], ' ');
    _ = it.next();
    const resident = it.next() orelse return 0;
    const pages = std.fmt.parseInt(usize, resident, 10) catch return 0;

    return pages * std.heap.page_size_min;
}

fn mib(bytes: usize) f64 {
    return @as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0);
}

pub fn main() !void {
    const p = std.debug.print;

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit(); // one call frees slots and slab together
    const a = arena.allocator();

    p("rss at start:                  {d:.1} MiB\n", .{mib(residentBytes())});

    // Each alloc is one contiguous run of address space (one mmap), so slab[i]
    // and slab[i+1] are neighbours in memory.
    const slots = try a.alloc(Conn, MAX_FD);
    const slab = try a.alloc(u8, MAX_FD * BUF_SIZE);

    p("slots virtual:                 {d:.1} MiB ({d} x {d} B)\n", .{ mib(slots.len * @sizeOf(Conn)), MAX_FD, @sizeOf(Conn) });
    p("slab virtual:                  {d:.1} MiB\n", .{mib(slab.len)});
    p("contiguous: slab spans {d} bytes between first and last byte\n", .{slab.len - 1});

    // Reserving the ~1 GiB above did not cost real RAM: the kernel only commits
    // a page the first time it is written. Untouched pages stay virtual.
    p("rss after alloc (untouched):   {d:.1} MiB\n", .{mib(residentBytes())});

    // Touch one byte in the first 1000 slab slices, like 1000 connections each
    // writing into their own slot. Only those pages become resident.
    for (0..1000) |fd| slab[fd * BUF_SIZE] = 1;
    p("rss after touching 1000:       {d:.1} MiB\n", .{mib(residentBytes())});

    // The trap that the zix ConnTable hits: memset touches every page of the
    // slots array, so all of it becomes resident even for fds never used.
    @memset(std.mem.sliceAsBytes(slots), 0);
    p("rss after memset(slots):       {d:.1} MiB  (whole slots array now resident)\n", .{mib(residentBytes())});
}
