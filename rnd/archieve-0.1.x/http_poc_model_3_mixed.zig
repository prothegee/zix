//! PoC: Model 3 — multiple accept threads (SO_REUSEPORT) + io.async() dispatch.
//!
//! Concurrency: N accept threads each call io.async(handleConnection) directly.
//! No ConnQueue — Threaded's internal pool is the shared dispatcher.
//! Combines the multi-port accept throughput of Model 2 with the adaptive
//! pool management of Model 1.
//!
//! Each accept thread shares the same io. io.async() from N threads is
//! mutex-protected inside Threaded — safe for concurrent callers. Pool grows
//! up to async_limit then falls back to inline on the stalled accept thread.
//!
//! Self-contained: no imports from zix src. Parser, date logic, and I/O
//! are all inlined to isolate the dispatch model as the only variable.
//!
//! Run: zig run rnd/http_poc_model_3_mixed.zig
//! Bench: wrk -c100 -t1 -d10s http://127.0.0.1:9102/

const std = @import("std");

const IP: []const u8 = "127.0.0.1";
const PORT: u16 = 9102;
const WORKERS: usize = 0; // 0 = cpu_count accept threads

// --------------------------------------------------------- //
// Parser (zero-copy, offset-based — same design as src/tcp/http/parser.zig)

const MAX_HEADERS: usize = 64;

const HeaderEntry = struct {
    name_start: u16,
    name_len: u8,
    value_start: u16,
    value_len: u16,
};

const ParsedHead = struct {
    path_start: u16,
    path_len: u16,
    header_count: u8,
    headers: [MAX_HEADERS]HeaderEntry,
    body_offset: u16,
    keep_alive: bool,
    content_length: u64,
};

const ParseError = error{ InvalidRequest, TooManyHeaders };

fn parse(buf: []const u8) ParseError!?ParsedHead {
    const header_end = std.mem.indexOf(u8, buf, "\r\n\r\n") orelse return null;
    const head_buf = buf[0..header_end];
    const first_crlf = std.mem.indexOf(u8, head_buf, "\r\n") orelse head_buf.len;
    const req_line = head_buf[0..first_crlf];

    const sp1 = std.mem.indexOfScalar(u8, req_line, ' ') orelse return error.InvalidRequest;
    const after_method = req_line[sp1 + 1 ..];
    const sp2 = std.mem.indexOfScalar(u8, after_method, ' ') orelse return error.InvalidRequest;
    const target = after_method[0..sp2];

    const path_abs: u16 = @intCast(sp1 + 1);
    const path_len: u16 = @intCast(if (std.mem.indexOfScalar(u8, target, '?')) |q| q else target.len);

    var headers: [MAX_HEADERS]HeaderEntry = undefined;
    var header_count: u8 = 0;
    var keep_alive = true;
    var content_length: u64 = 0;

    var pos: usize = first_crlf + 2;
    while (pos < head_buf.len) {
        const line_end = std.mem.indexOfPos(u8, head_buf, pos, "\r\n") orelse head_buf.len;
        const line = head_buf[pos..line_end];
        if (line.len == 0) break;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse { pos = line_end + 2; continue; };
        var val_off = colon + 1;
        while (val_off < line.len and line[val_off] == ' ') val_off += 1;
        if (header_count >= MAX_HEADERS) return error.TooManyHeaders;
        headers[header_count] = .{
            .name_start  = @intCast(pos),
            .name_len    = @intCast(colon),
            .value_start = @intCast(pos + val_off),
            .value_len   = @intCast(line.len - val_off),
        };
        header_count += 1;
        const name  = line[0..colon];
        const value = line[val_off..];
        if (std.ascii.eqlIgnoreCase(name, "content-length")) {
            content_length = std.fmt.parseInt(u64, value, 10) catch 0;
        } else if (std.ascii.eqlIgnoreCase(name, "connection")) {
            if (std.ascii.eqlIgnoreCase(value, "close")) keep_alive = false;
        }
        pos = line_end + 2;
    }

    return ParsedHead{
        .path_start     = path_abs,
        .path_len       = path_len,
        .header_count   = header_count,
        .headers        = headers,
        .body_offset    = @intCast(header_end + 4),
        .keep_alive     = keep_alive,
        .content_length = content_length,
    };
}

// --------------------------------------------------------- //
// Date cache: double-buffered, updated every 500ms by a background thread.

var g_date_bufs: [2][40]u8 = undefined;
var g_date_lens: [2]usize = .{ 0, 0 };
var g_date_active = std.atomic.Value(usize).init(0);
var g_date_secs = std.atomic.Value(u64).init(0);

fn formatHttpDate(secs: u64, buf: []u8) []u8 {
    const ep = std.time.epoch;
    const es = ep.EpochSeconds{ .secs = secs };
    const epoch_day = es.getEpochDay();
    const year_day  = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_secs  = es.getDaySeconds();
    const day_names   = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
    const month_names = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
    const dow = (@as(u64, epoch_day.day) % 7 + 4) % 7;
    return std.fmt.bufPrint(buf, "{s}, {d:0>2} {s} {d} {d:0>2}:{d:0>2}:{d:0>2} GMT", .{
        day_names[dow],
        @as(u32, month_day.day_index) + 1,
        month_names[@intFromEnum(month_day.month) - 1],
        year_day.year,
        day_secs.getHoursIntoDay(),
        day_secs.getMinutesIntoHour(),
        day_secs.getSecondsIntoMinute(),
    }) catch buf[0..0];
}

