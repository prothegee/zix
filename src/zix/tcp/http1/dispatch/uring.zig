//! ZIX Http1 dispatch uring model
//!
//! ### file: src/zix/tcp/http1/dispatch/uring.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Linux io_uring model: worker threads share nothing, each owns a listener,
//! a ring, and the connections it accepted.
//!
//! ### note:
//!
//! Cleartext HTTP/1.1 and WebSocket. TLS and SSE are not part of this
//! model yet. A connection is served on one worker from
//! accept to close. A response larger than the staging cap falls back to the
//! blocking writer.
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
const builtin = @import("builtin");
const linux = std.os.linux;
const IoUring = std.os.linux.IoUring;
const cache = @import("../cache.zig");
const compress = @import("../compress.zig");
const Config = @import("../Config.zig");
const chunk = @import("../chunk.zig");
const handler = @import("../handler.zig");
const HandlerFn = handler.HandlerFn;
const head = @import("../head.zig");
const header = @import("../header.zig");
const log = @import("../log.zig");
const parser = @import("../parser.zig");
const reader = @import("../reader.zig");
const static = @import("../static.zig");
const RespSink = @import("../RespSink.zig");
const writer = @import("../writer.zig");
const ws_pending = @import("../websocket/pending.zig");
const ws_pump = @import("../websocket/pump.zig");
const WsFrameFn = @import("../websocket/frame_fn.zig").WsFrameFn;
const WS_RECV_BUF_DEFAULT = @import("../ServeOpts.zig").WS_RECV_BUF_DEFAULT;
const ResponseCache = @import("../../../utils/cache/ResponseCache.zig");
const slab = @import("../../../multiplexers/slab.zig");

// --------------------------------------------------------- //
// Private:

/// Per-connection response staging size.
const SEND_BUF: usize = 16 * 1024;

/// A response larger than this is flushed directly instead of grown.
const MAX_RESPONSE_BYTES: usize = 8 * 1024 * 1024;

/// Largest fd the worker slot table can name.
const MAX_FD: usize = 1 << 16;

/// Most bytes one discard recv asks the kernel for.
const MAX_DRAIN_RECV: usize = 1 << 20;

/// SQ entries per worker ring.
const RING_ENTRIES: u16 = 1024;

/// CQ entries per worker ring.
const RING_CQ_ENTRIES: u32 = 4096;

/// Max CQEs drained per loop pass.
const CQE_BATCH: usize = 256;

/// How long a worker may sleep between stop checks, in seconds.
const WAIT_SECONDS: i64 = 1;

const RESPONSE_100_CONTINUE = "HTTP/1.1 100 Continue\r\n\r\n";
const RESPONSE_400_CLOSE =
    "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
const RESPONSE_413_CLOSE =
    "HTTP/1.1 413 Payload Too Large\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
const RESPONSE_431 =
    "HTTP/1.1 431 Request Header Fields Too Large\r\nContent-Length: 0\r\n\r\n";

/// Buffer group id of the WebSocket provided-buffer ring.
const WS_RING_BGID: u16 = 1;
/// Bytes per buffer in the WebSocket ring.
const WS_RING_BUF_SIZE: u32 = 4096;
/// Buffers in the WebSocket ring, shared by every WebSocket connection of one
/// worker.
const WS_RING_BUF_COUNT: u16 = 256;

const ConnOutcome = enum {
    keep_alive,
    close,
};

/// Completion routing tag, carried in the top byte of user_data.
const OpKind = enum(u8) {
    accept,
    recv,
    send,
    close,
};

/// Decoded user_data fields.
const Decoded = struct {
    op: OpKind,
    gen: u24,
    fd: linux.fd_t,
};

/// One accepted connection and everything the worker needs to resume it.
const Conn = struct {
    fd: std.posix.fd_t,
    gen: u24 = 0,
    buf: []u8,
    filled: usize = 0,
    /// Bytes of buf already searched for the header terminator.
    scan_from: usize = 0,
    /// Set once the 100 Continue answer was staged for this request.
    continue_sent: bool = false,
    /// Body bytes still to read and discard for a body too large to buffer.
    drain: usize = 0,
    /// Body bytes already taken off the socket for the deferred request.
    drain_received: usize = 0,
    /// Head bytes parked at the front of buf while the drain runs.
    pending_head_len: usize = 0,
    send_buf: []u8,
    /// Whether send_buf is heap owned and must be freed on close.
    send_heap: bool = false,
    staged: usize = 0,
    staged_off: usize = 0,
    /// Bytes the kernel owns while a send SQE is outstanding.
    inflight: usize = 0,
    closing: bool = false,
    /// Set once a handler promoted the connection to WebSocket. From then on
    /// buf holds frame bytes, not requests.
    ws: ?WsFrameFn = null,
};

/// One worker's setup, passed by value to the spawned thread.
const WorkerCtx = struct {
    config: Config,
    handler: HandlerFn,
    listener: std.Io.net.Server,
    allocator: std.mem.Allocator,
    stop: *std.atomic.Value(bool),
    failed: *std.atomic.Value(bool),
};

