//! zix http1 dispatch helpers shared by two or more dispatch models.

const std = @import("std");
const builtin = @import("builtin");
const Config = @import("../config.zig").Http1ServerConfig;
const core = @import("../core.zig");
const HandlerFn = core.HandlerFn;

// --------------------------------------------------------- //

/// Emit a server lifecycle line. Routes through config.logger when present.
/// Without a logger it prints to stderr only in Debug builds (silent in release).
pub fn logSystem(config: Config, comptime fmt: []const u8, args: anytype) void {
    if (config.logger) |lg| {
        lg.system(.INFO, "http1", fmt, args);
        return;
    }

    if (comptime builtin.mode == .Debug) std.debug.print("zix: " ++ fmt ++ "\n", args);
}

// --------------------------------------------------------- //
// Shared connection entry (ASYNC and MIXED)

pub const ConnArgs = struct {
    stream: std.Io.net.Stream,
    io: std.Io,
    handler: HandlerFn,
    handler_timeout_ms: u32 = 0,
    send_date_header: bool = true,
};

pub fn connEntry(args: ConnArgs) void {
    core.setDateHeader(args.send_date_header);

    defer args.stream.close(args.io);
    const fd = args.stream.socket.handle;
    core.serveConn(fd, args.handler, .{ .handler_timeout_ms = args.handler_timeout_ms });
}

/// Highest fd a worker's table can index. Linux hands out the lowest free fd,
/// so the table stays sparse. Connections on fds at or above this are refused.
pub const MAX_FD: usize = 1 << 16;

const ChunkDecode = struct { len: usize, consumed: usize };

/// Decode a chunked request body that is fully present in src.
///
/// Note:
/// - Chunk extensions are ignored. Trailers are skipped to the final blank line.
///
/// Return:
/// - ChunkDecode (decoded length in out, bytes consumed from src)
/// - null when the terminating zero chunk has not arrived yet, or out is too small
pub fn decodeChunkedInBuf(src: []const u8, out: []u8) ?ChunkDecode {
    var pos: usize = 0;
    var out_pos: usize = 0;

    while (true) {
        const line_end = std.mem.indexOfPos(u8, src, pos, "\r\n") orelse return null;
        const size_field = src[pos..line_end];
        const hex = if (std.mem.indexOfScalar(u8, size_field, ';')) |s| size_field[0..s] else size_field;
        const chunk_size = std.fmt.parseInt(usize, std.mem.trim(u8, hex, " "), 16) catch return null;
        pos = line_end + 2;

        if (chunk_size == 0) {
            const trailer_end = std.mem.indexOfPos(u8, src, pos, "\r\n") orelse return null;
            return .{ .len = out_pos, .consumed = trailer_end + 2 };
        }

        if (pos + chunk_size + 2 > src.len) return null;
        if (out_pos + chunk_size > out.len) return null;

        @memcpy(out[out_pos..][0..chunk_size], src[pos..][0..chunk_size]);
        out_pos += chunk_size;
        pos += chunk_size + 2;
    }
}

pub fn setNoDelay(fd: std.posix.fd_t) void {
    if (comptime @import("builtin").target.os.tag != .windows) {
        std.posix.setsockopt(
            fd,
            std.posix.IPPROTO.TCP,
            std.posix.TCP.NODELAY,
            std.mem.asBytes(&@as(c_int, 1)),
        ) catch {};
    }
}

pub fn setNonBlock(fd: std.posix.fd_t) void {
    const linux = std.os.linux;
    const cur = linux.fcntl(fd, std.posix.F.GETFL, 0);
    const nonblock: u32 = @bitCast(std.posix.O{ .NONBLOCK = true });
    _ = linux.fcntl(fd, std.posix.F.SETFL, cur | @as(usize, nonblock));
}

/// Spin up to 50 us before blocking. Reduces wake-up latency on saturated
/// loopback benchmarks. Silent no-op when the kernel lacks SO_BUSY_POLL support.
pub fn setBusyPoll(fd: std.posix.fd_t) void {
    const SO_BUSY_POLL: u32 = 46;
    std.posix.setsockopt(
        fd,
        std.posix.SOL.SOCKET,
        SO_BUSY_POLL,
        std.mem.asBytes(&@as(c_int, 50)),
    ) catch {};
}

