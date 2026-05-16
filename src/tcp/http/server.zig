//! zix http server

const std = @import("std");
const Config = @import("config.zig").HttpServerConfig;
const DispatchModel = @import("config.zig").DispatchModel;
const Router = @import("router.zig").Router;
const HandlerFn = @import("router.zig").HandlerFn;
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;
const fdWriteAll = @import("response.zig").fdWriteAll;
const formatHttpDate = @import("response.zig").formatHttpDate;
const Context = @import("context.zig").Context;
const static = @import("static.zig");
const parser = @import("parser.zig");

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

// --------------------------------------------------------- //
// Layer D: connection registry + timer eviction
// --------------------------------------------------------- //

const ConnEntry = struct {
    stream: std.Io.net.Stream,
    deadline: std.Io.Clock.Timestamp,
    done: std.atomic.Value(bool) = .init(false),
};

const ConnRegistry = struct {
    mutex: std.Io.Mutex = .init,
    entries: std.ArrayListUnmanaged(*ConnEntry) = .empty,

    fn register(self: *ConnRegistry, entry: *ConnEntry, io: std.Io) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.entries.append(std.heap.smp_allocator, entry) catch {};
    }

    fn deregister(self: *ConnRegistry, entry: *ConnEntry, io: std.Io) void {
        entry.done.store(true, .release);
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        for (self.entries.items, 0..) |e, i| {
            if (e == entry) {
                _ = self.entries.swapRemove(i);
                break;
            }
        }
    }

    fn evict(self: *ConnRegistry, io: std.Io) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const now = std.Io.Clock.Timestamp.now(io, .real);
        for (self.entries.items) |e| {
            if (!e.done.load(.acquire) and now.compare(.gte, e.deadline))
                e.stream.shutdown(io, .both) catch {};
        }
    }

    fn deinit(self: *ConnRegistry) void {
        self.entries.deinit(std.heap.smp_allocator);
    }
};

// --------------------------------------------------------- //

