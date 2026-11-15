//! ZIX channel
//!
//! ### file: src/zix/channel/Channel.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Buffered, blocking, in-process channel for passing typed values between tasks
//! and threads.
//!
//! ### note:
//!
//! The element type is fixed at init and checked at runtime on every send and recv.
//! Each OS thread passes its own `std.Io`.
//! Capacity 0 (unbuffered) is not supported, init asserts on it.
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

// --------------------------------------------------------- //
// Fields:

/// Ring buffer storage, `capacity * elem_size` bytes.
buf: []u8,
/// Number of slots in the ring.
capacity: usize,
/// Byte size of one element.
elem_size: usize,
/// `@typeName` of the element type given to init.
type_name: []const u8,
/// Slot index of the oldest element.
head: usize = 0,
/// Number of elements in the ring.
count: usize = 0,
closed: bool = false,
mutex: std.Io.Mutex = .init,
not_empty: std.Io.Condition = .init,
not_full: std.Io.Condition = .init,
allocator: std.mem.Allocator,

const Self = @This();

// --------------------------------------------------------- //
// Private:

/// Check that T is the element type given to init.
///
/// Param:
/// T - type (the element type used by the caller)
///
/// Return:
/// - void
/// - Error.ZixChannel_Channel_TypeMismatch when T is not the init type
fn checkType(self: *const Self, comptime T: type) Error!void {
    const same =
        @sizeOf(T) == self.elem_size and
        std.mem.eql(u8, @typeName(T), self.type_name);
    if (!same) return Error.ZixChannel_Channel_TypeMismatch;
}

/// The bytes of one ring slot.
///
/// Param:
/// index - usize (slot index, less than capacity)
///
/// Return:
/// - []u8 (elem_size bytes inside buf)
fn slotBytes(self: *Self, index: usize) []u8 {
    const offset = index * self.elem_size;

    return self.buf[offset..][0..self.elem_size];
}

// --------------------------------------------------------- //
// Public:

/// ZIX channel error
pub const Error = error {
    ZixChannel_Channel_Closed,
    ZixChannel_Channel_OutOfMemory,
    ZixChannel_Channel_TypeMismatch,
};

/// Allocate a ring buffer with `capacity` slots of type T.
///
/// Param:
/// allocator - std.mem.Allocator (owns the ring buffer until deinit)
/// T - type (the element type passed through the channel)
/// capacity - usize (number of slots, must be greater than 0)
///
/// Usage:
/// ```zig
/// var channel: zix.Channel = try .init(allocator, u32, 8);
/// defer channel.deinit();
///
/// try channel.send(io, u32, 42);
/// const value = try channel.recv(io, u32); // value == 42
/// channel.close(io); // recv now drains, then returns Closed
/// ```
///
/// Return:
/// - Self (an empty, open channel)
/// - Error.ZixChannel_Channel_OutOfMemory when the buffer cannot be allocated
pub fn init(allocator: std.mem.Allocator, comptime T: type, capacity: usize) Error!Self {
    std.debug.assert(capacity > 0);

    const buf = allocator.alloc(u8, capacity * @sizeOf(T)) catch |err| switch (err) {
        error.OutOfMemory => return Error.ZixChannel_Channel_OutOfMemory,
    };

    return .{
        .buf = buf,
        .capacity = capacity,
        .elem_size = @sizeOf(T),
        .type_name = @typeName(T),
        .allocator = allocator,
    };
}

/// Free the ring buffer. Call after every sender and receiver has exited.
pub fn deinit(self: *Self) void {
    self.allocator.free(self.buf);
}

