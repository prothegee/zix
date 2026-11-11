//! ZIX Http2 handler
//!
//! ### file: src/zix/tcp/http2/handler.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Handler contract and the one place an HTTP/2 handler is invoked.
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
const peer_addr = @import("../../utils/peer_address.zig");
const Logger = @import("../../logger/Logger.zig");
const Context = @import("Context.zig");
const Request = @import("Request.zig");
const Response = @import("Response.zig");
const ServeOpts = @import("ServeOpts.zig");
const writer = @import("writer.zig");

// --------------------------------------------------------- //
// Private:

/// Log one served stream, when a logger is attached.
///
/// Note:
/// - Costs one threadlocal load and one branch when no logger is attached.
/// - The client address falls back to the socket when no proxy header names
///   one, so a direct request is logged with a real address.
fn writeAccessRecord(req: *const Request, res: *const Response, fd: std.posix.fd_t) void {
    const logger = tl_access_logger orelse return;

    var peer_buf: [peer_addr.MAX_LEN]u8 = undefined;
    const client_ip = peer_addr.clientIp(
        req.header("x-forwarded-for") orelse "",
        req.header("x-real-ip") orelse "",
        fd,
        &peer_buf,
    );

    logger.access(
        "http2",
        req.method,
        req.path,
        res.status,
        res.bytes_written,
        client_ip,
        req.header("user-agent") orelse "",
        req.header("origin") orelse "",
    );
}

/// Answer a failed handler with one 500, unless it already answered.
fn completeError(fd: std.posix.fd_t, sid: u31, res: *Response) void {
    @branchHint(.cold);

    if (res.sent or writer.respondedFD()) return;

    writer.sendResponseFD(
        fd,
        sid,
        500,
        "text/plain",
        "Internal Server Error",
    ) catch |err| switch (err) {
        // Best effort: the peer went away. The connection loop sees the
        // broken socket on its next read.
        error.ZixHttp2_Writer_BrokenPipe,
        error.ZixHttp2_Writer_UnexpectedEOF,
        error.ZixHttp2_Writer_Overflow,
        error.ZixHttp2_Writer_BufferFull,
        => {},
    };
    res.status = 500;
}

// --------------------------------------------------------- //
// Public:

/// The logger this worker writes access records to, or null.
pub threadlocal var tl_access_logger: ?*Logger = null;

/// Attach the access logger for this worker or connection.
pub fn setAccessLogger(logger: ?*Logger) void {
    tl_access_logger = logger;
}

/// Handler signature: the request, response, context trio.
///
/// Note:
/// - All slices the request exposes are valid only for the duration of the
///   call.
/// - A returned error is completed by the engine as a 500 when the handler
///   wrote nothing.
pub const HandlerFn = *const fn (
    req: *Request,
    res: *Response,
    ctx: *Context,
) anyerror!void;

/// Build the response and context for one stream and hand the trio to the
/// handler. One place builds the trio, so every dispatch model invokes a
/// handler the same way.
///
/// Note:
/// - "Wrote nothing" covers both answer styles: the Response builder
///   (`Response.sent`) and the fd writers (`respondedFD`). Checking `sent`
///   alone would put a second HEADERS frame on a stream the peer saw closed.
/// - An error the handler swallows itself is the handler's own business.
///
/// Param:
/// handler_fn - HandlerFn (the route or top-level handler)
/// req - *Request (already built by the caller)
/// fd - std.posix.fd_t (the connection)
/// sid - u31 (the stream id)
/// io - std.Io (the worker io, carried on Context)
/// opts - ServeOpts (handler_timeout_ms and public_dir)
/// peer_max_frame_size - u32 (the peer's SETTINGS_MAX_FRAME_SIZE)
///
/// Return:
/// - void
pub inline fn invokeHandler(
    handler_fn: HandlerFn,
    req: *Request,
    fd: std.posix.fd_t,
    sid: u31,
    io: std.Io,
    opts: ServeOpts,
    peer_max_frame_size: u32,
) void {
    var res: Response = .{
        .fd = fd,
        .sid = sid,
    };
    var arena_buf: [Context.CTX_ARENA_BYTES]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&arena_buf);
    var ctx = Context.init(io, fba.allocator(), fd, sid);
    ctx.public_dir = opts.public_dir;
    ctx.max_frame_size = peer_max_frame_size;
    if (opts.handler_timeout_ms > 0) ctx.setTimeout(opts.handler_timeout_ms);

    // Cleared here rather than per connection: SETTINGS and the WINDOW_UPDATE
    // frames that paced this request were written before dispatch, and neither
    // is the handler answering.
    writer.tl_responded = false;

    handler_fn(req, &res, &ctx) catch |err| switch (err) {
        else => completeError(fd, sid, &res),
    };

    writeAccessRecord(req, &res, fd);
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const frame = @import("frame.zig");
const pair = @import("../../utils/socket/pair.zig");
const Header = @import("hpack/Header.zig");

