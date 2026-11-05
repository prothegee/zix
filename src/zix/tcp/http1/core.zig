//! ZIX Http1 core
//!
//! ### file: src/zix/tcp/http1/core.zig
//! 
//! ### author: Prana Ron
//! 
//! ---------------------------------------------------------
//! 
//! ### brief:
//! 
//! n/a
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

/// Date and Time
const dt = @import("../../utils/date_and_time.zig");
const std = @import("std");
const Request = @import("Request.zig");
const Response = @import("Response.zig");
const Context = @import("Context.zig");
const RespSink = @import("RespSink.zig");
const Status = @import("../../utils/http/status.zig");
const statusLine = Status.statusLine;
const statusPhrase = Status.stringFromEnum;
const ResponseCache = @import("../../utils/ResponseCache.zig");
const compression = @import("../../utils/compression/compression.zig");
const ServeOpts = @import("ServeOpts.zig");
const parseHead = @import("parser.zig").parseHead;
const ChunkedRead = @import("ChunkedRead.zig");
const BodyInfo = @import("BodyInfo.zig");
const ParsedHead = @import("ParsedHead.zig");
const ChunkedFrame = @import("ChunkedFrame.zig");
const peer_addr = @import("../../utils/peer_address.zig");

// --------------------------------------------------------- //
// Private:

threadlocal var tl_date: DateCache = .{ .secs = 0, .buf = undefined, .len = 0 };
threadlocal var tl_date_tick: u8 = 0;
threadlocal var tl_send_date: bool = true;

/// This pool thread's receive and body buffers for the thread model (.ASYNC).
///
/// io.async hands each connection to whichever pool thread is free, so a thread
/// keeps one pair and every connection it serves reuses them. That is the same
/// shape a .EPOLL or .URING worker already has, one body scratch shared by every
/// connection the worker owns, rather than a fresh reservation per connection.
threadlocal var tl_recv_buf: []u8 = &.{};
threadlocal var tl_body_buf: []u8 = &.{};

/// Per-handler deadline, thread-local so each worker tracks its own request.
/// 0 means no deadline is active.
threadlocal var tl_deadline_ns: u64 = 0;

/// Inline write fast-path buffer. A response whose status line, headers, and
/// body all fit here is sent in one direct write, skipping the iovec scatter
/// path. The body threshold is this minus HEADER_BUF_SIZE.
const SMALL_BODY_INLINE_BUF: usize = 4096;

const GZIP_OUT_SIZE: usize = 256 * 1024;

/// Bytes requested per drain read on the portable arm of drainBody. The Linux arm
/// asks for the whole remainder in one call, because MSG.TRUNC never writes a buffer.
const DRAIN_SCRATCH: usize = 4096;

/// Upper clamp on bytes requested in a single MSG.TRUNC drain recv. The kernel
/// never writes the buffer there, so a length past it is safe. Mirrors the clamp
/// the multiplexed models use.
const MAX_DRAIN_RECV: usize = 1 << 30;

const DateCache = struct {
    secs: u64,
    buf: [40]u8,
    len: usize,
};

const RecvHeadResult = struct {
    body_offset: usize,
    filled: usize,
};

fn appendStatusCode(buf: []u8, pos: usize, code: Status.Code) usize {
    const n: u16 = @intFromEnum(code);
    buf[pos]     = '0' + @as(u8, @intCast(n / 100));
    buf[pos + 1] = '0' + @as(u8, @intCast((n / 10) % 10));
    buf[pos + 2] = '0' + @as(u8, @intCast(n % 10));
    return pos + 3;
}

fn appendDec(buf: []u8, pos: usize, val: usize) usize {
    if (val == 0) {
        buf[pos] = '0';
        return pos + 1;
    }
    var tmp: [20]u8 = undefined;
    var tmp_len: usize = 0;
    var v = val;
    while (v > 0) {
        tmp[tmp_len] = '0' + @as(u8, @intCast(v % 10));
        tmp_len += 1;
        v /= 10;
    }

    var i: usize = 0;
    while (i < tmp_len) : (i += 1) {
        buf[pos + i] = tmp[tmp_len - 1 - i];
    }

    return pos + tmp_len;
}

fn appendBytes(buf: []u8, pos: usize, str: []const u8) usize {
    @memcpy(buf[pos..][0..str.len], str);
    return pos + str.len;
}

/// Wall-clock nanoseconds since the epoch (CLOCK_REALTIME).
fn wallClockNs() u64 {
    const ts = dt.nowUs(tl_io);

    return @as(u64, @intCast(ts)) * std.time.ns_per_s + @as(u64, @intCast(ts));
}

