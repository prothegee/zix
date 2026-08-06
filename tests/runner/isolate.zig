// Runs one runner check in a child copy of the runner, bounded in time.
//
// Why a separate process: a check that parks (a loopback round trip that never completes) cannot be
// unstuck from inside the runner. std.Io has no timed await for a function future, and Future.cancel
// is documented as not threadsafe, so an in-process check has no upper bound and a single park costs
// every check behind it. A child process does have a bound: the parent kills it, the park becomes an
// ordinary result, and the run reports the rest of the table.

const std = @import("std");
const group_run = @import("group_run.zig");

/// Argv flag that puts a runner copy into child mode: run one check by label, report it, exit.
pub const ONLY_FLAG = "--only";

/// Longest a single check attempt may take before the parent kills it, tuned for native speed.
///
/// Note:
/// - A healthy check finishes well inside a second, and the whole table inside ten.
/// - The floor is the child's own startup poll (common.START_TIMEOUT_MS, 12 seconds) plus the check
///   body, so this leaves 8 seconds of body slack over the slowest honest attempt.
/// - A slow host widens the live bound through CHECK_TIMEOUT_ENV (see checkTimeoutMs).
pub const CHECK_TIMEOUT_MS: u32 = 20_000;

/// Environment variable that widens CHECK_TIMEOUT_MS on a slow host. The value is milliseconds.
/// The qemu CI legs set it: on a shared host the VM can stall one child for tens of seconds while
/// its neighbors finish in milliseconds, and the native bound then kills a healthy check.
pub const CHECK_TIMEOUT_ENV = "ZIX_CHECK_TIMEOUT_MS";

/// Resolve the live check bound from the CHECK_TIMEOUT_ENV value.
///
/// Note:
/// - The env can only widen the bound. A narrower one would kill children still inside their
///   startup poll, so anything unparsable or below the default falls back to CHECK_TIMEOUT_MS.
///
/// Param:
/// env_value - ?[]const u8 (raw environment value, null when the variable is unset)
///
/// Return:
/// - u32 (milliseconds, never below CHECK_TIMEOUT_MS)
pub fn checkTimeoutMs(env_value: ?[]const u8) u32 {
    const text = env_value orelse return CHECK_TIMEOUT_MS;
    const parsed = std.fmt.parseInt(u32, text, 10) catch return CHECK_TIMEOUT_MS;

    return @max(parsed, CHECK_TIMEOUT_MS);
}

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
    /// The child blew the check bound and was killed.
    TIMED_OUT,
};

/// Whether an error is a transient symptom worth respawning the whole check for, versus a real
/// failure. Most are connection-establishment errors: under a startup burst a fresh server's accept
/// path is starved, so the probe or first client connect is refused, reset, or times out. A real
/// check failure is an assertion (UnexpectedStatus, UnexpectedBody, ...), never on this list.
///
/// Note:
/// - ResponseTimeout and ReadTimeout are the same transient shape one step later: the server
///   accepted and then went quiet, and a respawn clears it. They only reach here because the check
///   clients carry common.RESPONSE_TIMEOUT_MS. Without that bound the identical condition is an
///   infinite park, which no retry can see, and the run dies where it stands.
/// - These are safe to retry for a reason of their own: the check returned an error, so its defers
///   ran and its server is gone. A killed check needs its server taken down another way, which is
///   what RETRY_TIMED_OUT covers.
///
/// Param:
/// err - anyerror (what the check body returned)
///
/// Return:
/// - true when another attempt is worth spawning
pub fn isRetriable(err: anyerror) bool {
    return switch (err) {
        error.ServerStartTimeout,
        error.ConnectFailed,
        error.ConnectionRefused,
        error.ConnectionResetByPeer,
        error.ConnectionTimedOut,
        error.BrokenPipe,
        error.ResponseTimeout,
        error.ReadTimeout,
        => true,
        else => false,
    };
}

/// Whether a TIMED_OUT check is worth another attempt.
///
/// Note:
/// - The kill takes the child's whole process group where the platform has one (see
///   group_run.REAPS_GROUP), so the check's server dies with it and the next attempt starts from
///   nothing. Where it does not, the killed child leaves that server listening and a second attempt
///   would talk to the orphan, which is worse than reporting the timeout.
/// - A park that is real rather than a host stall still gets reported: the attempt cap ends the
///   retries and the last attempt's line stands.
pub const RETRY_TIMED_OUT: bool = group_run.REAPS_GROUP;