threadlocal var tl_seen_ctx: ?Context = null;

fn testRequest() Request {
    return .{
        .method = "GET",
        .path = "/probe",
        .query = "",
        .headers = &.{},
        .body = "",
    };
}

fn fdThenErrorHandler(_: *Request, _: *Response, ctx: *Context) anyerror!void {
    try writer.sendResponseFD(ctx.fd, ctx.sid, 200, "text/plain", "fd answered");

    return error.ZixTest_ProbeFailure;
}

fn responseThenErrorHandler(_: *Request, res: *Response, _: *Context) anyerror!void {
    try res.send("res answered");

    return error.ZixTest_ProbeFailure;
}

fn errorBeforeAnswerHandler(_: *Request, _: *Response, _: *Context) anyerror!void {
    return error.ZixTest_ProbeFailure;
}

fn swallowedErrorHandler(_: *Request, res: *Response, _: *Context) anyerror!void {
    res.send("swallowed") catch |err| switch (err) {
        else => return error.ZixTest_ProbeFailure,
    };
}

fn accessProbeHandler(_: *Request, res: *Response, _: *Context) anyerror!void {
    res.setStatus(202);

    try res.send("queued!");
}

fn ctxProbeHandler(_: *Request, res: *Response, ctx: *Context) anyerror!void {
    tl_seen_ctx = ctx.*;

    try res.send("ok");
}

/// Run one handler over a socket pair and return every byte the peer got.
fn wireOf(handler_fn: HandlerFn, opts: ServeOpts, buf: []u8) ![]u8 {
    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[1]);

    var req = testRequest();
    invokeHandler(
        handler_fn,
        &req,
        fds[0],
        1,
        std.testing.io,
        opts,
        frame.DEFAULT_MAX_FRAME_SIZE,
    );

    // Closed before the read so the peer sees EOF instead of blocking.
    _ = std.posix.system.close(fds[0]);

    var total: usize = 0;
    while (total < buf.len) {
        const got = try std.posix.read(fds[1], buf[total..]);
        if (got == 0) break;

        total += got;
    }

    return buf[0..total];
}

/// Count HEADERS frames in a raw h2 byte stream.
fn countHeadersFrames(wire: []const u8) usize {
    var pos: usize = 0;
    var found: usize = 0;

    while (pos + frame.FRAME_HEADER_LEN <= wire.len) {
        const header = frame.parseFrameHeader(wire[pos..][0..frame.FRAME_HEADER_LEN]);
        if (header.frame_type == frame.FRAME_TYPE_HEADERS) found += 1;

        pos += frame.FRAME_HEADER_LEN + header.length;
    }

    return found;
}

fn readLoggedLine(root: std.Io.Dir, allocator: std.mem.Allocator) ![]u8 {
    var days = root.iterate();

    while (try days.next(std.testing.io)) |entry| {
        if (entry.kind != .directory) continue;

        var day = try root.openDir(std.testing.io, entry.name, .{});
        defer day.close(std.testing.io);

        const bytes = day.readFileAlloc(
            std.testing.io,
            "log-000000.log",
            allocator,
            .limited(64 * 1024),
        ) catch continue;
        if (bytes.len > 0) return bytes;

        allocator.free(bytes);
    }

    return error.ZixTest_NoLogLine;
}