fn cachedDate() ![]const u8 {
    tl_date_tick +%= 1;
    if (tl_date_tick == 0 or tl_date.len == 0) {
        const secs: u64 = wallClockNs() / std.time.ns_per_s;
        if (secs != tl_date.secs or tl_date.len == 0) {
            var buf: [30]u8 = undefined;
            const d = try dt.now(tl_io, &buf, .RFC7231, 0, false);

            tl_date.secs = secs;
            tl_date.len = d.len;
        }
    }

    return tl_date.buf[0..tl_date.len];
}

fn buildSimpleHeader(
    buf: *[HEADER_BUF_SIZE]u8, status: Status.Code, content_type: []const u8, body_len: usize,
) ![]u8 {
    const len = try buildSimpleHeaderInto(buf, status, content_type, body_len);
    return buf[0..len];
}

/// The pair of buffers this pool thread serves connections with, allocated on
/// first use and grown only when a later connection asks for more.
///
/// Note:
/// - They live for the thread's lifetime rather than the connection's. That is
///   the trade the event-loop models already make, and it is what keeps a
///   request allocation-free.
/// - Resident is bounded by pool threads, not by connection count.
///
/// Param:
/// size - usize (bytes each buffer must hold, from config.max_recv_buf)
///
/// Return:
/// - the two buffers, each exactly size bytes
/// - null when the allocation failed, the caller drops the connection
fn threadConnBufs(size: usize) ?struct { recv: []u8, body: []u8 } {
    if (tl_recv_buf.len < size) {
        const grown = std.heap.smp_allocator.realloc(tl_recv_buf, size) catch return null;
        tl_recv_buf = grown;
    }

    if (tl_body_buf.len < size) {
        const grown = std.heap.smp_allocator.realloc(tl_body_buf, size) catch return null;
        tl_body_buf = grown;
    }

    return .{ .recv = tl_recv_buf[0..size], .body = tl_body_buf[0..size] };
}

/// Read some bytes from fd: the ntdll shim on Windows, std.posix.read elsewhere.
///
/// Return:
/// - usize (bytes read, 0 when the peer closed)
/// - read error otherwise
fn readOnceFD(fd: std.posix.fd_t, buf: []u8) !usize {
    return std.posix.read(fd, buf);
}

/// Bulk-read into buf until \r\n\r\n is found.
/// pre_filled bytes are already in buf from a previous iteration (keep-alive leftover).
///
/// Return:
/// - !RecvHeadResult
fn recvHead(fd: std.posix.fd_t, buf: []u8, pre_filled: usize) Error!RecvHeadResult {
    var filled = pre_filled;

    if (filled >= 4) {
        if (std.mem.indexOf(u8, buf[0..filled], "\r\n\r\n")) |pos| {
            return .{ .body_offset = pos + 4, .filled = filled };
        }
    }

    while (true) {
        if (filled >= buf.len) return Error.ZixHttp1_Core_HeaderTooLarge;
        const n = readOnceFD(fd, buf[filled..]) catch return Error.ZixHttp1_Core_Closed;
        if (n == 0) return Error.ZixHttp1_Core_Closed;
        const search_from = if (filled > 3) filled - 3 else 0;
        filled += n;
        if (std.mem.indexOfPos(u8, buf[0..filled], search_from, "\r\n\r\n")) |pos| {
            return .{ .body_offset = pos + 4, .filled = filled };
        }
    }
}

/// Discard request-body bytes still sitting on the socket.
///
/// Note:
/// - Never writes into the buffer the handler is about to read. The drained
///   bytes are not part of the delivered body, so sharing one buffer hands the
///   handler the tail of the drain in place of the start of its request.
/// - Stops early on a peer that hangs up, which the caller sees as a returned
///   count short of what it asked for.
///
/// Param:
/// fd - std.posix.fd_t (the connection)
/// owed - usize (body bytes still to consume)
///
/// Return:
/// - usize (bytes actually consumed off the socket)
fn drainBody(fd: std.posix.fd_t, owed: usize) usize {
    var remaining = owed;
    var consumed: usize = 0;
    var scratch: [DRAIN_SCRATCH]u8 = undefined;

    if (comptime @import("builtin").target.os.tag == .linux) {
        // MSG.TRUNC drops the bytes inside the kernel: nothing is copied to
        // userspace and one call may ask for far more than scratch holds.
        const linux = std.os.linux;

        while (remaining > 0) {
            const want = @min(remaining, MAX_DRAIN_RECV);
            const rc = linux.recvfrom(fd, &scratch, want, linux.MSG.TRUNC, null, null);
            switch (std.posix.errno(rc)) {
                .SUCCESS => {
                    const n: usize = @intCast(rc);
                    if (n == 0) return consumed;

                    consumed += n;
                    remaining -= n;
                },
                .INTR => continue,
                else => return consumed,
            }
        }

        return consumed;
    }

    // Portable arm: a dedicated scratch buffer, never the handler's body buffer.
    while (remaining > 0) {
        const want = @min(remaining, scratch.len);
        const n = readOnceFD(fd, scratch[0..want]) catch return consumed;
        if (n == 0) return consumed;

        consumed += n;
        remaining -= n;
    }

    return consumed;
}

