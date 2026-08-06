//! round_robin.zig: the upstream behind the zixer round-robin demo. Port: 9118 or 9119
//!
//! Run two instances on different ports. Each reply names the instance that
//! answered, so the rotation across the site's upstream list is visible, and
//! killing one instance shows the bounded retry landing on the survivor.
//!
//! Site file: examples/proxies/sites/round_robin.cfg (edge port 9117)
//!
//! Run:
//! zig build zixer-example-round_robin
//! ./zig-out/bin/zixer-example-round_robin-<arch>-<os> --port 9118 &
//! ./zig-out/bin/zixer-example-round_robin-<arch>-<os> --port 9119 &
//!
//! Through the proxy:
//! curl http://127.0.0.1:9117/ http://127.0.0.1:9117/ http://127.0.0.1:9117/

const std = @import("std");
const builtin = @import("builtin");
const zix = @import("zix");

const IP: []const u8 = "127.0.0.1";
/// Port when --port is absent. The site cfg lists 9118 and 9119.
const DEFAULT_PORT: u16 = 9118;
const DISPATCH_MODEL: zix.Http1.DispatchModel = .ASYNC;
const MAX_RECV_BUF: usize = 16 * 1024;

const REPORT_MAX: usize = 256;

/// The port this instance is serving, read once at startup so the handler can
/// name its own instance without touching argv per request.
var serving_port: u16 = DEFAULT_PORT;

// --------------------------------------------------------- //

/// Args iterator that also works on Windows: std's Iterator.init is
/// POSIX-only in Zig 0.16, Windows needs the allocating variant.
fn argsIterator(args: std.process.Args) std.process.Args.Iterator {
    if (comptime builtin.os.tag == .windows) {
        return std.process.Args.Iterator.initAllocator(args, std.heap.smp_allocator) catch {
            std.process.exit(2);
        };
    }

    return std.process.Args.Iterator.init(args);
}

/// Value of --port, or DEFAULT_PORT when it is absent or unusable.
fn portFromArgs(args: std.process.Args) u16 {
    var iter = argsIterator(args);
    _ = iter.next();

    while (iter.next()) |arg| {
        if (!std.mem.eql(u8, arg, "--port")) continue;

        const value = iter.next() orelse break;

        return std.fmt.parseInt(u16, value, 10) catch break;
    }

    return DEFAULT_PORT;
}

// GET / : name the instance that answered.
// curl usage: curl "http://127.0.0.1:9117/"
fn homeHandler(_: *zix.Http1.Request, res: *zix.Http1.Response, _: *zix.Http1.Context) !void {
    var report_buf: [REPORT_MAX]u8 = undefined;
    const report = std.fmt.bufPrint(&report_buf, "upstream: proxies/round_robin on {s}:{d}\n", .{ IP, serving_port }) catch "upstream: proxies/round_robin\n";

    res.setContentType(.TEXT_PLAIN);

    try res.send(report);
}

// --------------------------------------------------------- //

const Routes = zix.Http1.Router(&[_]zix.Http1.Route{
    .{ .path = "/", .handler = homeHandler },
});

pub fn main(process: std.process.Init) !void {
    serving_port = portFromArgs(process.minimal.args);

    var server = zix.Http1.Server.init(Routes.dispatch, .{
        .io = process.io,
        .ip = IP,
        .port = serving_port,
        .dispatch_model = DISPATCH_MODEL,
        .max_recv_buf = MAX_RECV_BUF,
    });
    defer server.deinit();

    std.log.info("proxies/round_robin listening on {s}:{d}", .{ IP, serving_port });

    try server.run();
}
