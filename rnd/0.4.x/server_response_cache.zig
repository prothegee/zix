//! PoC: ResponseCache for Http1, EPOLL model, zero zix dependencies (std only).
//!
//! What:
//!   Proving ground for the per-key precomputed response cache (see the local
//!   design note Proposal-Request-Response-Cache-Awareness.md). Same epoll skeleton as
//!   http_server_hello_epoll.zig (shared-nothing, one worker per core, lazy
//!   parseHead, coalesced write per event), with two A/B routes:
//!   - GET /nocache : rebuild + serialize the response on every request.
//!   - GET /cache   : key hit serves precomputed bytes straight from a
//!                    per-worker SoA slab, zero serialization on the hot path.
//!   Response bytes are byte-identical between the two routes, so the only
//!   variable is the serialization the cache skips.
//!
//! Why:
//!   Measure whether a hashed-key lookup plus fdWriteAll of a cached slice
//!   actually beats rebuilding the response, on a repeated-GET workload. This
//!   is the go / no-go gate before ADR-036 and before any src/ change.
//!
//! Cache design under test:
//!   - Per-worker, lock-free. Each worker owns one ResponseCache.
//!   - Structure-of-arrays: keys []u64, meta []Meta, one flat payload slab.
//!   - Open addressing with linear probe, key 0 is the empty sentinel.
//!   - Lazy on-access TTL: expired slots are reused in place by the next
//!     store, never zeroed (zeroing would truncate a probe chain).
//!   - Arena allocates the slab once at init, freed whole at deinit.
//!
//! Routes (:9100, /, /echo, /about byte-identical to the hello servers):
//!   GET /         -> 200 text/plain        "Hello, World!" (comptime constant)
//!   GET /echo     -> 200 application/json  {"status":"ok"}
//!   GET /about    -> 200 text/plain        "zix http1 basic server example"
//!   GET /nocache  -> 200 text/plain        "Hello, World!" rebuilt every request
//!   GET /cache    -> 200 text/plain        "Hello, World!" served from the cache
//!   GET /heavy-nocache -> 200 application/json  ~32 KiB body rebuilt every request
//!   GET /heavy-cache   -> 200 application/json  ~32 KiB body served from the cache
//!   GET /sized-nocache?bytes=N -> 200 application/json  N-byte body rebuilt every request
//!   GET /sized-cache?bytes=N   -> 200 application/json  N-byte body served from the cache
//!   GET /static-nocache -> 200 application/json  ~32 KiB file read on every request
//!   GET /static-cache   -> 200 application/json  ~32 KiB file read once then cached
//!   *             -> 404
//!
//! Comparable to:
//!   server_hello_epoll.zig (same epoll skeleton, /, /echo, /about identical)
//!   server_hello_uring.zig (same routes, io_uring dispatch, next as 0.4.x-rc2)
//!
//! Build:
//!   zig build-exe rnd/0.4.x/server_response_cache.zig -OReleaseFast -femit-bin=./server_response_cache.exec
//!
//! Bench:
//!   rnd/0.4.x/server_response_cache_bench       (light + heavy + static, c512 & c4096)
//!   rnd/0.4.x/server_response_cache_sweep       (body-size crossover sweep)
//!
//! Status:
//! PoC. Scratch, uncommitted.

const std = @import("std");
const linux = std.os.linux;

// --------------------------------------------------------- //

const PORT: u16 = 9100;
const KERNEL_BACKLOG: u31 = 1024;

/// Highest fd a worker's table can index. Linux hands out the lowest free fd,
/// so the table stays sparse. Connections on fds at or above this are refused.
const MAX_FD: usize = 65536;

/// Per-connection request accumulation buffer (mirrors max_recv_buf).
const CONN_BUF: usize = 16 * 1024;

/// Per-worker staged-response buffer, flushed once per readable event.
const OUT_BUF: usize = 16 * 1024;

/// Max epoll events drained per epoll_wait call.
const EPOLL_MAX_EVENTS: usize = 512;

/// Cache geometry under test. Slot count must be a power of two. value_bytes is
/// sized to hold the ~32 KiB heavy response, so the slab is entries x value
/// (64 x 64 KiB = 4 MiB per worker). Only a couple of keys are ever stored.
const CACHE_MAX_ENTRIES: u32 = 32;
const CACHE_MAX_VALUE_BYTES: u32 = 128 * 1024;
const CACHE_TTL_MS: u32 = 1000;

/// Heavy JSON body target size, used by the /heavy-* routes.
const HEAVY_TARGET: usize = 32 * 1024;

/// Default and clamp for the ?bytes=N sweep parameter. The max leaves headroom
/// so the full response still fits one cache slot (CACHE_MAX_VALUE_BYTES).
const SIZED_DEFAULT: usize = 1024;
const SIZED_MAX: usize = CACHE_MAX_VALUE_BYTES - 1024;

/// Static file served by the /static-* routes, created in rnd/0.4.x at startup.
/// Models a response read from a constant file on every request, which the
/// cache skips. Relative to cwd (the harness runs from the repo root).
const STATIC_PATH: [:0]const u8 = "rnd/0.4.x/static_response.bin";

// --------------------------------------------------------- //
// ResponseCache: per-worker, SoA slab, open addressing, lazy TTL.
// --------------------------------------------------------- //

