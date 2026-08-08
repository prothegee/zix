//! Portable socket read-side cut: wake a parked read from outside its dispatch loop.
//!
//! What:
//!   One helper, one concern. A shutdown of the read side wakes a blocking read, an epoll wait, or an
//!   io_uring recv the same way, because none of them special-case a peer half-close. The caller acts
//!   on the descriptor from outside, the loop parked on it is never told anything.
//!
//! Note:
//! - SHUT_RD only, never SHUT_RDWR. A full shutdown wakes the same read but also takes the send side
//!   away, which is the difference between a caller that can still write its own reply on the way out
//!   and one that cannot.
//! - Windows has no shutdown() over the raw AFD endpoints std opens for a socket, the equivalent is
//!   windows_io's partial-disconnect ioctl with only the receive direction set.

const std = @import("std");
const builtin = @import("builtin");
const win_io = @import("windows_io.zig");

const is_windows = builtin.os.tag == .windows;
const is_linux = builtin.os.tag == .linux;

// --------------------------------------------------------- //

/// Shut down the read side of a connected socket, so a thread parked reading it wakes with
/// end-of-stream while the socket's send side stays usable.
///
/// Note:
/// - Best effort: a socket already closed or never connected fails silently, matching every other
///   shutdown/close helper in the tree.
///
/// Param:
/// handle - std.posix.socket_t (the socket, from stream.socket.handle)
///
/// Return:
/// - void
pub fn shutdownRead(handle: std.posix.socket_t) void {
    if (comptime is_windows) {
        win_io.shutdownRead(handle);
        return;
    }

    if (comptime is_linux) {
        _ = std.os.linux.shutdown(handle, std.os.linux.SHUT.RD);
        return;
    }

    _ = std.posix.system.shutdown(handle, std.posix.SHUT.RD);
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //

test "zix utils: socket_cut shutdownRead wakes a parked read and leaves the write side open" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const addr = try std.Io.net.IpAddress.parse("127.0.0.1", 18985);
    var server = try addr.listen(io, .{ .kernel_backlog = 4, .reuse_address = true });
    defer server.deinit(io);

    const client = try addr.connect(io, .{ .mode = .stream, .protocol = .tcp });
    defer client.close(io);
    const accepted = try server.accept(io);
    defer accepted.close(io);

    const Parked = struct {
        var woke_at_eof: bool = false;

        // The client never sends anything, so this read has nowhere to wake from except the cut.
        fn run(stream: std.Io.net.Stream, parked_io: std.Io) void {
            var buf: [1]u8 = undefined;
            var reader = stream.reader(parked_io, &buf);
            reader.interface.readSliceAll(&buf) catch |err| {
                woke_at_eof = (err == error.EndOfStream);
                return;
            };
        }
    };

    const parked = try std.Thread.spawn(.{}, Parked.run, .{ accepted, io });

    // Give the thread time to actually park in its read before the cut lands.
    std.Io.sleep(io, std.Io.Duration.fromMilliseconds(50), .awake) catch {};
    shutdownRead(accepted.socket.handle);
    parked.join();

    try std.testing.expect(Parked.woke_at_eof);

    // The write side of the cut socket must still carry a reply.
    var write_buf: [16]u8 = undefined;
    var writer = accepted.writer(io, &write_buf);
    try writer.interface.writeAll("still-writable");
    try writer.interface.flush();

    var read_buf: [32]u8 = undefined;
    var client_reader = client.reader(io, &read_buf);
    var got: [14]u8 = undefined;
    try client_reader.interface.readSliceAll(&got);
    try std.testing.expectEqualStrings("still-writable", &got);
}

test "zix utils: socket_cut shutdownRead on an already-cut socket is a no-op" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const addr = try std.Io.net.IpAddress.parse("127.0.0.1", 18986);
    var server = try addr.listen(io, .{ .kernel_backlog = 4, .reuse_address = true });
    defer server.deinit(io);

    const client = try addr.connect(io, .{ .mode = .stream, .protocol = .tcp });
    defer client.close(io);
    const accepted = try server.accept(io);
    defer accepted.close(io);

    shutdownRead(accepted.socket.handle);
    shutdownRead(accepted.socket.handle);

    var read_buf: [1]u8 = undefined;
    var reader = accepted.reader(io, &read_buf);
    try std.testing.expectError(error.EndOfStream, reader.interface.readSliceAll(&read_buf));
}
