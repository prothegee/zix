//! Shared utilities for test runners.

const std = @import("std");

// --------------------------------------------------------- //

/// Poll TCP port until it accepts connections or timeout_ms elapses.
///
/// Param:
/// io - std.Io (used to attempt connect and sleep between retries)
/// port - u16 (port number on 127.0.0.1)
/// timeout_ms - u64 (maximum wait time in milliseconds)
///
/// Return:
/// - void on success
/// - error.ServerStartTimeout if port is not open within timeout_ms
pub fn waitForTcpPort(io: std.Io, port: u16, timeout_ms: u64) !void {
    var elapsed: u64 = 0;

    while (elapsed < timeout_ms) {
        const addr = std.Io.net.IpAddress.parse("127.0.0.1", port) catch {
            std.Io.sleep(io, std.Io.Duration.fromMilliseconds(50), .awake) catch {};
            elapsed += 50;
            continue;
        };
        const stream = addr.connect(io, .{ .mode = .stream, .protocol = .tcp }) catch {
            std.Io.sleep(io, std.Io.Duration.fromMilliseconds(50), .awake) catch {};
            elapsed += 50;
            continue;
        };
        stream.close(io);

        return;
    }

    return error.ServerStartTimeout;
}

/// Poll a Unix socket path until it exists or timeout_ms elapses.
///
/// Param:
/// io - std.Io (used to check file existence and sleep between retries)
/// path - []const u8 (absolute socket file path)
/// timeout_ms - u64 (maximum wait time in milliseconds)
///
/// Return:
/// - void on success
/// - error.ServerStartTimeout if path does not appear within timeout_ms
pub fn waitForUdsSocket(io: std.Io, path: []const u8, timeout_ms: u64) !void {
    var elapsed: u64 = 0;

    while (elapsed < timeout_ms) {
        std.Io.Dir.accessAbsolute(io, path, .{}) catch {
            std.Io.sleep(io, std.Io.Duration.fromMilliseconds(50), .awake) catch {};
            elapsed += 50;
            continue;
        };

        return;
    }

    return error.ServerStartTimeout;
}

/// Spawn an executable as a background child process.
/// stdout, stdin, and stderr are suppressed.
///
/// Param:
/// io - std.Io
/// server_path - []const u8 (path to the server binary)
///
/// Return:
/// - std.process.Child on success
/// - error from std.process.spawn on failure
pub fn spawnServer(io: std.Io, server_path: []const u8) !std.process.Child {
    return std.process.spawn(io, .{
        .argv = &.{server_path},
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
}
