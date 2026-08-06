//! Run one zixer demo row in a child copy of the runner, bounded in time.
//!
//! Why a separate process: a row whose client parks (an edge that accepted the
//! connection and then went quiet) cannot be unstuck from inside the runner.
//! std.Io has no timed await for a function future, so an in-process row has no
//! upper bound, and one park costs every row behind it plus every line they
//! would have printed. A child process does have a bound: the parent kills it,
//! the park becomes an ordinary FAIL line, and the run still reports the rest
//! of the table.

const std = @import("std");

/// Argv flag that puts a runner copy into child mode: run one row, report it,
/// and exit.
pub const ONLY_FLAG: []const u8 = "--only";

/// Environment variable that widens ROW_TIMEOUT_MS on a slow host, in
/// milliseconds. Shared with the zix protocol runner so one CI leg sets one
/// knob for both.
pub const ROW_TIMEOUT_ENV: []const u8 = "ZIX_CHECK_TIMEOUT_MS";

/// Longest one row may take before the parent kills it.
///
/// Note:
/// - A healthy row finishes inside a second, and the whole table inside ten.
/// - The floor is what a row already bounds itself: an upstream start poll of
///   12 seconds plus a site verb of 20. A row that is only slow reports its own
///   error, this bound exists for the one that never returns at all.
pub const ROW_TIMEOUT_MS: u32 = 45_000;

/// Exit codes a child uses. The child prints its own PASS or FAIL line, so the
/// code only carries whether the row passed.
pub const Exit = struct {
    pub const PASSED: u8 = 0;
    pub const FAILED: u8 = 1;
};

/// Longest child report this forwards. A row prints one line.
pub const REPORT_MAX: usize = 2048;

/// Upstream binary paths one child may carry, matching the runner's table.
pub const MAX_UPSTREAM_PATHS: usize = 16;

/// Widest argv a row needs: the runner, the flag, the label, the gateway
/// binary, then every upstream path.
const MAX_ARGV: usize = 4 + MAX_UPSTREAM_PATHS;

/// How one row ended, from the parent's side.
pub const Verdict = enum {
    PASSED,
    FAILED,
    /// The child blew the row bound and was killed.
    TIMED_OUT,
};

pub const Result = struct {
    verdict: Verdict,
    /// The line the child printed, copied into the caller's buffer. Written by
    /// the parent instead when the child never got far enough to print one.
    report: []const u8,
};

// --------------------------------------------------------- //

/// Resolve the live row bound from the ROW_TIMEOUT_ENV value.
///
/// Note:
/// - The environment can only widen the bound. A narrower one would kill rows
///   still inside their own start polls, so anything unparsable or below the
///   default falls back to ROW_TIMEOUT_MS.
///
/// Param:
/// env_value - ?[]const u8 (raw environment value, null when unset)
///
/// Return:
/// - u32 (milliseconds, never below ROW_TIMEOUT_MS)
pub fn rowTimeoutMs(env_value: ?[]const u8) u32 {
    const text = env_value orelse return ROW_TIMEOUT_MS;
    const parsed = std.fmt.parseInt(u32, text, 10) catch return ROW_TIMEOUT_MS;

    return @max(parsed, ROW_TIMEOUT_MS);
}

/// Lay out the child's argv: the runner, the flag, the label, the gateway, then
/// every upstream path in table order.
fn buildArgv(
    self_exe: []const u8,
    label: []const u8,
    zixer_path: []const u8,
    paths: []const []const u8,
    buf: *[MAX_ARGV][]const u8,
) []const []const u8 {
    std.debug.assert(paths.len <= MAX_UPSTREAM_PATHS);

    buf[0] = self_exe;
    buf[1] = ONLY_FLAG;
    buf[2] = label;
    buf[3] = zixer_path;
    for (paths, 0..) |path, index| buf[4 + index] = path;

    return buf[0 .. 4 + paths.len];
}

/// Map a finished child's exit status onto a verdict.
fn verdictOf(term: std.process.Child.Term) Verdict {
    return switch (term) {
        .exited => |code| if (code == Exit.PASSED) .PASSED else .FAILED,
        // Signalled or stopped: the child never chose a code, and a crash is a
        // real failure.
        else => .FAILED,
    };
}

