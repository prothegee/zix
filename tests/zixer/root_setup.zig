//! Build the throwaway zixer root the runner drives.
//!
//! The demo site files live in examples/proxies, which is also a zixer root a
//! developer may already have a daemon on. The runner copies main.cfg and every
//! site file into its own root under tmp/ instead, so a run never touches that
//! daemon, never leaves a control socket behind in the repository, and proves
//! the demo configs work from any root. Paths inside the configs (public_dir,
//! tls_cert, upstreams) stay as written, because they are relative to where the
//! daemon runs, not to the root dir.

const std = @import("std");

/// Where the demo configs are read from.
pub const DEMO_ROOT: []const u8 = "examples/proxies";
/// Where the runner's own root is built. Under tmp/, which is not tracked.
pub const RUNNER_ROOT: []const u8 = "tmp/zixer_runner_root";

/// Largest config file the runner copies.
const MAX_CFG_BYTES: usize = 64 * 1024;

/// Create the runner root: main.cfg, sites/ with every demo site file, logs/.
///
/// Note:
/// - An earlier run's root is removed first, so a stale site file from a
///   renamed demo can never be started by mistake.
///
/// Param:
/// io - std.Io
/// allocator - std.mem.Allocator (holds one config file at a time)
///
/// Return:
/// - void, the root is ready for `zixer --dir <RUNNER_ROOT>`
/// - error when a demo config cannot be read or the root cannot be created
pub fn create(io: std.Io, allocator: std.mem.Allocator) !void {
    const cwd = std.Io.Dir.cwd();

    cwd.deleteTree(io, RUNNER_ROOT) catch {};
    try cwd.createDirPath(io, RUNNER_ROOT ++ "/sites");
    try cwd.createDirPath(io, RUNNER_ROOT ++ "/logs");

    try copyFile(io, allocator, DEMO_ROOT ++ "/main.cfg", RUNNER_ROOT ++ "/main.cfg");

    var sites = try cwd.openDir(io, DEMO_ROOT ++ "/sites", .{ .iterate = true });
    defer sites.close(io);

    var iter = sites.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind == .directory) continue;
        if (!std.mem.endsWith(u8, entry.name, ".cfg")) continue;

        const from = try std.fmt.allocPrint(allocator, "{s}/sites/{s}", .{ DEMO_ROOT, entry.name });
        defer allocator.free(from);

        const dest_path = try std.fmt.allocPrint(allocator, "{s}/sites/{s}", .{ RUNNER_ROOT, entry.name });
        defer allocator.free(dest_path);

        try copyFile(io, allocator, from, dest_path);
    }
}

/// Remove the runner root, control socket and all.
pub fn destroy(io: std.Io) void {
    std.Io.Dir.cwd().deleteTree(io, RUNNER_ROOT) catch {};
}

/// Copy one whole file, creating or truncating the destination.
fn copyFile(io: std.Io, allocator: std.mem.Allocator, from: []const u8, dest_path: []const u8) !void {
    const content = try std.Io.Dir.cwd().readFileAlloc(io, from, allocator, .limited(MAX_CFG_BYTES));
    defer allocator.free(content);

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dest_path, .data = content });
}
