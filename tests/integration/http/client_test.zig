//! Integration tests: Http.Client and ClientResponse wired together without a live server.

const std = @import("std");
const zix = @import("zix");

test "zix integration: HttpClient.init and deinit, no requests" {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{ .stack_size = 512 * 1024 });
    defer threaded.deinit();

    var client = zix.Http.Client.init(.{
        .allocator = std.testing.allocator,
        .io = threaded.io(),
    });
    client.deinit();
}

test "zix integration: ClientResponse.header, lookup on mock head bytes" {
    const raw_head = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nX-Custom: hello\r\n\r\n";
    const head_copy = try std.testing.allocator.dupe(u8, raw_head);
    const body_copy = try std.testing.allocator.dupe(u8, "{}");

    var resp = zix.Http.ClientResponse{
        .status_code = 200,
        .head_bytes = head_copy,
        .body_data = body_copy,
        .allocator = std.testing.allocator,
    };
    defer resp.deinit();

    try std.testing.expectEqualStrings("application/json", resp.header("content-type").?);
    try std.testing.expectEqualStrings("application/json", resp.header("Content-Type").?);
    try std.testing.expectEqualStrings("hello", resp.header("x-custom").?);
}

test "zix integration: ClientResponse.iterateHeaders, count all headers" {
    const raw_head = "HTTP/1.1 200 OK\r\nA: 1\r\nB: 2\r\nC: 3\r\n\r\n";
    const head_copy = try std.testing.allocator.dupe(u8, raw_head);

    var resp = zix.Http.ClientResponse{
        .status_code = 200,
        .head_bytes = head_copy,
        .body_data = &.{},
        .allocator = std.testing.allocator,
    };
    defer resp.deinit();

    var count: usize = 0;
    var it = resp.iterateHeaders();
    while (it.next()) |_| count += 1;
    try std.testing.expectEqual(@as(usize, 3), count);
}

test "zix integration: ClientRequestOpts, all fields default" {
    const opts: zix.Http.ClientRequestOpts = .{};
    try std.testing.expectEqual(@as(usize, 0), opts.headers.len);
    try std.testing.expectEqual(null, opts.body);
    try std.testing.expectEqual(null, opts.connect_timeout_ms);
}
