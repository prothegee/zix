//! Brotli decoder PoC (RFC 7932), decoder-first de-risking step for the std-gap.
//!
//! Note:
//! - std ships NO brotli (std.compress has flate / zstd / lzma / xz only), so brotli
//!   must be authored from RFC 7932. This PoC proves the FRAMING is tractable, the
//!   step before the large compressed-block work.
//! - Implemented: the LSB-first bit reader, the stream header (WBITS, RFC 7932 sec 9.1),
//!   the meta-block header (ISLAST / ISLASTEMPTY / MNIBBLES / MLEN / ISUNCOMPRESSED,
//!   sec 9.2), and the UNCOMPRESSED meta-block path.
//! - Not implemented (the bulk, mapped in rnd/0.5.x/brotli-plan.md): the COMPRESSED
//!   meta-block (prefix codes sec 3, block-switch sec 6, context maps sec 7, the
//!   command loop sec 9.2, and the static dictionary sec 8 + Appendix A/B).
//! - Vectors are produced by the system `brotli` CLI, so this decodes REAL brotli
//!   output, not a hand-built stream.
//!
//! Run: zig run rnd/0.5.x/brotli_decoder_poc.zig

const std = @import("std");

const DecodeError = error{
    EndOfStream,
    Truncated,
    OutTooSmall,
    MetadataNotImplemented,
    CompressedBlockNotImplemented,
};

/// LSB-first bit reader: brotli reads bits from the least-significant bit of each byte.
const BitReader = struct {
    bytes: []const u8,
    byte_pos: usize = 0,
    bit_pos: u3 = 0,

    fn readBit(self: *BitReader) DecodeError!u1 {
        if (self.byte_pos >= self.bytes.len) return error.EndOfStream;

        const bit: u1 = @truncate(self.bytes[self.byte_pos] >> self.bit_pos);
        if (self.bit_pos == 7) {
            self.bit_pos = 0;
            self.byte_pos += 1;
        } else {
            self.bit_pos += 1;
        }

        return bit;
    }

    fn readBits(self: *BitReader, n: u6) DecodeError!u32 {
        var value: u32 = 0;
        var i: u6 = 0;
        while (i < n) : (i += 1) {
            const bit = try self.readBit();
            value |= @as(u32, bit) << @intCast(i);
        }

        return value;
    }

    /// Skip to the next byte boundary (used before an uncompressed meta-block body).
    fn alignToByte(self: *BitReader) void {
        if (self.bit_pos != 0) {
            self.bit_pos = 0;
            self.byte_pos += 1;
        }
    }
};

/// Stream header window size, RFC 7932 section 9.1.
fn readWindowBits(br: *BitReader) DecodeError!u6 {
    if (try br.readBit() == 0) return 16;

    const n1 = try br.readBits(3);
    if (n1 != 0) return @intCast(17 + n1); // 18..24

    const n2 = try br.readBits(3);
    if (n2 != 0) return @intCast(8 + n2); // 9..15

    return 17;
}

/// Decode one brotli stream into out, returning the decoded length. Returns
/// error.CompressedBlockNotImplemented at the first compressed meta-block: that is
/// the boundary this PoC deliberately stops at.
fn decode(br: *BitReader, out: []u8) DecodeError!usize {
    var out_len: usize = 0;

    const wbits = try readWindowBits(br);
    const window: u64 = (@as(u64, 1) << wbits) - 16;
    std.debug.print("  WBITS = {d} (window = {d} bytes)\n", .{ wbits, window });

    while (true) {
        const is_last = try br.readBit();
        if (is_last == 1) {
            const is_last_empty = try br.readBit();
            if (is_last_empty == 1) {
                std.debug.print("  meta-block: ISLAST + ISLASTEMPTY -> stream end\n", .{});
                return out_len;
            }
        }

        const mnibbles_code = try br.readBits(2);
        if (mnibbles_code == 3) {
            std.debug.print("  meta-block: metadata (MNIBBLES=3) -> not handled in PoC\n", .{});
            return error.MetadataNotImplemented;
        }

        const nibbles: u6 = @intCast(mnibbles_code + 4);
        const mlen = (try br.readBits(nibbles * 4)) + 1;

        var is_uncompressed: u1 = 0;
        if (is_last == 0) is_uncompressed = try br.readBit();

        std.debug.print("  meta-block: ISLAST={d} MLEN={d} ISUNCOMPRESSED={d}\n", .{ is_last, mlen, is_uncompressed });

        if (is_uncompressed == 1) {
            br.alignToByte();
            if (br.byte_pos + mlen > br.bytes.len) return error.Truncated;
            if (out_len + mlen > out.len) return error.OutTooSmall;

            @memcpy(out[out_len..][0..mlen], br.bytes[br.byte_pos..][0..mlen]);
            br.byte_pos += mlen;
            out_len += mlen;

            std.debug.print("    -> uncompressed: copied {d} bytes\n", .{mlen});
            continue;
        }

        // The bulk of brotli lives here. See rnd/0.5.x/brotli-plan.md phases D2..D6.
        std.debug.print("    -> COMPRESSED meta-block: prefix codes (sec 3), commands (sec 9.2), dictionary (sec 8) NOT IMPLEMENTED\n", .{});
        return error.CompressedBlockNotImplemented;
    }
}

fn runVector(name: []const u8, vector: []const u8, expected: ?[]const u8) void {
    std.debug.print("[{s}] {d} input bytes\n", .{ name, vector.len });

    var br = BitReader{ .bytes = vector };
    var out: [1024]u8 = undefined;

    if (decode(&br, &out)) |n| {
        std.debug.print("  DECODED {d} bytes: \"{s}\"\n", .{ n, out[0..n] });
        if (expected) |exp| {
            const verdict = if (std.mem.eql(u8, out[0..n], exp)) "MATCH" else "MISMATCH";
            std.debug.print("  {s} expected (\"{s}\")\n", .{ verdict, exp });
        }
    } else |err| {
        std.debug.print("  STOPPED at: {s}\n", .{@errorName(err)});
        if (expected == null) std.debug.print("  (expected boundary: this marks the next implementation step, the compressed block)\n", .{});
    }

    std.debug.print("\n", .{});
}

pub fn main() void {
    // All three produced by the system `brotli` CLI (printf ... | brotli -c).
    const empty = "\x3f";
    const uncompressed = "\x0f\x0c\x80" ++ "hello, brotli decoder PoC" ++ "\x03";
    const compressed = "\x1f\xef\x00\xf8\x8d\x94\x6e\xe6\xa2\x06\x31\xa3\xc3\x53\x68\x6f\x39\xc8\x24\xa3\xe5\x08\xdb\x74\x54\x16\x48\xd7\x16\x0f";

    runVector("empty stream", empty, "");
    runVector("uncompressed meta-block (real CLI)", uncompressed, "hello, brotli decoder PoC");
    runVector("compressed meta-block (real CLI, 240 raw -> 30)", compressed, null);
}
