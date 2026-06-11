//! FIX 4.x PoC server: echo server for all 3 dispatch models.
//!
//! Session: Logon -> application message echo -> Logout.
//! All session logic is in fix_poc_core.zig.
//!
//! Self-contained: no imports from zix src.
//!
//! Run:
//!   zig run rnd/fix_poc_server.zig                         (ASYNC, port 9400)
//!   zig run rnd/fix_poc_server.zig -- --model pool         (POOL)
//!   zig run rnd/fix_poc_server.zig -- --model mixed        (MIXED)
//!   zig run rnd/fix_poc_server.zig -- --port 9401          (custom port)
//! Test:
//!   zig run rnd/fix_poc_client.zig -- --port 9400

const std = @import("std");
const core = @import("fix_poc_core.zig");

const DEFAULT_IP: []const u8 = "0.0.0.0";
const DEFAULT_PORT: u16 = 9400;
const DEFAULT_MODEL: []const u8 = "async";
const COMP_ID: []const u8 = "SERVER";
const WORKERS: usize = 0; // 0 = cpu_count
const POOL_SIZE: usize = 0; // 0 = @max(10, cpu_count * 2)

// ------------------------------------------------------------------- //
// Connection handler (all models)                                      //
// ------------------------------------------------------------------- //

const ConnArgs = struct { stream: std.Io.net.Stream, io: std.Io };

fn handleConnection(args: ConnArgs) void {
    defer args.stream.close(args.io);
    core.serveConn(args.stream, args.io, COMP_ID) catch |e| {
        std.debug.print("fix: conn error: {}\n", .{e});
    };
}

// ------------------------------------------------------------------- //
// ASYNC model                                                          //
// ------------------------------------------------------------------- //

fn runAsync(ip: []const u8, port: u16, io: std.Io) !void {
    const addr = try std.Io.net.IpAddress.resolve(io, ip, port);
    var server = try addr.listen(io, .{
        .mode = .stream,
        .protocol = .tcp,
        .reuse_address = true,
        .kernel_backlog = 1024,
    });
    defer server.deinit(io);

    std.debug.print("fix server (async): {s}:{d}\n", .{ ip, port });

    while (true) {
        const stream = server.accept(io) catch |e| {
            std.debug.print("fix: accept error: {}\n", .{e});
            continue;
        };
        _ = io.async(handleConnection, .{ConnArgs{ .stream = stream, .io = io }});
    }
}

// ------------------------------------------------------------------- //
// POOL model                                                           //
// ------------------------------------------------------------------- //

const ConnQueue = struct {
    mutex: std.Io.Mutex = .init,
    ready: std.Io.Condition = .init,
    items: std.ArrayListUnmanaged(std.Io.net.Stream) = .empty,
    closed: bool = false,

    fn push(self: *ConnQueue, stream: std.Io.net.Stream, io: std.Io) void {
        self.mutex.lockUncancelable(io);
        self.items.append(std.heap.smp_allocator, stream) catch {
            self.mutex.unlock(io);
            stream.close(io);
            return;
        };
        self.mutex.unlock(io);
        self.ready.signal(io);
    }

    fn pop(self: *ConnQueue, io: std.Io) ?std.Io.net.Stream {
        self.mutex.lockUncancelable(io);
        while (self.items.items.len == 0) {
            if (self.closed) {
                self.mutex.unlock(io);
                return null;
            }
            self.ready.waitUncancelable(io, &self.mutex);
        }
        const stream = self.items.orderedRemove(0);
        self.mutex.unlock(io);
        return stream;
    }

    fn close(self: *ConnQueue, io: std.Io) void {
        self.mutex.lockUncancelable(io);
        self.closed = true;
        self.mutex.unlock(io);
        self.ready.broadcast(io);
    }

    fn deinit(self: *ConnQueue) void {
        self.items.deinit(std.heap.smp_allocator);
    }
};

const PoolCtx = struct { queue: *ConnQueue, io: std.Io };
const AcceptCtx = struct { queue: *ConnQueue, io: std.Io, ip: []const u8, port: u16 };

fn poolEntry(ctx: PoolCtx) void {
    while (ctx.queue.pop(ctx.io)) |stream| {
        handleConnection(.{ .stream = stream, .io = ctx.io });
    }
}

