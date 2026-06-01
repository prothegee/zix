//! Integration tests: Channel(T) init, send/recv round-trip, and drain-after-close.
//! Verifies allocation, capacity, generic element types, and blocking-path contracts
//! exercised with a real std.Io.Threaded instance.

const std = @import("std");
const zix = @import("zix");

test "zix integration: Channel(u32), init allocates requested capacity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ch = try zix.Channel(u32).init(arena.allocator(), 8);
    defer ch.deinit();

    try std.testing.expectEqual(@as(usize, 8), ch.buf.len);
    try std.testing.expectEqual(@as(usize, 0), ch.count);
    try std.testing.expectEqual(@as(usize, 0), ch.head);
}

test "zix integration: Channel([]const u8), slice element type compiles" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ch = try zix.Channel([]const u8).init(arena.allocator(), 4);
    defer ch.deinit();

    try std.testing.expectEqual(@as(usize, 4), ch.buf.len);
}

test "zix integration: Channel(struct), struct element type compiles" {
    const Msg = struct { id: u32, value: f32 };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ch = try zix.Channel(Msg).init(arena.allocator(), 2);
    defer ch.deinit();

    try std.testing.expectEqual(@as(usize, 2), ch.buf.len);
}

test "zix integration: Channel(u32), send and recv round-trip" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{ .stack_size = 512 * 1024 });
    const io = threaded.io();
    var ch = try zix.Channel(u32).init(arena.allocator(), 4);
    defer ch.deinit();

    try ch.send(io, 42);
    const v = try ch.recv(io);
    try std.testing.expectEqual(@as(u32, 42), v);
}

test "zix integration: Channel(u32), drain remaining items after close" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{ .stack_size = 512 * 1024 });
    const io = threaded.io();
    var ch = try zix.Channel(u32).init(arena.allocator(), 4);
    defer ch.deinit();

    try ch.send(io, 10);
    try ch.send(io, 20);
    ch.close(io);
    try std.testing.expectEqual(@as(u32, 10), try ch.recv(io));
    try std.testing.expectEqual(@as(u32, 20), try ch.recv(io));
    try std.testing.expectError(error.Closed, ch.recv(io));
}
