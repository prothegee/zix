//! ZIX utils compression brotli distance
//!
//! ### file: src/zix/utils/compression/brotli/distance.zig
//! 
//! ### author: Prana Ron
//! 
//! ---------------------------------------------------------
//! 
//! ### brief:
//! 
//! Distance codes (RFC 7932 sec 4): decode a code into a backward distance, and
//! pick the cheapest code for a distance when encoding.
//! 
//! ### note:
//! 
//! The encoder side uses NPOSTFIX=0 and NDIRECT=0 only.
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
const BitReader = @import("BitReader.zig");
const DistanceRing = @import("DistanceRing.zig");

// --------------------------------------------------------- //
// Private:

/// Short code offsets for codes 4..9 (last) and 10..15 (second to last).
const SHORT_OFFSETS = [_]i64{ -1, 1, -2, 2, -3, 3 };

fn readerError(err: BitReader.Error) Error {
    @branchHint(.cold);

    return switch (err) {
        error.ZixUtils_BrotliBitReader_Truncated => Error.ZixUtils_BrotliDistance_Truncated,
    };
}

/// Resolve a short code 0..15 against the ring (sec 4).
///
/// Param:
/// code - u16 (0..15)
/// ring - *const DistanceRing (recent distances)
///
/// Return:
/// - i64 (may be <= 0 for an invalid reference)
fn shortDistance(code: u16, ring: *const DistanceRing) i64 {
    if (code < 4) return ring.dist[code];

    const slot: usize = if (code < 10) 0 else 1;
    const offset_index: usize = if (code < 10) code - 4 else code - 10;

    return @as(i64, ring.dist[slot]) + SHORT_OFFSETS[offset_index];
}

/// The short code 0..15 that resolves to value, or null.
///
/// Param:
/// ring - DistanceRing (recent distances)
/// value - u32 (backward distance)
///
/// Return:
/// - ?u16
fn matchRingCode(ring: DistanceRing, value: u32) ?u16 {
    for (ring.dist, 0..) |recent, index| {
        if (value == recent) return @intCast(index);
    }

    for (SHORT_OFFSETS, 0..) |offset, index| {
        const candidate = @as(i64, ring.dist[0]) + offset;
        if (candidate > 0 and candidate == value) return @intCast(4 + index);
    }

    for (SHORT_OFFSETS, 0..) |offset, index| {
        const candidate = @as(i64, ring.dist[1]) + offset;
        if (candidate > 0 and candidate == value) return @intCast(10 + index);
    }

    return null;
}

// --------------------------------------------------------- //
// Public:

pub const Error = error {
    ZixUtils_BrotliDistance_Truncated,
    ZixUtils_BrotliDistance_Malformed,
};

/// A decoded distance and whether it goes into the ring.
pub const Distance = struct {
    value: u32,
    push: bool,
};

/// A distance code with its extra bits, for the encoder.
pub const DistanceCode = struct {
    code: u16,
    extra: u32,
    nextra: u6,
};

/// Decode one distance code into a backward distance (sec 4).
///
/// Param:
/// reader - *BitReader (stream, for the extra bits)
/// code - u16 (distance symbol)
/// ring - *const DistanceRing (recent distances)
/// npostfix - u32 (NPOSTFIX, 0..3)
/// ndirect - u32 (NDIRECT)
///
/// Return:
/// - Distance
/// - Error.ZixUtils_BrotliDistance_Malformed for a short code that resolves <= 0
/// - Error.ZixUtils_BrotliDistance_Truncated past the end
pub fn read(
    reader: *BitReader,
    code: u16,
    ring: *const DistanceRing,
    npostfix: u32,
    ndirect: u32,
) Error!Distance {
    if (code < 16) {
        const value = shortDistance(code, ring);
        if (value <= 0) return Error.ZixUtils_BrotliDistance_Malformed;

        return .{
            .value = @intCast(value),
            .push = code != 0,
        };
    }

    if (code < 16 + ndirect) {
        return .{
            .value = code - 16 + 1,
            .push = true,
        };
    }

    const dadj: u32 = code - ndirect - 16;
    const ndistbits: u5 = @intCast(1 + (dadj >> @intCast(npostfix + 1)));
    const dextra: u64 = reader.readBits(ndistbits) catch |err| return readerError(err);
    const postfix_mask: u32 = (@as(u32, 1) << @intCast(npostfix)) - 1;
    const hcode: u32 = dadj >> @intCast(npostfix);
    const lcode: u32 = dadj & postfix_mask;
    const offset: u64 = (@as(u64, 2 + (hcode & 1)) << ndistbits) - 4;
    const value: u64 = ((offset + dextra) << @intCast(npostfix)) + lcode + ndirect + 1;

    if (value > std.math.maxInt(u32)) return Error.ZixUtils_BrotliDistance_Malformed;

    return .{
        .value = @intCast(value),
        .push = true,
    };
}

