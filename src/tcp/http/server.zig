//! zix http server

const std = @import("std");
const Config = @import("config.zig").HttpServerConfig;
const Router = @import("router.zig").Router;
const HandlerFn = @import("router.zig").HandlerFn;
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;
const Context = @import("context.zig").Context;
const static = @import("static.zig");

// --------------------------------------------------------- //

/// Brief:
/// Handle a single TCP connection with a keep-alive request loop
///
/// Note:
/// - Heap-allocates I/O buffers from smp_allocator sized by config (max_client_request / max_client_response)
/// - Per-connection arena is reset each request; deinit on connection close
/// - Falls back to static file serving if no route matches; sends 404 if neither matches
///
/// Param:
/// stream - std.Io.net.Stream
/// io     - std.Io
/// server - *HttpServer
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

    /// Brief:
    /// Initialize the HTTP server with the given config
    ///
    /// Param:
    /// config - HttpServerConfig
    ///
    /// Return:
    /// !HttpServer
    pub fn init(config: Config) !HttpServer {
        return .{
            .config = config,
            .router = Router.init(config.allocator),
        };
    }

    /// Brief:
    /// Free all router storage
    pub fn deinit(self: *HttpServer) void {
        self.router.deinit();
    }

    /// Brief:
    /// Register a handler for an exact URL path
    ///
    /// Note:
    /// - Matches only when the request path equals path character-for-character
    /// - Logs and swallows allocation errors at runtime
    ///
    /// Param:
    /// path    - []const u8
    /// handler - HandlerFn
    pub fn registerHandler(self: *HttpServer, path: []const u8, handler: HandlerFn) void {
        self.router.register(path, handler) catch |err| {
            std.debug.print("zix: registerHandler failed for '{s}': {}\n", .{ path, err });
        };
    }

    /// Brief:
    /// Register a handler for a URL prefix and all sub-paths below it
    ///
    /// Note:
    /// - "/api" matches "/api", "/api/foo", "/api/foo/bar" but NOT "/apiv2"
    /// - Among multiple prefix routes, the longest matching prefix wins
    /// - Logs and swallows allocation errors at runtime
    ///
    /// Param:
    /// prefix  - []const u8 (no trailing slash)
    /// handler - HandlerFn
    pub fn registerPrefixHandler(self: *HttpServer, prefix: []const u8, handler: HandlerFn) void {
        self.router.registerPrefix(prefix, handler) catch |err| {
            std.debug.print("zix: registerPrefixHandler failed for '{s}': {}\n", .{ prefix, err });
        };
    }

    /// Brief:
    /// Register a handler for a parameterized URL pattern
    ///
    /// Note:
    /// - Segments prefixed with ':' are named captures; others must match literally
    /// - "/users/:id" matches "/users/alice" and captures id="alice"
    /// - Access captured values inside the handler via req.pathParam("id")
    /// - Logs and swallows allocation errors at runtime
    ///
    /// Param:
    /// pattern - []const u8 (e.g. "/users/:id" or "/:tenant/:branch")
    /// handler - HandlerFn
    pub fn registerParamHandler(self: *HttpServer, pattern: []const u8, handler: HandlerFn) void {
        self.router.registerParam(pattern, handler) catch |err| {
            std.debug.print("zix: registerParamHandler failed for '{s}': {}\n", .{ pattern, err });
        };
    }

    /// Brief:
    /// Start listening and accepting connections
    ///
    /// Note:
    /// - Blocks indefinitely; each accepted connection is spawned via io.concurrent()
    ///
    /// Return:
    /// !void
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
