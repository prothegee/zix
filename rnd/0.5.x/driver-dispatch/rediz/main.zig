//! rediz transport PoC: drive the HttpArena write-behind mirror workload against
//! the Redis 7 bench container under three dispatch models and compare raw
//! throughput. No HTTP anywhere. std only.
//!
//! ASYNC: K blocking connections, one round trip in flight each (io.async).
//! EPOLL: one thread, K non-blocking connections, W commands pipelined each.
//! URING: one thread, K connections as io_uring ops, W pipelined each.

const std = @import("std");
const resp = @import("resp.zig");

const linux = std.os.linux;
const Fd = resp.Fd;

const PORT: u16 = 6379;

const DURATION_NS: u64 = 5 * std.time.ns_per_s;
const POOL: usize = 20_000;
const WINDOW: usize = 64;
const ID_RANGE: u64 = 50_000;

const CATEGORIES = [_][]const u8{ "tools", "food", "books", "toys", "garden" };

const Model = enum { ASYNC, EPOLL, URING };

/// One profile per operation. The entry uses redis as a write-behind mirror, so
/// SET (fill) and DEL (invalidation) are the real load. GET is added as the
/// read counterpart a general driver would run.
const Profile = enum { SET, GET, DEL };

fn cpuConns() usize {
    const cpu = std.Thread.getCpuCount() catch 8;

    return std.math.clamp(cpu, 4, 16);
}

/// Workload-only measurement (connection setup excluded). cpu_ns is process CPU
/// time (all threads) during the workload, so cpu_ns / ns is the cores used.
const Result = struct { completed: u64, ns: u64, cpu_ns: u64 };

// --------------------------------------------------------- //
// workload

fn renderCommand(arena: std.mem.Allocator, rng: std.Random, profile: Profile) []const u8 {
    const id = rng.intRangeLessThan(u64, 1, ID_RANGE);
    var key_buf: [32]u8 = undefined;
    const key = std.fmt.bufPrint(&key_buf, "item:{d}", .{id}) catch unreachable;

    var cmd_buf: [512]u8 = undefined;
    const len = switch (profile) {
        .GET => resp.encodeCmd(&.{ "GET", key }, &cmd_buf),
        .DEL => resp.encodeCmd(&.{ "DEL", key }, &cmd_buf),
        .SET => blk: {
            const cat = CATEGORIES[rng.intRangeLessThan(usize, 0, CATEGORIES.len)];
            const price = rng.intRangeLessThan(u64, 1, 1000);
            const qty = rng.intRangeLessThan(u64, 1, 500);

            var val_buf: [256]u8 = undefined;
            const value = std.fmt.bufPrint(&val_buf, "{{\"id\":{d},\"name\":\"item{d}\",\"category\":\"{s}\",\"price\":{d},\"quantity\":{d},\"active\":true,\"tags\":[],\"rating_score\":0,\"rating_count\":0}}", .{ id, id, cat, price, qty }) catch unreachable;

            break :blk resp.encodeCmd(&.{ "SET", key, value }, &cmd_buf);
        },
    };

    return arena.dupe(u8, cmd_buf[0..len]) catch unreachable;
}

fn buildWorkload(arena: std.mem.Allocator, n: usize, profile: Profile) [][]const u8 {
    var prng = std.Random.DefaultPrng.init(0x5eed_0016 + @as(u64, @intFromEnum(profile)));
    const rng = prng.random();

    const commands = arena.alloc([]const u8, n) catch unreachable;
    for (commands) |*slot| slot.* = renderCommand(arena, rng, profile);

    return commands;
}

// --------------------------------------------------------- //
// ASYNC model

const AsyncCtx = struct {
    fd: Fd,
    commands: []const []const u8,
    deadline: u64,
    next: *std.atomic.Value(usize),
    completed: *std.atomic.Value(u64),
};

