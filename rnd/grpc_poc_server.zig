//! gRPC PoC server — SayHello (proto + JSON), EchoJSON (JSON echo).
//! Routes: /helloworld.Greeter/SayHello, /echo.EchoService/Echo.
//!
//! Run:
//!   zig run rnd/grpc_poc_server.zig                        (ASYNC, port 8083)
//!   zig run rnd/grpc_poc_server.zig -- --model pool        (POOL)
//!   zig run rnd/grpc_poc_server.zig -- --model mixed       (MIXED)
//!   zig run rnd/grpc_poc_server.zig -- --port 8084         (custom port)

const std = @import("std");
const h2 = @import("http2_poc_core.zig");
const grpc = @import("grpc_poc_core.zig");

const DEFAULT_IP: []const u8 = "127.0.0.1";
const DEFAULT_PORT: u16 = 8083;
const DEFAULT_MODEL: []const u8 = "async";
const WORKERS: usize = 0; // 0 = cpu_count
const POOL_SIZE: usize = 0; // 0 = @max(10, cpu_count * 2)

// ------------------------------------------------------------------ //
// gRPC route handler (shared by all models)                          //
// ------------------------------------------------------------------ //

fn grpcHandler(
    method: []const u8,
    path: []const u8,
    headers: []const h2.Header,
    body: []const u8,
    fd: std.posix.fd_t,
    sid: u31,
) void {
    _ = method;

    const ct = grpc.detectContentType(headers);

    const grpc_path = grpc.parsePath(path) orelse {
        grpc.sendGrpcError(fd, sid, grpc.GRPC_UNIMPLEMENTED, "invalid path") catch {};
        return;
    };

    if (std.mem.eql(u8, grpc_path.package_service, "helloworld.Greeter") and
        std.mem.eql(u8, grpc_path.method, "SayHello"))
    {
        switch (ct) {
            .PROTO => sayHelloProto(body, fd, sid),
            .JSON => sayHelloJson(body, fd, sid),
            .UNKNOWN => grpc.sendGrpcError(fd, sid, grpc.GRPC_INVALID_ARGUMENT, "unsupported content-type") catch {},
        }
        return;
    }

    if (std.mem.eql(u8, grpc_path.package_service, "echo.EchoService") and
        std.mem.eql(u8, grpc_path.method, "Echo"))
    {
        echoJson(body, fd, sid);
        return;
    }

    grpc.sendGrpcError(fd, sid, grpc.GRPC_UNIMPLEMENTED, "unknown method") catch {};
}

fn sayHelloProto(body: []const u8, fd: std.posix.fd_t, sid: u31) void {
    const prefix = grpc.readGrpcPrefix(body) catch {
        grpc.sendGrpcError(fd, sid, grpc.GRPC_INVALID_ARGUMENT, "bad prefix") catch {};
        return;
    };
    if (body.len < 5 + @as(usize, prefix.msg_len)) {
        grpc.sendGrpcError(fd, sid, grpc.GRPC_INVALID_ARGUMENT, "truncated body") catch {};
        return;
    }
    const msg_bytes = body[5..][0..prefix.msg_len];

    var name: []const u8 = "";
    var reader = grpc.MessageReader.init(msg_bytes);
    while (reader.next() catch null) |field| {
        if (field.field_number == 1 and field.wire_type == grpc.WT_LEN)
            name = field.payload;
    }

    var msg_buf: [256]u8 = undefined;
    const message = std.fmt.bufPrint(&msg_buf, "Hello, {s}!", .{name}) catch "Hello!";

    var resp_buf: [512]u8 = undefined;
    const resp_len = grpc.encodeString(1, message, &resp_buf);

    grpc.sendGrpcHeaders(fd, sid, "application/grpc+proto") catch return;
    grpc.sendGrpcData(fd, sid, resp_buf[0..resp_len]) catch return;
    grpc.sendGrpcTrailer(fd, sid, grpc.GRPC_OK, "") catch {};
}

