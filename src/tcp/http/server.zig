//! zix http server: the public Server type and the dispatch_model switch. The
//! shared request pipeline and the per-model dispatch loops live under dispatch/
//! (ADR-043). The server holds the comptime-baked router plus the connection
//! registry, run() spawns the date/eviction timer and hands off to the model.

const std = @import("std");
const builtin = @import("builtin");
const Config = @import("config.zig").HttpServerConfig;
const DispatchModel = @import("config.zig").DispatchModel;
const Router = @import("router.zig").Router;
const Route = @import("router.zig").Route;
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;
const Context = @import("context.zig").Context;
const rcache = @import("../../utils/response_cache.zig");
const setCache = @import("response.zig").setCache;
const common = @import("dispatch/common.zig");
const pool_model = @import("dispatch/pool.zig");
const async_model = @import("dispatch/async.zig");
const mixed_model = @import("dispatch/mixed.zig");
const epoll_model = @import("dispatch/epoll.zig");
const uring_model = @import("dispatch/uring.zig");
const tls_serve = @import("tls_serve.zig");
const tls_mux = @import("tls_mux.zig");

// --------------------------------------------------------- //

// Internal generic implementation: use `Server.init(stack_threshold, routes, config)` publicly.
fn HttpServerImpl(comptime stack_threshold: usize, comptime routes: []const Route) type {
    return struct {
        config: Config,
        router: Router(routes) = .{},
        registry: common.ConnRegistry = .{},

        const Self = @This();

        /// Stack buffer cutoff, read by dispatch/common.handleConnection to size
        /// the per-connection read buffer when it fits on the thread stack.
        pub const stack_buf_threshold = stack_threshold;

        // --------------------------------------------------------- //

        /// Parse and dispatch one complete HTTP request from buf. Thin delegate to
        /// the shared pipeline (dispatch/common.processRequest), kept as a method so
        /// callers and tests can drive a single request without a live socket loop.
        ///
        /// Return:
        /// - .keep_alive when the connection may serve another request
        /// - .close on error, streaming, unconsumed body, Connection: close, or peer hangup
        pub fn processRequest(
            self: *Self,
            stream: std.Io.net.Stream,
            fd: std.posix.fd_t,
            io: std.Io,
            buf: []u8,
            arena: *std.heap.ArenaAllocator,
        ) common.ReqOutcome {
            return common.processRequest(self, stream, fd, io, buf, arena);
        }

        /// Initialize the HTTP server with the given config
        ///
        /// Param:
        /// config - HttpServerConfig
        ///
        /// Return:
        /// - !Self
        pub fn init(config: Config) !Self {
            return .{ .config = config };
        }

        /// Free registry storage
        pub fn deinit(self: *Self) void {
            self.registry.deinit();
        }

        /// Start listening and accepting connections
        ///
        /// Note:
        /// - workers = 0 (default): cpu_count accept threads + max(10, cpu_count * 2) pool threads
        /// - workers = N: exactly N accept threads, same pool sizing formula
        /// - If config.public_dir is non-empty, validates the directory exists. Yields error.PublicDirNotFound if absent
        /// - Accept threads listen on the same port via SO_REUSEPORT
        /// - Pool threads handle connections synchronously via a shared work queue
        ///
        /// Return:
        /// - !void
        pub fn run(self: *Self) !void {
            const cfg = self.config;
            const cpu = try std.Thread.getCpuCount();

            const thread_io: std.Io = cfg.io;

            if (cfg.public_dir.len > 0) {
                const dir = std.Io.Dir.openDir(std.Io.Dir.cwd(), thread_io, cfg.public_dir, .{}) catch return error.PublicDirNotFound;
                dir.close(thread_io);
            }

            // Background timer: updates date cache every 500ms, evicts timed-out connections.
            const timer_thread = try std.Thread.spawn(.{}, common.timerLoop, .{ thread_io, &self.registry });
            defer timer_thread.detach();

            const effective_model: DispatchModel = blk: {
                if (comptime builtin.target.os.tag != .linux) {
                    // EPOLL and URING are Linux-only: fall back to POOL elsewhere.
                    if (cfg.dispatch_model == .EPOLL or cfg.dispatch_model == .URING) {
                        common.logSystem(cfg, "EPOLL/URING are Linux-only. Falling back to POOL.", .{});
                        break :blk .POOL;
                    }
                }
                break :blk cfg.dispatch_model;
            };

            // https opt-in (config.tls): terminate TLS on a gated path, the cleartext models above
            // are untouched. EPOLL / URING multiplex TLS in the event-driven worker (one SO_REUSEPORT
            // epoll worker per core, many connections each), the thread models hand each connection to
            // its own worker thread.
            if (cfg.tls != null) {
                if (effective_model == .EPOLL or effective_model == .URING) {
                    return tls_mux.runTlsMux(self, thread_io);
                }
                return tls_serve.runTls(self, thread_io);
            }

            switch (effective_model) {
                .POOL => try pool_model.runPool(self, thread_io, cpu),
                .ASYNC => try async_model.runAsync(self, thread_io),
                .MIXED => try mixed_model.runMixed(self, thread_io, cpu),
                .EPOLL => try epoll_model.runEpoll(self, thread_io),
                // Native io_uring ring path (ADR-037 Phase 4 step 4).
                .URING => try uring_model.runUring(self, thread_io),
            }
        }
    };
}