/// One ring, its fd slot table, and the connections it owns.
const Worker = struct {
    ring: IoUring = undefined,
    slots: []?*Conn = &.{},
    gen_counter: u24 = 0,
    listener_fd: std.posix.fd_t = -1,
    io: std.Io,
    handler_fn: HandlerFn,
    allocator: std.mem.Allocator,
    body_buf: []u8,
    arena: *std.heap.ArenaAllocator,
    accept_pending: bool = false,
    /// Per-connection receive buffer size, from config.max_recv_buf.
    recv_buf_size: usize,
    /// Per-handler budget in milliseconds, from config.handler_timeout_ms. 0 disables it.
    handler_timeout_ms: u32 = 0,
    /// Declared request body larger than this is refused with 413. 0 disables the check.
    max_request_body: usize = 0,
    /// SO_RCVBUF set when a body larger than the receive buffer is drained. 0 keeps
    /// the kernel default.
    large_body_recv_buf: usize = 0,
    /// Provided-buffer ring for WebSocket recvs. The kernel picks a buffer only
    /// when a frame arrives, so an idle WebSocket ties up no recv buffer. null
    /// when the kernel has no buffer rings: WebSocket then uses plain recv.
    ws_bufs: ?IoUring.BufferGroup = null,
    /// Connection buffer size after a WebSocket upgrade, from config.ws_recv_buf.
    ws_recv_buf_size: usize = WS_RECV_BUF_DEFAULT,
    /// Per-worker unmask scratch, ws_recv_buf_size bytes. Sets the largest frame.
    ws_payload_buf: []u8 = &.{},

    fn getSqe(self: *Worker) ?*linux.io_uring_sqe {
        if (self.ring.get_sqe()) |sqe| return sqe else |_| {}

        _ = self.ring.submit() catch |err| switch (err) {
            else => return null,
        };

        return self.ring.get_sqe() catch |err| switch (err) {
            else => null,
        };
    }

    fn lookup(self: *Worker, decoded: Decoded) ?*Conn {
        if (decoded.fd < 0) return null;
        const idx: usize = @intCast(decoded.fd);
        if (idx >= self.slots.len) return null;

        const conn = self.slots[idx] orelse return null;
        if (conn.gen != decoded.gen) return null;

        return conn;
    }

    fn armAccept(self: *Worker) void {
        const sqe = self.getSqe() orelse {
            self.accept_pending = true;

            return;
        };

        sqe.prep_multishot_accept(self.listener_fd, null, null, 0);
        sqe.user_data = packUserData(.accept, 0, self.listener_fd);
    }

    fn armRecv(self: *Worker, conn: *Conn) void {
        if (conn.filled >= conn.buf.len) {
            self.beginClose(conn);

            return;
        }

        if (conn.ws != null) {
            if (self.ws_bufs) |*group| {
                self.armWsRecv(conn, group);

                return;
            }
        }

        const sqe = self.getSqe() orelse {
            self.beginClose(conn);

            return;
        };

        sqe.prep_recv(conn.fd, conn.buf[conn.filled..], 0);
        sqe.user_data = packUserData(.recv, conn.gen, conn.fd);
    }

    /// Arm a buffer-select recv for a WebSocket connection. A full submission
    /// queue is submitted once and retried. A second failure closes.
    fn armWsRecv(self: *Worker, conn: *Conn, group: *IoUring.BufferGroup) void {
        const user_data = packUserData(.recv, conn.gen, conn.fd);

        _ = group.recv(user_data, conn.fd, 0) catch |first_err| switch (first_err) {
            else => {
                // Best effort: a failed submit leaves the queue full, and the
                // retry below closes.
                _ = self.ring.submit() catch |err| switch (err) {
                    else => {},
                };

                _ = group.recv(user_data, conn.fd, 0) catch |err| switch (err) {
                    else => self.beginClose(conn),
                };
            },
        };
    }

    /// Hand a ring-selected buffer back to the kernel.
    fn putWsBuf(self: *Worker, cqe: linux.io_uring_cqe) void {
        const group = if (self.ws_bufs) |*bufs| bufs else return;

        // Best effort: a buffer id the ring did not give out cannot go back.
        group.put(cqe) catch |err| switch (err) {
            else => {},
        };
    }

    fn armDrainRecv(self: *Worker, conn: *Conn) void {
        const want = @min(conn.drain, MAX_DRAIN_RECV);
        const sqe = self.getSqe() orelse {
            self.beginClose(conn);

            return;
        };

        sqe.prep_recv(conn.fd, conn.buf, linux.MSG.TRUNC);
        sqe.len = @intCast(want);
        sqe.user_data = packUserData(.recv, conn.gen, conn.fd);
    }

    fn submitSend(self: *Worker, conn: *Conn) void {
        const sqe = self.getSqe() orelse {
            self.finishClose(conn);

            return;
        };

        const payload = conn.send_buf[conn.staged_off..][0..conn.staged];
        sqe.prep_send(conn.fd, payload, linux.MSG.NOSIGNAL);
        sqe.user_data = packUserData(.send, conn.gen, conn.fd);
        conn.inflight = payload.len;
    }

    fn handleAccept(self: *Worker, cqe: linux.io_uring_cqe) void {
        const rearm = (cqe.flags & linux.IORING_CQE_F_MORE) == 0;
        defer if (rearm) self.armAccept();
        if (cqe.res < 0) return;

        const conn_fd: std.posix.fd_t = cqe.res;
        const idx: usize = @intCast(conn_fd);
        if (idx >= self.slots.len) {
            _ = linux.close(conn_fd);

            return;
        }

        setNoDelay(conn_fd);

        const conn = connAlloc(self.allocator, conn_fd, self.recv_buf_size) orelse {
            _ = linux.close(conn_fd);

            return;
        };

        self.gen_counter +%= 1;
        conn.gen = self.gen_counter;
        self.slots[idx] = conn;

        self.armRecv(conn);

        // Release the fresh recv now, so the first request never waits for the
        // rest of this completion batch. A failed submit only defers the SQE to
        // the next loop pass, the connection is not dropped.
        _ = self.ring.submit() catch |err| switch (err) {
            else => {},
        };
    }

    fn handleRecv(self: *Worker, cqe: linux.io_uring_cqe, decoded: Decoded) void {
        const has_buf = (cqe.flags & linux.IORING_CQE_F_BUFFER) != 0;

        const conn = self.lookup(decoded) orelse {
            // Freed while a buffer-select recv was in flight: return the buffer.
            if (has_buf) self.putWsBuf(cqe);

            return;
        };

        if (cqe.res <= 0) {
            // The ring ran dry: re-arm instead of dropping the connection.
            const no_bufs = cqe.res == -@as(i32, @intFromEnum(linux.E.NOBUFS));
            if (no_bufs and conn.ws != null and self.ws_bufs != null) {
                self.armRecv(conn);

                return;
            }

            if (has_buf) self.putWsBuf(cqe);

            // A WebSocket stream gets no HTTP answer, it just ends.
            if (conn.ws == null) stageHangupAnswer(conn);
            self.beginClose(conn);

            return;
        }

        if (conn.ws) |on_frame| {
            if (has_buf) {
                self.pumpWsSelected(conn, on_frame, cqe);

                return;
            }

            conn.filled += @intCast(cqe.res);
            self.pumpWs(conn, on_frame);

            return;
        }

        if (conn.drain > 0) {
            const received: usize = @intCast(cqe.res);
            const drained = @min(received, conn.drain);
            conn.drain -= drained;
            conn.drain_received += drained;

            if (conn.drain == 0) {
                self.finishDrainedRequest(conn);
            } else {
                self.armDrainRecv(conn);
            }

            return;
        }

        conn.filled += @intCast(cqe.res);

        const outcome = self.dispatch(conn);
        self.afterDispatch(conn, outcome);
    }

    fn handleSend(self: *Worker, cqe: linux.io_uring_cqe, decoded: Decoded) void {
        const conn = self.lookup(decoded) orelse return;
        if (cqe.res < 0) {
            conn.inflight = 0;
            conn.staged = 0;
            conn.staged_off = 0;
            self.beginClose(conn);

            return;
        }

        const sent: usize = @intCast(cqe.res);
        if (sent < conn.inflight) {
            conn.staged_off += sent;
            conn.staged -= sent;
            conn.inflight = 0;
            self.submitSend(conn);

            return;
        }

        conn.staged = 0;
        conn.staged_off = 0;
        conn.inflight = 0;

        if (conn.closing) {
            self.finishClose(conn);

            return;
        }

        if (conn.drain > 0) {
            self.armDrainRecv(conn);

            return;
        }

        // Frames that came with the handshake, or a partial frame left by the
        // last pass. A partial frame stages nothing and falls through to recv.
        if (conn.ws) |on_frame| {
            if (conn.filled > 0) {
                self.pumpWs(conn, on_frame);

                return;
            }
        }

        self.armRecv(conn);
    }

    /// Run the frame loop over buf and submit every reply as one ring send.
    /// No send is in flight here, so the pump stages from the front of
    /// send_buf.
    fn pumpWs(self: *Worker, conn: *Conn, on_frame: WsFrameFn) void {
        const result = ws_pump.pumpRing(
            conn.fd,
            conn.buf[0..conn.filled],
            self.ws_payload_buf,
            conn.send_buf,
            on_frame,
        );

        if (result.consumed > 0) {
            const rest = conn.filled - result.consumed;

            std.mem.copyForwards(
                u8,
                conn.buf[0..rest],
                conn.buf[result.consumed..conn.filled],
            );
            conn.filled = rest;
        }

        self.afterPumpWs(conn, result.staged, result.close);
    }

    /// Frames delivered into a ring-selected buffer. With no carried partial
    /// frame they are pumped in place (no copy), and only a trailing partial
    /// frame is copied into buf. With a carry, the bytes join buf first. The
    /// buffer goes back to the ring before the next step.
    fn pumpWsSelected(
        self: *Worker,
        conn: *Conn,
        on_frame: WsFrameFn,
        cqe: linux.io_uring_cqe,
    ) void {
        const group = if (self.ws_bufs) |*bufs| bufs else {
            self.beginClose(conn);

            return;
        };
        const data = group.get(cqe) catch |err| switch (err) {
            else => {
                self.beginClose(conn);

                return;
            },
        };

        if (conn.filled > 0) {
            const fits = data.len <= conn.buf.len - conn.filled;
            if (fits) {
                @memcpy(conn.buf[conn.filled..][0..data.len], data);
                conn.filled += data.len;
            }
            self.putWsBuf(cqe);

            if (!fits) {
                self.beginClose(conn);

                return;
            }

            self.pumpWs(conn, on_frame);

            return;
        }

        const result = ws_pump.pumpRing(
            conn.fd,
            data,
            self.ws_payload_buf,
            conn.send_buf,
            on_frame,
        );
        const leftover = data[result.consumed..];
        const fits = leftover.len <= conn.buf.len;

        if (fits) @memcpy(conn.buf[0..leftover.len], leftover);
        conn.filled = if (fits) leftover.len else 0;
        self.putWsBuf(cqe);

        self.afterPumpWs(conn, result.staged, result.close or !fits);
    }

    /// Send the staged replies, close, or wait for more frames.
    fn afterPumpWs(self: *Worker, conn: *Conn, staged: usize, close: bool) void {
        conn.staged = staged;
        conn.staged_off = 0;

        if (close) {
            self.beginClose(conn);

            return;
        }

        if (conn.staged > 0) {
            self.submitSend(conn);

            return;
        }

        self.armRecv(conn);
    }

    /// Serve the request whose body just finished draining: the head bytes
    /// were kept at the front of buf, so the normal parse path re-reads them
    /// and invokes the handler with the counted received total.
    fn finishDrainedRequest(self: *Worker, conn: *Conn) void {
        conn.filled = conn.pending_head_len;

        const outcome = self.dispatch(conn);
        self.afterDispatch(conn, outcome);
    }

    /// Submit the staged send when there is one, otherwise close, continue an
    /// oversized-body drain, or re-arm a recv.
    fn afterDispatch(self: *Worker, conn: *Conn, outcome: ConnOutcome) void {
        if (conn.staged > 0) {
            if (outcome == .close) conn.closing = true;
            self.submitSend(conn);

            return;
        }

        if (outcome == .close) {
            self.beginClose(conn);

            return;
        }

        if (conn.drain > 0) {
            self.armDrainRecv(conn);

            return;
        }

        self.armRecv(conn);
    }

    /// Parse every complete request in the receive buffer, run its handler,
    /// and stage the response bytes in the connection send buffer.
    fn dispatch(self: *Worker, conn: *Conn) ConnOutcome {
        var sink = RespSink{
            .fd = conn.fd,
            .buf = conn.send_buf,
            .buf_owned = conn.send_heap,
            .grow_allocator = self.allocator,
            .grow_cap = MAX_RESPONSE_BYTES,
        };
        writer.tl_resp_sink = &sink;
        defer {
            writer.tl_resp_sink = null;
            conn.send_buf = sink.buf;
            conn.send_heap = sink.buf_owned;
            conn.staged = sink.len - sink.off;
            conn.staged_off = sink.off;
        }

        var consumed: usize = 0;
        var keep_alive = true;
        var scan_from = conn.scan_from;
        conn.scan_from = 0;

        while (consumed < conn.filled) {
            const rem = conn.buf[consumed..conn.filled];
            const header_end = std.mem.indexOfPos(
                u8,
                rem,
                scan_from,
                "\r\n\r\n",
            ) orelse {
                if (rem.len >= conn.buf.len) {
                    _ = stageResponse(conn.fd, RESPONSE_431);
                    keep_alive = false;

                    break;
                }

                conn.scan_from = if (rem.len > 3) rem.len - 3 else 0;

                break;
            };
            scan_from = 0;

            const parsed = parser.parseHeadAt(rem, header_end) catch |err| switch (err) {
                else => {
                    _ = stageResponse(conn.fd, parser.parseErrorResponse(err));
                    keep_alive = false;

                    break;
                },
            };
            const req_head = parsed.head;

            if (req_head.expect_continue and
                !conn.continue_sent and
                (req_head.content_length > 0 or req_head.chunked_request))
            {
                if (!stageResponse(conn.fd, RESPONSE_100_CONTINUE)) {
                    keep_alive = false;

                    break;
                }
                conn.continue_sent = true;
            }

            var body: []const u8 = &.{};
            var request_len: usize = parsed.body_offset;

            if (req_head.chunked_request) {
                const decoded = chunk.decodeChunkedInBuf(
                    rem[parsed.body_offset..],
                    self.body_buf,
                );
                switch (decoded.stop) {
                    .COMPLETE => {},
                    .NEED_MORE => break,
                    .MALFORMED => {
                        _ = stageResponse(conn.fd, RESPONSE_400_CLOSE);
                        keep_alive = false;

                        break;
                    },
                    .TOO_LARGE => {
                        _ = stageResponse(conn.fd, RESPONSE_413_CLOSE);
                        keep_alive = false;

                        break;
                    },
                }

                body = self.body_buf[0..decoded.len];
                request_len = parsed.body_offset + decoded.consumed;
            } else if (req_head.content_length > 0) {
                if (self.max_request_body != 0 and
                    req_head.content_length > self.max_request_body)
                {
                    _ = stageResponse(conn.fd, RESPONSE_413_CLOSE);
                    keep_alive = false;

                    break;
                }

                if (req_head.content_length >
                    std.math.maxInt(usize) - parsed.body_offset)
                {
                    _ = stageResponse(conn.fd, RESPONSE_413_CLOSE);
                    keep_alive = false;

                    break;
                }

                const content_length: usize = @intCast(req_head.content_length);
                const need = parsed.body_offset + content_length;

                if (need <= rem.len) {
                    body = rem[parsed.body_offset..need];
                    request_len = need;
                } else if (conn.pending_head_len > 0) {
                    handler.tl_body_info = .{
                        .received = conn.drain_received,
                        .complete = true,
                    };
                    conn.pending_head_len = 0;
                    conn.drain_received = 0;
                    request_len = parsed.body_offset;
                } else if (need > conn.buf.len) {
                    // Best effort: a kernel that rejects SO_RCVBUF still drains the body.
                    reader.setRecvBuf(
                        conn.fd,
                        self.large_body_recv_buf,
                    ) catch |err| switch (err) {
                        else => {},
                    };

                    if (consumed > 0) {
                        std.mem.copyForwards(
                            u8,
                            conn.buf[0..parsed.body_offset],
                            rem[0..parsed.body_offset],
                        );
                    }

                    const present_body = rem.len - parsed.body_offset;
                    conn.drain = content_length - present_body;
                    conn.drain_received = present_body;
                    conn.pending_head_len = parsed.body_offset;
                    consumed = conn.filled;

                    break;
                } else {
                    break;
                }
            }

            handler.setTimeout(self.io, self.handler_timeout_ms);
            _ = self.arena.reset(.retain_capacity);
            handler.invokeHandler(
                self.handler_fn,
                &req_head,
                body,
                conn.fd,
                self.io,
                self.arena.allocator(),
            );

            consumed += request_len;
            conn.continue_sent = false;

            // WebSocket.serve was called: the bytes after this request are frames.
            if (ws_pending.take()) |pending| {
                conn.ws = pending.on_frame;

                break;
            }

            if (!req_head.keep_alive) {
                keep_alive = false;

                break;
            }
        }

        if (consumed >= conn.filled) {
            conn.filled = 0;
        } else if (consumed > 0) {
            std.mem.copyForwards(
                u8,
                conn.buf[0 .. conn.filled - consumed],
                conn.buf[consumed..conn.filled],
            );
            conn.filled -= consumed;
        }

        // Just upgraded: switch buf from the HTTP size to the WebSocket size.
        if (conn.ws != null and !resizeForWs(self.allocator, conn, self.ws_recv_buf_size)) {
            return .close;
        }

        return if (keep_alive) .keep_alive else .close;
    }

    /// Close intent: flush staged bytes first when possible, otherwise free
    /// now. With a send in flight the free is deferred to the send completion.
    fn beginClose(self: *Worker, conn: *Conn) void {
        conn.closing = true;
        if (conn.inflight > 0) return;

        if (conn.staged > 0) {
            self.submitSend(conn);

            return;
        }

        self.finishClose(conn);
    }

    /// Clear the slot, free the connection, then hand the close to the ring so
    /// the worker never blocks on it. A full submission queue falls back to a
    /// synchronous close, so the fd is never leaked.
    fn finishClose(self: *Worker, conn: *Conn) void {
        const fd = conn.fd;
        const idx: usize = @intCast(fd);
        if (idx < self.slots.len and self.slots[idx] == conn) {
            self.slots[idx] = null;
        }
        connFree(self.allocator, conn);

        const sqe = self.getSqe() orelse {
            _ = linux.close(fd);

            return;
        };

        sqe.prep_close(fd);
        sqe.user_data = packUserData(.close, 0, fd);
    }

    fn deinitConns(self: *Worker) void {
        for (self.slots) |slot| {
            if (slot) |conn| connFree(self.allocator, conn);
        }
    }

    fn service(self: *Worker, stop: *std.atomic.Value(bool)) void {
        self.armAccept();

        var cqes: [CQE_BATCH]linux.io_uring_cqe = undefined;
        while (!stop.load(.acquire)) {
            waitOnce(&self.ring) catch |err| switch (err) {
                else => {
                    stop.store(true, .release);

                    return;
                },
            };

            if (self.accept_pending) {
                self.accept_pending = false;
                self.armAccept();
            }

            const count = self.ring.copy_cqes(&cqes, 0) catch |err| switch (err) {
                else => {
                    stop.store(true, .release);

                    return;
                },
            };

            for (cqes[0..count]) |cqe| {
                const decoded = unpackUserData(cqe.user_data);
                switch (decoded.op) {
                    .accept => self.handleAccept(cqe),
                    .recv => self.handleRecv(cqe, decoded),
                    .send => self.handleSend(cqe, decoded),
                    .close => {},
                }
            }
        }
    }
};