/// Log one served request, when a logger is attached.
///
/// Note:
/// - The whole call costs one threadlocal load and one branch when no logger is attached, which is
///   what keeps a raw engine paying nothing for a feature it did not ask for.
/// - The client address falls back to the socket when no proxy header names one, so a direct
///   request is logged with a real address rather than "-".
fn writeAccessRecord(req: *const Request, res: *const Response, fd: std.posix.fd_t) void {
    std.log.info("TODO: core writeAccessRecord logger.access", .{});
    _ = req;
    _ = res;
    _ = fd;
}

// --------------------------------------------------------- //

pub const Error = error {
    ZixHttp1_Core_BrokenPipe,
    ZixHttp1_Core_HeaderTooLarge,
    ZixHttp1_Core_Closed,
};

/// Scratch buffer for building one HTTP status line plus its headers.
pub const HEADER_BUF_SIZE: usize = 256;

/// Shared per-connection scratch size: the blocking-loop receive buffer, the
/// chunked-body reader, and the TLS payload buffers all use it.
pub const BUF_SIZE: usize = 1 * 1024;

/// ZIX Http1 core threadlocal io
/// initialize at server init function
pub threadlocal var tl_io: std.Io = undefined;

/// Response extra-header capacity (Response.addHeader) for this worker, from
/// config.max_response_headers. The backing buffer is allocated lazily per
/// request on the first addHeader call, so requests that add none pay nothing.
pub threadlocal var tl_max_response_headers: usize = 16;

/// Whether response bytes for the request in flight have already reached the wire.
///
/// Note:
/// - The `Response` builder tracks the same thing in `Response.sent`,
///   but a handler may answer through the fd writers instead, which hold no `Response`.
///   Without this the engine reads such a handler as never having answered and completes it
///   a second time, gluing a status line onto a response the peer is already reading.
/// - A threadlocal because the fd writers take an fd and nothing else. Cleared by invokeHandler,
///   so it never carries into the next request on this thread.
pub threadlocal var tl_responded: bool = false;

/// Coalescing sink for the current worker. null sends every write straight to the fd.
pub threadlocal var tl_resp_sink: ?*RespSink = null;

// Response cache: per-worker, per-key precomputed response (ADR-036).
/// The calling thread's response cache when config.response_cache is on, null otherwise.
/// The multiplexed workers set it once per worker,
/// .ASYNC once per io pool thread (utils/async_cache).
/// When null every cache call below degrades to a no-op, so a handler that uses the cache API
/// still works on a server with caching disabled.
pub threadlocal var tl_cache: ?*ResponseCache = null;

/// Configured static-serve root for the unmatched-route fallback. Empty disables it. The router
/// reads these because the static fallback runs before any handler, so the public_dir and io are
/// threaded down per worker the same way the date / cache / compression switches are.
pub threadlocal var tl_static_dir: []const u8 = "";
pub threadlocal var tl_static_io: ?std.Io = null;

/// Whether response compression is enabled for this worker. Off unless the server
/// installs it from config.compress. When off, sendNegotiateCachedFD always writes
/// uncompressed.
pub threadlocal var tl_compression: bool = false;

/// Body size floor for compression, installed from config.compression_min_size.
pub threadlocal var tl_compression_min_size: usize = compression.MIN_SIZE_DEFAULT;

/// Compressed-output cap, installed from config.compression_max_out. A compressed
/// result above this is discarded and the response is sent uncompressed.
pub threadlocal var tl_compression_max_out: usize = GZIP_OUT_SIZE;

/// Body measurements for the request about to be invoked. Null is the common
/// case and the one the bodyless hot path takes, so the check costs one load and
/// one branch. Consumed and cleared by invokeHandler, so it never leaks into a
/// later request on the same thread.
pub threadlocal var tl_body_info: ?BodyInfo = null;

