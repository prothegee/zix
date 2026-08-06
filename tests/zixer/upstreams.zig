//! Spawn and reap the backend a demo proxies to.
//!
//! Each demo row names the upstream binaries it needs. They are ordinary
//! example servers: the runner starts them, waits until they answer, hands the
//! site to the daemon, and kills them once the check is done.

const std = @import("std");

const common = @import("runner_common");

const child_stderr = @import("child_stderr.zig");

/// How many upstream processes one demo row may need. round_robin needs two.
pub const MAX_PER_CHECK: usize = 2;

/// Fixed moment a datagram upstream gets to bind. A udp server has no accept
/// to poll, so there is nothing to connect to while waiting.
const UDP_BIND_MS: u64 = 400;

/// One upstream a demo needs: which binary, with what arguments, and how the
/// runner knows it is up.
pub const Spec = struct {
    /// Index into the runner's argv upstream paths.
    binary: usize,
    /// Extra arguments, i.e. the --port a second round-robin instance takes.
    args: []const []const u8 = &.{},
    /// Listening tcp port to poll, or null for a datagram upstream.
    tcp_port: ?u16 = null,
};

/// Upstream processes started for one demo row, killed together.
pub const Group = struct {
    children: [MAX_PER_CHECK]std.process.Child = undefined,
    len: usize = 0,

    /// Kill every process in the group. Called on both the pass and the fail
    /// path, so a failing check never leaves a port bound for the next one.
    pub fn kill(group: *Group, io: std.Io) void {
        var index: usize = 0;
        while (index < group.len) : (index += 1) {
            group.children[index].kill(io);
        }

        group.len = 0;
    }
};

/// Start every upstream one demo row needs and wait until each is answering.
///
/// Note:
/// - Each upstream's stderr goes to a file in the row's root, never a pipe.
///   Nothing here drains a pipe, so an upstream that panics would fill one and
///   then park alive still holding its port. The file also survives a row the
///   parent had to kill, so its report can quote what the upstream said.
/// - A file also means common.waitForTcpPort finds no stderr pipe to scrape,
///   so it captures no io_uring fallback note. These demo upstreams all run the
///   ASYNC model, which never emits one.
///
/// Param:
/// io - std.Io
/// root - []const u8 (the row's runner root, from root_setup.rootPath)
/// paths - []const []const u8 (upstream binary paths, in argv order)
/// specs - []const Spec (what this row needs)
///
/// Return:
/// - Group holding the live children
/// - error.ServerStartTimeout when a tcp upstream never accepts
pub fn start(io: std.Io, root: []const u8, paths: []const []const u8, specs: []const Spec) !Group {
    var group = Group{};
    errdefer group.kill(io);

    var needs_bind_wait = false;

    for (specs, 0..) |spec, slot| {
        var argv_buf: [4][]const u8 = undefined;
        argv_buf[0] = paths[spec.binary];
        for (spec.args, 0..) |arg, index| argv_buf[index + 1] = arg;

        var name_buf: [child_stderr.MAX_NAME]u8 = undefined;
        const err_file = try child_stderr.create(io, root, try child_stderr.upstreamName(slot, &name_buf));
        defer err_file.close(io);

        group.children[group.len] = try std.process.spawn(io, .{
            .argv = argv_buf[0 .. 1 + spec.args.len],
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .{ .file = err_file },
        });
        group.len += 1;

        if (spec.tcp_port) |port| {
            try common.waitForTcpPort(io, &group.children[group.len - 1], port, common.START_TIMEOUT_MS);
        } else {
            needs_bind_wait = true;
        }
    }

    if (needs_bind_wait) std.Io.sleep(io, std.Io.Duration.fromMilliseconds(UDP_BIND_MS), .awake) catch {};

    return group;
}