/// Max attempts for a check whose attempt hit a transient startup error (a fresh server's accept
/// threads starved by a concurrent startup burst, so the probe or first client connect is refused).
/// Respawning the whole check almost always clears it. Real assertion failures are never retried.
pub const MAX_ATTEMPTS: usize = 3;

/// Max attempts for a check whose attempt blew its bound and was killed. Lower than MAX_ATTEMPTS
/// because each of these costs a full timeout_ms of wall clock, and the CI legs that see them run
/// the whole leg under one step cap. One more attempt is enough: on a shared host the park is a
/// stall of that one process, and a process spawned a moment later does not inherit it.
pub const MAX_TIMEOUT_ATTEMPTS: usize = 2;

/// How many attempts a verdict is allowed in total. One means the result stands as it is.
///
/// Param:
/// verdict - Verdict (what the attempt just finished as)
///
/// Return:
/// - usize (total attempts allowed, never below 1)
pub fn attemptCap(verdict: Verdict) usize {
    return switch (verdict) {
        .RETRIABLE => MAX_ATTEMPTS,
        .TIMED_OUT => if (RETRY_TIMED_OUT) MAX_TIMEOUT_ATTEMPTS else 1,
        .PASSED, .FAILED => 1,
    };
}

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
fn unreportedLine(label: []const u8, err: anyerror, timeout_ms: u32, buf: []u8) []const u8 {
    if (err == error.Timeout) {
        return std.fmt.bufPrint(buf, "FAIL {s}: no result in {d}s, child killed\n", .{
            label,
            timeout_ms / 1000,
        }) catch buf[0..0];
    }

    return std.fmt.bufPrint(buf, "FAIL {s}: child {s}\n", .{ label, @errorName(err) }) catch buf[0..0];
}

