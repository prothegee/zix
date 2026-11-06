const std = @import("std");
const builtin = @import("builtin");

pub fn main() !void {
    const kq = std.c.kqueue();
    if (kq < 0) return error.KqueueFailed;

    var changes = [1]std.c.Kevent{.{
        .ident = 0,
        .filter = std.c.EVFILT.READ,
        .flags = std.c.EV.ADD | std.c.EV.ENABLE,
        .fflags = 0,
        .data = 0,
        .udata = 0,
    }};
    var events: [1]std.c.Kevent = undefined;
    const rc = std.c.kevent(kq, &changes, 1, &events, 1, null);
    if (rc < 0) return error.KeventFailed;
    _ = std.c.close(kq);
    std.debug.print(
        "kqueue probe ok on {s} (link_libc={})\n",
        .{ @tagName(builtin.target.os.tag), builtin.link_libc },
    );
}
