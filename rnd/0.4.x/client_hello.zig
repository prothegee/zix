//! PoC: HTTP load generator, zero dependencies (std only).
//!
//! What:
//!   A wrk/gcannon-style closed-loop benchmark client for the hello PoC
//!   servers. Each thread owns an epoll instance and a share of the
//!   connections. Every connection sends a burst of pipeline-depth requests
//!   in one write, reads until all responses of the burst are parsed, then
//!   sends the next burst. Throughput is completed responses per second.
//!
//! Why:
//!   Removes the external-tool dependency from the parseHead fix A/B
//!   (../../../zix-bench-*.sh need wrk or gcannon). Validated against both
//!   on the same servers before trusting its numbers.
//!
//! Usage:
//!   http_client_hello http://127.0.0.1:9100/ [-c conns] [-t threads] [-d seconds] [-p pipeline]
//!
//!   defaults: -c 64, -t 4, -d 10, -p 1
//!   host must be a dotted IPv4 address or localhost (no DNS, zero deps).
//!
//! Note:
//! - Closed loop: a new burst is only sent after the previous burst fully
//!   completed, like wrk pipeline scripts and gcannon -p. No latency stats.
//! - A connection that errors or is closed by the server is reconnected
//!   immediately and counted under conn errors.
//!
//! Build:
//!   zig build-exe rnd/0.4.x/http_client_hello.zig -OReleaseFast
//!
//! Status:
//! Reject. Not worth the time, already exists h2load, wrk, gcanon, etc.

const std = @import("std");
const linux = std.os.linux;

// --------------------------------------------------------- //

/// Per-connection response reassembly buffer. Hello responses are ~100B, so
/// this comfortably holds a full pipeline burst of headers plus bodies.
const RECV_BUF: usize = 64 * 1024;

/// Max epoll events drained per epoll_wait call.
const EPOLL_MAX_EVENTS: usize = 256;

/// Hard cap on pipeline depth, keeps the burst buffer bounded.
const MAX_PIPELINE: usize = 256;

// --------------------------------------------------------- //

const Options = struct {
    ip: u32,
    port: u16,
    host: []const u8,
    path: []const u8,
    conns: usize = 64,
    threads: usize = 4,
    duration_s: u64 = 10,
    pipeline: usize = 1,
};

/// Parse a dotted IPv4 quad into a network-order u32.
fn parseIp4(text: []const u8) !u32 {
    var octets: [4]u8 = undefined;
    var it = std.mem.splitScalar(u8, text, '.');

    for (&octets) |*octet| {
        const part = it.next() orelse return error.BadIp;
        octet.* = std.fmt.parseInt(u8, part, 10) catch return error.BadIp;
    }
    if (it.next() != null) return error.BadIp;

    return @bitCast(octets);
}