/// Run one check in a child copy of the runner and wait for it, bounded by timeout_ms.
///
/// Note:
/// - The child prints its own PASS or FAIL line. This forwards those bytes untouched rather than
///   reformatting them, so the wrapped fallback note the child built survives intact.
/// - A killed child runs no defers, so the server it spawned has to be taken down from outside.
///   group_run does that by killing the child's whole process group where the platform has one, and
///   RETRY_TIMED_OUT says whether that happened, which is what decides if a caller may attempt the
///   check again.
///
/// Param:
/// io - std.Io
/// self_exe - []const u8 (argv[0] of the running runner, respawned as the child)
/// label - []const u8 (which check the child should run)
/// paths - []const []const u8 (that check's server binaries)
/// timeout_ms - u32 (kill bound for this attempt, from checkTimeoutMs)
/// report_buf - []u8 (receives the report line, size it at REPORT_MAX)
///
/// Return:
/// - Result, whose `report` borrows report_buf
pub fn runIsolated(
    io: std.Io,
    self_exe: []const u8,
    label: []const u8,
    paths: []const []const u8,
    timeout_ms: u32,
    report_buf: []u8,
) Result {
    var argv_buf: [MAX_ARGV][]const u8 = undefined;
    const argv = buildArgv(self_exe, label, paths, &argv_buf);

    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();

    const outcome = group_run.runBounded(arena.allocator(), io, argv, timeout_ms) catch |err| return .{
        .verdict = .FAILED,
        .report = unreportedLine(label, err, timeout_ms, report_buf),
    };

    const term = outcome.term orelse return .{
        .verdict = .TIMED_OUT,
        .report = unreportedLine(label, error.Timeout, timeout_ms, report_buf),
    };

    return .{
        .verdict = verdictOf(term),
        .report = copyReport(outcome.stderr, report_buf),
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

test "zix runner: isRetriable accepts a connection-establishment error" {
    try std.testing.expect(isRetriable(error.ServerStartTimeout));
    try std.testing.expect(isRetriable(error.ConnectionRefused));
    try std.testing.expect(isRetriable(error.BrokenPipe));
}

test "zix runner: isRetriable accepts a server that accepted then went quiet" {
    try std.testing.expect(isRetriable(error.ResponseTimeout));
    try std.testing.expect(isRetriable(error.ReadTimeout));
}

test "zix runner: isRetriable refuses an assertion failure" {
    try std.testing.expect(!isRetriable(error.UnexpectedStatus));
    try std.testing.expect(!isRetriable(error.UnexpectedBody));
    try std.testing.expect(!isRetriable(error.MissingExpectedSubstring));
}

test "zix runner: verdictOf treats a signalled child as failed" {
    if (comptime @import("builtin").target.os.tag == .windows) {
        // windows region: std.posix.SIG is a separate enum there with no KILL member. A child that
        // dies without choosing an exit code lands on the same else arm either way, which the
        // unknown-status case above covers on every target.
        std.log.info("zix runner: std.posix.SIG has no KILL on windows, signalled-child case skipped", .{});
        return;
    }

    try std.testing.expectEqual(Verdict.FAILED, verdictOf(.{ .signal = std.posix.SIG.KILL }));
}

test "zix runner: a timed-out check is worth another attempt only where the group is reaped" {
    try std.testing.expectEqual(group_run.REAPS_GROUP, RETRY_TIMED_OUT);
}

test "zix runner: attemptCap lets a settled verdict stand on its first attempt" {
    try std.testing.expectEqual(@as(usize, 1), attemptCap(.PASSED));
    try std.testing.expectEqual(@as(usize, 1), attemptCap(.FAILED));
}

test "zix runner: attemptCap gives a transient startup error the full run of attempts" {
    try std.testing.expectEqual(MAX_ATTEMPTS, attemptCap(.RETRIABLE));
}

test "zix runner: attemptCap gives a killed check one more attempt where the group is reaped" {
    const expected: usize = if (RETRY_TIMED_OUT) MAX_TIMEOUT_ATTEMPTS else 1;

    try std.testing.expectEqual(expected, attemptCap(.TIMED_OUT));
}

test "zix runner: a killed check costs less wall clock than a refused one" {
    try std.testing.expect(MAX_TIMEOUT_ATTEMPTS < MAX_ATTEMPTS);
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
    const line = unreportedLine("http1-timeout-resp", error.Timeout, CHECK_TIMEOUT_MS, &buf);

    try std.testing.expectEqualStrings("FAIL http1-timeout-resp: no result in 20s, child killed\n", line);
}

test "zix runner: unreportedLine names a widened bound in whole seconds" {
    var buf: [REPORT_MAX]u8 = undefined;
    const line = unreportedLine("http-websocket", error.Timeout, 60_000, &buf);

    try std.testing.expectEqualStrings("FAIL http-websocket: no result in 60s, child killed\n", line);
}

test "zix runner: unreportedLine names the error when the child never spawned" {
    var buf: [REPORT_MAX]u8 = undefined;
    const line = unreportedLine("http", error.FileNotFound, CHECK_TIMEOUT_MS, &buf);

    try std.testing.expectEqualStrings("FAIL http: child FileNotFound\n", line);
}

test "zix runner: unreportedLine yields an empty line when the buffer cannot hold it" {
    var buf: [4]u8 = undefined;
    const line = unreportedLine("http", error.Timeout, CHECK_TIMEOUT_MS, &buf);

    try std.testing.expectEqual(@as(usize, 0), line.len);
}

test "zix runner: checkTimeoutMs on an unset variable keeps the default" {
    try std.testing.expectEqual(CHECK_TIMEOUT_MS, checkTimeoutMs(null));
}

test "zix runner: checkTimeoutMs widens the bound from a valid value" {
    try std.testing.expectEqual(@as(u32, 60_000), checkTimeoutMs("60000"));
}

test "zix runner: checkTimeoutMs refuses to narrow below the default" {
    try std.testing.expectEqual(CHECK_TIMEOUT_MS, checkTimeoutMs("5000"));
}

test "zix runner: checkTimeoutMs on an unparsable value keeps the default" {
    try std.testing.expectEqual(CHECK_TIMEOUT_MS, checkTimeoutMs("60s"));
    try std.testing.expectEqual(CHECK_TIMEOUT_MS, checkTimeoutMs(""));
}
