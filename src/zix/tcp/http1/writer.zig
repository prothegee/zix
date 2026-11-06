//! ZIX Http1 writer
//!
//! ### file: src/zix/tcp/http1/writer.zig
//! 
//! ### author: Prana Ron
//! 
//! ---------------------------------------------------------
//! 
//! ### brief:
//! 
//! Bytes to a connection: direct writes and the simple response helpers.
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
const head = @import("head.zig");
const cache = @import("cache.zig");
const RespSink = @import("RespSink.zig");

// --------------------------------------------------------- //
// Private:

/// Inline write fast-path buffer. A response whose status line, headers, and
/// body all fit here is sent in one direct write, skipping the iovec scatter
/// path. The body threshold is this minus HEADER_BUF_SIZE.
const SMALL_BODY_INLINE_BUF: usize = 4096;

// --------------------------------------------------------- //
// Public:

/// ZIX Http1 writer error
pub const Error = error {
    ZixHttp1_Writer_BrokenPipe,
    ZixHttp1_Writer_HeadBuild,
};

/// Whether response bytes for the request in flight have already reached the wire.
///
/// Note:
/// - The `Response` builder tracks the same thing in `Response.sent`, but a
///   handler may answer through the fd writers instead, which hold no
///   `Response`. Without this the engine reads such a handler as never having
///   answered and completes it a second time.
/// - A threadlocal because the fd writers take an fd and nothing else. Cleared
///   by invokeHandler, so it never carries into the next request on this thread.
pub threadlocal var tl_responded: bool = false;

/// Coalescing sink for the current worker. null sends every write straight to
/// the fd.
pub threadlocal var tl_resp_sink: ?*RespSink = null;

/// Record that response bytes for the request in flight reached the wire.
pub fn markResponded() void {
    tl_responded = true;
}

/// Whether the request in flight has been answered through the fd writers.
///
/// Return:
/// - bool
pub fn respondedFD() bool {
    return tl_responded;
}

/// Write all of data to fd, retrying partial writes.
pub fn writeAllDirectFD(fd: std.posix.fd_t, data: []const u8) Error!void {
    var rem = data;
    while (rem.len > 0) {
        const rc = std.posix.system.write(fd, rem.ptr, rem.len);
        switch (std.posix.errno(rc)) {
            .SUCCESS => {
                const n: usize = @intCast(rc);
                if (n == 0) return Error.ZixHttp1_Writer_BrokenPipe;
                rem = rem[n..];
            },
            .INTR => continue,
            // Non-blocking socket with a full send buffer: wait for the peer
            // to drain it, then retry. Blocking sockets never hit this branch.
            .AGAIN => {
                var pfd = [_]std.posix.pollfd{.{
                    .fd = fd,
                    .events = std.posix.POLL.OUT,
                    .revents = 0,
                }};
                _ = std.posix.poll(&pfd, -1) catch |err| switch (err) {
                    else => return Error.ZixHttp1_Writer_BrokenPipe,
                };
            },
            else => return Error.ZixHttp1_Writer_BrokenPipe,
        }
    }
}

/// Write response bytes to fd, the canonical write behind every send helper.
/// Routes through the coalescing sink (tl_resp_sink) when one is installed for
/// this worker, otherwise writes directly.
///
/// Note:
/// - Marks the request in flight as answered, so a handler that writes here
///   directly is not completed a second time by invokeHandler. Every send
///   helper lands here.
pub fn writeAllFD(fd: std.posix.fd_t, data: []const u8) Error!void {
    markResponded();

    if (tl_resp_sink) |sink| {
        if (sink.fd == fd) {
            // Zero-copy cache replay: a whole-response hit written while the
            // batch is empty is borrowed (slot pinned) instead of copied. Only
            // the exact slice the cache lookup returned qualifies.
            if (sink.allow_direct and sink.len == 0 and sink.direct.len == 0) {
                if (cache.tl_cache) |resp_cache| {
                    if (resp_cache.hitSlot(data)) |slot| {
                        resp_cache.pin(slot);
                        sink.direct = data;
                        sink.direct_slot = slot;

                        return;
                    }
                }
            }

            sink.materializeDirect();
            sink.append(data);
            if (sink.failed) return Error.ZixHttp1_Writer_BrokenPipe;

            return;
        }
    }

    return writeAllDirectFD(fd, data);
}