/// Per-slot bookkeeping, kept separate from the payload bytes (DoD: hot
/// metadata stays dense and cache-friendly, cold payload lives in the slab).
const Meta = struct {
    insert_tick_ms: u64,
    len: u32,
    ttl_ms: u32,
};

/// Configuration for one cache instance.
const CacheConfig = struct {
    max_entries: u32,
    max_value_bytes: u32,
};

/// Per-worker response cache. Not thread-safe by design: one instance per
/// worker, never shared, so no lock is needed.
const ResponseCache = struct {
    keys: []u64,
    meta: []Meta,
    slab: []u8,
    value_bytes: usize,
    mask: usize,
    arena: std.heap.ArenaAllocator,

    /// Allocate the whole cache from one arena.
    ///
    /// Note:
    /// - max_entries must be a power of two so the slot index is a mask, not a
    ///   modulo.
    ///
    /// Param:
    /// backing - std.mem.Allocator (owns the arena's backing memory)
    /// config - CacheConfig (slot count and per-slot byte cap)
    ///
    /// Return:
    /// - !ResponseCache
    fn init(backing: std.mem.Allocator, config: CacheConfig) !ResponseCache {
        std.debug.assert(std.math.isPowerOfTwo(config.max_entries));

        var arena = std.heap.ArenaAllocator.init(backing);
        errdefer arena.deinit();
        const allocator = arena.allocator();

        const count: usize = config.max_entries;
        const keys = try allocator.alloc(u64, count);
        @memset(keys, 0);

        const meta = try allocator.alloc(Meta, count);
        const slab = try allocator.alloc(u8, count * config.max_value_bytes);

        return .{
            .keys = keys,
            .meta = meta,
            .slab = slab,
            .value_bytes = config.max_value_bytes,
            .mask = count - 1,
            .arena = arena,
        };
    }

    /// Free the slab, keys, and meta in one shot.
    fn deinit(self: *ResponseCache) void {
        self.arena.deinit();
    }

    /// Return the cached bytes for key when present and still fresh.
    /// A miss or an expired entry returns null. now_ms is supplied by the
    /// caller (computed once per event), so lookup itself does no syscall.
    ///
    /// Note:
    /// - An entry expires exactly at insert_tick_ms + ttl_ms, so a ttl_ms of 0
    ///   is always treated as expired (a per-store way to skip the cache).
    ///
    /// Return:
    /// - ?[]const u8
    fn lookup(self: *ResponseCache, key: u64, now_ms: u64) ?[]const u8 {
        var index: usize = @intCast(key & self.mask);
        var probes: usize = 0;
        while (probes <= self.mask) : (probes += 1) {
            const slot_key = self.keys[index];
            if (slot_key == 0) return null;

            if (slot_key == key) {
                const entry = self.meta[index];
                if (now_ms >= entry.insert_tick_ms + entry.ttl_ms) return null;

                const base = index * self.value_bytes;
                return self.slab[base .. base + entry.len];
            }

            index = (index + 1) & self.mask;
        }

        return null;
    }

    /// Copy bytes into the slot for key, evicting an expired neighbour if the
    /// probe reaches one. Returns false when bytes exceed the per-slot cap or
    /// the table is full of live distinct keys.
    ///
    /// Return:
    /// - bool (true when stored)
    fn store(self: *ResponseCache, key: u64, bytes: []const u8, ttl_ms: u32, now_ms: u64) bool {
        if (bytes.len > self.value_bytes) return false;

        var index: usize = @intCast(key & self.mask);
        var probes: usize = 0;
        while (probes <= self.mask) : (probes += 1) {
            const slot_key = self.keys[index];
            const expired = slot_key != 0 and now_ms >= self.meta[index].insert_tick_ms + self.meta[index].ttl_ms;

            if (slot_key == 0 or slot_key == key or expired) {
                const base = index * self.value_bytes;
                @memcpy(self.slab[base .. base + bytes.len], bytes);

                self.keys[index] = key;
                self.meta[index] = .{
                    .insert_tick_ms = now_ms,
                    .len = @intCast(bytes.len),
                    .ttl_ms = ttl_ms,
                };

                return true;
            }

            index = (index + 1) & self.mask;
        }

        return false;
    }
};

/// Hash the cache key parts into a non-zero u64 (0 is the empty sentinel). The
/// query is part of the key, so /sized-cache?bytes=4096 and ?bytes=8192 hash to
/// distinct entries.
fn hashKey(method: []const u8, path: []const u8, query: []const u8) u64 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(method);
    hasher.update(path);
    hasher.update(query);

    const digest = hasher.final();
    return if (digest == 0) 1 else digest;
}

/// Monotonic milliseconds for TTL. Computed once per readable event, not per
/// request, so the cost does not land on the hit path.
fn nowMillis() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(linux.CLOCK.MONOTONIC, &ts);

    return @as(u64, @intCast(ts.sec)) * 1000 + @as(u64, @intCast(ts.nsec)) / 1_000_000;
}

// Per-worker cache and the current event tick, set before each dispatch pass.
threadlocal var tl_cache: ?*ResponseCache = null;
threadlocal var tl_now_ms: u64 = 0;

// --------------------------------------------------------- //
// Lazy head: identical to http_server_hello_epoll.zig.
// --------------------------------------------------------- //

pub const ParsedHead = struct {
    method: []const u8,
    path: []const u8,
    query: []const u8,
    raw_headers: []const u8,
    version_minor: u8,
    keep_alive: bool,
    content_length: u64,
    chunked_request: bool,
    expect_continue: bool,
};