/// Copy a child's report into the caller's buffer, truncating rather than
/// dropping it.
fn copyReport(text: []const u8, buf: []u8) []const u8 {
    const len = @min(text.len, buf.len);
    @memcpy(buf[0..len], text[0..len]);

    return buf[0..len];
}

/// The report line for a row whose child never printed one: killed on the
/// bound, or never spawned.
fn unreportedLine(label: []const u8, err: anyerror, timeout_ms: u32, buf: []u8) []const u8 {
    if (err == error.Timeout) {
        return std.fmt.bufPrint(buf, "FAIL zixer-{s}: no result in {d}s, child killed\n", .{
            label,
            timeout_ms / 1000,
        }) catch buf[0..0];
    }

    return std.fmt.bufPrint(buf, "FAIL zixer-{s}: child {s}\n", .{ label, @errorName(err) }) catch buf[0..0];
}

/// Run one row in a child copy of the runner and wait for it, bounded by
/// timeout_ms.
///
/// Note:
/// - The child prints its own PASS or FAIL line. This forwards those bytes
///   untouched rather than reformatting them.
/// - A child killed on the bound runs no defers, so its daemon and upstreams
///   stay alive holding their ports. Every row owns its own ports and its own
///   runner root, so nothing later in the table can collide with that orphan.
///
/// Param:
/// io - std.Io
/// self_exe - []const u8 (argv[0] of the running runner, respawned as the child)
/// label - []const u8 (which row the child should run)
/// zixer_path - []const u8 (the gateway binary under test)
/// paths - []const []const u8 (every upstream binary, in table order)
/// timeout_ms - u32 (kill bound for this row, from rowTimeoutMs)
/// report_buf - []u8 (receives the report line, size it at REPORT_MAX)
///
/// Return:
/// - Result, whose report borrows report_buf
pub fn runRow(
    io: std.Io,
    self_exe: []const u8,
    label: []const u8,
    zixer_path: []const u8,
    paths: []const []const u8,
    timeout_ms: u32,
    report_buf: []u8,
) Result {
    var argv_buf: [MAX_ARGV][]const u8 = undefined;
    const argv = buildArgv(self_exe, label, zixer_path, paths, &argv_buf);

    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();

    const finished = std.process.run(arena.allocator(), io, .{
        .argv = argv,
        .timeout = .{ .duration = .{
            .raw = std.Io.Duration.fromMilliseconds(@as(i64, timeout_ms)),
            .clock = .real,
        } },
    }) catch |err| return .{
        .verdict = if (err == error.Timeout) .TIMED_OUT else .FAILED,
        .report = unreportedLine(label, err, timeout_ms, report_buf),
    };

    return .{
        .verdict = verdictOf(finished.term),
        .report = copyReport(finished.stderr, report_buf),
    };
}