// --------------------------------------------------------- //

/// HTTP server: initialize with a comptime stack buffer threshold and comptime route table
///
/// Note:
/// - stack_threshold sets the cutoff for stack vs heap I/O buffers per connection:
///   if max_recv_buf fits within stack_threshold the buffer lives on the
///   connection thread stack, otherwise heap-allocated
/// - stack_threshold must be comptime so Zig can size the stack arrays at compile time
/// - routes must be comptime: the router is baked into the server type at compile time
///   (no heap allocation, no dynamic registration after init)
/// - workers in config controls accept thread count:
///   0 (default) = cpu_count accept threads, max(10, cpu_count * 2) pool threads.
///   N           = exactly N accept threads, same pool sizing formula.
///
/// Usage:
/// ```zig
/// var server = try zix.Http.Server.init(4096, &[_]zix.Http.Route{
///     .{ .path = "/",      .handler = homeHandler },
///     .{ .path = "/api",   .handler = apiHandler,  .kind = .PREFIX },
///     .{ .path = "/u/:id", .handler = userHandler, .kind = .PARAM },
/// }, .{ .ip = "0.0.0.0", .port = 8080, ... });
/// ```
pub const Server = struct {
    /// Initialize the HTTP server
    ///
    /// Param:
    /// stack_threshold - comptime usize (stack buffer size cutoff, e.g. 4096)
    /// routes - comptime []const Route (route table baked into server type)
    /// config - HttpServerConfig
    ///
    /// Return:
    /// - !HttpServerImpl(stack_threshold, routes)
    pub fn init(
        comptime stack_threshold: usize,
        comptime routes: []const Route,
        config: Config,
    ) !HttpServerImpl(stack_threshold, routes) {
        return HttpServerImpl(stack_threshold, routes).init(config);
    }
};

// --------------------------------------------------------- //
// --------------------------------------------------------- //

test "zix http: EpollConnTable slab alloc and free lifecycle" {
    var table = try common.EpollConnTable.init(256);
    defer table.deinit();

    try std.testing.expectEqual(@as(?*common.EpollConn, null), table.get(5));

    const conn = table.alloc(5).?;
    try std.testing.expectEqual(@as(std.posix.fd_t, 5), conn.fd);
    try std.testing.expectEqual(@as(usize, 256), conn.buf.len);
    try std.testing.expectEqual(@as(usize, 0), conn.filled);

    const got = table.get(5).?;
    try std.testing.expectEqual(conn, got);

    table.free(5);
    try std.testing.expectEqual(@as(?*common.EpollConn, null), table.get(5));

    table.free(5);
}

test "zix http: EpollConnTable filled tracks accumulated bytes" {
    var table = try common.EpollConnTable.init(512);
    defer table.deinit();

    const conn = table.alloc(10).?;
    conn.filled = 42;
    try std.testing.expectEqual(@as(usize, 42), table.get(10).?.filled);

    table.free(10);
    try std.testing.expectEqual(@as(?*common.EpollConn, null), table.get(10));
}

