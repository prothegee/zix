//! http_sse_client.zig: Server-Sent Events client example.
//!
//! Connects to the http_sse example server and reads every tick event
//! until the server closes the stream after 10 ticks.
//!
//! Run:
//! zig build example-http_sse && ./zig-out/bin/example-http_sse &
//! zig build example-http_sse_client && ./zig-out/bin/example-http_sse_client
//! kill %1

const std = @import("std");
const zix = @import("zix");

pub fn main(process: std.process.Init) !void {
    const sse = zix.Http.SseClient.init(.{
        .io = process.io,
        .connect_timeout_ms = 5000,
    });

    var stream = try sse.open("http://127.0.0.1:9010/events");
    defer stream.deinit();
    std.debug.print("sse: connected\n", .{});

    var buf: [4096]u8 = undefined;
    var count: usize = 0;

    while (try stream.next(&buf)) |ev| {
        count += 1;
        if (ev.event) |et| {
            std.debug.print("sse: [{d}] event={s} data={s}\n", .{ count, et, ev.data });
        } else {
            std.debug.print("sse: [{d}] data={s}\n", .{ count, ev.data });
        }
        if (ev.id) |id| std.debug.print("sse:     id={s}\n", .{id});
        if (ev.retry) |ms| std.debug.print("sse:     retry={d}ms\n", .{ms});
    }

    std.debug.print("sse: stream closed after {d} events\n", .{count});
}