fn packUserData(op: OpKind, gen: u24, fd: linux.fd_t) u64 {
    const fd_bits: u32 = @bitCast(fd);

    return (@as(u64, @intFromEnum(op)) << 56) |
        (@as(u64, gen) << 32) |
        fd_bits;
}

fn unpackUserData(user_data: u64) Decoded {
    return .{
        .op = @enumFromInt(@as(u8, @intCast(user_data >> 56))),
        .gen = @intCast((user_data >> 32) & 0xff_ff_ff),
        .fd = @bitCast(@as(u32, @intCast(user_data & 0xff_ff_ff_ff))),
    };
}

fn workerCount(workers: usize) usize {
    if (workers != 0) return workers;

    const cpu = std.Thread.getCpuCount() catch |err| switch (err) {
        else => 1,
    };

    return @max(1, cpu);
}

/// Best effort: a kernel that rejects TCP_NODELAY still serves the request.
fn setNoDelay(fd: std.posix.fd_t) void {
    std.posix.setsockopt(
        fd,
        std.posix.IPPROTO.TCP,
        std.posix.TCP.NODELAY,
        std.mem.asBytes(&@as(c_int, 1)),
    ) catch |err| switch (err) {
        else => {},
    };
}

fn initRing() Error!IoUring {
    var params = std.mem.zeroInit(linux.io_uring_params, .{
        .flags = linux.IORING_SETUP_SINGLE_ISSUER |
            linux.IORING_SETUP_DEFER_TASKRUN |
            linux.IORING_SETUP_CQSIZE |
            linux.IORING_SETUP_CLAMP,
        .cq_entries = RING_CQ_ENTRIES,
    });

    const ring = IoUring.init_params(RING_ENTRIES, &params) catch |err| switch (err) {
        else => IoUring.init(RING_ENTRIES, 0) catch |fallback_err| switch (fallback_err) {
            else => return Error.ZixHttp1_Uring_SetupFailed,
        },
    };

    return ring;
}

/// Submit the staged SQEs and wait for at least one completion, with a
/// periodic bound when the kernel supports one so a worker can see stop.
fn waitOnce(ring: *IoUring) Error!void {
    if ((ring.features & linux.IORING_FEAT_EXT_ARG) == 0) {
        _ = ring.submit_and_wait(1) catch |err| switch (err) {
            error.SignalInterrupt => return,
            else => return Error.ZixHttp1_Uring_WaitFailed,
        };

        return;
    }

    const submitted = ring.flush_sq();
    var deadline = linux.kernel_timespec{ .sec = WAIT_SECONDS, .nsec = 0 };
    var wait_arg = linux.io_uring_getevents_arg{
        .sigmask = 0,
        .sigmask_sz = 0,
        .pad = 0,
        .ts = @intFromPtr(&deadline),
    };
    const ring_fd: u64 = @bitCast(@as(i64, ring.fd));
    const rc = linux.syscall6(
        .io_uring_enter,
        ring_fd,
        submitted,
        1,
        linux.IORING_ENTER_GETEVENTS | linux.IORING_ENTER_EXT_ARG,
        @intFromPtr(&wait_arg),
        @sizeOf(linux.io_uring_getevents_arg),
    );

    switch (linux.errno(rc)) {
        .SUCCESS, .TIME, .INTR => {},
        else => return Error.ZixHttp1_Uring_WaitFailed,
    }
}

fn connAlloc(allocator: std.mem.Allocator, fd: std.posix.fd_t, recv_size: usize) ?*Conn {
    const conn = allocator.create(Conn) catch |err| switch (err) {
        error.OutOfMemory => return null,
    };
    const recv_buf = allocator.alloc(u8, recv_size) catch |err| switch (err) {
        error.OutOfMemory => {
            allocator.destroy(conn);

            return null;
        },
    };
    const send_buf = allocator.alloc(u8, SEND_BUF) catch |err| switch (err) {
        error.OutOfMemory => {
            allocator.free(recv_buf);
            allocator.destroy(conn);

            return null;
        },
    };
    conn.* = .{
        .fd = fd,
        .buf = recv_buf,
        .send_buf = send_buf,
        .send_heap = true,
    };

    return conn;
}

/// Resize buf for a connection that just upgraded to WebSocket, keeping the
/// frame bytes already received.
///
/// Return:
/// - true when buf has the new size
/// - false when the received bytes do not fit or the allocation failed
fn resizeForWs(allocator: std.mem.Allocator, conn: *Conn, size: usize) bool {
    if (conn.buf.len == size) return true;
    if (conn.filled > size) return false;

    conn.buf = allocator.realloc(conn.buf, size) catch |err| switch (err) {
        error.OutOfMemory => return false,
    };

    return true;
}

fn connFree(allocator: std.mem.Allocator, conn: *Conn) void {
    if (conn.send_heap) allocator.free(conn.send_buf);

    allocator.free(conn.buf);
    allocator.destroy(conn);
}