test "zix http: EpollConnTable get returns null for out-of-range fd" {
    var table = try common.EpollConnTable.init(64);
    defer table.deinit();

    try std.testing.expectEqual(@as(?*common.EpollConn, null), table.get(common.MAX_FD));
    try std.testing.expectEqual(@as(?*common.EpollConn, null), table.alloc(common.MAX_FD));
}

test "zix http: getAvailableCpuCount returns at least 1" {
    const count = common.getAvailableCpuCount();
    try std.testing.expect(count >= 1);
}

test "zix http: effectiveCacheEntries honors the memory ceiling" {
    const base = Config{ .io = undefined, .ip = "127.0.0.1", .port = 0, .dispatch_model = .ASYNC, .cache_max_entries = 1024, .cache_max_value_bytes = 16 * 1024 };

    // no ceiling: the configured entry count passes through unchanged
    try std.testing.expectEqual(@as(u32, 1024), common.effectiveCacheEntries(base));

    // ceiling caps the entry count so entries * value_bytes fits
    var capped = base;
    capped.cache_max_total_bytes = 256 * 1024;
    try std.testing.expectEqual(@as(u32, 16), common.effectiveCacheEntries(capped));

    // a tiny ceiling still yields at least one slot
    var tiny = base;
    tiny.cache_max_total_bytes = 1;
    try std.testing.expectEqual(@as(u32, 1), common.effectiveCacheEntries(tiny));
}

fn cacheRouteHandler(req: *Request, res: *Response, _: *Context) anyerror!void {
    if (res.serveCached(req)) return;

    try res.sendCached(req, "cached-body", 0);
}

test "zix http: EPOLL processRequest serves a cache miss then a hit" {
    var cache = try rcache.ResponseCache.init(std.testing.allocator, .{ .max_entries = 16, .max_value_bytes = 256 });
    defer cache.deinit();

    setCache(&cache, 1000);
    defer setCache(null, 0);

    const routes = [_]Route{.{ .path = "/cached", .handler = cacheRouteHandler }};
    const ServerImpl = HttpServerImpl(4096, &routes);
    var server = try ServerImpl.init(.{ .io = undefined, .ip = "127.0.0.1", .port = 0, .dispatch_model = .ASYNC, .response_cache = true });
    defer server.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var fds: [2]i32 = undefined;
    try std.testing.expectEqual(@as(usize, 0), std.os.linux.socketpair(std.os.linux.AF.UNIX, std.os.linux.SOCK.STREAM, 0, &fds));
    defer _ = std.os.linux.close(fds[0]);
    defer _ = std.os.linux.close(fds[1]);

    const stream = std.Io.net.Stream{ .socket = .{ .handle = fds[1], .address = undefined } };
    const raw = "GET /cached HTTP/1.1\r\nHost: x\r\n\r\n";

    // first request: cache miss, handler builds and stores the response
    var buf1: [128]u8 = undefined;
    @memcpy(buf1[0..raw.len], raw);
    _ = arena.reset(.retain_capacity);
    _ = server.processRequest(stream, fds[1], undefined, buf1[0..raw.len], &arena);

    var first: [256]u8 = undefined;
    const n1 = try std.posix.read(fds[0], &first);
    try std.testing.expect(std.mem.endsWith(u8, first[0..n1], "\r\n\r\ncached-body"));

    // second request: cache hit, identical bytes served with no rebuild
    var buf2: [128]u8 = undefined;
    @memcpy(buf2[0..raw.len], raw);
    _ = arena.reset(.retain_capacity);
    _ = server.processRequest(stream, fds[1], undefined, buf2[0..raw.len], &arena);

    var second: [256]u8 = undefined;
    const n2 = try std.posix.read(fds[0], &second);
    try std.testing.expectEqualStrings(first[0..n1], second[0..n2]);

    // the entry is present and fresh
    try std.testing.expect(cache.lookup(rcache.hashKey("GET", "/cached", ""), rcache.nowMillis()) != null);
}
