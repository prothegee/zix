//! ZIX Http2 Grpc DispatchTask
//!
//! ### file: src/zix/tcp/http2/grpc/DispatchTask.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! One server-streaming call on its own task: a deep copy of the stream's
//! headers and body, so the read loop can reuse the stream slot at once.
//!
//! ### note:
//!
//! Heap-allocated by spawn and freed by the task when the handler returns.
//! Every write goes through the connection ConnMutex.
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
const deadline = @import("deadline.zig");
const encoding = @import("encoding.zig");
const frame = @import("../frame.zig");
const handler = @import("handler.zig");
const path = @import("path.zig");
const ConnMutex = @import("ConnMutex.zig");
const Context = @import("Context.zig");
const GrpcStatus = @import("status.zig").GrpcStatus;
const Header = @import("../hpack/Header.zig");
const Request = @import("Request.zig");
const ServeOpts = @import("ServeOpts.zig");
const Stream = @import("Stream.zig");

// --------------------------------------------------------- //
// Fields:

handler_fn: handler.HandlerFn,
fd: std.posix.fd_t,
stream_id: u31,
header_count: usize,
headers: [frame.MAX_HEADERS]Header,
/// Copy of the stream's HPACK strings. headers point into it.
header_scratch: [TASK_HEADER_SCRATCH_SIZE]u8,
body_len: usize,
body: [TASK_BODY_BUF_SIZE]u8,
opts: ServeOpts,
/// Held with one reference until the task ends.
conn_mutex: *ConnMutex,
io: std.Io,

const Self = @This();

// --------------------------------------------------------- //
// Private:

/// Close a call that never reached its handler, best effort.
fn answerError(
    fd: std.posix.fd_t,
    stream_id: u31,
    conn_mutex: *ConnMutex,
    io: std.Io,
    stat: GrpcStatus,
    grpc_message: []const u8,
) void {
    var ctx = Context.init(io, std.heap.smp_allocator, fd, stream_id, &.{});
    ctx._write_mutex = conn_mutex;

    _ = ctx.finishIfOpen(stat, grpc_message);
}

/// Point bytes at the task copy when they lived in the stream scratch.
///
/// Return:
/// - ?[]const u8 (null when the bytes lie past the copied part)
fn rebase(self: *Self, bytes: []const u8, src: []const u8, copied: usize) ?[]const u8 {
    const base = @intFromPtr(src.ptr);
    const addr = @intFromPtr(bytes.ptr);
    if (addr < base or addr >= base + src.len) return bytes;

    const offset = addr - base;
    if (offset + bytes.len > copied) return null;

    return self.header_scratch[offset..][0..bytes.len];
}

/// Copy the headers and their scratch, then point every header at the copy.
///
/// Return:
/// - bool (false when a header lies past TASK_HEADER_SCRATCH_SIZE)
fn copyHeaders(self: *Self, stream: *const Stream) bool {
    const copied = @min(self.header_scratch.len, stream.header_scratch.len);
    @memcpy(self.header_scratch[0..copied], stream.header_scratch[0..copied]);

    self.header_count = stream.header_count;
    self.headers = stream.headers;

    const src = stream.header_scratch;

    for (self.headers[0..self.header_count]) |*entry| {
        entry.name = self.rebase(entry.name, src, copied) orelse return false;
        entry.value = self.rebase(entry.value, src, copied) orelse return false;
    }

    return true;
}

/// Copy the body, gunzipped when the client sent grpc-encoding: gzip.
///
/// Return:
/// - bool (false when the body is past TASK_BODY_BUF_SIZE)
fn copyBody(self: *Self, stream: *const Stream, max_body: usize) bool {
    var decomp: ?[]u8 = null;
    defer if (decomp) |buf| std.heap.smp_allocator.free(buf);

    const body = encoding.maybeDecompressBody(
        stream.bodyBytes(),
        stream.headerList(),
        max_body,
        &decomp,
    );
    if (body.len > self.body.len) return false;

    @memcpy(self.body[0..body.len], body);
    self.body_len = body.len;

    return true;
}

