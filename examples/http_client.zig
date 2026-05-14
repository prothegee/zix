const std = @import("std");
const zix = @import("zix");

// Runs alongside http_basic.zig server on port 9000.
// Usage: zig build example-http_client && ./zig-out/bin/example-http_client

pub fn main(process: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();

    var client = zix.Http.Client.init(.{
        .allocator = arena.allocator(),
        .io = process.io,
        .connect_timeout_ms = 5000,
        .max_response_body = 64 * 1024,
    });
    defer client.deinit();

    // GET /
    {
        var resp = try client.get("http://127.0.0.1:9000/", .{});
        defer resp.deinit();
        std.debug.print("GET /  status={d}  body={s}\n", .{ resp.status(), resp.body() });
        if (resp.header("content-type")) |ct| {
            std.debug.print("  content-type: {s}\n", .{ct});
        }
    }

    // GET /about
    {
        var resp = try client.get("http://127.0.0.1:9000/about", .{});
        defer resp.deinit();
        std.debug.print("GET /about  status={d}  body={s}\n", .{ resp.status(), resp.body() });
    }

    // POST /echo with custom header and body
    {
        const extra = [_]std.http.Header{
            .{ .name = "X-Trace-Id", .value = "demo-001" },
        };
        var resp = try client.post("http://127.0.0.1:9000/echo", .{
            .headers = &extra,
            .body = "hello from zix client",
        });
        defer resp.deinit();
        std.debug.print("POST /echo  status={d}  body={s}\n", .{ resp.status(), resp.body() });
    }
}
