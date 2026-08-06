//! Files the runner's child processes write their stderr to.
//!
//! A child spawned with a stderr pipe stops the moment that pipe fills, and
//! nothing in the runner drains one. A daemon that panics writes its message
//! and its trace, fills the pipe, and then parks alive still holding every port
//! it bound, which reads as a row that produced no output at all. A file has no
//! such limit. It also outlives a child the parent had to kill, so a report can
//! quote what that child actually said.

const std = @import("std");

/// Directory inside a row's runner root that holds the stderr files.
const DIR_NAME: []const u8 = "logs";

/// File name the daemon's stderr goes to.
pub const DAEMON_NAME: []const u8 = "daemon.err";

/// Longest file name this builds, an upstream slot at its widest.
pub const MAX_NAME: usize = 32;

/// Longest path this builds: a runner root, the directory, and a name.
pub const MAX_PATH: usize = 160;

/// Bytes of a child's stderr a report quotes. Sized for a panic message plus
/// the head of its trace, which is what a wedged child leaves behind.
pub const TAIL_MAX: usize = 2048;

// --------------------------------------------------------- //

/// Build the path of one child's stderr file.
///
/// Param:
/// root - []const u8 (the row's runner root, cwd relative)
/// name - []const u8 (DAEMON_NAME or an upstreamName result)
/// buf - *[MAX_PATH]u8 (receives the path)
///
/// Return:
/// - []const u8 borrowing buf
/// - error.NoSpaceLeft when the root is longer than MAX_PATH allows
pub fn filePath(root: []const u8, name: []const u8, buf: *[MAX_PATH]u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "{s}/{s}/{s}", .{ root, DIR_NAME, name });
}

/// The stderr file name of one upstream, by its slot in the row's spec list.
///
/// Param:
/// index - usize (slot in the row's spec list, not the argv binary index)
/// buf - *[MAX_NAME]u8 (receives the name)
///
/// Return:
/// - []const u8 borrowing buf
pub fn upstreamName(index: usize, buf: *[MAX_NAME]u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "upstream-{d}.err", .{index});
}

/// Create one child's stderr file, truncating an earlier run's.
///
/// Note:
/// - The caller hands the file to std.process.spawn and closes its own copy
///   once the child holds it.
///
/// Param:
/// io - std.Io
/// root - []const u8 (the row's runner root, its logs directory must exist)
/// name - []const u8 (DAEMON_NAME or an upstreamName result)
///
/// Return:
/// - std.Io.File open for writing
/// - error when the path does not fit or the file cannot be created
pub fn create(io: std.Io, root: []const u8, name: []const u8) !std.Io.File {
    var path_buf: [MAX_PATH]u8 = undefined;
    const file_path = try filePath(root, name, &path_buf);

    return std.Io.Dir.cwd().createFile(io, file_path, .{});
}

/// Read the last bytes one child wrote to its stderr file.
///
/// Note:
/// - Every failure reads as "the child said nothing", because this only ever
///   decorates a report. A missing file is the normal case for a child that
///   exited quietly.
///
/// Param:
/// io - std.Io
/// root - []const u8 (the row's runner root)
/// name - []const u8 (DAEMON_NAME or an upstreamName result)
/// buf - []u8 (receives the tail, size it at TAIL_MAX)
///
/// Return:
/// - []const u8 borrowing buf, empty when the child wrote nothing
pub fn tail(io: std.Io, root: []const u8, name: []const u8, buf: []u8) []const u8 {
    var path_buf: [MAX_PATH]u8 = undefined;
    const file_path = filePath(root, name, &path_buf) catch return "";

    const file = std.Io.Dir.cwd().openFile(io, file_path, .{}) catch return "";
    defer file.close(io);

    const length = file.length(io) catch return "";
    if (length == 0 or buf.len == 0) return "";

    const want: usize = @intCast(@min(length, buf.len));
    const offset = length - want;

    const got = file.readPositionalAll(io, buf[0..want], offset) catch return "";

    return buf[0..got];
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //

test "zix zixer: child stderr, filePath joins the root, the directory, and the name" {
    var buf: [MAX_PATH]u8 = undefined;
    const built = try filePath("tmp/zixer_runner_http2", DAEMON_NAME, &buf);

    try std.testing.expectEqualStrings("tmp/zixer_runner_http2/logs/daemon.err", built);
}

test "zix zixer: child stderr, filePath refuses a root the buffer cannot hold" {
    var buf: [MAX_PATH]u8 = undefined;
    var long_root: [MAX_PATH]u8 = @splat('r');

    try std.testing.expectError(error.NoSpaceLeft, filePath(&long_root, DAEMON_NAME, &buf));
}

test "zix zixer: child stderr, upstreamName numbers each slot" {
    var buf: [MAX_NAME]u8 = undefined;

    try std.testing.expectEqualStrings("upstream-0.err", try upstreamName(0, &buf));
    try std.testing.expectEqualStrings("upstream-1.err", try upstreamName(1, &buf));
}

test "zix zixer: child stderr, tail reads back what a child wrote" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const root = "tmp/zixer_child_stderr_wrote";
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    try std.Io.Dir.cwd().createDirPath(io, root ++ "/" ++ DIR_NAME);

    const file = try create(io, root, DAEMON_NAME);
    try file.writeStreamingAll(io, "panic: reached unreachable code\n");
    file.close(io);

    var buf: [TAIL_MAX]u8 = undefined;
    const read_back = tail(io, root, DAEMON_NAME, &buf);

    try std.testing.expectEqualStrings("panic: reached unreachable code\n", read_back);
}

test "zix zixer: child stderr, tail keeps only the last bytes of a long file" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const root = "tmp/zixer_child_stderr_long";
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    try std.Io.Dir.cwd().createDirPath(io, root ++ "/" ++ DIR_NAME);

    const file = try create(io, root, DAEMON_NAME);
    try file.writeStreamingAll(io, "head bytes that fall off the front");
    try file.writeStreamingAll(io, "TAIL");
    file.close(io);

    var buf: [4]u8 = undefined;
    const read_back = tail(io, root, DAEMON_NAME, &buf);

    try std.testing.expectEqualStrings("TAIL", read_back);
}

test "zix zixer: child stderr, tail on a child that wrote nothing is empty" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const root = "tmp/zixer_child_stderr_quiet";
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    try std.Io.Dir.cwd().createDirPath(io, root ++ "/" ++ DIR_NAME);

    const file = try create(io, root, DAEMON_NAME);
    file.close(io);

    var buf: [TAIL_MAX]u8 = undefined;

    try std.testing.expectEqual(@as(usize, 0), tail(io, root, DAEMON_NAME, &buf).len);
}

test "zix zixer: child stderr, tail on an absent file is empty" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var buf: [TAIL_MAX]u8 = undefined;

    try std.testing.expectEqual(@as(usize, 0), tail(io, "tmp/zixer_child_stderr_absent", DAEMON_NAME, &buf).len);
}
