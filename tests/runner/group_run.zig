// Runs a child process under a time bound and, when the bound fires, ends the child together with
// the processes it spawned.
//
// Why not std.process.run: its timeout kills the direct child only. A runner check spawns a server
// of its own, so killing just the check leaves that server listening on the check's port, and that
// orphan is what made a killed check unsafe to attempt again. Here the child puts itself in a
// process group of its own (leadOwnGroup) and the bound signals the whole group, so the server goes
// with it and the next attempt starts from nothing.
//
// std.process.SpawnOptions carries a pgid field, but zig 0.16 never applies it, so the grouping has
// to be done by the child once it is running.
//
// Note on coverage: the tests below cover what a caller observes (exit status, stderr, and that a
// child does not outlive its bound). The group leadership itself is not unit tested, because the
// only way to build a grouped child here is to move the test binary's own process group, which
// would cost it the signals its parent sends. The runner exercises that path on every CI leg.

const std = @import("std");
const builtin = @import("builtin");

/// Bytes of headroom kept ahead of the stderr read cursor, matching what std.process.run reserves.
const RESERVE: usize = 64;

/// Whether a child killed on its bound is killed together with the processes it spawned.
///
/// Note:
/// - POSIX groups them, so one signal reaches all of them. Windows has no equivalent here, so a
///   killed child there still leaves its own children running, and a caller has to treat that
///   outcome as final rather than start an attempt that would talk to the orphan.
pub const REAPS_GROUP: bool = builtin.os.tag != .windows;

/// What a bounded run ended as.
pub const Outcome = struct {
    /// How the child exited, or null when the bound fired and it was killed instead.
    term: ?std.process.Child.Term,
    /// What the child wrote to stderr, allocated from the caller's allocator. Empty when the bound
    /// fired: a killed child's partial output is not a result, and the caller words its own line.
    stderr: []const u8,
};

/// Put this process in a process group of its own, so a parent that bounds it can end this process
/// and everything it spawns with one signal. A bounded child calls this once, before it spawns
/// anything.
///
/// Note:
/// - Nothing to do on Windows, and nothing to do about a failure either: the way this fails on
///   POSIX is that the process already leads a group, which is the state being asked for.
/// - The trade is that a caller leaves the terminal's foreground group, so a Ctrl+C at an
///   interactive prompt no longer reaches it. Its parent still ends it on the bound, so the cost is
///   an abandoned run leaving children alive for the rest of one bound instead of dying at once.
///
/// Return:
/// - void
pub fn leadOwnGroup() void {
    switch (comptime builtin.os.tag) {
        .windows => {},
        .linux => _ = std.os.linux.setpgid(0, 0),
        else => _ = std.c.setpgid(0, 0),
    }
}

/// Kill the process group the child leads, which is the child plus everything it spawned.
/// A child that already exited leaves no group, and that is not an error worth reporting.
fn killGroup(child_id: std.process.Child.Id) void {
    switch (comptime builtin.os.tag) {
        .windows => {},
        else => std.posix.kill(-child_id, std.posix.SIG.KILL) catch {},
    }
}

/// Run argv as a child process, collect its stderr, and give it timeout_ms to finish.
///
/// Note:
/// - stdout is discarded. A bounded child reports on stderr, and a pipe nobody reads is somewhere a
///   chatty child can block for good.
/// - When the bound fires the group is killed before this returns, so the pipe has no writer left
///   and the reader teardown that follows finishes instead of waiting on a live child.
///
/// Param:
/// gpa - std.mem.Allocator (allocates the returned stderr)
/// io - std.Io
/// argv - []const []const u8 (program path followed by its arguments)
/// timeout_ms - u32 (how long the child may take before its group is killed)
///
/// Return:
/// - Outcome, whose term is null when the bound fired
/// - error from the spawn, from reading stderr, or from the wait
pub fn runBounded(
    gpa: std.mem.Allocator,
    io: std.Io,
    argv: []const []const u8,
    timeout_ms: u32,
) !Outcome {
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .pipe,
    });
    defer child.kill(io);

    var streams: std.Io.File.MultiReader.Buffer(1) = undefined;
    var stderr_reader: std.Io.File.MultiReader = undefined;
    stderr_reader.init(gpa, io, streams.toStreams(), &.{child.stderr.?});
    defer stderr_reader.deinit();

    const bound: std.Io.Timeout = .{ .duration = .{
        .raw = std.Io.Duration.fromMilliseconds(@as(i64, timeout_ms)),
        .clock = .real,
    } };

    var over_bound = false;
    while (stderr_reader.fill(RESERVE, bound)) |_| {} else |err| switch (err) {
        error.EndOfStream => {},
        error.Timeout => over_bound = true,
        else => |other| return other,
    }

    if (over_bound) {
        // Still set: the id is only cleared once the child has been waited for, which the deferred
        // kill below does after this returns.
        if (child.id) |child_id| killGroup(child_id);

        return .{ .term = null, .stderr = "" };
    }

    try stderr_reader.checkAnyError();

    const term = try child.wait(io);

    return .{ .term = term, .stderr = try stderr_reader.toOwnedSlice(0) };
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //

