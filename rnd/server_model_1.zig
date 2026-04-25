//! model 1
//! Zig 0.16.0-dev.3059+42e33db9d

//
// Design
//
// #-----------------------------------------------------------------#
// |                        Main Thread                              |
// |  #-----------------------------------------------------------#  |
// |  |  HttpServer.init()                                        |  |
// |  |                                                           |  |
// |  |  while (is_running):                                      |  |
// |  |      stream = net_server.accept()                         |  |
// |  |      #---------------------------------------------#      |  |
// |  |      |  std.Thread.spawn(handlers, stream)        |       |  |
// |  |      |  (detached)                                |       |  |
// |  |      #---------------------------------------------#      |  |
// |  |      (continues to next accept immediately)               |  |
// |  #-----------------------------------------------------------#  |
// #-----------------------------------------------------------------#
//         |                                   |
//         v                                   v
// #-----------------------------#   #-----------------------------#
// |   Connection Thread 1       |   |   Connection Thread N       |
// |  #-----------------------#  |   |  #-----------------------#  |
// |  |  handlers()           |  |   |  |  handlers()           |  |
// |  |                       |  |   |  |                       |  |
// |  |  - Arena (4KB)        |  |   |  |  - Arena (4KB)        |  |
// |  |  - Stack buffers      |  |   |  |  - Stack buffers      |  |
// |  |  - Keep‑alive loop    |  |   |  |  - Keep‑alive loop    |  |
// |  #-----------------------+  |   |  #-----------------------+  |
// |  (thread exits when         |   |  |  (thread exits when      |
// |   connection closes)        |   |  |   connection closes)     |
// #-----------------------------#   #-----------------------------#
//

const std = @import("std");

const IP: []const u8 = "127.0.0.1";
const PORT: u16 = 9001;
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

    io: std.Io,
    ip: []const u8,
    port: u16,
    net_server: std.Io.net.Server,
    allocator: std.heap.ArenaAllocator,
    is_running: bool,
    keep_alive: bool,

    pub fn init(io: std.Io, allocator: std.heap.ArenaAllocator, ip: []const u8, port: u16) !This {
        var threaded = std.Io.Threaded.init(allocator.child_allocator, .{});
        const thread_io = threaded.io();

        var address = std.Io.net.IpAddress.resolve(thread_io, ip, port) catch |err| {
            std.debug.print("Error: fail to resolve address: {}\n", .{err});
            return err;
        };

        const net_server = address.listen(io, .{
            .mode = .stream,
            .protocol = .tcp,
            .reuse_address = true,
            .kernel_backlog = MAX_KERNEL_BACKLOG,
        }) catch |err| {
            std.debug.print("Error: fail to listen address: {}\n", .{err});
            return err;
        };

        return .{
            .io = io,
            .ip = ip,
            .port = port,
            .net_server = net_server,
            .allocator = allocator,
            .is_running = false,
            .keep_alive = false,
        };
    }
    pub fn deinit(self: This) void {
        self.is_running = false;
        self.server.deinit(self.io);
    }

    pub fn run(self: *This) !void {
        if (@import("builtin").mode == .Debug) {
            std.debug.print("DEBUG MODE\n", .{});
        }
        std.debug.print("HttpServer running: {s}:{d}\n", .{ self.ip, self.port });
        defer self.net_server.deinit(self.io);

        self.is_running = true;
        self.keep_alive = true;

        while (self.is_running) {
            const stream = self.net_server.accept(self.io) catch |err| {
                std.debug.print("Error: fail to accept loop: {}\n", .{err});
                continue;
            };

            const thread = std.Thread.spawn(.{}, handlers, .{ self.io, stream, self.keep_alive }) catch |err| {
                std.debug.print("Error: fail spawn a thread: {}\n", .{err});
                stream.close(self.io);
                continue;
            };

            thread.detach();
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

    var server = try HttpServer.init(IO, ALLOCATOR, IP, PORT);

    try server.run();
}

//
// ➜ wrk -c100 -t2 -d10s http://localhost:9002/
// Running 10s test @ http://localhost:9002/
//   2 threads and 100 connections
//   Thread Stats   Avg      Stdev     Max   +/- Stdev
//     Latency   207.34us  207.70us  17.09ms   99.61%
//     Req/Sec   127.71k     4.03k  137.87k    77.00%
//   2541208 requests in 10.00s, 208.42MB read
// Requests/sec: 254072.04
// Transfer/sec:     20.84MB
//
