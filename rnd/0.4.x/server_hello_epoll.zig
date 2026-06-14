//! PoC: hello server, EPOLL model, zero zix dependencies (std only).
//!
//! What:
//!   Proving ground for the parseHead fix. Same public spec as zix.Http1
//!   (comptime Router, HandlerFn(head, body, fd), fdWriteAll) but with the
//!   lazy head design under test:
//!   - ParsedHead.headers[MAX_HEADERS] array + header_count replaced by a
//!     raw_headers slice (zero copy, nothing tokenized up front).
//!   - The framing scan only tokenizes lines whose first letter can begin
//!     content-length, connection, transfer-encoding, or expect (c/t/e).
//!     Everything else (host, user-agent, accept, ...) skips in two compares.
//!   - getHeader scans raw_headers on demand, paid only by handlers that ask.
//!
//! Why:
//!   perf 2026-06-11 (gcannon t4 c128 p16): engine parseHead is ~36% of
//!   userspace cycles (~257 cyc/req), more than a hand-rolled server's whole
//!   budget. This PoC measures how much of that the lazy design recovers,
//!   A/B against http_server_hello_uring.zig (identical parse/router code,
//!   only the dispatch model differs).
//!
//! Routes (byte-identical to the zix-compare-epoll_and_uring servers, :9100):
//!   GET /       -> 200 text/plain        "Hello, World!"
//!   GET /echo   -> 200 application/json   {"status":"ok"}
//!   GET /about  -> 200 text/plain         "zix http1 basic server example"
//!   *           -> 404
//!
//! Architecture: shared-nothing, one worker per CPU core. Each worker owns a
//! private SO_REUSEPORT listener, epoll instance, and ConnTable. Pipelined
//! requests are parsed in one pass and their responses coalesce into a single
//! write per readable event.
//!
//! Out of scope (PoC): chunked request bodies (connection closes),
//! expect-continue, oversize body drain, handler timeout, WebSocket.
//!
//! Build:
//!   zig build-exe rnd/0.4.x/http_server_hello_epoll.zig -OReleaseFast
//!
//! Status:
//! Accepted. Already implemented.

const std = @import("std");
const linux = std.os.linux;

// --------------------------------------------------------- //

const PORT: u16 = 9100;
const KERNEL_BACKLOG: u31 = 1024;

/// Highest fd a worker's table can index. Linux hands out the lowest free fd,
/// so the table stays sparse. Connections on fds at or above this are refused.
const MAX_FD: usize = 65536;

/// Per-connection request accumulation buffer (mirrors max_recv_buf).
const CONN_BUF: usize = 16 * 1024;

/// Per-worker staged-response buffer, flushed once per readable event.
const OUT_BUF: usize = 16 * 1024;

/// Max epoll events drained per epoll_wait call.
const EPOLL_MAX_EVENTS: usize = 512;

// --------------------------------------------------------- //
// Lazy head: the parseHead fix under test.
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
// Response sink: one coalesced write per readable event.
// --------------------------------------------------------- //

const RespSink = struct {
    fd: linux.fd_t,
    buf: []u8,
    len: usize = 0,
    failed: bool = false,

    fn append(self: *RespSink, bytes: []const u8) void {
        if (self.len + bytes.len > self.buf.len) {
            self.flush();
            if (self.failed) return;

            if (bytes.len > self.buf.len) {
                fdWriteAllDirect(self.fd, bytes) catch {
                    self.failed = true;
                };
                return;
            }
        }

        @memcpy(self.buf[self.len..][0..bytes.len], bytes);
        self.len += bytes.len;
    }

    fn flush(self: *RespSink) void {
        if (self.len == 0) return;

        fdWriteAllDirect(self.fd, self.buf[0..self.len]) catch {
            self.failed = true;
        };
        self.len = 0;
    }
};

threadlocal var tl_resp_sink: ?*RespSink = null;

/// Write response bytes for fd. Inside a dispatch pass this stages into the
/// per-event sink, so pipelined responses coalesce into one write.
pub fn fdWriteAll(fd: linux.fd_t, data: []const u8) error{BrokenPipe}!void {
    if (tl_resp_sink) |sink| {
        if (sink.fd == fd) {
            sink.append(data);
            if (sink.failed) return error.BrokenPipe;

            return;
        }
    }

    return fdWriteAllDirect(fd, data);
}