pub const HandlerFn = *const fn (
    head: *const ParsedHead,
    body: []const u8,
    fd: linux.fd_t,
) void;

const ParseResult = struct { head: ParsedHead, body_offset: usize };

pub fn parseHead(buf: []const u8) !ParseResult {
    const header_end = std.mem.indexOf(u8, buf, "\r\n\r\n") orelse return error.IncompleteHeader;
    const body_offset = header_end + 4;

    const first_crlf = std.mem.indexOf(u8, buf[0..header_end], "\r\n") orelse header_end;
    const req_line = buf[0..first_crlf];

    const sp1 = std.mem.indexOfScalar(u8, req_line, ' ') orelse return error.InvalidRequest;
    if (sp1 == 0) return error.InvalidRequest;
    const method = req_line[0..sp1];

    const rest = req_line[sp1 + 1 ..];
    const sp2 = std.mem.lastIndexOfScalar(u8, rest, ' ') orelse return error.InvalidRequest;
    const target = rest[0..sp2];
    const version_str = rest[sp2 + 1 ..];

    const version_minor: u8 = if (std.mem.eql(u8, version_str, "HTTP/1.1"))
        1
    else if (std.mem.eql(u8, version_str, "HTTP/1.0"))
        0
    else
        return error.InvalidRequest;

    var path = target;
    var query: []const u8 = "";
    if (std.mem.indexOfScalar(u8, target, '?')) |question_mark| {
        path = target[0..question_mark];
        query = target[question_mark + 1 ..];
    }

    const raw_headers = if (first_crlf >= header_end)
        buf[0..0]
    else
        buf[first_crlf + 2 .. header_end + 2];

    var keep_alive = (version_minor == 1);
    var content_length: u64 = 0;
    var chunked_request = false;
    var expect_continue = false;

    var pos: usize = 0;
    while (pos < raw_headers.len) {
        const line_end = std.mem.indexOfPos(u8, raw_headers, pos, "\r\n") orelse raw_headers.len;
        const line = raw_headers[pos..line_end];
        pos = line_end + 2;
        if (line.len == 0) break;

        const first_lower = line[0] | 0x20;
        if (first_lower != 'c' and first_lower != 't' and first_lower != 'e') continue;

        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = line[0..colon];
        var value_off: usize = colon + 1;
        while (value_off < line.len and line[value_off] == ' ') value_off += 1;
        const value = line[value_off..];

        if (std.ascii.eqlIgnoreCase(name, "content-length")) {
            content_length = std.fmt.parseInt(u64, value, 10) catch 0;
        } else if (std.ascii.eqlIgnoreCase(name, "connection")) {
            if (std.ascii.eqlIgnoreCase(value, "close")) keep_alive = false;
            if (std.ascii.eqlIgnoreCase(value, "keep-alive")) keep_alive = true;
        } else if (std.ascii.eqlIgnoreCase(name, "transfer-encoding")) {
            if (std.ascii.indexOfIgnoreCase(value, "chunked") != null) chunked_request = true;
        } else if (std.ascii.eqlIgnoreCase(name, "expect")) {
            if (std.ascii.eqlIgnoreCase(value, "100-continue")) expect_continue = true;
        }
    }

    return .{ .head = .{
        .method = method,
        .path = path,
        .query = query,
        .raw_headers = raw_headers,
        .version_minor = version_minor,
        .keep_alive = keep_alive,
        .content_length = content_length,
        .chunked_request = chunked_request,
        .expect_continue = expect_continue,
    }, .body_offset = body_offset };
}

// --------------------------------------------------------- //
// Response sink: one coalesced write per readable event.
// --------------------------------------------------------- //

const RespSink = struct {
    fd: linux.fd_t,
    buf: []u8,
    len: usize = 0,
    failed: bool = false,

    fn append(self: *RespSink, bytes: []const u8) void {
        if (self.len + bytes.len > self.buf.len) {
            self.flush();
            if (self.failed) return;

            if (bytes.len > self.buf.len) {
                fdWriteAllDirect(self.fd, bytes) catch {
                    self.failed = true;
                };
                return;
            }
        }

        @memcpy(self.buf[self.len..][0..bytes.len], bytes);
        self.len += bytes.len;
    }

    fn flush(self: *RespSink) void {
        if (self.len == 0) return;

        fdWriteAllDirect(self.fd, self.buf[0..self.len]) catch {
            self.failed = true;
        };
        self.len = 0;
    }
};

threadlocal var tl_resp_sink: ?*RespSink = null;

pub fn fdWriteAll(fd: linux.fd_t, data: []const u8) error{BrokenPipe}!void {
    if (tl_resp_sink) |sink| {
        if (sink.fd == fd) {
            sink.append(data);
            if (sink.failed) return error.BrokenPipe;

            return;
        }
    }

    return fdWriteAllDirect(fd, data);
}

fn fdWriteAllDirect(fd: linux.fd_t, data: []const u8) error{BrokenPipe}!void {
    var remaining = data;
    while (remaining.len > 0) {
        const write_rc = linux.write(fd, remaining.ptr, remaining.len);
        switch (std.posix.errno(write_rc)) {
            .SUCCESS => {
                const written: usize = @intCast(write_rc);
                if (written == 0) return error.BrokenPipe;
                remaining = remaining[written..];
            },
            .INTR => continue,
            .AGAIN => {
                var poll_fds = [_]linux.pollfd{.{ .fd = fd, .events = linux.POLL.OUT, .revents = 0 }};
                _ = linux.poll(&poll_fds, 1, -1);
            },
            else => return error.BrokenPipe,
        }
    }
}

