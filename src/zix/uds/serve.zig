//! ZIX Uds serve
//!
//! ### file: src/zix/uds/serve.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Listens on the UDS socket path, accepts connections, and hands each one to
//! the handler.
//!
//! ### note:
//!
//! The socket file is removed before bind and again when run() returns, so a
//! stale file from a crashed run never blocks the next one.
//! run() only returns on a setup failure, or when the io cancels the accept.
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
const builtin = @import("builtin");
const Config = @import("Config.zig");
const Logger = @import("../logger/Logger.zig");
const HandlerFn = @import("handler.zig").HandlerFn;

// --------------------------------------------------------- //
// Private:

/// Convert milliseconds into the timeval a socket timeout option takes.
fn msToTimeval(ms: u32) std.posix.timeval {
    return .{
        .sec = @intCast(ms / 1000),
        .usec = @intCast((ms % 1000) * 1000),
    };
}

/// Set one socket timeout option, best effort.
fn setTimeoutOpt(sock_fd: std.posix.socket_t, option: u32, ms: u32) void {
    const timeout = msToTimeval(ms);

    std.posix.setsockopt(
        sock_fd,
        std.posix.SOL.SOCKET,
        option,
        std.mem.asBytes(&timeout),
    ) catch |err| switch (err) {
        // Best effort: the connection is still served, only without this timeout.
        else => {},
    };
}

/// Remove the socket file at path, best effort.
fn removeSocketFile(io: std.Io, path: []const u8) void {
    std.Io.Dir.cwd().deleteFile(io, path) catch |err| switch (err) {
        // No file is the normal case. Any other failure surfaces at listen.
        else => {},
    };
}

/// Run the handler on one accepted connection.
fn dispatchConn(
    handler: *const HandlerFn,
    stream: std.Io.net.Stream,
    io: std.Io,
    logger: ?*Logger,
) void {
    if (logger) |active| active.system(.INFO, "uds", "connection accepted", .{});

    handler(stream, io);
}

// --------------------------------------------------------- //
// Public:

pub const Error = error {
    /// config.path does not fit a unix socket address
    ZixUds_Serve_PathInvalid,
    /// bind or listen on config.path failed
    ZixUds_Serve_ListenFailed,
};

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
        logger.system(level, "uds", fmt, args);

        return;
    }

    switch (level) {
        .ERROR => std.log.err(fmt, args),
        .WARN => std.log.warn(fmt, args),
        .INFO => std.log.info(fmt, args),
        .DEBUG => std.log.debug(fmt, args),
    }
}

/// Set the receive and send timeouts of one accepted connection, best effort.
///
/// Note:
/// - 0 leaves that timeout untouched (disabled). No-op on Windows.
///
/// Param:
/// sock_fd - std.posix.socket_t (the accepted connection)
/// recv_ms - u32 (SO_RCVTIMEO in milliseconds)
/// send_ms - u32 (SO_SNDTIMEO in milliseconds)
///
/// Return:
/// - void
pub fn applyConnTimeout(sock_fd: std.posix.socket_t, recv_ms: u32, send_ms: u32) void {
    if (comptime builtin.target.os.tag == .windows) return;

    if (recv_ms > 0) setTimeoutOpt(sock_fd, std.posix.SO.RCVTIMEO, recv_ms);

    if (send_ms > 0) setTimeoutOpt(sock_fd, std.posix.SO.SNDTIMEO, send_ms);
}

