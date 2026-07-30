// Runs one runner check in a child copy of the runner, bounded in time.
//
// Why a separate process: a check that parks (a loopback round trip that never completes) cannot be
// unstuck from inside the runner. std.Io has no timed await for a function future, and Future.cancel
// is documented as not threadsafe, so an in-process check has no upper bound and a single park costs
// every check behind it. A child process does have a bound: the parent kills it, the park becomes an
// ordinary result, and the run reports the rest of the table.

const std = @import("std");

/// Argv flag that puts a runner copy into child mode: run one check by label, report it, exit.
pub const ONLY_FLAG = "--only";

/// Longest a single check attempt may take before the parent kills it.
///
/// Note:
/// - A healthy check finishes well inside a second, and the whole table inside ten.
/// - The floor is the child's own startup poll (common.START_TIMEOUT_MS, 12 seconds) plus the check
///   body, so this leaves 8 seconds of body slack over the slowest honest attempt.
pub const CHECK_TIMEOUT_MS: u32 = 20_000;

/// Longest child report this forwards. A PASS line is short. The longest case is a PASS carrying a
/// fallback note, which common.printPass wraps at 80 columns and which stays inside a few hundred
/// bytes.
pub const REPORT_MAX = 2048;

/// Exit codes a child uses to tell the parent what happened. The child has already printed its own
/// PASS or FAIL line, so the code only carries whether another attempt is worth spawning.
pub const Exit = struct {
    pub const PASSED: u8 = 0;
    pub const FAILED: u8 = 1;
    pub const RETRIABLE: u8 = 2;
};

/// Widest argv a check needs: the runner path, the flag, the label, then the check's server paths.
/// Arity is at most 2 in the table (uds-http and channel-ipc each take two server binaries).
const MAX_ARGV = 5;

pub const Verdict = enum {
    PASSED,
    FAILED,
    /// A transient startup symptom, worth respawning the whole check.
    RETRIABLE,
    /// The child blew CHECK_TIMEOUT_MS and was killed.
    TIMED_OUT,
};

pub const Result = struct {
    verdict: Verdict,
    /// The line the child printed, copied into the caller's buffer. Written by the parent instead
    /// when the child never got far enough to print one.
    report: []const u8,
};

/// Lay out the child's argv: the runner itself, the flag, the label, then that check's server paths.
fn buildArgv(
    self_exe: []const u8,
    label: []const u8,
    paths: []const []const u8,
    buf: *[MAX_ARGV][]const u8,
) []const []const u8 {
    std.debug.assert(paths.len <= MAX_ARGV - 3);

    buf[0] = self_exe;
    buf[1] = ONLY_FLAG;
    buf[2] = label;
    for (paths, 0..) |path, i| buf[3 + i] = path;

    return buf[0 .. 3 + paths.len];
}

/// Map a finished child's exit status onto a verdict.
fn verdictOf(term: std.process.Child.Term) Verdict {
    return switch (term) {
        .exited => |code| switch (code) {
            Exit.PASSED => .PASSED,
            Exit.RETRIABLE => .RETRIABLE,
            else => .FAILED,
        },
        // Signalled or stopped: the child never chose a code, and a crash is a real failure.
        else => .FAILED,
    };
}

/// Copy a child's report into the caller's buffer, truncating rather than dropping it.
fn copyReport(text: []const u8, buf: []u8) []const u8 {
    const len = @min(text.len, buf.len);
    @memcpy(buf[0..len], text[0..len]);

    return buf[0..len];
}

/// The report line for a check whose child never printed one: killed on the bound, or never spawned.
fn unreportedLine(label: []const u8, err: anyerror, buf: []u8) []const u8 {
    if (err == error.Timeout) {
        return std.fmt.bufPrint(buf, "FAIL {s}: no result in {d}s, child killed\n", .{
            label,
            CHECK_TIMEOUT_MS / 1000,
        }) catch buf[0..0];
    }

    return std.fmt.bufPrint(buf, "FAIL {s}: child {s}\n", .{ label, @errorName(err) }) catch buf[0..0];
}

/// Run one check in a child copy of the runner and wait for it, bounded by CHECK_TIMEOUT_MS.
///
/// Note:
/// - The child prints its own PASS or FAIL line. This forwards those bytes untouched rather than
///   reformatting them, so the wrapped fallback note the child built survives intact.
/// - A child killed on the bound leaves its own server child running, because a killed process runs
///   no defers. That orphan holds one port, and since every check owns a unique port nothing else in
///   the run can collide with it. It is also why a caller must not retry a TIMED_OUT check: a second
///   attempt would talk to the orphan instead of a fresh server.
///
/// Param:
/// io - std.Io
/// self_exe - []const u8 (argv[0] of the running runner, respawned as the child)
/// label - []const u8 (which check the child should run)
/// paths - []const []const u8 (that check's server binaries)
/// report_buf - []u8 (receives the report line, size it at REPORT_MAX)
///
/// Return:
/// - Result, whose `report` borrows report_buf
pub fn runIsolated(
    io: std.Io,
    self_exe: []const u8,
    label: []const u8,
    paths: []const []const u8,
    report_buf: []u8,
) Result {
    var argv_buf: [MAX_ARGV][]const u8 = undefined;
    const argv = buildArgv(self_exe, label, paths, &argv_buf);

    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();

    const finished = std.process.run(arena.allocator(), io, .{
        .argv = argv,
        .timeout = .{ .duration = .{
            .raw = std.Io.Duration.fromMilliseconds(@as(i64, CHECK_TIMEOUT_MS)),
            .clock = .real,
        } },
    }) catch |err| return .{
        .verdict = if (err == error.Timeout) .TIMED_OUT else .FAILED,
        .report = unreportedLine(label, err, report_buf),
    };

    return .{
        .verdict = verdictOf(finished.term),
        .report = copyReport(finished.stderr, report_buf),
    };
}

