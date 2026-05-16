//! model 2
//! Zig 0.16.0-dev.3059+42e33db9d

//
// Design
//
// #-----------------------------------------------------------------#
// |                        Main Thread                              |
// |  #-----------------------------------------------------------#  |
// |  |  HttpServer.init()                                        |  |
// |  |  (workers = CPU count)                                    |  |
// |  |                                                           |  |
// |  |  std.Io.Threaded.init() -> global thread pool             |  |
// |  |                                                           |  |
// |  |  Spawn N worker threads (startProcess)                    |  |
// |  |  Wait for all to join                                     |  |
// |  #-----------------------------------------------------------#  |
// #-----------------------------------------------------------------#
//    | (worker 1)          | (worker 2)          | (worker N)
//    v                     v                     v
// #-----------------#   #-----------------#   #-----------------#
// | Worker Thread 1 |   | Worker Thread 2 |   | Worker Thread N |
// | #-------------# |   | #-------------# |   | #-------------# |
// | | listen()    | |   | | listen()    | |   | | listen()    | |
// | | (SO_REUSE*) | |   | | (SO_REUSE*) | |   | | (SO_REUSE*) | |
// | #-------------# |   | #-------------# |   | #-------------# |
// |                 |   |                 |   |                 |
// | while(running): |   | while(running): |   | while(running): |
// |   accept()      |   |   accept()      |   |   accept()      |
// |   |             |   |   |             |   |   |             |
// |   v             |   |   v             |   |   v             |
// | #---------------#   #-----------------#   #-----------------#
// | | concurrent    |   | concurrent      |   | concurrent      |
// | | handlers      |   | handlers        |   | handlers        |
// | #---------------#   #-----------------#   #-----------------#
// | (submit to pool)|   |(submit to pool) |   |(submit to pool) |
// #-----------------#   #-----------------#   #-----------------#
//       |                       |                       |
//       v                       v                       v
// #-----------------------------------------------------------------#
// |                 Global Thread Pool (std.Io.Threaded)            |
// |  #-----------------------------------------------------------#  |
// |  |  Fixed number of worker threads (reused)                  |  |
// |  |                                                           |  |
// |  |  For each submitted handler task:                         |  |
// |  |      #---------------------------------------------#      |  |
// |  |      |  handlers(io, stream, keep_alive)           |      |  |
// |  |      |  (runs on any available pool thread)        |      |  |
// |  |      |  - Arena allocator per call                 |      |  |
// |  |      |  - Stack buffers                            |      |  |
// |  |      |  - Keep‑alive loop inside                   |      |  |
// |  |      #---------------------------------------------#      |  |
// |  #-----------------------------------------------------------#  |
// #-----------------------------------------------------------------#
//

const std = @import("std");

const IP: []const u8 = "127.0.0.1";
const PORT: u16 = 9002;
const WORKERS: usize = 0;
const MAX_KERNEL_BACKLOG: usize = 1024 * 4;
const MAX_CLIENT_REQUEST: usize = 1024 * 4;
const MAX_ALLOCATOR_SIZE: usize = 1024 * 4;
const MAX_CLIENT_RESPONSE: usize = 1024 * 4;

// --------------------------------------------------------- //

const Template = struct {
    pub const page_ok =
        \\OK
    ;
    pub const page_not_found =
        \\Not Found
    ;
    pub const page_method_not_allowed =
        \\Method Not Allowed
    ;
};

// --------------------------------------------------------- //

fn handlers(io: std.Io, stream: std.Io.net.Stream, keep_alive: bool) void {
    defer stream.close(io);

    var buf_read: [MAX_CLIENT_REQUEST]u8 = undefined;
    var buf_write: [MAX_CLIENT_REQUEST]u8 = undefined;

    var read = stream.reader(io, &buf_read);
    var write = stream.writer(io, &buf_write);

    var server = std.http.Server.init(&read.interface, &write.interface);

    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    var resp = std.ArrayList(u8).initCapacity(allocator, MAX_CLIENT_REQUEST) catch |err| {
        std.debug.print("Error: fail to init resp capacity: {}\n", .{err});
        return;
    };

    while (keep_alive) {
        var req = server.receiveHead() catch |err| {
            if (err == error.HttpConnectionClosing) break;
            if (err == error.ConnectionResetByPeer) break;
            break;
        };
        var path = if (std.mem.indexOfScalar(u8, req.head.target, '?')) |pos|
            req.head.target[0..pos]
        else
            req.head.target;
        if (path.len == 0) path = "/";

        resp.clearRetainingCapacity();

        const body =
            if (std.mem.eql(u8, path, "/"))
                if (req.head.method == .GET)
                    Template.page_ok
                else
                    Template.page_method_not_allowed
            else
                Template.page_not_found;

        // IMPORTANT:
        // - Current reponse lack of header/s
        // - Performance good

        resp.appendSlice(allocator, body) catch |err| {
            std.debug.print("Error: resp append slice {}\n", .{err});
            return;
        };

        req.respond(body, .{}) catch |err| {
            std.debug.print("Error: req.respond err: {}\n", .{err});
            return;
        };

        req.server.out.writeAll(resp.items) catch |err| {
            std.debug.print("Error: resp write error: {}\n", .{err});
            return;
        };
        req.server.out.flush() catch |err| {
            std.debug.print("Error: resp flush error: {}\n", .{err});
            return;
        };
    }
}