/// Stage what a peer gets when it hangs up part way through a request.
///
/// Note:
/// - Bytes left in buf, or a head parked on a drain that can never reach zero,
///   are a request that never finished arriving. A bare close reads the same to
///   a client as a crash, a timeout, or a dropped connection, so answer 400.
/// - An idle keep-alive connection has neither and closes without a byte.
fn stageHangupAnswer(conn: *Conn) void {
    if (conn.filled == 0 and conn.pending_head_len == 0) return;

    writer.writeAllFD(conn.fd, RESPONSE_400_CLOSE) catch |err| switch (err) {
        error.ZixHttp1_Writer_BrokenPipe,
        error.ZixHttp1_Writer_HeadBuild,
        => {},
    };
}

fn stageResponse(fd: std.posix.fd_t, bytes: []const u8) bool {
    writer.writeAllFD(fd, bytes) catch |err| switch (err) {
        error.ZixHttp1_Writer_BrokenPipe,
        error.ZixHttp1_Writer_HeadBuild,
        => return false,
    };

    return true;
}

fn closeListeners(listeners: []std.Io.net.Server, io: std.Io) void {
    for (listeners) |*listener| listener.deinit(io);
}

fn failSetup(ctx: *const WorkerCtx) void {
    ctx.failed.store(true, .release);
    ctx.stop.store(true, .release);
}

fn workerMain(ctx: WorkerCtx) void {
    const io = ctx.config.io;
    var listener = ctx.listener;
    defer listener.deinit(io);

    handler.setAccessLogger(ctx.config.logger);
    head.setDateHeader(ctx.config.send_date_header);
    header.setMaxResponseHeaders(ctx.config.max_response_headers.value());
    compress.installWorker(ctx.config);
    static.setStatic(ctx.config.public_dir, io);

    // Per-worker response cache. It lives on the worker stack, so the pointer
    // installed for this thread stays valid until this worker returns.
    var resp_cache: ?ResponseCache = null;
    cache.installWorker(&resp_cache, ctx.allocator, ctx.config);
    defer cache.uninstallWorker(&resp_cache);

    const recv_size = ctx.config.recvBufSize();
    const ws_size = ctx.config.wsRecvBufSize();
    const listener_fd = listener.socket.handle;

    const slots = slab.mapZeroedSlots(?*Conn, MAX_FD) catch |err| switch (err) {
        else => {
            failSetup(&ctx);

            return;
        },
    };
    defer slab.unmapSlots(slots);

    const body_buf = ctx.allocator.alloc(u8, recv_size) catch |err| switch (err) {
        error.OutOfMemory => {
            failSetup(&ctx);

            return;
        },
    };
    defer ctx.allocator.free(body_buf);

    const ws_payload_buf = ctx.allocator.alloc(u8, ws_size) catch |err| switch (err) {
        error.OutOfMemory => {
            failSetup(&ctx);

            return;
        },
    };
    defer ctx.allocator.free(ws_payload_buf);

    var arena = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena.deinit();

    var worker = Worker{
        .slots = slots,
        .listener_fd = listener_fd,
        .io = io,
        .handler_fn = ctx.handler,
        .allocator = ctx.allocator,
        .body_buf = body_buf,
        .arena = &arena,
        .recv_buf_size = recv_size,
        .handler_timeout_ms = ctx.config.handler_timeout_ms,
        .max_request_body = ctx.config.max_request_body,
        .large_body_recv_buf = ctx.config.large_body_recv_buf,
        .ws_recv_buf_size = ws_size,
        .ws_payload_buf = ws_payload_buf,
    };
    worker.ring = initRing() catch |err| switch (err) {
        else => {
            failSetup(&ctx);

            return;
        },
    };
    defer worker.ring.deinit();

    // Best effort: without buffer rings, WebSocket falls back to plain recv.
    worker.ws_bufs = IoUring.BufferGroup.init(
        &worker.ring,
        ctx.allocator,
        WS_RING_BGID,
        WS_RING_BUF_SIZE,
        WS_RING_BUF_COUNT,
    ) catch |err| switch (err) {
        else => null,
    };
    defer if (worker.ws_bufs) |*group| group.deinit(ctx.allocator);
    defer worker.deinitConns();

    worker.service(ctx.stop);

    if (ctx.stop.load(.acquire)) failSetup(&ctx);
}

// --------------------------------------------------------- //
// Public:

/// ZIX Http1 uring dispatch error
pub const Error = error {
    ZixHttp1_Uring_Unsupported,
    ZixHttp1_Uring_ResolveFailed,
    ZixHttp1_Uring_ListenFailed,
    ZixHttp1_Uring_OutOfMemory,
    ZixHttp1_Uring_SpawnFailed,
    ZixHttp1_Uring_SetupFailed,
    ZixHttp1_Uring_WaitFailed,
};

/// Run one uring worker per CPU, or per config.workers when non-zero.
pub fn run(config: Config, handler_fn: HandlerFn) Error!void {
    if (comptime builtin.target.os.tag != .linux) {
        return Error.ZixHttp1_Uring_Unsupported;
    }

    const io = config.io;
    const allocator = std.heap.smp_allocator;
    const workers = workerCount(config.workers);

    const address = std.Io.net.IpAddress.resolve(
        io,
        config.ip,
        config.port,
    ) catch |err| switch (err) {
        else => return Error.ZixHttp1_Uring_ResolveFailed,
    };

    const listeners = allocator.alloc(
        std.Io.net.Server,
        workers,
    ) catch |err| switch (err) {
        error.OutOfMemory => return Error.ZixHttp1_Uring_OutOfMemory,
    };

    var bound: usize = 0;
    while (bound < workers) : (bound += 1) {
        listeners[bound] = address.listen(io, .{
            .mode = .stream,
            .reuse_address = true,
            .kernel_backlog = config.kernel_backlog,
        }) catch |err| switch (err) {
            else => {
                closeListeners(listeners[0..bound], io);
                allocator.free(listeners);

                return Error.ZixHttp1_Uring_ListenFailed;
            },
        };
    }

    const threads = allocator.alloc(
        std.Thread,
        workers,
    ) catch |err| switch (err) {
        error.OutOfMemory => {
            closeListeners(listeners, io);
            allocator.free(listeners);

            return Error.ZixHttp1_Uring_OutOfMemory;
        },
    };
    defer allocator.free(threads);

    var stop = std.atomic.Value(bool).init(false);
    var failed = std.atomic.Value(bool).init(false);

    var spawned: usize = 0;
    while (spawned < workers) : (spawned += 1) {
        threads[spawned] = std.Thread.spawn(
            .{},
            workerMain,
            .{WorkerCtx{
                .config = config,
                .handler = handler_fn,
                .listener = listeners[spawned],
                .allocator = allocator,
                .stop = &stop,
                .failed = &failed,
            }},
        ) catch |err| switch (err) {
            else => {
                stop.store(true, .release);
                closeListeners(listeners[spawned..], io);
                for (threads[0..spawned]) |thread| thread.join();
                allocator.free(listeners);

                return Error.ZixHttp1_Uring_SpawnFailed;
            },
        };
    }

    log.logSystem(
        config,
        .INFO,
        "listening on {s}:{d} (io_uring, {d} workers)",
        .{ config.ip, config.port, workers },
    );

    for (threads) |thread| thread.join();

    allocator.free(listeners);

    if (failed.load(.acquire)) return Error.ZixHttp1_Uring_SetupFailed;
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const Context = @import("../Context.zig");
const Request = @import("../Request.zig");
const Response = @import("../Response.zig");
const pair = @import("../../../utils/socket/pair.zig");

/// Receive buffer size the tests allocate, the same 16 KiB the worker used before
/// it read max_recv_buf from Config.
const TEST_CONN_BUF: usize = 16 * 1024;

/// SO_RCVBUF the kernel reports for fd.
fn testRecvBufSize(fd: std.posix.fd_t) !usize {
    var value: c_int = 0;
    var len: linux.socklen_t = @sizeOf(c_int);
    const rc = linux.getsockopt(
        fd,
        std.posix.SOL.SOCKET,
        std.posix.SO.RCVBUF,
        std.mem.asBytes(&value),
        &len,
    );
    if (std.posix.errno(rc) != .SUCCESS) return error.ZixTest_GetSockOptFailed;

    return @intCast(value);
}

fn okHandler(_: *Request, res: *Response, _: *Context) anyerror!void {
    res.setContentType(.TEXT_PLAIN);

    try res.send("ok");
}

fn echoLenHandler(req: *Request, res: *Response, _: *Context) anyerror!void {
    var buf: [48]u8 = undefined;
    const out = std.fmt.bufPrint(
        &buf,
        "{d}:{s}",
        .{
            req.bodyReceived(),
            if (req.bodyComplete()) "whole" else "cut",
        },
    ) catch |err| switch (err) {
        else => return,
    };

    res.setContentType(.TEXT_PLAIN);

    try res.send(out);
}

fn testWorker(
    handler_fn: HandlerFn,
    allocator: std.mem.Allocator,
    body_buf: []u8,
    arena: *std.heap.ArenaAllocator,
) Worker {
    return .{
        .io = std.testing.io,
        .handler_fn = handler_fn,
        .allocator = allocator,
        .body_buf = body_buf,
        .arena = arena,
        .recv_buf_size = TEST_CONN_BUF,
        .ws_payload_buf = body_buf,
    };
}

fn testWriteAll(fd: std.posix.fd_t, bytes: []const u8) !void {
    var written: usize = 0;
    while (written < bytes.len) {
        const rc = std.posix.system.write(
            fd,
            bytes[written..].ptr,
            bytes.len - written,
        );
        switch (std.posix.errno(rc)) {
            .SUCCESS => {
                const count: usize = @intCast(rc);
                if (count == 0) return error.TestWriteClosed;
                written += count;
            },
            .INTR => continue,
            else => return error.TestWriteFailed,
        }
    }
}

fn testReadAvailable(fd: std.posix.fd_t, out: []u8) []u8 {
    var len: usize = 0;
    while (len < out.len) {
        const rc = linux.recvfrom(
            fd,
            out[len..].ptr,
            out.len - len,
            linux.MSG.DONTWAIT,
            null,
            null,
        );
        switch (std.posix.errno(rc)) {
            .SUCCESS => {
                const count: usize = @intCast(rc);
                if (count == 0) break;
                len += count;
            },
            .AGAIN => break,
            .INTR => continue,
            else => break,
        }
    }

    return out[0..len];
}

fn testPair() ![2]std.posix.fd_t {
    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);

    return fds;
}

