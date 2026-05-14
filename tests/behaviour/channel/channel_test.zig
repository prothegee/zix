//! Behaviour tests: zix.Channel(T) field defaults, ring arithmetic contracts,
//! and observable state changes produced by send/recv/close.

const std = @import("std");
const zix = @import("zix");

// --------------------------------------------------------- //

test "zix behaviour: Channel, closed field defaults to false after init" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ch = try zix.Channel(u32).init(arena.allocator(), 4);
    defer ch.deinit();
    try std.testing.expect(!ch.closed);
}

test "zix behaviour: Channel, head starts at zero" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ch = try zix.Channel(u32).init(arena.allocator(), 4);
    defer ch.deinit();
    try std.testing.expectEqual(@as(usize, 0), ch.head);
}

test "zix behaviour: Channel, ring tail formula is (head + count) % buf.len" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ch = try zix.Channel(u32).init(arena.allocator(), 4);
    defer ch.deinit();

    // Manually set state to simulate 3 items in a 4-slot ring
    ch.buf[0] = 10;
    ch.buf[1] = 20;
    ch.buf[2] = 30;
    ch.count = 3;

    const tail = (ch.head + ch.count) % ch.buf.len;
    try std.testing.expectEqual(@as(usize, 3), tail);
    try std.testing.expectEqual(@as(u32, 10), ch.buf[ch.head]);
}

test "zix behaviour: Channel, send increments count" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{ .stack_size = 512 * 1024 });
    const io = threaded.io();
    var ch = try zix.Channel(u32).init(arena.allocator(), 4);
    defer ch.deinit();
    try ch.send(io, 99);
    try std.testing.expectEqual(@as(usize, 1), ch.count);
}

test "zix behaviour: Channel, recv decrements count" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{ .stack_size = 512 * 1024 });
    const io = threaded.io();
    var ch = try zix.Channel(u32).init(arena.allocator(), 4);
    defer ch.deinit();
    try ch.send(io, 7);
    _ = try ch.recv(io);
    try std.testing.expectEqual(@as(usize, 0), ch.count);
}

test "zix behaviour: Channel, close sets closed field to true" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{ .stack_size = 512 * 1024 });
    const io = threaded.io();
    var ch = try zix.Channel(u32).init(arena.allocator(), 4);
    defer ch.deinit();
    try std.testing.expect(!ch.closed);
    ch.close(io);
    try std.testing.expect(ch.closed);
}