/// Put one value into the channel. Waits while the buffer is full.
///
/// Param:
/// io - std.Io (the io of the calling thread)
/// T - type (must be the type given to init)
/// value - T (the value to send)
///
/// Return:
/// - void
/// - Error.ZixChannel_Channel_TypeMismatch when T is not the init type
/// - Error.ZixChannel_Channel_Closed when close ran before or during the wait
pub fn send(self: *Self, io: std.Io, comptime T: type, value: T) Error!void {
    try self.checkType(T);

    self.mutex.lockUncancelable(io);
    while (self.count == self.capacity and !self.closed) {
        self.not_full.waitUncancelable(io, &self.mutex);
    }

    if (self.closed) {
        self.mutex.unlock(io);
        return Error.ZixChannel_Channel_Closed;
    }

    const tail = (self.head + self.count) % self.capacity;
    @memcpy(self.slotBytes(tail), std.mem.asBytes(&value));
    self.count += 1;
    self.mutex.unlock(io);

    self.not_empty.signal(io);
}

/// Take one value from the channel. Waits while the buffer is empty.
///
/// Param:
/// io - std.Io (the io of the calling thread)
/// T - type (must be the type given to init)
///
/// Return:
/// - T (the oldest value in the buffer)
/// - Error.ZixChannel_Channel_TypeMismatch when T is not the init type
/// - Error.ZixChannel_Channel_Closed when the channel is closed and empty
pub fn recv(self: *Self, io: std.Io, comptime T: type) Error!T {
    try self.checkType(T);

    self.mutex.lockUncancelable(io);
    while (self.count == 0) {
        if (self.closed) {
            self.mutex.unlock(io);
            return Error.ZixChannel_Channel_Closed;
        }

        self.not_empty.waitUncancelable(io, &self.mutex);
    }

    var value: T = undefined;
    @memcpy(std.mem.asBytes(&value), self.slotBytes(self.head));
    self.head = (self.head + 1) % self.capacity;
    self.count -= 1;
    self.mutex.unlock(io);

    self.not_full.signal(io);

    return value;
}

/// Stop new sends and wake every waiting sender and receiver.
/// Items already in the buffer stay readable until drained.
///
/// Param:
/// io - std.Io (the io of the calling thread)
pub fn close(self: *Self, io: std.Io) void {
    self.mutex.lockUncancelable(io);
    self.closed = true;
    self.mutex.unlock(io);

    self.not_empty.broadcast(io);
    self.not_full.broadcast(io);
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const TEST_ITEM_COUNT: usize = 100;

const TestPoint = struct {
    x_pos: i32,
    y_pos: i32,
};

const TestThreadResult = struct {
    received: [TEST_ITEM_COUNT]u32 = undefined,
    received_len: usize = 0,
    send_failed: bool = false,
};

fn testSendU32(channel: *Self, io: std.Io, value: u32) Error!void {
    return channel.send(io, u32, value);
}

fn testRecvU32(channel: *Self, io: std.Io) Error!u32 {
    return channel.recv(io, u32);
}

fn testProducer(channel: *Self, result: *TestThreadResult) void {
    var threaded = std.Io.Threaded.init(std.mem.Allocator.failing, .{});
    defer threaded.deinit();
    const io = threaded.io();

    for (0..TEST_ITEM_COUNT) |i| {
        channel.send(io, u32, @intCast(i)) catch |err| switch (err) {
            error.ZixChannel_Channel_Closed,
            error.ZixChannel_Channel_OutOfMemory,
            error.ZixChannel_Channel_TypeMismatch,
            => {
                result.send_failed = true;
                break;
            },
        };
    }

    channel.close(io);
}

fn testConsumer(channel: *Self, result: *TestThreadResult) void {
    var threaded = std.Io.Threaded.init(std.mem.Allocator.failing, .{});
    defer threaded.deinit();
    const io = threaded.io();

    while (result.received_len < TEST_ITEM_COUNT) {
        const value = channel.recv(io, u32) catch |err| switch (err) {
            error.ZixChannel_Channel_Closed,
            error.ZixChannel_Channel_OutOfMemory,
            error.ZixChannel_Channel_TypeMismatch,
            => return,
        };

        result.received[result.received_len] = value;
        result.received_len += 1;
    }
}

test "zix channel: Channel, init fills defaults" {
    var channel: Self = try .init(std.testing.allocator, u32, 4);
    defer channel.deinit();

    try std.testing.expectEqual(@as(usize, 4), channel.capacity);
    try std.testing.expectEqual(@as(usize, 16), channel.buf.len);
    try std.testing.expectEqual(@as(usize, 0), channel.count);
    try std.testing.expectEqual(@as(usize, 0), channel.head);
    try std.testing.expect(!channel.closed);
}

test "zix channel: Channel, ring tail is head plus count modulo capacity" {
    const io = std.testing.io;

    var channel: Self = try .init(std.testing.allocator, u32, 4);
    defer channel.deinit();

    try channel.send(io, u32, 10);
    try channel.send(io, u32, 20);
    try channel.send(io, u32, 30);
    _ = try channel.recv(io, u32);
    try channel.send(io, u32, 40);
    try channel.send(io, u32, 50);

    try std.testing.expectEqual(@as(usize, 1), channel.head);
    try std.testing.expectEqual(@as(usize, 4), channel.count);
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&@as(u32, 50)), channel.slotBytes(0));
}