fn testConn(fd: std.posix.fd_t, buf: []u8, send_buf: []u8) Conn {
    return .{
        .fd = fd,
        .buf = buf,
        .send_buf = send_buf,
        .send_heap = false,
    };
}

const compression = @import("../../../utils/compression/compression.zig");

/// Body sendNegotiated compresses in the compression parity test.
const NEGOTIATED_BODY = blk: {
    const unit = "zix compression parity body. ";
    var text: [unit.len * 40]u8 = undefined;
    for (0..40) |i| @memcpy(text[i * unit.len ..][0..unit.len], unit);

    break :blk text;
};

fn negotiatedHandler(req: *Request, res: *Response, _: *Context) anyerror!void {
    res.setContentType(.TEXT_PLAIN);

    try res.sendNegotiated(req, &NEGOTIATED_BODY);
}

fn testCompressConfig() Config {
    return .{
        .io = std.testing.io,
        .ip = "127.0.0.1",
        .port = 0,
        .dispatch_model = .URING,
        .compress = true,
    };
}

/// The response carries gzip, and its body inflates back to NEGOTIATED_BODY.
fn expectGzipResponse(bytes: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, bytes, "Content-Encoding: gzip\r\n") != null);

    const head_end = std.mem.indexOf(u8, bytes, "\r\n\r\n").?;
    const plain = try compression.decode(
        std.testing.allocator,
        .GZIP,
        bytes[head_end + 4 ..],
        1 << 16,
    );
    defer std.testing.allocator.free(plain);

    try std.testing.expectEqualStrings(&NEGOTIATED_BODY, plain);
}

/// Slow-path count of cachedHandler. A cache hit returns before it counts.
var cached_miss_count: usize = 0;

fn cachedHandler(req: *Request, res: *Response, _: *Context) anyerror!void {
    if (try res.sendFromCache(req)) return;

    cached_miss_count += 1;
    res.setContentType(.TEXT_PLAIN);

    try res.sendCached(req, "cached", 60_000);
}

/// Exact wire bytes cachedHandler answers with, on a miss and on a hit.
const CACHED_RESPONSE =
    "HTTP/1.1 200 Ok\r\nContent-Type: text/plain\r\n" ++
    "Content-Length: 6\r\n\r\ncached";

/// Two pipelined requests must get two byte-identical cached responses.
fn expectTwoCachedResponses(bytes: []const u8) !void {
    try std.testing.expectEqual(CACHED_RESPONSE.len * 2, bytes.len);
    try std.testing.expectEqualStrings(CACHED_RESPONSE, bytes[0..CACHED_RESPONSE.len]);
    try std.testing.expectEqualStrings(CACHED_RESPONSE, bytes[CACHED_RESPONSE.len..]);
}

fn testCacheConfig() Config {
    return .{
        .io = std.testing.io,
        .ip = "127.0.0.1",
        .port = 0,
        .dispatch_model = .URING,
        .response_cache = true,
        .cache_max_entries = 8,
        .cache_max_value_bytes = 1024,
    };
}

const websocket = @import("../websocket.zig");

const WS_UPGRADE_REQUEST =
    "GET /ws HTTP/1.1\r\n" ++
    "Upgrade: websocket\r\n" ++
    "Connection: Upgrade\r\n" ++
    "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n";

const WS_UPGRADE_RESPONSE =
    "HTTP/1.1 101 Switching Protocols\r\n" ++
    "Upgrade: websocket\r\n" ++
    "Connection: Upgrade\r\n" ++
    "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n\r\n";

/// Masked "Hello" text frame from RFC 6455 section 5.7.
const WS_MASKED_HELLO = [_]u8{
    0x81, 0x85, 0x37, 0xfa, 0x21, 0x3d,
    0x7f, 0x9f, 0x4d, 0x51, 0x58,
};

/// Masked close frame with no payload.
const WS_MASKED_CLOSE = [_]u8{ 0x88, 0x80, 1, 2, 3, 4 };

fn testWsEcho(fd: std.posix.fd_t, opcode: u8, payload: []const u8) void {
    websocket.sendFD(fd, @enumFromInt(opcode), payload) catch |err| switch (err) {
        error.ZixHttp1_WebSocketSend_BrokenPipe,
        error.ZixHttp1_WebSocketSend_HeadBuild,
        => {},
    };
}

fn wsHandler(req: *Request, _: *Response, _: *Context) anyerror!void {
    try websocket.serve(req.fd, req.header("sec-websocket-key").?, testWsEcho);
}

/// Wait for one completion and return it.
fn testOneCqe(ring: *IoUring) !linux.io_uring_cqe {
    try waitOnce(ring);

    var cqes: [1]linux.io_uring_cqe = undefined;
    const count = ring.copy_cqes(&cqes, 1) catch |err| switch (err) {
        else => return error.TestRingCopyFailed,
    };
    if (count != 1) return error.TestRingNoCompletion;

    return cqes[0];
}

/// A worker with a ring, a WebSocket buffer ring, and one WebSocket
/// connection on fd in its slot table.
const TestWsRing = struct {
    worker: Worker,
    slots: []?*Conn,
    conn: *Conn,

    fn init(fd: std.posix.fd_t, body_buf: []u8, arena: *std.heap.ArenaAllocator) !?TestWsRing {
        var worker = testWorker(okHandler, std.testing.allocator, body_buf, arena);
        worker.ring = testRing() orelse return null;

        const slots = try std.testing.allocator.alloc(?*Conn, @as(usize, @intCast(fd)) + 1);
        @memset(slots, null);
        worker.slots = slots;

        const conn = connAlloc(std.testing.allocator, fd, 64).?;
        conn.ws = testWsEcho;
        slots[@intCast(fd)] = conn;

        return .{
            .worker = worker,
            .slots = slots,
            .conn = conn,
        };
    }

    /// Register the buffer ring. Call once the struct is at its final address.
    fn initBufs(self: *TestWsRing) bool {
        self.worker.ws_bufs = IoUring.BufferGroup.init(
            &self.worker.ring,
            std.testing.allocator,
            WS_RING_BGID,
            WS_RING_BUF_SIZE,
            4,
        ) catch |err| switch (err) {
            else => {
                std.log.info("buffer ring unavailable ({s}), test skipped", .{@errorName(err)});

                return false;
            },
        };

        return true;
    }

    fn deinit(self: *TestWsRing) void {
        const live = self.slots[@intCast(self.conn.fd)] != null;
        if (live) connFree(std.testing.allocator, self.conn);
        if (self.worker.ws_bufs) |*group| group.deinit(std.testing.allocator);
        self.worker.ring.deinit();
        std.testing.allocator.free(self.slots);
    }
};

/// A ring for the WebSocket tests, or null when the kernel has none.
fn testRing() ?IoUring {
    return initRing() catch |err| switch (err) {
        else => {
            std.log.info("io_uring unavailable ({s}), test skipped", .{@errorName(err)});

            return null;
        },
    };
}

test "zix http1: uring, user_data round trip preserves op, gen, fd" {
    const decoded = unpackUserData(packUserData(.send, 0xabcdef, 1234));

    try std.testing.expectEqual(OpKind.send, decoded.op);
    try std.testing.expectEqual(@as(u24, 0xabcdef), decoded.gen);
    try std.testing.expectEqual(@as(linux.fd_t, 1234), decoded.fd);
}

test "zix http1: uring, answers one request" {
    if (comptime builtin.target.os.tag != .linux) {
        std.log.info("URING is Linux-only, test skipped", .{});

        return;
    }

    const fds = try testPair();
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    head.setDateHeader(false);
    defer head.setDateHeader(true);

    var conn_buf: [4096]u8 = undefined;
    const req = "GET / HTTP/1.1\r\nConnection: close\r\n\r\n";
    @memcpy(conn_buf[0..req.len], req);

    var send_buf: [1024]u8 = undefined;
    var conn = testConn(fds[1], &conn_buf, &send_buf);
    conn.filled = req.len;

    var body_buf: [4096]u8 = undefined;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var worker = testWorker(okHandler, std.testing.allocator, &body_buf, &arena);
    const outcome = worker.dispatch(&conn);

    try std.testing.expectEqual(ConnOutcome.close, outcome);
    try std.testing.expectEqualStrings(
        "HTTP/1.1 200 Ok\r\nContent-Type: text/plain\r\n" ++
            "Content-Length: 2\r\n\r\nok",
        send_buf[0..conn.staged],
    );
}

test "zix http1: uring, answers a pipelined burst in order" {
    if (comptime builtin.target.os.tag != .linux) {
        std.log.info("URING is Linux-only, test skipped", .{});

        return;
    }

    const fds = try testPair();
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    head.setDateHeader(false);
    defer head.setDateHeader(true);

    var conn_buf: [4096]u8 = undefined;
    const req =
        "GET /a HTTP/1.1\r\nConnection: keep-alive\r\n\r\n" ++
        "GET /b HTTP/1.1\r\nConnection: close\r\n\r\n";
    @memcpy(conn_buf[0..req.len], req);

    var send_buf: [1024]u8 = undefined;
    var conn = testConn(fds[1], &conn_buf, &send_buf);
    conn.filled = req.len;

    var body_buf: [4096]u8 = undefined;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var worker = testWorker(okHandler, std.testing.allocator, &body_buf, &arena);
    const outcome = worker.dispatch(&conn);

    try std.testing.expectEqual(ConnOutcome.close, outcome);
    try std.testing.expectEqual(@as(usize, 0), conn.filled);

    const resp = send_buf[0..conn.staged];
    try std.testing.expectEqual(
        @as(usize, 2),
        std.mem.count(u8, resp, "HTTP/1.1 200 Ok"),
    );
    try std.testing.expectEqual(
        @as(usize, 2),
        std.mem.count(u8, resp, "Content-Length: 2"),
    );
}

