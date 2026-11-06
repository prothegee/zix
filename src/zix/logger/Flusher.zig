//! ZIX Logger Flusher
//!
//! ### file: src/zix/logger/Flusher.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Background thread that owns every logger write syscall.
//!
//! ### note:
//!
//! The context is type erased on purpose. A generic parameter here would make
//! the logger struct depend on a generic instantiated over itself.
//!
//! ---------------------------------------------------------
//!
//! ### licenses:
//!
//! - BSD-3-Clause
//!
//! ### copyright:
//!
//! - (c) Prana Ron // @prothegee // prothegee@pm.me
//!
//! ### contributors:
//!
//! - Prana Ron // @prothegee // prothegee@pm.me
//!

const std = @import("std");
const builtin = @import("builtin");

// --------------------------------------------------------- //
// Fields:

thread: ?std.Thread = null,
stopping: std.atomic.Value(bool) = .init(false),
context: ?*anyopaque = null,
pump: ?*const fn (*anyopaque, bool) bool = null,

const Self = @This();

// --------------------------------------------------------- //
// Private:

/// Quiet passes before the nap lengthens.
const PASSES_BEFORE_BACKOFF: u32 = 64;

fn sleepNs(nanoseconds: u64) void {
    if (nanoseconds == 0) return;

    if (comptime builtin.os.tag == .windows) {
        const interval: std.os.windows.LARGE_INTEGER =
            -@as(i64, @intCast(nanoseconds / 100));
        _ = std.os.windows.ntdll.NtDelayExecution(.FALSE, &interval);

        return;
    }

    const seconds = nanoseconds / std.time.ns_per_s;
    const remainder = nanoseconds % std.time.ns_per_s;

    if (comptime builtin.os.tag == .linux) {
        const request = std.os.linux.timespec{
            .sec = @intCast(seconds),
            .nsec = @intCast(remainder),
        };
        _ = std.os.linux.nanosleep(&request, null);

        return;
    }

    const request = std.posix.timespec{
        .sec = @intCast(seconds),
        .nsec = @intCast(remainder),
    };
    _ = std.c.nanosleep(&request, null);
}

fn loop(self: *Self) void {
    const context = self.context.?;
    const pump = self.pump.?;

    var quiet_passes: u32 = 0;
    var since_linger_ns: u64 = 0;

    while (!self.stopping.load(.acquire)) {
        if (pump(context, true)) {
            quiet_passes = 0;
            since_linger_ns = 0;

            continue;
        }

        quiet_passes +|= 1;
        const nap = if (quiet_passes > PASSES_BEFORE_BACKOFF)
            IDLE_NAP_NS
        else
            BUSY_NAP_NS;
        sleepNs(nap);
        since_linger_ns +|= nap;

        if (since_linger_ns >= LINGER_NS) {
            since_linger_ns = 0;
            _ = pump(context, false);
        }
    }

    _ = pump(context, false);
}

// --------------------------------------------------------- //
// Public:

/// ZIX Logger Flusher error
pub const Error = error{
    ZixLogger_Flusher_SpawnFailed,
};

/// How long the thread naps while a burst may still be in progress.
pub const BUSY_NAP_NS: u64 = 20 * std.time.ns_per_us;

/// How long the thread naps once a burst is well and truly over.
pub const IDLE_NAP_NS: u64 = 2 * std.time.ns_per_ms;

/// How long buffered records may sit before a trickle is written out.
pub const LINGER_NS: u64 = 2 * std.time.ns_per_ms;

/// Spawn the thread. Calling this twice without a stop is caller error.
pub fn start(
    self: *Self,
    context: *anyopaque,
    pump: *const fn (*anyopaque, bool) bool,
) Error!void {
    self.context = context;
    self.pump = pump;
    self.stopping.store(false, .release);

    self.thread = std.Thread.spawn(.{}, loop, .{self}) catch |err| switch (err) {
        else => return Error.ZixLogger_Flusher_SpawnFailed,
    };
}

/// Stop the thread and wait for it. Safe when it never started.
pub fn stop(self: *Self) void {
    const thread = self.thread orelse return;

    self.stopping.store(true, .release);
    thread.join();

    self.thread = null;
    self.context = null;
    self.pump = null;
}

pub fn running(self: *const Self) bool {
    return self.thread != null;
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const Counter = struct {
    passes: std.atomic.Value(u32) = .init(0),

    fn pump(context: *anyopaque, urgent_only: bool) bool {
        const self: *Counter = @ptrCast(@alignCast(context));
        _ = urgent_only;
        _ = self.passes.fetchAdd(1, .acq_rel);

        return false;
    }
};

test "zix logger: Flusher, stop on a never-started thread does nothing" {
    var flusher = Self{};

    try std.testing.expect(!flusher.running());
    flusher.stop();
    try std.testing.expect(!flusher.running());
}

test "zix logger: Flusher, the thread runs passes until stopped" {
    var counter = Counter{};
    var flusher = Self{};

    try flusher.start(&counter, Counter.pump);
    try std.testing.expect(flusher.running());

    sleepNs(20 * std.time.ns_per_ms);

    flusher.stop();

    const passes = counter.passes.load(.acquire);
    try std.testing.expect(passes >= 2);
    try std.testing.expect(!flusher.running());
}

test "zix logger: Flusher, stop runs one final pass" {
    var counter = Counter{};
    var flusher = Self{};

    try flusher.start(&counter, Counter.pump);
    flusher.stop();

    try std.testing.expect(counter.passes.load(.acquire) >= 1);
}

test "zix logger: Flusher, a flusher can be restarted after a stop" {
    var counter = Counter{};
    var flusher = Self{};

    try flusher.start(&counter, Counter.pump);
    flusher.stop();
    const after_first = counter.passes.load(.acquire);

    try flusher.start(&counter, Counter.pump);
    flusher.stop();

    try std.testing.expect(counter.passes.load(.acquire) > after_first);
}

