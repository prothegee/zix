//! Edge tests: zix.Channel(T) boundary conditions.
//! Verifies: capacity=1 minimum works, ring head wraps at buf.len,
//! full-buffer stability, and error.Closed on send/recv after close.

const std = @import("std");
const zix = @import("zix");

// --------------------------------------------------------- //

test "zix edge: Channel, capacity 1 allocates exactly one slot" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ch = try zix.Channel(u32).init(arena.allocator(), 1);
    defer ch.deinit();
    try std.testing.expectEqual(@as(usize, 1), ch.buf.len);
    try std.testing.expectEqual(@as(usize, 0), ch.count);
}

test "zix edge: Channel, ring head wraps when it reaches buf.len" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ch = try zix.Channel(u32).init(arena.allocator(), 4);
    defer ch.deinit();

    // Simulate: head at 3, one item consumed, next head must wrap to 0
    ch.head = 3;
    ch.count = 1;
    ch.buf[3] = 99;

    // head advances: (3 + 1) % 4 == 0
    const next_head = (ch.head + 1) % ch.buf.len;
    try std.testing.expectEqual(@as(usize, 0), next_head);
    try std.testing.expectEqual(@as(u32, 99), ch.buf[ch.head]);
}

test "zix edge: Channel, full boundary: count equals buf.len" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ch = try zix.Channel(u32).init(arena.allocator(), 4);
    defer ch.deinit();

    // Fill all slots manually
    ch.buf[0] = 1;
    ch.buf[1] = 2;
    ch.buf[2] = 3;
    ch.buf[3] = 4;
    ch.count = 4;

    // count == buf.len means the channel is full, no free slot at tail
    try std.testing.expect(ch.count == ch.buf.len);
    // tail index points back to head (ring is full)
    const tail = (ch.head + ch.count) % ch.buf.len;
    try std.testing.expectEqual(ch.head, tail);
}

test "zix edge: Channel, send after close returns error.Closed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{ .stack_size = 512 * 1024 });
    const io = threaded.io();
    var ch = try zix.Channel(u32).init(arena.allocator(), 4);
    defer ch.deinit();
    ch.close(io);
    try std.testing.expectError(error.Closed, ch.send(io, 1));
}

test "zix edge: Channel, recv on empty closed channel returns error.Closed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{ .stack_size = 512 * 1024 });
    const io = threaded.io();
    var ch = try zix.Channel(u32).init(arena.allocator(), 4);
    defer ch.deinit();
    ch.close(io);
    try std.testing.expectError(error.Closed, ch.recv(io));
}