fn asyncConn(ctx: AsyncCtx) void {
    var qbuf: [2048]u8 = undefined;
    var rbuf: [65536]u8 = undefined;
    var local: u64 = 0;

    while (nowNs() < ctx.deadline) {
        const idx = ctx.next.fetchAdd(1, .monotonic) % ctx.commands.len;

        const qlen = resp.encode(ctx.commands[idx], &qbuf);
        resp.writeAll(ctx.fd, qbuf[0..qlen]) catch break;

        var acc: usize = 0;
        var got: bool = false;
        while (!got) {
            const n = resp.readNb(ctx.fd, rbuf[acc..]);
            if (n == 0) break;

            acc += n;
            const result = resp.scan(rbuf[0..acc]);
            if (result.ready >= 1) {
                local += 1;
                got = true;
                break;
            }
            if (result.consumed > 0) {
                std.mem.copyForwards(u8, rbuf[0 .. acc - result.consumed], rbuf[result.consumed..acc]);
                acc -= result.consumed;
            }
            if (acc == rbuf.len) break;
        }
        if (!got) break;
    }

    _ = ctx.completed.fetchAdd(local, .monotonic);
}

fn runAsync(gpa: std.mem.Allocator, commands: []const []const u8, conns: usize) !Result {
    const fds = try gpa.alloc(Fd, conns);
    defer gpa.free(fds);

    var opened: usize = 0;
    errdefer for (fds[0..opened]) |fd| resp.close(fd);
    while (opened < conns) : (opened += 1) fds[opened] = try resp.connect(PORT);
    defer for (fds) |fd| resp.close(fd);

    var threaded = std.Io.Threaded.init(gpa, .{ .async_limit = .unlimited });
    defer threaded.deinit();
    const io = threaded.io();

    var next = std.atomic.Value(usize).init(0);
    var completed = std.atomic.Value(u64).init(0);

    const futures = try gpa.alloc(std.Io.Future(void), conns);
    defer gpa.free(futures);

    const cpu0 = cpuNs();
    const start = nowNs();
    const deadline = start + DURATION_NS;
    for (futures, fds) |*future, fd| future.* = io.async(asyncConn, .{AsyncCtx{ .fd = fd, .commands = commands, .deadline = deadline, .next = &next, .completed = &completed }});
    for (futures) |*future| future.await(io);
    const elapsed = nowNs() - start;

    return .{ .completed = completed.load(.monotonic), .ns = elapsed, .cpu_ns = cpuNs() - cpu0 };
}

// --------------------------------------------------------- //
// multiplexed connection state (EPOLL and URING)

const OUT_BUF: usize = 32 * 1024;
const IN_BUF: usize = 64 * 1024;

const Conn = struct {
    fd: Fd,
    out: [OUT_BUF]u8 = undefined,
    out_len: usize = 0,
    out_sent: usize = 0,
    in: [IN_BUF]u8 = undefined,
    in_len: usize = 0,
    inflight: usize = 0,

    fn fill(self: *Conn, commands: []const []const u8, next: *usize) void {
        if (self.out_len != 0) return;

        while (self.inflight < WINDOW) {
            const cmd = commands[next.* % commands.len];
            if (self.out_len + cmd.len > self.out.len) break;

            self.out_len += resp.encode(cmd, self.out[self.out_len..]);
            self.inflight += 1;
            next.* += 1;
        }
    }

    fn ingest(self: *Conn, n: usize, completed: *u64) bool {
        self.in_len += n;

        const result = resp.scan(self.in[0..self.in_len]);
        if (result.failed) return false;

        self.inflight -= result.ready;
        completed.* += result.ready;

        if (result.consumed > 0) {
            std.mem.copyForwards(u8, self.in[0 .. self.in_len - result.consumed], self.in[result.consumed..self.in_len]);
            self.in_len -= result.consumed;
        }

        return true;
    }
};

fn openConns(gpa: std.mem.Allocator, conns: usize) ![]Conn {
    const table = try gpa.alloc(Conn, conns);
    for (table, 0..) |*conn, idx| {
        conn.* = .{ .fd = resp.connect(PORT) catch {
            for (table[0..idx]) |*done| resp.close(done.fd);
            gpa.free(table);

            return error.ConnectFailed;
        } };
        resp.setNonBlock(conn.fd);
    }

    return table;
}

