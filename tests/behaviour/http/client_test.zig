//! Behaviour tests: Http.ClientConfig defaults and ClientResponse observable contracts.

const std = @import("std");
const zix = @import("zix");

test "zix behaviour: ClientConfig, connect_timeout_ms default is 0" {
    const cfg: zix.Http.ClientConfig = .{ .allocator = std.testing.allocator, .io = undefined };
    try std.testing.expectEqual(@as(u32, 0), cfg.connect_timeout_ms);
}

test "zix behaviour: ClientConfig, response_timeout_ms default is 0" {
    const cfg: zix.Http.ClientConfig = .{ .allocator = std.testing.allocator, .io = undefined };
    try std.testing.expectEqual(@as(u32, 0), cfg.response_timeout_ms);
}

test "zix behaviour: ClientConfig, read_timeout_ms default is 0" {
    const cfg: zix.Http.ClientConfig = .{ .allocator = std.testing.allocator, .io = undefined };
    try std.testing.expectEqual(@as(u32, 0), cfg.read_timeout_ms);
}

test "zix behaviour: ClientConfig, max_response_body default is 4 MB" {
    const cfg: zix.Http.ClientConfig = .{ .allocator = std.testing.allocator, .io = undefined };
    try std.testing.expectEqual(@as(usize, 1024 * 1024 * 4), cfg.max_response_body);
}

test "zix behaviour: ClientConfig, follow_redirects default is true" {
    const cfg: zix.Http.ClientConfig = .{ .allocator = std.testing.allocator, .io = undefined };
    try std.testing.expect(cfg.follow_redirects);
}

test "zix behaviour: ClientConfig, max_redirects default is 3" {
    const cfg: zix.Http.ClientConfig = .{ .allocator = std.testing.allocator, .io = undefined };
    try std.testing.expectEqual(@as(u8, 3), cfg.max_redirects);
}

test "zix behaviour: ClientConfig, user_agent default is from 'zon_options.user_agent'" {
    const cfg: zix.Http.ClientConfig = .{ .allocator = std.testing.allocator, .io = undefined };
    try std.testing.expectEqualStrings(zix.Http.default_user_agent, cfg.user_agent);
}

test "zix behaviour: ClientResponse.status(), returns status_code field" {
    const head_copy = try std.testing.allocator.dupe(u8, "HTTP/1.1 404 Not Found\r\n\r\n");
    var resp = zix.Http.ClientResponse{
        .status_code = 404,
        .head_bytes = head_copy,
        .body_data = &.{},
        .allocator = std.testing.allocator,
    };
    defer resp.deinit();

    try std.testing.expectEqual(@as(u16, 404), resp.status());
}

test "zix behaviour: ClientResponse.body(), returns body_data slice" {
    const head_copy = try std.testing.allocator.dupe(u8, "HTTP/1.1 200 OK\r\n\r\n");
    const body_copy = try std.testing.allocator.dupe(u8, "hello");
    var resp = zix.Http.ClientResponse{
        .status_code = 200,
        .head_bytes = head_copy,
        .body_data = body_copy,
        .allocator = std.testing.allocator,
    };
    defer resp.deinit();

    try std.testing.expectEqualStrings("hello", resp.body());
}

test "zix behaviour: ClientResponse.header(), case-insensitive match" {
    const head_copy = try std.testing.allocator.dupe(u8, "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\n");
    var resp = zix.Http.ClientResponse{
        .status_code = 200,
        .head_bytes = head_copy,
        .body_data = &.{},
        .allocator = std.testing.allocator,
    };
    defer resp.deinit();

    try std.testing.expectEqualStrings("text/plain", resp.header("content-type").?);
    try std.testing.expectEqualStrings("text/plain", resp.header("CONTENT-TYPE").?);
    try std.testing.expectEqualStrings("text/plain", resp.header("Content-Type").?);
}

test "zix behaviour: ClientResponse.deinit(), zero-length body is safe" {
    const head_copy = try std.testing.allocator.dupe(u8, "HTTP/1.1 204 No Content\r\n\r\n");
    var resp = zix.Http.ClientResponse{
        .status_code = 204,
        .head_bytes = head_copy,
        .body_data = &.{},
        .allocator = std.testing.allocator,
    };
    resp.deinit();
}