/// The logger this worker writes access records to, or null when none is attached.
///
/// Note:
/// - A threadlocal rather than a parameter because the multiplexed models install their per-worker
///   state once for the worker's whole life, and threading a logger through every dispatch call
///   would put that setup on the per-request path instead.
pub threadlocal var tl_access_logger: struct{} = null; // TODO

/// Handler signature: the ergonomic request, response, context trio. All slices
/// the request exposes are valid only for the duration of the call. A returned
/// error is completed by the engine as a 500 when the handler wrote nothing.
pub const HandlerFn = *const fn (
    req: *Request,
    res: *Response,
    ctx: *Context,
) anyerror!void;

/// Arm or clear the per-handler deadline for the current thread.
/// The server calls this before each dispatch with config.handler_timeout_ms.
/// Handlers may call it to shorten their own budget. ms = 0 clears the deadline.
pub fn setTimeout(ms: u32) void {
    tl_deadline_ns = if (ms == 0)
        0
    else
        wallClockNs() + @as(u64, ms) * std.time.ns_per_ms;
}

/// Initialize what required from ZIX Http1 core
/// must be invoke on server initialize level before run.
///
/// Currently core has local thread for it own IO.
pub fn initialize(io: std.Io) void {
    tl_io = io;
}

/// Record that response bytes for the request in flight reached the wire.
///
/// Note:
/// - Called by the fd writers, never by a handler. `Response.send*` reaches it through the same
///   writers, so both answer styles set it.
///
/// Return:
/// - void
pub fn markResponded() void {
    tl_responded = true;
}

/// Write a simple response header into buf starting at offset 0.
/// buf must be at least 256 bytes. Returns the number of bytes written.
/// The block ends with the final \r\n\r\n, so a caller inserting extra
/// headers (Response.addHeader) splices them in before the last two bytes.
pub fn buildSimpleHeaderInto(
    buf: []u8, status: Status.Code, content_type: []const u8, body_len: usize,
) !usize {
    var pos: usize = 0;

    const line = statusLine(status);
    if (line.len > 0) {
        pos = appendBytes(buf, pos, line);
    } else {
        pos = appendBytes(buf, pos, "HTTP/1.1 ");
        pos = appendStatusCode(buf, pos, status);
        buf[pos] = ' ';
        pos += 1;
        pos = appendBytes(buf, pos, statusPhrase(status));
        pos = appendBytes(buf, pos, "\r\n");
    }

    if (content_type.len > 0) {
        pos = appendBytes(buf, pos, "Content-Type: ");
        pos = appendBytes(buf, pos, content_type);
        pos = appendBytes(buf, pos, "\r\n");
    }
    pos = appendBytes(buf, pos, "Content-Length: ");
    pos = appendDec(buf, pos, body_len);
    pos = appendBytes(buf, pos, "\r\n");
    if (tl_send_date) {
        pos = appendBytes(buf, pos, "Date: ");
        pos = appendBytes(buf, pos, try cachedDate());
        pos = appendBytes(buf, pos, "\r\n");
    }
    pos = appendBytes(buf, pos, "\r\n");

    return pos;
}

pub fn writeAllDirectFD(fd: std.posix.fd_t, data: []const u8) Error!void {
    var rem = data;
    while (rem.len > 0) {
        const rc = std.posix.system.write(fd, rem.ptr, rem.len);
        switch (std.posix.errno(rc)) {
            .SUCCESS => {
                const n: usize = @intCast(rc);
                if (n == 0) return Error.ZixHttp1_Core_BrokenPipe;
                rem = rem[n..];
            },
            .INTR => continue,
            // Non-blocking socket with a full send buffer: wait for the peer
            // to drain it, then retry. Blocking sockets never hit this branch.
            .AGAIN => {
                var pfd = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.OUT, .revents = 0 }};
                _ = std.posix.poll(&pfd, -1) catch return Error.ZixHttp1_Core_BrokenPipe;
            },
            else => return Error.ZixHttp1_Core_BrokenPipe,
        }
    }
}

