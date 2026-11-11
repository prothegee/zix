//! ZIX Http2 Grpc Context
//!
//! ### file: src/zix/tcp/http2/grpc/Context.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Context of one gRPC call: the buffered request messages, the reply verbs
//! (headers, messages, status), the deadline, and the response cache.
//!
//! ### note:
//!
//! A reply goes one of two ways. With `_out` set (unary), every frame is
//! staged and flushed in one write after the handler. Without it
//! (server-streaming), each frame is written at once under `_write_mutex`.
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
const builder = @import("frame/builder.zig");
const cache = @import("cache.zig");
const frame = @import("../frame.zig");
const gzip = @import("frame/gzip.zig");
const prefix = @import("frame/prefix.zig");
const writer = @import("../writer.zig");
const ConnMutex = @import("ConnMutex.zig");
const GrpcStatus = @import("status.zig").GrpcStatus;
const ReplyStage = @import("ReplyStage.zig");

// --------------------------------------------------------- //
// Fields:

io: std.Io,
/// Connection fd, the raw escape hatch.
fd: std.posix.fd_t,
/// HTTP/2 stream id of this call.
stream_id: u31,
/// Per-request scratch allocator.
allocator: std.mem.Allocator,
/// Full gRPC path of this call (e.g. "/pkg.Svc/Method"). Part of the cache
/// key. Empty skips the cache.
path: []const u8 = "",
/// Set at dispatch from the tightest of Route.timeout_ms,
/// ServeOpts.handler_timeout_ms, and grpc-timeout. The handler may change it.
deadline: ?std.Io.Clock.Timestamp = null,
/// Request body: gRPC messages, each behind a 5-byte prefix.
_body: []const u8 = &.{},
/// Read cursor in _body.
_pos: usize = 0,
_hdr_sent: bool = false,
/// Reply message bytes sent, prefixes not counted.
_sent_bytes: usize = 0,
_grpc_status: u8 = 0,
/// Whether the handler closed the call with finish.
_finished: bool = false,
/// Connection write lock. Null when no other thread writes on the connection.
_write_mutex: ?*ConnMutex = null,
/// Cork buffer for a unary reply. Null on the streaming path.
_out: ?*ReplyStage = null,
/// Gzip reply messages and announce grpc-encoding: gzip.
_resp_gzip: bool = false,
/// Packs small streaming messages into one DATA frame. Used only with _out.
_coal: ?[]u8 = null,
/// Bytes packed in _coal.
_coal_len: usize = 0,

const Self = @This();

// --------------------------------------------------------- //
// Private:

const Inner = Error || builder.Error || writer.Error;

/// A streaming DATA frame up to this size (head plus payload) goes out in one
/// write instead of two.
const STREAM_INLINE_CAP: usize = 4096;

fn innerError(err: Inner) Error {
    @branchHint(.cold);

    return switch (err) {
        error.ZixHttp2_GrpcContext_BrokenPipe => Error.ZixHttp2_GrpcContext_BrokenPipe,
        error.ZixHttp2_GrpcContext_UnexpectedEOF => Error.ZixHttp2_GrpcContext_UnexpectedEOF,
        error.ZixHttp2_GrpcContext_Overflow => Error.ZixHttp2_GrpcContext_Overflow,
        error.ZixHttp2_GrpcContext_BufferFull => Error.ZixHttp2_GrpcContext_BufferFull,
        error.ZixHttp2_GrpcBuilder_UnexpectedEOF => Error.ZixHttp2_GrpcContext_UnexpectedEOF,
        error.ZixHttp2_GrpcBuilder_Overflow => Error.ZixHttp2_GrpcContext_Overflow,
        error.ZixHttp2_GrpcBuilder_BufferFull => Error.ZixHttp2_GrpcContext_BufferFull,
        error.ZixHttp2_Writer_BrokenPipe => Error.ZixHttp2_GrpcContext_BrokenPipe,
        error.ZixHttp2_Writer_UnexpectedEOF => Error.ZixHttp2_GrpcContext_UnexpectedEOF,
        error.ZixHttp2_Writer_Overflow => Error.ZixHttp2_GrpcContext_Overflow,
        error.ZixHttp2_Writer_BufferFull => Error.ZixHttp2_GrpcContext_BufferFull,
    };
}

fn fromNow(io: std.Io, ms: u64) std.Io.Clock.Timestamp {
    return std.Io.Clock.Timestamp.fromNow(
        io,
        std.Io.Clock.Duration{
            .raw = std.Io.Duration.fromMilliseconds(@intCast(ms)),
            .clock = .real,
        },
    );
}

