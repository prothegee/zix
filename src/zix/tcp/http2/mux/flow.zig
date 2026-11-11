//! ZIX Http2 mux flow
//!
//! ### file: src/zix/tcp/http2/mux/flow.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Send-side flow control: DATA up to the send windows, the rest parked.
//!
//! ### note:
//!
//! - A DATA frame is capped by the peer's SETTINGS_MAX_FRAME_SIZE, never by
//!   this server's own receive-side max_frame_size. The peer rejects a larger
//!   frame with FRAME_SIZE_ERROR.
//! - A parked body holds its slot until it drains or the peer resets it.
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
const frame = @import("../frame.zig");
const writer = @import("../writer.zig");
const MuxConn = @import("MuxConn.zig");
const MuxStream = @import("MuxStream.zig");

// --------------------------------------------------------- //
// Private:

/// Write one DATA frame.
fn writeData(fd: std.posix.fd_t, sid: u31, chunk: []const u8, end: bool) writer.Error!void {
    try writer.writeFrameHeaderFD(fd, .{
        .length = @intCast(chunk.len),
        .frame_type = frame.FRAME_TYPE_DATA,
        .flags = if (end) frame.FLAG_END_STREAM else 0,
        .stream_id = sid,
    });

    try writer.writeAllFD(fd, chunk);
}

// --------------------------------------------------------- //
// Public:

/// Send DATA for body up to the connection and stream send windows. What does
/// not fit is parked on the stream for a later WINDOW_UPDATE.
///
/// Note:
/// - END_STREAM rides the final frame only once the whole body has gone out.
/// - A failed write stops the send and parks the rest. The connection loop
///   sees the broken socket on its next read.
///
/// Param:
/// conn - *MuxConn (owns the connection window and the peer frame cap)
/// stream - *MuxStream (owns the stream window and the parked tail)
/// body - []const u8 (must outlive the stream while any of it is parked)
/// end - bool (whether the last frame of body ends the stream)
///
/// Return:
/// - void
pub fn pumpBody(conn: *MuxConn, stream: *MuxStream, body: []const u8, end: bool) void {
    var offset: usize = 0;

    while (offset < body.len) {
        const room = @min(conn.send_window, stream.send_window);
        if (room <= 0) break;

        const cap = @min(@as(i64, conn.peer_max_frame_size), room);
        const chunk_len = @min(body.len - offset, @as(usize, @intCast(cap)));
        const is_last = end and offset + chunk_len == body.len;

        writeData(conn.fd, stream.id, body[offset..][0..chunk_len], is_last) catch |err| {
            switch (err) {
                // Park the rest: the next read sees the broken socket.
                error.ZixHttp2_Writer_BrokenPipe,
                error.ZixHttp2_Writer_UnexpectedEOF,
                error.ZixHttp2_Writer_Overflow,
                error.ZixHttp2_Writer_BufferFull,
                => break,
            }
        };

        conn.send_window -= @intCast(chunk_len);
        stream.send_window -= @intCast(chunk_len);
        offset += chunk_len;
    }

    if (offset < body.len) {
        stream.pending_body = body[offset..];
        stream.pending_end = end;

        return;
    }

    stream.pending_body = &.{};
    stream.pending_end = false;
}

/// Resume one parked stream after a window grew. Frees the slot once its body
/// fully drains.
///
/// Param:
/// conn - *MuxConn (the connection owning the slot)
/// slot - usize (the stream's slot)
///
/// Return:
/// - void
pub fn resumeStream(conn: *MuxConn, slot: usize) void {
    const stream = conn.streams[slot];
    if (!stream.isParked()) return;

    pumpBody(conn, stream, stream.pending_body, stream.pending_end);

    if (!stream.isParked()) conn.releaseSlot(slot);
}

