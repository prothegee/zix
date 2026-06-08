//! zix http1 comptime router — exact-path matching, zero runtime overhead.

const std = @import("std");
const core = @import("core.zig");

pub const Route = struct {
    path: []const u8,
    handler: core.HandlerFn,
};

/// Returns a zero-size type with a single `dispatch` function that does comptime
/// exact-path matching across all routes. Unknown paths get 404 text/plain.
///
/// Usage:
/// ```zig
/// const R = zix.Http1.Router(&[_]zix.Http1.Route{
///     .{ .path = "/", .handler = homeHandler },
/// });
/// try server.run(R.dispatch);
/// ```
pub fn Router(comptime routes: []const Route) type {
    return struct {
        pub fn dispatch(
            head: *const core.ParsedHead,
            body: []const u8,
            fd: std.posix.fd_t,
        ) void {
            inline for (routes) |route| {
                if (std.mem.eql(u8, head.path, route.path)) {
                    route.handler(head, body, fd);
                    return;
                }
            }

            core.writeSimple(fd, 404, "text/plain", "Not Found") catch {};
        }
    };
}