/// BrokenPipe when the staged reply already failed a write.
fn stageStatus(out: *const ReplyStage) Inner!void {
    if (out.failed) return Error.ZixHttp2_GrpcContext_BrokenPipe;
}

/// Write or stage the initial HEADERS once. The caller holds _write_mutex on
/// the streaming path.
fn flushHeaders(self: *Self, content_type: []const u8) Inner!void {
    if (self._hdr_sent) return;

    if (self._out) |out| try stageStatus(out);

    var buf: [builder.HEADERS_FRAME_SCRATCH]u8 = undefined;
    const len = if (self._resp_gzip)
        try builder.buildGrpcHeadersGzip(&buf, self.stream_id, content_type)
    else
        try builder.buildGrpcHeaders(&buf, self.stream_id, content_type);

    if (self._out) |out| {
        out.append(buf[0..len]);
        self._hdr_sent = true;

        return stageStatus(out);
    }

    try writer.writeAllFD(self.fd, buf[0..len]);
    self._hdr_sent = true;
}

/// Stage the packed messages as one DATA frame, then empty the pack.
fn emitCoalesced(self: *Self, out: *ReplyStage) void {
    if (self._coal_len == 0) return;

    const coal = self._coal.?;
    var head: [frame.FRAME_HEADER_LEN]u8 = undefined;
    frame.encodeFrameHeader(&head, .{
        .length = @intCast(self._coal_len),
        .frame_type = frame.FRAME_TYPE_DATA,
        .flags = 0,
        .stream_id = self.stream_id,
    });

    out.append(&head);
    out.append(coal[0..self._coal_len]);
    self._coal_len = 0;
}

/// Stage one message: packed into _coal when it fits, its own DATA frame
/// otherwise.
fn stageData(
    self: *Self,
    out: *ReplyStage,
    content_type: []const u8,
    payload: []const u8,
    compress: bool,
) Inner!void {
    try self.flushHeaders(content_type);

    if (self._coal) |coal| {
        const framed = prefix.PREFIX_LEN + payload.len;

        if (framed <= coal.len) {
            if (self._coal_len + framed > coal.len) self.emitCoalesced(out);

            prefix.writeGrpcPrefix(
                coal[self._coal_len..][0..prefix.PREFIX_LEN],
                compress,
                @intCast(payload.len),
            );
            @memcpy(coal[self._coal_len + prefix.PREFIX_LEN ..][0..payload.len], payload);
            self._coal_len += framed;
            self._sent_bytes += payload.len;

            return stageStatus(out);
        }

        // Past the pack: flush what is packed so wire order is kept.
        self.emitCoalesced(out);
    }

    var head: [builder.DATA_HEAD_LEN]u8 = undefined;
    _ = try builder.buildGrpcDataHeader(&head, self.stream_id, payload.len, compress);

    out.append(&head);
    out.append(payload);
    self._sent_bytes += payload.len;

    return stageStatus(out);
}

/// Write one DATA frame now. The caller holds _write_mutex.
fn writeData(self: *Self, payload: []const u8, compress: bool) Inner!void {
    var head: [builder.DATA_HEAD_LEN]u8 = undefined;
    const head_len =
        try builder.buildGrpcDataHeader(&head, self.stream_id, payload.len, compress);

    if (head_len + payload.len <= STREAM_INLINE_CAP) {
        var one: [STREAM_INLINE_CAP]u8 = undefined;
        @memcpy(one[0..head_len], head[0..head_len]);
        @memcpy(one[head_len..][0..payload.len], payload);

        try writer.writeAllFD(self.fd, one[0 .. head_len + payload.len]);
    } else {
        try writer.writeAllFD(self.fd, head[0..head_len]);
        try writer.writeAllFD(self.fd, payload);
    }

    self._sent_bytes += payload.len;
}

fn sendDataFrame(
    self: *Self,
    content_type: []const u8,
    payload: []const u8,
    compress: bool,
) Inner!void {
    if (self._out) |out| return self.stageData(out, content_type, payload, compress);

    if (self._write_mutex) |mutex| mutex.lock();
    defer if (self._write_mutex) |mutex| mutex.unlock();

    try self.flushHeaders(content_type);
    try self.writeData(payload, compress);
}

/// Gzip data into buf.
///
/// Return:
/// - ?usize (compressed length, null when it did not compress)
fn compressedLen(data: []const u8, buf: []u8) ?usize {
    return gzip.compressGrpcMessage(data, buf) catch |err| switch (err) {
        // Not the caller's problem: the message goes out uncompressed.
        error.ZixHttp2_GrpcGzip_TruncatedBody,
        error.ZixHttp2_GrpcGzip_DecompressFailed,
        error.ZixHttp2_GrpcGzip_BufferTooSmall,
        error.ZixHttp2_GrpcGzip_CompressFailed,
        error.ZixHttp2_GrpcGzip_OutOfMemory,
        => null,
    };
}