fn acceptEntry(ctx: AcceptCtx) void {
    const addr = std.Io.net.IpAddress.resolve(ctx.io, ctx.ip, ctx.port) catch return;
    var server = addr.listen(ctx.io, .{
        .mode = .stream,
        .protocol = .tcp,
        .reuse_address = true,
        .kernel_backlog = 1024,
    }) catch return;
    defer server.deinit(ctx.io);

    while (true) {
        const stream = server.accept(ctx.io) catch continue;
        ctx.queue.push(stream, ctx.io);
    }
}

fn runPool(ip: []const u8, port: u16, io: std.Io) !void {
    const cpu = try std.Thread.getCpuCount();
    const worker_count = if (WORKERS == 0) cpu else WORKERS;
    const pool_count = if (POOL_SIZE == 0) @max(10, cpu * 2) else POOL_SIZE;

    std.debug.print("fix server (pool): {s}:{d} ({d} accept, {d} pool)\n", .{
        ip, port, worker_count, pool_count,
    });

    var queue = ConnQueue{};
    defer queue.deinit();

    const pool_threads = try std.heap.smp_allocator.alloc(std.Thread, pool_count);
    defer std.heap.smp_allocator.free(pool_threads);
    for (pool_threads) |*t|
        t.* = try std.Thread.spawn(
            .{ .stack_size = 512 * 1024 },
            poolEntry,
            .{PoolCtx{ .queue = &queue, .io = io }},
        );

    const acc_threads = try std.heap.smp_allocator.alloc(std.Thread, worker_count);
    defer std.heap.smp_allocator.free(acc_threads);
    for (acc_threads) |*t|
        t.* = try std.Thread.spawn(
            .{ .stack_size = 256 * 1024 },
            acceptEntry,
            .{AcceptCtx{ .queue = &queue, .io = io, .ip = ip, .port = port }},
        );

    for (acc_threads) |t| t.join();
    queue.close(io);
    for (pool_threads) |t| t.join();
}

// ------------------------------------------------------------------- //
// MIXED model                                                          //
// ------------------------------------------------------------------- //

const MixedAcceptCtx = struct { io: std.Io, ip: []const u8, port: u16 };

fn mixedAcceptEntry(ctx: MixedAcceptCtx) void {
    const addr = std.Io.net.IpAddress.resolve(ctx.io, ctx.ip, ctx.port) catch return;
    var server = addr.listen(ctx.io, .{
        .mode = .stream,
        .protocol = .tcp,
        .reuse_address = true,
        .kernel_backlog = 1024,
    }) catch return;
    defer server.deinit(ctx.io);

    while (true) {
        const stream = server.accept(ctx.io) catch continue;
        _ = ctx.io.async(handleConnection, .{ConnArgs{ .stream = stream, .io = ctx.io }});
    }
}

fn runMixed(ip: []const u8, port: u16, io: std.Io) !void {
    const cpu = try std.Thread.getCpuCount();
    const worker_count = if (WORKERS == 0) cpu else WORKERS;

    std.debug.print("fix server (mixed): {s}:{d} ({d} accept)\n", .{ ip, port, worker_count });

    const acc_threads = try std.heap.smp_allocator.alloc(std.Thread, worker_count);
    defer std.heap.smp_allocator.free(acc_threads);
    for (acc_threads) |*t|
        t.* = try std.Thread.spawn(
            .{ .stack_size = 256 * 1024 },
            mixedAcceptEntry,
            .{MixedAcceptCtx{ .io = io, .ip = ip, .port = port }},
        );

    for (acc_threads) |t| t.join();
}

// ------------------------------------------------------------------- //
// main                                                                 //
// ------------------------------------------------------------------- //

pub fn main(process: std.process.Init) !void {
    var ip: []const u8 = DEFAULT_IP;
    var port: u16 = DEFAULT_PORT;
    var model: []const u8 = DEFAULT_MODEL;

    var args = std.process.Args.Iterator.init(process.minimal.args);
    _ = args.next(); // argv[0]
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--ip")) {
            ip = args.next() orelse return error.MissingArg;
        } else if (std.mem.eql(u8, arg, "--port")) {
            const s = args.next() orelse return error.MissingArg;
            port = try std.fmt.parseInt(u16, s, 10);
        } else if (std.mem.eql(u8, arg, "--model")) {
            model = args.next() orelse return error.MissingArg;
        }
    }

    const io = process.io;

    if (std.mem.eql(u8, model, "pool")) {
        try runPool(ip, port, io);
    } else if (std.mem.eql(u8, model, "mixed")) {
        try runMixed(ip, port, io);
    } else {
        try runAsync(ip, port, io);
    }
}