/// Response with Content-Length body.
///
/// Note:
/// - Marks the request in flight as answered. The sink fast path below builds straight into the
///   batch and never reaches writeAllFD, so the mark cannot be left to that writer alone.
pub fn sendSimpleFD(
    fd: std.posix.fd_t,
    status: Status.Code,
    content_type: []const u8,
    body: []const u8,
) !void {
    markResponded();

    if (tl_resp_sink) |sink| {
        if (sink.fd == fd) {
            // A pending zero-copy replay must land in the batch before this
            // response so the wire order matches the request order.
            sink.materializeDirect();

            // Fast path: build header directly into sink.buf at sink.len, then
            // append body. Eliminates the hdr_buf[256] stack allocation and the
            // hdr_buf-to-sink memcpy on the pipelined hot path.
            if (sink.len + HEADER_BUF_SIZE + body.len <= sink.buf.len) {
                const hdr_len =
                    try buildSimpleHeaderInto(sink.buf[sink.len..], status, content_type, body.len);
                sink.len += hdr_len;
                @memcpy(sink.buf[sink.len..][0..body.len], body);
                sink.len += body.len;
            } else {
                var hdr_buf: [HEADER_BUF_SIZE]u8 = undefined;
                const hdr = try buildSimpleHeader(&hdr_buf, status, content_type, body.len);
                sink.append(hdr);
                if (!sink.failed) sink.append(body);
            }

            return if (sink.failed) Error.ZixHttp1_Core_BrokenPipe else {};
        }
    }

    var hdr_buf: [HEADER_BUF_SIZE]u8 = undefined;
    const hdr = try buildSimpleHeader(&hdr_buf, status, content_type, body.len);

    if (body.len <= SMALL_BODY_INLINE_BUF - HEADER_BUF_SIZE) {
        var buf: [SMALL_BODY_INLINE_BUF]u8 = undefined;
        @memcpy(buf[0..hdr.len], hdr);
        @memcpy(buf[hdr.len..][0..body.len], body);

        // Skips that sink check entirely instead,
        // and write straight to the fd since code only reaches this line.
        return writeAllDirectFD(fd, buf[0 .. hdr.len + body.len]);
    }

    std.log.info("TODO: check native platform writer", .{});
    // Either check the native platofrm then use platform writer
    // No writev over ntdll: two blocking writes keep the same wire bytes
    // for Windows. Probably.

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
                if (n == 0) return Error.ZixHttp1_Core_BrokenPipe;
                sent += n;
            },
            .INTR => continue,
            .AGAIN => {
                var pfd = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.OUT, .revents = 0 }};
                _ = std.posix.poll(&pfd, -1) catch return Error.ZixHttp1_Core_BrokenPipe;
            },
            else => return Error.ZixHttp1_Core_BrokenPipe,
        }
    }
}

/// Headers-only response (no body). Used for HEAD method responses.
pub fn sendSimpleNoBodyFD(
    fd: std.posix.fd_t,
    status: u16,
    content_type: []const u8,
    content_length: usize,
) !void {
    var hdr_buf: [HEADER_BUF_SIZE]u8 = undefined;
    const hdr = buildSimpleHeader(&hdr_buf, status, content_type, content_length);

    return writeAllFD(fd, hdr);
}

/// JSON response. Shorthand for sendSimpleFD with "application/json".
pub fn sendJsonFD(fd: std.posix.fd_t, status: u16, body: []const u8) !void {
    return sendSimpleFD(fd, status, "application/json", body);
}

/// Send 100 Continue before reading a large body.
pub fn send100ContinueFD(fd: std.posix.fd_t) !void {
    try writeAllFD(fd, "HTTP/1.1 100 Continue\r\n\r\n");
}

/// Write response bytes to fd, the canonical write behind every send helper.
/// Routes through the coalescing sink (tl_resp_sink) or the TLS stream sink
/// when one is installed for this worker, otherwise writes directly.
///
/// Note:
/// - Marks the request in flight as answered, so a handler that writes here directly is not
///   completed a second time by invokeHandler. Every send helper lands here, the SSE prologue
///   and the WebSocket 101 upgrade included.
pub fn writeAllFD(fd: std.posix.fd_t, data: []const u8) Error!void {
    markResponded();

    if (tl_resp_sink) |sink| {
        if (sink.fd == fd) {
            // Zero-copy cache replay: a whole-response hit written while the
            // batch is empty is borrowed (slot pinned) instead of copied. Only
            // the exact slice the cache lookup returned qualifies.
            if (sink.allow_direct and sink.len == 0 and sink.direct.len == 0) {
                if (tl_cache) |c| {
                    if (c.hitSlot(data)) |slot| {
                        c.pin(slot);
                        sink.direct = data;
                        sink.direct_slot = slot;

                        return;
                    }
                }
            }

            sink.materializeDirect();
            sink.append(data);
            if (sink.failed) return Error.ZixHttp1_Core_BrokenPipe;

            return;
        }
    }

    std.log.info("TODO: Streaming https path (ADR-054)", .{});
    // Streaming https path (ADR-054):
    // the capture sink was detached by beginStream(),
    // so each write encrypts one TLS record and sends it. null in cleartext,
    // where writes go straight to the fd.

    return writeAllDirectFD(fd, data);
}