fn sendMessageInner(self: *Self, content_type: []const u8, data: []const u8) Inner!void {
    if (self._resp_gzip and data.len > 0) {
        const allocator = std.heap.smp_allocator;
        const size = data.len + gzip.GZIP_FRAMING_HEADROOM;
        const maybe_buf: ?[]u8 = allocator.alloc(u8, size) catch |err| switch (err) {
            // Not the caller's problem: the message goes out uncompressed.
            error.OutOfMemory => null,
        };

        if (maybe_buf) |buf| {
            defer allocator.free(buf);

            if (compressedLen(data, buf)) |len| {
                return self.sendDataFrame(content_type, buf[0..len], true);
            }
        }
    }

    return self.sendDataFrame(content_type, data, false);
}

/// The closing HEADERS: a trailer after HEADERS, trailers-only before them.
fn buildClose(self: *const Self, out: []u8, grpc_message: []const u8) builder.Error!usize {
    if (self._hdr_sent) {
        return builder.buildGrpcTrailer(out, self.stream_id, self._grpc_status, grpc_message);
    }

    return builder.buildGrpcError(out, self.stream_id, self._grpc_status, grpc_message);
}

fn finishInner(self: *Self, stat: GrpcStatus, grpc_message: []const u8) Inner!void {
    self._grpc_status = @intFromEnum(stat);
    self._finished = true;

    var buf: [builder.HEADERS_FRAME_SCRATCH]u8 = undefined;

    if (self._out) |out| {
        self.emitCoalesced(out);

        const len = try self.buildClose(&buf, grpc_message);
        out.append(buf[0..len]);

        return stageStatus(out);
    }

    if (self._write_mutex) |mutex| mutex.lock();
    defer if (self._write_mutex) |mutex| mutex.unlock();

    const len = try self.buildClose(&buf, grpc_message);

    try writer.writeAllFD(self.fd, buf[0..len]);
}

// --------------------------------------------------------- //
// Public:

/// ZIX Http2 Grpc context error
pub const Error = error {
    ZixHttp2_GrpcContext_BrokenPipe,
    ZixHttp2_GrpcContext_UnexpectedEOF,
    ZixHttp2_GrpcContext_Overflow,
    ZixHttp2_GrpcContext_BufferFull,
};

/// Backing size in bytes of the per-request stack arena behind allocator.
pub const CTX_ARENA_BYTES: usize = 4096;

/// Payload cap of one packed streaming DATA frame. The HTTP/2 default
/// SETTINGS_MAX_FRAME_SIZE, so any peer accepts it.
pub const STREAM_COALESCE_CAP: usize = 16384;

/// Build a context for one call.
///
/// Param:
/// io - std.Io (the worker io)
/// allocator - std.mem.Allocator (per-request scratch)
/// fd - std.posix.fd_t (the connection)
/// stream_id - u31 (the stream id)
/// body - []const u8 (the request body, borrowed for the call)
///
/// Return:
/// - Context
pub fn init(
    io: std.Io,
    allocator: std.mem.Allocator,
    fd: std.posix.fd_t,
    stream_id: u31,
    body: []const u8,
) Self {
    return .{
        .io = io,
        .allocator = allocator,
        .fd = fd,
        .stream_id = stream_id,
        ._body = body,
    };
}

/// Return a copy with the deadline set to now + ms.
pub fn withTimeout(self: Self, ms: u64) Self {
    var ctx = self;
    ctx.deadline = fromNow(self.io, ms);

    return ctx;
}

/// Return a copy with an explicit deadline timestamp.
pub fn withDeadline(self: Self, timestamp: std.Io.Clock.Timestamp) Self {
    var ctx = self;
    ctx.deadline = timestamp;

    return ctx;
}

/// Set the deadline to now + ms in place.
pub fn setTimeout(self: *Self, ms: u64) void {
    self.deadline = fromNow(self.io, ms);
}

/// Whether the deadline has passed. False when no deadline is set.
pub fn isExpired(self: *const Self) bool {
    return self.timedOut();
}

/// Whether the deadline has passed. False when no deadline is set. The
/// handler must check this explicitly, it does not interrupt anything.
pub fn timedOut(self: *const Self) bool {
    const deadline = self.deadline orelse return false;

    return std.Io.Clock.Timestamp.now(self.io, .real).compare(.gte, deadline);
}