/// Parse http://host:port/path. Host must be dotted IPv4 or localhost.
fn parseUrl(url: []const u8) !struct { ip: u32, port: u16, host: []const u8, path: []const u8 } {
    const scheme = "http://";
    if (!std.mem.startsWith(u8, url, scheme)) return error.BadUrl;

    const rest = url[scheme.len..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
    const authority = rest[0..slash];
    const path = if (slash < rest.len) rest[slash..] else "/";

    var host = authority;
    var port: u16 = 80;
    if (std.mem.indexOfScalar(u8, authority, ':')) |colon| {
        host = authority[0..colon];
        port = std.fmt.parseInt(u16, authority[colon + 1 ..], 10) catch return error.BadUrl;
    }

    const ip = if (std.mem.eql(u8, host, "localhost"))
        try parseIp4("127.0.0.1")
    else
        try parseIp4(host);

    return .{ .ip = ip, .port = port, .host = host, .path = path };
}

fn parseArgs(args: anytype) !Options {
    var it = std.process.Args.Iterator.init(args);
    _ = it.skip();

    var url: ?[]const u8 = null;
    var opts_partial = struct {
        conns: usize = 64,
        threads: usize = 4,
        duration_s: u64 = 10,
        pipeline: usize = 1,
    }{};

    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "-c")) {
            const val = it.next() orelse return error.MissingValue;
            opts_partial.conns = try std.fmt.parseInt(usize, val, 10);
        } else if (std.mem.eql(u8, arg, "-t")) {
            const val = it.next() orelse return error.MissingValue;
            opts_partial.threads = try std.fmt.parseInt(usize, val, 10);
        } else if (std.mem.eql(u8, arg, "-d")) {
            const val = it.next() orelse return error.MissingValue;
            opts_partial.duration_s = try std.fmt.parseInt(u64, val, 10);
        } else if (std.mem.eql(u8, arg, "-p")) {
            const val = it.next() orelse return error.MissingValue;
            opts_partial.pipeline = try std.fmt.parseInt(usize, val, 10);
        } else if (url == null) {
            url = arg;
        } else {
            return error.UnknownArg;
        }
    }

    const parsed_url = try parseUrl(url orelse return error.MissingUrl);

    if (opts_partial.conns == 0 or opts_partial.threads == 0 or opts_partial.pipeline == 0) return error.BadValue;
    if (opts_partial.pipeline > MAX_PIPELINE) return error.BadValue;
    if (opts_partial.threads > opts_partial.conns) opts_partial.threads = opts_partial.conns;

    return .{
        .ip = parsed_url.ip,
        .port = parsed_url.port,
        .host = parsed_url.host,
        .path = parsed_url.path,
        .conns = opts_partial.conns,
        .threads = opts_partial.threads,
        .duration_s = opts_partial.duration_s,
        .pipeline = opts_partial.pipeline,
    };
}

// --------------------------------------------------------- //

fn monotonicNs() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);

    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

/// Per-connection state. burst_sent tracks bytes of the current burst already
/// written (a full socket buffer leaves a remainder finished via EPOLLOUT).
/// awaiting is the count of responses still owed for the current burst.
const Conn = struct {
    fd: linux.fd_t,
    buf: []u8,
    filled: usize,
    burst_sent: usize,
    awaiting: usize,
};

const Counters = struct {
    ok: u64 = 0,
    non_2xx: u64 = 0,
    conn_errors: u64 = 0,
};

const WorkerCtx = struct {
    opts: *const Options,
    burst: []const u8,
    conn_count: usize,
    deadline_ns: u64,
    counters: Counters = .{},
};

// --------------------------------------------------------- //

fn connectBlocking(ip: u32, port: u16) !linux.fd_t {
    const socket_rc = linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    if (std.posix.errno(socket_rc) != .SUCCESS) return error.SocketFailed;

    const fd: linux.fd_t = @intCast(socket_rc);
    errdefer _ = linux.close(fd);

    const addr = linux.sockaddr.in{
        .family = linux.AF.INET,
        .port = std.mem.nativeToBig(u16, port),
        .addr = ip,
    };
    while (true) {
        const connect_rc = linux.connect(fd, @ptrCast(&addr), @sizeOf(linux.sockaddr.in));
        switch (std.posix.errno(connect_rc)) {
            .SUCCESS => break,
            .INTR => continue,
            else => return error.ConnectFailed,
        }
    }

    std.posix.setsockopt(fd, std.posix.IPPROTO.TCP, std.posix.TCP.NODELAY, std.mem.asBytes(&@as(c_int, 1))) catch {};

    const cur_flags = linux.fcntl(fd, std.posix.F.GETFL, 0);
    const nonblock_bit: u32 = @bitCast(std.posix.O{ .NONBLOCK = true });
    _ = linux.fcntl(fd, std.posix.F.SETFL, cur_flags | @as(usize, nonblock_bit));

    return fd;
}

fn epollMod(epfd: linux.fd_t, conn: *Conn, want_out: bool) void {
    const out_bit: u32 = if (want_out) linux.EPOLL.OUT else 0;

    var event = linux.epoll_event{
        .events = linux.EPOLL.IN | linux.EPOLL.RDHUP | out_bit,
        .data = .{ .ptr = @intFromPtr(conn) },
    };
    _ = linux.epoll_ctl(epfd, linux.EPOLL.CTL_MOD, conn.fd, &event);
}