fn fdWriteAllDirect(fd: linux.fd_t, data: []const u8) error{BrokenPipe}!void {
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
            // Known PoC simplification, same as the engine today: a full send
            // buffer parks this worker until the peer drains it.
            .AGAIN => {
                var poll_fds = [_]linux.pollfd{.{ .fd = fd, .events = linux.POLL.OUT, .revents = 0 }};
                _ = linux.poll(&poll_fds, 1, -1);
            },
            else => return error.BrokenPipe,
        }
    }
}

// --------------------------------------------------------- //
// Comptime router: EXACT matching, same dispatch shape as zix.Http1.Router.
// PREFIX and PARAM are out of PoC scope.
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
// EPOLL engine: shared-nothing, one listener + epoll per worker.
// --------------------------------------------------------- //

/// Per-connection read state. buf accumulates bytes until one or more whole
/// requests are present. filled is the live byte count held in buf.
const Conn = struct {
    fd: linux.fd_t,
    buf: []u8,
    filled: usize,
};

/// Private per-worker fd to Conn map. A connection fd is accepted and served
/// by a single worker and freed before its fd can be reused.
const ConnTable = struct {
    slots: []?*Conn,

    const allocator = std.heap.smp_allocator;

    fn init() !ConnTable {
        const slots = try allocator.alloc(?*Conn, MAX_FD);
        @memset(slots, null);

        return .{ .slots = slots };
    }

    fn deinit(self: *ConnTable) void {
        for (self.slots) |maybe_conn| {
            if (maybe_conn) |conn| {
                allocator.free(conn.buf);
                allocator.destroy(conn);
            }
        }

        allocator.free(self.slots);
    }

    fn get(self: *ConnTable, fd: linux.fd_t) ?*Conn {
        const idx: usize = @intCast(fd);
        if (idx >= self.slots.len) return null;

        return self.slots[idx];
    }

    fn alloc(self: *ConnTable, fd: linux.fd_t) ?*Conn {
        const idx: usize = @intCast(fd);
        if (idx >= self.slots.len) return null;

        const conn = allocator.create(Conn) catch return null;
        const buf = allocator.alloc(u8, CONN_BUF) catch {
            allocator.destroy(conn);
            return null;
        };

        conn.* = .{ .fd = fd, .buf = buf, .filled = 0 };
        self.slots[idx] = conn;

        return conn;
    }

    fn free(self: *ConnTable, fd: linux.fd_t) void {
        const idx: usize = @intCast(fd);
        if (idx >= self.slots.len) return;

        if (self.slots[idx]) |conn| {
            allocator.free(conn.buf);
            allocator.destroy(conn);
            self.slots[idx] = null;
        }
    }
};

const ConnOutcome = enum { keep_alive, close };

/// Drain readable bytes, then dispatch every complete request held in
/// conn.buf. Pipelined requests are all served in this one pass and their
/// responses leave in one coalesced write. Trailing partial bytes are
/// compacted for the next readable event.
fn serveConnEvent(conn: *Conn, out_buf: []u8) ConnOutcome {
    while (true) {
        if (conn.filled >= conn.buf.len) return .close;

        const read_rc = linux.read(conn.fd, conn.buf.ptr + conn.filled, conn.buf.len - conn.filled);
        switch (std.posix.errno(read_rc)) {
            .SUCCESS => {},
            .AGAIN => break,
            .INTR => continue,
            else => return .close,
        }

        const got: usize = @intCast(read_rc);
        if (got == 0) return .close;
        conn.filled += got;
    }

    var sink = RespSink{ .fd = conn.fd, .buf = out_buf };
    tl_resp_sink = &sink;
    const outcome = dispatchBuffered(conn);
    tl_resp_sink = null;

    sink.flush();
    if (sink.failed) return .close;

    return outcome;
}

