//! ZIX Http2 Grpc mux MuxConn
//!
//! ### file: src/zix/tcp/http2/grpc/mux/MuxConn.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Per-fd state of one non-blocking gRPC h2c connection: read buffer,
//! streams, and the reply stage.
//!
//! ### note:
//!
//! - Owned by one worker thread, never shared, so no write lock is needed.
//! - streams[i] is valid only while slots[i] is true. The stream is borrowed
//!   from the per-worker pool on claim and returned on release.
//! - stage points into stage_buf, so a MuxConn is heap-only and never moved.
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
const frame = @import("../../frame.zig");
const settings_frame = @import("settings_frame.zig");
const stream_pool = @import("stream_pool.zig");
const HpackDecoder = @import("../../hpack/HpackDecoder.zig");
const MuxPhase = @import("../../mux/mux_phase.zig").MuxPhase;
const ReplyStage = @import("../ReplyStage.zig");
const ServeOpts = @import("../ServeOpts.zig");
const Stream = @import("../Stream.zig");

// --------------------------------------------------------- //
// Fields:

fd: std.posix.fd_t,
opts: ServeOpts,
/// Worker io, carried onto the Context of every call.
io: std.Io,
/// Read accumulator. Unprocessed bytes are rbuf[rstart..rend].
rbuf: []u8,
rstart: usize,
rend: usize,
hpack_dec: HpackDecoder,
/// Borrowed streams, valid only where slots is true.
streams: []*Stream,
slots: []bool,
last_stream_id: u31,
/// Inbound DATA bytes since the last connection WINDOW_UPDATE.
conn_window_consumed: usize,
phase: MuxPhase,
/// Server SETTINGS, built once in init.
settings: [settings_frame.SETTINGS_FRAME_LEN]u8,
/// Backing store of stage.
stage_buf: [STAGE_BUF_LEN]u8,
/// Every frame produced in one readable event, flushed in one write.
stage: ReplyStage,

const Self = @This();

// --------------------------------------------------------- //
// Public:

/// ZIX Http2 Grpc mux connection error
pub const Error = error {
    ZixHttp2_GrpcMuxConn_OutOfMemory,
};

/// Reply stage per connection, in bytes. Holds 100 coalesced unary replies,
/// or a long streaming reply in a few flushes.
pub const STAGE_BUF_LEN: usize = 64 * 1024;

/// Allocate a connection in the await_preface phase.
///
/// Param:
/// fd - std.posix.fd_t (the accepted connection, owned by the caller)
/// opts - ServeOpts (stream, frame, and body limits)
/// io - std.Io (the worker io)
///
/// Return:
/// - *Self (free with deinit)
/// - error.ZixHttp2_GrpcMuxConn_OutOfMemory when an allocation fails
pub fn init(fd: std.posix.fd_t, opts: ServeOpts, io: std.Io) Error!*Self {
    const allocator = std.heap.smp_allocator;

    const max_payload = opts.max_frame_size + frame.FRAME_PAYLOAD_SLACK;
    const rbuf_len = @max(opts.conn_read_buf_min, max_payload + frame.FRAME_HEADER_LEN);

    const self = allocator.create(Self) catch |err| switch (err) {
        error.OutOfMemory => return Error.ZixHttp2_GrpcMuxConn_OutOfMemory,
    };
    errdefer allocator.destroy(self);

    const rbuf = allocator.alloc(u8, rbuf_len) catch |err| switch (err) {
        error.OutOfMemory => return Error.ZixHttp2_GrpcMuxConn_OutOfMemory,
    };
    errdefer allocator.free(rbuf);

    const streams = allocator.alloc(*Stream, opts.max_streams) catch |err| switch (err) {
        error.OutOfMemory => return Error.ZixHttp2_GrpcMuxConn_OutOfMemory,
    };
    errdefer allocator.free(streams);

    const slots = allocator.alloc(bool, opts.max_streams) catch |err| switch (err) {
        error.OutOfMemory => return Error.ZixHttp2_GrpcMuxConn_OutOfMemory,
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
        .conn_window_consumed = 0,
        .phase = .await_preface,
        .settings = undefined,
        .stage_buf = undefined,
        .stage = undefined,
    };

    settings_frame.build(&self.settings, opts);
    self.stage = .{
        .fd = fd,
        .buf = &self.stage_buf,
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
            error.ZixHttp2_GrpcStreamPool_OutOfMemory => return null,
        };
        stream.open(sid);

        self.streams[slot] = stream;
        self.slots[slot] = true;

        return slot;
    }

    return null;
}

/// Find the live slot for sid.
///
/// Param:
/// sid - u31 (the stream id to look up)
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