/// Encode a distance as an explicit code (NPOSTFIX=0, NDIRECT=0), the inverse of
/// read. The even and odd series tile 1, 2, 3, ... exactly.
///
/// Param:
/// value - u32 (backward distance, 1..2^24)
///
/// Return:
/// - DistanceCode
pub fn explicitCode(value: u32) DistanceCode {
    var nbits: u5 = 1;
    while (nbits < 25) : (nbits += 1) {
        const span = @as(u32, 1) << nbits;

        const even_base = (@as(u32, 2) << nbits) - 3;
        if (value >= even_base and value < even_base + span) {
            return .{
                .code = 16 + 2 * (@as(u16, nbits) - 1),
                .extra = value - even_base,
                .nextra = nbits,
            };
        }

        const odd_base = (@as(u32, 3) << nbits) - 3;
        if (value >= odd_base and value < odd_base + span) {
            return .{
                .code = 16 + 2 * (@as(u16, nbits) - 1) + 1,
                .extra = value - odd_base,
                .nextra = nbits,
            };
        }
    }

    // Every distance in a 2^24 window lands in a bucket with nbits <= 24.
    unreachable;
}

/// Pick the cheapest code for value and advance the ring exactly as the decoder does.
///
/// Param:
/// ring - *DistanceRing (recent distances, updated)
/// value - u32 (backward distance)
///
/// Return:
/// - DistanceCode
pub fn choose(ring: *DistanceRing, value: u32) DistanceCode {
    if (matchRingCode(ring.*, value)) |code| {
        if (code != 0) ring.push(value);

        return .{
            .code = code,
            .extra = 0,
            .nextra = 0,
        };
    }

    const explicit = explicitCode(value);
    ring.push(value);

    return explicit;
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "zix utils compression brotli: distance, short code 0 is the last distance" {
    var reader = BitReader.init(&.{});
    const ring: DistanceRing = .{};
    const result = try read(&reader, 0, &ring, 0, 0);

    try std.testing.expectEqual(@as(u32, 4), result.value);
    try std.testing.expect(!result.push);
}

test "zix utils compression brotli: distance, short code 5 adds one to the last" {
    var reader = BitReader.init(&.{});
    const ring: DistanceRing = .{};
    const result = try read(&reader, 5, &ring, 0, 0);

    try std.testing.expectEqual(@as(u32, 5), result.value);
    try std.testing.expect(result.push);
}

test "zix utils compression brotli: distance, short code below one is malformed" {
    var reader = BitReader.init(&.{});
    var ring: DistanceRing = .{};
    ring.push(1);

    try std.testing.expectError(
        Error.ZixUtils_BrotliDistance_Malformed,
        read(&reader, 8, &ring, 0, 0),
    );
}

test "zix utils compression brotli: distance, direct code maps straight" {
    var reader = BitReader.init(&.{});
    const ring: DistanceRing = .{};
    const result = try read(&reader, 18, &ring, 0, 4);

    try std.testing.expectEqual(@as(u32, 3), result.value);
}

test "zix utils compression brotli: distance, explicit code without extra bits is truncated" {
    var reader = BitReader.init(&.{});
    const ring: DistanceRing = .{};

    try std.testing.expectError(
        Error.ZixUtils_BrotliDistance_Truncated,
        read(&reader, 16, &ring, 0, 0),
    );
}

test "zix utils compression brotli: distance, explicitCode round-trips through read" {
    const ring: DistanceRing = .{};
    const samples = [_]u32{ 1, 2, 3, 4, 5, 100, 4096, 65535, 1 << 20 };

    for (samples) |value| {
        const encoded = explicitCode(value);

        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, encoded.extra, .little);
        var reader = BitReader.init(&bytes);

        const decoded = try read(&reader, encoded.code, &ring, 0, 0);

        try std.testing.expectEqual(value, decoded.value);
    }
}

test "zix utils compression brotli: distance, choose reuses the last distance" {
    var ring: DistanceRing = .{};
    const picked = choose(&ring, 4);

    try std.testing.expectEqual(@as(u16, 0), picked.code);
    try std.testing.expectEqual(@as(u32, 4), ring.dist[0]);
    try std.testing.expectEqual(@as(u32, 11), ring.dist[1]);
}

test "zix utils compression brotli: distance, choose uses an offset short code" {
    var ring: DistanceRing = .{};
    const picked = choose(&ring, 6);

    try std.testing.expectEqual(@as(u16, 7), picked.code);
    try std.testing.expectEqual(@as(u32, 6), ring.dist[0]);
}

test "zix utils compression brotli: distance, choose falls back to an explicit code" {
    var ring: DistanceRing = .{};
    const picked = choose(&ring, 1000);

    try std.testing.expect(picked.code >= 16);
    try std.testing.expectEqual(@as(u32, 1000), ring.dist[0]);
}

