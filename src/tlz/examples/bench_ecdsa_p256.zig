//! TLZ example bench_ecdsa_p256
//!
//! ### file: src/tlz/examples/bench_ecdsa_p256.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! What one ECDSA P-256 SHA-256 sign costs with the key type a `tlz.SigningKey`
//! holds, in us per sign.
//!
//! ### note:
//!
//! Build with `-Doptimize=ReleaseFast`. A Debug build measures the safety checks
//! rather than the signer. The quickest of ROUNDS is reported, not the mean. The
//! signature is checked by the std verifier before any timing. The reference is
//! `openssl speed ecdsap256`. Build with
//! `zig build example-bench_ecdsa_p256 -Doptimize=ReleaseFast` from `src/tlz`, then
//! run `./zig-out/bin/tlz-example-bench_ecdsa_p256-<arch>-<os>-fast`.
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
const tlz = @import("tlz");

// --------------------------------------------------------- //
// Private:

/// The ECDSA P-256 key pair type a `tlz.SigningKey` holds.
const KeyPair = @FieldType(tlz.SigningKey, "ecdsa_p256");

/// Signs one round does.
const ITERATIONS: usize = 10_000;

/// Rounds run per row. The quickest is what gets reported.
const ROUNDS: usize = 5;

/// The bytes every sign covers, about the size of a TLS 1.3 CertificateVerify input.
const MESSAGE = "tlz bench_ecdsa_p256: the bytes one TLS 1.3 CertificateVerify signs, " ++
    "64 spaces of context, the label, a zero byte, and the transcript hash.";

/// Nanoseconds since `started` on the monotonic clock.
fn since(io: std.Io, started: std.Io.Timestamp) u64 {
    const ended = std.Io.Timestamp.now(io, .awake);

    return @intCast(started.durationTo(ended).nanoseconds);
}

/// Sign ITERATIONS times, ROUNDS times over. No noise is passed, so every sign
/// takes the deterministic RFC 6979 nonce and the random source stays out.
///
/// Return:
/// - u64 (nanoseconds the quickest round took)
fn timeSign(io: std.Io, key_pair: KeyPair) !u64 {
    // One sign before the clock starts warms the code path.
    _ = try key_pair.sign(MESSAGE, null);

    var best: u64 = std.math.maxInt(u64);

    for (0..ROUNDS) |_| {
        const started = std.Io.Timestamp.now(io, .awake);

        for (0..ITERATIONS) |_| {
            const signature = try key_pair.sign(MESSAGE, null);
            std.mem.doNotOptimizeAway(signature);
        }

        best = @min(best, since(io, started));
    }

    return best;
}

/// Print the row: us per sign and signs per second.
fn printRow(elapsed: u64) void {
    const per_sign_ns = @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(ITERATIONS));
    const per_sign_us = per_sign_ns / @as(f64, std.time.ns_per_us);
    const rate = @as(f64, std.time.ns_per_s) / per_sign_ns;

    std.debug.print("{s: <14}{d: >10.2}{d: >12.0}\n", .{
        "ecdsa p256",
        per_sign_us,
        rate,
    });
}

// --------------------------------------------------------- //
// Public:

// main takes std.process.Init for io: the monotonic clock comes from it. The signs
// themselves touch no IO and no allocator.
pub fn main(init: std.process.Init) !void {
    const key_pair = try KeyPair.generateDeterministic(@splat(0x11));

    const check = try key_pair.sign(MESSAGE, null);
    try check.verify(MESSAGE, key_pair.public_key);

    std.debug.print("ecdsa p256 sign: {d} signs per round, quickest of {d} rounds\n\n", .{
        ITERATIONS,
        ROUNDS,
    });
    std.debug.print("{s: <14}{s: >10}{s: >12}\n", .{
        "key",
        "us/sign",
        "signs/s",
    });

    const elapsed = try timeSign(init.io, key_pair);

    printRow(elapsed);
}