/// Pin the calling thread to the CPU slot assigned to worker_id, respecting
/// the cgroup-allowed CPU mask so we never select a CPU the container cannot use.
pub fn pinToCpu(worker_id: usize) void {
    const linux = std.os.linux;
    var cpu_set: linux.cpu_set_t = undefined;
    if (linux.sched_getaffinity(0, @sizeOf(linux.cpu_set_t), &cpu_set) != 0) return;

    var cpu_list: [256]u32 = undefined;
    var n_cpus: usize = 0;
    for (cpu_set, 0..) |word, word_idx| {
        var w = word;
        while (w != 0) : (w &= w - 1) {
            if (n_cpus < cpu_list.len) {
                cpu_list[n_cpus] = @intCast(word_idx * @bitSizeOf(usize) + @ctz(w));
                n_cpus += 1;
            }
        }
    }
    if (n_cpus == 0) return;

    const target = cpu_list[worker_id % n_cpus];
    var target_set: linux.cpu_set_t = std.mem.zeroes(linux.cpu_set_t);
    const cpu_word = target / @bitSizeOf(usize);
    const cpu_bit: u6 = @intCast(target % @bitSizeOf(usize));
    target_set[cpu_word] |= @as(usize, 1) << cpu_bit;

    linux.sched_setaffinity(0, &target_set) catch {};
}

/// Count CPUs available to this process via sched_getaffinity, respecting cgroup
/// and taskset restrictions. Falls back to std.Thread.getCpuCount when the syscall
/// fails. Used by EPOLL to default to one worker per available CPU so that multiple
/// workers are never pinned to the same core under cgroup-limited bench environments.
pub fn getAvailableCpuCount() usize {
    const linux = std.os.linux;
    var cpu_set: linux.cpu_set_t = undefined;
    if (linux.sched_getaffinity(0, @sizeOf(linux.cpu_set_t), &cpu_set) != 0) {
        return std.Thread.getCpuCount() catch 1;
    }

    var count: usize = 0;
    for (cpu_set) |word| {
        count += @popCount(word);
    }

    return if (count == 0) 1 else count;
}

/// Fast path for HTTP/1.1 GET requests: extract method and path with direct
/// arithmetic, bypassing the full header scan loop in parseHeadAt. Only
/// keep_alive defaults (HTTP/1.1 = true) and content_length=0 are assumed;
/// raw_headers is still set so handlers can call getHeader() if needed.
/// Returns null when the request is not a GET or the format is unexpected.
pub fn parseGetFastPath(rem: []const u8, header_end: usize) ?core.ParseResult {
    if (rem.len < 16) return null;
    if (std.mem.readInt(u32, rem[0..4], .little) != comptime std.mem.readInt(u32, "GET ", .little)) return null;

    const line_end = std.mem.indexOfScalarPos(u8, rem, 4, '\r') orelse return null;

    // Minimum for "GET / HTTP/1.1": line_end >= 14, last 9 chars = " HTTP/1.1"
    if (line_end < 14) return null;
    if (rem[line_end - 9] != ' ') return null;
    if (std.mem.readInt(u64, rem[line_end - 8 ..][0..8], .little) != comptime std.mem.readInt(u64, "HTTP/1.1", .little)) return null;

    const full_path = rem[4 .. line_end - 9];
    var path = full_path;
    var query: []const u8 = "";
    if (std.mem.indexOfScalar(u8, full_path, '?')) |q| {
        path = full_path[0..q];
        query = full_path[q + 1 ..];
    }

    const raw_start = line_end + 2;
    const raw_headers: []const u8 = if (raw_start < header_end + 2) rem[raw_start .. header_end + 2] else &.{};

    // Bail out to parseHeadAt when "close" appears in raw_headers so that
    // Connection: close is handled correctly. This is the rare case.
    if (std.mem.indexOf(u8, raw_headers, "close") != null) return null;

    return .{
        .head = .{
            .method = rem[0..3],
            .path = path,
            .query = query,
            .raw_headers = raw_headers,
            .version_minor = 1,
            .keep_alive = true,
            .content_length = 0,
            .chunked_request = false,
            .expect_continue = false,
        },
        .body_offset = header_end + 4,
    };
}

/// Effective cache slot count for a worker, honoring cache_max_total_bytes.
/// When a memory ceiling is set, the entry count is reduced so the slab
/// (entries * value_bytes) fits. ResponseCache.init then rounds down to a power
/// of two, so the slab never exceeds the ceiling.
pub fn effectiveCacheEntries(config: Config) u32 {
    if (config.cache_max_total_bytes == 0) return config.cache_max_entries;

    const value_bytes: usize = @max(1, config.cache_max_value_bytes);
    const fit = config.cache_max_total_bytes / value_bytes;
    const capped = @min(@as(usize, config.cache_max_entries), fit);

    return @intCast(@max(@as(usize, 1), capped));
}