fn timerLoop(io: std.Io, registry: *ConnRegistry) void {
    while (true) {
        updateDateCache(io);
        registry.evict(io);
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
        registry: ConnRegistry = .{},

        const Self = @This();

        // --------------------------------------------------------- //

        /// Brief:
        /// Handle a single TCP connection with a keep-alive request loop
        ///
        /// Note:
        /// - Sets TCP_NODELAY immediately on accepted connection
        /// - Stack-allocates I/O buffers when config sizes fit within stack_threshold
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

            // Disable Nagle: each response is sent immediately without waiting to coalesce.
            if (comptime @import("builtin").target.os.tag != .windows) {
                std.posix.setsockopt(
                    stream.socket.handle,
                    std.posix.IPPROTO.TCP,
                    std.posix.TCP.NODELAY,
                    std.mem.asBytes(&@as(c_int, 1)),
                ) catch {};
            }

            const cfg = server.config;
            // Raw fd — all recv/send on the hot path bypass std.Io dispatch.
            const fd = stream.socket.handle;

            // Layer D: connection guard via registry eviction (model 2 only).
            var maybe_conn_entry: ?ConnEntry = null;
            if (cfg.conn_timeout_ms > 0) {
                maybe_conn_entry = ConnEntry{
                    .stream = stream,
                    .deadline = std.Io.Clock.Timestamp.fromNow(
                        io,
                        std.Io.Clock.Duration{ .raw = std.Io.Duration.fromMilliseconds(cfg.conn_timeout_ms), .clock = .real },
                    ),
                };
                server.registry.register(&maybe_conn_entry.?, io);
            }
            defer if (maybe_conn_entry != null) server.registry.deregister(&maybe_conn_entry.?, io);

            // Read buffer: stack when max_client_request <= stack_threshold, heap otherwise.
            var stack_read: [stack_threshold]u8 = undefined;
            const buf_read = if (cfg.max_client_request <= stack_threshold)
                stack_read[0..cfg.max_client_request]
            else
                std.heap.smp_allocator.alloc(u8, cfg.max_client_request) catch return;
            defer if (cfg.max_client_request > stack_threshold) std.heap.smp_allocator.free(buf_read);

            var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
            defer arena.deinit();
            _ = arena.allocator().alloc(u8, cfg.max_allocator_size) catch {};
            _ = arena.reset(.retain_capacity);

            while (true) {
                _ = arena.reset(.retain_capacity);
                const allocator = arena.allocator();

                // Incremental recv loop: accumulate bytes until \r\n\r\n is found.
                // Only the new tail is searched each iteration to avoid re-scanning.
                var filled: usize = 0;
                var header_end: usize = 0;
                var found = false;

                while (filled < buf_read.len) {
                    const n = std.posix.read(fd, buf_read[filled..]) catch break;
                    if (n == 0) break; // peer closed
                    const prev = filled;
                    filled += n;
                    const search_from = if (prev > 3) prev - 3 else 0;
                    if (std.mem.indexOfPos(u8, buf_read[0..filled], search_from, "\r\n\r\n")) |pos| {
                        header_end = pos;
                        found = true;
                        break;
                    }
                }

                if (!found) {
                    if (filled >= buf_read.len) {
                        fdWriteAll(fd, "HTTP/1.1 431 Request Header Fields Too Large\r\nContent-Length: 0\r\n\r\n") catch {};
                    }
                    break;
                }

                // Zero-copy parse: all fields are offsets into buf_read.
                const head = parser.parse(buf_read[0..filled], cfg.max_request_headers.value()) catch {
                    fdWriteAll(fd, "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n") catch {};
                    break;
                } orelse break; // incomplete — should not happen since found == true

                var req = Request{
                    .buf        = buf_read[0..filled],
                    .head       = head,
                    .fd         = fd,
                    .buf_filled = filled,
                    .allocator  = allocator,
                };
                var res = Response.init(fd, head.keep_alive, io, allocator, cfg.max_response_headers.value());

                // Zero-syscall Date: one atomic load from the global double-buffered cache.
                const idx = g_date_active.load(.acquire);
                res.date_cache = g_date_bufs[idx][0..g_date_lens[idx]];

                var ctx = Context{ .io = io, .allocator = allocator, .stream = stream };
                // Layer B: optional handler deadline. Handlers call ctx.timedOut() between steps.
                if (cfg.handler_timeout_ms > 0) ctx = ctx.withTimeout(cfg.handler_timeout_ms);

                const matched = server.router.dispatch(&req, &res, &ctx) catch false;
                if (res.streaming) break;

                if (!matched) {
                    var served = false;
                    if (cfg.public_dir.len > 0) {
                        const sub = req.path();
                        const stripped = if (sub.len > 0 and sub[0] == '/') sub[1..] else sub;
                        if (stripped.len > 0) {
                            served = static.serve(&req, fd, stripped, cfg.public_dir, io) catch false;
                        }
                    }
                    if (!served) {
                        res.setStatus(.NOT_FOUND);
                        res.send("Not Found") catch {};
                    }
                }

                // Keep-alive: if there is a body and the handler did not consume it,
                // close rather than risk misaligned reads on the next request.
                if (head.content_length > 0 and req.body_cache == null) break;
            }
        }

        // --------------------------------------------------------- //

        /// Brief:
        /// Accept thread — accepts connections and enqueues them immediately.
        /// Never handles I/O stays in the accept loop at all times.
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
                    if (err != error.ConnectionAborted) {
                        std.debug.print("zix: worker accept error: {}\n", .{err});
                        break;
                    }
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

        /// Brief:
        /// Accept thread for MIXED dispatch — accepts connections and dispatches each via io.async().
        /// No ConnQueue. The shared io Threaded pool handles scheduling.
        fn asyncWorkerEntry(self: *Self, io: std.Io) void {
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
                    if (err != error.ConnectionAborted) {
                        std.debug.print("zix: worker accept error: {}\n", .{err});
                        break;
                    }
                    continue;
                };
                _ = io.async(handleConnection, .{ stream, io, self });
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
        /// Free all router and registry storage
        pub fn deinit(self: *Self) void {
            self.router.deinit();
            self.registry.deinit();
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
        /// - workers = 0 (default): cpu_count accept threads + cpu_count*20 pool threads
        /// - workers = N: exactly N accept threads, same pool sizing formula
        /// - If config.public_dir is non-empty, validates the directory exists, returns error.PublicDirNotFound if not
        /// - Accept threads listen on the same port via SO_REUSEPORT
        /// - Pool threads handle connections synchronously via a shared work queue
        ///
        /// Return:
        /// !void
        pub fn run(self: *Self) !void {
            const cfg = self.config;
            const cpu = try std.Thread.getCpuCount();

            // Use caller's io if provided; otherwise create an internal Threaded backend.
            // Caller-provided io: async_limit and stack_size from InitOptions are respected.
            // Internal: stack_size=512KB reduces virtual memory and TLB pressure.
            var internal: ?std.Io.Threaded = if (cfg.io == null)
                std.Io.Threaded.init(std.heap.smp_allocator, .{ .stack_size = 512 * 1024 })
            else
                null;
            defer if (internal) |*t| t.deinit();
            const thread_io: std.Io = cfg.io orelse internal.?.io();

            if (cfg.public_dir.len > 0) {
                const dir = std.Io.Dir.openDir(std.Io.Dir.cwd(), thread_io, cfg.public_dir, .{}) catch return error.PublicDirNotFound;
                dir.close(thread_io);
            }

            // Background timer: updates date cache every 500ms, evicts timed-out connections.
            const timer_thread = try std.Thread.spawn(.{}, timerLoop, .{ thread_io, &self.registry });
            defer timer_thread.detach();

            switch (cfg.dispatch_model) {
                .POOL => {
                    const worker_count = if (cfg.workers == 0) cpu else cfg.workers;
                    const pool_size    = if (cfg.pool_size == 0) @max(10, cpu * 2) else cfg.pool_size;

                    std.debug.print("zix: listening on {s}:{d} ({d} accept, {d} pool)\n", .{ cfg.ip, cfg.port, worker_count, pool_size });

                    var queue = ConnQueue{};
                    defer queue.deinit();

                    const pool_threads = try std.heap.smp_allocator.alloc(std.Thread, pool_size);
                    defer std.heap.smp_allocator.free(pool_threads);
                    for (pool_threads) |*t| {
                        t.* = try std.Thread.spawn(
                            .{ .stack_size = 512 * 1024 },
                            poolEntry,
                            .{ self, &queue, thread_io },
                        );
                    }

                    const acc_threads = try std.heap.smp_allocator.alloc(std.Thread, worker_count);
                    defer std.heap.smp_allocator.free(acc_threads);
                    for (acc_threads) |*t| {
                        t.* = try std.Thread.spawn(.{}, workerEntry, .{ self, &queue, thread_io });
                    }

                    for (acc_threads) |t| t.join();
                    queue.close(thread_io);
                    for (pool_threads) |t| t.join();
                },

                .ASYNC => {
                    std.debug.print("zix: listening on {s}:{d} (io.async)\n", .{ cfg.ip, cfg.port });

                    const addr = std.Io.net.IpAddress.resolve(thread_io, cfg.ip, cfg.port) catch |err| {
                        std.debug.print("zix: resolve error: {}\n", .{err});
                        return;
                    };
                    var net_server = addr.listen(thread_io, .{
                        .mode = .stream,
                        .kernel_backlog = @intCast(cfg.max_kernel_backlog),
                        .reuse_address = true,
                    }) catch |err| {
                        std.debug.print("zix: listen error: {}\n", .{err});
                        return;
                    };
                    defer net_server.deinit(thread_io);

                    while (true) {
                        const stream = net_server.accept(thread_io) catch |err| {
                            if (err != error.ConnectionAborted) {
                                std.debug.print("zix: accept error: {}\n", .{err});
                                break;
                            }
                            continue;
                        };
                        _ = thread_io.async(handleConnection, .{ stream, thread_io, self });
                    }
                },

                .MIXED => {
                    const worker_count = if (cfg.workers == 0) cpu else cfg.workers;

                    std.debug.print("zix: listening on {s}:{d} ({d} accept, io.async)\n", .{ cfg.ip, cfg.port, worker_count });

                    const acc_threads = try std.heap.smp_allocator.alloc(std.Thread, worker_count);
                    defer std.heap.smp_allocator.free(acc_threads);
                    for (acc_threads) |*t| {
                        t.* = try std.Thread.spawn(.{}, asyncWorkerEntry, .{ self, thread_io });
                    }

                    for (acc_threads) |t| t.join();
                },
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
///   buffer lives on the connection thread stack, otherwise heap-allocated
/// - stack_threshold must be comptime so Zig can size the stack arrays at compile time
/// - workers in config controls accept thread count:
///     0 (default) -> cpu_count accept threads, cpu_count*20 pool threads
///     N           -> exactly N accept threads, same pool sizing formula
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