fn sayHelloJson(body: []const u8, fd: std.posix.fd_t, sid: u31) void {
    const prefix = grpc.readGrpcPrefix(body) catch {
        grpc.sendGrpcError(fd, sid, grpc.GRPC_INVALID_ARGUMENT, "bad prefix") catch {};
        return;
    };
    if (body.len < 5 + @as(usize, prefix.msg_len)) {
        grpc.sendGrpcError(fd, sid, grpc.GRPC_INVALID_ARGUMENT, "truncated body") catch {};
        return;
    }
    const json_bytes = body[5..][0..prefix.msg_len];

    const Request = struct { name: []const u8 };
    const req = std.json.parseFromSlice(
        Request,
        std.heap.smp_allocator,
        json_bytes,
        .{ .ignore_unknown_fields = true },
    ) catch {
        grpc.sendGrpcError(fd, sid, grpc.GRPC_INVALID_ARGUMENT, "bad json") catch {};
        return;
    };
    defer req.deinit();

    var msg_buf: [256]u8 = undefined;
    const message = std.fmt.bufPrint(&msg_buf, "Hello, {s}!", .{req.value.name}) catch "Hello!";

    var resp_json_buf: [512]u8 = undefined;
    const resp_json = std.fmt.bufPrint(&resp_json_buf, "{{\"message\":\"{s}\"}}", .{message}) catch "{}";

    grpc.sendGrpcHeaders(fd, sid, "application/grpc+json") catch return;
    grpc.sendGrpcData(fd, sid, resp_json) catch return;
    grpc.sendGrpcTrailer(fd, sid, grpc.GRPC_OK, "") catch {};
}

fn echoJson(body: []const u8, fd: std.posix.fd_t, sid: u31) void {
    const prefix = grpc.readGrpcPrefix(body) catch {
        grpc.sendGrpcError(fd, sid, grpc.GRPC_INVALID_ARGUMENT, "bad prefix") catch {};
        return;
    };
    if (body.len < 5 + @as(usize, prefix.msg_len)) {
        grpc.sendGrpcError(fd, sid, grpc.GRPC_INVALID_ARGUMENT, "truncated body") catch {};
        return;
    }
    const json_bytes = body[5..][0..prefix.msg_len];

    grpc.sendGrpcHeaders(fd, sid, "application/grpc+json") catch return;
    grpc.sendGrpcData(fd, sid, json_bytes) catch return;
    grpc.sendGrpcTrailer(fd, sid, grpc.GRPC_OK, "") catch {};
}

// ------------------------------------------------------------------ //
// Connection handler (shared by all models)                          //
// h2.serveConn already closes the stream internally.                 //
// ------------------------------------------------------------------ //

const ConnArgs = struct { stream: std.Io.net.Stream, io: std.Io };

fn handleConnection(args: ConnArgs) void {
    h2.serveConn(args.stream, args.io, grpcHandler);
}

// ------------------------------------------------------------------ //
// ASYNC model                                                         //
// ------------------------------------------------------------------ //

fn runAsync(ip: []const u8, port: u16, io: std.Io) !void {
    const addr = try std.Io.net.IpAddress.resolve(io, ip, port);
    var server = try addr.listen(io, .{
        .mode = .stream,
        .reuse_address = true,
        .kernel_backlog = 128,
    });
    defer server.deinit(io);

    std.debug.print("grpc server (async): {s}:{d}\n", .{ ip, port });

    while (true) {
        const stream = server.accept(io) catch |e| {
            if (e != error.ConnectionAborted)
                std.debug.print("grpc: accept error: {}\n", .{e});
            continue;
        };
        _ = io.async(handleConnection, .{ConnArgs{ .stream = stream, .io = io }});
    }
}

// ------------------------------------------------------------------ //
// POOL model                                                          //
// ------------------------------------------------------------------ //

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
        .reuse_address = true,
        .kernel_backlog = 128,
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

    std.debug.print("grpc server (pool): {s}:{d} ({d} accept, {d} pool)\n", .{
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

// ------------------------------------------------------------------ //
// MIXED model                                                         //
// ------------------------------------------------------------------ //

const MixedAcceptCtx = struct { io: std.Io, ip: []const u8, port: u16 };

fn mixedAcceptEntry(ctx: MixedAcceptCtx) void {
    const addr = std.Io.net.IpAddress.resolve(ctx.io, ctx.ip, ctx.port) catch return;
    var server = addr.listen(ctx.io, .{
        .mode = .stream,
        .reuse_address = true,
        .kernel_backlog = 128,
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

    std.debug.print("grpc server (mixed): {s}:{d} ({d} accept)\n", .{ ip, port, worker_count });

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

// ------------------------------------------------------------------ //
// main                                                                //
// ------------------------------------------------------------------ //

pub fn main(process: std.process.Init) !void {
    var ip: []const u8 = DEFAULT_IP;
    var port: u16 = DEFAULT_PORT;
    var model: []const u8 = DEFAULT_MODEL;

    var args = std.process.Args.Iterator.init(process.minimal.args);
    _ = args.next();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--ip")) {
            ip = args.next() orelse ip;
        } else if (std.mem.eql(u8, arg, "--port")) {
            const s = args.next() orelse continue;
            port = std.fmt.parseInt(u16, s, 10) catch port;
        } else if (std.mem.eql(u8, arg, "--model")) {
            model = args.next() orelse model;
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
