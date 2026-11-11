//! ZIX Http2 mux MuxConn
//!
//! ### file: src/zix/tcp/http2/mux/MuxConn.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Per-fd state of one non-blocking h2c connection: read buffer, streams, windows.
//!
//! ### note:
//!
//! - Owned by one worker thread, never shared.
//! - streams[i] is valid only while slots[i] is true. The heavy stream state is
//!   borrowed from the per-worker pool on claim and returned on release.
//! - rbuf keeps a partial frame across readable events until the rest arrives.
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
const stream_pool = @import("stream_pool.zig");
const HpackDecoder = @import("../hpack/HpackDecoder.zig");
const MuxPhase = @import("mux_phase.zig").MuxPhase;
const MuxStream = @import("MuxStream.zig");
const ServeOpts = @import("../ServeOpts.zig");

// --------------------------------------------------------- //
// Fields:

fd: std.posix.fd_t,
opts: ServeOpts,
/// Worker io, carried onto the Context of every handler call.
io: std.Io,
/// Read accumulator. Unprocessed bytes are rbuf[rstart..rend].
rbuf: []u8,
rstart: usize,
rend: usize,
hpack_dec: HpackDecoder,
/// Borrowed streams, valid only where slots is true.
streams: []*MuxStream,
slots: []bool,
last_stream_id: u31,
phase: MuxPhase,
/// The peer's remaining receive window for all of this connection's DATA.
send_window: i64,
/// The peer's SETTINGS_INITIAL_WINDOW_SIZE: a new stream's send window.
peer_init_window: i64,
/// The peer's SETTINGS_MAX_FRAME_SIZE: the largest DATA frame it accepts.
peer_max_frame_size: u32,

const Self = @This();

// --------------------------------------------------------- //
// Public:

/// ZIX Http2 mux connection error
pub const Error = error {
    ZixHttp2_MuxConn_OutOfMemory,
};

/// Allocate a connection in the await_preface phase.
///
/// Param:
/// fd - std.posix.fd_t (the accepted connection, owned by the caller)
/// opts - ServeOpts (stream, frame, and body limits)
/// io - std.Io (the worker io)
///
/// Return:
/// - *Self (free with deinit)
/// - error.ZixHttp2_MuxConn_OutOfMemory when an allocation fails
pub fn init(fd: std.posix.fd_t, opts: ServeOpts, io: std.Io) Error!*Self {
    const allocator = std.heap.smp_allocator;

    const max_payload = opts.max_frame_size + frame.FRAME_PAYLOAD_SLACK;
    const rbuf_len = @max(opts.conn_read_buf_min, max_payload + frame.FRAME_HEADER_LEN);

    const self = allocator.create(Self) catch |err| switch (err) {
        error.OutOfMemory => return Error.ZixHttp2_MuxConn_OutOfMemory,
    };
    errdefer allocator.destroy(self);

    const rbuf = allocator.alloc(u8, rbuf_len) catch |err| switch (err) {
        error.OutOfMemory => return Error.ZixHttp2_MuxConn_OutOfMemory,
    };
    errdefer allocator.free(rbuf);

    const streams = allocator.alloc(*MuxStream, opts.max_streams) catch |err| switch (err) {
        error.OutOfMemory => return Error.ZixHttp2_MuxConn_OutOfMemory,
    };
    errdefer allocator.free(streams);

    const slots = allocator.alloc(bool, opts.max_streams) catch |err| switch (err) {
        error.OutOfMemory => return Error.ZixHttp2_MuxConn_OutOfMemory,
    };

    @memset(slots, false);

    self.* = .{
        .fd = fd,
        .opts = opts,
        .io = io,
        .rbuf = rbuf,
        .rstart = 0,
        .rend = 0,
        .hpack_dec = HpackDecoder.init(),
        .streams = streams,
        .slots = slots,
        .last_stream_id = 0,
        .phase = .await_preface,
        .send_window = frame.DEFAULT_INITIAL_WINDOW,
        .peer_init_window = frame.DEFAULT_INITIAL_WINDOW,
        .peer_max_frame_size = frame.DEFAULT_MAX_FRAME_SIZE,
    };

    return self;
}

/// Return every open stream to the pool and free the connection. The caller
/// still owns and closes the fd.
pub fn deinit(self: *Self) void {
    const allocator = std.heap.smp_allocator;

    for (self.slots, 0..) |in_use, slot| {
        if (in_use) stream_pool.release(self.streams[slot]);
    }

    allocator.free(self.slots);
    allocator.free(self.streams);
    allocator.free(self.rbuf);
    allocator.destroy(self);
}