/// Set whether responses include the Date header. Called once per worker thread at startup.
pub fn setDateHeader(enabled: bool) void {
    tl_send_date = enabled;
}

/// Install the static-serve root and io for this worker thread. Called once per worker at startup.
/// An empty public_dir leaves static serving off (the router falls straight through to 404).
pub fn setStatic(public_dir: []const u8, io: std.Io) void {
    tl_static_dir = public_dir;
    tl_static_io = io;
}

/// Install the Response extra-header capacity for this worker thread.
/// Called once per worker at startup.
pub fn setMaxResponseHeaders(count: usize) void {
    tl_max_response_headers = count;
}

// /// Attach the access logger for this worker (or, under .ASYNC, for this connection).
// pub fn setAccessLogger(logger: ?*Logger) void {
//     tl_access_logger = logger;
// }

/// Install or clear the compression policy for this worker.
pub fn setCompression(enabled: bool, min_size: usize, max_out: usize) void {
    tl_compression = enabled;
    tl_compression_min_size = min_size;
    tl_compression_max_out = max_out;
}

/// Whether the request in flight has been answered through the fd writers.
///
/// Return:
/// - bool
pub fn respondedFD() bool {
    return tl_responded;
}

/// Keep-alive connection loop. The caller owns closing the fd. Pass raw fd extracted
/// from the accepted stream.
pub fn serveConn(fd: std.posix.fd_t, handler: HandlerFn, opts: ServeOpts, io: std.Io) void {
    if (opts.nodelay) {
        if (comptime @import("builtin").target.os.tag != .windows) {
            // std.posix.TCP is void on the BSDs in Zig 0.16: TCP_NODELAY is 1 there.
            const nodelay: u32 = if (comptime std.posix.TCP != void) std.posix.TCP.NODELAY else 1;

            std.posix.setsockopt(
                fd,
                std.posix.IPPROTO.TCP,
                nodelay,
                std.mem.asBytes(&@as(c_int, 1)),
            ) catch {};
        }
    }

    // Per-connection scratch for the handler trio, reset before each request so a
    // long keep-alive connection never grows without bound.
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();

    // Both buffers are cut from config.max_recv_buf, the same knob the .EPOLL
    // and .URING connection slots use, so the body a handler is given has one
    // size across every dispatch model.
    const recv_size = if (opts.max_recv_buf == 0) BUF_SIZE else opts.max_recv_buf;

    const bufs = threadConnBufs(recv_size) orelse return;
    const recv_buf = bufs.recv;
    const body_buf = bufs.body;

    var leftover: usize = 0;

    while (true) {
        const hdr = recvHead(fd, recv_buf, leftover) catch |err| {
            if (err == error.ZixHeaderTooLarge) {
                writeAllFD(
                    fd,
                    "HTTP/1.1 431 Request Header Fields Too Large\r\nContent-Length: 0\r\n\r\n",
                ) catch {};
            }
            return;
        };

        const result = parseHead(recv_buf[0..hdr.filled]) catch |err| {
            writeAllFD(fd, parseErrorResponse(err)) catch {};
            return;
        };
        const head = result.head;

        if (head.expect_continue and (head.content_length > 0 or head.chunked_request)) {
            send100ContinueFD(fd) catch return;
        }

        var body_len: usize = 0;
        var received: u64 = 0;
        var drained_large = false;
        // Whether this request declared a body at all, and whether reading it
        // reached the end. A request with no body skips the handoff below
        // entirely, so the bodyless path pays one compare and no store.
        var has_body = false;
        var body_complete = true;
        var chunked_leftover: usize = 0;
        var chunked_leftover_off: usize = 0;
        if (head.chunked_request) {
            // The body reads into body_buf and is decoded over itself there. recv_buf
            // cannot be used as that scratch: head still points into it, and the
            // handler is about to be given those slices.
            const peeked = hdr.filled - hdr.body_offset;
            if (peeked > 0) @memcpy(body_buf[0..peeked], recv_buf[hdr.body_offset..hdr.filled]);

            const chunked = readChunkedBody(fd, body_buf, peeked);
            switch (chunked.stop) {
                .COMPLETE => {},
                .MALFORMED => {
                    // The rest of the body cannot be framed, so there is no way to
                    // find where the next request would start. Answer and close.
                    writeAllFD(
                        fd,
                        "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
                    ) catch {};

                    return;
                },
                .TOO_LARGE => {
                    writeAllFD(
                        fd,
                        "HTTP/1.1 413 Payload Too Large\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
                    ) catch {};

                    return;
                },
                .NEED_MORE => return,
            }

            has_body = true;
            body_len = chunked.len;
            received = chunked.received;
            chunked_leftover_off = chunked.leftover_off;
            chunked_leftover = chunked.leftover;
        } else if (head.content_length > 0) {
            // Refused before a byte of it is read or discarded, so a declared
            // length cannot make this thread consume an arbitrary body.
            if (opts.max_request_body != 0 and head.content_length > opts.max_request_body) {
                writeAllFD(
                    fd,
                    "HTTP/1.1 413 Payload Too Large\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
                ) catch {};

                return;
            }

            has_body = true;

            const content_length: usize = @intCast(head.content_length);
            const to_read: usize = @min(content_length, body_buf.len);
            const peeked = hdr.filled - hdr.body_offset;
            const from_peek = @min(peeked, to_read);
            if (from_peek > 0) {
                @memcpy(body_buf[0..from_peek], recv_buf[hdr.body_offset..][0..from_peek]);
            }
            body_len = from_peek;
            while (body_len < to_read) {
                const n = readOnceFD(fd, body_buf[body_len..to_read]) catch break;
                if (n == 0) break;
                body_len += n;
            }

            // Body bytes already off the socket: the ones that arrived with the head, plus the
            // ones the fill loop pulled. Counting only the head-side bytes here would make the
            // drain below ask for the fill loop's bytes a second time, taking them from the next
            // request on the connection.
            received = @min(peeked, content_length) + (body_len - from_peek);

            // Body larger than the handler buffer: consume the rest off the socket so the
            // connection stays usable for keep-alive (the leftover would otherwise be misparsed as
            // the next request). drainBody never touches body_buf, so the slice handed to the
            // handler stays the start of the request instead of the tail of the drain. A wider
            // SO_RCVBUF (opts.large_body_recv_buf) speeds this on uploads.
            if (received < content_length) {
                setRecvBuf(fd, opts.large_body_recv_buf);

                received += drainBody(fd, content_length - received);
                drained_large = true;
            }

            // A peer that stopped early leaves the drain short of the declared
            // length. The handler still runs, so it needs a way to tell that
            // upload apart from one that finished.
            body_complete = received >= content_length;
        }

        setTimeout(opts.handler_timeout_ms);
        _ = arena.reset(.retain_capacity);

        // The delivered slice is capped by body_buf, the count is everything the socket gave up,
        // so a handler comparing the two can tell a truncated body from a complete one.
        if (has_body) tl_body_info = .{ .received = received, .complete = body_complete };
        invokeHandler(handler, &head, body_buf[0..body_len], fd, io, arena.allocator());

        std.log.info("TODO: if (takeWebSocket)", .{});

        if (!head.keep_alive) return;

        if (head.chunked_request) {
            // Bytes the chunked read pulled past the end of the body: a pipelined
            // request, carried to the front of recv_buf for the next pass. The
            // handler has returned, so overwriting the head bytes is safe now.
            leftover = chunked_leftover;
            if (leftover > 0) {
                @memcpy(recv_buf[0..leftover], body_buf[chunked_leftover_off..][0..leftover]);
            }
        } else if (drained_large) {
            // The whole body was consumed off the socket, and a large body has no
            // pipelined request after it, so nothing is left to carry.
            leftover = 0;
        } else {
            const body_consumed: usize = @intCast(@min(head.content_length, @as(u64, body_buf.len)));
            const request_end = hdr.body_offset + body_consumed;
            if (hdr.filled > request_end) {
                leftover = hdr.filled - request_end;
                std.mem.copyForwards(u8, recv_buf[0..leftover], recv_buf[request_end..hdr.filled]);
            } else {
                leftover = 0;
            }
        }
    }
}