/// Begin a streaming response (SSE) from a handler.
///
/// Note:
/// - Detaches the coalescing sink, so each subsequent writeAllFD flushes
///   immediately. An SSE handler never returns, so a buffered sink would never
///   flush.
/// - A no-op when no sink is installed.
pub fn beginStream() void {
    if (tl_resp_sink) |sink| {
        sink.materializeDirect();
        sink.flush();
        tl_resp_sink = null;
    }
}

/// Response with a Content-Length body.
///
/// Note:
/// - Marks the request in flight as answered. The sink fast path below builds
///   straight into the batch and never reaches writeAllFD, so the mark cannot
///   be left to that writer alone.
pub fn sendSimpleFD(
    io: std.Io,
    fd: std.posix.fd_t,
    status: Status.Code,
    content_type: []const u8,
    body: []const u8,
) Error!void {
    markResponded();

    if (tl_resp_sink) |sink| {
        if (sink.fd == fd) {
            // A pending zero-copy replay must land in the batch before this
            // response so the wire order matches the request order.
            sink.materializeDirect();

            // Fast path: build header directly into sink.buf at sink.len, then
            // append body. Eliminates the hdr_buf stack allocation and the
            // hdr_buf-to-sink memcpy on the pipelined hot path.
            if (sink.len + head.HEADER_BUF_SIZE + body.len <= sink.buf.len) {
                const hdr_len = head.buildSimpleHeaderInto(
                    io, sink.buf[sink.len..], status, content_type, body.len,
                ) catch |err| switch (err) {
                    error.ZixHttp1_Head_DateFormat => return Error.ZixHttp1_Writer_HeadBuild,
                };
                sink.len += hdr_len;
                @memcpy(sink.buf[sink.len..][0..body.len], body);
                sink.len += body.len;
            } else {
                var hdr_buf: [head.HEADER_BUF_SIZE]u8 = undefined;
                const hdr = head.buildSimpleHeader(
                    io, &hdr_buf, status, content_type, body.len,
                ) catch |err| switch (err) {
                    error.ZixHttp1_Head_DateFormat => return Error.ZixHttp1_Writer_HeadBuild,
                };
                sink.append(hdr);
                if (!sink.failed) sink.append(body);
            }

            return if (sink.failed) Error.ZixHttp1_Writer_BrokenPipe else {};
        }
    }

    var hdr_buf: [head.HEADER_BUF_SIZE]u8 = undefined;
    const hdr = head.buildSimpleHeader(
        io, &hdr_buf, status, content_type, body.len,
    ) catch |err| switch (err) {
        error.ZixHttp1_Head_DateFormat => return Error.ZixHttp1_Writer_HeadBuild,
    };

    if (body.len <= SMALL_BODY_INLINE_BUF - head.HEADER_BUF_SIZE) {
        var buf: [SMALL_BODY_INLINE_BUF]u8 = undefined;
        @memcpy(buf[0..hdr.len], hdr);
        @memcpy(buf[hdr.len..][0..body.len], body);

        return writeAllDirectFD(fd, buf[0 .. hdr.len + body.len]);
    }

    std.log.info("TODO: check native platform writer", .{});
    // Either check the native platform then use platform writer
    // No writev over ntdll: two blocking writes keep the same wire bytes
    // for Windows.

    var sent: usize = 0;
    const total = hdr.len + body.len;
    while (sent < total) {
        var iovs: [2]std.posix.iovec_const = undefined;
        var nvec: usize = 0;
        if (sent < hdr.len) {
            iovs[0] = .{ .base = hdr[sent..].ptr, .len = hdr.len - sent };
            iovs[1] = .{ .base = body.ptr, .len = body.len };
            nvec = 2;
        } else {
            const body_sent = sent - hdr.len;
            iovs[0] = .{ .base = body[body_sent..].ptr, .len = body.len - body_sent };
            nvec = 1;
        }
        const rc = std.os.linux.writev(fd, &iovs, nvec);
        switch (std.posix.errno(rc)) {
            .SUCCESS => {
                const n: usize = @intCast(rc);
                if (n == 0) return Error.ZixHttp1_Writer_BrokenPipe;
                sent += n;
            },
            .INTR => continue,
            .AGAIN => {
                var pfd = [_]std.posix.pollfd{.{
                    .fd = fd,
                    .events = std.posix.POLL.OUT,
                    .revents = 0,
                }};
                _ = std.posix.poll(&pfd, -1) catch |err| switch (err) {
                    else => return Error.ZixHttp1_Writer_BrokenPipe,
                };
            },
            else => return Error.ZixHttp1_Writer_BrokenPipe,
        }
    }
}