/// Send as much of the current burst as the socket accepts.
///
/// Return:
/// - true when the burst is fully written
/// - false when a remainder waits for EPOLLOUT, or the connection died
fn pumpSend(ctx: *WorkerCtx, conn: *Conn) bool {
    while (conn.burst_sent < ctx.burst.len) {
        const chunk = ctx.burst[conn.burst_sent..];

        const write_rc = linux.write(conn.fd, chunk.ptr, chunk.len);
        switch (std.posix.errno(write_rc)) {
            .SUCCESS => {
                const written: usize = @intCast(write_rc);
                if (written == 0) return false;
                conn.burst_sent += written;
            },
            .INTR => continue,
            .AGAIN => return false,
            else => return false,
        }
    }

    return true;
}

/// Parse complete responses out of conn.buf. Counts status codes and returns
/// the number of whole responses consumed. Partial tail bytes are compacted.
fn consumeResponses(ctx: *WorkerCtx, conn: *Conn) usize {
    var consumed: usize = 0;
    var completed: usize = 0;

    while (consumed < conn.filled) {
        const remaining = conn.buf[consumed..conn.filled];

        const header_end = std.mem.indexOf(u8, remaining, "\r\n\r\n") orelse break;
        const head = remaining[0..header_end];

        var content_length: usize = 0;
        var line_pos: usize = 0;
        while (line_pos < head.len) {
            const line_end = std.mem.indexOfPos(u8, head, line_pos, "\r\n") orelse head.len;
            const line = head[line_pos..line_end];
            line_pos = line_end + 2;

            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            if (!std.ascii.eqlIgnoreCase(line[0..colon], "content-length")) continue;

            var value_off: usize = colon + 1;
            while (value_off < line.len and line[value_off] == ' ') value_off += 1;
            content_length = std.fmt.parseInt(usize, line[value_off..], 10) catch 0;
            break;
        }

        const total_len = header_end + 4 + content_length;
        if (total_len > remaining.len) break;

        // Status line: "HTTP/1.1 NNN ...", code at bytes 9..12.
        if (remaining.len >= 12 and remaining[9] == '2') {
            ctx.counters.ok += 1;
        } else {
            ctx.counters.non_2xx += 1;
        }

        consumed += total_len;
        completed += 1;
    }

    if (consumed > 0 and consumed < conn.filled) {
        std.mem.copyForwards(u8, conn.buf, conn.buf[consumed..conn.filled]);
        conn.filled -= consumed;
    } else if (consumed >= conn.filled) {
        conn.filled = 0;
    }

    return completed;
}

fn startBurst(ctx: *WorkerCtx, epfd: linux.fd_t, conn: *Conn) void {
    conn.burst_sent = 0;
    conn.awaiting = ctx.opts.pipeline;

    const done = pumpSend(ctx, conn);
    epollMod(epfd, conn, !done);
}

fn reconnect(ctx: *WorkerCtx, epfd: linux.fd_t, conn: *Conn) void {
    ctx.counters.conn_errors += 1;

    _ = linux.epoll_ctl(epfd, linux.EPOLL.CTL_DEL, conn.fd, null);
    _ = linux.close(conn.fd);

    conn.fd = connectBlocking(ctx.opts.ip, ctx.opts.port) catch {
        conn.fd = -1;
        return;
    };
    conn.filled = 0;

    var event = linux.epoll_event{
        .events = linux.EPOLL.IN | linux.EPOLL.RDHUP,
        .data = .{ .ptr = @intFromPtr(conn) },
    };
    _ = linux.epoll_ctl(epfd, linux.EPOLL.CTL_ADD, conn.fd, &event);

    startBurst(ctx, epfd, conn);
}

/// Drain readable bytes and account completed responses. Starts the next
/// burst once the current one is fully answered.
///
/// Return:
/// - true while the connection is healthy
/// - false when it must be reconnected
fn pumpRecv(ctx: *WorkerCtx, epfd: linux.fd_t, conn: *Conn) bool {
    while (true) {
        if (conn.filled >= conn.buf.len) return false;

        const read_rc = linux.read(conn.fd, conn.buf.ptr + conn.filled, conn.buf.len - conn.filled);
        switch (std.posix.errno(read_rc)) {
            .SUCCESS => {},
            .AGAIN => break,
            .INTR => continue,
            else => return false,
        }

        const got: usize = @intCast(read_rc);
        if (got == 0) return false;
        conn.filled += got;
    }

    const completed = consumeResponses(ctx, conn);
    if (completed > conn.awaiting) return false;
    conn.awaiting -= completed;

    if (conn.awaiting == 0) startBurst(ctx, epfd, conn);

    return true;
}

