const std = @import("std");
const builtin = @import("builtin");

fn setNoDelay(fd: std.posix.fd_t) void {
    std.posix.setsockopt(
        fd,
        std.posix.IPPROTO.TCP,
        std.posix.TCP.NODELAY,
        std.mem.asBytes(&@as(c_int, 1)),
    ) catch |err| switch (err) {
        else => {},
    };
}

fn setNonBlock(fd: std.posix.fd_t) bool {
    const rc = std.c.fcntl(fd, std.posix.F.GETFL, @as(c_int, 0));
    if (std.posix.errno(rc) != .SUCCESS) return false;

    const flags: std.posix.O = @bitCast(@as(u32, @intCast(rc)));
    var nonblock = flags;
    nonblock.NONBLOCK = true;
    const bits: u32 = @bitCast(nonblock);
    const set_rc = std.c.fcntl(fd, std.posix.F.SETFL, @as(c_int, @intCast(bits)));

    return std.posix.errno(set_rc) == .SUCCESS;
}

pub fn main() !void {
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const address = std.Io.net.IpAddress.resolve(io, "127.0.0.1", 0) catch
        return error.ResolveFailed;

    var server = address.listen(io, .{
        .mode = .stream,
        .reuse_address = true,
        .kernel_backlog = 8,
    }) catch return error.ListenFailed;
    defer server.deinit(io);

    const listener_fd: std.posix.fd_t = server.socket.handle;
    if (!setNonBlock(listener_fd)) return error.NonBlockFailed;

    const accepted = std.c.accept(listener_fd, null, null);
    switch (std.posix.errno(accepted)) {
        .SUCCESS => {},
        .AGAIN => {},
        else => {},
    }

    _ = std.c.shutdown(listener_fd, 1);
    setNoDelay(listener_fd);

    std.debug.print(
        "posix surface ok on {s}\n",
        .{@tagName(builtin.target.os.tag)},
    );
}