fn dispatchBuffered(conn: *Conn) ConnOutcome {
    var consumed: usize = 0;
    var outcome: ConnOutcome = .keep_alive;

    while (consumed < conn.filled) {
        const remaining = conn.buf[consumed..conn.filled];

        const parsed = parseHead(remaining) catch |err| switch (err) {
            error.IncompleteHeader => break,
            error.InvalidRequest => return .close,
        };

        if (parsed.head.chunked_request) return .close;

        const total_len = parsed.body_offset + parsed.head.content_length;
        if (total_len > remaining.len) break;

        const body = remaining[parsed.body_offset..total_len];
        Routes.dispatch(&parsed.head, body, conn.fd);

        consumed += total_len;
        if (!parsed.head.keep_alive) {
            outcome = .close;
            break;
        }
    }

    if (consumed > 0 and consumed < conn.filled) {
        std.mem.copyForwards(u8, conn.buf, conn.buf[consumed..conn.filled]);
        conn.filled -= consumed;
    } else if (consumed >= conn.filled) {
        conn.filled = 0;
    }

    return outcome;
}

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
    const socket_rc = linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC | linux.SOCK.NONBLOCK, 0);
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

/// Accept every pending connection and register each in epfd.
/// Level-triggered, so draining to EAGAIN guarantees no accept is missed.
fn acceptAll(table: *ConnTable, epfd: linux.fd_t, listener_fd: linux.fd_t) void {
    while (true) {
        const accept_rc = linux.accept4(listener_fd, null, null, linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC);
        switch (std.posix.errno(accept_rc)) {
            .SUCCESS => {},
            .AGAIN => return,
            .INTR, .CONNABORTED => continue,
            else => return,
        }

        const conn_fd: linux.fd_t = @intCast(accept_rc);
        setNoDelay(conn_fd);
        if (table.alloc(conn_fd) == null) {
            _ = linux.close(conn_fd);
            continue;
        }

        var conn_event = linux.epoll_event{
            .events = linux.EPOLL.IN | linux.EPOLL.RDHUP,
            .data = .{ .fd = conn_fd },
        };
        if (std.posix.errno(linux.epoll_ctl(epfd, linux.EPOLL.CTL_ADD, conn_fd, &conn_event)) != .SUCCESS) {
            table.free(conn_fd);
            _ = linux.close(conn_fd);
        }
    }
}

fn workerEntry() void {
    const listener_fd = createListener() catch return;
    defer _ = linux.close(listener_fd);

    var table = ConnTable.init() catch return;
    defer table.deinit();

    const epfd_rc = linux.epoll_create1(linux.EPOLL.CLOEXEC);
    if (std.posix.errno(epfd_rc) != .SUCCESS) return;
    const epfd: linux.fd_t = @intCast(epfd_rc);
    defer _ = linux.close(epfd);

    var listener_event = linux.epoll_event{
        .events = linux.EPOLL.IN,
        .data = .{ .fd = listener_fd },
    };
    if (std.posix.errno(linux.epoll_ctl(epfd, linux.EPOLL.CTL_ADD, listener_fd, &listener_event)) != .SUCCESS) return;

    var out_buf: [OUT_BUF]u8 = undefined;
    var events: [EPOLL_MAX_EVENTS]linux.epoll_event = undefined;
    while (true) {
        const wait_rc = linux.epoll_wait(epfd, &events, EPOLL_MAX_EVENTS, -1);
        switch (std.posix.errno(wait_rc)) {
            .SUCCESS => {},
            .INTR => continue,
            else => return,
        }

        const event_count: usize = @intCast(wait_rc);
        for (events[0..event_count]) |event| {
            if (event.data.fd == listener_fd) {
                acceptAll(&table, epfd, listener_fd);
                continue;
            }

            const conn = table.get(event.data.fd) orelse continue;

            const outcome = if ((event.events & (linux.EPOLL.HUP | linux.EPOLL.ERR)) != 0)
                ConnOutcome.close
            else
                serveConnEvent(conn, &out_buf);

            if (outcome == .close) {
                _ = linux.epoll_ctl(epfd, linux.EPOLL.CTL_DEL, event.data.fd, null);
                _ = linux.close(event.data.fd);
                table.free(event.data.fd);
            }
        }
    }
}

pub fn main(process: std.process.Init) !void {
    _ = process;

    const cpu_count = std.Thread.getCpuCount() catch 1;
    std.debug.print("http-hello-epoll: listening on 0.0.0.0:{d} (epoll, {d} workers, lazy parseHead)\n", .{ PORT, cpu_count });

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

test "poc: parseHead incomplete and invalid" {
    try std.testing.expectError(error.IncompleteHeader, parseHead("GET / HTTP/1.1\r\nHost: x\r\n"));
    try std.testing.expectError(error.InvalidRequest, parseHead("BOGUS\r\n\r\n"));
}
