//! Build the throwaway zixer root one demo row runs on.
//!
//! The demo site files live in examples/proxies, which is also a zixer root a
//! developer may already have a daemon on. A row copies main.cfg and every site
//! file into a root of its own under tmp/ instead, so a run never touches that
//! daemon, never leaves a control socket behind in the repository, and proves
//! the demo configs work from any root. Paths inside the configs (public_dir,
//! tls_cert, upstreams) stay as written, because they are relative to where the
//! daemon runs, not to the root dir.
//!
//! One root per row, named after the row: a row the parent had to kill leaves a
//! daemon still holding its control socket, and on Windows a file another
//! process holds open cannot be removed. A shared root would hand that orphan
//! to the next row.

const std = @import("std");

/// Where the demo configs are read from.
pub const DEMO_ROOT: []const u8 = "examples/proxies";

/// Prefix every row's root shares. Under tmp/, which is not tracked.
pub const ROOT_PREFIX: []const u8 = "tmp/zixer_runner_";

/// Longest root path this builds, the prefix plus a row label.
pub const MAX_ROOT: usize = 64;

/// Largest config file a row copies.
const MAX_CFG_BYTES: usize = 64 * 1024;

/// Longest path this builds inside a root.
const MAX_INNER: usize = MAX_ROOT + 64;

// --------------------------------------------------------- //

/// Build the root path one demo row runs on.
///
/// Param:
/// label - []const u8 (the row label, which is also the directory suffix)
/// buf - *[MAX_ROOT]u8 (receives the path)
///
/// Return:
/// - []const u8 borrowing buf
/// - error.NoSpaceLeft when the label is longer than MAX_ROOT allows
pub fn rootPath(label: []const u8, buf: *[MAX_ROOT]u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "{s}{s}", .{ ROOT_PREFIX, label });
}

/// Build a path inside one row's root.
///
/// Param:
/// root - []const u8 (from rootPath)
/// sub_path - []const u8 (relative to the root, i.e. "sites/http2.cfg")
/// buf - *[MAX_INNER]u8 (receives the path)
///
/// Return:
/// - []const u8 borrowing buf
/// - error.NoSpaceLeft when the joined path does not fit
pub fn innerPath(root: []const u8, sub_path: []const u8, buf: *[MAX_INNER]u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "{s}/{s}", .{ root, sub_path });
}

/// Create one row's root: main.cfg, sites/ with every demo site file, logs/.
///
/// Note:
/// - An earlier run's root of the same name is removed first, so a stale site
///   file from a renamed demo can never be started by mistake.
///
/// Param:
/// io - std.Io
/// allocator - std.mem.Allocator (holds one config file at a time)
/// root - []const u8 (from rootPath)
///
/// Return:
/// - void, the root is ready for `zixer --dir <root>`
/// - error when a demo config cannot be read or the root cannot be created
pub fn create(io: std.Io, allocator: std.mem.Allocator, root: []const u8) !void {
    const cwd = std.Io.Dir.cwd();

    cwd.deleteTree(io, root) catch {};

    var sites_buf: [MAX_INNER]u8 = undefined;
    const sites_dir = try innerPath(root, "sites", &sites_buf);
    try cwd.createDirPath(io, sites_dir);

    var logs_buf: [MAX_INNER]u8 = undefined;
    const logs_dir = try innerPath(root, "logs", &logs_buf);
    try cwd.createDirPath(io, logs_dir);

    var main_buf: [MAX_INNER]u8 = undefined;
    const main_dest = try innerPath(root, "main.cfg", &main_buf);
    try copyFile(io, allocator, DEMO_ROOT ++ "/main.cfg", main_dest);

    var sites = try cwd.openDir(io, DEMO_ROOT ++ "/sites", .{ .iterate = true });
    defer sites.close(io);

    var iter = sites.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind == .directory) continue;
        if (!std.mem.endsWith(u8, entry.name, ".cfg")) continue;

        const from = try std.fmt.allocPrint(allocator, "{s}/sites/{s}", .{ DEMO_ROOT, entry.name });
        defer allocator.free(from);

        const dest_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ sites_dir, entry.name });
        defer allocator.free(dest_path);

        try copyFile(io, allocator, from, dest_path);
    }
}

/// Remove one row's root, control socket and all.
///
/// Note:
/// - Best effort. A row the parent killed leaves a daemon holding files there,
///   and on Windows those cannot be removed while it lives.
pub fn destroy(io: std.Io, root: []const u8) void {
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
}

/// Copy one whole file, creating or truncating the destination.
fn copyFile(io: std.Io, allocator: std.mem.Allocator, from: []const u8, dest_path: []const u8) !void {
    const content = try std.Io.Dir.cwd().readFileAlloc(io, from, allocator, .limited(MAX_CFG_BYTES));
    defer allocator.free(content);

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dest_path, .data = content });
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //

test "zix zixer: root setup, rootPath names a directory after the row" {
    var buf: [MAX_ROOT]u8 = undefined;

    try std.testing.expectEqualStrings("tmp/zixer_runner_http2", try rootPath("http2", &buf));
    try std.testing.expectEqualStrings("tmp/zixer_runner_round-robin", try rootPath("round-robin", &buf));
}

test "zix zixer: root setup, rootPath refuses a label the buffer cannot hold" {
    var buf: [MAX_ROOT]u8 = undefined;
    var long_label: [MAX_ROOT]u8 = @splat('x');

    try std.testing.expectError(error.NoSpaceLeft, rootPath(&long_label, &buf));
}

test "zix zixer: root setup, innerPath joins the root and the sub path" {
    var buf: [MAX_INNER]u8 = undefined;

    try std.testing.expectEqualStrings("tmp/zixer_runner_http2/sites", try innerPath("tmp/zixer_runner_http2", "sites", &buf));
    try std.testing.expectEqualStrings("tmp/zixer_runner_http2/control.sock", try innerPath("tmp/zixer_runner_http2", "control.sock", &buf));
}