/// Run the handler, then drop the task and its mutex reference.
fn run(self: *Self) void {
    const conn_mutex = self.conn_mutex;
    defer {
        _ = conn_mutex.active_streaming.fetchSub(1, .acq_rel);
        std.heap.smp_allocator.destroy(self);
        conn_mutex.release();
    }

    const headers = self.headers[0..self.header_count];
    const call_path = path.headerPath(headers);
    const started = handler.rpcStart(self.io, self.opts.logger);

    var arena_buf: [Context.CTX_ARENA_BYTES]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&arena_buf);

    const body = self.body[0..self.body_len];
    var ctx = Context.init(self.io, fba.allocator(), self.fd, self.stream_id, body);
    ctx.path = call_path;
    ctx.deadline = deadline.computeDeadline(self.io, self.opts.handler_timeout_ms, headers);
    ctx._write_mutex = conn_mutex;
    ctx._resp_gzip = self.opts.compress and encoding.headersAcceptGzip(headers);

    var req: Request = .{
        .path = call_path,
        .headers = headers,
        ._ctx = &ctx,
    };

    handler.invoke(self.handler_fn, &req, &ctx);
    handler.writeRpcRecord(self.opts.logger, started, &ctx, call_path, self.body_len);
}

// --------------------------------------------------------- //
// Public:

/// HPACK string bytes a task can carry.
pub const TASK_HEADER_SCRATCH_SIZE: usize = 4096;

/// Request body bytes a task can carry.
pub const TASK_BODY_BUF_SIZE: usize = 64 * 1024;

