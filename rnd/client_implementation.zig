const std = @import("std");

pub fn main(process: std.process.Init) !void {
    var client = std.http.Client{
        .allocator = std.heap.page_allocator,
        .io = process.io,
    };
    defer client.deinit();

    const uri = try std.Uri.parse("http://127.0.0.1:8080/");
    var req = try client.request(.GET, uri, .{ .keep_alive = false });
    defer req.deinit();

    try req.sendBodiless();
    var resp = req.receiveHead(&.{}) catch |err| {
        std.debug.print("Error: {any}\n", .{err});
        return;
    };

    std.debug.print("Status: {}\n", .{resp.head.status});
    var it = resp.head.iterateHeaders();
    while (it.next()) |h| {
        std.debug.print("{s}: {s}\n", .{ h.name, h.value });
    }

    const reader = resp.reader(&.{});
    const n = try reader.discardRemaining();
    std.debug.print("Discarded {} bytes of body\n", .{n});
}
