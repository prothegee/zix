//! ZIX Http1 chunk
//!
//! ### file: src/zix/tcp/http1/chunk.zig
//! 
//! ### author: Prana Ron
//! 
//! ---------------------------------------------------------
//! 
//! ### brief:
//! 
//! Chunked transfer framing: walk, decode, and read off a socket.
//! 
//! ### note:
//! 
//! n/a
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
const ChunkedFrame = @import("ChunkedFrame.zig");
const ChunkedRead = @import("ChunkedRead.zig");
const reader = @import("reader.zig");

// --------------------------------------------------------- //
// Public:

/// Why a chunked body read or decode stopped.
pub const ChunkedStop = enum {
    /// The terminal chunk arrived, the body is whole.
    COMPLETE,
    /// The bytes in hand end mid-body. Read more and try again.
    NEED_MORE,
    /// The body does not fit the buffer the engine can hand a handler.
    TOO_LARGE,
    /// A chunk size line is not valid hex.
    MALFORMED,
};

/// Walk the chunk framing in src without moving a byte.
///
/// Note:
/// - Steps over chunk data by its declared size, so the cost is one step per
///   chunk rather than one per byte, and data that happens to spell the terminal
///   chunk cannot be mistaken for it.
/// - The stop reason separates "not arrived yet" from "broken" from "too big".
///
/// Param:
/// src - []const u8 (chunked bytes received so far, framing included)
/// out_cap - usize (bytes the caller can hold, decides TOO_LARGE)
///
/// Return:
/// - ChunkedFrame
pub fn chunkedFrame(src: []const u8, out_cap: usize) ChunkedFrame {
    var pos: usize = 0;
    var decoded: usize = 0;

    while (true) {
        const line_end = std.mem.indexOfPos(u8, src, pos, "\r\n") orelse
            return .{ .stop = .NEED_MORE };
        const size_field = src[pos..line_end];
        const hex = if (std.mem.indexOfScalar(u8, size_field, ';')) |semi|
            size_field[0..semi]
        else
            size_field;

        const chunk_size = std.fmt.parseInt(
            usize, std.mem.trim(u8, hex, " "), 16,
        ) catch |err| switch (err) {
            else => return .{ .stop = .MALFORMED },
        };
        pos = line_end + 2;

        if (chunk_size == 0) {
            const trailer_end = std.mem.indexOfPos(u8, src, pos, "\r\n") orelse
                return .{ .stop = .NEED_MORE };

            return .{ .len = decoded, .consumed = trailer_end + 2, .stop = .COMPLETE };
        }

        if (decoded + chunk_size > out_cap) return .{ .stop = .TOO_LARGE };
        if (pos + chunk_size + 2 > src.len) return .{ .stop = .NEED_MORE };

        decoded += chunk_size;
        pos += chunk_size + 2;
    }
}

/// Decode a chunked request body that is fully present in src (RFC 9112 7.1).
///
/// Note:
/// - out may be src itself. Decoding only removes framing, so every byte moves
///   left and a forward copy is correct even where the ranges overlap. @memcpy
///   is not usable for that, it requires disjoint ranges.
/// - Nothing is copied until the framing walk says the body is whole, so a
///   partial body leaves src untouched and the caller can read more into it.
///
/// Param:
/// src - []const u8 (chunked bytes received so far, framing included)
/// out - []u8 (decode destination, may alias src)
///
/// Return:
/// - ChunkedFrame (len and consumed are set only when stop is COMPLETE)
pub fn decodeChunkedInBuf(src: []const u8, out: []u8) ChunkedFrame {
    const frame = chunkedFrame(src, out.len);
    if (frame.stop != .COMPLETE) return frame;

    var pos: usize = 0;
    var out_pos: usize = 0;

    while (out_pos < frame.len) {
        const line_end = std.mem.indexOfPos(u8, src, pos, "\r\n").?;
        const size_field = src[pos..line_end];
        const hex = if (std.mem.indexOfScalar(u8, size_field, ';')) |semi|
            size_field[0..semi]
        else
            size_field;
        const chunk_size = std.fmt.parseInt(
            usize, std.mem.trim(u8, hex, " "), 16,
        ) catch |err| switch (err) {
            else => unreachable,
        };
        pos = line_end + 2;

        std.mem.copyForwards(u8, out[out_pos..][0..chunk_size], src[pos..][0..chunk_size]);
        out_pos += chunk_size;
        pos += chunk_size + 2;
    }

    return frame;
}

