// Parameterized QUERY runner for the HTTP and HTTP1 query examples (RFC 10008).
// The cases and the wire logic live in checks_query.zig, so all_runner and this
// standalone step check the same thing.
//
// Invoked by `zig build test-runner-<name>`.
// argv[1]: server binary path
// argv[2]: label
// argv[3]: port

const std = @import("std");
const common = @import("common.zig");
const checks_query = @import("checks_query.zig");

pub fn main(process: std.process.Init) void {
    var arg_iter = common.argsIterator(process.minimal.args);
    _ = arg_iter.skip();
    const server_path = arg_iter.next() orelse {
        std.debug.print("FAIL: missing server path\n", .{});
        std.process.exit(1);
    };
    const label = arg_iter.next() orelse {
        std.debug.print("FAIL: missing label\n", .{});
        std.process.exit(1);
    };
    const port_str = arg_iter.next() orelse {
        std.debug.print("FAIL {s}: missing port\n", .{label});
        std.process.exit(1);
    };

    const port = std.fmt.parseInt(u16, port_str, 10) catch {
        std.debug.print("FAIL {s}: invalid port\n", .{label});
        std.process.exit(1);
    };

    checks_query.runHttpQuery(process.io, server_path, port) catch |err| {
        std.debug.print("FAIL {s}: {}\n", .{ label, err });
        std.process.exit(1);
    };
    common.printPass(label);
}