/// Shell the child tests run their one-liners through. POSIX only, which is what gates those tests.
const SHELL: []const u8 = "/bin/sh";

/// Whether the child tests below can run here. They drive a POSIX shell, and killGroup is a no-op
/// on Windows anyway, so there is nothing for them to observe there.
const CHILD_TESTS_RUN: bool = builtin.os.tag != .windows;

test "zix runner: group_run reaps a killed child's group everywhere but windows" {
    try std.testing.expectEqual(builtin.os.tag != .windows, REAPS_GROUP);
}

test "zix runner: group_run runBounded reports a child's exit code" {
    if (comptime !CHILD_TESTS_RUN) {
        std.log.info("zix runner: group_run child tests need a POSIX shell, skipped on this platform", .{});
        return;
    }

    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const outcome = try runBounded(arena.allocator(), io, &.{ SHELL, "-c", "exit 7" }, 5_000);

    try std.testing.expectEqual(@as(u8, 7), outcome.term.?.exited);
}

test "zix runner: group_run runBounded hands back what the child wrote to stderr" {
    if (comptime !CHILD_TESTS_RUN) {
        std.log.info("zix runner: group_run child tests need a POSIX shell, skipped on this platform", .{});
        return;
    }

    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const outcome = try runBounded(arena.allocator(), io, &.{ SHELL, "-c", "printf 'PASS http\\n' >&2" }, 5_000);

    try std.testing.expectEqualStrings("PASS http\n", outcome.stderr);
}

test "zix runner: group_run runBounded discards what the child wrote to stdout" {
    if (comptime !CHILD_TESTS_RUN) {
        std.log.info("zix runner: group_run child tests need a POSIX shell, skipped on this platform", .{});
        return;
    }

    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const outcome = try runBounded(arena.allocator(), io, &.{ SHELL, "-c", "printf 'noise'" }, 5_000);

    try std.testing.expectEqual(@as(u8, 0), outcome.term.?.exited);
    try std.testing.expectEqual(@as(usize, 0), outcome.stderr.len);
}

test "zix runner: group_run runBounded reports no term for a child that outlives the bound" {
    if (comptime !CHILD_TESTS_RUN) {
        std.log.info("zix runner: group_run child tests need a POSIX shell, skipped on this platform", .{});
        return;
    }

    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const outcome = try runBounded(arena.allocator(), io, &.{ SHELL, "-c", "sleep 30" }, 300);

    try std.testing.expectEqual(null, outcome.term);
    try std.testing.expectEqual(@as(usize, 0), outcome.stderr.len);
}

test "zix runner: group_run runBounded returns while a killed child still had output to come" {
    if (comptime !CHILD_TESTS_RUN) {
        std.log.info("zix runner: group_run child tests need a POSIX shell, skipped on this platform", .{});
        return;
    }

    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // Writes a line, then holds the pipe open well past the bound. The early bytes are not a
    // verdict, so the bound path drops them rather than reporting half a result.
    const script = "printf 'PASS partial\\n' >&2; sleep 30";
    const outcome = try runBounded(arena.allocator(), io, &.{ SHELL, "-c", script }, 400);

    try std.testing.expectEqual(null, outcome.term);
    try std.testing.expectEqual(@as(usize, 0), outcome.stderr.len);
}

test "zix runner: group_run runBounded surfaces a program that does not exist" {
    if (comptime !CHILD_TESTS_RUN) {
        std.log.info("zix runner: group_run child tests need a POSIX shell, skipped on this platform", .{});
        return;
    }

    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectError(
        error.FileNotFound,
        runBounded(arena.allocator(), io, &.{"/nonexistent/zix-group-run-probe"}, 5_000),
    );
}