/// Headers-only response (no body). Used for HEAD method responses.
pub fn sendSimpleNoBodyFD(
    io: std.Io,
    fd: std.posix.fd_t,
    status: Status.Code,
    content_type: []const u8,
    content_length: usize,
) Error!void {
    var hdr_buf: [head.HEADER_BUF_SIZE]u8 = undefined;
    const hdr = head.buildSimpleHeader(
        io, &hdr_buf, status, content_type, content_length,
    ) catch |err| switch (err) {
        error.ZixHttp1_Head_DateFormat => return Error.ZixHttp1_Writer_HeadBuild,
    };

    return writeAllFD(fd, hdr);
}

/// JSON response. Shorthand for sendSimpleFD with "application/json".
pub fn sendJsonFD(
    io: std.Io,
    fd: std.posix.fd_t,
    status: Status.Code,
    body: []const u8,
) Error!void {
    return sendSimpleFD(io, fd, status, "application/json", body);
}

/// Send 100 Continue before reading a large body.
pub fn send100ContinueFD(fd: std.posix.fd_t) Error!void {
    try writeAllFD(fd, "HTTP/1.1 100 Continue\r\n\r\n");
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const pair = @import("../../utils/socket/pair.zig");

test "zix http1: writer, sends a simple response" {
    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    head.setDateHeader(false);
    defer head.setDateHeader(true);

    try sendSimpleFD(std.testing.io, fds[0], .OK, "text/plain", "hello");

    var buf: [256]u8 = undefined;
    const n = try std.posix.read(fds[1], &buf);

    try std.testing.expectEqualStrings(
        "HTTP/1.1 200 Ok\r\nContent-Type: text/plain\r\nContent-Length: 5\r\n\r\nhello",
        buf[0..n],
    );
}

test "zix http1: writer, sends a json response" {
    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    head.setDateHeader(false);
    defer head.setDateHeader(true);

    try sendJsonFD(std.testing.io, fds[0], .OK, "{}");

    var buf: [256]u8 = undefined;
    const n = try std.posix.read(fds[1], &buf);

    try std.testing.expectEqualStrings(
        "HTTP/1.1 200 Ok\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n{}",
        buf[0..n],
    );
}

test "zix http1: writer, streams a body past the inline buffer" {
    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    head.setDateHeader(false);
    defer head.setDateHeader(true);

    const body: [5000]u8 = @splat('z');
    try sendSimpleFD(std.testing.io, fds[0], .OK, "text/plain", &body);

    var buf: [8192]u8 = undefined;
    var total: usize = 0;
    const expected = 5000 + 67;
    while (total < expected) {
        const n = try std.posix.read(fds[1], buf[total..]);
        if (n == 0) break;
        total += n;
    }

    try std.testing.expectEqual(expected, total);
    try std.testing.expect(std.mem.endsWith(u8, buf[0..total], &body));
}