/// Whether any live stream is still waiting for the rest of its request.
pub fn requestInFlight(self: *const Self) bool {
    for (self.slots, 0..) |in_use, slot| {
        if (in_use and !self.streams[slot].end_stream) return true;
    }

    return false;
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

test "zix http2 grpc mux: MuxConn, init starts awaiting the preface" {
    const conn = try init(UNUSED_FD, TEST_OPTS, std.testing.io);
    defer conn.deinit();

    try std.testing.expectEqual(MuxPhase.await_preface, conn.phase);
    try std.testing.expectEqual(@as(usize, 0), conn.buffered().len);
    try std.testing.expectEqual(@as(usize, 0), conn.stage.len);
}

test "zix http2 grpc mux: MuxConn, stage writes into its own buffer" {
    const conn = try init(UNUSED_FD, TEST_OPTS, std.testing.io);
    defer conn.deinit();

    try std.testing.expectEqual(@as([*]u8, &conn.stage_buf), conn.stage.buf.ptr);
    try std.testing.expectEqual(STAGE_BUF_LEN, conn.stage.buf.len);
}

test "zix http2 grpc mux: MuxConn, init builds the server SETTINGS" {
    const conn = try init(UNUSED_FD, TEST_OPTS, std.testing.io);
    defer conn.deinit();

    const header = frame.parseFrameHeader(conn.settings[0..frame.FRAME_HEADER_LEN]);
    const max_streams = std.mem.readInt(u32, conn.settings[11..15], .big);

    try std.testing.expectEqual(frame.FRAME_TYPE_SETTINGS, header.frame_type);
    try std.testing.expectEqual(@as(u32, 2), max_streams);
}

test "zix http2 grpc mux: MuxConn, rbuf holds one frame past the read floor" {
    const opts: ServeOpts = .{
        .max_frame_size = 64 * 1024,
        .conn_read_buf_min = 1024,
    };
    const conn = try init(UNUSED_FD, opts, std.testing.io);
    defer conn.deinit();

    try std.testing.expect(conn.rbuf.len >= 64 * 1024 + frame.FRAME_HEADER_LEN);
}

test "zix http2 grpc mux: MuxConn, claimSlot opens a stream" {
    const conn = try init(UNUSED_FD, TEST_OPTS, std.testing.io);
    defer conn.deinit();

    const slot = conn.claimSlot(3).?;

    try std.testing.expectEqual(@as(u31, 3), conn.streams[slot].id);
    try std.testing.expect(conn.streams[slot].state == .OPEN);
    try std.testing.expectEqual(@as(?usize, slot), conn.findSlot(3));
}

test "zix http2 grpc mux: MuxConn, claimSlot past max_streams is null" {
    const conn = try init(UNUSED_FD, TEST_OPTS, std.testing.io);
    defer conn.deinit();

    _ = conn.claimSlot(1).?;
    _ = conn.claimSlot(3).?;

    try std.testing.expect(conn.claimSlot(5) == null);
}

test "zix http2 grpc mux: MuxConn, findSlot misses an unknown stream" {
    const conn = try init(UNUSED_FD, TEST_OPTS, std.testing.io);
    defer conn.deinit();

    _ = conn.claimSlot(1).?;

    try std.testing.expect(conn.findSlot(9) == null);
}

test "zix http2 grpc mux: MuxConn, releaseSlot frees the slot for reuse" {
    const conn = try init(UNUSED_FD, TEST_OPTS, std.testing.io);
    defer conn.deinit();

    const slot = conn.claimSlot(1).?;
    conn.releaseSlot(slot);

    try std.testing.expect(conn.findSlot(1) == null);
    try std.testing.expectEqual(@as(?usize, slot), conn.claimSlot(3));
}

test "zix http2 grpc mux: MuxConn, stream slots are pooled across connections" {
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

test "zix http2 grpc mux: MuxConn, requestInFlight is true for an open request" {
    const conn = try init(UNUSED_FD, TEST_OPTS, std.testing.io);
    defer conn.deinit();

    _ = conn.claimSlot(1).?;

    try std.testing.expect(conn.requestInFlight());
}

test "zix http2 grpc mux: MuxConn, requestInFlight is false once the request ended" {
    const conn = try init(UNUSED_FD, TEST_OPTS, std.testing.io);
    defer conn.deinit();

    const slot = conn.claimSlot(1).?;
    conn.streams[slot].end_stream = true;

    try std.testing.expect(!conn.requestInFlight());
}

test "zix http2 grpc mux: MuxConn, compact resets an empty buffer" {
    const conn = try init(UNUSED_FD, TEST_OPTS, std.testing.io);
    defer conn.deinit();

    conn.rstart = 10;
    conn.rend = 10;
    conn.compact();

    try std.testing.expectEqual(@as(usize, 0), conn.rstart);
    try std.testing.expectEqual(@as(usize, 0), conn.rend);
}

test "zix http2 grpc mux: MuxConn, compact moves a partial frame to the front" {
    const conn = try init(UNUSED_FD, TEST_OPTS, std.testing.io);
    defer conn.deinit();

    conn.rstart = conn.rbuf.len - 3;
    conn.rend = conn.rbuf.len;
    @memcpy(conn.rbuf[conn.rstart..conn.rend], "abc");
    conn.compact();

    try std.testing.expectEqual(@as(usize, 0), conn.rstart);
    try std.testing.expectEqualStrings("abc", conn.buffered());
}

test "zix http2 grpc mux: MuxConn, compact leaves a buffer with room alone" {
    const conn = try init(UNUSED_FD, TEST_OPTS, std.testing.io);
    defer conn.deinit();

    conn.rstart = 2;
    conn.rend = 5;
    conn.compact();

    try std.testing.expectEqual(@as(usize, 2), conn.rstart);
    try std.testing.expectEqual(@as(usize, 5), conn.rend);
}