/// Read the next request message. The slice points into the body and is
/// valid for the duration of the handler call.
///
/// Return:
/// - ?[]const u8 (null when every whole message was read)
pub fn recvMessage(self: *Self) ?[]const u8 {
    const remaining = self._body[self._pos..];
    if (remaining.len < prefix.PREFIX_LEN) return null;

    const msg_len = std.mem.readInt(u32, remaining[1..prefix.PREFIX_LEN], .big);
    const total = prefix.PREFIX_LEN + @as(usize, msg_len);
    if (total > remaining.len) return null;

    self._pos += total;

    return remaining[prefix.PREFIX_LEN..total];
}

/// Send the initial HEADERS (`:status 200`, content-type). No-op once sent.
///
/// Return:
/// - void
/// - error.ZixHttp2_GrpcContext_BrokenPipe when the peer is gone
/// - error.ZixHttp2_GrpcContext_BufferFull when content_type does not fit
pub fn sendHeaders(self: *Self, content_type: []const u8) Error!void {
    if (self._out == null) {
        if (self._write_mutex) |mutex| mutex.lock();
    }
    defer if (self._out == null) {
        if (self._write_mutex) |mutex| mutex.unlock();
    };

    return self.flushHeaders(content_type) catch |err| innerError(err);
}

/// Send one reply message, HEADERS first when not sent yet.
///
/// Note:
/// - With gzip on, the message is compressed and its prefix flag is 1. A
///   failed compression sends it uncompressed.
///
/// Return:
/// - void
/// - error.ZixHttp2_GrpcContext_BrokenPipe when the peer is gone. `try`
///   hands it to the engine, which answers the call with a gRPC status.
/// - error.ZixHttp2_GrpcContext_Overflow when data is past one DATA frame
pub fn sendMessage(self: *Self, content_type: []const u8, data: []const u8) Error!void {
    return self.sendMessageInner(content_type, data) catch |err| innerError(err);
}

/// Close the call with a gRPC status. Call exactly once per handler.
///
/// Note:
/// - Before any message this is a trailers-only reply, after one a trailer.
/// - The call counts as closed even when the write failed, so the engine does
///   not answer it a second time.
///
/// Return:
/// - void
/// - error.ZixHttp2_GrpcContext_BrokenPipe when the peer is gone
/// - error.ZixHttp2_GrpcContext_BufferFull when grpc_message does not fit
pub fn finish(self: *Self, stat: GrpcStatus, grpc_message: []const u8) Error!void {
    return self.finishInner(stat, grpc_message) catch |err| innerError(err);
}

/// Close a call the handler left open. Used by the engine on a handler error,
/// never by a handler. A status the handler chose is never overwritten.
///
/// Param:
/// stat - GrpcStatus (the status to close an open call with)
/// grpc_message - []const u8 (the grpc-message text to carry)
///
/// Return:
/// - bool (true when this closed the call, false when it was already closed)
pub fn finishIfOpen(self: *Self, stat: GrpcStatus, grpc_message: []const u8) bool {
    if (self._finished) return false;

    self.finish(stat, grpc_message) catch |err| switch (err) {
        // Best effort: the peer is gone or the status did not fit. The call
        // is closed either way.
        error.ZixHttp2_GrpcContext_BrokenPipe,
        error.ZixHttp2_GrpcContext_UnexpectedEOF,
        error.ZixHttp2_GrpcContext_Overflow,
        error.ZixHttp2_GrpcContext_BufferFull,
        => {},
    };

    return true;
}

/// Serve a cached unary reply when a fresh one exists. The key is the path
/// plus the raw request body. On a hit the message is sent and the call is
/// finished with OK.
///
/// Usage:
/// ```zig
/// fn handler(
///     req: *zix.Grpc.Request,
///     res: *zix.Grpc.Response,
///     _: *zix.Grpc.Context,
/// ) anyerror!void {
///     if (try res.serveCached("application/grpc")) return;
///
///     const reply = buildExpensiveReply(req.recvMessage());
///     try res.sendCached("application/grpc", reply, 0);
///     try res.finish(.OK, "");
/// }
/// ```
///
/// Return:
/// - bool (true when served from cache, the handler should return)
/// - error.ZixHttp2_GrpcContext_BrokenPipe when the peer went away mid-replay
pub fn serveCached(self: *Self, content_type: []const u8) Error!bool {
    const resp_cache = cache.tl_cache orelse return false;
    if (self.path.len == 0) return false;

    const key = cache.requestKey(self.path, self._body);
    const bytes = resp_cache.lookup(key, cache.nowMillis(self.io)) orelse return false;

    try self.sendMessage(content_type, bytes);
    try self.finish(.OK, "");

    return true;
}

