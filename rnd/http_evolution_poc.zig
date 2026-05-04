//! http_evolution_poc.zig
//! Prototype reflecting Top-Down Routing, Explicit Static, and Atomic Control.

const std = @import("std");

const Status = enum(u8) { idle, running, stopping, stopped };

// Explicit Context structure.
const Context = struct {
    io: std.Io,
    // Renamed from 'allocator' to reflect transience.
    request_arena: std.mem.Allocator,
    server: *HttpServer,
};

const HandlerFn = *const fn (ctx: *Context) anyerror!void;

// Modular static serving instead of hardcoded fallback.
const Static = struct {
    pub fn handler(dir: []const u8) HandlerFn {
        _ = dir; // logic to open file and stream...
        return struct {
            fn handle(ctx: *Context) anyerror!void {
                _ = ctx; // static serving logic here...
                std.debug.print("poc: explicitly serving static file\n", .{});
            }
        }.handle;
    }
};

const Route = struct {
    prefix: []const u8,
    handler: HandlerFn,
};

const HttpServer = struct {
    status: std.atomic.Value(Status) = std.atomic.Value(Status).init(.idle),
    routes: std.ArrayList(Route),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) HttpServer {
        return .{
            .routes = .empty,
            .allocator = allocator,
        };
    }

    // TOP-DOWN: First match wins. Simple and explicit.
    pub fn register(self: *HttpServer, prefix: []const u8, handler: HandlerFn) !void {
        try self.routes.append(self.allocator, .{ .prefix = prefix, .handler = handler });
    }

    pub fn stop(self: *HttpServer) void {
        self.status.store(.stopping, .release);
    }

    pub fn run(self: *HttpServer, io: std.Io) !void {
        self.status.store(.running, .release);

        // Simulating the Accept loop.
        while (self.status.load(.acquire) == .running) {
            // In real code: net_server.accept() with a timeout
            // or a check between connections.
            std.Io.sleep(io, std.Io.Duration.fromMilliseconds(100), .real) catch {};

            // Check status again after "blocking" call.
            if (self.status.load(.acquire) != .running) break;

            // Simulate one request.
            try self.dispatch(io, "/static/index.html");

            // Auto-stop for PoC.
            self.stop();
        }
    }

    fn dispatch(self: *HttpServer, io: std.Io, path: []const u8) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();

        var ctx = Context{
            .io = io,
            .request_arena = arena.allocator(),
            .server = self,
        };

        // Explicit Top-Down scan.
        for (self.routes.items) |route| {
            if (std.mem.startsWith(u8, path, route.prefix)) {
                try route.handler(&ctx);
                return;
            }
        }
        std.debug.print("poc: 404 Not Found for {s}\n", .{path});
    }
};

pub fn main(process: std.process.Init) !void {
    var server = HttpServer.init(std.heap.smp_allocator);

    // 1. Explicitly register static serving (removes 'magic' fallback).
    try server.register("/static", Static.handler("./public"));

    // 2. Explicitly register home.
    try server.register("/", struct {
        fn handle(ctx: *Context) !void {
            _ = ctx;
            std.debug.print("poc: serving home\n", .{});
        }
    }.handle);

    try server.run(process.io);
}