/// Run one finished stream on its own task. The caller frees the stream slot
/// right after.
///
/// Note:
/// - opts.io set runs the task on that pool. Null spawns a detached thread.
/// - A call that cannot be copied or started is closed at once: INTERNAL when
///   the task cannot be made, RESOURCE_EXHAUSTED when the body does not fit.
///
/// Param:
/// handler_fn - handler.HandlerFn (the router dispatch)
/// stream - *const Stream (the finished stream)
/// fd - std.posix.fd_t (the connection)
/// opts - ServeOpts (serve knobs carried to the call)
/// conn_mutex - *ConnMutex (the connection write lock)
/// io - std.Io (the worker io, carried on Context)
///
/// Return:
/// - void
pub fn spawn(
    handler_fn: handler.HandlerFn,
    stream: *const Stream,
    fd: std.posix.fd_t,
    opts: ServeOpts,
    conn_mutex: *ConnMutex,
    io: std.Io,
) void {
    const allocator = std.heap.smp_allocator;
    const task = allocator.create(Self) catch |err| switch (err) {
        error.OutOfMemory => {
            answerError(fd, stream.id, conn_mutex, io, .INTERNAL, "server overloaded");

            return;
        },
    };

    if (!task.copyHeaders(stream)) {
        allocator.destroy(task);
        answerError(fd, stream.id, conn_mutex, io, .INTERNAL, "request headers too large");

        return;
    }

    if (!task.copyBody(stream, opts.max_body)) {
        allocator.destroy(task);
        answerError(
            fd,
            stream.id,
            conn_mutex,
            io,
            .RESOURCE_EXHAUSTED,
            "request message exceeds max_body",
        );

        return;
    }

    task.handler_fn = handler_fn;
    task.fd = fd;
    task.stream_id = stream.id;
    task.opts = opts;
    task.io = io;
    task.conn_mutex = conn_mutex;

    _ = conn_mutex.active_streaming.fetchAdd(1, .monotonic);
    conn_mutex.retain();

    if (opts.io) |pool_io| {
        _ = pool_io.async(run, .{task});

        return;
    }

    const thread = std.Thread.spawn(.{}, run, .{task}) catch |err| switch (err) {
        // The call is answered here, the connection keeps serving.
        else => {
            _ = conn_mutex.active_streaming.fetchSub(1, .acq_rel);
            conn_mutex.release();
            allocator.destroy(task);
            answerError(fd, stream.id, conn_mutex, io, .INTERNAL, "spawn failed");

            return;
        },
    };

    thread.detach();
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const builtin = @import("builtin");
const pair = @import("../../../utils/socket/pair.zig");
const prefix = @import("frame/prefix.zig");
const Response = @import("Response.zig");

fn echoHandler(req: *Request, res: *Response, _: *Context) anyerror!void {
    while (req.recvMessage()) |msg| try res.sendMessage("application/grpc", msg);

    try res.finish(.OK, "");
}

fn isLinux() bool {
    if (comptime builtin.target.os.tag == .linux) return true;

    std.log.info("this test drives a Linux socket pair, test skipped", .{});

    return false;
}

fn newTask() !*Self {
    return std.testing.allocator.create(Self);
}

test "zix http2 grpc: DispatchTask, copyHeaders points headers at the copy" {
    var scratch: [16]u8 = undefined;
    @memcpy(scratch[0..5], ":path");
    @memcpy(scratch[5..9], "/a/b");

    var stream: Stream = .{
        .header_scratch = &scratch,
    };
    stream.headers[0] = .{
        .name = scratch[0..5],
        .value = scratch[5..9],
    };
    stream.header_count = 1;

    const task = try newTask();
    defer std.testing.allocator.destroy(task);

    try std.testing.expect(task.copyHeaders(&stream));

    const name_addr = @intFromPtr(task.headers[0].name.ptr);

    try std.testing.expectEqual(@intFromPtr(&task.header_scratch), name_addr);
    try std.testing.expectEqualStrings("/a/b", task.headers[0].value);
}

test "zix http2 grpc: DispatchTask, copyHeaders keeps a static table string" {
    var scratch: [8]u8 = undefined;
    var stream: Stream = .{
        .header_scratch = &scratch,
    };
    stream.headers[0] = .{
        .name = ":method",
        .value = "POST",
    };
    stream.header_count = 1;

    const task = try newTask();
    defer std.testing.allocator.destroy(task);

    try std.testing.expect(task.copyHeaders(&stream));
    try std.testing.expectEqualStrings(":method", task.headers[0].name);
}

test "zix http2 grpc: DispatchTask, copyHeaders past the task scratch refuses" {
    const scratch = try std.testing.allocator.alloc(u8, TASK_HEADER_SCRATCH_SIZE + 8);
    defer std.testing.allocator.free(scratch);

    var stream: Stream = .{
        .header_scratch = scratch,
    };
    stream.headers[0] = .{
        .name = scratch[TASK_HEADER_SCRATCH_SIZE..][0..4],
        .value = "x",
    };
    stream.header_count = 1;

    const task = try newTask();
    defer std.testing.allocator.destroy(task);

    try std.testing.expect(!task.copyHeaders(&stream));
}

test "zix http2 grpc: DispatchTask, copyBody copies the body" {
    var body: [4]u8 = "ping".*;
    var stream: Stream = .{
        .body = &body,
        .body_len = 4,
    };

    const task = try newTask();
    defer std.testing.allocator.destroy(task);

    try std.testing.expect(task.copyBody(&stream, 16));
    try std.testing.expectEqualStrings("ping", task.body[0..task.body_len]);
}

test "zix http2 grpc: DispatchTask, copyBody past the task buffer refuses" {
    const body = try std.testing.allocator.alloc(u8, TASK_BODY_BUF_SIZE + 1);
    defer std.testing.allocator.free(body);

    var stream: Stream = .{
        .body = body,
        .body_len = body.len,
    };

    const task = try newTask();
    defer std.testing.allocator.destroy(task);

    try std.testing.expect(!task.copyBody(&stream, body.len));
}

test "zix http2 grpc: DispatchTask, spawn runs the handler on a thread" {
    if (!isLinux()) return;

    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    var body: [9]u8 = undefined;
    prefix.writeGrpcPrefix(body[0..prefix.PREFIX_LEN], false, 4);
    @memcpy(body[prefix.PREFIX_LEN..], "ping");

    var stream: Stream = .{
        .body = &body,
        .body_len = body.len,
    };
    stream.open(1);
    stream.body_len = body.len;

    const conn_mutex = try ConnMutex.create();
    defer conn_mutex.release();

    spawn(echoHandler, &stream, fds[1], .{}, conn_mutex, std.testing.io);

    var reply: [512]u8 = undefined;
    var total: usize = 0;
    while (std.mem.indexOf(u8, reply[0..total], "ping") == null) {
        const got = try std.posix.read(fds[0], reply[total..]);
        if (got == 0) break;

        total += got;
    }

    while (conn_mutex.streamingActive()) std.atomic.spinLoopHint();

    try std.testing.expect(std.mem.indexOf(u8, reply[0..total], "ping") != null);
}