/// Send a unary reply message and store it for later serveCached hits. The
/// handler still calls finish.
///
/// Note:
/// - Nothing is stored without a cache, with an empty path, for a message past
///   the per-slot cap, or when the send failed.
///
/// Param:
/// content_type - []const u8 (reply content-type, e.g. "application/grpc")
/// data - []const u8 (the uncompressed reply message)
/// ttl_ms - u32 (freshness in milliseconds, 0 means the worker default)
///
/// Return:
/// - void
/// - error.ZixHttp2_GrpcContext_BrokenPipe when the peer is gone
pub fn sendCached(
    self: *Self,
    content_type: []const u8,
    data: []const u8,
    ttl_ms: u32,
) Error!void {
    try self.sendMessage(content_type, data);

    const resp_cache = cache.tl_cache orelse return;
    if (self.path.len == 0) return;

    const ttl = if (ttl_ms == 0) cache.tl_cache_ttl_ms else ttl_ms;
    const key = cache.requestKey(self.path, self._body);

    _ = resp_cache.store(key, data, ttl, cache.nowMillis(self.io));
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const builtin = @import("builtin");
const pair = @import("../../../utils/socket/pair.zig");
const FrameHeader = @import("../FrameHeader.zig");
const Http1Config = @import("../../http1/Config.zig");
const ResponseCache = @import("../../../utils/cache/ResponseCache.zig");

const TEST_FD: std.posix.fd_t = if (builtin.os.tag == .windows)
    std.os.windows.INVALID_HANDLE_VALUE
else
    -1;

/// What a staged reply holds, frame by frame.
const StagedFrames = struct {
    headers: usize = 0,
    data_frames: usize = 0,
    messages: usize = 0,
    max_data_payload: usize = 0,
};

/// Counts writes routed through the frame write hook and keeps the bytes.
const WriteHookProbe = struct {
    count: usize = 0,
    buf: [256]u8 = undefined,
    len: usize = 0,
};

fn writeHookProbe(probe_ctx: *anyopaque, bytes: []const u8) void {
    const probe: *WriteHookProbe = @ptrCast(@alignCast(probe_ctx));
    probe.count += 1;

    if (probe.len + bytes.len <= probe.buf.len) {
        @memcpy(probe.buf[probe.len..][0..bytes.len], bytes);
        probe.len += bytes.len;
    }
}

fn installProbe(probe: *WriteHookProbe) void {
    writer.write_hook = writeHookProbe;
    writer.write_hook_ctx = probe;
}

fn removeProbe() void {
    writer.write_hook = null;
    writer.write_hook_ctx = null;
}

fn isLinux() bool {
    if (comptime builtin.target.os.tag == .linux) return true;

    std.log.info("this test drives a Linux socket pair, test skipped", .{});

    return false;
}

fn testContext(body: []const u8) Self {
    return Self.init(std.testing.io, std.testing.allocator, TEST_FD, 1, body);
}

fn stagedContext(stage: *ReplyStage) Self {
    var ctx = testContext(&.{});
    ctx._out = stage;

    return ctx;
}

fn walkStaged(buf: []const u8) StagedFrames {
    var out: StagedFrames = .{};
    var pos: usize = 0;

    while (pos + frame.FRAME_HEADER_LEN <= buf.len) {
        const header = frame.parseFrameHeader(buf[pos..][0..frame.FRAME_HEADER_LEN]);
        const payload = buf[pos + frame.FRAME_HEADER_LEN ..][0..header.length];
        pos += frame.FRAME_HEADER_LEN + header.length;

        if (header.frame_type == frame.FRAME_TYPE_HEADERS) out.headers += 1;
        if (header.frame_type != frame.FRAME_TYPE_DATA) continue;

        out.data_frames += 1;
        out.max_data_payload = @max(out.max_data_payload, header.length);

        var msg_pos: usize = 0;
        while (msg_pos + prefix.PREFIX_LEN <= payload.len) {
            const msg_len = std.mem.readInt(u32, payload[msg_pos + 1 ..][0..4], .big);
            msg_pos += prefix.PREFIX_LEN + msg_len;
            out.messages += 1;
        }
    }

    return out;
}

fn testCacheConfig() Http1Config {
    return .{
        .io = std.testing.io,
        .ip = "127.0.0.1",
        .port = 0,
        .dispatch_model = .ASYNC,
        .cache_max_entries = 16,
        .cache_max_value_bytes = 256,
    };
}

test "zix http2 grpc: Context, init keeps fd, stream id, and body" {
    const ctx = Self.init(std.testing.io, std.testing.allocator, TEST_FD, 7, "abc");

    try std.testing.expectEqual(TEST_FD, ctx.fd);
    try std.testing.expectEqual(@as(u31, 7), ctx.stream_id);
    try std.testing.expectEqualStrings("abc", ctx._body);
    try std.testing.expectEqualStrings("", ctx.path);
}

test "zix http2 grpc: Context, recvMessage on an empty body returns null" {
    var ctx = testContext(&.{});

    try std.testing.expect(ctx.recvMessage() == null);
}

test "zix http2 grpc: Context, recvMessage reads one message" {
    var body: [10]u8 = undefined;
    prefix.writeGrpcPrefix(body[0..prefix.PREFIX_LEN], false, 5);
    @memcpy(body[prefix.PREFIX_LEN..], "hello");

    var ctx = testContext(&body);

    try std.testing.expectEqualStrings("hello", ctx.recvMessage().?);
    try std.testing.expect(ctx.recvMessage() == null);
}

test "zix http2 grpc: Context, recvMessage reads two messages in order" {
    var body: [16]u8 = undefined;
    prefix.writeGrpcPrefix(body[0..5], false, 3);
    @memcpy(body[5..8], "foo");
    prefix.writeGrpcPrefix(body[8..13], false, 3);
    @memcpy(body[13..16], "bar");

    var ctx = testContext(&body);

    try std.testing.expectEqualStrings("foo", ctx.recvMessage().?);
    try std.testing.expectEqualStrings("bar", ctx.recvMessage().?);
    try std.testing.expect(ctx.recvMessage() == null);
}

test "zix http2 grpc: Context, recvMessage past the body returns null" {
    var body: [7]u8 = undefined;
    prefix.writeGrpcPrefix(body[0..prefix.PREFIX_LEN], false, 9);
    @memcpy(body[prefix.PREFIX_LEN..], "ab");

    var ctx = testContext(&body);

    try std.testing.expect(ctx.recvMessage() == null);
    try std.testing.expectEqual(@as(usize, 0), ctx._pos);
}

test "zix http2 grpc: Context, starts without a deadline" {
    const ctx = testContext(&.{});

    try std.testing.expect(ctx.deadline == null);
    try std.testing.expect(!ctx.isExpired());
}

test "zix http2 grpc: Context, withTimeout zero is expired" {
    const ctx = testContext(&.{}).withTimeout(0);

    try std.testing.expect(ctx.isExpired());
}

test "zix http2 grpc: Context, withTimeout in the future is not expired" {
    const ctx = testContext(&.{}).withTimeout(60_000);

    try std.testing.expect(!ctx.timedOut());
}

test "zix http2 grpc: Context, withDeadline in the past is expired" {
    const past = std.Io.Clock.Timestamp.now(std.testing.io, .real);
    const ctx = testContext(&.{}).withDeadline(past);

    try std.testing.expect(ctx.isExpired());
}

test "zix http2 grpc: Context, setTimeout replaces the deadline" {
    var ctx = testContext(&.{});

    ctx.setTimeout(60_000);
    try std.testing.expect(!ctx.isExpired());

    ctx.setTimeout(0);
    try std.testing.expect(ctx.isExpired());
}

test "zix http2 grpc: Context, sendHeaders stages HEADERS once" {
    var backing: [1024]u8 = undefined;
    var stage: ReplyStage = .{
        .fd = TEST_FD,
        .buf = &backing,
    };
    var ctx = stagedContext(&stage);

    try ctx.sendHeaders("application/grpc");
    const first_len = stage.len;
    try ctx.sendHeaders("application/grpc");

    try std.testing.expect(first_len > 0);
    try std.testing.expectEqual(first_len, stage.len);
    try std.testing.expectEqual(@as(usize, 1), walkStaged(stage.buf[0..stage.len]).headers);
}

test "zix http2 grpc: Context, unary reply stages HEADERS, DATA, and trailer" {
    var backing: [1024]u8 = undefined;
    var stage: ReplyStage = .{
        .fd = TEST_FD,
        .buf = &backing,
    };
    var ctx = stagedContext(&stage);

    try ctx.sendMessage("application/grpc", "pong");
    try ctx.finish(.OK, "");

    const walked = walkStaged(stage.buf[0..stage.len]);

    try std.testing.expectEqual(@as(usize, 2), walked.headers);
    try std.testing.expectEqual(@as(usize, 1), walked.data_frames);
    try std.testing.expectEqual(@as(usize, 4), ctx._sent_bytes);
}

test "zix http2 grpc: Context, finish before a message is trailers-only" {
    var backing: [1024]u8 = undefined;
    var stage: ReplyStage = .{
        .fd = TEST_FD,
        .buf = &backing,
    };
    var ctx = stagedContext(&stage);

    try ctx.finish(.NOT_FOUND, "missing");

    var expected: [builder.HEADERS_FRAME_SCRATCH]u8 = undefined;
    const status_code = @intFromEnum(GrpcStatus.NOT_FOUND);
    const len = try builder.buildGrpcError(&expected, 1, status_code, "missing");

    try std.testing.expectEqualSlices(u8, expected[0..len], stage.buf[0..stage.len]);
    try std.testing.expectEqual(status_code, ctx._grpc_status);
}

test "zix http2 grpc: Context, finishIfOpen closes an open call" {
    var backing: [1024]u8 = undefined;
    var stage: ReplyStage = .{
        .fd = TEST_FD,
        .buf = &backing,
    };
    var ctx = stagedContext(&stage);

    try std.testing.expect(ctx.finishIfOpen(.INTERNAL, "handler error"));
    try std.testing.expect(ctx._finished);
    try std.testing.expectEqual(@intFromEnum(GrpcStatus.INTERNAL), ctx._grpc_status);
}

test "zix http2 grpc: Context, finishIfOpen leaves a finished call alone" {
    var backing: [1024]u8 = undefined;
    var stage: ReplyStage = .{
        .fd = TEST_FD,
        .buf = &backing,
    };
    var ctx = stagedContext(&stage);

    try ctx.finish(.OK, "");
    const closed_len = stage.len;

    try std.testing.expect(!ctx.finishIfOpen(.INTERNAL, "handler error"));
    try std.testing.expectEqual(closed_len, stage.len);
    try std.testing.expectEqual(@intFromEnum(GrpcStatus.OK), ctx._grpc_status);
}

test "zix http2 grpc: Context, a failed stage reports BrokenPipe" {
    var backing: [1024]u8 = undefined;
    var stage: ReplyStage = .{
        .fd = TEST_FD,
        .buf = &backing,
        .failed = true,
    };
    var ctx = stagedContext(&stage);

    const result = ctx.sendMessage("application/grpc", "x");

    try std.testing.expectError(Error.ZixHttp2_GrpcContext_BrokenPipe, result);
}

test "zix http2 grpc: Context, content_type past the scratch is BufferFull" {
    var backing: [1024]u8 = undefined;
    var stage: ReplyStage = .{
        .fd = TEST_FD,
        .buf = &backing,
    };
    var ctx = stagedContext(&stage);
    const long: [builder.HEADERS_FRAME_SCRATCH]u8 = @splat('a');

    try std.testing.expectError(Error.ZixHttp2_GrpcContext_BufferFull, ctx.sendHeaders(&long));
}

test "zix http2 grpc: Context, sendMessage reports a dead peer" {
    if (!isLinux()) return;

    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[1]);

    // The peer end goes first, so the send has nowhere to land.
    _ = std.posix.system.close(fds[0]);

    var ctx = Self.init(std.testing.io, std.testing.allocator, fds[1], 1, &.{});
    ctx._hdr_sent = true;

    const result = ctx.sendMessage("application/grpc", "payload");

    try std.testing.expectError(Error.ZixHttp2_GrpcContext_BrokenPipe, result);
}