// --------------------------------------------------------- //
// Comptime router: EXACT matching.
// --------------------------------------------------------- //

pub const Route = struct {
    path: []const u8,
    handler: HandlerFn,
};

const RESP_404: []const u8 = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n";

pub fn Router(comptime routes: []const Route) type {
    const exact_pairs: [routes.len]struct { []const u8, HandlerFn } = blk: {
        var pairs: [routes.len]struct { []const u8, HandlerFn } = undefined;
        for (routes, 0..) |route, index| pairs[index] = .{ route.path, route.handler };
        break :blk pairs;
    };

    const exact_map = std.StaticStringMap(HandlerFn).initComptime(exact_pairs);

    return struct {
        pub fn dispatch(head: *const ParsedHead, body: []const u8, fd: linux.fd_t) void {
            if (exact_map.get(head.path)) |handler| {
                handler(head, body, fd);
                return;
            }

            fdWriteAll(fd, RESP_404) catch {};
        }
    };
}

// --------------------------------------------------------- //
// Handlers. /, /echo, /about are byte-identical to the hello servers so the
// cross-file A/B is apples-to-apples. /nocache and /cache return the same
// "Hello, World!" bytes as /, the only difference being the dispatch path:
//   /        comptime constant write (best case, no hash, no serialize)
//   /nocache rebuild + serialize on every request (worst case)
//   /cache   hashed-key lookup then write a cached slice
// --------------------------------------------------------- //