/// Response to answer a failed request-line parse with
///
/// Note:
/// - A method the engine does not implement is 501, not 400: the request line
///   was well formed and only the method is unsupported (RFC 9110 section
///   15.6.2). QUERY reached this path before RFC 10008 support, and answering
///   400 told a client the request was broken when it was merely unhandled
/// - Every other parse failure is a malformed request line, which stays 400
/// - Reached only on the error path, so no request that parses pays for it
///
/// Param:
/// err - anyerror (from parseHead or parseHeadAt)
///
/// Return:
/// - []const u8 (a complete response, ready to write)
pub fn parseErrorResponse(err: anyerror) []const u8 {
    return switch (err) {
        error.ZixHttp1_Parser_UnknownMethod =>
            "HTTP/1.1 501 Not Implemented\r\nContent-Length: 0\r\n\r\n",
        else => "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n",
    };
}

/// Decode a chunked request body that is fully present in src (RFC 9112 7.1).
///
/// Note:
/// - Every dispatch model decodes here, so a chunked body means the same thing
///   on all three.
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
        const hex = if (std.mem.indexOfScalar(u8, size_field, ';')) |semi| size_field[0..semi] else size_field;
        const chunk_size = std.fmt.parseInt(usize, std.mem.trim(u8, hex, " "), 16) catch unreachable;
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
/// - Whatever follows the body is reported, not discarded. The reader this
///   replaced kept a private buffer and dropped its tail, losing a pipelined
///   request the server had already taken off the socket.
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

        const n = readOnceFD(fd, buf[filled..]) catch return .{ .received = filled, .stop = .NEED_MORE };
        if (n == 0) return .{ .received = filled, .stop = .NEED_MORE };

        filled += n;
    }
}

