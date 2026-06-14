//! PoC: hello server, io_uring model, zero zix dependencies (std only).
//!
//! What:
//!   The io_uring twin of http_server_hello_epoll.zig. The ParsedHead, lazy
//!   parseHead, getHeader, Router, handlers, and response constants are
//!   copied verbatim from the epoll variant, so an A/B between the two
//!   measures only the dispatch model, never the parse path.
//!
//! Why:
//!   Same motivation as the epoll variant (parseHead fix proving ground),
//!   plus the io_uring engine mechanics validated 2026-06-11 in
//!   ../../../zix-compare-epoll_and_uring/zix-uring: per-worker rings,
//!   multishot accept, multishot recv with a provided buffer ring, one
//!   coalesced send per readable completion, at most one send SQE in flight
//!   per connection, generation-tagged user_data against fd reuse, and
//!   deferred close while a send is pending.
//!
//! Routes (byte-identical to the zix-compare-epoll_and_uring servers, :9100):
//!   GET /       -> 200 text/plain        "Hello, World!"
//!   GET /echo   -> 200 application/json   {"status":"ok"}
//!   GET /about  -> 200 text/plain         "zix http1 basic server example"
//!   *           -> 404
//!
//! Out of scope (PoC): chunked request bodies (connection closes),
//! expect-continue, oversize body drain, handler timeout, WebSocket.
//!
//! Build:
//!   zig build-exe rnd/0.4.x/http_server_hello_uring.zig -OReleaseFast
//!
//! Status:
//! Postpone.

const std = @import("std");
const linux = std.os.linux;
const IoUring = linux.IoUring;

// --------------------------------------------------------- //

const PORT: u16 = 9101;
const KERNEL_BACKLOG: u31 = 1024;

/// Highest fd a worker's table can index. Linux hands out the lowest free fd,
/// so the table stays sparse. Connections on fds at or above this are refused.
const MAX_FD: usize = 65536;

/// Per-connection request accumulation buffer (mirrors max_recv_buf).
const CONN_BUF: usize = 16 * 1024;

/// Per-connection staged-response buffer. The kernel owns the sent prefix
/// while a send SQE is in flight, so this cannot flush mid-pass the way the
/// epoll sink can: a dispatch pass that stages more than this closes the
/// connection (~170 hello responses, far above any sane pipeline depth).
const SEND_BUF: usize = 16 * 1024;

/// SQ entries per worker ring.
const RING_ENTRIES: u16 = 4096;

/// Provided buffer ring: count x size shared by all connections of a worker.
const BUF_COUNT: u16 = 256;
const BUF_SIZE: u32 = 16384;

/// Max CQEs drained per loop pass.
const CQE_BATCH: usize = 512;

// --------------------------------------------------------- //
// Lazy head: the parseHead fix under test.
// Copied verbatim from http_server_hello_epoll.zig, keep in sync.
// --------------------------------------------------------- //

/// Parsed request head. Same field spec as zix.Http1.ParsedHead except the
/// eager headers array: raw_headers keeps the unparsed header block and
/// getHeader tokenizes on demand.
pub const ParsedHead = struct {
    method: []const u8,
    path: []const u8,
    query: []const u8,
    /// Raw header block, from the byte after the request line CRLF up to and
    /// including the final header CRLF. Empty when the request has no headers.
    raw_headers: []const u8,
    version_minor: u8,
    keep_alive: bool,
    content_length: u64,
    chunked_request: bool,
    expect_continue: bool,
};

/// Handler signature. All slices are valid only for the duration of the call.
pub const HandlerFn = *const fn (
    head: *const ParsedHead,
    body: []const u8,
    fd: linux.fd_t,
) void;

const ParseResult = struct { head: ParsedHead, body_offset: usize };