/// The bytes read but not yet processed.
pub fn buffered(self: *const Self) []u8 {
    return self.rbuf[self.rstart..self.rend];
}

/// Make room for the next read: reset an empty buffer, or move a partial
/// frame to the front of a full one.
pub fn compact(self: *Self) void {
    if (self.rstart == self.rend) {
        self.rstart = 0;
        self.rend = 0;

        return;
    }

    if (self.rend < self.rbuf.len) return;

    const len = self.rend - self.rstart;
    std.mem.copyForwards(u8, self.rbuf[0..len], self.rbuf[self.rstart..self.rend]);

    self.rstart = 0;
    self.rend = len;
}

/// Claim a free slot for sid and open a pooled stream in it.
///
/// Param:
/// sid - u31 (the new stream id)
///
/// Return:
/// - ?usize (the slot, null when every slot is live or the pool can not grow)
pub fn claimSlot(self: *Self, sid: u31) ?usize {
    for (self.slots, 0..) |in_use, slot| {
        if (in_use) continue;

        const stream = stream_pool.acquire(self.opts) catch |err| switch (err) {
            // Out of memory reads like a full table: the stream is refused.
            error.ZixHttp2_StreamPool_OutOfMemory => return null,
        };
        stream.open(sid, self.peer_init_window);

        self.streams[slot] = stream;
        self.slots[slot] = true;

        return slot;
    }

    return null;
}

/// Find the live slot for sid.
///
/// Return:
/// - ?usize (the slot, null when no live stream has sid)
pub fn findSlot(self: *const Self, sid: u31) ?usize {
    for (self.slots, 0..) |in_use, slot| {
        if (in_use and self.streams[slot].id == sid) return slot;
    }

    return null;
}

/// Free a slot and return its stream to the pool.
pub fn releaseSlot(self: *Self, slot: usize) void {
    self.slots[slot] = false;

    stream_pool.release(self.streams[slot]);
}

/// Whether any live stream is still waiting for the rest of its request. A
/// stream held only by a parked response is not: that request arrived whole.
pub fn requestInFlight(self: *const Self) bool {
    for (self.slots, 0..) |in_use, slot| {
        if (in_use and !self.streams[slot].end_stream) return true;
    }

    return false;
}