/// Widen the socket receive buffer (SO_RCVBUF) so a large request body drains in fewer cycles.
/// Applied only on the large-body path (a body bigger than the read buffer), so ordinary small
/// requests keep the kernel default and its autotuning. bytes = 0 leaves the socket untouched.
/// Note: an explicit SO_RCVBUF disables receive autotuning for that socket, which is why it is set
/// only when a large body is actually detected, not at accept.
pub fn setRecvBuf(fd: std.posix.fd_t, bytes: usize) void {
    if (bytes == 0) return;

    const val: c_int = @intCast(@min(bytes, std.math.maxInt(c_int)));
    std.posix.setsockopt(
        fd, std.posix.SOL.SOCKET, std.posix.SO.RCVBUF, std.mem.asBytes(&val)
    ) catch {};
}

/// Build the request, response, and context trio over a parsed request and hand
/// it to the handler. One place builds the trio, so every dispatch model invokes
/// a handler the same way. On an error return the response is completed with a
/// 500, but only when the handler wrote nothing, so a handler that already sent a
/// response and then failed does not corrupt the stream.
///
/// Note:
/// - "Wrote nothing" covers both answer styles: the Response builder (`Response.sent`) and the fd
///   writers (`respondedFD`). A handler that answers with `sendSimpleFD` or `writeAllFD` holds no
///   Response, so checking `Response.sent` alone read it as unanswered and appended a second
///   status line to a response the peer was already reading.
/// - An error the handler swallows itself is the handler's own business. The engine completes an
///   error the handler RETURNS, nothing else.
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

    if (tl_body_info) |info| {
        req.body_received = info.received;
        req.body_complete = info.complete;
        tl_body_info = null;
    }

    // Cleared here rather than at connection setup: the 100-continue an Expect request gets is
    // written by the engine before this point, and that interim write is not the handler answering.
    tl_responded = false;

    handler_fn(&req, &res, &ctx) catch {
        if (!res.sent and !respondedFD()) {
            sendSimpleFD(fd, .INTERNAL_SERVER_ERROR, "text/plain", "Internal Server Error") catch {};
            res.status = .INTERNAL_SERVER_ERROR;
        }
    };

    writeAccessRecord(&req, &res, fd);
}

/// Walk the chunk framing in src without moving a byte.
///
/// Note:
/// - Steps over chunk data by its declared size, so the cost is one step per
///   chunk rather than one per byte, and data that happens to spell the terminal
///   chunk cannot be mistaken for it.
/// - The stop reason separates "not arrived yet" from "broken" from "too big".
///   One null for all three left every caller unable to answer, which is how a
///   malformed body used to stall a connection instead of drawing a 400.
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
        const line_end = std.mem.indexOfPos(u8, src, pos, "\r\n") orelse return .{ .stop = .NEED_MORE };
        const size_field = src[pos..line_end];
        const hex = if (std.mem.indexOfScalar(u8, size_field, ';')) |semi| size_field[0..semi] else size_field;

        const chunk_size = std.fmt.parseInt(usize, std.mem.trim(u8, hex, " "), 16) catch
            return .{ .stop = .MALFORMED };
        pos = line_end + 2;

        if (chunk_size == 0) {
            const trailer_end = std.mem.indexOfPos(u8, src, pos, "\r\n") orelse return .{ .stop = .NEED_MORE };

            return .{ .len = decoded, .consumed = trailer_end + 2, .stop = .COMPLETE };
        }

        if (decoded + chunk_size > out_cap) return .{ .stop = .TOO_LARGE };
        if (pos + chunk_size + 2 > src.len) return .{ .stop = .NEED_MORE };

        decoded += chunk_size;
        pos += chunk_size + 2;
    }
}

