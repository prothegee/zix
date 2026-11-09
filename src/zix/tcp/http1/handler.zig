//! ZIX Http1 handler
//!
//! ### file: src/zix/tcp/http1/handler.zig
//! 
//! ### author: Prana Ron
//! 
//! ---------------------------------------------------------
//! 
//! ### brief:
//! 
//! Handler contract and the one place a handler is invoked.
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
const Status = @import("../../utils/http/status.zig");
const Method = @import("../../utils/http/method.zig");
const peer_addr = @import("../../utils/peer_address.zig");
const Logger = @import("../../logger/Logger.zig");
const BodyInfo = @import("BodyInfo.zig");
const Context = @import("Context.zig");
const ParsedHead = @import("ParsedHead.zig");
const Request = @import("Request.zig");
const Response = @import("Response.zig");
const writer = @import("writer.zig");

// --------------------------------------------------------- //
// Private:

/// Per-handler deadline, thread-local so each worker tracks its own request.
/// 0 means no deadline is active.
threadlocal var tl_deadline_ns: u64 = 0;

/// The io that armed tl_deadline_ns, kept so isExpired can read the same clock
/// without an io argument.
threadlocal var tl_deadline_io: ?std.Io = null;

/// Wall-clock nanoseconds since the epoch.
fn wallClockNs(io: std.Io) u64 {
    const ts = std.Io.Clock.Timestamp.now(io, .real);

    return @intCast(ts.raw.toNanoseconds());
}

/// Log one served request, when a logger is attached.
///
/// Note:
/// - The whole call costs one threadlocal load and one branch when no logger is
///   attached, which is what keeps a raw engine paying nothing for a feature it
///   did not ask for.
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
        "http1",
        Method.stringFromEnum(req.method()),
        req.path(),
        @intFromEnum(res.status),
        res.bytes_written,
        client_ip,
        req.header("user-agent") orelse "",
        req.header("origin") orelse "",
    );
}

// --------------------------------------------------------- //
// Public:

/// The logger this worker writes access records to, or null.
pub threadlocal var tl_access_logger: ?*Logger = null;

/// Attach the access logger for this worker or connection.
pub fn setAccessLogger(logger: ?*Logger) void {
    tl_access_logger = logger;
}

/// Handler signature: the ergonomic request, response, context trio.
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

/// Body measurements for the request about to be invoked. Null is the common
/// case and the one the bodyless hot path takes, so the check costs one load
/// and one branch. Consumed and cleared by invokeHandler, so it never leaks
/// into a later request on the same thread.
pub threadlocal var tl_body_info: ?BodyInfo = null;

/// Arm or clear the per-handler deadline for the current thread.
/// The server calls this before each dispatch with config.handler_timeout_ms.
/// Handlers may call it to shorten their own budget. ms = 0 clears the
/// deadline.
///
/// Param:
/// io - std.Io (the worker io used to read the wall clock)
/// ms - u32 (budget in milliseconds, 0 clears)
pub fn setTimeout(io: std.Io, ms: u32) void {
    tl_deadline_io = io;
    tl_deadline_ns = if (ms == 0)
        0
    else
        wallClockNs(io) + @as(u64, ms) * std.time.ns_per_ms;
}

/// Whether the per-handler deadline armed for this thread has passed.
///
/// Note:
/// - Same budget as ctx.isExpired() before a handler shortens its own
///   deadline with ctx.setTimeout.
/// - The handler must check it, nothing is interrupted.
///
/// Return:
/// - true when a deadline is armed and has passed
/// - false when no deadline is armed or it is still ahead
pub fn isExpired() bool {
    if (tl_deadline_ns == 0) return false;

    const io = tl_deadline_io orelse return false;

    return wallClockNs(io) >= tl_deadline_ns;
}