test "zix channel: Channel, capacity 1 sends and receives" {
    const io = std.testing.io;

    var channel: Self = try .init(std.testing.allocator, u32, 1);
    defer channel.deinit();

    try channel.send(io, u32, 7);
    try std.testing.expectEqual(@as(u32, 7), try channel.recv(io, u32));
    try channel.send(io, u32, 8);
    try std.testing.expectEqual(@as(u32, 8), try channel.recv(io, u32));
    try std.testing.expectEqual(@as(usize, 0), channel.count);
}

test "zix channel: Channel, ring wraps across capacity in FIFO order" {
    const io = std.testing.io;

    var channel: Self = try .init(std.testing.allocator, u32, 2);
    defer channel.deinit();

    for (0..5) |i| {
        try channel.send(io, u32, @intCast(i));
        try std.testing.expectEqual(@as(u32, @intCast(i)), try channel.recv(io, u32));
    }

    try channel.send(io, u32, 100);
    try channel.send(io, u32, 101);

    try std.testing.expectEqual(@as(u32, 100), try channel.recv(io, u32));
    try std.testing.expectEqual(@as(u32, 101), try channel.recv(io, u32));
}

test "zix channel: Channel, slice element type round-trips" {
    const io = std.testing.io;

    var channel: Self = try .init(std.testing.allocator, []const u8, 2);
    defer channel.deinit();

    try channel.send(io, []const u8, "hello");

    try std.testing.expectEqualStrings("hello", try channel.recv(io, []const u8));
}

test "zix channel: Channel, struct element type round-trips" {
    const io = std.testing.io;

    var channel: Self = try .init(std.testing.allocator, TestPoint, 2);
    defer channel.deinit();

    try channel.send(io, TestPoint, .{
        .x_pos = 3,
        .y_pos = -4,
    });

    const point = try channel.recv(io, TestPoint);
    try std.testing.expectEqual(@as(i32, 3), point.x_pos);
    try std.testing.expectEqual(@as(i32, -4), point.y_pos);
}

test "zix channel: Channel, zero-size element type round-trips" {
    const io = std.testing.io;

    var channel: Self = try .init(std.testing.allocator, void, 2);
    defer channel.deinit();

    try channel.send(io, void, {});
    try channel.recv(io, void);

    try std.testing.expectEqual(@as(usize, 0), channel.count);
}

test "zix channel: Channel, send with another type returns TypeMismatch" {
    const io = std.testing.io;

    var channel: Self = try .init(std.testing.allocator, u32, 2);
    defer channel.deinit();

    try std.testing.expectError(
        Error.ZixChannel_Channel_TypeMismatch,
        channel.send(io, i32, 1),
    );
    try std.testing.expectEqual(@as(usize, 0), channel.count);
}