/// Re-emit a child's report on the parent's stderr, byte for byte.
///
/// Note:
/// - Forwarding rather than reformatting is what keeps every result in table order: the checks
///   finish in any order, but only the parent ever writes, and it writes as it awaits each slot.
pub fn forward(io: std.Io, text: []const u8) void {
    if (text.len == 0) return;

    std.Io.File.stderr().writeStreamingAll(io, text) catch {};
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //

test "zix runner: buildArgv lays out the runner, flag, label, then paths" {
    var buf: [MAX_ARGV][]const u8 = undefined;
    const argv = buildArgv("/cache/test-runner-all", "uds-http", &.{ "/bin/uds", "/bin/uds-http" }, &buf);

    try std.testing.expectEqual(@as(usize, 5), argv.len);
    try std.testing.expectEqualStrings("/cache/test-runner-all", argv[0]);
    try std.testing.expectEqualStrings(ONLY_FLAG, argv[1]);
    try std.testing.expectEqualStrings("uds-http", argv[2]);
    try std.testing.expectEqualStrings("/bin/uds", argv[3]);
    try std.testing.expectEqualStrings("/bin/uds-http", argv[4]);
}

test "zix runner: buildArgv on a single path check stops at four entries" {
    var buf: [MAX_ARGV][]const u8 = undefined;
    const argv = buildArgv("/cache/test-runner-all", "http", &.{"/bin/http"}, &buf);

    try std.testing.expectEqual(@as(usize, 4), argv.len);
    try std.testing.expectEqualStrings("/bin/http", argv[3]);
}

test "zix runner: verdictOf maps a zero exit to passed" {
    try std.testing.expectEqual(Verdict.PASSED, verdictOf(.{ .exited = Exit.PASSED }));
}

test "zix runner: verdictOf maps the retriable exit code to retriable" {
    try std.testing.expectEqual(Verdict.RETRIABLE, verdictOf(.{ .exited = Exit.RETRIABLE }));
}

test "zix runner: verdictOf maps a plain failure exit to failed" {
    try std.testing.expectEqual(Verdict.FAILED, verdictOf(.{ .exited = Exit.FAILED }));
}

test "zix runner: verdictOf treats an unknown exit code as failed" {
    try std.testing.expectEqual(Verdict.FAILED, verdictOf(.{ .exited = 42 }));
}

test "zix runner: verdictOf treats a child with no exit status as failed" {
    try std.testing.expectEqual(Verdict.FAILED, verdictOf(.{ .unknown = 0 }));
}

test "zix runner: verdictOf treats a signalled child as failed" {
    if (comptime @import("builtin").target.os.tag == .windows) {
        // windows region: std.posix.SIG is a separate enum there with no KILL member. A child that
        // dies without choosing an exit code lands on the same else arm either way, which the
        // unknown-status case above covers on every target.
        return error.SkipZigTest;
    }

    try std.testing.expectEqual(Verdict.FAILED, verdictOf(.{ .signal = std.posix.SIG.KILL }));
}

test "zix runner: copyReport passes a child line through unchanged" {
    var buf: [REPORT_MAX]u8 = undefined;
    const copied = copyReport("PASS http\n", &buf);

    try std.testing.expectEqualStrings("PASS http\n", copied);
}

test "zix runner: copyReport truncates rather than dropping an oversized line" {
    var buf: [4]u8 = undefined;
    const copied = copyReport("PASS http\n", &buf);

    try std.testing.expectEqualStrings("PASS", copied);
}

test "zix runner: copyReport on empty child output yields an empty line" {
    var buf: [REPORT_MAX]u8 = undefined;
    const copied = copyReport("", &buf);

    try std.testing.expectEqual(@as(usize, 0), copied.len);
}

test "zix runner: unreportedLine names the bound when the child was killed" {
    var buf: [REPORT_MAX]u8 = undefined;
    const line = unreportedLine("http1-timeout-resp", error.Timeout, &buf);

    try std.testing.expectEqualStrings("FAIL http1-timeout-resp: no result in 20s, child killed\n", line);
}

test "zix runner: unreportedLine names the error when the child never spawned" {
    var buf: [REPORT_MAX]u8 = undefined;
    const line = unreportedLine("http", error.FileNotFound, &buf);

    try std.testing.expectEqualStrings("FAIL http: child FileNotFound\n", line);
}

test "zix runner: unreportedLine yields an empty line when the buffer cannot hold it" {
    var buf: [4]u8 = undefined;
    const line = unreportedLine("http", error.Timeout, &buf);

    try std.testing.expectEqual(@as(usize, 0), line.len);
}
