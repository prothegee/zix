const std = @import("std");
const builtin = @import("builtin");

pub fn main() !void {
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const address = std.Io.net.IpAddress.resolve(io, "127.0.0.1", 0) catch
        return error.ResolveFailed;

    var server = address.listen(io, .{
        .mode = .stream,
        .reuse_address = true,
        .kernel_backlog = 128,
    }) catch return error.ListenFailed;
    defer server.deinit(io);

    const kq = std.c.kqueue();
    if (kq < 0) return error.KqueueFailed;

    var changes = [2]std.c.Kevent{
        .{
            .ident = @intCast(server.socket.handle),
            .filter = std.c.EVFILT.READ,
            .flags = std.c.EV.ADD | std.c.EV.ENABLE,
            .fflags = 0,
            .data = 0,
            .udata = 0,
        },
        .{
            .ident = @intCast(server.socket.handle),
            .filter = std.c.EVFILT.WRITE,
            .flags = std.c.EV.ADD | std.c.EV.ENABLE,
            .fflags = 0,
            .data = 0,
            .udata = 0,
        },
    };
    var events: [8]std.c.Kevent = undefined;
    var timeout = std.posix.timespec{
        .sec = 0,
        .nsec = 10 * std.time.ns_per_ms,
    };
    const rc = std.c.kevent(kq, &changes, 2, &events, 8, &timeout);
    if (rc < 0) return error.KeventFailed;

    _ = std.c.close(kq);

    std.debug.print(
        "surface ok on {s}: {d} events\n",
        .{ @tagName(builtin.target.os.tag), rc },
    );
}