fn updateDateCache() void {
    var ts: std.posix.timespec = undefined;
    _ = std.posix.system.clock_gettime(std.posix.CLOCK.REALTIME, &ts);
    const cur: u64 = if (ts.sec >= 0) @intCast(ts.sec) else 0;
    if (cur == g_date_secs.load(.monotonic)) return;
    const next = 1 - g_date_active.load(.monotonic);
    const s = formatHttpDate(cur, &g_date_bufs[next]);
    g_date_lens[next] = s.len;
    g_date_active.store(next, .release);
    g_date_secs.store(cur, .release);
}

fn timerLoop() void {
    while (true) {
        updateDateCache();
        _ = std.posix.system.nanosleep(&(std.posix.timespec{ .sec = 0, .nsec = 500 * 1000 * 1000 }), null);
    }
}

// --------------------------------------------------------- //

fn fdWriteAll(fd: std.posix.fd_t, data: []const u8) error{BrokenPipe}!void {
    var rem = data;
    while (rem.len > 0) {
        const rc = std.posix.system.write(fd, rem.ptr, rem.len);
        switch (std.posix.errno(rc)) {
            .SUCCESS => {
                const n: usize = @intCast(rc);
                if (n == 0) return error.BrokenPipe;
                rem = rem[n..];
            },
            .INTR => continue,
            else => return error.BrokenPipe,
        }
    }
}

// --------------------------------------------------------- //

fn handleConnection(stream: std.Io.net.Stream, io: std.Io) void {
    defer stream.close(io);
    const fd = stream.socket.handle;

    std.posix.setsockopt(
        fd, std.posix.IPPROTO.TCP, std.posix.TCP.NODELAY,
        std.mem.asBytes(&@as(c_int, 1)),
    ) catch {};

    var read_buf: [4096]u8 = undefined;

    while (true) {
        var filled: usize = 0;
        var found = false;
        while (filled < read_buf.len) {
            const n = std.posix.read(fd, read_buf[filled..]) catch break;
            if (n == 0) break;
            const prev = filled;
            filled += n;
            const search_from = if (prev > 3) prev - 3 else 0;
            if (std.mem.indexOfPos(u8, read_buf[0..filled], search_from, "\r\n\r\n")) |_| {
                found = true;
                break;
            }
        }
        if (!found) break;

        const head = parse(read_buf[0..filled]) catch break orelse break;

        const idx  = g_date_active.load(.acquire);
        const date = g_date_bufs[idx][0..g_date_lens[idx]];

        var resp: [512]u8 = undefined;
        var off: usize = 0;
        const prefix = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 13\r\nDate: ";
        @memcpy(resp[off..][0..prefix.len], prefix);
        off += prefix.len;
        @memcpy(resp[off..][0..date.len], date);
        off += date.len;
        const tail = if (head.keep_alive)
            "\r\nConnection: keep-alive\r\n\r\nHello, World!"
        else
            "\r\nConnection: close\r\n\r\nHello, World!";
        @memcpy(resp[off..][0..tail.len], tail);
        off += tail.len;

        fdWriteAll(fd, resp[0..off]) catch break;

        if (!head.keep_alive) break;
        if (head.content_length > 0) break;
    }
}

// --------------------------------------------------------- //

const AcceptCtx = struct { io: std.Io };

// Each accept thread owns its own listener (SO_REUSEPORT) and dispatches
// accepted connections via io.async() into the shared Threaded pool.
fn acceptEntry(ctx: AcceptCtx) void {
    const addr = std.Io.net.IpAddress.resolve(ctx.io, IP, PORT) catch return;
    var net_server = addr.listen(ctx.io, .{
        .mode = .stream, .kernel_backlog = 4096, .reuse_address = true,
    }) catch return;
    defer net_server.deinit(ctx.io);
    while (true) {
        const stream = net_server.accept(ctx.io) catch continue;
        _ = ctx.io.async(handleConnection, .{ stream, ctx.io });
    }
}

// --------------------------------------------------------- //

pub fn main() !void {
    const cpu = try std.Thread.getCpuCount();
    const worker_count = if (WORKERS == 0) cpu else WORKERS;

    // Default InitOptions: async_limit = cpu_count - 1, stack_size = 8MB.
    // Tune async_limit and stack_size here to benchmark different pool configs.
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    updateDateCache();
    const timer = try std.Thread.spawn(.{}, timerLoop, .{});
    defer timer.detach();

    std.debug.print("poc model 3 (mixed): {s}:{d} ({d} accept + io.async pool)\n", .{
        IP, PORT, worker_count,
    });

    const acc_threads = try std.heap.smp_allocator.alloc(std.Thread, worker_count);
    defer std.heap.smp_allocator.free(acc_threads);
    for (acc_threads) |*t|
        t.* = try std.Thread.spawn(.{}, acceptEntry, .{AcceptCtx{ .io = io }});

    for (acc_threads) |t| t.join();
}