test "zix http2: handler, error with nothing answered becomes one 500" {
    var buf: [4096]u8 = undefined;
    const wire = try wireOf(errorBeforeAnswerHandler, .{}, &buf);

    try std.testing.expectEqual(@as(usize, 1), countHeadersFrames(wire));
    try std.testing.expect(std.mem.indexOf(u8, wire, "Internal Server Error") != null);
}

test "zix http2: handler, fd answer then error gets no second response" {
    var buf: [4096]u8 = undefined;
    const wire = try wireOf(fdThenErrorHandler, .{}, &buf);

    try std.testing.expectEqual(@as(usize, 1), countHeadersFrames(wire));
    try std.testing.expect(std.mem.indexOf(u8, wire, "fd answered") != null);
    try std.testing.expect(std.mem.indexOf(u8, wire, "Internal Server Error") == null);
}

test "zix http2: handler, Response answer then error gets no second response" {
    var buf: [4096]u8 = undefined;
    const wire = try wireOf(responseThenErrorHandler, .{}, &buf);

    try std.testing.expectEqual(@as(usize, 1), countHeadersFrames(wire));
    try std.testing.expect(std.mem.indexOf(u8, wire, "res answered") != null);
    try std.testing.expect(std.mem.indexOf(u8, wire, "Internal Server Error") == null);
}

test "zix http2: handler, swallowed error gets nothing from the engine" {
    var buf: [4096]u8 = undefined;
    const wire = try wireOf(swallowedErrorHandler, .{}, &buf);

    try std.testing.expectEqual(@as(usize, 1), countHeadersFrames(wire));
    try std.testing.expect(std.mem.indexOf(u8, wire, "swallowed") != null);
}

test "zix http2: handler, context carries opts and peer frame size" {
    var buf: [4096]u8 = undefined;
    tl_seen_ctx = null;

    _ = try wireOf(ctxProbeHandler, .{
        .public_dir = "public",
        .handler_timeout_ms = 60_000,
    }, &buf);

    const seen = tl_seen_ctx.?;

    try std.testing.expectEqualStrings("public", seen.public_dir);
    try std.testing.expectEqual(frame.DEFAULT_MAX_FRAME_SIZE, seen.max_frame_size);
    try std.testing.expect(seen.deadline != null);
}

test "zix http2: handler, zero timeout leaves no deadline" {
    var buf: [4096]u8 = undefined;
    tl_seen_ctx = null;

    _ = try wireOf(ctxProbeHandler, .{}, &buf);

    try std.testing.expect(tl_seen_ctx.?.deadline == null);
}

test "zix http2: handler, access record names the engine" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var root_buf: [64]u8 = undefined;
    const root = try std.fmt.bufPrint(
        &root_buf,
        ".zig-cache/tmp/{s}",
        .{tmp.sub_path},
    );

    var logger = try Logger.init(std.testing.allocator, .{
        .console = .OFF,
        .save_path = root,
        .save_min_level = .DEBUG,
    });
    defer logger.deinit();

    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    setAccessLogger(&logger);
    defer setAccessLogger(null);

    const headers = [_]Header{
        .{
            .name = "x-real-ip",
            .value = "198.51.100.9",
        },
        .{
            .name = "user-agent",
            .value = "h2load/1.0",
        },
    };
    var req: Request = .{
        .method = "POST",
        .path = "/rpc/submit",
        .query = "",
        .headers = &headers,
        .body = "",
    };

    invokeHandler(
        accessProbeHandler,
        &req,
        fds[0],
        1,
        std.testing.io,
        .{},
        frame.DEFAULT_MAX_FRAME_SIZE,
    );
    logger.flush();

    const line = try readLoggedLine(tmp.dir, std.testing.allocator);
    defer std.testing.allocator.free(line);

    try std.testing.expect(std.mem.indexOf(
        u8,
        line,
        "[http2:access] POST /rpc/submit 202 7 " ++
            "\"198.51.100.9\" \"h2load/1.0\" \"-\"",
    ) != null);
}

test "zix http2: handler, no logger writes no access record" {
    setAccessLogger(null);

    var buf: [4096]u8 = undefined;
    const wire = try wireOf(accessProbeHandler, .{}, &buf);

    try std.testing.expectEqual(@as(usize, 1), countHeadersFrames(wire));
    try std.testing.expect(tl_access_logger == null);
}