/// Read a chunked request body off a blocking socket and decode it in place.
///
/// Note:
/// - buf is both the read buffer and the decode destination. The caller seeds it
///   with the body bytes that arrived alongside the head, and the body is decoded
///   over those same bytes, so there is no second buffer and no full-body copy.
/// - A body that outgrows buf stops with TOO_LARGE rather than being cut to what
///   fits, because a handler cannot tell a cut body from a whole one.
/// - Whatever follows the body is reported, not discarded, so a pipelined
///   request is not lost.
///
/// Param:
/// fd - std.posix.fd_t
/// buf - []u8 (read buffer and decode destination, seeded bytes already at the front)
/// seeded - usize (how many body bytes the caller placed at the front of buf)
///
/// Return:
/// - ChunkedRead
pub fn readChunkedBody(fd: std.posix.fd_t, buf: []u8, seeded: usize) ChunkedRead {
    var filled = seeded;

    while (true) {
        const frame = chunkedFrame(buf[0..filled], buf.len);
        switch (frame.stop) {
            .COMPLETE => {
                _ = decodeChunkedInBuf(buf[0..filled], buf);

                return .{
                    .len = frame.len,
                    .received = frame.consumed,
                    .leftover_off = frame.consumed,
                    .leftover = filled - frame.consumed,
                    .stop = .COMPLETE,
                };
            },
            .MALFORMED, .TOO_LARGE => return .{ .received = filled, .stop = frame.stop },
            .NEED_MORE => {},
        }

        if (filled == buf.len) return .{ .received = filled, .stop = .TOO_LARGE };

        const n = reader.readOnceFD(fd, buf[filled..]) catch |err| switch (err) {
            else => return .{ .received = filled, .stop = .NEED_MORE },
        };
        if (n == 0) return .{ .received = filled, .stop = .NEED_MORE };

        filled += n;
    }
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "zix http1: chunk, frame completes" {
    const src = "5\r\nhello\r\n0\r\n\r\n";
    const frame = chunkedFrame(src, 64);

    try std.testing.expectEqual(ChunkedStop.COMPLETE, frame.stop);
    try std.testing.expectEqual(@as(usize, 5), frame.len);
    try std.testing.expectEqual(src.len, frame.consumed);
}

test "zix http1: chunk, frame needs more" {
    const frame = chunkedFrame("5\r\nhel", 64);

    try std.testing.expectEqual(ChunkedStop.NEED_MORE, frame.stop);
}

test "zix http1: chunk, frame too large" {
    const frame = chunkedFrame("5\r\nhello\r\n0\r\n\r\n", 4);

    try std.testing.expectEqual(ChunkedStop.TOO_LARGE, frame.stop);
}

test "zix http1: chunk, frame malformed" {
    const frame = chunkedFrame("zz\r\nhello\r\n0\r\n\r\n", 64);

    try std.testing.expectEqual(ChunkedStop.MALFORMED, frame.stop);
}

test "zix http1: chunk, decodes in place" {
    const src = "5\r\nhello\r\n0\r\n\r\n";
    var out: [64]u8 = undefined;
    const frame = decodeChunkedInBuf(src, &out);

    try std.testing.expectEqual(ChunkedStop.COMPLETE, frame.stop);
    try std.testing.expectEqualStrings("hello", out[0..frame.len]);
}

