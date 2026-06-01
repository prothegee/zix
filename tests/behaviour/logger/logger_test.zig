//! Behaviour tests: zix.Logger API contracts.
//! Verifies enum backing values, config defaults, and safe no-op operations.

const std = @import("std");
const zix = @import("zix");

// --------------------------------------------------------- //

test "zix behaviour: Logger.Level backing values" {
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(zix.Logger.Level.DEBUG));
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(zix.Logger.Level.INFO));
    try std.testing.expectEqual(@as(u8, 2), @intFromEnum(zix.Logger.Level.WARN));
    try std.testing.expectEqual(@as(u8, 3), @intFromEnum(zix.Logger.Level.ERROR));
}

test "zix behaviour: Logger.ConsoleMode backing values" {
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(zix.Logger.ConsoleMode.OFF));
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(zix.Logger.ConsoleMode.DEBUG_ONLY));
    try std.testing.expectEqual(@as(u8, 2), @intFromEnum(zix.Logger.ConsoleMode.ALWAYS));
}

test "zix behaviour: Logger.Config defaults" {
    const cfg = zix.Logger.Config{};
    try std.testing.expectEqual(zix.Logger.ConsoleMode.OFF, cfg.console);
    try std.testing.expectEqual(zix.Logger.Level.INFO, cfg.console_min_level);
    try std.testing.expectEqualStrings("", cfg.save_path);
    try std.testing.expectEqualStrings("log", cfg.save_file);
    try std.testing.expectEqual(zix.Logger.Level.INFO, cfg.save_min_level);
    try std.testing.expectEqual(@as(u64, 1_000_000), cfg.max_lines);
}

test "zix behaviour: Logger init and deinit with no save_path" {
    var logger = try zix.Logger.init(std.testing.allocator, .{});
    defer logger.deinit();
}

test "zix behaviour: Logger flush with no save_path is a no-op" {
    var logger = try zix.Logger.init(std.testing.allocator, .{});
    defer logger.deinit();

    logger.flush();
}

test "zix behaviour: Http.ServerConfig.logger defaults to null" {
    const cfg = zix.Http.ServerConfig{
        .io = undefined,
        .ip = "127.0.0.1",
        .port = 8080,
    };
    try std.testing.expectEqual(@as(?*zix.Logger, null), cfg.logger);
}

test "zix behaviour: Http.Context.logger defaults to null" {
    const ctx = zix.Http.Context{
        .io = undefined,
        .allocator = std.testing.allocator,
    };
    try std.testing.expectEqual(@as(?*zix.Logger, null), ctx.logger);
}

test "zix behaviour: Http.Response.bytes_written defaults to 0" {
    const res = zix.Http.Response.init(
        undefined,
        true,
        undefined,
        std.testing.allocator,
        32,
    );
    try std.testing.expectEqual(@as(usize, 0), res.bytes_written);
}
