const std = @import("std");
const Config = @import("config.zig").HttpServerConfig;
const Router = @import("router.zig").Router;
const HandlerFn = @import("router.zig").HandlerFn;
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;
const Context = @import("context.zig").Context;
const static = @import("static.zig");

// --------------------------------------------------------- //

fn handleConnection(stream: std.Io.net.Stream, io: std.Io, server: *HttpServer) void {
    defer stream.close(io);

    const cfg = server.config;

    // Heap-allocate I/O buffers using config sizes (max_client_request / max_client_response)
    const buf_read = std.heap.smp_allocator.alloc(u8, cfg.max_client_request) catch return;
    defer std.heap.smp_allocator.free(buf_read);
    const buf_write = std.heap.smp_allocator.alloc(u8, cfg.max_client_response) catch return;
    defer std.heap.smp_allocator.free(buf_write);

    var conn_reader = stream.reader(io, buf_read);
    var conn_writer = stream.writer(io, buf_write);
    var http_server = std.http.Server.init(&conn_reader.interface, &conn_writer.interface);

    // Per-connection arena; max_allocator_size is the initial backing allocation.
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();

    while (true) {
        _ = arena.reset(.retain_capacity);
        const allocator = arena.allocator();

        var inner_req = http_server.receiveHead() catch |err| {
            if (err == error.HttpConnectionClosing) break;
            if (err == error.ConnectionResetByPeer) break;
            break;
        };

        var req = Request{
            .inner = &inner_req,
            .reader = &conn_reader.interface,
            .allocator = allocator,
        };
        var res = Response.init(&inner_req, allocator);
        var ctx = Context{ .io = io, .allocator = allocator };

        const matched = server.router.dispatch(&req, &res, &ctx) catch false;
        if (!matched) {
            var served = false;
            if (cfg.public_dir.len > 0) {
                const sub = req.path();
                const stripped = if (sub.len > 0 and sub[0] == '/') sub[1..] else sub;
                if (stripped.len > 0) {
                    served = static.serve(&inner_req, stripped, cfg.public_dir, io) catch false;
                }
            }
            if (!served) {
                res.setStatus(.NOT_FOUND);
                res.send("Not Found") catch {};
            }
        }
    }
}

// --------------------------------------------------------- //

pub const HttpServer = struct {
    config: Config,
    router: Router,

    pub fn init(config: Config) !HttpServer {
        return .{
            .config = config,
            .router = Router.init(config.allocator),
        };
    }

    pub fn deinit(self: *HttpServer) void {
        self.router.deinit();
    }

    pub fn registerHandler(self: *HttpServer, path: []const u8, handler: HandlerFn) void {
        self.router.register(path, handler) catch |err| {
            std.debug.print("zix: registerHandler failed for '{s}': {}\n", .{ path, err });
        };
    }

    pub fn run(self: *HttpServer) !void {
        const cfg = self.config;
        const io = cfg.io;

        const addr = try std.Io.net.IpAddress.resolve(io, cfg.ip, cfg.port);
        var net_server = try addr.listen(io, .{
            .mode = .stream,
            .kernel_backlog = @intCast(cfg.max_kernel_backlog),
            .reuse_address = true,
        });
        defer net_server.deinit(io);

        std.debug.print("zix: listening on {s}:{d}\n", .{ cfg.ip, cfg.port });

        while (true) {
            const stream = net_server.accept(io) catch |err| {
                std.debug.print("zix: accept error: {}\n", .{err});
                continue;
            };

            _ = io.concurrent(handleConnection, .{ stream, io, self }) catch |err| {
                std.debug.print("zix: concurrent error: {}\n", .{err});
                stream.close(io);
            };
        }
    }
};