// --------------------------------------------------------- //

const HttpServer = struct {
    const This = @This();

    var io: std.Io = undefined;
    var threaded: std.Io.Threaded = undefined;
    var allocator: std.heap.ArenaAllocator = undefined;

    var net_server: std.Io.net.Server = undefined;
    var net_address: std.Io.net.IpAddress = undefined;
    var net_stream: std.Io.net.Stream = undefined;

    ip: []const u8,
    port: u16,
    is_running: bool,
    keep_alive: bool,
    workers: usize,

    pub fn init(sio: std.Io, arena: std.heap.ArenaAllocator, ip: []const u8, port: u16, workers: usize) !This {
        This.io = sio;
        This.allocator = arena;

        const actual_workers =
            if (workers == 0)
                try std.Thread.getCpuCount()
            else
                workers;

        return .{ .ip = ip, .port = port, .is_running = false, .keep_alive = false, .workers = actual_workers };
    }
    pub fn deinit(self: This) void {
        self.is_running = false;
        self.server.deinit(self.io);
    }

    pub fn run(self: *This) !void {
        This.threaded = std.Io.Threaded.init(This.allocator.child_allocator, .{});
        defer This.threaded.deinit();

        const workers_msg =
            if (self.workers == 1)
                "worker"
            else
                "workers";
        if (@import("builtin").mode == .Debug) {
            std.debug.print("DEBUG MODE\n", .{});
        }
        std.debug.print("HttpServer running: {s}:{d} ({d} {s})\n", .{ self.ip, self.port, self.workers, workers_msg });

        self.is_running = true;
        self.keep_alive = true;

        const threads = try This.allocator.child_allocator.alloc(std.Thread, self.workers);
        defer This.allocator.child_allocator.free(threads);

        for (threads) |*t| {
            t.* = try std.Thread.spawn(.{}, startProcess, .{self});
        }
        for (threads) |t| {
            t.join();
        }
    }

    fn startProcess(self: *This) !void {
        This.net_address = std.Io.net.IpAddress.resolve(This.io, self.ip, self.port) catch |err| {
            return err;
        };

        This.net_server = This.net_address.listen(This.io, .{
            .mode = .stream,
            .protocol = .tcp,
            .reuse_address = true,
            .kernel_backlog = MAX_KERNEL_BACKLOG,
        }) catch |err| {
            std.debug.print("Error: fail to listen address: {}\n", .{err});
            return err;
        };
        defer This.net_server.deinit(This.io);

        while (self.is_running) {
            This.net_stream = This.net_server.accept(This.io) catch |err| {
                std.debug.print("Error: fail to accept loop: {}\n", .{err});
                continue;
            };

            _ = This.threaded.io().concurrent(handlers, .{ This.io, This.net_stream, self.keep_alive }) catch |err| {
                std.debug.print("Error: fail io concurrent: {}\n", .{err});
                This.net_stream.close(This.io);
            };
        } else {
            std.process.exit(1);
        }
    }
};

// --------------------------------------------------------- //

pub fn main(process: std.process.Init) !void {
    const IO = process.io;
    const ALLOCATOR = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer ALLOCATOR.deinit();

    var server = try HttpServer.init(IO, ALLOCATOR, IP, PORT, WORKERS);

    try server.run();
}

//
// ➜ wrk -c100 -t2 -d10s http://localhost:9003/
// Running 10s test @ http://localhost:9003/
//   2 threads and 100 connections
//   Thread Stats   Avg      Stdev     Max   +/- Stdev
//     Latency    38.91us   20.88us   4.02ms   84.29%
//     Req/Sec   124.77k     5.31k  138.64k    62.00%
//   2481905 requests in 10.00s, 203.56MB read
// Requests/sec: 248159.80
// Transfer/sec:     20.35MB
//