/// Parse a complete HTTP/1.x request head from buf.
/// buf must contain the full header block ending with \r\n\r\n.
/// All slices in ParsedHead point into buf (zero copy).
///
/// Note:
/// - Framing pass: a header line is tokenized only when its first letter is
///   c, t, or e (the only letters that can start a framing-relevant header).
///   All other lines cost one indexOfPos plus one masked compare.
///
/// Return:
/// - !ParseResult
/// - error.IncompleteHeader when \r\n\r\n has not arrived yet
/// - error.InvalidRequest on a malformed request line
pub fn parseHead(buf: []const u8) !ParseResult {
    const header_end = std.mem.indexOf(u8, buf, "\r\n\r\n") orelse return error.IncompleteHeader;
    const body_offset = header_end + 4;

    const first_crlf = std.mem.indexOf(u8, buf[0..header_end], "\r\n") orelse header_end;
    const req_line = buf[0..first_crlf];

    const sp1 = std.mem.indexOfScalar(u8, req_line, ' ') orelse return error.InvalidRequest;
    if (sp1 == 0) return error.InvalidRequest;
    const method = req_line[0..sp1];

    const rest = req_line[sp1 + 1 ..];
    const sp2 = std.mem.lastIndexOfScalar(u8, rest, ' ') orelse return error.InvalidRequest;
    const target = rest[0..sp2];
    const version_str = rest[sp2 + 1 ..];

    const version_minor: u8 = if (std.mem.eql(u8, version_str, "HTTP/1.1"))
        1
    else if (std.mem.eql(u8, version_str, "HTTP/1.0"))
        0
    else
        return error.InvalidRequest;

    var path = target;
    var query: []const u8 = "";
    if (std.mem.indexOfScalar(u8, target, '?')) |question_mark| {
        path = target[0..question_mark];
        query = target[question_mark + 1 ..];
    }

    const raw_headers = if (first_crlf >= header_end)
        buf[0..0]
    else
        buf[first_crlf + 2 .. header_end + 2];

    var keep_alive = (version_minor == 1);
    var content_length: u64 = 0;
    var chunked_request = false;
    var expect_continue = false;

    var pos: usize = 0;
    while (pos < raw_headers.len) {
        const line_end = std.mem.indexOfPos(u8, raw_headers, pos, "\r\n") orelse raw_headers.len;
        const line = raw_headers[pos..line_end];
        pos = line_end + 2;
        if (line.len == 0) break;

        const first_lower = line[0] | 0x20;
        if (first_lower != 'c' and first_lower != 't' and first_lower != 'e') continue;

        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = line[0..colon];
        var value_off: usize = colon + 1;
        while (value_off < line.len and line[value_off] == ' ') value_off += 1;
        const value = line[value_off..];

        if (std.ascii.eqlIgnoreCase(name, "content-length")) {
            content_length = std.fmt.parseInt(u64, value, 10) catch 0;
        } else if (std.ascii.eqlIgnoreCase(name, "connection")) {
            if (std.ascii.eqlIgnoreCase(value, "close")) keep_alive = false;
            if (std.ascii.eqlIgnoreCase(value, "keep-alive")) keep_alive = true;
        } else if (std.ascii.eqlIgnoreCase(name, "transfer-encoding")) {
            if (std.ascii.indexOfIgnoreCase(value, "chunked") != null) chunked_request = true;
        } else if (std.ascii.eqlIgnoreCase(name, "expect")) {
            if (std.ascii.eqlIgnoreCase(value, "100-continue")) expect_continue = true;
        }
    }

    return .{ .head = .{
        .method = method,
        .path = path,
        .query = query,
        .raw_headers = raw_headers,
        .version_minor = version_minor,
        .keep_alive = keep_alive,
        .content_length = content_length,
        .chunked_request = chunked_request,
        .expect_continue = expect_continue,
    }, .body_offset = body_offset };
}

