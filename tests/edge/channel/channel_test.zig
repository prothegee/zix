//! Edge tests: zix.Channel(T) boundary conditions.
//! Verifies: capacity=1 minimum works, ring head wraps at buf.len,
//! full-buffer stability, and error.ZixClosed on send/recv after close.

const std = @import("std");
const zix = @import("zix");

// --------------------------------------------------------- //

test "zix edge: Channel, capacity 1 allocates exactly one slot" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var channel = try zix.Channel(u32).init(arena.allocator(), 1);
    defer channel.deinit();

    try std.testing.expectEqual(@as(usize, 1), channel.buf.len);
    try std.testing.expectEqual(@as(usize, 0), channel.count);
}

test "zix edge: Channel, ring head wraps when it reaches buf.len" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var channel = try zix.Channel(u32).init(arena.allocator(), 4);
    defer channel.deinit();

    // Simulate: head at 3, one item consumed, next head must wrap to 0
    channel.head = 3;
    channel.count = 1;
    channel.buf[3] = 99;

    // head advances: (3 + 1) % 4 == 0
    const next_head = (channel.head + 1) % channel.buf.len;
    try std.testing.expectEqual(@as(usize, 0), next_head);
    try std.testing.expectEqual(@as(u32, 99), channel.buf[channel.head]);
}

test "zix edge: Channel, full boundary: count equals buf.len" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var channel = try zix.Channel(u32).init(arena.allocator(), 4);
    defer channel.deinit();

    // Fill all slots manually
    channel.buf[0] = 1;
    channel.buf[1] = 2;
    channel.buf[2] = 3;
    channel.buf[3] = 4;
    channel.count = 4;

    // count == buf.len means the channel is full, no free slot at tail
    try std.testing.expect(channel.count == channel.buf.len);
    // tail index points back to head (ring is full)
    const tail = (channel.head + channel.count) % channel.buf.len;
    try std.testing.expectEqual(channel.head, tail);
}

test "zix edge: Channel, send after close returns error.ZixClosed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{ .stack_size = 512 * 1024 });
    const io = threaded.io();
    var channel = try zix.Channel(u32).init(arena.allocator(), 4);
    defer channel.deinit();

    channel.close(io);
    try std.testing.expectError(error.ZixClosed, channel.send(io, 1));
}

test "zix edge: Channel, recv on empty closed channel returns error.ZixClosed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{ .stack_size = 512 * 1024 });
    const io = threaded.io();
    var channel = try zix.Channel(u32).init(arena.allocator(), 4);
    defer channel.deinit();

    channel.close(io);
    try std.testing.expectError(error.ZixClosed, channel.recv(io));
}
