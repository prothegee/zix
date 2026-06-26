//! Brotli encoder PoC, phase E4 (RFC 7932), last-distance ring buffer.
//!
//! Note:
//! - Builds on E3 (rnd/0.5.x/brotli_encoder_lz_poc.zig). E3 always spelled out a distance
//!   with the explicit extra-bit codes (>= 16). E4 adds the last-distance ring buffer
//!   (sec 4): when a match reuses a recent distance, it is sent as a short code 0..15 with
//!   ZERO extra bits, the common case for column-structured or regularly spaced data.
//! - The encoder simulates the exact ring the decoder maintains (initial {4,11,15,16},
//!   pushed after every real back-reference, but NOT after short code 0). Short codes:
//!   0..3 = the four recent distances, 4..9 = last distance +/- 1..3, 10..15 = second
//!   distance +/- 1..3. Anything else falls back to the explicit code.
//! - The match finder, command machinery, and prefix-code building are reused unchanged
//!   from E3; only the per-command distance choice differs.
//! - Verified by self round-trip through the full decoder (brotli_conformance_poc.zig) and
//!   the `brotli -dc` interop gate (rnd/0.5.x/verify-brotli-encoder-dist.sh).
//!
//! Run: zig run rnd/0.5.x/brotli_encoder_dist_poc.zig

const std = @import("std");
const e2 = @import("brotli_encoder_literal_poc.zig");
const e3 = @import("brotli_encoder_lz_poc.zig");
const cmd_tables = @import("brotli_command_poc.zig");
const decoder = @import("brotli_conformance_poc.zig");

const EncodeError = e3.EncodeError;

/// Pick the cheapest distance code for value given the current ring, and advance the ring
/// exactly as the decoder would (sec 4). Short codes 1..15 push the resolved distance, code
/// 0 leaves the ring unchanged, the explicit code pushes too.
pub fn chooseDistance(ring: *cmd_tables.DistanceRing, value: u32) e3.DistanceCode {
    const short = matchRingCode(ring.*, value);
    if (short) |code| {
        if (code != 0) ring.push(value);

        return .{ .code = code, .extra = 0, .nextra = 0 };
    }

    const dc = e3.distanceCode(value);
    ring.push(value);

    return dc;
}

/// The short distance code (0..15) that resolves to value, or null if none does (sec 4).
pub fn matchRingCode(ring: cmd_tables.DistanceRing, value: u32) ?u16 {
    if (value == ring.d[0]) return 0;
    if (value == ring.d[1]) return 1;
    if (value == ring.d[2]) return 2;
    if (value == ring.d[3]) return 3;

    const offsets = [_]i64{ -1, 1, -2, 2, -3, 3 };
    for (offsets, 0..) |off, k| {
        const cand = @as(i64, ring.d[0]) + off;
        if (cand > 0 and @as(u32, @intCast(cand)) == value) return @intCast(4 + k);
    }
    for (offsets, 0..) |off, k| {
        const cand = @as(i64, ring.d[1]) + off;
        if (cand > 0 and @as(u32, @intCast(cand)) == value) return @intCast(10 + k);
    }

    return null;
}