test "zix http2 grpc: Context, gzip reply sets the compress flag" {
    var backing: [1024]u8 = undefined;
    var stage: ReplyStage = .{
        .fd = TEST_FD,
        .buf = &backing,
    };
    var ctx = stagedContext(&stage);
    ctx._resp_gzip = true;
    ctx._hdr_sent = true;

    try ctx.sendMessage("application/grpc", "hello hello hello");

    const head_len = frame.FRAME_HEADER_LEN;

    try std.testing.expectEqual(@as(u8, 1), stage.buf[head_len]);
}

test "zix http2 grpc: Context, streaming packs many messages into one DATA frame" {
    var backing: [4096]u8 = undefined;
    var stage: ReplyStage = .{
        .fd = TEST_FD,
        .buf = &backing,
    };
    var coal: [STREAM_COALESCE_CAP]u8 = undefined;
    var ctx = stagedContext(&stage);
    ctx._hdr_sent = true;
    ctx._coal = &coal;

    try ctx.sendMessage("application/grpc", "aa");
    try ctx.sendMessage("application/grpc", "bb");
    try ctx.sendMessage("application/grpc", "cc");
    try ctx.finish(.OK, "");

    const walked = walkStaged(stage.buf[0..stage.len]);

    try std.testing.expectEqual(@as(usize, 1), walked.data_frames);
    try std.testing.expectEqual(@as(usize, 3), walked.messages);
}

