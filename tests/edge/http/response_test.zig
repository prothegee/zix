//! Edge tests: zix.Http.Response.addHeader boundary conditions.
//! Verifies header injection guards (CR/LF), TooManyHeaders at cap,
//! buffer growth from initial 4 to 5, and max_headers=1 single-slot behaviour.

const std = @import("std");
const zix = @import("zix");

// --------------------------------------------------------- //

test "zix edge: addHeader, CR in name returns InvalidHeaderName" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var res = zix.Http.Response.init(undefined, false, undefined, arena.allocator(), 32);
    try std.testing.expectError(error.InvalidHeaderName, res.addHeader("Bad\rName", "value"));
}

test "zix edge: addHeader, LF in name returns InvalidHeaderName" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var res = zix.Http.Response.init(undefined, false, undefined, arena.allocator(), 32);
    try std.testing.expectError(error.InvalidHeaderName, res.addHeader("Bad\nName", "value"));
}

test "zix edge: addHeader, CR in value returns InvalidHeaderValue" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var res = zix.Http.Response.init(undefined, false, undefined, arena.allocator(), 32);
    try std.testing.expectError(error.InvalidHeaderValue, res.addHeader("X-Ok", "bad\rvalue"));
}

test "zix edge: addHeader, LF in value returns InvalidHeaderValue" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var res = zix.Http.Response.init(undefined, false, undefined, arena.allocator(), 32);
    try std.testing.expectError(error.InvalidHeaderValue, res.addHeader("X-Ok", "bad\nvalue"));
}

// --------------------------------------------------------- //

test "zix edge: addHeader, buffer grows from 4 to 5 on the 5th header" {
    // max_headers=5: initial buf=min(4,5)=4, the 5th add triggers growth to min(8,5)=5
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var res = zix.Http.Response.init(undefined, false, undefined, arena.allocator(), 5);
    try res.addHeader("H1", "v1");
    try res.addHeader("H2", "v2");
    try res.addHeader("H3", "v3");
    try res.addHeader("H4", "v4");
    try std.testing.expectEqual(@as(usize, 4), res.extra_len);
    try res.addHeader("H5", "v5");
    try std.testing.expectEqual(@as(usize, 5), res.extra_len);
    // values must be intact across the reallocation
    try std.testing.expectEqualStrings("H1", res.extra_buf.?[0].name);
    try std.testing.expectEqualStrings("H5", res.extra_buf.?[4].name);
    // 6th header exceeds max_headers
    try std.testing.expectError(error.TooManyHeaders, res.addHeader("H6", "v6"));
}

test "zix edge: addHeader, max_headers=1 rejects second header without growth" {
    // initial buf=min(4,1)=1; on the second call extra_buf.len(1) >= max_headers(1) -> TooManyHeaders
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var res = zix.Http.Response.init(undefined, false, undefined, arena.allocator(), 1);
    try res.addHeader("Only", "one");
    try std.testing.expectEqual(@as(usize, 1), res.extra_len);
    try std.testing.expectError(error.TooManyHeaders, res.addHeader("Second", "two"));
}

// --------------------------------------------------------- //

test "zix edge: HeaderSize.CUSTOM(0), value() returns 0" {
    const hs: zix.Http.HeaderSize = .{ .CUSTOM = 0 };
    try std.testing.expectEqual(@as(usize, 0), hs.value());
}
