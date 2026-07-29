//! Behaviour tests: zix.Http3.ServerConfig static-serving defaults and how they are stored.

const std = @import("std");
const zix = @import("zix");

// --------------------------------------------------------- //

test "zix behaviour: Http3 ServerConfig static serving is off by default" {
    const cfg = zix.Http3.ServerConfig{
        .io = undefined,
        .allocator = std.testing.allocator,
        .ip = "127.0.0.1",
        .port = 9500,
        .dispatch_model = .ASYNC,
    };

    // An empty public_dir keeps the router going straight to 404.
    try std.testing.expectEqualStrings("", cfg.public_dir);
    try std.testing.expectEqual(@as(u32, 0), cfg.public_dir_cache_ttl_ms);
    try std.testing.expectEqual(@as(u32, 256), cfg.public_dir_cache_max_entries);
}

test "zix behaviour: Http3 ServerConfig static fields are stored as set" {
    const cfg = zix.Http3.ServerConfig{
        .io = undefined,
        .allocator = std.testing.allocator,
        .ip = "127.0.0.1",
        .port = 9500,
        .dispatch_model = .ASYNC,
        .public_dir = "./public",
        .public_dir_cache_ttl_ms = 30_000,
        .public_dir_cache_max_entries = 64,
    };

    try std.testing.expectEqualStrings("./public", cfg.public_dir);
    try std.testing.expectEqual(@as(u32, 30_000), cfg.public_dir_cache_ttl_ms);
    try std.testing.expectEqual(@as(u32, 64), cfg.public_dir_cache_max_entries);
}

test "zix behaviour: Http3 static serving needs caching, unlike the other engines" {
    // On Http1 / Http / Http2 a ttl of 0 only turns the cache off and static files still serve. On
    // Http3 the response body outlives the handler, so it can only come from the cache: a ttl of 0
    // means no static serving at all. This test pins that difference so it is not "fixed" by
    // accident into a path that would hand the engine a body it cannot hold.
    const http3 = zix.Http3.ServerConfig{
        .io = undefined,
        .allocator = std.testing.allocator,
        .ip = "127.0.0.1",
        .port = 9500,
        .dispatch_model = .ASYNC,
        .public_dir = "./public",
    };
    const http1 = zix.Http1.ServerConfig{
        .io = undefined,
        .ip = "127.0.0.1",
        .port = 9501,
        .dispatch_model = .ASYNC,
        .public_dir = "./public",
    };

    // Same default on both, different meaning, which is exactly why it is documented per engine.
    try std.testing.expectEqual(@as(u32, 0), http3.public_dir_cache_ttl_ms);
    try std.testing.expectEqual(@as(u32, 0), http1.public_dir_cache_ttl_ms);
}