/// Build the request, response, and context trio over a parsed request and
/// hand it to the handler. One place builds the trio, so every dispatch model
/// invokes a handler the same way.
///
/// Note:
/// - On an error return the response is completed with a 500, but only when the
///   handler wrote nothing, so a handler that already sent a response and then
///   failed does not corrupt the stream.
/// - "Wrote nothing" covers both answer styles: the Response builder
///   (`Response.sent`) and the fd writers (`respondedFD`). A handler that
///   answers with sendSimpleFD or writeAllFD holds no Response, so checking
///   `Response.sent` alone read it as unanswered and appended a second status
///   line to a response the peer was already reading.
/// - An error the handler swallows itself is the handler's own business. The
///   engine completes an error the handler returns, nothing else.
///
/// Param:
/// handler_fn - HandlerFn (the route or top-level handler)
/// head - *const ParsedHead (borrows the receive buffer)
/// body - []const u8 (already drained by the engine)
/// fd - std.posix.fd_t (the connection)
/// io - std.Io (the worker io, carried for ctx and an inline driver call)
/// allocator - std.mem.Allocator (per-request scratch, reset by the engine)
///
/// Return:
/// - void
pub inline fn invokeHandler(
    handler_fn: HandlerFn,
    head: *const ParsedHead,
    body: []const u8,
    fd: std.posix.fd_t,
    io: std.Io,
    allocator: std.mem.Allocator,
) void {
    var req = Request.init(head, body, fd);
    var res = Response.init(fd, io, allocator);
    var ctx = Context.init(io, allocator, fd);
    ctx.logger = tl_access_logger;
    if (tl_deadline_ns != 0) {
        ctx.deadline = std.Io.Timestamp.fromNanoseconds(tl_deadline_ns).withClock(.real);
    }

    if (tl_body_info) |info| {
        req.body_received = info.received;
        req.body_complete = info.complete;
        tl_body_info = null;
    }

    // Cleared here rather than at connection setup: the 100-continue an Expect
    // request gets is written by the engine before this point, and that interim
    // write is not the handler answering.
    writer.tl_responded = false;

    handler_fn(&req, &res, &ctx) catch |err| switch (err) {
        else => {
            if (!res.sent and !writer.respondedFD()) {
                writer.sendSimpleFD(
                    io, fd, .INTERNAL_SERVER_ERROR, "text/plain", "Internal Server Error",
                ) catch |write_err| switch (write_err) {
                    error.ZixHttp1_Writer_BrokenPipe,
                    error.ZixHttp1_Writer_HeadBuild,
                    => {},
                };
                res.status = .INTERNAL_SERVER_ERROR;
            }
        },
    };

    writeAccessRecord(&req, &res, fd);
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const pair = @import("../../utils/socket/pair.zig");

fn failingHandler(_: *Request, _: *Response, _: *Context) anyerror!void {
    return error.ZixTest_HandlerFailed;
}

fn bodyInfoHandler(req: *Request, res: *Response, _: *Context) anyerror!void {
    try std.testing.expectEqual(@as(u64, 4), req.bodyReceived());
    try std.testing.expect(req.bodyComplete());

    try res.send("ok");
}

threadlocal var tl_seen_deadline: ?std.Io.Clock.Timestamp = null;

fn deadlineProbeHandler(_: *Request, res: *Response, ctx: *Context) anyerror!void {
    tl_seen_deadline = ctx.deadline;

    try res.send("ok");
}

fn testHead() ParsedHead {
    return .{
        .path = "/",
        .query = "",
        .method = "GET",
        .keep_alive = true,
        .raw_headers = "",
        .version_minor = 1,
        .content_length = 0,
        .chunked_request = false,
        .expect_continue = false,
    };
}

test "zix http1: handler, error becomes 500" {
    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    const head_module = @import("head.zig");
    head_module.setDateHeader(false);
    defer head_module.setDateHeader(true);

    const parsed = testHead();
    invokeHandler(failingHandler, &parsed, "", fds[0], std.testing.io, std.testing.allocator);

    var buf: [512]u8 = undefined;
    const n = try std.posix.read(fds[1], &buf);

    try std.testing.expectEqualStrings(
        "HTTP/1.1 500 Internal Server Error\r\n" ++
        "Content-Type: text/plain\r\n" ++
        "Content-Length: 21\r\n\r\nInternal Server Error",
        buf[0..n],
    );
}

test "zix http1: handler, body info reaches the request" {
    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    const head_module = @import("head.zig");
    head_module.setDateHeader(false);
    defer head_module.setDateHeader(true);

    tl_body_info = .{ .received = 4, .complete = true };
    const parsed = testHead();
    invokeHandler(
        bodyInfoHandler, &parsed, "body", fds[0], std.testing.io, std.testing.allocator,
    );

    try std.testing.expect(tl_body_info == null);
}

fn writesThenFails(req: *Request, res: *Response, _: *Context) anyerror!void {
    _ = req;
    try res.send("ok");

    return error.ZixTest_AfterWrite;
}

test "zix http1: handler, answered then failed gets no second response" {
    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    const head_module = @import("head.zig");
    head_module.setDateHeader(false);
    defer head_module.setDateHeader(true);

    const parsed = testHead();
    invokeHandler(writesThenFails, &parsed, "", fds[0], std.testing.io, std.testing.allocator);

    var buf: [256]u8 = undefined;
    const n = try std.posix.read(fds[1], &buf);

    try std.testing.expectEqualStrings(
        "HTTP/1.1 200 Ok\r\nContent-Length: 2\r\n\r\nok",
        buf[0..n],
    );
}

fn accessProbeHandler(_: *Request, res: *Response, _: *Context) anyerror!void {
    res.setStatus(.CREATED);

    try res.send("hello");
}

test "zix http1: handler, access record names the engine" {
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

    const parsed = ParsedHead{
        .path = "/orders/42",
        .query = "",
        .method = "GET",
        .keep_alive = true,
        .raw_headers = "x-forwarded-for: 203.0.113.7\r\n" ++
            "user-agent: curl/8.5.0\r\n",
        .version_minor = 1,
        .content_length = 0,
        .chunked_request = false,
        .expect_continue = false,
    };

    invokeHandler(
        accessProbeHandler,
        &parsed,
        "",
        fds[0],
        std.testing.io,
        std.testing.allocator,
    );
    logger.flush();

    const line = try readLoggedLine(tmp.dir, std.testing.allocator);
    defer std.testing.allocator.free(line);

    try std.testing.expect(std.mem.indexOf(
        u8,
        line,
        "[http1:access] GET /orders/42 201 5 " ++
            "\"203.0.113.7\" \"curl/8.5.0\" \"-\"",
    ) != null);
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

    return error.ZixNoLogLine;
}

test "zix http1: handler, isExpired is false without a deadline" {
    setTimeout(std.testing.io, 0);

    try std.testing.expect(!isExpired());
}

test "zix http1: handler, isExpired is false before the deadline" {
    setTimeout(std.testing.io, 60_000);
    defer setTimeout(std.testing.io, 0);

    try std.testing.expect(!isExpired());
}

test "zix http1: handler, isExpired is true past the deadline" {
    setTimeout(std.testing.io, 60_000);
    defer setTimeout(std.testing.io, 0);

    tl_deadline_ns = 1;

    try std.testing.expect(isExpired());
}

test "zix http1: handler, armed budget fills the context deadline" {
    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    setTimeout(std.testing.io, 60_000);
    defer setTimeout(std.testing.io, 0);

    tl_seen_deadline = null;
    const parsed = testHead();
    invokeHandler(
        deadlineProbeHandler, &parsed, "", fds[0], std.testing.io, std.testing.allocator,
    );

    const seen = tl_seen_deadline orelse return error.ZixTest_NoDeadline;
    try std.testing.expectEqual(std.Io.Clock.real, seen.clock);
    try std.testing.expectEqual(@as(i96, tl_deadline_ns), seen.raw.toNanoseconds());
}

test "zix http1: handler, no budget leaves the context deadline empty" {
    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    setTimeout(std.testing.io, 0);
    tl_seen_deadline = std.Io.Clock.Timestamp.now(std.testing.io, .real);

    const parsed = testHead();
    invokeHandler(
        deadlineProbeHandler, &parsed, "", fds[0], std.testing.io, std.testing.allocator,
    );

    try std.testing.expect(tl_seen_deadline == null);
}