fn workerEntry(ctx: *WorkerCtx) void {
    const allocator = std.heap.smp_allocator;

    const epfd_rc = linux.epoll_create1(linux.EPOLL.CLOEXEC);
    if (std.posix.errno(epfd_rc) != .SUCCESS) return;
    const epfd: linux.fd_t = @intCast(epfd_rc);
    defer _ = linux.close(epfd);

    const conns = allocator.alloc(Conn, ctx.conn_count) catch return;
    defer allocator.free(conns);

    for (conns) |*conn| {
        const fd = connectBlocking(ctx.opts.ip, ctx.opts.port) catch {
            conn.* = .{ .fd = -1, .buf = &.{}, .filled = 0, .burst_sent = 0, .awaiting = 0 };
            ctx.counters.conn_errors += 1;
            continue;
        };
        const buf = allocator.alloc(u8, RECV_BUF) catch return;
        conn.* = .{ .fd = fd, .buf = buf, .filled = 0, .burst_sent = 0, .awaiting = 0 };

        var event = linux.epoll_event{
            .events = linux.EPOLL.IN | linux.EPOLL.RDHUP,
            .data = .{ .ptr = @intFromPtr(conn) },
        };
        _ = linux.epoll_ctl(epfd, linux.EPOLL.CTL_ADD, fd, &event);
    }
    defer for (conns) |*conn| {
        if (conn.fd >= 0) _ = linux.close(conn.fd);
        if (conn.buf.len > 0) allocator.free(conn.buf);
    };

    for (conns) |*conn| {
        if (conn.fd >= 0) startBurst(ctx, epfd, conn);
    }

    var events: [EPOLL_MAX_EVENTS]linux.epoll_event = undefined;
    while (true) {
        const now_ns = monotonicNs();
        if (now_ns >= ctx.deadline_ns) break;

        const remaining_ms: i32 = @intCast(@min((ctx.deadline_ns - now_ns) / std.time.ns_per_ms + 1, 1000));
        const wait_rc = linux.epoll_wait(epfd, &events, EPOLL_MAX_EVENTS, remaining_ms);
        switch (std.posix.errno(wait_rc)) {
            .SUCCESS => {},
            .INTR => continue,
            else => break,
        }

        const event_count: usize = @intCast(wait_rc);
        for (events[0..event_count]) |event| {
            const conn: *Conn = @ptrFromInt(event.data.ptr);
            if (conn.fd < 0) continue;

            if ((event.events & (linux.EPOLL.HUP | linux.EPOLL.ERR | linux.EPOLL.RDHUP)) != 0) {
                reconnect(ctx, epfd, conn);
                continue;
            }

            if ((event.events & linux.EPOLL.OUT) != 0) {
                if (pumpSend(ctx, conn)) epollMod(epfd, conn, false);
            }

            if ((event.events & linux.EPOLL.IN) != 0) {
                if (!pumpRecv(ctx, epfd, conn)) reconnect(ctx, epfd, conn);
            }
        }
    }
}

// --------------------------------------------------------- //

fn formatThroughput(buf: []u8, req_per_s: f64) []const u8 {
    if (req_per_s >= 1_000_000.0)
        return std.fmt.bufPrint(buf, "{d:.2}M", .{req_per_s / 1_000_000.0}) catch "?";
    if (req_per_s >= 1_000.0)
        return std.fmt.bufPrint(buf, "{d:.2}K", .{req_per_s / 1_000.0}) catch "?";

    return std.fmt.bufPrint(buf, "{d:.0}", .{req_per_s}) catch "?";
}