/// Case-insensitive header lookup, scanning raw_headers on demand.
/// Cost is paid only by handlers that actually read a header.
pub fn getHeader(head: *const ParsedHead, name: []const u8) ?[]const u8 {
    var pos: usize = 0;
    while (pos < head.raw_headers.len) {
        const line_end = std.mem.indexOfPos(u8, head.raw_headers, pos, "\r\n") orelse head.raw_headers.len;
        const line = head.raw_headers[pos..line_end];
        pos = line_end + 2;
        if (line.len == 0) break;

        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (!std.ascii.eqlIgnoreCase(line[0..colon], name)) continue;

        var value_off: usize = colon + 1;
        while (value_off < line.len and line[value_off] == ' ') value_off += 1;

        return line[value_off..];
    }

    return null;
}

// --------------------------------------------------------- //
// Response sink: stages into the connection's send buffer. The event loop
// submits one coalesced send SQE per readable completion.
// --------------------------------------------------------- //

const RespSink = struct {
    fd: linux.fd_t,
    conn: *Conn,
    failed: bool = false,

    fn append(self: *RespSink, bytes: []const u8) void {
        const conn = self.conn;
        if (conn.staged + bytes.len > conn.send_buf.len) {
            self.failed = true;
            return;
        }

        @memcpy(conn.send_buf[conn.staged..][0..bytes.len], bytes);
        conn.staged += bytes.len;
    }
};

threadlocal var tl_resp_sink: ?*RespSink = null;

/// Write response bytes for fd. Inside a dispatch pass this stages into the
/// connection's send buffer, carried out by the loop's send SQE. Outside a
/// pass it is a plain blocking write (never taken on this server's hot path).
pub fn fdWriteAll(fd: linux.fd_t, data: []const u8) error{BrokenPipe}!void {
    if (tl_resp_sink) |sink| {
        if (sink.fd == fd) {
            sink.append(data);
            if (sink.failed) return error.BrokenPipe;

            return;
        }
    }

    var remaining = data;
    while (remaining.len > 0) {
        const write_rc = linux.write(fd, remaining.ptr, remaining.len);
        switch (std.posix.errno(write_rc)) {
            .SUCCESS => {
                const written: usize = @intCast(write_rc);
                if (written == 0) return error.BrokenPipe;
                remaining = remaining[written..];
            },
            .INTR => continue,
            else => return error.BrokenPipe,
        }
    }
}

// --------------------------------------------------------- //
// Comptime router: EXACT matching, same dispatch shape as zix.Http1.Router.
// Copied verbatim from http_server_hello_epoll.zig, keep in sync.
// --------------------------------------------------------- //

pub const Route = struct {
    path: []const u8,
    handler: HandlerFn,
};

const RESP_404: []const u8 = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n";

/// Build a router type whose dispatch table is fixed at compile time.
/// EXACT routes go into a StaticStringMap for O(1) lookup. Unknown paths
/// get the preformatted 404.
pub fn Router(comptime routes: []const Route) type {
    const exact_pairs: [routes.len]struct { []const u8, HandlerFn } = blk: {
        var pairs: [routes.len]struct { []const u8, HandlerFn } = undefined;
        for (routes, 0..) |route, index| pairs[index] = .{ route.path, route.handler };
        break :blk pairs;
    };

    const exact_map = std.StaticStringMap(HandlerFn).initComptime(exact_pairs);

    return struct {
        pub fn dispatch(head: *const ParsedHead, body: []const u8, fd: linux.fd_t) void {
            if (exact_map.get(head.path)) |handler| {
                handler(head, body, fd);
                return;
            }

            fdWriteAll(fd, RESP_404) catch {};
        }
    };
}

// --------------------------------------------------------- //
// Hello handlers: byte-identical to zix-compare-epoll_and_uring.
// --------------------------------------------------------- //

