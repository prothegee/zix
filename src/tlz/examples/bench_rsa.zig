//! TLZ example bench_rsa
//!
//! ### file: src/tlz/examples/bench_rsa.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! What one RSA sign costs for 2048, 3072, and 4096 bit keys, with PKCS#1 v1.5 and
//! with PSS (the TLS 1.3 CertificateVerify padding), in ms per sign.
//!
//! ### note:
//!
//! Build with `-Doptimize=ReleaseFast`. A Debug build measures the safety checks
//! rather than the signer. The quickest of ROUNDS is reported, not the mean. Every
//! signature is checked by the std verifier before any timing. The reference is
//! `openssl speed rsa2048 rsa3072 rsa4096` (PKCS#1 v1.5). Build with
//! `zig build example-bench_rsa -Doptimize=ReleaseFast` from `src/tlz`, then run
//! `./zig-out/bin/tlz-example-bench_rsa-<arch>-<os>-fast`.
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

const StdRsa = std.crypto.Certificate.rsa;
const Sha256 = std.crypto.hash.sha2.Sha256;

// --------------------------------------------------------- //
// Private:

/// The RSA private key type a `tlz.SigningKey` holds.
const RsaKey = @FieldType(tlz.SigningKey, "rsa");

/// Signs one round does.
const ITERATIONS: usize = 100;

/// Rounds run per row. The quickest is what gets reported.
const ROUNDS: usize = 5;

/// The bytes every sign covers, about the size of a TLS 1.3 CertificateVerify input.
const MESSAGE = "tlz bench_rsa: the bytes one TLS 1.3 CertificateVerify signs, " ++
    "64 spaces of context, the label, a zero byte, and the transcript hash.";

/// Room for the decoded key DER, the 4096 bit key is about 2.4 KB.
const DER_BYTES = 4096;

/// Room for the widest signature, RSA-4096.
const SIGNATURE_BYTES = 512;

/// The public exponent of every key here (openssl genpkey default).
const PUBLIC_EXPONENT = [_]u8{
    0x01,
    0x00,
    0x01,
};

/// One key width and its PKCS#8 PEM.
const KeyCase = struct {
    bits: usize,
    pem: []const u8,
};

const KEYS = [_]KeyCase{
    .{
        .bits = 2048,
        .pem = @embedFile("certs/rsa_2048_key.pem"),
    },
    .{
        .bits = 3072,
        .pem = @embedFile("certs/rsa_3072_key.pem"),
    },
    .{
        .bits = 4096,
        .pem = @embedFile("certs/rsa_4096_key.pem"),
    },
};

/// Which RSA signature padding a row signs with.
const Padding = enum {
    PKCS1V15,
    PSS,
};

const PADDINGS = [_]Padding{
    .PKCS1V15,
    .PSS,
};

/// Nanoseconds since `started` on the monotonic clock.
fn since(io: std.Io, started: std.Io.Timestamp) u64 {
    const ended = std.Io.Timestamp.now(io, .awake);

    return @intCast(started.durationTo(ended).nanoseconds);
}

/// Decode one PKCS#8 PEM into the tlz RSA key.
fn loadKey(pem: []const u8) !RsaKey {
    var der_buf: [DER_BYTES]u8 = undefined;
    const der = try tlz.pemToDer(&der_buf, pem);

    return RsaKey.fromDer(der, true);
}

/// Sign MESSAGE once with one padding. The PSS salt is fixed, so the cost of the
/// random source stays out of the number.
fn signOnce(key: *const RsaKey, comptime padding: Padding, out: []u8) ![]const u8 {
    const salt: [Sha256.digest_length]u8 = @splat(0x5a);

    return switch (padding) {
        .PKCS1V15 => key.signPkcs1v15(MESSAGE, out),
        .PSS => key.signPss(MESSAGE, salt, out),
    };
}

/// Sign ITERATIONS times, ROUNDS times over.
///
/// Return:
/// - u64 (nanoseconds the quickest round took)
fn timeSign(io: std.Io, key: *const RsaKey, comptime padding: Padding) !u64 {
    var out: [SIGNATURE_BYTES]u8 = undefined;

    // One sign before the clock starts warms the code path.
    _ = try signOnce(key, padding, &out);

    var best: u64 = std.math.maxInt(u64);

    for (0..ROUNDS) |_| {
        const started = std.Io.Timestamp.now(io, .awake);

        for (0..ITERATIONS) |_| {
            const signature = try signOnce(key, padding, &out);
            std.mem.doNotOptimizeAway(signature.ptr);
        }

        best = @min(best, since(io, started));
    }

    return best;
}

/// Check both paddings sign bytes the std verifier accepts, so the table times
/// real signatures.
fn checkSignatures(comptime bits: usize, key: *const RsaKey) !void {
    const modulus_len = bits / 8;
    const public_key = try StdRsa.PublicKey.fromBytes(&PUBLIC_EXPONENT, key.modulus());

    var out: [SIGNATURE_BYTES]u8 = undefined;

    const v15 = try signOnce(key, .PKCS1V15, &out);
    try tlz.verifyRsaPkcs1v15(modulus_len, v15[0..modulus_len], MESSAGE, public_key, Sha256);

    const pss = try signOnce(key, .PSS, &out);
    try tlz.verifyRsaPss(modulus_len, pss[0..modulus_len], MESSAGE, public_key, Sha256);
}

/// Print one row: ms per sign and signs per second.
fn printRow(bits: usize, padding: Padding, elapsed: u64) void {
    const per_sign_ns = @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(ITERATIONS));
    const per_sign_ms = per_sign_ns / @as(f64, std.time.ns_per_ms);
    const rate = @as(f64, std.time.ns_per_s) / per_sign_ns;

    std.debug.print("rsa{d: <8}{s: <12}{d: >10.3}{d: >12.1}\n", .{
        bits,
        @tagName(padding),
        per_sign_ms,
        rate,
    });
}

// --------------------------------------------------------- //
// Public:

// main takes std.process.Init for io: the monotonic clock comes from it. The signs
// themselves touch no IO and no allocator.
pub fn main(init: std.process.Init) !void {
    std.debug.print("rsa sign: {d} signs per round, quickest of {d} rounds\n\n", .{
        ITERATIONS,
        ROUNDS,
    });
    std.debug.print("{s: <11}{s: <12}{s: >10}{s: >12}\n", .{
        "key",
        "padding",
        "ms/sign",
        "signs/s",
    });

    inline for (KEYS) |case| {
        const key = try loadKey(case.pem);

        try checkSignatures(case.bits, &key);

        inline for (PADDINGS) |padding| {
            const elapsed = try timeSign(init.io, &key, padding);

            printRow(case.bits, padding, elapsed);
        }
    }
}

