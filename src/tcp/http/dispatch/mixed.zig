//! zix http .MIXED dispatch model: N pinned accept threads, each dispatching
//! accepted connections via io.async(). No ConnQueue, the io Threaded pool
//! handles scheduling.

const std = @import("std");
const common = @import("common.zig");
const logSystem = common.logSystem;
const handleConnection = common.handleConnection;
const pinToCpu = common.pinToCpu;

// --------------------------------------------------------- //

/// Accept thread for MIXED dispatch: accepts connections and dispatches each via io.async().
/// No ConnQueue. The shared io Threaded pool handles scheduling.
fn asyncWorkerEntry(server: anytype, io: std.Io, worker_id: usize) void {
    pinToCpu(worker_id);

    const cfg = server.config;

    // io.async needs a concrete function (no anytype param), so wrap the generic
    // handleConnection in a closure where the server pointer type is fixed.
    const Spawn = struct {
        fn handle(stream: std.Io.net.Stream, h_io: std.Io, srv: @TypeOf(server)) void {
            handleConnection(stream, h_io, srv);
        }
    };

    const addr = std.Io.net.IpAddress.resolve(io, cfg.ip, cfg.port) catch |err| {
        logSystem(cfg, "worker resolve error: {}", .{err});
        return;
    };
    var net_server = addr.listen(io, .{
        .mode = .stream,
        .kernel_backlog = @intCast(cfg.kernel_backlog),
        .reuse_address = true, // SO_REUSEADDR + SO_REUSEPORT on POSIX, required for POOL, applied to all models
    }) catch |err| {
        logSystem(cfg, "worker listen error: {}", .{err});
        return;
    };
    defer net_server.deinit(io);

    while (true) {
        const stream = net_server.accept(io) catch |err| {
            if (err != error.ConnectionAborted) {
                logSystem(cfg, "worker accept error: {}", .{err});
                break;
            }
            continue;
        };
        _ = io.async(Spawn.handle, .{ stream, io, server });
    }
}

// --------------------------------------------------------- //
// MIXED model

pub fn runMixed(server: anytype, io: std.Io, cpu: usize) !void {
    const cfg = server.config;
    const worker_count = if (cfg.workers == 0) cpu else cfg.workers;

    logSystem(cfg, "listening on {s}:{d} ({d} accept, io.async)", .{ cfg.ip, cfg.port, worker_count });

    const acc_threads = try std.heap.smp_allocator.alloc(std.Thread, worker_count);
    defer std.heap.smp_allocator.free(acc_threads);
    for (acc_threads, 0..) |*t, idx| {
        t.* = try std.Thread.spawn(.{}, asyncWorkerEntry, .{ server, io, idx });
    }

    for (acc_threads) |t| t.join();
}