const RESP_HOME: []const u8 = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 13\r\n\r\nHello, World!";
const RESP_ECHO: []const u8 = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 15\r\n\r\n{\"status\":\"ok\"}";
const RESP_ABOUT: []const u8 = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 30\r\n\r\nzix http1 basic server example";

fn homeHandler(head: *const ParsedHead, body: []const u8, fd: linux.fd_t) void {
    _ = head;
    _ = body;

    fdWriteAll(fd, RESP_HOME) catch {};
}

fn echoHandler(head: *const ParsedHead, body: []const u8, fd: linux.fd_t) void {
    _ = head;
    _ = body;

    fdWriteAll(fd, RESP_ECHO) catch {};
}

fn aboutHandler(head: *const ParsedHead, body: []const u8, fd: linux.fd_t) void {
    _ = head;
    _ = body;

    fdWriteAll(fd, RESP_ABOUT) catch {};
}

const Routes = Router(&[_]Route{
    .{ .path = "/", .handler = homeHandler },
    .{ .path = "/echo", .handler = echoHandler },
    .{ .path = "/about", .handler = aboutHandler },
});

// --------------------------------------------------------- //
// io_uring engine: shared-nothing, one ring + listener per worker.
// --------------------------------------------------------- //

/// CQE routing tag carried in user_data.
const OpKind = enum(u8) { accept, recv, send };

/// user_data layout: op in the top byte, generation in the middle, fd in the
/// low 32 bits. The generation guards against fd reuse: a connection can close
/// and its fd be re-accepted while stale CQEs for the old connection are still
/// in the completion queue, and those must not touch the new connection.
fn packUserData(op: OpKind, gen: u24, fd: linux.fd_t) u64 {
    const fd_bits: u32 = @bitCast(fd);

    return (@as(u64, @intFromEnum(op)) << 56) | (@as(u64, gen) << 32) | fd_bits;
}

const Decoded = struct { op: OpKind, gen: u24, fd: linux.fd_t };

fn unpackUserData(user_data: u64) Decoded {
    return .{
        .op = @enumFromInt(@as(u8, @intCast(user_data >> 56))),
        .gen = @intCast((user_data >> 32) & 0xff_ff_ff),
        .fd = @bitCast(@as(u32, @intCast(user_data & 0xff_ff_ff_ff))),
    };
}

/// Per-connection state. req holds partial request bytes between readable
/// completions. send_buf front [0..inflight] is owned by the kernel while a
/// send SQE is outstanding, [inflight..staged] is appended and waiting.
/// closing marks a connection that must be freed once the last send lands.
const Conn = struct {
    fd: linux.fd_t,
    gen: u24,
    req: []u8,
    filled: usize,
    send_buf: []u8,
    staged: usize,
    inflight: usize,
    closing: bool,
};

const ConnOutcome = enum { keep_alive, close };

const Worker = struct {
    ring: IoUring,
    buffers: IoUring.BufferGroup,
    slots: []?*Conn,
    listener_fd: linux.fd_t,
    gen_counter: u24,

    const allocator = std.heap.smp_allocator;

    /// ring and buffers stay undefined here: BufferGroup captures a pointer
    /// to the ring, so both are initialized by the caller after the Worker
    /// has its final address.
    fn init(listener_fd: linux.fd_t) !Worker {
        const slots = try allocator.alloc(?*Conn, MAX_FD);
        @memset(slots, null);

        return .{
            .ring = undefined,
            .buffers = undefined,
            .slots = slots,
            .listener_fd = listener_fd,
            .gen_counter = 0,
        };
    }

    fn deinit(self: *Worker) void {
        for (self.slots) |maybe_conn| {
            if (maybe_conn) |conn| self.destroyConn(conn);
        }

        allocator.free(self.slots);
        self.buffers.deinit(allocator);
        self.ring.deinit();
    }

    /// Get an SQE, submitting the staged batch first when the SQ is full.
    fn getSqe(self: *Worker) ?*linux.io_uring_sqe {
        return self.ring.get_sqe() catch {
            _ = self.ring.submit() catch return null;

            return self.ring.get_sqe() catch null;
        };
    }

    fn armAccept(self: *Worker) void {
        const sqe = self.getSqe() orelse return;
        sqe.prep_multishot_accept(self.listener_fd, null, null, 0);
        sqe.user_data = packUserData(.accept, 0, self.listener_fd);
    }

    fn armRecv(self: *Worker, conn: *Conn) void {
        _ = self.buffers.recv_multishot(packUserData(.recv, conn.gen, conn.fd), conn.fd, 0) catch {
            _ = self.ring.submit() catch {};
            _ = self.buffers.recv_multishot(packUserData(.recv, conn.gen, conn.fd), conn.fd, 0) catch {};
        };
    }

    fn submitSend(self: *Worker, conn: *Conn) void {
        const sqe = self.getSqe() orelse {
            self.finishClose(conn);
            return;
        };
        sqe.prep_send(conn.fd, conn.send_buf[0..conn.staged], linux.MSG.NOSIGNAL);
        sqe.user_data = packUserData(.send, conn.gen, conn.fd);

        conn.inflight = conn.staged;
    }

    // ----------------------------------------------------- //

    fn lookup(self: *Worker, decoded: Decoded) ?*Conn {
        const idx: usize = @intCast(decoded.fd);
        if (idx >= self.slots.len) return null;

        const conn = self.slots[idx] orelse return null;
        if (conn.gen != decoded.gen) return null;

        return conn;
    }

    fn destroyConn(self: *Worker, conn: *Conn) void {
        self.slots[@intCast(conn.fd)] = null;

        allocator.free(conn.req);
        allocator.free(conn.send_buf);
        allocator.destroy(conn);
    }

    /// Close intent: flush staged bytes first when possible, otherwise free
    /// now. With a send in flight the free is deferred to the send CQE.
    fn beginClose(self: *Worker, conn: *Conn) void {
        conn.closing = true;
        if (conn.inflight > 0) return;

        if (conn.staged > 0) {
            self.submitSend(conn);
            return;
        }

        self.finishClose(conn);
    }

    fn finishClose(self: *Worker, conn: *Conn) void {
        _ = linux.close(conn.fd);
        self.destroyConn(conn);
    }

    // ----------------------------------------------------- //

    fn handleAccept(self: *Worker, cqe: linux.io_uring_cqe) void {
        const rearm = (cqe.flags & linux.IORING_CQE_F_MORE) == 0;
        defer if (rearm) self.armAccept();

        if (cqe.res < 0) return;

        const conn_fd: linux.fd_t = cqe.res;
        const idx: usize = @intCast(conn_fd);
        if (idx >= self.slots.len) {
            _ = linux.close(conn_fd);
            return;
        }

        setNoDelay(conn_fd);

        const conn = allocator.create(Conn) catch {
            _ = linux.close(conn_fd);
            return;
        };
        const req = allocator.alloc(u8, CONN_BUF) catch {
            allocator.destroy(conn);
            _ = linux.close(conn_fd);
            return;
        };
        const send_buf = allocator.alloc(u8, SEND_BUF) catch {
            allocator.free(req);
            allocator.destroy(conn);
            _ = linux.close(conn_fd);
            return;
        };

        self.gen_counter +%= 1;
        conn.* = .{
            .fd = conn_fd,
            .gen = self.gen_counter,
            .req = req,
            .filled = 0,
            .send_buf = send_buf,
            .staged = 0,
            .inflight = 0,
            .closing = false,
        };
        self.slots[idx] = conn;

        self.armRecv(conn);
    }

    fn handleRecv(self: *Worker, cqe: linux.io_uring_cqe, decoded: Decoded) void {
        const conn = self.lookup(decoded) orelse {
            // Stale CQE for a freed connection: the selected buffer must
            // still go back to the kernel or the ring leaks it.
            if ((cqe.flags & linux.IORING_CQE_F_BUFFER) != 0) self.buffers.put(cqe) catch {};
            return;
        };

        if (cqe.res < 0) {
            const errno: linux.E = @enumFromInt(@as(u32, @intCast(-cqe.res)));
            if (errno == .NOBUFS) {
                // Buffer ring exhausted mid-burst. Buffers freed by put()
                // during this batch make the re-arm succeed.
                self.armRecv(conn);
                return;
            }

            self.beginClose(conn);
            return;
        }

        if (cqe.res == 0) {
            self.beginClose(conn);
            return;
        }

        const data = self.buffers.get(cqe) catch {
            self.beginClose(conn);
            return;
        };

        if (conn.filled + data.len > conn.req.len) {
            self.buffers.put(cqe) catch {};
            self.beginClose(conn);
            return;
        }

        @memcpy(conn.req[conn.filled..][0..data.len], data);
        conn.filled += data.len;
        self.buffers.put(cqe) catch {};

        const outcome = self.dispatchBuffered(conn);

        if (conn.inflight == 0 and conn.staged > 0) self.submitSend(conn);

        if (outcome == .close) {
            self.beginClose(conn);
            return;
        }

        if ((cqe.flags & linux.IORING_CQE_F_MORE) == 0) self.armRecv(conn);
    }

    /// Parse every complete request in conn.req and dispatch it through the
    /// comptime router. Responses stage into conn.send_buf via the sink and
    /// leave as one coalesced send SQE. Trailing partial bytes are compacted
    /// to the front for the next readable completion.
    fn dispatchBuffered(self: *Worker, conn: *Conn) ConnOutcome {
        _ = self;

        var sink = RespSink{ .fd = conn.fd, .conn = conn };
        tl_resp_sink = &sink;
        defer tl_resp_sink = null;

        var consumed: usize = 0;
        var outcome: ConnOutcome = .keep_alive;

        while (consumed < conn.filled) {
            const remaining = conn.req[consumed..conn.filled];

            const parsed = parseHead(remaining) catch |err| switch (err) {
                error.IncompleteHeader => break,
                error.InvalidRequest => return .close,
            };

            if (parsed.head.chunked_request) return .close;

            const total_len = parsed.body_offset + parsed.head.content_length;
            if (total_len > remaining.len) break;

            const body = remaining[parsed.body_offset..total_len];
            Routes.dispatch(&parsed.head, body, conn.fd);
            if (sink.failed) return .close;

            consumed += total_len;
            if (!parsed.head.keep_alive) {
                outcome = .close;
                break;
            }
        }

        if (consumed > 0 and consumed < conn.filled) {
            std.mem.copyForwards(u8, conn.req, conn.req[consumed..conn.filled]);
            conn.filled -= consumed;
        } else if (consumed >= conn.filled) {
            conn.filled = 0;
        }

        return outcome;
    }

    fn handleSend(self: *Worker, cqe: linux.io_uring_cqe, decoded: Decoded) void {
        const conn = self.lookup(decoded) orelse return;

        if (cqe.res < 0) {
            conn.inflight = 0;
            conn.staged = 0;
            self.beginClose(conn);
            return;
        }

        // Drop the sent prefix. A short send, or bytes appended while this
        // send was in flight, leave a remainder that goes out immediately.
        const sent: usize = @intCast(cqe.res);
        std.mem.copyForwards(u8, conn.send_buf, conn.send_buf[sent..conn.staged]);
        conn.staged -= sent;
        conn.inflight = 0;

        if (conn.staged > 0) {
            self.submitSend(conn);
            return;
        }

        if (conn.closing) self.finishClose(conn);
    }

    // ----------------------------------------------------- //

    fn run(self: *Worker) void {
        self.armAccept();

        var cqes: [CQE_BATCH]linux.io_uring_cqe = undefined;
        while (true) {
            _ = self.ring.submit_and_wait(1) catch |err| switch (err) {
                error.SignalInterrupt => continue,
                else => return,
            };

            const count = self.ring.copy_cqes(&cqes, 0) catch return;
            for (cqes[0..count]) |cqe| {
                const decoded = unpackUserData(cqe.user_data);
                switch (decoded.op) {
                    .accept => self.handleAccept(cqe),
                    .recv => self.handleRecv(cqe, decoded),
                    .send => self.handleSend(cqe, decoded),
                }
            }
        }
    }
};

// --------------------------------------------------------- //

fn setNoDelay(fd: linux.fd_t) void {
    std.posix.setsockopt(
        fd,
        std.posix.IPPROTO.TCP,
        std.posix.TCP.NODELAY,
        std.mem.asBytes(&@as(c_int, 1)),
    ) catch {};
}

fn createListener() !linux.fd_t {
    const socket_rc = linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    if (std.posix.errno(socket_rc) != .SUCCESS) return error.SocketFailed;

    const fd: linux.fd_t = @intCast(socket_rc);
    errdefer _ = linux.close(fd);

    try std.posix.setsockopt(fd, linux.SOL.SOCKET, linux.SO.REUSEADDR, std.mem.asBytes(&@as(c_int, 1)));
    try std.posix.setsockopt(fd, linux.SOL.SOCKET, linux.SO.REUSEPORT, std.mem.asBytes(&@as(c_int, 1)));

    const addr = linux.sockaddr.in{
        .family = linux.AF.INET,
        .port = std.mem.nativeToBig(u16, PORT),
        .addr = 0,
    };
    if (std.posix.errno(linux.bind(fd, @ptrCast(&addr), @sizeOf(linux.sockaddr.in))) != .SUCCESS) return error.BindFailed;
    if (std.posix.errno(linux.listen(fd, KERNEL_BACKLOG)) != .SUCCESS) return error.ListenFailed;

    return fd;
}

fn workerEntry() void {
    const listener_fd = createListener() catch return;

    var worker = Worker.init(listener_fd) catch {
        _ = linux.close(listener_fd);
        return;
    };
    worker.ring = IoUring.init(
        RING_ENTRIES,
        linux.IORING_SETUP_SINGLE_ISSUER | linux.IORING_SETUP_COOP_TASKRUN,
    ) catch return;
    worker.buffers = IoUring.BufferGroup.init(
        &worker.ring,
        Worker.allocator,
        0,
        BUF_SIZE,
        BUF_COUNT,
    ) catch return;
    defer worker.deinit();

    worker.run();
}

pub fn main(process: std.process.Init) !void {
    _ = process;

    const cpu_count = std.Thread.getCpuCount() catch 1;
    std.debug.print("http-hello-uring: listening on 0.0.0.0:{d} (io_uring, {d} workers, lazy parseHead)\n", .{ PORT, cpu_count });

    var index: usize = 1;
    while (index < cpu_count) : (index += 1) {
        _ = try std.Thread.spawn(.{}, workerEntry, .{});
    }

    workerEntry();
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //

test "poc: parseHead lazy framing scan" {
    const raw = "GET /echo?a=1 HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\nConnection: close\r\n\r\nhello";
    const parsed = try parseHead(raw);

    try std.testing.expectEqualStrings("GET", parsed.head.method);
    try std.testing.expectEqualStrings("/echo", parsed.head.path);
    try std.testing.expectEqualStrings("a=1", parsed.head.query);
    try std.testing.expectEqual(@as(u64, 5), parsed.head.content_length);
    try std.testing.expect(!parsed.head.keep_alive);
    try std.testing.expectEqual(raw.len - 5, parsed.body_offset);
}

test "poc: getHeader scans raw_headers on demand" {
    const raw = "GET / HTTP/1.1\r\nHost: example.com\r\nUser-Agent: test\r\n\r\n";
    const parsed = try parseHead(raw);

    try std.testing.expectEqualStrings("example.com", getHeader(&parsed.head, "host").?);
    try std.testing.expectEqualStrings("test", getHeader(&parsed.head, "User-Agent").?);
    try std.testing.expect(getHeader(&parsed.head, "missing") == null);
}

test "poc: user_data round trip" {
    const packed_value = packUserData(.send, 0xabcdef, 1234);
    const decoded = unpackUserData(packed_value);

    try std.testing.expectEqual(OpKind.send, decoded.op);
    try std.testing.expectEqual(@as(u24, 0xabcdef), decoded.gen);
    try std.testing.expectEqual(@as(linux.fd_t, 1234), decoded.fd);
}
