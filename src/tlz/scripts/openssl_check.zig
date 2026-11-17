//! TLZ scripts openssl_check
//!
//! ### file: src/tlz/scripts/openssl_check.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! The program behind `zig build openssl-check` (and `tlz-openssl-check` at the zix root):
//! probe OpenSSL again and compare it with what the build was configured with.
//!
//! ### note:
//!
//! Zig caches the configure result, so a changed OpenSSL can go unseen. This program
//! only reports: it never changes the build. A difference exits with 1.
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
const OpensslProbe = @import("OpensslProbe.zig");

// --------------------------------------------------------- //
// Private:

/// Exit code when the host matches the build.
const EXIT_MATCH: u8 = 0;

/// Exit code when the host differs from the build, or the check cannot run.
const EXIT_CHANGED: u8 = 1;

/// What the check found.
const Verdict = enum(u8) {
    MATCH,
    CHANGED,
};

/// Compare the configured state text with the state text found now.
///
/// Param:
/// configured - []const u8 (the state text the build was configured with)
/// now - []const u8 (the state text the probe found now)
///
/// Return:
/// - Verdict.MATCH when both are equal
/// - Verdict.CHANGED otherwise
fn verdictOf(configured: []const u8, now: []const u8) Verdict {
    if (std.mem.eql(u8, configured, now)) return .MATCH;

    return .CHANGED;
}

/// Log the result of the check.
fn report(
    verdict: Verdict,
    configured: []const u8,
    now: []const u8,
    result: *const OpensslProbe,
) void {
    switch (verdict) {
        .MATCH => std.log.info("tlz openssl-check: OpenSSL {s} ({s}), matches the build", .{
            now,
            result.sourceName(),
        }),
        .CHANGED => std.log.warn("tlz openssl-check: the build uses OpenSSL {s}, the host " ++
            "now has {s} ({s}). Clear the configure cache so the build probes again " ++
            "(zix root: zig build cleanup, otherwise remove .zig-cache).", .{
            configured,
            now,
            result.sourceName(),
        }),
    }

    if (result.belowFloor()) {
        std.log.warn("tlz openssl-check: OpenSSL {s} is below the supported {d}.{d}, " ++
            "the next configure stops the build", .{
            now,
            OpensslProbe.OPENSSL_FLOOR.major,
            OpensslProbe.OPENSSL_FLOOR.minor,
        });
    }
}

/// Run the check.
///
/// Param:
/// init - std.process.Init (args: the program, then the configured state text)
///
/// Return:
/// - EXIT_MATCH or EXIT_CHANGED
fn run(init: std.process.Init) u8 {
    const arena = init.arena.allocator();
    const args = init.minimal.args.toSlice(arena) catch |err| switch (err) {
        else => {
            std.log.err("tlz openssl-check: cannot read the arguments ({t})", .{err});
            return EXIT_CHANGED;
        },
    };
    if (args.len != 2) {
        std.log.err("tlz openssl-check: expected one argument, the configured state", .{});
        return EXIT_CHANGED;
    }

    const result = OpensslProbe.probe(
        arena,
        init.io,
        init.environ_map,
        builtin.os.tag,
    ) catch |err| switch (err) {
        error.Tlz_OpensslProbe_EnvDirInvalid => {
            std.log.err("tlz openssl-check: OPENSSL_DIR has no include/openssl/ssl.h", .{});
            return EXIT_CHANGED;
        },
        error.Tlz_OpensslProbe_OutOfMemory => {
            std.log.err("tlz openssl-check: out of memory while probing OpenSSL " ++
                "(joining a path or reading opensslv.h)", .{});
            return EXIT_CHANGED;
        },
    };

    var now_buf: [32]u8 = undefined;
    const now = result.stateText(&now_buf);
    const verdict = verdictOf(args[1], now);

    report(verdict, args[1], now, &result);

    return switch (verdict) {
        .MATCH => EXIT_MATCH,
        .CHANGED => EXIT_CHANGED,
    };
}

// --------------------------------------------------------- //
// Public:

pub fn main(init: std.process.Init) u8 {
    return run(init);
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "tlz scripts: openssl_check, verdictOf equal state is MATCH" {
    try std.testing.expectEqual(Verdict.MATCH, verdictOf("4.1.0", "4.1.0"));
}

test "tlz scripts: openssl_check, verdictOf a new version is CHANGED" {
    try std.testing.expectEqual(Verdict.CHANGED, verdictOf("3.6.5", "4.1.0"));
}

test "tlz scripts: openssl_check, verdictOf installed after configure is CHANGED" {
    try std.testing.expectEqual(Verdict.CHANGED, verdictOf("none", "3.5.2"));
}

test "tlz scripts: openssl_check, verdictOf removed after configure is CHANGED" {
    try std.testing.expectEqual(Verdict.CHANGED, verdictOf("4.1.0", "none"));
}

test "tlz scripts: openssl_check, verdictOf both unknown is MATCH" {
    try std.testing.expectEqual(Verdict.MATCH, verdictOf("unknown", "unknown"));
}

test "tlz scripts: openssl_check, exit codes differ" {
    try std.testing.expect(EXIT_MATCH != EXIT_CHANGED);
}

