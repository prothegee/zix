//! ZIX Uds Server
//!
//! ### file: src/zix/uds/Server.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Configured UDS stream server: init, deinit, and run.
//!
//! ### note:
//!
//! The handler is fixed at init, so run() takes no argument. config.io is
//! caller-provided and must outlive the server.
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
const HandlerFn = @import("handler.zig").HandlerFn;
const ignoreSigpipe = @import("../utils/ignore_sigpipe.zig").ignoreSigpipe;
const serve = @import("serve.zig");

// --------------------------------------------------------- //
// Fields:

config: Config,
handler: *const HandlerFn,

const Self = @This();

// --------------------------------------------------------- //
// Private:

fn serveError(err: serve.Error) Error {
    return switch (err) {
        error.ZixUds_Serve_PathInvalid => Error.ZixUds_Server_PathInvalid,
        error.ZixUds_Serve_ListenFailed => Error.ZixUds_Server_ListenFailed,
    };
}

/// Reject a config that run() cannot serve.
fn gateRun(config: Config) Error!void {
    if (config.max_recv_buf == 0) {
        serve.logSystem(
            config,
            .ERROR,
            "config.max_recv_buf can't be zero (got {d})",
            .{config.max_recv_buf},
        );

        return Error.ZixUds_Server_MaxRecvBufZero;
    }
}

// --------------------------------------------------------- //
// Public:

pub const Error = error {
    /// The target has no unix domain sockets
    ZixUds_Server_Unsupported,
    /// config.path is empty
    ZixUds_Server_PathEmpty,
    /// E.Q.: error.ZixUds_Serve_PathInvalid
    ZixUds_Server_PathInvalid,
    /// E.Q.: error.ZixUds_Serve_ListenFailed
    ZixUds_Server_ListenFailed,
    /// config.max_recv_buf is 0
    ZixUds_Server_MaxRecvBufZero,
};

/// Create a server that runs handler on every accepted connection.
///
/// Usage:
/// ```zig
/// var server = try zix.Uds.Server.init(zix.Uds.echoHandler, .{
///     .io = io,
///     .allocator = allocator,
///     .path = "./.tmp/app.sock",
/// });
/// defer server.deinit();
///
/// try server.run();
/// ```
///
/// Param:
/// handler - comptime HandlerFn (owns and closes each accepted stream)
/// config - Config (server configuration)
///
/// Return:
/// - Self
/// - Error.ZixUds_Server_Unsupported when the target has no unix sockets
/// - Error.ZixUds_Server_PathEmpty when config.path is empty
pub fn init(comptime handler: HandlerFn, config: Config) Error!Self {
    if (comptime !std.Io.net.has_unix_sockets) return Error.ZixUds_Server_Unsupported;

    if (config.path.len == 0) return Error.ZixUds_Server_PathEmpty;

    return .{
        .config = config,
        .handler = handler,
    };
}

/// No-op: run() releases the listener and the socket file itself.
pub fn deinit(self: *Self) void {
    _ = self;
}

