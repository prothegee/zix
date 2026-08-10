//! Drive the zixer binary: the daemon, and one site at a time.
//!
//! Every call here is what a reader would type by hand, so a runner failure
//! reproduces as a shell command. The daemon runs in the foreground as a child
//! of the row, and each site verb is a short bounded child of its own.

const std = @import("std");

const child_stderr = @import("child_stderr.zig");
const root_setup = @import("root_setup.zig");

/// Longest a `start`, `stop`, or `restart` verb may take before the row treats
/// the daemon as wedged.
const VERB_TIMEOUT_MS: u32 = 20_000;
/// Longest a row waits for the daemon to bind its control socket.
const SOCKET_TIMEOUT_MS: u64 = 12_000;
/// Poll gap while waiting for the control socket to appear.
const POLL_GAP_MS: u64 = 50;

/// Longest path this builds inside a runner root.
const MAX_INNER: usize = root_setup.MAX_ROOT + 64;

/// One running daemon, plus the root and the binary path its verbs are issued
/// with.
pub const Gateway = struct {
    zixer_path: []const u8,
    root: []const u8,
    child: std.process.Child,

    /// Ask the daemon to bind one site, by cfg file name.
    ///
    /// Return:
    /// - void when the site is serving
    /// - error.SiteStartFailed with the daemon's own reason on stderr
    pub fn startSite(gateway: *const Gateway, io: std.Io, name: []const u8) !void {
        try gateway.verb(io, "start", name, error.SiteStartFailed);
    }

    /// Ask the daemon to unbind one site. A stop that fails is reported, never
    /// swallowed: a port left bound breaks every later check.
    pub fn stopSite(gateway: *const Gateway, io: std.Io, name: []const u8) !void {
        try gateway.verb(io, "stop", name, error.SiteStopFailed);
    }

    /// Stop every site and the daemon with it, then reap the child.
    pub fn shutdown(gateway: *Gateway, io: std.Io) void {
        gateway.verb(io, "daemon", "stop", error.DaemonStopFailed) catch {
            gateway.child.kill(io);
            return;
        };

        _ = gateway.child.wait(io) catch {};
    }

    /// Run one zixer verb as a bounded child and require exit code 0.
    fn verb(gateway: *const Gateway, io: std.Io, command: []const u8, argument: []const u8, on_failure: anyerror) !void {
        var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
        defer arena.deinit();

        const finished = std.process.run(arena.allocator(), io, .{
            .argv = &.{ gateway.zixer_path, "--dir", gateway.root, command, argument },
            .timeout = .{ .duration = .{
                .raw = std.Io.Duration.fromMilliseconds(@as(i64, VERB_TIMEOUT_MS)),
                .clock = .real,
            } },
        }) catch return on_failure;

        switch (finished.term) {
            .exited => |code| if (code == 0) return,
            else => {},
        }

        std.Io.File.stderr().writeStreamingAll(io, finished.stdout) catch {};

        return on_failure;
    }
};

/// Start the daemon in the foreground and wait for its control socket.
///
/// Note:
/// - Foreground on purpose: the row owns the process, so a crashed daemon is
///   visible as a dead child rather than an orphan holding ports.
/// - Its stderr goes to a file, never a pipe. Nothing here drains a pipe, so a
///   daemon that panics would fill one and then park alive mid-write, holding
///   every port it bound. The file also survives a killed row, which is what
///   lets the parent quote the daemon's own words. See child_stderr.
///
/// Param:
/// io - std.Io
/// zixer_path - []const u8 (the gateway binary under test)
/// root - []const u8 (the row's runner root, from root_setup.rootPath)
///
/// Return:
/// - Gateway with the daemon serving
/// - error.ZixerDaemonStartTimeout when the control socket never appears
pub fn start(io: std.Io, zixer_path: []const u8, root: []const u8) !Gateway {
    const err_file = try child_stderr.create(io, root, child_stderr.DAEMON_NAME);
    defer err_file.close(io);

    var child = try std.process.spawn(io, .{
        .argv = &.{ zixer_path, "--dir", root, "daemon" },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .{ .file = err_file },
    });
    errdefer child.kill(io);

    var socket_buf: [MAX_INNER]u8 = undefined;
    const socket_path = try root_setup.innerPath(root, "control.sock", &socket_buf);

    var waited: u64 = 0;
    while (waited < SOCKET_TIMEOUT_MS) : (waited += POLL_GAP_MS) {
        if (std.Io.Dir.cwd().access(io, socket_path, .{})) |_| {
            return .{ .zixer_path = zixer_path, .root = root, .child = child };
        } else |_| {}

        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(POLL_GAP_MS), .awake) catch {};
    }

    return error.ZixerDaemonStartTimeout;
}