// --------------------------------------------------------- //
// EPOLL model

fn epollEvents(conn: *Conn) u32 {
    var events: u32 = linux.EPOLL.IN;
    if (conn.out_sent < conn.out_len) events |= linux.EPOLL.OUT;

    return events;
}

fn epollMod(epfd: Fd, conn: *Conn, idx: usize) void {
    var event = linux.epoll_event{ .events = epollEvents(conn), .data = .{ .ptr = idx } };
    _ = linux.epoll_ctl(epfd, linux.EPOLL.CTL_MOD, conn.fd, &event);
}

fn runEpoll(gpa: std.mem.Allocator, commands: []const []const u8, conns: usize) !Result {
    const table = try openConns(gpa, conns);
    defer {
        for (table) |*conn| resp.close(conn.fd);
        gpa.free(table);
    }

    const epfd: Fd = @intCast(linux.epoll_create1(0));
    defer resp.close(epfd);

    var next: usize = 0;
    var completed: u64 = 0;
    const cpu0 = cpuNs();
    const start = nowNs();
    const deadline = start + DURATION_NS;

    for (table, 0..) |*conn, idx| {
        conn.fill(commands, &next);
        var event = linux.epoll_event{ .events = epollEvents(conn), .data = .{ .ptr = idx } };
        _ = linux.epoll_ctl(epfd, linux.EPOLL.CTL_ADD, conn.fd, &event);
    }

    var events: [256]linux.epoll_event = undefined;
    while (nowNs() < deadline) {
        const count = linux.epoll_wait(epfd, &events, events.len, 100);
        if (count == 0) continue;

        for (events[0..count]) |event| {
            const idx: usize = @intCast(event.data.ptr);
            const conn = &table[idx];

            if (event.events & linux.EPOLL.OUT != 0) {
                conn.out_sent += resp.writeNb(conn.fd, conn.out[conn.out_sent..conn.out_len]);
                if (conn.out_sent >= conn.out_len) {
                    conn.out_len = 0;
                    conn.out_sent = 0;
                }
            }

            if (event.events & linux.EPOLL.IN != 0) {
                const n = resp.readNb(conn.fd, conn.in[conn.in_len..]);
                if (n > 0) {
                    if (!conn.ingest(n, &completed)) return error.ServerError;
                }
            }

            conn.fill(commands, &next);
            epollMod(epfd, conn, idx);
        }
    }

    return .{ .completed = completed, .ns = nowNs() - start, .cpu_ns = cpuNs() - cpu0 };
}

// --------------------------------------------------------- //
// URING model

const OP_RECV: u64 = 0;
const OP_SEND: u64 = 1;

fn uringPump(ring: *linux.IoUring, conn: *Conn, idx: usize, commands: []const []const u8, next: *usize, send_armed: *bool) void {
    conn.fill(commands, next);
    if (!send_armed.* and conn.out_sent < conn.out_len) {
        const user_data = (idx << 1) | OP_SEND;
        _ = ring.send(user_data, conn.fd, conn.out[conn.out_sent..conn.out_len], 0) catch return;
        send_armed.* = true;
    }
}