/// Listen on config.path and serve until the io cancels the accept loop.
///
/// Return:
/// - void when the io cancels the accept loop
/// - Error.ZixUds_Server_Unsupported when the target has no unix sockets
/// - Error.ZixUds_Server_MaxRecvBufZero when config.max_recv_buf is 0
/// - Error.ZixUds_Server_PathInvalid when config.path does not fit
/// - Error.ZixUds_Server_ListenFailed when bind or listen fails
pub fn run(self: *const Self) Error!void {
    if (comptime !std.Io.net.has_unix_sockets) return Error.ZixUds_Server_Unsupported;

    try gateRun(self.config);

    ignoreSigpipe();

    serve.run(self.config, self.handler) catch |err| switch (err) {
        else => return serveError(err),
    };
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const Logger = @import("../logger/Logger.zig");
const echoHandler = @import("handler.zig").echoHandler;

fn mockHandler(stream: std.Io.net.Stream, io: std.Io) void {
    stream.close(io);
}

fn testConfig(path: []const u8) Config {
    return .{
        .io = std.testing.io,
        .allocator = std.testing.allocator,
        .path = path,
    };
}

test "zix uds: Server, init with an empty path is PathEmpty" {
    try std.testing.expectError(
        Error.ZixUds_Server_PathEmpty,
        Self.init(echoHandler, testConfig("")),
    );
}

test "zix uds: Server, init with a valid path succeeds" {
    var server = try Self.init(echoHandler, testConfig("zix_test.sock"));
    defer server.deinit();

    try std.testing.expectEqualStrings("zix_test.sock", server.config.path);
}

test "zix uds: Server, init stores the handler" {
    const server = try Self.init(mockHandler, testConfig("zix_test.sock"));

    try std.testing.expect(server.handler == &mockHandler);
}

test "zix uds: Server, init keeps the timeouts disabled by default" {
    const server = try Self.init(echoHandler, testConfig("zix_test.sock"));

    try std.testing.expectEqual(@as(u32, 0), server.config.recv_timeout_ms);
    try std.testing.expectEqual(@as(u32, 0), server.config.send_timeout_ms);
}

test "zix uds: Server, init stores the timeouts from config" {
    var config = testConfig("zix_test.sock");
    config.recv_timeout_ms = 5000;
    config.send_timeout_ms = 3000;

    const server = try Self.init(echoHandler, config);

    try std.testing.expectEqual(@as(u32, 5000), server.config.recv_timeout_ms);
    try std.testing.expectEqual(@as(u32, 3000), server.config.send_timeout_ms);
}

test "zix uds: Server, init accepts a one-byte path" {
    const server = try Self.init(echoHandler, testConfig("a"));

    try std.testing.expectEqual(@as(usize, 1), server.config.path.len);
}

test "zix uds: Server, run with max_recv_buf 0 is MaxRecvBufZero" {
    // Console off: the expected error line must not reach std.log.err.
    var logger = try Logger.init(std.testing.allocator, .{});
    defer logger.deinit();

    var config = testConfig("zix_test.sock");
    config.max_recv_buf = 0;
    config.logger = &logger;

    const server = try Self.init(echoHandler, config);

    try std.testing.expectError(Error.ZixUds_Server_MaxRecvBufZero, server.run());
}

test "zix uds: Server, gateRun accepts a max_recv_buf of 1" {
    var config = testConfig("zix_test.sock");
    config.max_recv_buf = 1;

    try gateRun(config);
}

test "zix uds: Server, run in a missing directory is ListenFailed" {
    if (comptime !std.Io.net.has_unix_sockets) return error.SkipZigTest;

    // Console off: the expected error line must not reach std.log.err.
    var logger = try Logger.init(std.testing.allocator, .{});
    defer logger.deinit();

    var config = testConfig("no-such-dir-for-zix-uds/zix.sock");
    config.logger = &logger;

    const server = try Self.init(echoHandler, config);

    try std.testing.expectError(Error.ZixUds_Server_ListenFailed, server.run());
}

test "zix uds: Server, run with a path past the address limit is PathInvalid" {
    if (comptime !std.Io.net.has_unix_sockets) return error.SkipZigTest;

    // Console off: the expected error line must not reach std.log.err.
    var logger = try Logger.init(std.testing.allocator, .{});
    defer logger.deinit();

    const long_path: [std.Io.net.UnixAddress.max_len + 1]u8 = @splat('a');

    var config = testConfig(&long_path);
    config.logger = &logger;

    const server = try Self.init(echoHandler, config);

    try std.testing.expectError(Error.ZixUds_Server_PathInvalid, server.run());
}

test "zix uds: Server, maps serve errors with the same condition" {
    try std.testing.expectEqual(
        Error.ZixUds_Server_PathInvalid,
        serveError(error.ZixUds_Serve_PathInvalid),
    );
    try std.testing.expectEqual(
        Error.ZixUds_Server_ListenFailed,
        serveError(error.ZixUds_Serve_ListenFailed),
    );
}

