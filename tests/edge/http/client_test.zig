//! Edge tests: Http.Client error paths and boundary conditions.

const std = @import("std");
const zix = @import("zix");

test "zix edge: error.InvalidUrl, unsupported scheme" {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{ .stack_size = 512 * 1024 });
    defer threaded.deinit();

    var client = zix.Http.Client.init(.{
        .allocator = std.testing.allocator,
        .io = threaded.io(),
    });
    defer client.deinit();

    try std.testing.expectError(error.InvalidUrl, client.get("ftp://example.com/", .{}));
}

test "zix edge: error.InvalidUrl, missing host" {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{ .stack_size = 512 * 1024 });
    defer threaded.deinit();

    var client = zix.Http.Client.init(.{
        .allocator = std.testing.allocator,
        .io = threaded.io(),
    });
    defer client.deinit();

    try std.testing.expectError(error.InvalidUrl, client.get("http://", .{}));
}

test "zix edge: error.InvalidUrl, malformed url" {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{ .stack_size = 512 * 1024 });
    defer threaded.deinit();

    var client = zix.Http.Client.init(.{
        .allocator = std.testing.allocator,
        .io = threaded.io(),
    });
    defer client.deinit();

    try std.testing.expectError(error.InvalidUrl, client.get(":::bad", .{}));
}

test "zix edge: ClientResponse.header(), absent name returns null" {
    const head_copy = try std.testing.allocator.dupe(u8, "HTTP/1.1 200 OK\r\nX-Present: yes\r\n\r\n");
    var resp = zix.Http.ClientResponse{
        .status_code = 200,
        .head_bytes = head_copy,
        .body_data = &.{},
        .allocator = std.testing.allocator,
    };
    defer resp.deinit();
    try std.testing.expectEqual(null, resp.header("x-missing"));
}

test "zix edge: RequestOpts.connect_timeout_ms, override is distinct from null" {
    const opts_default: zix.Http.ClientRequestOpts = .{};
    const opts_zero: zix.Http.ClientRequestOpts = .{ .connect_timeout_ms = 0 };
    const opts_set: zix.Http.ClientRequestOpts = .{ .connect_timeout_ms = 5000 };

    try std.testing.expectEqual(null, opts_default.connect_timeout_ms);
    try std.testing.expectEqual(@as(u32, 0), opts_zero.connect_timeout_ms.?);
    try std.testing.expectEqual(@as(u32, 5000), opts_set.connect_timeout_ms.?);
}