fn runUring(gpa: std.mem.Allocator, commands: []const []const u8, conns: usize) !Result {
    const table = try openConns(gpa, conns);
    defer {
        for (table) |*conn| resp.close(conn.fd);
        gpa.free(table);
    }

    const entries: u16 = @intCast(std.math.ceilPowerOfTwo(usize, conns * 4) catch 4096);
    var ring = try linux.IoUring.init(entries, 0);
    defer ring.deinit();

    const send_armed = try gpa.alloc(bool, conns);
    defer gpa.free(send_armed);
    @memset(send_armed, false);

    var next: usize = 0;
    var completed: u64 = 0;
    const cpu0 = cpuNs();
    const start = nowNs();
    const deadline = start + DURATION_NS;

    for (table, 0..) |*conn, idx| {
        _ = try ring.recv((idx << 1) | OP_RECV, conn.fd, .{ .buffer = conn.in[conn.in_len..] }, 0);
        uringPump(&ring, conn, idx, commands, &next, &send_armed[idx]);
    }

    while (nowNs() < deadline) {
        _ = try ring.submit_and_wait(1);

        while (ring.cq_ready() > 0) {
            const cqe = try ring.copy_cqe();
            const idx: usize = @intCast(cqe.user_data >> 1);
            const op = cqe.user_data & 1;
            const conn = &table[idx];

            if (cqe.res <= 0) return error.ServerError;
            const done: usize = @intCast(cqe.res);

            if (op == OP_SEND) {
                conn.out_sent += done;
                send_armed[idx] = false;
                if (conn.out_sent >= conn.out_len) {
                    conn.out_len = 0;
                    conn.out_sent = 0;
                }
            } else {
                if (!conn.ingest(done, &completed)) return error.ServerError;
                _ = try ring.recv((idx << 1) | OP_RECV, conn.fd, .{ .buffer = conn.in[conn.in_len..] }, 0);
            }

            uringPump(&ring, conn, idx, commands, &next, &send_armed[idx]);
        }
    }

    return .{ .completed = completed, .ns = nowNs() - start, .cpu_ns = cpuNs() - cpu0 };
}

// --------------------------------------------------------- //

fn runModel(gpa: std.mem.Allocator, model: Model, commands: []const []const u8, conns: usize) !Result {
    return switch (model) {
        .ASYNC => runAsync(gpa, commands, conns),
        .EPOLL => runEpoll(gpa, commands, conns),
        .URING => runUring(gpa, commands, conns),
    };
}

fn nowNs() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);

    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

/// Process CPU time (user + system, all threads) in nanoseconds.
fn cpuNs() u64 {
    var usage: linux.rusage = undefined;
    _ = linux.getrusage(linux.rusage.SELF, &usage);

    const user = @as(u64, @intCast(usage.utime.sec)) * std.time.ns_per_s + @as(u64, @intCast(usage.utime.usec)) * std.time.ns_per_us;
    const sys = @as(u64, @intCast(usage.stime.sec)) * std.time.ns_per_s + @as(u64, @intCast(usage.stime.usec)) * std.time.ns_per_us;

    return user + sys;
}

/// Whole-machine CPU jiffies from /proc/stat: busy (all cores minus idle and
/// iowait) and total. A before/after delta gives the machine-wide busy percent,
/// which includes redis and matches what top shows.
fn machineCpu() struct { busy: u64, total: u64 } {
    const fd_rc = linux.openat(linux.AT.FDCWD, "/proc/stat", .{}, 0);
    if (std.posix.errno(fd_rc) != .SUCCESS) return .{ .busy = 0, .total = 0 };

    const fd: Fd = @intCast(fd_rc);
    defer _ = linux.close(fd);

    var buf: [512]u8 = undefined;
    const read_rc = linux.read(fd, &buf, buf.len);
    if (std.posix.errno(read_rc) != .SUCCESS) return .{ .busy = 0, .total = 0 };

    const first_line_end = std.mem.indexOfScalar(u8, buf[0..read_rc], '\n') orelse read_rc;
    var it = std.mem.tokenizeScalar(u8, buf[0..first_line_end], ' ');
    _ = it.next(); // "cpu"

    var total: u64 = 0;
    var idle: u64 = 0;
    var field: usize = 0;
    while (it.next()) |tok| : (field += 1) {
        const value = std.fmt.parseInt(u64, tok, 10) catch continue;
        total += value;
        if (field == 3 or field == 4) idle += value; // idle + iowait
    }

    return .{ .busy = total - idle, .total = total };
}