test "zix http1: uring, waits for the rest of a split head" {
    if (comptime builtin.target.os.tag != .linux) {
        std.log.info("URING is Linux-only, test skipped", .{});

        return;
    }

    const fds = try testPair();
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    head.setDateHeader(false);
    defer head.setDateHeader(true);

    var conn_buf: [4096]u8 = undefined;
    const first_req = "GET / HTTP/1.1\r\n";
    @memcpy(conn_buf[0..first_req.len], first_req);

    var send_buf: [1024]u8 = undefined;
    var conn = testConn(fds[1], &conn_buf, &send_buf);
    conn.filled = first_req.len;

    var body_buf: [4096]u8 = undefined;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var worker = testWorker(okHandler, std.testing.allocator, &body_buf, &arena);
    const first = worker.dispatch(&conn);

    try std.testing.expectEqual(ConnOutcome.keep_alive, first);
    try std.testing.expectEqual(@as(usize, 0), conn.staged);
    try std.testing.expect(conn.scan_from > 0);

    const rest = "Connection: close\r\n\r\n";
    @memcpy(conn_buf[conn.filled..][0..rest.len], rest);
    conn.filled += rest.len;

    const second = worker.dispatch(&conn);

    try std.testing.expectEqual(ConnOutcome.close, second);
    try std.testing.expectEqualStrings(
        "HTTP/1.1 200 Ok\r\nContent-Type: text/plain\r\n" ++
            "Content-Length: 2\r\n\r\nok",
        send_buf[0..conn.staged],
    );
}

test "zix http1: uring, answers a malformed request with 400" {
    if (comptime builtin.target.os.tag != .linux) {
        std.log.info("URING is Linux-only, test skipped", .{});

        return;
    }

    const fds = try testPair();
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    head.setDateHeader(false);
    defer head.setDateHeader(true);

    var conn_buf: [4096]u8 = undefined;
    const req = "BAD\r\n\r\n";
    @memcpy(conn_buf[0..req.len], req);

    var send_buf: [1024]u8 = undefined;
    var conn = testConn(fds[1], &conn_buf, &send_buf);
    conn.filled = req.len;

    var body_buf: [4096]u8 = undefined;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var worker = testWorker(okHandler, std.testing.allocator, &body_buf, &arena);
    const outcome = worker.dispatch(&conn);

    try std.testing.expectEqual(ConnOutcome.close, outcome);
    try std.testing.expectEqualStrings(
        "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n",
        send_buf[0..conn.staged],
    );
}

test "zix http1: uring, answers 431 when the head fills the buffer" {
    if (comptime builtin.target.os.tag != .linux) {
        std.log.info("URING is Linux-only, test skipped", .{});

        return;
    }

    const fds = try testPair();
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    head.setDateHeader(false);
    defer head.setDateHeader(true);

    var conn_buf: [64]u8 = undefined;
    @memset(&conn_buf, 'a');

    var send_buf: [1024]u8 = undefined;
    var conn = testConn(fds[1], &conn_buf, &send_buf);
    conn.filled = conn_buf.len;

    var body_buf: [4096]u8 = undefined;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var worker = testWorker(okHandler, std.testing.allocator, &body_buf, &arena);
    const outcome = worker.dispatch(&conn);

    try std.testing.expectEqual(ConnOutcome.close, outcome);
    try std.testing.expectEqualStrings(
        "HTTP/1.1 431 Request Header Fields Too Large\r\n" ++
            "Content-Length: 0\r\n\r\n",
        send_buf[0..conn.staged],
    );
}

test "zix http1: uring, sends 100 Continue while the body is still arriving" {
    if (comptime builtin.target.os.tag != .linux) {
        std.log.info("URING is Linux-only, test skipped", .{});

        return;
    }

    const fds = try testPair();
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    head.setDateHeader(false);
    defer head.setDateHeader(true);

    var conn_buf: [4096]u8 = undefined;
    const head_part =
        "POST / HTTP/1.1\r\nExpect: 100-continue\r\n" ++
        "Content-Length: 2\r\n\r\n";
    @memcpy(conn_buf[0..head_part.len], head_part);

    var send_buf: [1024]u8 = undefined;
    var conn = testConn(fds[1], &conn_buf, &send_buf);
    conn.filled = head_part.len;

    var body_buf: [4096]u8 = undefined;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var worker = testWorker(okHandler, std.testing.allocator, &body_buf, &arena);
    const first = worker.dispatch(&conn);

    try std.testing.expectEqual(ConnOutcome.keep_alive, first);
    try std.testing.expect(conn.continue_sent);
    try std.testing.expectEqualStrings(
        "HTTP/1.1 100 Continue\r\n\r\n",
        send_buf[0..conn.staged],
    );

    @memcpy(conn_buf[conn.filled..][0..2], "ok");
    conn.filled += 2;
    conn.staged = 0;

    const second = worker.dispatch(&conn);

    try std.testing.expectEqual(ConnOutcome.keep_alive, second);
    try std.testing.expectEqualStrings(
        "HTTP/1.1 200 Ok\r\nContent-Type: text/plain\r\n" ++
            "Content-Length: 2\r\n\r\nok",
        send_buf[0..conn.staged],
    );
}

test "zix http1: uring, decodes a fully present chunked body" {
    if (comptime builtin.target.os.tag != .linux) {
        std.log.info("URING is Linux-only, test skipped", .{});

        return;
    }

    const fds = try testPair();
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    head.setDateHeader(false);
    defer head.setDateHeader(true);

    var conn_buf: [4096]u8 = undefined;
    const req =
        "POST /u HTTP/1.1\r\nHost: t\r\nTransfer-Encoding: chunked\r\n\r\n" ++
        "2\r\n20\r\n0\r\n\r\n";
    @memcpy(conn_buf[0..req.len], req);

    var send_buf: [1024]u8 = undefined;
    var conn = testConn(fds[1], &conn_buf, &send_buf);
    conn.filled = req.len;

    var body_buf: [4096]u8 = undefined;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var worker = testWorker(
        echoLenHandler,
        std.testing.allocator,
        &body_buf,
        &arena,
    );
    const outcome = worker.dispatch(&conn);

    try std.testing.expectEqual(ConnOutcome.keep_alive, outcome);
    try std.testing.expectEqual(@as(usize, 0), conn.filled);
    try std.testing.expect(
        std.mem.endsWith(u8, send_buf[0..conn.staged], "\r\n\r\n2:whole"),
    );
}

test "zix http1: uring, defers a body larger than the receive buffer" {
    if (comptime builtin.target.os.tag != .linux) {
        std.log.info("URING is Linux-only, test skipped", .{});

        return;
    }

    const fds = try testPair();
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    head.setDateHeader(false);
    defer head.setDateHeader(true);

    var conn_buf: [1024]u8 = undefined;
    const req = "POST /u HTTP/1.1\r\nContent-Length: 5000\r\n\r\nabc";
    @memcpy(conn_buf[0..req.len], req);

    var send_buf: [1024]u8 = undefined;
    var conn = testConn(fds[1], &conn_buf, &send_buf);
    conn.filled = req.len;

    var body_buf: [4096]u8 = undefined;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var worker = testWorker(
        echoLenHandler,
        std.testing.allocator,
        &body_buf,
        &arena,
    );
    const outcome = worker.dispatch(&conn);

    try std.testing.expectEqual(ConnOutcome.keep_alive, outcome);
    try std.testing.expectEqual(@as(usize, 0), conn.filled);
    try std.testing.expectEqual(@as(usize, 4997), conn.drain);
    try std.testing.expectEqual(@as(usize, 3), conn.drain_received);
    try std.testing.expect(conn.pending_head_len > 0);
    try std.testing.expectEqual(
        @as(usize, 0),
        conn.staged,
    );

    const head_bytes = conn.buf[0..conn.pending_head_len];
    try std.testing.expect(
        std.mem.startsWith(u8, head_bytes, "POST /u HTTP/1.1\r\n"),
    );
}

test "zix http1: uring, answers 400 when the peer quits mid request" {
    if (comptime builtin.target.os.tag != .linux) {
        std.log.info("URING is Linux-only, test skipped", .{});

        return;
    }

    const fds = try testPair();
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    var conn_buf: [64]u8 = undefined;
    var send_buf: [64]u8 = undefined;
    var conn = testConn(fds[1], &conn_buf, &send_buf);
    conn.filled = 5;

    stageHangupAnswer(&conn);

    var out: [256]u8 = undefined;
    const resp = testReadAvailable(fds[0], &out);

    try std.testing.expectEqualStrings(
        "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n" ++
            "Connection: close\r\n\r\n",
        resp,
    );
}

test "zix http1: uring, init ring receives one byte from a socket pair" {
    if (comptime builtin.target.os.tag != .linux) {
        std.log.info("URING is Linux-only, test skipped", .{});

        return;
    }

    var ring = initRing() catch |err| switch (err) {
        else => {
            std.log.info(
                "io_uring unavailable ({s}), test skipped",
                .{@errorName(err)},
            );

            return;
        },
    };
    defer ring.deinit();

    const fds = try testPair();
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    var buf: [16]u8 = undefined;
    const sqe = try ring.get_sqe();
    sqe.prep_recv(fds[0], &buf, 0);
    sqe.user_data = packUserData(.recv, 7, fds[0]);

    try testWriteAll(fds[1], "zix");
    try waitOnce(&ring);

    var cqes: [4]linux.io_uring_cqe = undefined;
    const count = ring.copy_cqes(&cqes, 0) catch |err| switch (err) {
        else => return error.TestRingCopyFailed,
    };

    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expectEqual(@as(i32, 3), cqes[0].res);
    try std.testing.expectEqualStrings("zix", buf[0..3]);

    const decoded = unpackUserData(cqes[0].user_data);
    try std.testing.expectEqual(OpKind.recv, decoded.op);
    try std.testing.expectEqual(@as(u24, 7), decoded.gen);
    try std.testing.expectEqual(fds[0], decoded.fd);
}

