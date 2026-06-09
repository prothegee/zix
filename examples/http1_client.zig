const std = @import("std");
const zix = @import("zix");

// Runs against any of the http1 basic servers on port 9100
// (e.g. example-http1_basic_2_pool with routes / /echo /about).
//
// Usage:
// 1. start a server:  ./zig-out/bin/example-http1_basic_2_pool
// 2. run this client:  ./zig-out/bin/example-http1_client
//
// zix.Http.Client speaks HTTP/1.1 over std.http.Client, so it works against the
// raw zix.Http1 server. The version selector is forward-looking: HTTP_1 is the
// default and the only implemented backend today. Selecting HTTP_2 or HTTP_3
// yields error.UnsupportedVersion until those backends are wired.

pub fn main(process: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();

    var client = zix.Http.Client.init(.{
        .allocator = arena.allocator(),
        .io = process.io,
        .connect_timeout_ms = 5000,
        .max_response_body = 64 * 1024,
        .version = .HTTP_1,
    });
    defer client.deinit();

    // GET /
    {
        var resp = try client.get("http://127.0.0.1:9100/", .{});
        defer resp.deinit();
        std.debug.print("GET /  status={d}  body={s}\n", .{ resp.status(), resp.body() });
        if (resp.header("content-type")) |ct| {
            std.debug.print("  content-type: {s}\n", .{ct});
        }
    }

    // GET /about
    {
        var resp = try client.get("http://127.0.0.1:9100/about", .{});
        defer resp.deinit();
        std.debug.print("GET /about  status={d}  body={s}\n", .{ resp.status(), resp.body() });
    }

    // POST /echo with a custom header and body
    {
        const extra = [_]std.http.Header{
            .{ .name = "X-Trace-Id", .value = "demo-001" },
        };
        var resp = try client.post("http://127.0.0.1:9100/echo", .{
            .headers = &extra,
            .body = "hello from zix http1 client",
        });
        defer resp.deinit();
        std.debug.print("POST /echo  status={d}  body={s}\n", .{ resp.status(), resp.body() });
    }
}
