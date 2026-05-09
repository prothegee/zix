//! zix http server

const std = @import("std");
const Config = @import("config.zig").HttpServerConfig;
const Router = @import("router.zig").Router;
const HandlerFn = @import("router.zig").HandlerFn;
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;
const formatHttpDate = @import("response.zig").formatHttpDate;
const Context = @import("context.zig").Context;
const static = @import("static.zig");

// Global date cache — updated by a background timer thread (model 2) or the accept loop (model 1).
// Readers do a single atomic load — no lock, no syscall per request.
// Double-buffered so the writer never tears a read in progress.
var g_date_bufs: [2][40]u8 = undefined;
var g_date_lens: [2]usize = .{ 0, 0 };
var g_date_active = std.atomic.Value(usize).init(0);
var g_date_secs = std.atomic.Value(u64).init(0);

fn updateDateCache(io: std.Io) void {
    const ts = std.Io.Clock.real.now(io);
    const raw_secs = ts.toSeconds();
    const cur_secs: u64 = if (raw_secs >= 0) @intCast(raw_secs) else 0;
    if (cur_secs != g_date_secs.load(.monotonic)) {
        const next_idx = 1 - g_date_active.load(.monotonic);
        const s = formatHttpDate(cur_secs, &g_date_bufs[next_idx]);
        g_date_lens[next_idx] = s.len;
        g_date_active.store(next_idx, .release);
        g_date_secs.store(cur_secs, .release);
    }
}

fn timerLoop(io: std.Io) void {
    while (true) {
        updateDateCache(io);
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(500), .awake) catch break;
    }
}

// --------------------------------------------------------- //