pub fn main(process: std.process.Init) !void {
    const allocator = process.gpa;

    const opts = parseArgs(process.minimal.args) catch {
        std.debug.print(
            "usage: http_client_hello http://<ipv4|localhost>:<port>/<path> [-c conns] [-t threads] [-d seconds] [-p pipeline]\n",
            .{},
        );
        return error.BadArgs;
    };

    var request_buf: [512]u8 = undefined;
    const request = try std.fmt.bufPrint(
        &request_buf,
        "GET {s} HTTP/1.1\r\nHost: {s}\r\n\r\n",
        .{ opts.path, opts.host },
    );

    const burst = try allocator.alloc(u8, request.len * opts.pipeline);
    defer allocator.free(burst);
    for (0..opts.pipeline) |index| {
        @memcpy(burst[index * request.len ..][0..request.len], request);
    }

    std.debug.print(
        "http-hello-client: http://{s}:{d}{s}  conns={d} threads={d} duration={d}s pipeline={d}\n",
        .{ opts.host, opts.port, opts.path, opts.conns, opts.threads, opts.duration_s, opts.pipeline },
    );

    const start_ns = monotonicNs();
    const deadline_ns = start_ns + opts.duration_s * std.time.ns_per_s;

    const contexts = try allocator.alloc(WorkerCtx, opts.threads);
    defer allocator.free(contexts);
    const base_conns = opts.conns / opts.threads;
    var extra_conns = opts.conns % opts.threads;
    for (contexts) |*ctx| {
        var conn_count = base_conns;
        if (extra_conns > 0) {
            conn_count += 1;
            extra_conns -= 1;
        }
        ctx.* = .{ .opts = &opts, .burst = burst, .conn_count = conn_count, .deadline_ns = deadline_ns };
    }

    const threads = try allocator.alloc(std.Thread, opts.threads - 1);
    defer allocator.free(threads);
    for (threads, 0..) |*thread, index| {
        thread.* = try std.Thread.spawn(.{}, workerEntry, .{&contexts[index + 1]});
    }
    workerEntry(&contexts[0]);
    for (threads) |thread| thread.join();

    const elapsed_s = @as(f64, @floatFromInt(monotonicNs() - start_ns)) / std.time.ns_per_s;

    var totals = Counters{};
    for (contexts) |ctx| {
        totals.ok += ctx.counters.ok;
        totals.non_2xx += ctx.counters.non_2xx;
        totals.conn_errors += ctx.counters.conn_errors;
    }

    const completed = totals.ok + totals.non_2xx;
    const req_per_s = @as(f64, @floatFromInt(completed)) / elapsed_s;

    var tp_buf: [32]u8 = undefined;
    std.debug.print("requests: {d} ({d} ok, {d} non-2xx, {d} conn errors)\n", .{ completed, totals.ok, totals.non_2xx, totals.conn_errors });
    std.debug.print("duration: {d:.2}s\n", .{elapsed_s});
    std.debug.print("throughput: {s} req/s ({d:.0})\n", .{ formatThroughput(&tp_buf, req_per_s), req_per_s });
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //

test "poc: parseUrl forms" {
    const parsed = try parseUrl("http://127.0.0.1:9100/echo");
    try std.testing.expectEqual(@as(u16, 9100), parsed.port);
    try std.testing.expectEqualStrings("/echo", parsed.path);
    try std.testing.expectEqualStrings("127.0.0.1", parsed.host);

    const bare = try parseUrl("http://localhost:8080");
    try std.testing.expectEqualStrings("/", bare.path);

    try std.testing.expectError(error.BadUrl, parseUrl("https://127.0.0.1/"));
    try std.testing.expectError(error.BadIp, parseUrl("http://example.com/"));
}

test "poc: parseIp4" {
    const ip = try parseIp4("127.0.0.1");
    const octets: [4]u8 = @bitCast(ip);
    try std.testing.expectEqual(@as(u8, 127), octets[0]);
    try std.testing.expectEqual(@as(u8, 1), octets[3]);

    try std.testing.expectError(error.BadIp, parseIp4("1.2.3"));
    try std.testing.expectError(error.BadIp, parseIp4("1.2.3.4.5"));
    try std.testing.expectError(error.BadIp, parseIp4("256.1.1.1"));
}