/// Encode input as a single LZ77 compressed brotli meta-block using ring-buffer distances
/// (phase E4). See encodeLzBlockAlloc in E3 for the non-ring baseline.
fn encodeDistBlockAlloc(allocator: std.mem.Allocator, input: []const u8, wbits: u6) EncodeError![]u8 {
    if (input.len > e2.MAX_META_BLOCK_LEN) return error.InputTooLarge;

    var bw: e2.BitWriter = .{};
    errdefer bw.deinit(allocator);

    try e2.writeWindowBits(&bw, allocator, wbits);

    if (input.len == 0) {
        try bw.writeBit(allocator, 1);
        try bw.writeBit(allocator, 1);

        return bw.toOwnedSlice(allocator);
    }

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    var commands: std.ArrayList(e3.Command) = .empty;
    try e3.parseCommands(scratch, input, wbits, &commands);

    // first pass: choose each command's distance code while simulating the decoder's ring.
    const chosen = try scratch.alloc(e3.DistanceCode, commands.items.len);
    var ring = cmd_tables.DistanceRing{};
    for (commands.items, 0..) |c, idx| {
        if (c.copy_len > 0) chosen[idx] = chooseDistance(&ring, c.distance);
    }

    // literal code over the inserted literals only.
    var lits: std.ArrayList(u8) = .empty;
    for (commands.items) |c| try lits.appendSlice(scratch, input[c.lit_off..][0..c.insert_len]);

    var lsyms: [4]u16 = undefined;
    var lnsym: usize = 0;
    const lc = e2.buildLiteralCode(lits.items, &lsyms, &lnsym);

    var cmd_freq = std.mem.zeroes([e3.COMMAND_ALPHABET]u32);
    var dist_freq = std.mem.zeroes([e3.DISTANCE_ALPHABET]u32);
    for (commands.items, 0..) |c, idx| {
        const insert_code = e2.selectInsertCode(c.insert_len);
        if (c.copy_len > 0) {
            const copy_code = e3.selectCopyCode(c.copy_len);
            cmd_freq[e3.composeCommandExplicit(insert_code, copy_code)] += 1;
            dist_freq[chosen[idx].code] += 1;
        } else {
            cmd_freq[e3.composeCommandExplicit(insert_code, 0)] += 1;
        }
    }

    const cmd_code = try e3.buildTreeCode(scratch, &cmd_freq, e3.COMMAND_ALPHABET);
    const dist_code = try e3.buildTreeCode(scratch, &dist_freq, e3.DISTANCE_ALPHABET);

    try bw.writeBit(allocator, 1); // ISLAST = 1
    try bw.writeBit(allocator, 0); // ISLASTEMPTY = 0
    try e2.writeMetaBlockLen(&bw, allocator, input.len);
    try bw.writeBit(allocator, 0); // NBLTYPESL = 1
    try bw.writeBit(allocator, 0); // NBLTYPESI = 1
    try bw.writeBit(allocator, 0); // NBLTYPESD = 1
    try bw.writeInt(allocator, 0, 2); // NPOSTFIX = 0
    try bw.writeInt(allocator, 0, 4); // NDIRECT = 0
    try bw.writeInt(allocator, 0, 2); // context mode LSB6
    try bw.writeBit(allocator, 0); // NTREESL = 1
    try bw.writeBit(allocator, 0); // NTREESD = 1

    try e2.writeLiteralCode(&bw, allocator, &lc, &lsyms, lnsym);
    try e3.writeTreeCode(&bw, allocator, cmd_code, e3.COMMAND_ALPHABET);
    try e3.writeTreeCode(&bw, allocator, dist_code, e3.DISTANCE_ALPHABET);

    for (commands.items, 0..) |c, idx| {
        const insert_code = e2.selectInsertCode(c.insert_len);
        const copy_code: u8 = if (c.copy_len > 0) e3.selectCopyCode(c.copy_len) else 0;
        const sym = e3.composeCommandExplicit(insert_code, copy_code);

        try bw.writeCode(allocator, cmd_code.codes[sym], @intCast(cmd_code.lengths[sym]));
        try bw.writeInt(allocator, c.insert_len - cmd_tables.INSERT_LEN_BASE[insert_code], cmd_tables.INSERT_LEN_EXTRA[insert_code]);

        const copy_value: u32 = if (c.copy_len > 0) c.copy_len else cmd_tables.COPY_LEN_BASE[0];
        try bw.writeInt(allocator, copy_value - cmd_tables.COPY_LEN_BASE[copy_code], cmd_tables.COPY_LEN_EXTRA[copy_code]);

        var k: usize = 0;
        while (k < c.insert_len) : (k += 1) {
            const b = input[c.lit_off + k];
            try bw.writeCode(allocator, lc.codes[b], @intCast(lc.lengths[b]));
        }

        if (c.copy_len > 0) {
            const dc = chosen[idx];
            try bw.writeCode(allocator, dist_code.codes[dc.code], @intCast(dist_code.lengths[dc.code]));
            try bw.writeInt(allocator, dc.extra, dc.nextra);
        }
    }

    return bw.toOwnedSlice(allocator);
}