// Work queue shared between accept threads (producers) and pool threads (consumers).
// Accept threads push accepted streams immediately and never block on handling.
// Pool threads pop and handle each connection synchronously (blocking I/O, no scheduler).
const ConnQueue = struct {
    mutex: std.Io.Mutex = .init,
    ready: std.Io.Condition = .init,
    // Uses smp_allocator directly — no per-request arena needed for the queue itself.
    items: std.ArrayListUnmanaged(std.Io.net.Stream) = .empty,
    closed: bool = false,

    // Push a new connection. On OOM the stream is closed and the connection dropped.
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

    // Pop the next connection, blocking until one arrives.
    // Returns null only after close() has been called and the queue is empty.
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

    // Signal all waiting pool threads to drain and exit.
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

// --------------------------------------------------------- //

// Internal generic implementation — use `Server.init(stack_threshold, config)` publicly.
fn HttpServerImpl(comptime stack_threshold: usize) type {
    return struct {
        config: Config,
        router: Router,

        const Self = @This();

        // --------------------------------------------------------- //

        /// Brief:
        /// Handle a single TCP connection with a keep-alive request loop
        ///
        /// Note:
        /// - Sets TCP_NODELAY immediately on accepted connection
        /// - Stack-allocates I/O buffers when config sizes fit within stack_threshold;
        ///   heap-allocates from smp_allocator otherwise
        /// - Per-connection arena is pre-warmed with max_allocator_size then reset
        ///   with retain_capacity before the loop — first request pays no heap cost
        /// - Date header refreshed from thread-local cache once per second
        /// - Falls back to static file serving if no route matches, sends 404 if neither matches
        ///
        /// Param:
        /// stream - std.Io.net.Stream
        /// io     - std.Io
        /// server - *Self
        fn handleConnection(stream: std.Io.net.Stream, io: std.Io, server: *Self) void {
            defer stream.close(io);

            // Disable Nagle's algorithm — sends each response immediately without
            // waiting to coalesce packets. Critical for throughput with small responses.
            if (comptime @import("builtin").target.os.tag != .windows) {
                std.posix.setsockopt(
                    stream.socket.handle,
                    std.posix.IPPROTO.TCP,
                    std.posix.TCP.NODELAY,
                    std.mem.asBytes(&@as(c_int, 1)),
                ) catch {};
            }

            const cfg = server.config;

            var stack_read: [stack_threshold]u8 = undefined;
            var stack_write: [stack_threshold]u8 = undefined;

            const buf_read = if (cfg.max_client_request <= stack_threshold)
                stack_read[0..cfg.max_client_request]
            else
                std.heap.smp_allocator.alloc(u8, cfg.max_client_request) catch return;
            defer if (cfg.max_client_request > stack_threshold) std.heap.smp_allocator.free(buf_read);

            const buf_write = if (cfg.max_client_response <= stack_threshold)
                stack_write[0..cfg.max_client_response]
            else
                std.heap.smp_allocator.alloc(u8, cfg.max_client_response) catch return;
            defer if (cfg.max_client_response > stack_threshold) std.heap.smp_allocator.free(buf_write);

            var conn_reader = stream.reader(io, buf_read);
            var conn_writer = stream.writer(io, buf_write);
            var http_server = std.http.Server.init(&conn_reader.interface, &conn_writer.interface);

            var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
            defer arena.deinit();
            _ = arena.allocator().alloc(u8, cfg.max_allocator_size) catch {};
            _ = arena.reset(.retain_capacity);

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
                var res = Response.init(&inner_req, io, allocator, cfg.max_response_headers.value());
                // Zero-syscall Date: atomic load from global cache; no clock call per request.
                const idx = g_date_active.load(.acquire);
                res.date_cache = g_date_bufs[idx][0..g_date_lens[idx]];
                var ctx = Context{ .io = io, .allocator = allocator, .stream = stream };

                const matched = server.router.dispatch(&req, &res, &ctx) catch false;
                if (res.streaming) break;
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

        /// Brief:
        /// Accept thread — accepts connections and enqueues them immediately.
        /// Never handles I/O; stays in the accept loop at all times.
        ///
        /// Note:
        /// - reuse_address = true sets SO_REUSEADDR + SO_REUSEPORT on POSIX,
        ///   allowing all accept threads to listen on the same port in parallel
        fn workerEntry(self: *Self, queue: *ConnQueue, io: std.Io) void {
            const cfg = self.config;

            const addr = std.Io.net.IpAddress.resolve(io, cfg.ip, cfg.port) catch |err| {
                std.debug.print("zix: worker resolve error: {}\n", .{err});
                return;
            };
            var net_server = addr.listen(io, .{
                .mode = .stream,
                .kernel_backlog = @intCast(cfg.max_kernel_backlog),
                .reuse_address = true,
            }) catch |err| {
                std.debug.print("zix: worker listen error: {}\n", .{err});
                return;
            };
            defer net_server.deinit(io);

            while (true) {
                const stream = net_server.accept(io) catch |err| {
                    std.debug.print("zix: worker accept error: {}\n", .{err});
                    continue;
                };
                queue.push(stream, io);
            }
        }

        /// Brief:
        /// Pool thread — pops connections from the queue and handles each one
        /// synchronously with blocking I/O (no scheduler, no fiber overhead).
        /// Exits when the queue is closed and drained.
        fn poolEntry(self: *Self, queue: *ConnQueue, io: std.Io) void {
            while (queue.pop(io)) |stream| {
                handleConnection(stream, io, self);
            }
        }

        // --------------------------------------------------------- //

        /// Brief:
        /// Initialize the HTTP server with the given config
        ///
        /// Param:
        /// config - HttpServerConfig
        ///
        /// Return:
        /// !Self
        pub fn init(config: Config) !Self {
            return .{
                .config = config,
                .router = Router.init(config.allocator),
            };
        }

        /// Brief:
        /// Free all router storage
        pub fn deinit(self: *Self) void {
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
        pub fn registerHandler(self: *Self, path: []const u8, handler: HandlerFn) void {
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
        pub fn registerPrefixHandler(self: *Self, prefix: []const u8, handler: HandlerFn) void {
            self.router.registerPrefix(prefix, handler) catch |err| {
                std.debug.print("zix: registerPrefixHandler failed for '{s}': {}\n", .{ prefix, err });
            };
        }

        /// Brief:
        /// Register a handler for a parameterized URL pattern
        ///
        /// Note:
        /// - Segments prefixed with ':' are named captures, others must match literally
        /// - "/users/:id" matches "/users/alice" and captures id="alice"
        /// - Access captured values inside the handler via req.pathParam("id")
        /// - Logs and swallows allocation errors at runtime
        ///
        /// Param:
        /// pattern - []const u8 (e.g. "/users/:id" or "/:tenant/:branch")
        /// handler - HandlerFn
        pub fn registerParamHandler(self: *Self, pattern: []const u8, handler: HandlerFn) void {
            self.router.registerParam(pattern, handler) catch |err| {
                std.debug.print("zix: registerParamHandler failed for '{s}': {}\n", .{ pattern, err });
            };
        }

        /// Brief:
        /// Start listening and accepting connections
        ///
        /// Note:
        /// - If config.public_dir is non-empty, validates the directory exists before binding;
        ///   returns error.PublicDirNotFound if not
        /// - workers = 0 (default): auto CPU count accept threads + cpu*2 pool threads (model 2)
        /// - workers = 1: single-threaded, uses the caller's io directly (model 1)
        /// - workers = N: exactly N accept threads in model 2
        /// - Model 2 accept threads listen on the same port via SO_REUSEPORT; pool threads handle
        ///   connections synchronously via a shared work queue
        ///
        /// Return:
        /// !void
        pub fn run(self: *Self) !void {
            const cfg = self.config;
            const io = cfg.io;

            if (cfg.public_dir.len > 0) {
                const dir = std.Io.Dir.openDir(std.Io.Dir.cwd(), io, cfg.public_dir, .{}) catch return error.PublicDirNotFound;
                dir.close(io);
            }

            // Accept threads only push to the work queue — they never handle I/O.
            // 2 is enough to saturate even a high-throughput listener; cpu_count accept
            // threads would add unnecessary OS threads without throughput benefit.
            const worker_count = if (cfg.workers == 0) 2 else cfg.workers;

            if (worker_count <= 1) {
                // Model 1 — single thread, caller's io
                std.debug.print("zix: listening on {s}:{d}\n", .{ cfg.ip, cfg.port });

                const addr = try std.Io.net.IpAddress.resolve(io, cfg.ip, cfg.port);
                var net_server = try addr.listen(io, .{
                    .mode = .stream,
                    .kernel_backlog = @intCast(cfg.max_kernel_backlog),
                    .reuse_address = true,
                });
                defer net_server.deinit(io);

                updateDateCache(io);
                while (true) {
                    updateDateCache(io);
                    const stream = net_server.accept(io) catch |err| {
                        std.debug.print("zix: accept error: {}\n", .{err});
                        continue;
                    };
                    if (io.concurrent(handleConnection, .{ stream, io, self })) |_| {} else |_| {
                        handleConnection(stream, io, self);
                    }
                }
            } else {
                // Model 2 — accept threads + pool threads connected by a work queue.
                // Pool threads handle connections synchronously (blocking I/O, no scheduler),
                // matching thread pool model. stack_size=512KB vs 8MB default reduces
                // virtual memory and TLB pressure; handleConnection only needs ~2×stack_threshold.
                const cpu = std.Thread.getCpuCount() catch 8;
                const pool_size = if (cfg.pool_size == 0) @max(10, cpu * 2) else cfg.pool_size;

                var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{
                    .stack_size = 512 * 1024,
                });
                defer threaded.deinit();
                const thread_io = threaded.io();

                var queue = ConnQueue{};
                defer queue.deinit();

                std.debug.print("zix: listening on {s}:{d} ({d} accept, {d} pool)\n", .{ cfg.ip, cfg.port, worker_count, pool_size });

                // Background timer thread: updates the global date cache every 500ms.
                // Keeps the per-request hot path to one atomic load instead of a clock syscall.
                const timer_thread = try std.Thread.spawn(.{}, timerLoop, .{thread_io});
                defer timer_thread.detach();

                // Pool threads: block on queue.pop(), handle synchronously
                const pool_threads = try std.heap.smp_allocator.alloc(std.Thread, pool_size);
                defer std.heap.smp_allocator.free(pool_threads);
                for (pool_threads) |*t| {
                    t.* = try std.Thread.spawn(
                        .{ .stack_size = 512 * 1024 },
                        poolEntry,
                        .{ self, &queue, thread_io },
                    );
                }

                // Accept threads: call accept() and push to queue, never block on I/O
                const acc_threads = try std.heap.smp_allocator.alloc(std.Thread, worker_count);
                defer std.heap.smp_allocator.free(acc_threads);
                for (acc_threads) |*t| {
                    t.* = try std.Thread.spawn(.{}, workerEntry, .{ self, &queue, thread_io });
                }

                for (acc_threads) |t| t.join();
                queue.close(thread_io);
                for (pool_threads) |t| t.join();
            }
        }
    };
}

// --------------------------------------------------------- //

/// Brief:
/// HTTP server — initialize with an explicit stack buffer threshold
///
/// Note:
/// - stack_threshold sets the cutoff for stack vs heap I/O buffers per connection:
///   if max_client_request / max_client_response fit within stack_threshold the
///   buffer lives on the connection thread stack; otherwise heap-allocated
/// - stack_threshold must be comptime so Zig can size the stack arrays at compile time
/// - workers in config controls the concurrency model:
///     0 (default) → auto CPU count accept threads + cpu*2 pool threads (model 2)
///     1           → single-threaded, uses caller's io (model 1)
///     N           → exactly N accept threads in model 2
///
/// Usage:
/// var server = try zix.Http.Server.init(4096, .{ .ip = "0.0.0.0", .port = 8080, ... });
pub const Server = struct {
    /// Brief:
    /// Initialize the HTTP server
    ///
    /// Param:
    /// stack_threshold - comptime usize: stack buffer size cutoff (e.g. 4096)
    /// config          - HttpServerConfig
    ///
    /// Return:
    /// !HttpServerImpl(stack_threshold)
    pub fn init(comptime stack_threshold: usize, config: Config) !HttpServerImpl(stack_threshold) {
        return HttpServerImpl(stack_threshold).init(config);
    }
};