test "zix http2 grpc: Context, streaming pack respects the frame cap" {
    var backing: [4096]u8 = undefined;
    var stage: ReplyStage = .{
        .fd = TEST_FD,
        .buf = &backing,
    };
    // Holds two framed 2-byte messages (7 bytes each), then must flush.
    var coal: [16]u8 = undefined;
    var ctx = stagedContext(&stage);
    ctx._hdr_sent = true;
    ctx._coal = &coal;

    for (0..5) |_| try ctx.sendMessage("application/grpc", "xy");
    try ctx.finish(.OK, "");

    const walked = walkStaged(stage.buf[0..stage.len]);

    try std.testing.expectEqual(@as(usize, 3), walked.data_frames);
    try std.testing.expectEqual(@as(usize, 5), walked.messages);
    try std.testing.expect(walked.max_data_payload <= coal.len);
}

test "zix http2 grpc: Context, streaming message past the pack gets its own frame" {
    var backing: [4096]u8 = undefined;
    var stage: ReplyStage = .{
        .fd = TEST_FD,
        .buf = &backing,
    };
    var coal: [8]u8 = undefined;
    var ctx = stagedContext(&stage);
    ctx._hdr_sent = true;
    ctx._coal = &coal;

    try ctx.sendMessage("application/grpc", "a");
    try ctx.sendMessage("application/grpc", "longer than the pack");
    try ctx.finish(.OK, "");

    const walked = walkStaged(stage.buf[0..stage.len]);

    try std.testing.expectEqual(@as(usize, 2), walked.data_frames);
    try std.testing.expectEqual(@as(usize, 2), walked.messages);
}