test "zix http1: uring, Worker leaves the request knobs off by default" {
    var body_buf: [64]u8 = undefined;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const worker = testWorker(okHandler, std.testing.allocator, &body_buf, &arena);

    try std.testing.expectEqual(@as(u32, 0), worker.handler_timeout_ms);
    try std.testing.expectEqual(@as(usize, 0), worker.max_request_body);
    try std.testing.expectEqual(@as(usize, 0), worker.large_body_recv_buf);
}

test "zix http1: uring, connAlloc sizes the recv buffer from max_recv_buf" {
    const conn = connAlloc(std.testing.allocator, -1, 2048).?;
    defer connFree(std.testing.allocator, conn);

    try std.testing.expectEqual(@as(usize, 2048), conn.buf.len);
}

test "zix http1: uring, connAlloc fails without memory" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{
        .fail_index = 1,
    });

    try std.testing.expectEqual(
        @as(?*Conn, null),
        connAlloc(failing.allocator(), -1, 2048),
    );
}

test "zix http1: uring, refuses a body past max_request_body with 413" {
    if (comptime builtin.target.os.tag != .linux) {
        std.log.info("URING is Linux-only, test skipped", .{});

        return;
    }

    const fds = try testPair();
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    head.setDateHeader(false);
    defer head.setDateHeader(true);

    var conn_buf: [1024]u8 = undefined;
    const req = "POST /u HTTP/1.1\r\nContent-Length: 5\r\n\r\nhello";
    @memcpy(conn_buf[0..req.len], req);

    var send_buf: [1024]u8 = undefined;
    var conn = testConn(fds[1], &conn_buf, &send_buf);
    conn.filled = req.len;

    var body_buf: [4096]u8 = undefined;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var worker = testWorker(okHandler, std.testing.allocator, &body_buf, &arena);
    worker.max_request_body = 4;

    const outcome = worker.dispatch(&conn);

    try std.testing.expectEqual(ConnOutcome.close, outcome);
    try std.testing.expect(std.mem.startsWith(
        u8,
        send_buf[0..conn.staged],
        "HTTP/1.1 413 Payload Too Large\r\n",
    ));
}

test "zix http1: uring, accepts a body at max_request_body" {
    if (comptime builtin.target.os.tag != .linux) {
        std.log.info("URING is Linux-only, test skipped", .{});

        return;
    }

    const fds = try testPair();
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    head.setDateHeader(false);
    defer head.setDateHeader(true);

    var conn_buf: [1024]u8 = undefined;
    const req = "POST /u HTTP/1.1\r\nContent-Length: 4\r\n\r\nhell";
    @memcpy(conn_buf[0..req.len], req);

    var send_buf: [1024]u8 = undefined;
    var conn = testConn(fds[1], &conn_buf, &send_buf);
    conn.filled = req.len;

    var body_buf: [4096]u8 = undefined;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var worker = testWorker(okHandler, std.testing.allocator, &body_buf, &arena);
    worker.max_request_body = 4;

    const outcome = worker.dispatch(&conn);

    try std.testing.expectEqual(ConnOutcome.keep_alive, outcome);
    try std.testing.expect(std.mem.startsWith(
        u8,
        send_buf[0..conn.staged],
        "HTTP/1.1 200 Ok\r\n",
    ));
}

test "zix http1: uring, large body drain applies large_body_recv_buf" {
    if (comptime builtin.target.os.tag != .linux) {
        std.log.info("URING is Linux-only, test skipped", .{});

        return;
    }

    const fds = try testPair();
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    head.setDateHeader(false);
    defer head.setDateHeader(true);

    const before = try testRecvBufSize(fds[1]);

    var conn_buf: [1024]u8 = undefined;
    const req = "POST /u HTTP/1.1\r\nContent-Length: 5000\r\n\r\nabc";
    @memcpy(conn_buf[0..req.len], req);

    var send_buf: [1024]u8 = undefined;
    var conn = testConn(fds[1], &conn_buf, &send_buf);
    conn.filled = req.len;

    var body_buf: [4096]u8 = undefined;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var worker = testWorker(echoLenHandler, std.testing.allocator, &body_buf, &arena);
    worker.large_body_recv_buf = 4096;

    _ = worker.dispatch(&conn);

    try std.testing.expect(conn.drain > 0);
    try std.testing.expect(try testRecvBufSize(fds[1]) != before);
}

test "zix http1: uring, serves a miss then a hit from the response cache" {
    if (comptime builtin.target.os.tag != .linux) {
        std.log.info("URING is Linux-only, test skipped", .{});

        return;
    }

    const fds = try testPair();
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    head.setDateHeader(false);
    defer head.setDateHeader(true);

    var resp_cache: ?ResponseCache = null;
    cache.installWorker(&resp_cache, std.testing.allocator, testCacheConfig());
    defer cache.uninstallWorker(&resp_cache);

    cached_miss_count = 0;

    var conn_buf: [4096]u8 = undefined;
    const req =
        "GET /cached HTTP/1.1\r\nConnection: keep-alive\r\n\r\n" ++
        "GET /cached HTTP/1.1\r\nConnection: close\r\n\r\n";
    @memcpy(conn_buf[0..req.len], req);

    var send_buf: [1024]u8 = undefined;
    var conn = testConn(fds[1], &conn_buf, &send_buf);
    conn.filled = req.len;

    var body_buf: [4096]u8 = undefined;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var worker = testWorker(cachedHandler, std.testing.allocator, &body_buf, &arena);
    const outcome = worker.dispatch(&conn);

    try std.testing.expectEqual(ConnOutcome.close, outcome);
    try std.testing.expectEqual(@as(usize, 1), cached_miss_count);
    try expectTwoCachedResponses(send_buf[0..conn.staged]);
}

test "zix http1: uring, serves gzip through sendNegotiated" {
    if (comptime builtin.target.os.tag != .linux) {
        std.log.info("URING is Linux-only, test skipped", .{});

        return;
    }

    const fds = try testPair();
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    head.setDateHeader(false);
    defer head.setDateHeader(true);

    compress.installWorker(testCompressConfig());
    defer compress.setCompression(false, 256, 256 * 1024);

    var conn_buf: [4096]u8 = undefined;
    const req = "GET /gz HTTP/1.1\r\nAccept-Encoding: gzip\r\nConnection: close\r\n\r\n";
    @memcpy(conn_buf[0..req.len], req);

    var send_buf: [4096]u8 = undefined;
    var conn = testConn(fds[1], &conn_buf, &send_buf);
    conn.filled = req.len;

    var body_buf: [4096]u8 = undefined;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var worker = testWorker(negotiatedHandler, std.testing.allocator, &body_buf, &arena);
    const outcome = worker.dispatch(&conn);

    try std.testing.expectEqual(ConnOutcome.close, outcome);
    try expectGzipResponse(send_buf[0..conn.staged]);
}

test "zix http1: uring, dispatch promotes an upgrade to WebSocket" {
    if (comptime builtin.target.os.tag != .linux) {
        std.log.info("URING is Linux-only, test skipped", .{});

        return;
    }

    const fds = try testPair();
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    var conn_buf: [4096]u8 = undefined;
    const bytes = WS_UPGRADE_REQUEST ++ WS_MASKED_HELLO;
    @memcpy(conn_buf[0..bytes.len], bytes);

    var send_buf: [1024]u8 = undefined;
    var conn = testConn(fds[1], &conn_buf, &send_buf);
    conn.filled = bytes.len;

    var body_buf: [4096]u8 = undefined;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var worker = testWorker(wsHandler, std.testing.allocator, &body_buf, &arena);
    worker.ws_recv_buf_size = conn_buf.len;
    const outcome = worker.dispatch(&conn);

    try std.testing.expectEqual(ConnOutcome.keep_alive, outcome);
    try std.testing.expect(conn.ws != null);
    try std.testing.expectEqual(WS_MASKED_HELLO.len, conn.filled);
    try std.testing.expectEqualStrings(WS_UPGRADE_RESPONSE, send_buf[0..conn.staged]);
}

test "zix http1: uring, pumpWs stages the echo as one ring send" {
    if (comptime builtin.target.os.tag != .linux) {
        std.log.info("URING is Linux-only, test skipped", .{});

        return;
    }

    var ring = testRing() orelse return;
    defer ring.deinit();

    const fds = try testPair();
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    var conn_buf: [64]u8 = undefined;
    const bytes = WS_MASKED_HELLO ++ WS_MASKED_HELLO;
    @memcpy(conn_buf[0..bytes.len], &bytes);

    var send_buf: [64]u8 = undefined;
    var conn = testConn(fds[1], &conn_buf, &send_buf);
    conn.filled = bytes.len;

    var body_buf: [64]u8 = undefined;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var worker = testWorker(okHandler, std.testing.allocator, &body_buf, &arena);
    worker.ring = ring;
    defer ring = worker.ring;

    worker.pumpWs(&conn, testWsEcho);
    try waitOnce(&worker.ring);

    var out: [64]u8 = undefined;
    const response = testReadAvailable(fds[0], &out);
    const echo = [_]u8{ 0x81, 5 } ++ "Hello".*;

    try std.testing.expectEqual(@as(usize, 0), conn.filled);
    try std.testing.expectEqual(echo.len * 2, conn.inflight);
    try std.testing.expectEqualStrings(&(echo ++ echo), response);
}

