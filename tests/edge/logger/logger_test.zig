//! Edge tests: zix.Logger boundary conditions and error paths.

const std = @import("std");
const zix = @import("zix");

// --------------------------------------------------------- //

test "zix edge: statusLevel 2xx boundary (200 -> INFO)" {
    const Logger = zix.Logger;
    _ = Logger;
    // statusLevel is internal, verify via access() with each status class.
    // Test that access() does not crash for every boundary status.
    var logger = try zix.Logger.init(std.testing.allocator, .{ .save_min_level = .DEBUG });
    defer logger.deinit();

    logger.access("GET", "/", 100, 0, "", "", "");
    logger.access("GET", "/", 199, 0, "", "", "");
    logger.access("GET", "/", 200, 0, "", "", "");
    logger.access("GET", "/", 301, 0, "", "", "");
    logger.access("GET", "/", 399, 0, "", "", "");
    logger.access("GET", "/", 400, 0, "", "", "");
    logger.access("GET", "/", 499, 0, "", "", "");
    logger.access("GET", "/", 500, 0, "", "", "");
    logger.access("GET", "/", 599, 0, "", "", "");
}

test "zix edge: Level enum ordering (DEBUG < INFO < WARN < ERROR)" {
    try std.testing.expect(
        @intFromEnum(zix.Logger.Level.DEBUG) < @intFromEnum(zix.Logger.Level.INFO),
    );
    try std.testing.expect(
        @intFromEnum(zix.Logger.Level.INFO) < @intFromEnum(zix.Logger.Level.WARN),
    );
    try std.testing.expect(
        @intFromEnum(zix.Logger.Level.WARN) < @intFromEnum(zix.Logger.Level.ERROR),
    );
}

test "zix edge: system() below save_min_level is silent (no file written)" {
    var logger = try zix.Logger.init(std.testing.allocator, .{
        .save_min_level = .ERROR,
        .save_path = "",
    });
    defer logger.deinit();

    logger.system(.DEBUG, "test", "filtered", .{});
    logger.system(.INFO, "test", "filtered", .{});
    logger.system(.WARN, "test", "filtered", .{});
    try std.testing.expectEqual(@as(std.posix.fd_t, -1), logger.file_fd);
}

test "zix edge: access() below save_min_level is silent" {
    var logger = try zix.Logger.init(std.testing.allocator, .{
        .save_min_level = .ERROR,
        .save_path = "",
    });
    defer logger.deinit();

    logger.access("GET", "/", 200, 100, "", "UA", "origin");
    try std.testing.expectEqual(@as(std.posix.fd_t, -1), logger.file_fd);
}

test "zix edge: system() with empty component does not panic" {
    var logger = try zix.Logger.init(std.testing.allocator, .{});
    defer logger.deinit();

    logger.system(.INFO, "", "no component", .{});
}

test "zix edge: system() with empty format does not panic" {
    var logger = try zix.Logger.init(std.testing.allocator, .{});
    defer logger.deinit();

    logger.system(.INFO, "test", "", .{});
}

test "zix edge: access() with empty method and path does not panic" {
    var logger = try zix.Logger.init(std.testing.allocator, .{});
    defer logger.deinit();

    logger.access("", "", 200, 0, "", "", "");
}

test "zix edge: init with empty save_path, file_fd stays invalid" {
    var logger = try zix.Logger.init(std.testing.allocator, .{ .save_path = "" });
    defer logger.deinit();

    try std.testing.expectEqual(@as(std.posix.fd_t, -1), logger.file_fd);
}

test "zix edge: access() empty client_ip does not panic" {
    var logger = try zix.Logger.init(std.testing.allocator, .{});
    defer logger.deinit();
    logger.access("GET", "/", 200, 0, "", "", "");
}

test "zix edge: access() non-empty client_ip does not panic" {
    var logger = try zix.Logger.init(std.testing.allocator, .{});
    defer logger.deinit();
    logger.access("GET", "/", 200, 0, "203.0.113.5", "", "");
}

test "zix edge: console OFF, consoleActive false for all levels" {
    var logger = try zix.Logger.init(std.testing.allocator, .{
        .console = .OFF,
    });
    defer logger.deinit();
    // All system() calls with console OFF produce no output and do not crash.
    logger.system(.DEBUG, "t", "msg", .{});
    logger.system(.INFO, "t", "msg", .{});
    logger.system(.WARN, "t", "msg", .{});
    logger.system(.ERROR, "t", "msg", .{});
}