test "zix http1: effectiveCacheEntries honors the memory ceiling" {
    const base = Config{ .io = undefined, .ip = "127.0.0.1", .port = 0, .cache_max_entries = 1024, .cache_max_value_bytes = 16 * 1024 };

    // no ceiling: entry count unchanged
    try std.testing.expectEqual(@as(u32, 1024), effectiveCacheEntries(base));

    // ceiling of 256 KiB / 16 KiB = 16 slots, below the configured 1024
    var capped = base;
    capped.cache_max_total_bytes = 256 * 1024;
    try std.testing.expectEqual(@as(u32, 16), effectiveCacheEntries(capped));

    // a tiny ceiling still yields at least one slot
    var tiny = base;
    tiny.cache_max_total_bytes = 1;
    try std.testing.expectEqual(@as(u32, 1), effectiveCacheEntries(tiny));
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //

test "zix http1: parseGetFastPath basic GET with host header" {
    const req = "GET /pipeline HTTP/1.1\r\nHost: localhost\r\n\r\n";
    const header_end = std.mem.indexOf(u8, req, "\r\n\r\n").?;
    const result = parseGetFastPath(req, header_end).?;

    try std.testing.expectEqualStrings("GET", result.head.method);
    try std.testing.expectEqualStrings("/pipeline", result.head.path);
    try std.testing.expectEqualStrings("", result.head.query);
    try std.testing.expectEqual(true, result.head.keep_alive);
    try std.testing.expectEqual(@as(u64, 0), result.head.content_length);
    try std.testing.expectEqual(false, result.head.chunked_request);
    try std.testing.expectEqual(@as(u8, 1), result.head.version_minor);
    try std.testing.expectEqual(header_end + 4, result.body_offset);
}

test "zix http1: parseGetFastPath with query string" {
    const req = "GET /baseline11?a=1&b=2 HTTP/1.1\r\nHost: x\r\n\r\n";
    const header_end = std.mem.indexOf(u8, req, "\r\n\r\n").?;
    const result = parseGetFastPath(req, header_end).?;

    try std.testing.expectEqualStrings("/baseline11", result.head.path);
    try std.testing.expectEqualStrings("a=1&b=2", result.head.query);
}

test "zix http1: parseGetFastPath rejects POST" {
    const req = "POST /upload HTTP/1.1\r\nContent-Length: 5\r\n\r\nhello";
    const header_end = std.mem.indexOf(u8, req, "\r\n\r\n").?;
    try std.testing.expectEqual(@as(?core.ParseResult, null), parseGetFastPath(req, header_end));
}

test "zix http1: parseGetFastPath rejects HTTP/1.0" {
    const req = "GET / HTTP/1.0\r\n\r\n";
    const header_end = std.mem.indexOf(u8, req, "\r\n\r\n").?;
    try std.testing.expectEqual(@as(?core.ParseResult, null), parseGetFastPath(req, header_end));
}

test "zix http1: parseGetFastPath integer compare matches the full word" {
    // Method differs only in the trailing byte ("GETX" vs "GET ").
    const bad_method = "GETX/ HTTP/1.1\r\n\r\n";
    try std.testing.expectEqual(@as(?core.ParseResult, null), parseGetFastPath(bad_method, std.mem.indexOf(u8, bad_method, "\r\n\r\n").?));

    // Version differs only in a middle byte ("HXTP/1.1" vs "HTTP/1.1").
    const bad_version = "GET / HXTP/1.1\r\n\r\n";
    try std.testing.expectEqual(@as(?core.ParseResult, null), parseGetFastPath(bad_version, std.mem.indexOf(u8, bad_version, "\r\n\r\n").?));

    // The exact words still match.
    const good = "GET / HTTP/1.1\r\n\r\n";
    try std.testing.expect(parseGetFastPath(good, std.mem.indexOf(u8, good, "\r\n\r\n").?) != null);
}

test "zix http1: parseGetFastPath raw_headers covers host line" {
    const req = "GET / HTTP/1.1\r\nHost: example.com\r\n\r\n";
    const header_end = std.mem.indexOf(u8, req, "\r\n\r\n").?;
    const result = parseGetFastPath(req, header_end).?;
    const host = core.getHeader(&result.head, "host");
    try std.testing.expect(host != null);
    try std.testing.expectEqualStrings("example.com", host.?);
}