/// Resume every parked stream after the connection window grew.
pub fn resumeAll(conn: *MuxConn) void {
    for (conn.slots, 0..) |in_use, slot| {
        if (in_use and conn.streams[slot].isParked()) resumeStream(conn, slot);
    }
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const builtin = @import("builtin");
const pair = @import("../../../utils/socket/pair.zig");
const ServeOpts = @import("../ServeOpts.zig");

/// DATA frames read back from the wire.
const DataTally = struct {
    bytes: usize = 0,
    frames: usize = 0,
    largest: usize = 0,
    end_streams: usize = 0,
};

fn isLinux() bool {
    if (comptime builtin.target.os.tag == .linux) return true;

    std.log.info("this test drives a Linux socket pair, test skipped", .{});

    return false;
}

/// Shut the server end for writing, read everything, and count DATA frames.
fn tallyData(client_fd: std.posix.fd_t, server_fd: std.posix.fd_t, buf: []u8) DataTally {
    _ = std.os.linux.shutdown(server_fd, std.os.linux.SHUT.WR);

    var total: usize = 0;
    while (total < buf.len) {
        const got = std.posix.read(client_fd, buf[total..]) catch break;
        if (got == 0) break;

        total += got;
    }

    var tally: DataTally = .{};
    var pos: usize = 0;

    while (pos + frame.FRAME_HEADER_LEN <= total) {
        const header = frame.parseFrameHeader(buf[pos..][0..frame.FRAME_HEADER_LEN]);
        pos += frame.FRAME_HEADER_LEN + header.length;

        if (header.frame_type != frame.FRAME_TYPE_DATA) continue;

        tally.bytes += header.length;
        tally.frames += 1;
        tally.largest = @max(tally.largest, header.length);
        if ((header.flags & frame.FLAG_END_STREAM) != 0) tally.end_streams += 1;
    }

    return tally;
}

const TEST_OPTS: ServeOpts = .{
    .max_streams = 4,
    .max_body = 64,
    .max_header_scratch = 64,
};

test "zix http2 mux: flow, pumpBody paces a body by the send window" {
    if (!isLinux()) return;

    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    const conn = try MuxConn.init(fds[1], TEST_OPTS, std.testing.io);
    defer conn.deinit();

    conn.send_window = 100;
    conn.peer_init_window = 100;
    const slot = conn.claimSlot(1).?;
    const stream = conn.streams[slot];

    const body: [250]u8 = @splat('z');
    pumpBody(conn, stream, &body, true);

    try std.testing.expectEqual(@as(usize, 150), stream.pending_body.len);
    try std.testing.expectEqual(@as(i64, 0), conn.send_window);

    conn.send_window += 100;
    stream.send_window += 100;
    resumeStream(conn, slot);

    try std.testing.expectEqual(@as(usize, 50), stream.pending_body.len);
    try std.testing.expect(conn.slots[slot]);

    conn.send_window += 100;
    stream.send_window += 100;
    resumeStream(conn, slot);

    try std.testing.expect(!conn.slots[slot]);

    var buf: [4096]u8 = undefined;
    const tally = tallyData(fds[0], fds[1], &buf);

    try std.testing.expectEqual(@as(usize, 250), tally.bytes);
    try std.testing.expectEqual(@as(usize, 1), tally.end_streams);
    try std.testing.expect(tally.largest <= 100);
}

test "zix http2 mux: flow, pumpBody caps DATA at the peer max frame size" {
    if (!isLinux()) return;

    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    const conn = try MuxConn.init(fds[1], TEST_OPTS, std.testing.io);
    defer conn.deinit();

    conn.send_window = 1 << 20;
    const slot = conn.claimSlot(1).?;
    const stream = conn.streams[slot];
    stream.send_window = 1 << 20;

    const body = try std.testing.allocator.alloc(u8, 40000);
    defer std.testing.allocator.free(body);
    @memset(body, 'f');

    pumpBody(conn, stream, body, true);

    var buf: [64 * 1024]u8 = undefined;
    const tally = tallyData(fds[0], fds[1], &buf);

    try std.testing.expectEqual(@as(usize, 40000), tally.bytes);
    try std.testing.expect(tally.largest <= frame.DEFAULT_MAX_FRAME_SIZE);
    try std.testing.expect(tally.frames >= 3);
}

test "zix http2 mux: flow, pumpBody with no window parks the whole body" {
    if (!isLinux()) return;

    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    const conn = try MuxConn.init(fds[1], TEST_OPTS, std.testing.io);
    defer conn.deinit();

    conn.send_window = 0;
    const slot = conn.claimSlot(1).?;
    const stream = conn.streams[slot];

    pumpBody(conn, stream, "parked", true);

    try std.testing.expectEqualStrings("parked", stream.pending_body);
    try std.testing.expect(stream.pending_end);
}

test "zix http2 mux: flow, pumpBody without end leaves the stream open" {
    if (!isLinux()) return;

    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    const conn = try MuxConn.init(fds[1], TEST_OPTS, std.testing.io);
    defer conn.deinit();

    const slot = conn.claimSlot(1).?;
    pumpBody(conn, conn.streams[slot], "part", false);

    var buf: [256]u8 = undefined;
    const tally = tallyData(fds[0], fds[1], &buf);

    try std.testing.expectEqual(@as(usize, 4), tally.bytes);
    try std.testing.expectEqual(@as(usize, 0), tally.end_streams);
}

test "zix http2 mux: flow, resumeStream on a stream not parked keeps the slot" {
    const conn = try MuxConn.init(undefined, TEST_OPTS, std.testing.io);
    defer conn.deinit();

    const slot = conn.claimSlot(1).?;
    resumeStream(conn, slot);

    try std.testing.expect(conn.slots[slot]);
}

test "zix http2 mux: flow, resumeAll drains every parked stream" {
    if (!isLinux()) return;

    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    const conn = try MuxConn.init(fds[1], TEST_OPTS, std.testing.io);
    defer conn.deinit();

    conn.send_window = 0;
    const body: [300]u8 = @splat('m');
    const sids = [_]u31{ 1, 3, 5 };
    for (sids) |sid| {
        const slot = conn.claimSlot(sid).?;
        pumpBody(conn, conn.streams[slot], &body, true);
    }

    conn.send_window = 3 * body.len;
    resumeAll(conn);

    for (sids) |sid| try std.testing.expect(conn.findSlot(sid) == null);

    var buf: [4096]u8 = undefined;
    const tally = tallyData(fds[0], fds[1], &buf);

    try std.testing.expectEqual(@as(usize, 3 * body.len), tally.bytes);
    try std.testing.expectEqual(@as(usize, 3), tally.end_streams);
}

test "zix http2 mux: flow, a broken socket parks the rest" {
    if (!isLinux()) return;

    const conn = try MuxConn.init(-1, TEST_OPTS, std.testing.io);
    defer conn.deinit();

    const slot = conn.claimSlot(1).?;
    pumpBody(conn, conn.streams[slot], "lost", true);

    try std.testing.expectEqualStrings("lost", conn.streams[slot].pending_body);
}

