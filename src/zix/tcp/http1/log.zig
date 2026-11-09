//! ZIX Http1 log
//!
//! ### file: src/zix/tcp/http1/log.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Server line output shared by the dispatch models.
//!
//! ### note:
//!
//! n/a
//!
//! ---------------------------------------------------------
//!
//! ### licenses:
//!
//! - BSD-3-Clause
//!
//! ### copyright:
//!
//! - (c) Prana Ron // @prothegee // prothegee@pm.me
//!
//! ### contributors:
//!
//! - Prana Ron // @prothegee // prothegee@pm.me
//!

const std = @import("std");
const Config = @import("Config.zig");
const Logger = @import("../../logger/Logger.zig");

// --------------------------------------------------------- //
// Public:

/// Emit a server line at the given level.
///
/// Note:
/// - Without a logger the line still reaches std.log, so a release build never
///   loses a failure.
///
/// Param:
/// config - Config (source of the optional logger)
/// level - Logger.Level (severity of the line)
/// fmt - []const u8 (comptime format string)
/// args - anytype (format arguments)
///
/// Return:
/// - void
pub fn logSystem(
    config: Config,
    level: Logger.Level,
    comptime fmt: []const u8,
    args: anytype,
) void {
    if (config.logger) |logger| {
        logger.system(level, "http1", fmt, args);

        return;
    }

    switch (level) {
        .ERROR => std.log.err(fmt, args),
        .WARN => std.log.warn(fmt, args),
        .INFO => std.log.info(fmt, args),
        .DEBUG => std.log.debug(fmt, args),
    }
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

fn testConfig(logger: ?*Logger) Config {
    return .{
        .io = std.testing.io,
        .ip = "127.0.0.1",
        .port = 0,
        .dispatch_model = .ASYNC,
        .logger = logger,
    };
}

test "zix http1: log, logSystem writes to the attached logger" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var capture = try tmp.dir.createFile(std.testing.io, "capture.log", .{});
    defer capture.close(std.testing.io);

    var logger = try Logger.init(std.testing.allocator, .{
        .console = .ALWAYS,
        .console_min_level = .DEBUG,
        .console_fd = capture.handle,
    });
    defer logger.deinit();

    logSystem(testConfig(&logger), .INFO, "listening on port {d}", .{9015});
    logger.flush();

    const content = try tmp.dir.readFileAlloc(
        std.testing.io,
        "capture.log",
        std.testing.allocator,
        .limited(64 * 1024),
    );
    defer std.testing.allocator.free(content);

    try std.testing.expect(std.mem.indexOf(u8, content, "http1") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "listening on port 9015") != null);
}

test "zix http1: log, logSystem without a logger falls back to std.log" {
    logSystem(testConfig(null), .INFO, "fallback line {d}", .{1});
    logSystem(testConfig(null), .DEBUG, "fallback line {d}", .{2});
}