test "zix http2 grpc: Context, streaming small DATA frame is one write" {
    var probe: WriteHookProbe = .{};
    installProbe(&probe);
    defer removeProbe();

    var ctx = testContext(&.{});
    ctx._hdr_sent = true;

    try ctx.sendMessage("application/grpc", "pong");

    try std.testing.expectEqual(@as(usize, 1), probe.count);
    try std.testing.expectEqual(builder.DATA_HEAD_LEN + 4, probe.len);

    const header: FrameHeader = frame.parseFrameHeader(probe.buf[0..frame.FRAME_HEADER_LEN]);

    try std.testing.expectEqual(frame.FRAME_TYPE_DATA, header.frame_type);
    try std.testing.expectEqual(@as(u31, 1), header.stream_id);
    try std.testing.expectEqualStrings("pong", probe.buf[builder.DATA_HEAD_LEN..][0..4]);
}

test "zix http2 grpc: Context, streaming DATA past the inline cap is two writes" {
    var probe: WriteHookProbe = .{};
    installProbe(&probe);
    defer removeProbe();

    var ctx = testContext(&.{});
    ctx._hdr_sent = true;

    const big: [STREAM_INLINE_CAP + 1]u8 = @splat('x');
    try ctx.sendMessage("application/grpc", &big);

    try std.testing.expectEqual(@as(usize, 2), probe.count);
}

test "zix http2 grpc: Context, serveCached without a cache is a miss" {
    cache.setCache(null, 0);

    var ctx = testContext("req");
    ctx.path = "/svc.Svc/Method";

    try std.testing.expect(!try ctx.serveCached("application/grpc"));
}

test "zix http2 grpc: Context, serveCached with an empty path is a miss" {
    var resp_cache = try ResponseCache.init(std.testing.allocator, testCacheConfig());
    defer resp_cache.deinit();

    cache.setCache(&resp_cache, 1000);
    defer cache.setCache(null, 0);

    var ctx = testContext("req");

    try std.testing.expect(!try ctx.serveCached("application/grpc"));
}

test "zix http2 grpc: Context, sendCached stores and serveCached replays" {
    var resp_cache = try ResponseCache.init(std.testing.allocator, testCacheConfig());
    defer resp_cache.deinit();

    cache.setCache(&resp_cache, 1000);
    defer cache.setCache(null, 0);

    var backing: [1024]u8 = undefined;
    var stage: ReplyStage = .{
        .fd = TEST_FD,
        .buf = &backing,
    };

    var first = stagedContext(&stage);
    first.path = "/svc.Svc/Method";
    first._body = "request-body";

    try std.testing.expect(!try first.serveCached("application/grpc"));
    try first.sendCached("application/grpc", "unary-reply", 0);
    try first.finish(.OK, "");

    stage.len = 0;

    var second = stagedContext(&stage);
    second.path = "/svc.Svc/Method";
    second._body = "request-body";

    try std.testing.expect(try second.serveCached("application/grpc"));
    try std.testing.expect(second._finished);
    try std.testing.expect(std.mem.indexOf(u8, stage.buf[0..stage.len], "unary-reply") != null);
}