/// Re-emit a child's report on the parent's stderr, byte for byte.
pub fn forward(io: std.Io, text: []const u8) void {
    if (text.len == 0) return;

    std.Io.File.stderr().writeStreamingAll(io, text) catch {};
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //

test "zix zixer: row isolate, buildArgv lays out the runner, flag, label, gateway, then upstreams" {
    var buf: [MAX_ARGV][]const u8 = undefined;
    const argv = buildArgv("/cache/zixer-test-runner-all", "http2", "/bin/zixer", &.{ "/bin/up0", "/bin/up1" }, &buf);

    try std.testing.expectEqual(@as(usize, 6), argv.len);
    try std.testing.expectEqualStrings("/cache/zixer-test-runner-all", argv[0]);
    try std.testing.expectEqualStrings(ONLY_FLAG, argv[1]);
    try std.testing.expectEqualStrings("http2", argv[2]);
    try std.testing.expectEqualStrings("/bin/zixer", argv[3]);
    try std.testing.expectEqualStrings("/bin/up0", argv[4]);
    try std.testing.expectEqualStrings("/bin/up1", argv[5]);
}

test "zix zixer: row isolate, buildArgv with no upstream paths stops at four entries" {
    var buf: [MAX_ARGV][]const u8 = undefined;
    const argv = buildArgv("/cache/zixer-test-runner-all", "static", "/bin/zixer", &.{}, &buf);

    try std.testing.expectEqual(@as(usize, 4), argv.len);
    try std.testing.expectEqualStrings("/bin/zixer", argv[3]);
}

test "zix zixer: row isolate, verdictOf maps a zero exit to passed" {
    try std.testing.expectEqual(Verdict.PASSED, verdictOf(.{ .exited = Exit.PASSED }));
}

test "zix zixer: row isolate, verdictOf maps a non-zero exit to failed" {
    try std.testing.expectEqual(Verdict.FAILED, verdictOf(.{ .exited = Exit.FAILED }));
    try std.testing.expectEqual(Verdict.FAILED, verdictOf(.{ .exited = 42 }));
}

test "zix zixer: row isolate, verdictOf treats a child with no exit status as failed" {
    try std.testing.expectEqual(Verdict.FAILED, verdictOf(.{ .unknown = 0 }));
}

test "zix zixer: row isolate, copyReport passes a child line through unchanged" {
    var buf: [REPORT_MAX]u8 = undefined;

    try std.testing.expectEqualStrings("PASS zixer-http2 (http2.cfg)\n", copyReport("PASS zixer-http2 (http2.cfg)\n", &buf));
}

test "zix zixer: row isolate, copyReport truncates rather than dropping an oversized line" {
    var buf: [4]u8 = undefined;

    try std.testing.expectEqualStrings("PASS", copyReport("PASS zixer-http2\n", &buf));
}

test "zix zixer: row isolate, copyReport on empty child output yields an empty line" {
    var buf: [REPORT_MAX]u8 = undefined;

    try std.testing.expectEqual(@as(usize, 0), copyReport("", &buf).len);
}

test "zix zixer: row isolate, unreportedLine names the bound when the child was killed" {
    var buf: [REPORT_MAX]u8 = undefined;
    const line = unreportedLine("http2", error.Timeout, ROW_TIMEOUT_MS, &buf);

    try std.testing.expectEqualStrings("FAIL zixer-http2: no result in 45s, child killed\n", line);
}

test "zix zixer: row isolate, unreportedLine names a widened bound in whole seconds" {
    var buf: [REPORT_MAX]u8 = undefined;
    const line = unreportedLine("http3", error.Timeout, 60_000, &buf);

    try std.testing.expectEqualStrings("FAIL zixer-http3: no result in 60s, child killed\n", line);
}

test "zix zixer: row isolate, unreportedLine names the error when the child never spawned" {
    var buf: [REPORT_MAX]u8 = undefined;
    const line = unreportedLine("grpc", error.FileNotFound, ROW_TIMEOUT_MS, &buf);

    try std.testing.expectEqualStrings("FAIL zixer-grpc: child FileNotFound\n", line);
}

test "zix zixer: row isolate, unreportedLine yields an empty line when the buffer cannot hold it" {
    var buf: [4]u8 = undefined;

    try std.testing.expectEqual(@as(usize, 0), unreportedLine("http2", error.Timeout, ROW_TIMEOUT_MS, &buf).len);
}

test "zix zixer: row isolate, rowTimeoutMs on an unset variable keeps the default" {
    try std.testing.expectEqual(ROW_TIMEOUT_MS, rowTimeoutMs(null));
}

test "zix zixer: row isolate, rowTimeoutMs widens the bound from a valid value" {
    try std.testing.expectEqual(@as(u32, 60_000), rowTimeoutMs("60000"));
}

test "zix zixer: row isolate, rowTimeoutMs refuses to narrow below the default" {
    try std.testing.expectEqual(ROW_TIMEOUT_MS, rowTimeoutMs("5000"));
}

test "zix zixer: row isolate, rowTimeoutMs on an unparsable value keeps the default" {
    try std.testing.expectEqual(ROW_TIMEOUT_MS, rowTimeoutMs("60s"));
    try std.testing.expectEqual(ROW_TIMEOUT_MS, rowTimeoutMs(""));
}