/// Take the peer's new SETTINGS_INITIAL_WINDOW_SIZE.
///
/// Note:
/// - RFC 7540 section 6.9.2: every open stream's send window moves by the
///   difference between the new and the old value.
///
/// Param:
/// value - u32 (the advertised initial window)
///
/// Return:
/// - void
pub fn setPeerInitialWindow(self: *Self, value: u32) void {
    const new_window: i64 = value;
    const delta = new_window - self.peer_init_window;

    self.peer_init_window = new_window;

    for (self.slots, 0..) |in_use, slot| {
        if (in_use) self.streams[slot].send_window += delta;
    }
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const TEST_OPTS: ServeOpts = .{
    .max_streams = 2,
    .max_body = 64,
    .max_header_scratch = 64,
};

/// A descriptor the connection never touches in these tests.
const UNUSED_FD: std.posix.fd_t = undefined;

test "zix http2 mux: MuxConn, init starts awaiting the preface" {
    const conn = try init(UNUSED_FD, TEST_OPTS, std.testing.io);
    defer conn.deinit();

    try std.testing.expectEqual(MuxPhase.await_preface, conn.phase);
    try std.testing.expectEqual(@as(usize, 0), conn.buffered().len);
    try std.testing.expectEqual(frame.DEFAULT_MAX_FRAME_SIZE, conn.peer_max_frame_size);
}

test "zix http2 mux: MuxConn, rbuf holds one frame past the read floor" {
    const opts: ServeOpts = .{
        .max_frame_size = 64 * 1024,
        .conn_read_buf_min = 1024,
    };
    const conn = try init(UNUSED_FD, opts, std.testing.io);
    defer conn.deinit();

    try std.testing.expect(conn.rbuf.len >= 64 * 1024 + frame.FRAME_HEADER_LEN);
}

test "zix http2 mux: MuxConn, claimSlot opens a stream with the peer window" {
    const conn = try init(UNUSED_FD, TEST_OPTS, std.testing.io);
    defer conn.deinit();

    conn.peer_init_window = 300;
    const slot = conn.claimSlot(3).?;

    try std.testing.expectEqual(@as(u31, 3), conn.streams[slot].id);
    try std.testing.expectEqual(@as(i64, 300), conn.streams[slot].send_window);
    try std.testing.expectEqual(@as(?usize, slot), conn.findSlot(3));
}

test "zix http2 mux: MuxConn, claimSlot past max_streams is null" {
    const conn = try init(UNUSED_FD, TEST_OPTS, std.testing.io);
    defer conn.deinit();

    _ = conn.claimSlot(1).?;
    _ = conn.claimSlot(3).?;

    try std.testing.expect(conn.claimSlot(5) == null);
}

test "zix http2 mux: MuxConn, releaseSlot frees the slot for reuse" {
    const conn = try init(UNUSED_FD, TEST_OPTS, std.testing.io);
    defer conn.deinit();

    const slot = conn.claimSlot(1).?;
    conn.releaseSlot(slot);

    try std.testing.expect(conn.findSlot(1) == null);
    try std.testing.expectEqual(@as(?usize, slot), conn.claimSlot(3));
}

test "zix http2 mux: MuxConn, stream slots are pooled across connections" {
    const conn_a = try init(UNUSED_FD, TEST_OPTS, std.testing.io);
    const slot_a = conn_a.claimSlot(1).?;
    const stream_a = conn_a.streams[slot_a];
    conn_a.releaseSlot(slot_a);
    conn_a.deinit();

    const conn_b = try init(UNUSED_FD, TEST_OPTS, std.testing.io);
    defer conn_b.deinit();
    const slot_b = conn_b.claimSlot(3).?;

    try std.testing.expectEqual(stream_a, conn_b.streams[slot_b]);
    try std.testing.expectEqual(@as(u31, 3), conn_b.streams[slot_b].id);
}

test "zix http2 mux: MuxConn, requestInFlight is true for an open request" {
    const conn = try init(UNUSED_FD, TEST_OPTS, std.testing.io);
    defer conn.deinit();

    _ = conn.claimSlot(1).?;

    try std.testing.expect(conn.requestInFlight());
}

test "zix http2 mux: MuxConn, requestInFlight is false once the request ended" {
    const conn = try init(UNUSED_FD, TEST_OPTS, std.testing.io);
    defer conn.deinit();

    const slot = conn.claimSlot(1).?;
    conn.streams[slot].end_stream = true;
    conn.streams[slot].pending_body = "owed";

    try std.testing.expect(!conn.requestInFlight());
}

test "zix http2 mux: MuxConn, setPeerInitialWindow moves open streams by the delta" {
    const conn = try init(UNUSED_FD, TEST_OPTS, std.testing.io);
    defer conn.deinit();

    const slot = conn.claimSlot(1).?;
    conn.streams[slot].send_window = 1000;
    conn.setPeerInitialWindow(frame.DEFAULT_INITIAL_WINDOW - 500);

    try std.testing.expectEqual(@as(i64, 500), conn.streams[slot].send_window);
    try std.testing.expectEqual(
        @as(i64, frame.DEFAULT_INITIAL_WINDOW - 500),
        conn.peer_init_window,
    );
}

test "zix http2 mux: MuxConn, compact resets an empty buffer" {
    const conn = try init(UNUSED_FD, TEST_OPTS, std.testing.io);
    defer conn.deinit();

    conn.rstart = 10;
    conn.rend = 10;
    conn.compact();

    try std.testing.expectEqual(@as(usize, 0), conn.rstart);
    try std.testing.expectEqual(@as(usize, 0), conn.rend);
}

test "zix http2 mux: MuxConn, compact moves a partial frame to the front" {
    const conn = try init(UNUSED_FD, TEST_OPTS, std.testing.io);
    defer conn.deinit();

    conn.rstart = conn.rbuf.len - 3;
    conn.rend = conn.rbuf.len;
    @memcpy(conn.rbuf[conn.rstart..conn.rend], "abc");
    conn.compact();

    try std.testing.expectEqual(@as(usize, 0), conn.rstart);
    try std.testing.expectEqualStrings("abc", conn.buffered());
}

test "zix http2 mux: MuxConn, compact leaves a buffer with room alone" {
    const conn = try init(UNUSED_FD, TEST_OPTS, std.testing.io);
    defer conn.deinit();

    conn.rstart = 2;
    conn.rend = 5;
    conn.compact();

    try std.testing.expectEqual(@as(usize, 2), conn.rstart);
    try std.testing.expectEqual(@as(usize, 5), conn.rend);
}