pub fn main(process: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    var arg_iter = std.process.Args.Iterator.init(process.minimal.args);
    _ = arg_iter.skip();

    const input_path = arg_iter.next();
    const output_path = arg_iter.next();

    if (input_path != null and output_path != null) {
        const io = process.io;
        const cwd = std.Io.Dir.cwd();

        const input = try cwd.readFileAlloc(io, input_path.?, allocator, .unlimited);
        const stream = try encodeDistBlockAlloc(allocator, input, 22);

        const f = try cwd.createFile(io, output_path.?, .{});
        defer f.close(io);

        var write_buf: [8192]u8 = undefined;
        var writer = f.writer(io, &write_buf);
        try writer.interface.writeAll(stream);
        try writer.interface.flush();

        return;
    }

    // a run of fixed-width records sharing one repeating gap exercises the ring reuse.
    var record: std.ArrayList(u8) = .empty;
    var r: usize = 0;
    while (r < 64) : (r += 1) {
        try record.appendSlice(allocator, "field-a,field-b,field-c,");
    }

    const stream = try encodeDistBlockAlloc(allocator, record.items, 22);
    const back = try decoder.decode(allocator, stream);

    const verdict = if (std.mem.eql(u8, back, record.items)) "OK" else "MISMATCH";
    std.debug.print("[{d} bytes -> {d} bytes] {s}\n", .{ record.items.len, stream.len, verdict });
}

// --------------------------------------------------------- //
// test cases
// --------------------------------------------------------- //

const testing = std.testing;

fn roundTrip(input: []const u8, wbits: u6) !void {
    const stream = try encodeDistBlockAlloc(testing.allocator, input, wbits);
    defer testing.allocator.free(stream);

    const back = try decoder.decode(testing.allocator, stream);
    defer testing.allocator.free(back);

    try testing.expectEqualSlices(u8, input, back);
}

test "ring code: initial distances map to short codes 0..3" {
    const ring = cmd_tables.DistanceRing{}; // {4, 11, 15, 16}

    try testing.expectEqual(@as(?u16, 0), matchRingCode(ring, 4));
    try testing.expectEqual(@as(?u16, 1), matchRingCode(ring, 11));
    try testing.expectEqual(@as(?u16, 2), matchRingCode(ring, 15));
    try testing.expectEqual(@as(?u16, 3), matchRingCode(ring, 16));
}

test "ring code: last-distance plus/minus offsets map to 4..9" {
    const ring = cmd_tables.DistanceRing{}; // d[0] = 4

    try testing.expectEqual(@as(?u16, 4), matchRingCode(ring, 3)); // 4 - 1
    try testing.expectEqual(@as(?u16, 5), matchRingCode(ring, 5)); // 4 + 1
    try testing.expectEqual(@as(?u16, 6), matchRingCode(ring, 2)); // 4 - 2
    try testing.expectEqual(@as(?u16, null), matchRingCode(ring, 100));
}

test "empty and no-match inputs round-trip" {
    try roundTrip("", 22);
    try roundTrip("abcdefghijklmnopqrstuvwxyz0123456789", 22);
}

test "fixed-width records reuse one distance (ring path)" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var r: usize = 0;
    while (r < 80) : (r += 1) try buf.appendSlice(testing.allocator, "2026-06-23,zix,ok\n");

    const stream = try encodeDistBlockAlloc(testing.allocator, buf.items, 22);
    defer testing.allocator.free(stream);

    try testing.expect(stream.len < buf.items.len / 6);

    const back = try decoder.decode(testing.allocator, stream);
    defer testing.allocator.free(back);
    try testing.expectEqualSlices(u8, buf.items, back);
}

test "repeated phrase round-trips" {
    try roundTrip("the quick brown fox the quick brown fox the quick brown fox", 22);
}

test "long single-byte run round-trips" {
    var input: [40000]u8 = undefined;
    @memset(&input, 'q');

    try roundTrip(&input, 24);
}

test "binary data round-trips" {
    var input: [3000]u8 = undefined;
    for (&input, 0..) |*b, i| b.* = @truncate((i * 2654435761) >> 11);

    try roundTrip(&input, 22);
}

test "ring distances never beat a correct decode on structured data" {
    // interleave two periods so both d[0] and d[1] reuse paths fire.
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var r: usize = 0;
    while (r < 200) : (r += 1) {
        try buf.appendSlice(testing.allocator, if (r % 2 == 0) "alpha-token " else "beta-token ");
    }

    try roundTrip(buf.items, 22);
}