test "zix channel: Channel, recv with another type returns TypeMismatch" {
    const io = std.testing.io;

    var channel: Self = try .init(std.testing.allocator, u32, 2);
    defer channel.deinit();

    try channel.send(io, u32, 1);

    try std.testing.expectError(
        Error.ZixChannel_Channel_TypeMismatch,
        channel.recv(io, f32),
    );
    try std.testing.expectEqual(@as(usize, 1), channel.count);
}

test "zix channel: Channel, send after close returns Closed" {
    const io = std.testing.io;

    var channel: Self = try .init(std.testing.allocator, u32, 2);
    defer channel.deinit();

    channel.close(io);

    try std.testing.expectError(Error.ZixChannel_Channel_Closed, channel.send(io, u32, 1));
}

test "zix channel: Channel, recv on empty closed channel returns Closed" {
    const io = std.testing.io;

    var channel: Self = try .init(std.testing.allocator, u32, 2);
    defer channel.deinit();

    channel.close(io);

    try std.testing.expectError(Error.ZixChannel_Channel_Closed, channel.recv(io, u32));
}

test "zix channel: Channel, close drains remaining items then returns Closed" {
    const io = std.testing.io;

    var channel: Self = try .init(std.testing.allocator, u32, 4);
    defer channel.deinit();

    try channel.send(io, u32, 1);
    try channel.send(io, u32, 2);
    channel.close(io);

    try std.testing.expectEqual(@as(u32, 1), try channel.recv(io, u32));
    try std.testing.expectEqual(@as(u32, 2), try channel.recv(io, u32));
    try std.testing.expectError(Error.ZixChannel_Channel_Closed, channel.recv(io, u32));
}

test "zix channel: Channel, full send resumes after one recv" {
    const io = std.testing.io;

    var channel: Self = try .init(std.testing.allocator, u32, 1);
    defer channel.deinit();

    try channel.send(io, u32, 1);
    var future = io.concurrent(testSendU32, .{
        &channel,
        io,
        2,
    }) catch |err| switch (err) {
        error.ConcurrencyUnavailable => return error.SkipZigTest,
    };

    try std.testing.expectEqual(@as(u32, 1), try channel.recv(io, u32));
    try std.testing.expectEqual(@as(u32, 2), try channel.recv(io, u32));
    try future.await(io);
}

test "zix channel: Channel, empty recv resumes after one send" {
    const io = std.testing.io;

    var channel: Self = try .init(std.testing.allocator, u32, 1);
    defer channel.deinit();

    var future = io.concurrent(testRecvU32, .{
        &channel,
        io,
    }) catch |err| switch (err) {
        error.ConcurrencyUnavailable => return error.SkipZigTest,
    };

    try channel.send(io, u32, 9);

    try std.testing.expectEqual(@as(u32, 9), try future.await(io));
}

test "zix channel: Channel, close unblocks a waiting recv" {
    const io = std.testing.io;

    var channel: Self = try .init(std.testing.allocator, u32, 1);
    defer channel.deinit();

    var future = io.concurrent(testRecvU32, .{
        &channel,
        io,
    }) catch |err| switch (err) {
        error.ConcurrencyUnavailable => return error.SkipZigTest,
    };

    channel.close(io);

    try std.testing.expectError(Error.ZixChannel_Channel_Closed, future.await(io));
}

test "zix channel: Channel, two OS threads pass 100 items with per-thread io" {
    var channel: Self = try .init(std.testing.allocator, u32, 8);
    defer channel.deinit();
    var producer_result: TestThreadResult = .{};
    var consumer_result: TestThreadResult = .{};

    const producer = try std.Thread.spawn(.{}, testProducer, .{
        &channel,
        &producer_result,
    });
    const consumer = try std.Thread.spawn(.{}, testConsumer, .{
        &channel,
        &consumer_result,
    });
    producer.join();
    consumer.join();

    try std.testing.expect(!producer_result.send_failed);
    try std.testing.expectEqual(TEST_ITEM_COUNT, consumer_result.received_len);
    for (consumer_result.received, 0..) |value, i| {
        try std.testing.expectEqual(@as(u32, @intCast(i)), value);
    }
}