const RESP_HOME: []const u8 = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 13\r\n\r\nHello, World!";
const RESP_ECHO: []const u8 = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 15\r\n\r\n{\"status\":\"ok\"}";
const RESP_ABOUT: []const u8 = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 30\r\n\r\nzix http1 basic server example";

/// Body served by /, /nocache, and /cache. Identical across all three so the
/// only measured variable is the dispatch path.
const HOME_BODY: []const u8 = "Hello, World!";

/// Serialize the full home response into scratch. This is the per-request work
/// the cache exists to skip.
fn buildHomeResponse(scratch: []u8) []const u8 {
    return std.fmt.bufPrint(
        scratch,
        "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: {d}\r\n\r\n{s}",
        .{ HOME_BODY.len, HOME_BODY },
    ) catch unreachable;
}

fn homeHandler(head: *const ParsedHead, body: []const u8, fd: linux.fd_t) void {
    _ = head;
    _ = body;

    fdWriteAll(fd, RESP_HOME) catch {};
}

fn echoHandler(head: *const ParsedHead, body: []const u8, fd: linux.fd_t) void {
    _ = head;
    _ = body;

    fdWriteAll(fd, RESP_ECHO) catch {};
}

fn aboutHandler(head: *const ParsedHead, body: []const u8, fd: linux.fd_t) void {
    _ = head;
    _ = body;

    fdWriteAll(fd, RESP_ABOUT) catch {};
}

/// Baseline: rebuild and serialize on every request.
fn nocacheHandler(head: *const ParsedHead, body: []const u8, fd: linux.fd_t) void {
    _ = head;
    _ = body;

    var scratch: [256]u8 = undefined;
    const resp = buildHomeResponse(&scratch);

    fdWriteAll(fd, resp) catch {};
}

/// Cached: serve precomputed bytes on a key hit, build + store on a miss.
fn cachedHandler(head: *const ParsedHead, body: []const u8, fd: linux.fd_t) void {
    _ = body;

    const cache = tl_cache.?;
    const now = tl_now_ms;
    const key = hashKey(head.method, head.path, head.query);

    if (cache.lookup(key, now)) |bytes| {
        fdWriteAll(fd, bytes) catch {};
        return;
    }

    var scratch: [256]u8 = undefined;
    const resp = buildHomeResponse(&scratch);

    _ = cache.store(key, resp, CACHE_TTL_MS, now);
    fdWriteAll(fd, resp) catch {};
}

// --------------------------------------------------------- //
// JSON body builder, shared by the /heavy-* and /sized-* routes. Bytes are
// deterministic for a given target, so the nocache and cache variants of one
// size return identical responses. The build cost (record formatting plus the
// assembly memcpy) is the per-request work the cache exists to skip.
// --------------------------------------------------------- //

// Per-worker scratch. Kept off the stack and out of the shared cache so a build
// never touches another worker's memory. Sized to hold the largest sweep body.
threadlocal var tl_build_body: [128 * 1024]u8 = undefined;
threadlocal var tl_build_resp: [144 * 1024]u8 = undefined;

/// Fill body_buf with a JSON array of records until it reaches target_bytes (or
/// the buffer runs low) and return the length. Overshoots by at most one record.
fn buildJsonBody(body_buf: []u8, target_bytes: usize) usize {
    var written: usize = 0;
    body_buf[written] = '[';
    written += 1;

    var index: usize = 0;
    while (written < target_bytes) : (index += 1) {
        // headroom for a separator, the next record, and the closing bracket
        if (written + 80 >= body_buf.len) break;

        if (index != 0) {
            body_buf[written] = ',';
            written += 1;
        }

        const record = std.fmt.bufPrint(
            body_buf[written..],
            "{{\"id\":{d},\"name\":\"widget-{d}\",\"price\":{d},\"ok\":true}}",
            .{ index, index, 1000 + index },
        ) catch break;
        written += record.len;
    }

    body_buf[written] = ']';
    written += 1;

    return written;
}

/// Serialize a full JSON response (status line, headers, body) of about
/// target_bytes into out.
fn buildJsonResponse(out: []u8, body_buf: []u8, target_bytes: usize) []const u8 {
    const body_len = buildJsonBody(body_buf, target_bytes);

    const header = std.fmt.bufPrint(
        out,
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\n\r\n",
        .{body_len},
    ) catch unreachable;
    @memcpy(out[header.len..][0..body_len], body_buf[0..body_len]);

    return out[0 .. header.len + body_len];
}

/// Read ?bytes=N from the query, clamped to [1, SIZED_MAX]. A missing or invalid
/// value falls back to SIZED_DEFAULT.
fn sizedTarget(query: []const u8) usize {
    const tag = "bytes=";
    const at = std.mem.indexOf(u8, query, tag) orelse return SIZED_DEFAULT;
    const start = at + tag.len;

    var end = start;
    while (end < query.len and query[end] >= '0' and query[end] <= '9') end += 1;

    const value = std.fmt.parseInt(usize, query[start..end], 10) catch return SIZED_DEFAULT;
    if (value == 0) return SIZED_DEFAULT;

    return @min(value, SIZED_MAX);
}

/// Heavy baseline: rebuild and serialize the ~32 KiB body on every request.
fn heavyNocacheHandler(head: *const ParsedHead, body: []const u8, fd: linux.fd_t) void {
    _ = head;
    _ = body;

    const resp = buildJsonResponse(&tl_build_resp, &tl_build_body, HEAVY_TARGET);

    fdWriteAll(fd, resp) catch {};
}

/// Heavy cached: serve the precomputed bytes on a key hit, build + store on a miss.
fn heavyCacheHandler(head: *const ParsedHead, body: []const u8, fd: linux.fd_t) void {
    _ = body;

    const cache = tl_cache.?;
    const now = tl_now_ms;
    const key = hashKey(head.method, head.path, head.query);

    if (cache.lookup(key, now)) |bytes| {
        fdWriteAll(fd, bytes) catch {};
        return;
    }

    const resp = buildJsonResponse(&tl_build_resp, &tl_build_body, HEAVY_TARGET);

    _ = cache.store(key, resp, CACHE_TTL_MS, now);
    fdWriteAll(fd, resp) catch {};
}

/// Sweep baseline: rebuild a body of ?bytes=N on every request.
fn sizedNocacheHandler(head: *const ParsedHead, body: []const u8, fd: linux.fd_t) void {
    _ = body;

    const resp = buildJsonResponse(&tl_build_resp, &tl_build_body, sizedTarget(head.query));

    fdWriteAll(fd, resp) catch {};
}

/// Sweep cached: serve the cached body of ?bytes=N, build + store on a miss.
/// The query is part of the cache key, so each size is its own entry.
fn sizedCacheHandler(head: *const ParsedHead, body: []const u8, fd: linux.fd_t) void {
    _ = body;

    const cache = tl_cache.?;
    const now = tl_now_ms;
    const key = hashKey(head.method, head.path, head.query);

    if (cache.lookup(key, now)) |bytes| {
        fdWriteAll(fd, bytes) catch {};
        return;
    }

    const resp = buildJsonResponse(&tl_build_resp, &tl_build_body, sizedTarget(head.query));

    _ = cache.store(key, resp, CACHE_TTL_MS, now);
    fdWriteAll(fd, resp) catch {};
}

// --------------------------------------------------------- //
// Static file variant: a fixed ~32 KiB response written to rnd/0.4.x at startup.
// The nocache route opens and reads the file on every request, the cache route
// reads it once then serves the slab copy. This models "read a constant file"
// as the response source, where the cache skips the open + read syscalls.
// --------------------------------------------------------- //

/// Create STATIC_PATH holding a full ~32 KiB HTTP response. Called once at
/// startup, before workers spawn.
fn writeStaticFile() void {
    const resp = buildJsonResponse(&tl_build_resp, &tl_build_body, HEAVY_TARGET);

    const open_rc = linux.open(STATIC_PATH, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
    if (std.posix.errno(open_rc) != .SUCCESS) return;
    const file_fd: linux.fd_t = @intCast(open_rc);
    defer _ = linux.close(file_fd);

    var off: usize = 0;
    while (off < resp.len) {
        const write_rc = linux.write(file_fd, resp.ptr + off, resp.len - off);
        switch (std.posix.errno(write_rc)) {
            .SUCCESS => off += @intCast(write_rc),
            .INTR => continue,
            else => return,
        }
    }
}

/// Read the full static response from disk into out. Returns 404 on any error.
fn readStaticResponse(out: []u8) []const u8 {
    const open_rc = linux.open(STATIC_PATH, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (std.posix.errno(open_rc) != .SUCCESS) return RESP_404;
    const file_fd: linux.fd_t = @intCast(open_rc);
    defer _ = linux.close(file_fd);

    var written: usize = 0;
    while (written < out.len) {
        const read_rc = linux.read(file_fd, out.ptr + written, out.len - written);
        switch (std.posix.errno(read_rc)) {
            .SUCCESS => {},
            .INTR => continue,
            else => return RESP_404,
        }

        const got: usize = @intCast(read_rc);
        if (got == 0) break;
        written += got;
    }

    return out[0..written];
}

/// Static baseline: open + read the file on every request.
fn staticNocacheHandler(head: *const ParsedHead, body: []const u8, fd: linux.fd_t) void {
    _ = head;
    _ = body;

    const resp = readStaticResponse(&tl_build_resp);

    fdWriteAll(fd, resp) catch {};
}

/// Static cached: read the file once on a miss, then serve the slab copy.
fn staticCacheHandler(head: *const ParsedHead, body: []const u8, fd: linux.fd_t) void {
    _ = body;

    const cache = tl_cache.?;
    const now = tl_now_ms;
    const key = hashKey(head.method, head.path, head.query);

    if (cache.lookup(key, now)) |bytes| {
        fdWriteAll(fd, bytes) catch {};
        return;
    }

    const resp = readStaticResponse(&tl_build_resp);

    _ = cache.store(key, resp, CACHE_TTL_MS, now);
    fdWriteAll(fd, resp) catch {};
}

const Routes = Router(&[_]Route{
    .{ .path = "/", .handler = homeHandler },
    .{ .path = "/echo", .handler = echoHandler },
    .{ .path = "/about", .handler = aboutHandler },
    .{ .path = "/nocache", .handler = nocacheHandler },
    .{ .path = "/cache", .handler = cachedHandler },
    .{ .path = "/heavy-nocache", .handler = heavyNocacheHandler },
    .{ .path = "/heavy-cache", .handler = heavyCacheHandler },
    .{ .path = "/sized-nocache", .handler = sizedNocacheHandler },
    .{ .path = "/sized-cache", .handler = sizedCacheHandler },
    .{ .path = "/static-nocache", .handler = staticNocacheHandler },
    .{ .path = "/static-cache", .handler = staticCacheHandler },
});

// --------------------------------------------------------- //
// EPOLL engine: shared-nothing, one listener + epoll + cache per worker.
// --------------------------------------------------------- //

const Conn = struct {
    fd: linux.fd_t,
    buf: []u8,
    filled: usize,
};

const ConnTable = struct {
    slots: []?*Conn,

    const allocator = std.heap.smp_allocator;

    fn init() !ConnTable {
        const slots = try allocator.alloc(?*Conn, MAX_FD);
        @memset(slots, null);

        return .{ .slots = slots };
    }

    fn deinit(self: *ConnTable) void {
        for (self.slots) |maybe_conn| {
            if (maybe_conn) |conn| {
                allocator.free(conn.buf);
                allocator.destroy(conn);
            }
        }

        allocator.free(self.slots);
    }

    fn get(self: *ConnTable, fd: linux.fd_t) ?*Conn {
        const idx: usize = @intCast(fd);
        if (idx >= self.slots.len) return null;

        return self.slots[idx];
    }

    fn alloc(self: *ConnTable, fd: linux.fd_t) ?*Conn {
        const idx: usize = @intCast(fd);
        if (idx >= self.slots.len) return null;

        const conn = allocator.create(Conn) catch return null;
        const buf = allocator.alloc(u8, CONN_BUF) catch {
            allocator.destroy(conn);
            return null;
        };

        conn.* = .{ .fd = fd, .buf = buf, .filled = 0 };
        self.slots[idx] = conn;

        return conn;
    }

    fn free(self: *ConnTable, fd: linux.fd_t) void {
        const idx: usize = @intCast(fd);
        if (idx >= self.slots.len) return;

        if (self.slots[idx]) |conn| {
            allocator.free(conn.buf);
            allocator.destroy(conn);
            self.slots[idx] = null;
        }
    }
};

const ConnOutcome = enum { keep_alive, close };

fn serveConnEvent(conn: *Conn, out_buf: []u8) ConnOutcome {
    while (true) {
        if (conn.filled >= conn.buf.len) return .close;

        const read_rc = linux.read(conn.fd, conn.buf.ptr + conn.filled, conn.buf.len - conn.filled);
        switch (std.posix.errno(read_rc)) {
            .SUCCESS => {},
            .AGAIN => break,
            .INTR => continue,
            else => return .close,
        }

        const got: usize = @intCast(read_rc);
        if (got == 0) return .close;
        conn.filled += got;
    }

    tl_now_ms = nowMillis();

    var sink = RespSink{ .fd = conn.fd, .buf = out_buf };
    tl_resp_sink = &sink;
    const outcome = dispatchBuffered(conn);
    tl_resp_sink = null;

    sink.flush();
    if (sink.failed) return .close;

    return outcome;
}

fn dispatchBuffered(conn: *Conn) ConnOutcome {
    var consumed: usize = 0;
    var outcome: ConnOutcome = .keep_alive;

    while (consumed < conn.filled) {
        const remaining = conn.buf[consumed..conn.filled];

        const parsed = parseHead(remaining) catch |err| switch (err) {
            error.IncompleteHeader => break,
            error.InvalidRequest => return .close,
        };

        if (parsed.head.chunked_request) return .close;

        const total_len = parsed.body_offset + parsed.head.content_length;
        if (total_len > remaining.len) break;

        const body = remaining[parsed.body_offset..total_len];
        Routes.dispatch(&parsed.head, body, conn.fd);

        consumed += total_len;
        if (!parsed.head.keep_alive) {
            outcome = .close;
            break;
        }
    }

    if (consumed > 0 and consumed < conn.filled) {
        std.mem.copyForwards(u8, conn.buf, conn.buf[consumed..conn.filled]);
        conn.filled -= consumed;
    } else if (consumed >= conn.filled) {
        conn.filled = 0;
    }

    return outcome;
}

// --------------------------------------------------------- //

fn setNoDelay(fd: linux.fd_t) void {
    std.posix.setsockopt(
        fd,
        std.posix.IPPROTO.TCP,
        std.posix.TCP.NODELAY,
        std.mem.asBytes(&@as(c_int, 1)),
    ) catch {};
}

fn createListener() !linux.fd_t {
    const socket_rc = linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC | linux.SOCK.NONBLOCK, 0);
    if (std.posix.errno(socket_rc) != .SUCCESS) return error.SocketFailed;

    const fd: linux.fd_t = @intCast(socket_rc);
    errdefer _ = linux.close(fd);

    try std.posix.setsockopt(fd, linux.SOL.SOCKET, linux.SO.REUSEADDR, std.mem.asBytes(&@as(c_int, 1)));
    try std.posix.setsockopt(fd, linux.SOL.SOCKET, linux.SO.REUSEPORT, std.mem.asBytes(&@as(c_int, 1)));

    const addr = linux.sockaddr.in{
        .family = linux.AF.INET,
        .port = std.mem.nativeToBig(u16, PORT),
        .addr = 0,
    };
    if (std.posix.errno(linux.bind(fd, @ptrCast(&addr), @sizeOf(linux.sockaddr.in))) != .SUCCESS) return error.BindFailed;
    if (std.posix.errno(linux.listen(fd, KERNEL_BACKLOG)) != .SUCCESS) return error.ListenFailed;

    return fd;
}

fn acceptAll(table: *ConnTable, epfd: linux.fd_t, listener_fd: linux.fd_t) void {
    while (true) {
        const accept_rc = linux.accept4(listener_fd, null, null, linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC);
        switch (std.posix.errno(accept_rc)) {
            .SUCCESS => {},
            .AGAIN => return,
            .INTR, .CONNABORTED => continue,
            else => return,
        }

        const conn_fd: linux.fd_t = @intCast(accept_rc);
        setNoDelay(conn_fd);
        if (table.alloc(conn_fd) == null) {
            _ = linux.close(conn_fd);
            continue;
        }

        var conn_event = linux.epoll_event{
            .events = linux.EPOLL.IN | linux.EPOLL.RDHUP,
            .data = .{ .fd = conn_fd },
        };
        if (std.posix.errno(linux.epoll_ctl(epfd, linux.EPOLL.CTL_ADD, conn_fd, &conn_event)) != .SUCCESS) {
            table.free(conn_fd);
            _ = linux.close(conn_fd);
        }
    }
}

fn workerEntry() void {
    const listener_fd = createListener() catch return;
    defer _ = linux.close(listener_fd);

    var table = ConnTable.init() catch return;
    defer table.deinit();

    var cache = ResponseCache.init(std.heap.smp_allocator, .{
        .max_entries = CACHE_MAX_ENTRIES,
        .max_value_bytes = CACHE_MAX_VALUE_BYTES,
    }) catch return;
    defer cache.deinit();

    tl_cache = &cache;

    const epfd_rc = linux.epoll_create1(linux.EPOLL.CLOEXEC);
    if (std.posix.errno(epfd_rc) != .SUCCESS) return;
    const epfd: linux.fd_t = @intCast(epfd_rc);
    defer _ = linux.close(epfd);

    var listener_event = linux.epoll_event{
        .events = linux.EPOLL.IN,
        .data = .{ .fd = listener_fd },
    };
    if (std.posix.errno(linux.epoll_ctl(epfd, linux.EPOLL.CTL_ADD, listener_fd, &listener_event)) != .SUCCESS) return;

    var out_buf: [OUT_BUF]u8 = undefined;
    var events: [EPOLL_MAX_EVENTS]linux.epoll_event = undefined;
    while (true) {
        const wait_rc = linux.epoll_wait(epfd, &events, EPOLL_MAX_EVENTS, -1);
        switch (std.posix.errno(wait_rc)) {
            .SUCCESS => {},
            .INTR => continue,
            else => return,
        }

        const event_count: usize = @intCast(wait_rc);
        for (events[0..event_count]) |event| {
            if (event.data.fd == listener_fd) {
                acceptAll(&table, epfd, listener_fd);
                continue;
            }

            const conn = table.get(event.data.fd) orelse continue;

            const outcome = if ((event.events & (linux.EPOLL.HUP | linux.EPOLL.ERR)) != 0)
                ConnOutcome.close
            else
                serveConnEvent(conn, &out_buf);

            if (outcome == .close) {
                _ = linux.epoll_ctl(epfd, linux.EPOLL.CTL_DEL, event.data.fd, null);
                _ = linux.close(event.data.fd);
                table.free(event.data.fd);
            }
        }
    }
}

pub fn main(process: std.process.Init) !void {
    _ = process;

    writeStaticFile();

    const cpu_count = std.Thread.getCpuCount() catch 1;
    std.debug.print("response-cache-poc: listening on 0.0.0.0:{d} (epoll, {d} workers, /cache vs /nocache)\n", .{ PORT, cpu_count });

    var index: usize = 1;
    while (index < cpu_count) : (index += 1) {
        _ = try std.Thread.spawn(.{}, workerEntry, .{});
    }

    workerEntry();
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //

test "cache: store then lookup returns identical bytes" {
    var cache = try ResponseCache.init(std.testing.allocator, .{ .max_entries = 16, .max_value_bytes = 256 });
    defer cache.deinit();

    const key = hashKey("GET", "/cache", "");
    const payload = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nhi";

    try std.testing.expect(cache.store(key, payload, 1000, 100));
    try std.testing.expectEqualStrings(payload, cache.lookup(key, 200).?);
}

test "cache: miss on absent key" {
    var cache = try ResponseCache.init(std.testing.allocator, .{ .max_entries = 16, .max_value_bytes = 256 });
    defer cache.deinit();

    try std.testing.expect(cache.lookup(hashKey("GET", "/absent", ""), 100) == null);
}

test "cache: expired entry returns null then refetches" {
    var cache = try ResponseCache.init(std.testing.allocator, .{ .max_entries = 16, .max_value_bytes = 256 });
    defer cache.deinit();

    const key = hashKey("GET", "/cache", "");
    try std.testing.expect(cache.store(key, "first", 1000, 100));

    // now is past insert(100) + ttl(1000)
    try std.testing.expect(cache.lookup(key, 1101) == null);

    // store overwrites the same slot, fresh again
    try std.testing.expect(cache.store(key, "second", 1000, 1200));
    try std.testing.expectEqualStrings("second", cache.lookup(key, 1300).?);
}

test "cache: oversize value bypasses store" {
    var cache = try ResponseCache.init(std.testing.allocator, .{ .max_entries = 16, .max_value_bytes = 8 });
    defer cache.deinit();

    try std.testing.expect(!cache.store(hashKey("GET", "/big", ""), "this is longer than eight", 1000, 100));
}

test "cache: ttl 0 means never fresh" {
    var cache = try ResponseCache.init(std.testing.allocator, .{ .max_entries = 16, .max_value_bytes = 256 });
    defer cache.deinit();

    const key = hashKey("GET", "/cache", "");
    try std.testing.expect(cache.store(key, "x", 0, 100));
    try std.testing.expect(cache.lookup(key, 100) == null);
}

test "cache: distinct keys coexist via probing" {
    var cache = try ResponseCache.init(std.testing.allocator, .{ .max_entries = 16, .max_value_bytes = 64 });
    defer cache.deinit();

    const key_a = hashKey("GET", "/a", "");
    const key_b = hashKey("GET", "/b", "");
    try std.testing.expect(cache.store(key_a, "alpha", 1000, 100));
    try std.testing.expect(cache.store(key_b, "bravo", 1000, 100));

    try std.testing.expectEqualStrings("alpha", cache.lookup(key_a, 200).?);
    try std.testing.expectEqualStrings("bravo", cache.lookup(key_b, 200).?);
}

test "json response: content-length matches body and fits the cache cap" {
    var body_buf: [128 * 1024]u8 = undefined;
    var resp_buf: [144 * 1024]u8 = undefined;
    const resp = buildJsonResponse(&resp_buf, &body_buf, HEAVY_TARGET);

    const split = std.mem.indexOf(u8, resp, "\r\n\r\n").?;
    const body_len = resp.len - (split + 4);

    const cl_tag = "Content-Length: ";
    const cl_start = std.mem.indexOf(u8, resp, cl_tag).? + cl_tag.len;
    const cl_end = std.mem.indexOfPos(u8, resp, cl_start, "\r\n").?;
    const declared = try std.fmt.parseInt(usize, resp[cl_start..cl_end], 10);

    try std.testing.expectEqual(body_len, declared);
    try std.testing.expect(resp.len <= CACHE_MAX_VALUE_BYTES);
    try std.testing.expect(body_len > 16 * 1024);
}

test "json body: reaches the requested target size" {
    var body_buf: [128 * 1024]u8 = undefined;
    for ([_]usize{ 256, 1024, 4096, 32768 }) |target| {
        const len = buildJsonBody(&body_buf, target);
        try std.testing.expect(len >= target);
        try std.testing.expect(len < target + 128);
    }
}

test "sizedTarget: parses, defaults, and clamps" {
    try std.testing.expectEqual(@as(usize, 4096), sizedTarget("bytes=4096"));
    try std.testing.expectEqual(SIZED_DEFAULT, sizedTarget("foo=1"));
    try std.testing.expectEqual(SIZED_DEFAULT, sizedTarget("bytes=0"));
    try std.testing.expectEqual(SIZED_MAX, sizedTarget("bytes=99999999"));
}

test "static file: read returns the written response" {
    writeStaticFile();
    defer _ = linux.unlink(STATIC_PATH);

    var buf: [144 * 1024]u8 = undefined;
    const got = readStaticResponse(&buf);

    try std.testing.expect(got.len > 16 * 1024);
    try std.testing.expect(std.mem.startsWith(u8, got, "HTTP/1.1 200 OK"));
}

test "parseHead lazy framing scan" {
    const raw = "GET /cache?a=1 HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\n\r\n";
    const parsed = try parseHead(raw);

    try std.testing.expectEqualStrings("GET", parsed.head.method);
    try std.testing.expectEqualStrings("/cache", parsed.head.path);
    try std.testing.expect(parsed.head.keep_alive);
}