test "zix http1: uring, pumpWs closes after a close frame" {
    if (comptime builtin.target.os.tag != .linux) {
        std.log.info("URING is Linux-only, test skipped", .{});

        return;
    }

    var ring = testRing() orelse return;
    defer ring.deinit();

    const fds = try testPair();
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    var conn_buf: [64]u8 = undefined;
    @memcpy(conn_buf[0..WS_MASKED_CLOSE.len], &WS_MASKED_CLOSE);

    var send_buf: [64]u8 = undefined;
    var conn = testConn(fds[1], &conn_buf, &send_buf);
    conn.filled = WS_MASKED_CLOSE.len;

    var body_buf: [64]u8 = undefined;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var worker = testWorker(okHandler, std.testing.allocator, &body_buf, &arena);
    worker.ring = ring;
    defer ring = worker.ring;

    worker.pumpWs(&conn, testWsEcho);

    try std.testing.expect(conn.closing);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x88, 0 }, send_buf[0..conn.staged]);
}

test "zix http1: uring, pumpWs keeps a partial frame and stages nothing" {
    if (comptime builtin.target.os.tag != .linux) {
        std.log.info("URING is Linux-only, test skipped", .{});

        return;
    }

    var ring = testRing() orelse return;
    defer ring.deinit();

    const fds = try testPair();
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    var conn_buf: [64]u8 = undefined;
    @memcpy(conn_buf[0..4], WS_MASKED_HELLO[0..4]);

    var send_buf: [64]u8 = undefined;
    var conn = testConn(fds[1], &conn_buf, &send_buf);
    conn.filled = 4;

    var body_buf: [64]u8 = undefined;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var worker = testWorker(okHandler, std.testing.allocator, &body_buf, &arena);
    worker.ring = ring;
    defer ring = worker.ring;

    worker.pumpWs(&conn, testWsEcho);

    try std.testing.expectEqual(@as(usize, 4), conn.filled);
    try std.testing.expectEqual(@as(usize, 0), conn.staged);
    try std.testing.expect(!conn.closing);
}

test "zix http1: uring, WebSocket hangup sends no HTTP answer" {
    if (comptime builtin.target.os.tag != .linux) {
        std.log.info("URING is Linux-only, test skipped", .{});

        return;
    }

    var ring = testRing() orelse return;
    defer ring.deinit();

    const fds = try testPair();
    defer _ = std.posix.system.close(fds[0]);

    var body_buf: [64]u8 = undefined;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var worker = testWorker(okHandler, std.testing.allocator, &body_buf, &arena);
    worker.ring = ring;
    defer ring = worker.ring;

    const slots = try std.testing.allocator.alloc(?*Conn, @as(usize, @intCast(fds[1])) + 1);
    defer std.testing.allocator.free(slots);
    @memset(slots, null);
    worker.slots = slots;

    const conn = connAlloc(std.testing.allocator, fds[1], 64).?;
    conn.ws = testWsEcho;
    conn.filled = 3;
    slots[@intCast(fds[1])] = conn;

    var cqe = std.mem.zeroes(linux.io_uring_cqe);
    cqe.res = 0;
    worker.handleRecv(cqe, .{
        .op = .recv,
        .gen = conn.gen,
        .fd = fds[1],
    });
    try waitOnce(&worker.ring);

    var out: [64]u8 = undefined;
    const response = testReadAvailable(fds[0], &out);

    try std.testing.expectEqual(@as(usize, 0), response.len);
    try std.testing.expect(slots[@intCast(fds[1])] == null);
}

test "zix http1: uring, WebSocket recv echoes from the buffer ring" {
    if (comptime builtin.target.os.tag != .linux) {
        std.log.info("URING is Linux-only, test skipped", .{});

        return;
    }

    const fds = try testPair();
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    var body_buf: [64]u8 = undefined;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var setup = (try TestWsRing.init(fds[1], &body_buf, &arena)) orelse return;
    defer setup.deinit();
    if (!setup.initBufs()) return;

    setup.worker.armRecv(setup.conn);
    try testWriteAll(fds[0], &WS_MASKED_HELLO);

    const cqe = try testOneCqe(&setup.worker.ring);

    try std.testing.expect((cqe.flags & linux.IORING_CQE_F_BUFFER) != 0);

    setup.worker.handleRecv(cqe, unpackUserData(cqe.user_data));
    _ = try testOneCqe(&setup.worker.ring);

    var out: [16]u8 = undefined;
    const response = testReadAvailable(fds[0], &out);

    try std.testing.expectEqualStrings(&([_]u8{ 0x81, 5 } ++ "Hello".*), response);
    try std.testing.expectEqual(@as(usize, 0), setup.conn.filled);
}

test "zix http1: uring, buffer ring keeps a trailing partial frame" {
    if (comptime builtin.target.os.tag != .linux) {
        std.log.info("URING is Linux-only, test skipped", .{});

        return;
    }

    const fds = try testPair();
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    var body_buf: [64]u8 = undefined;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var setup = (try TestWsRing.init(fds[1], &body_buf, &arena)) orelse return;
    defer setup.deinit();
    if (!setup.initBufs()) return;

    setup.worker.armRecv(setup.conn);
    try testWriteAll(fds[0], &(WS_MASKED_HELLO ++ WS_MASKED_HELLO[0..4].*));

    const cqe = try testOneCqe(&setup.worker.ring);
    setup.worker.handleRecv(cqe, unpackUserData(cqe.user_data));

    try std.testing.expectEqual(@as(usize, 4), setup.conn.filled);
    try std.testing.expectEqualSlices(u8, WS_MASKED_HELLO[0..4], setup.conn.buf[0..4]);
}

test "zix http1: uring, buffer ring joins a carried partial frame" {
    if (comptime builtin.target.os.tag != .linux) {
        std.log.info("URING is Linux-only, test skipped", .{});

        return;
    }

    const fds = try testPair();
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    var body_buf: [64]u8 = undefined;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var setup = (try TestWsRing.init(fds[1], &body_buf, &arena)) orelse return;
    defer setup.deinit();
    if (!setup.initBufs()) return;

    @memcpy(setup.conn.buf[0..4], WS_MASKED_HELLO[0..4]);
    setup.conn.filled = 4;

    setup.worker.armRecv(setup.conn);
    try testWriteAll(fds[0], WS_MASKED_HELLO[4..]);

    const cqe = try testOneCqe(&setup.worker.ring);
    setup.worker.handleRecv(cqe, unpackUserData(cqe.user_data));
    _ = try testOneCqe(&setup.worker.ring);

    var out: [16]u8 = undefined;
    const response = testReadAvailable(fds[0], &out);

    try std.testing.expectEqualStrings(&([_]u8{ 0x81, 5 } ++ "Hello".*), response);
    try std.testing.expectEqual(@as(usize, 0), setup.conn.filled);
}

test "zix http1: uring, buffer ring ENOBUFS re-arms instead of closing" {
    if (comptime builtin.target.os.tag != .linux) {
        std.log.info("URING is Linux-only, test skipped", .{});

        return;
    }

    const fds = try testPair();
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    var body_buf: [64]u8 = undefined;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var setup = (try TestWsRing.init(fds[1], &body_buf, &arena)) orelse return;
    defer setup.deinit();
    if (!setup.initBufs()) return;

    var cqe = std.mem.zeroes(linux.io_uring_cqe);
    cqe.res = -@as(i32, @intFromEnum(linux.E.NOBUFS));
    setup.worker.handleRecv(cqe, .{
        .op = .recv,
        .gen = setup.conn.gen,
        .fd = fds[1],
    });

    try std.testing.expect(!setup.conn.closing);
    try std.testing.expect(setup.slots[@intCast(fds[1])] != null);
}

test "zix http1: uring, upgrade resizes buf to ws_recv_buf" {
    if (comptime builtin.target.os.tag != .linux) {
        std.log.info("URING is Linux-only, test skipped", .{});

        return;
    }

    const fds = try testPair();
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    const conn = connAlloc(std.testing.allocator, fds[1], TEST_CONN_BUF).?;
    defer connFree(std.testing.allocator, conn);

    @memcpy(conn.buf[0..WS_UPGRADE_REQUEST.len], WS_UPGRADE_REQUEST);
    conn.filled = WS_UPGRADE_REQUEST.len;

    var body_buf: [64]u8 = undefined;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var worker = testWorker(wsHandler, std.testing.allocator, &body_buf, &arena);
    worker.ws_recv_buf_size = 64;
    const outcome = worker.dispatch(conn);

    try std.testing.expectEqual(ConnOutcome.keep_alive, outcome);
    try std.testing.expectEqual(@as(usize, 64), conn.buf.len);
}

test "zix http1: uring, upgrade closes when buffered frames pass ws_recv_buf" {
    if (comptime builtin.target.os.tag != .linux) {
        std.log.info("URING is Linux-only, test skipped", .{});

        return;
    }

    const fds = try testPair();
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    const conn = connAlloc(std.testing.allocator, fds[1], TEST_CONN_BUF).?;
    defer connFree(std.testing.allocator, conn);

    const bytes = WS_UPGRADE_REQUEST ++ WS_MASKED_HELLO;
    @memcpy(conn.buf[0..bytes.len], bytes);
    conn.filled = bytes.len;

    var body_buf: [64]u8 = undefined;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var worker = testWorker(wsHandler, std.testing.allocator, &body_buf, &arena);
    worker.ws_recv_buf_size = 4;

    try std.testing.expectEqual(ConnOutcome.close, worker.dispatch(conn));
}

test "zix http1: uring, resizeForWs keeps the received bytes" {
    const conn = connAlloc(std.testing.allocator, -1, 32).?;
    defer connFree(std.testing.allocator, conn);

    @memcpy(conn.buf[0..3], "abc");
    conn.filled = 3;

    try std.testing.expect(resizeForWs(std.testing.allocator, conn, 8));
    try std.testing.expectEqual(@as(usize, 8), conn.buf.len);
    try std.testing.expectEqualStrings("abc", conn.buf[0..3]);
}

test "zix http1: uring, resizeForWs refuses bytes past the new size" {
    const conn = connAlloc(std.testing.allocator, -1, 32).?;
    defer connFree(std.testing.allocator, conn);

    conn.filled = 9;

    try std.testing.expect(!resizeForWs(std.testing.allocator, conn, 8));
    try std.testing.expectEqual(@as(usize, 32), conn.buf.len);
}