/// Listen on config.path and serve each accepted connection with handler.
///
/// Note:
/// - Each connection runs as a concurrent task. When the io has no
///   concurrency left, the connection runs inline on the accept loop.
/// - An accept failure is logged and the loop keeps accepting, except a
///   canceled or shut down listener, which ends run().
///
/// Param:
/// config - Config (server configuration, config.io drives every call)
/// handler - *const HandlerFn (owns each accepted stream)
///
/// Return:
/// - void when the io cancels the accept loop
/// - Error.ZixUds_Serve_PathInvalid when config.path does not fit
/// - Error.ZixUds_Serve_ListenFailed when bind or listen fails
pub fn run(config: Config, handler: *const HandlerFn) Error!void {
    const io = config.io;

    removeSocketFile(io, config.path);

    // The bare std error names neither the socket nor what went wrong with it.
    const address = std.Io.net.UnixAddress.init(config.path) catch |err| switch (err) {
        else => {
            logSystem(
                config,
                .ERROR,
                "the socket path is not usable: {s} ({s})",
                .{ config.path, @errorName(err) },
            );

            return Error.ZixUds_Serve_PathInvalid;
        },
    };

    var server = address.listen(io, .{
        .kernel_backlog = config.kernel_backlog,
    }) catch |err| switch (err) {
        else => {
            logSystem(
                config,
                .ERROR,
                "could not listen on {s} ({s})",
                .{ config.path, @errorName(err) },
            );

            return Error.ZixUds_Serve_ListenFailed;
        },
    };
    defer {
        server.deinit(io);
        removeSocketFile(io, config.path);
    }

    // A group task frees its resources when it returns. cancel() ends the
    // connections still open when run() returns.
    var connections: std.Io.Group = .init;
    defer connections.cancel(io);

    logSystem(config, .INFO, "listening on {s}", .{config.path});

    while (true) {
        const stream = server.accept(io) catch |err| switch (err) {
            error.Canceled,
            error.SocketNotListening,
            => return,
            else => {
                logSystem(config, .WARN, "accept error: {s}", .{@errorName(err)});

                continue;
            },
        };

        applyConnTimeout(stream.socket.handle, config.recv_timeout_ms, config.send_timeout_ms);

        const args = .{
            handler,
            stream,
            io,
            config.logger,
        };

        connections.concurrent(io, dispatchConn, args) catch |err| switch (err) {
            error.ConcurrencyUnavailable => @call(.auto, dispatchConn, args),
        };
    }
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const frame = @import("frame.zig");
const handler_mod = @import("handler.zig");
const socket_pair = @import("../utils/socket/pair.zig");

const linux_only = builtin.target.os.tag == .linux;

fn testConfig(path: []const u8, logger: ?*Logger) Config {
    return .{
        .io = std.testing.io,
        .allocator = std.testing.allocator,
        .path = path,
        .logger = logger,
    };
}

/// Read one socket timeout option back from the kernel.
fn testReadTimeout(sock_fd: std.posix.fd_t, option: u32) !std.posix.timeval {
    var timeout: std.posix.timeval = undefined;
    var opt_len: std.posix.socklen_t = @sizeOf(std.posix.timeval);

    const rc = std.os.linux.getsockopt(
        sock_fd,
        std.posix.SOL.SOCKET,
        option,
        @ptrCast(&timeout),
        &opt_len,
    );
    if (std.posix.errno(rc) != .SUCCESS) return error.TestGetSockOptFailed;

    return timeout;
}

/// Open a socket pair, return one end and close the other.
fn testSocket() !std.posix.fd_t {
    var fds: [2]std.posix.fd_t = undefined;
    try socket_pair.open(std.testing.io, &fds);
    _ = std.posix.system.close(fds[1]);

    return fds[0];
}

/// Build "<tmp dir>/<name>" relative to the cwd into buf.
fn testSocketPath(buf: []u8, tmp: std.testing.TmpDir, name: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, ".zig-cache/tmp/{s}/{s}", .{ tmp.sub_path, name });
}

/// Connect to path, retrying while the server is still starting.
fn testConnect(path: []const u8) !std.Io.net.Stream {
    const address = try std.Io.net.UnixAddress.init(path);

    var attempt: usize = 0;
    while (attempt < 200) : (attempt += 1) {
        if (address.connect(std.testing.io)) |stream| {
            return stream;
        } else |err| switch (err) {
            error.FileNotFound,
            error.ConnectionRefused,
            => try std.testing.io.sleep(.fromMilliseconds(5), .awake),
            else => return err,
        }
    }

    return error.TestConnectTimedOut;
}

test "zix uds: serve, msToTimeval splits seconds and microseconds" {
    const timeout = msToTimeval(2500);

    try std.testing.expectEqual(@as(@TypeOf(timeout.sec), 2), timeout.sec);
    try std.testing.expectEqual(@as(@TypeOf(timeout.usec), 500_000), timeout.usec);
}

test "zix uds: serve, msToTimeval below one second has zero seconds" {
    const timeout = msToTimeval(1);

    try std.testing.expectEqual(@as(@TypeOf(timeout.sec), 0), timeout.sec);
    try std.testing.expectEqual(@as(@TypeOf(timeout.usec), 1000), timeout.usec);
}

test "zix uds: serve, msToTimeval accepts the u32 max" {
    const timeout = msToTimeval(std.math.maxInt(u32));

    try std.testing.expectEqual(@as(@TypeOf(timeout.sec), 4_294_967), timeout.sec);
    try std.testing.expectEqual(@as(@TypeOf(timeout.usec), 295_000), timeout.usec);
}

test "zix uds: serve, applyConnTimeout zero ms is a no-op" {
    if (comptime !linux_only) return error.SkipZigTest;

    const sock_fd = try testSocket();
    defer _ = std.posix.system.close(sock_fd);

    applyConnTimeout(sock_fd, 0, 0);

    const recv_tv = try testReadTimeout(sock_fd, std.posix.SO.RCVTIMEO);
    const send_tv = try testReadTimeout(sock_fd, std.posix.SO.SNDTIMEO);

    try std.testing.expectEqual(@as(@TypeOf(recv_tv.sec), 0), recv_tv.sec);
    try std.testing.expectEqual(@as(@TypeOf(recv_tv.usec), 0), recv_tv.usec);
    try std.testing.expectEqual(@as(@TypeOf(send_tv.sec), 0), send_tv.sec);
    try std.testing.expectEqual(@as(@TypeOf(send_tv.usec), 0), send_tv.usec);
}