/// Reset the peak RSS high-water mark so the next read reflects one run only.
fn resetRssPeak() void {
    const fd_rc = linux.openat(linux.AT.FDCWD, "/proc/self/clear_refs", .{ .ACCMODE = .WRONLY }, 0);
    if (std.posix.errno(fd_rc) != .SUCCESS) return;

    const fd: Fd = @intCast(fd_rc);
    defer _ = linux.close(fd);
    _ = linux.write(fd, "5\n", 2);
}

/// Peak RSS in kilobytes since the last resetRssPeak (VmHWM from /proc).
fn peakRssKb() u64 {
    const fd_rc = linux.openat(linux.AT.FDCWD, "/proc/self/status", .{}, 0);
    if (std.posix.errno(fd_rc) != .SUCCESS) return 0;

    const fd: Fd = @intCast(fd_rc);
    defer _ = linux.close(fd);

    var buf: [4096]u8 = undefined;
    const read_rc = linux.read(fd, &buf, buf.len);
    if (std.posix.errno(read_rc) != .SUCCESS) return 0;

    const content = buf[0..read_rc];
    const marker = std.mem.indexOf(u8, content, "VmHWM:") orelse return 0;
    var rest = content[marker + "VmHWM:".len ..];
    var start: usize = 0;
    while (start < rest.len and (rest[start] == ' ' or rest[start] == '\t')) start += 1;
    var end = start;
    while (end < rest.len and rest[end] >= '0' and rest[end] <= '9') end += 1;

    return std.fmt.parseInt(u64, rest[start..end], 10) catch 0;
}

/// Unbuffered stderr line, so partial output survives a kill.
fn line(comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, fmt, args) catch return;
    _ = linux.write(2, text.ptr, text.len);
}

fn bench(gpa: std.mem.Allocator, model: Model, profile: Profile, commands: []const []const u8, conns: usize) !void {
    resetRssPeak();
    const machine0 = machineCpu();
    const result = try runModel(gpa, model, commands, conns);
    const machine1 = machineCpu();
    const rss_mb = @as(f64, @floatFromInt(peakRssKb())) / 1024.0;

    const secs = @as(f64, @floatFromInt(result.ns)) / std.time.ns_per_s;
    const rps = @as(f64, @floatFromInt(result.completed)) / secs;

    // driver process CPU, top-style: 100 percent is one core
    const drv_pct = 100.0 * @as(f64, @floatFromInt(result.cpu_ns)) / @as(f64, @floatFromInt(result.ns));

    // whole-machine busy percent over the run, includes redis, matches top
    const total_delta = machine1.total - machine0.total;
    const busy_delta = machine1.busy - machine0.busy;
    const machine_pct = if (total_delta > 0) 100.0 * @as(f64, @floatFromInt(busy_delta)) / @as(f64, @floatFromInt(total_delta)) else 0.0;

    line("  {s:<6} {s:<6} {d:>10} {d:>10.0} {d:>7.0} {d:>8.0} {d:>7.1}\n", .{ @tagName(model), @tagName(profile), result.completed, rps, drv_pct, machine_pct, rss_mb });
}

// --------------------------------------------------------- //

pub fn main() !void {
    const gpa = std.heap.smp_allocator;

    const conns = cpuConns();
    const seconds = DURATION_NS / std.time.ns_per_s;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    line("rediz transport PoC: {d}s per (model,op), K={d} conns, window={d}, pool={d}\n", .{ seconds, conns, WINDOW, POOL });
    line("  reqs = completed in {d}s (duration-based, so faster model finishes more).\n", .{seconds});
    line("  drvCPU% = driver process, 100% = one core. machCPU% = whole box (includes redis, matches top).\n", .{});
    line("  {s:<6} {s:<6} {s:>10} {s:>10} {s:>7} {s:>8} {s:>7}\n", .{ "model", "op", "reqs", "req/s", "drvCPU%", "machCPU%", "memMB" });

    for ([_]Profile{ .SET, .GET, .DEL }) |profile| {
        const commands = buildWorkload(arena, POOL, profile);
        for ([_]Model{ .ASYNC, .EPOLL, .URING }) |model| {
            try bench(gpa, model, profile, commands, conns);
        }
    }
}
