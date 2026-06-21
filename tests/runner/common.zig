//! Shared utilities for test runners.

const std = @import("std");

// --------------------------------------------------------- //
// Runtime fallback note captured from a server's startup stderr (e.g. a server
// configured for io_uring that found io_uring unusable and fell back to EPOLL).
// Transparency: a passing test that silently ran a different model than asked
// would hide that, so waitForTcpPort scrapes the line and report() surfaces it.

var note_buf: [200]u8 = undefined;
var note_len: usize = 0;

/// Return and clear the most recent captured fallback note, if any.
pub fn takeFallbackNote() ?[]const u8 {
    if (note_len == 0) return null;

    const note = note_buf[0..note_len];
    note_len = 0;

    return note;
}

/// Print a PASS line for a runner test, surfacing any captured fallback note
/// (e.g. io_uring -> EPOLL) wrapped onto indented continuation lines so a long
/// reason does not run off one line. The first line keeps the note head up to
/// its ": " separator (the "(<errno>):" lead), then the remainder is word-wrapped
/// at WRAP columns under a 5-space indent aligned with the label. Consumes the note.
pub fn printPass(label: []const u8) void {
    const note = takeFallbackNote() orelse {
        std.debug.print("PASS {s}\n", .{label});
        return;
    };

    const INDENT = "     ";
    const WRAP: usize = 80;

    var rest = note;
    if (std.mem.indexOf(u8, note, ": ")) |ci| {
        std.debug.print("PASS {s} (NOTE: {s}\n", .{ label, note[0 .. ci + 1] });
        rest = note[ci + 2 ..];
    } else {
        std.debug.print("PASS {s} (NOTE:\n", .{label});
    }

    std.debug.print("{s}", .{INDENT});
    var line_len: usize = INDENT.len;
    var first = true;
    var it = std.mem.tokenizeScalar(u8, rest, ' ');
    while (it.next()) |word| {
        if (!first and line_len + 1 + word.len > WRAP) {
            std.debug.print("\n{s}{s}", .{ INDENT, word });
            line_len = INDENT.len + word.len;
        } else if (first) {
            std.debug.print("{s}", .{word});
            line_len += word.len;
            first = false;
        } else {
            std.debug.print(" {s}", .{word});
            line_len += 1 + word.len;
        }
    }

    std.debug.print(")\n", .{});
}

/// Read a server child's buffered startup stderr (non-blocking) and, if it logged
/// a runtime fallback, stash that line for report() to surface. Never blocks: the
/// fd is switched to non-blocking and read once (the startup lines are already in
/// the pipe by the time the listener accepts).
fn captureFallbackNote(child: *std.process.Child) void {
    const f = child.stderr orelse return;
    const fd = f.handle;
    const linux = std.os.linux;

    const cur = linux.fcntl(fd, std.posix.F.GETFL, 0);
    const nonblock: u32 = @bitCast(std.posix.O{ .NONBLOCK = true });
    _ = linux.fcntl(fd, std.posix.F.SETFL, cur | @as(usize, nonblock));

    var buf: [4096]u8 = undefined;
    const n = std.posix.read(fd, &buf) catch return;
    if (n == 0) return;

    const data = buf[0..n];
    const start = std.mem.indexOf(u8, data, "io_uring unavailable") orelse return;
    var line = data[start..];
    if (std.mem.indexOfScalar(u8, line, '\n')) |nl| line = line[0..nl];

    const copy_len = @min(line.len, note_buf.len);
    @memcpy(note_buf[0..copy_len], line[0..copy_len]);
    note_len = copy_len;
}

// --------------------------------------------------------- //

/// Poll TCP port until it accepts connections or timeout_ms elapses. On success,
/// scrape the server child's startup stderr for a runtime fallback note.
///
/// Param:
/// io - std.Io (used to attempt connect and sleep between retries)
/// child - *std.process.Child (the spawned server, for the fallback-note scrape)
/// port - u16 (port number on 127.0.0.1)
/// timeout_ms - u64 (maximum wait time in milliseconds)
///
/// Return:
/// - void on success
/// - error.ServerStartTimeout if port is not open within timeout_ms
pub fn waitForTcpPort(io: std.Io, child: *std.process.Child, port: u16, timeout_ms: u64) !void {
    note_len = 0;
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
        captureFallbackNote(child);

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
        .stderr = .pipe,
    });
}