test "zix uds: serve, applyConnTimeout sets SO_RCVTIMEO" {
    if (comptime !linux_only) return error.SkipZigTest;

    const sock_fd = try testSocket();
    defer _ = std.posix.system.close(sock_fd);

    applyConnTimeout(sock_fd, 2500, 0);

    const recv_tv = try testReadTimeout(sock_fd, std.posix.SO.RCVTIMEO);

    try std.testing.expectEqual(@as(@TypeOf(recv_tv.sec), 2), recv_tv.sec);
    try std.testing.expectEqual(@as(@TypeOf(recv_tv.usec), 500_000), recv_tv.usec);
}

test "zix uds: serve, applyConnTimeout sets SO_SNDTIMEO" {
    if (comptime !linux_only) return error.SkipZigTest;

    const sock_fd = try testSocket();
    defer _ = std.posix.system.close(sock_fd);

    applyConnTimeout(sock_fd, 0, 1000);

    const send_tv = try testReadTimeout(sock_fd, std.posix.SO.SNDTIMEO);

    try std.testing.expectEqual(@as(@TypeOf(send_tv.sec), 1), send_tv.sec);
    try std.testing.expectEqual(@as(@TypeOf(send_tv.usec), 0), send_tv.usec);
}

test "zix uds: serve, applyConnTimeout recv only leaves SO_SNDTIMEO disabled" {
    if (comptime !linux_only) return error.SkipZigTest;

    const sock_fd = try testSocket();
    defer _ = std.posix.system.close(sock_fd);

    applyConnTimeout(sock_fd, 750, 0);

    const send_tv = try testReadTimeout(sock_fd, std.posix.SO.SNDTIMEO);

    try std.testing.expectEqual(@as(@TypeOf(send_tv.sec), 0), send_tv.sec);
    try std.testing.expectEqual(@as(@TypeOf(send_tv.usec), 0), send_tv.usec);
}

test "zix uds: serve, logSystem writes to the attached logger" {
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

    logSystem(testConfig("zix.sock", &logger), .INFO, "listening on {s}", .{"zix.sock"});
    logger.flush();

    const content = try tmp.dir.readFileAlloc(
        std.testing.io,
        "capture.log",
        std.testing.allocator,
        .limited(64 * 1024),
    );
    defer std.testing.allocator.free(content);

    try std.testing.expect(std.mem.indexOf(u8, content, "uds") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "listening on zix.sock") != null);
}

test "zix uds: serve, logSystem without a logger falls back to std.log" {
    logSystem(testConfig("zix.sock", null), .INFO, "fallback line {d}", .{1});
    logSystem(testConfig("zix.sock", null), .DEBUG, "fallback line {d}", .{2});
}

test "zix uds: serve, run with a path past the address limit is PathInvalid" {
    if (comptime !std.Io.net.has_unix_sockets) return error.SkipZigTest;

    // Console off: the expected error line must not reach std.log.err.
    var logger = try Logger.init(std.testing.allocator, .{});
    defer logger.deinit();

    const long_path: [std.Io.net.UnixAddress.max_len + 1]u8 = @splat('a');

    try std.testing.expectError(
        Error.ZixUds_Serve_PathInvalid,
        run(testConfig(&long_path, &logger), handler_mod.echoHandler),
    );
}

test "zix uds: serve, run in a missing directory is ListenFailed" {
    if (comptime !std.Io.net.has_unix_sockets) return error.SkipZigTest;

    // Console off: the expected error line must not reach std.log.err.
    var logger = try Logger.init(std.testing.allocator, .{});
    defer logger.deinit();

    const config = testConfig("no-such-dir-for-zix-uds-tests/zix.sock", &logger);

    try std.testing.expectError(
        Error.ZixUds_Serve_ListenFailed,
        run(config, handler_mod.echoHandler),
    );
}

test "zix uds: serve, run echoes a frame and removes the socket on cancel" {
    if (comptime !linux_only) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.net.UnixAddress.max_len]u8 = undefined;
    const path = try testSocketPath(&path_buf, tmp, "serve.sock");

    var future = try std.testing.io.concurrent(run, .{
        testConfig(path, null),
        handler_mod.echoHandler,
    });

    const client = try testConnect(path);

    var write_buf: [64]u8 = undefined;
    var stream_writer = client.writer(std.testing.io, &write_buf);
    try frame.writeFrame(&stream_writer.interface, "ping");

    var read_buf: [64]u8 = undefined;
    var stream_reader = client.reader(std.testing.io, &read_buf);
    var out: [64]u8 = undefined;
    const reply = try frame.readFrame(&stream_reader.interface, &out);

    try std.testing.expectEqualStrings("ping", reply);

    client.close(std.testing.io);
    try future.cancel(std.testing.io);

    try std.testing.expectError(
        error.FileNotFound,
        tmp.dir.access(std.testing.io, "serve.sock", .{}),
    );
}

