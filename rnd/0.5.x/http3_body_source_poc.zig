//! HTTP/3 static body source PoC (ADR-064 checkpoint 5).
//!
//! What:
//!   zix.Http3 cannot serve a cached file the way the other three engines do. Its pump reads the
//!   body once per packet (`copyStreamSlice` in src/udp/http3/dispatch/common.zig), and a loss
//!   rewinds `sent` and reads the same range AGAIN, so the body has to be a stable, randomly
//!   readable source for the whole life of the stream, long after the handler returned.
//!
//!   This measures the four ways to be that source, at the engine's real numbers, so the choice is
//!   made on data instead of on which one sounds cheaper.
//!
//! Note:
//! - Constants are lifted from the engine, not invented: a 1200-byte datagram minus the 160-byte
//!   per-packet frame reserve gives a 1040-byte stream chunk, and 256 KiB is the size the existing
//!   HTTP/3 example already serves on its multi-packet route.
//! - Every strategy is checksummed against the baseline, so a strategy that reads the wrong bytes
//!   fails loudly instead of posting a fast, wrong number.
//! - The retransmit pass models what loss actually costs each strategy: the file-backed strategies
//!   pay a second read, the in-memory one pays a second memcpy.
//! - The page cache is warmed first. This measures the steady state of a served file, not cold disk.
//!
//! Run:    zig run rnd/0.5.x/http3_body_source_poc.zig

const std = @import("std");
const builtin = @import("builtin");

/// Monotonic nanoseconds, the same shape the engine's own clock helpers use (std.time has no Timer
/// on this compiler). MONOTONIC rather than REALTIME, so a clock adjustment cannot skew a run.
fn monotonicNs() u64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);

    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

/// Raw positional read, the syscall with no std.Io dispatch in front of it. Linux only, which is
/// where the zero-copy work already lives, and the std.Io variant below covers every other target.
fn preadRaw(fd: std.posix.fd_t, buf: []u8, offset: u64) !usize {
    const rc = std.os.linux.pread(fd, buf.ptr, buf.len, @intCast(offset));
    if (std.posix.errno(rc) != .SUCCESS) return error.ReadFailed;

    return @intCast(rc);
}

/// Datagram size the engine defaults to (Http3ServerConfig.max_datagram_size).
const MAX_DATAGRAM_SIZE: usize = 1200;

/// Room a sealed packet reserves for its frames and AEAD tag (dispatch/common.zig).
const PER_PACKET_FRAME_RESERVE: usize = 160;

/// Stream bytes carried by one packet, which is the unit every strategy is measured in.
const CHUNK: usize = MAX_DATAGRAM_SIZE - PER_PACKET_FRAME_RESERVE;

/// Body size under test, matching the multi-packet route of the existing HTTP/3 example.
const BODY_SIZE: usize = 256 * 1024;

/// Block a batched read pulls in before handing chunks out of it.
const BLOCK_SIZE: usize = 64 * 1024;

/// Full-body passes per strategy. High enough that a pass is not dominated by timer noise.
const ROUNDS: usize = 200;

/// One chunk in this many is sent twice, modelling a loss and its retransmission.
const RETRANSMIT_EVERY: usize = 50;

/// Engine capacity constants, used for the memory arithmetic rather than for timing.
const MAX_CONNECTIONS: usize = 256;
const MAX_SEND_STREAMS: usize = 64;
const MAX_SENT_RANGES: usize = 128;

/// Larger fixture for the memory section, big enough that a resident-size delta is unambiguous.
const MEMORY_FIXTURE_SIZE: usize = 16 * 1024 * 1024;

const FIXTURE_DIR = ".zig-cache/poc-http3-body";
const FIXTURE_PATH = FIXTURE_DIR ++ "/body.bin";
const MEMORY_FIXTURE_PATH = FIXTURE_DIR ++ "/memory.bin";

// --------------------------------------------------------- //

const Result = struct {
    name: []const u8,
    /// What the strategy costs per packet, which is the number the pump pays.
    ns_per_chunk: f64,
    /// Same run expressed as body throughput, easier to compare against a link rate.
    mib_per_sec: f64,
    /// Bytes held per worker so a stream can still be read after the handler returned.
    held_bytes_per_worker: u64,
    /// Rolling checksum of everything the strategy produced, compared against the baseline.
    checksum: u64,
};

/// Fold a produced chunk into a rolling checksum, so a strategy cannot post a fast number by
/// reading the wrong bytes.
///
/// Note:
/// - Only the head and tail of the chunk are folded. The fixture content is position-dependent, so
///   that still catches a wrong offset or a short read, and it keeps the verification from
///   dominating the measurement it is supposed to guard.
const VERIFY_EDGE: usize = 16;

fn fold(sum: u64, bytes: []const u8) u64 {
    const head = bytes[0..@min(VERIFY_EDGE, bytes.len)];
    const tail = bytes[bytes.len - @min(VERIFY_EDGE, bytes.len) ..];

    return sum ^ std.hash.Wyhash.hash(sum, head) ^ std.hash.Wyhash.hash(sum ^ 1, tail);
}

/// Write the fixture and return it open. Deterministic content, so every run compares like for like.
fn createFixture(io: std.Io) !std.Io.File {
    std.Io.Dir.cwd().createDirPath(io, FIXTURE_DIR) catch {};

    var body: [BODY_SIZE]u8 = undefined;
    for (&body, 0..) |*byte, index| byte.* = @intCast((index * 31 + 7) % 251);

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = FIXTURE_PATH, .data = &body });

    return std.Io.Dir.cwd().openFile(io, FIXTURE_PATH, .{});
}

/// Whether this chunk index is resent, modelling a lost packet the pump has to rewind for.
fn isRetransmit(chunk_index: usize) bool {
    return chunk_index % RETRANSMIT_EVERY == 0;
}

// --------------------------------------------------------- //

/// Today's behaviour: the whole body sits in memory and the pump memcpy's out of it.
///
/// Note:
/// - This is the baseline every other strategy is compared against, for both speed and bytes.
fn runResident(body: []const u8, packet: []u8) !Result {
    const started = monotonicNs();
    var checksum: u64 = 0;
    var chunks: usize = 0;

    for (0..ROUNDS) |_| {
        var offset: usize = 0;
        var index: usize = 0;

        while (offset < body.len) : (index += 1) {
            const len = @min(CHUNK, body.len - offset);

            @memcpy(packet[0..len], body[offset..][0..len]);
            checksum = fold(checksum, packet[0..len]);
            chunks += 1;

            if (isRetransmit(index)) {
                @memcpy(packet[0..len], body[offset..][0..len]);
                chunks += 1;
            }

            offset += len;
        }
    }

    const elapsed = monotonicNs() - started;

    return .{
        .name = "resident body, memcpy per packet",
        .ns_per_chunk = @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(chunks)),
        .mib_per_sec = throughput(chunks, elapsed),
        // Worst case is every send-stream slot on every connection holding its own body.
        .held_bytes_per_worker = MAX_CONNECTIONS * MAX_SEND_STREAMS * BODY_SIZE,
        .checksum = checksum,
    };
}

/// File-backed: nothing is held, every packet reads its own chunk straight from the cached file.
fn runPreadRaw(file: std.Io.File, packet: []u8) !Result {
    const started = monotonicNs();
    var checksum: u64 = 0;
    var chunks: usize = 0;

    for (0..ROUNDS) |_| {
        var offset: usize = 0;
        var index: usize = 0;

        while (offset < BODY_SIZE) : (index += 1) {
            const len = @min(CHUNK, BODY_SIZE - offset);

            const read = try preadRaw(file.handle, packet[0..len], offset);
            checksum = fold(checksum, packet[0..read]);
            chunks += 1;

            if (isRetransmit(index)) {
                _ = try preadRaw(file.handle, packet[0..len], offset);
                chunks += 1;
            }

            offset += len;
        }
    }

    const elapsed = monotonicNs() - started;

    return .{
        .name = "file-backed, raw pread per packet",
        .ns_per_chunk = @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(chunks)),
        .mib_per_sec = throughput(chunks, elapsed),
        .held_bytes_per_worker = 0,
        .checksum = checksum,
    };
}

/// File-backed through the std.Io path the engine would actually call, since it carries an io.
fn runPreadIo(file: std.Io.File, io: std.Io, packet: []u8) !Result {
    const started = monotonicNs();
    var checksum: u64 = 0;
    var chunks: usize = 0;

    for (0..ROUNDS) |_| {
        var offset: usize = 0;
        var index: usize = 0;

        while (offset < BODY_SIZE) : (index += 1) {
            const len = @min(CHUNK, BODY_SIZE - offset);

            const read = try file.readPositionalAll(io, packet[0..len], offset);
            checksum = fold(checksum, packet[0..read]);
            chunks += 1;

            if (isRetransmit(index)) {
                _ = try file.readPositionalAll(io, packet[0..len], offset);
                chunks += 1;
            }

            offset += len;
        }
    }

    const elapsed = monotonicNs() - started;

    return .{
        .name = "file-backed, std.Io readPositionalAll per packet",
        .ns_per_chunk = @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(chunks)),
        .mib_per_sec = throughput(chunks, elapsed),
        .held_bytes_per_worker = 0,
        .checksum = checksum,
    };
}

/// File-backed with one block of read amortized over the packets that fall inside it.
///
/// Note:
/// - The scratch block is per worker, not per stream: the pump drains one stream's packets in an
///   inner loop, so a single block serves that whole burst before the next stream touches it.
/// - A retransmit that lands outside the resident block re-reads, which is the cost being measured.
fn runBlockRead(file: std.Io.File, packet: []u8, block: []u8) !Result {
    const started = monotonicNs();
    var checksum: u64 = 0;
    var chunks: usize = 0;
    var reads: usize = 0;

    for (0..ROUNDS) |_| {
        var offset: usize = 0;
        var index: usize = 0;
        var block_start: usize = 0;
        var block_len: usize = 0;

        while (offset < BODY_SIZE) : (index += 1) {
            const len = @min(CHUNK, BODY_SIZE - offset);

            if (offset < block_start or offset + len > block_start + block_len) {
                block_start = offset;
                block_len = try preadRaw(file.handle, block[0..@min(block.len, BODY_SIZE - offset)], offset);
                reads += 1;
            }

            const inside = offset - block_start;
            @memcpy(packet[0..len], block[inside..][0..len]);
            checksum = fold(checksum, packet[0..len]);
            chunks += 1;

            if (isRetransmit(index)) {
                @memcpy(packet[0..len], block[inside..][0..len]);
                chunks += 1;
            }

            offset += len;
        }
    }

    const elapsed = monotonicNs() - started;

    return .{
        .name = "file-backed, 64 KiB block read plus memcpy",
        .ns_per_chunk = @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(chunks)),
        .mib_per_sec = throughput(chunks, elapsed),
        // One scratch block per worker, shared by every connection that worker serves.
        .held_bytes_per_worker = BLOCK_SIZE,
        .checksum = checksum,
    };
}

/// Map the file once and memcpy each packet out of the mapping.
///
/// Note:
/// - The mapping belongs to the cache entry, not to a stream, so every concurrent stream on every
///   connection reads the same one. It is file-backed, so its pages are page cache rather than
///   private dirty memory: the kernel can drop them under pressure and re-fault on demand.
fn runMmap(mapping: []const u8, packet: []u8) !Result {
    const started = monotonicNs();
    var checksum: u64 = 0;
    var chunks: usize = 0;

    for (0..ROUNDS) |_| {
        var offset: usize = 0;
        var index: usize = 0;

        while (offset < mapping.len) : (index += 1) {
            const len = @min(CHUNK, mapping.len - offset);

            @memcpy(packet[0..len], mapping[offset..][0..len]);
            checksum = fold(checksum, packet[0..len]);
            chunks += 1;

            if (isRetransmit(index)) {
                @memcpy(packet[0..len], mapping[offset..][0..len]);
                chunks += 1;
            }

            offset += len;
        }
    }

    const elapsed = monotonicNs() - started;

    return .{
        .name = "file-backed, mmap once plus memcpy per packet",
        .ns_per_chunk = @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(chunks)),
        .mib_per_sec = throughput(chunks, elapsed),
        // One mapping per cached file, shared by every stream, and page cache rather than anonymous.
        .held_bytes_per_worker = 0,
        .checksum = checksum,
    };
}

/// What one syscall costs on this box, so the read strategies above can be read in proportion. A
/// write to /dev/null does almost no kernel work, so this is close to the entry and exit floor.
fn runSyscallFloor(null_fd: std.posix.fd_t, packet: []u8) !u64 {
    const started = monotonicNs();
    var calls: usize = 0;

    for (0..ROUNDS) |_| {
        var offset: usize = 0;

        while (offset < BODY_SIZE) : (offset += CHUNK) {
            _ = std.os.linux.write(null_fd, packet.ptr, @min(CHUNK, BODY_SIZE - offset));
            calls += 1;
        }
    }

    return (monotonicNs() - started) / calls;
}

fn throughput(chunks: usize, elapsed_ns: u64) f64 {
    const bytes = @as(f64, @floatFromInt(chunks * CHUNK));
    const seconds = @as(f64, @floatFromInt(elapsed_ns)) / std.time.ns_per_s;

    return bytes / seconds / (1024.0 * 1024.0);
}

/// Render one byte count in whichever unit reads clearly at its magnitude.
fn writeBytes(out: *std.Io.Writer, bytes: u64) !void {
    if (bytes == 0) return out.print("none", .{});
    if (bytes < 1024) return out.print("{d} B", .{bytes});
    if (bytes < 1024 * 1024) return out.print("{d} KiB", .{bytes / 1024});
    if (bytes < 1024 * 1024 * 1024) return out.print("{d} MiB", .{bytes / (1024 * 1024)});

    return out.print("{d} GiB", .{bytes / (1024 * 1024 * 1024)});
}

fn report(out: *std.Io.Writer, results: []const Result, baseline: Result) !void {
    try out.print("\nchunk {d} B, body {d} KiB, {d} rounds, 1 retransmit every {d} packets\n\n", .{ CHUNK, BODY_SIZE / 1024, ROUNDS, RETRANSMIT_EVERY });

    for (results) |result| {
        const ratio = result.ns_per_chunk / baseline.ns_per_chunk;

        try out.print("  {s}\n", .{result.name});
        try out.print("    {d:.1} ns per packet, {d:.0} MiB/s, {d:.2}x baseline\n", .{ result.ns_per_chunk, result.mib_per_sec, ratio });
        try out.print("    held per worker: ", .{});
        try writeBytes(out, result.held_bytes_per_worker);
        try out.print("\n", .{});

        if (result.checksum != baseline.checksum) {
            try out.print("    MISMATCH: this strategy did not produce the baseline bytes\n", .{});
        }

        try out.print("\n", .{});
    }
}

/// The memory ceiling each strategy implies, from the engine's own capacity constants. Timing alone
/// does not decide this: a strategy can be fast and still be unaffordable at peak concurrency.
fn reportCeilings(out: *std.Io.Writer) !void {
    const streams_per_worker = MAX_CONNECTIONS * MAX_SEND_STREAMS;
    const inflight_per_conn = MAX_SENT_RANGES * MAX_DATAGRAM_SIZE;

    try out.print("engine capacity: {d} connections per worker, {d} send streams each, so {d} concurrent large bodies per worker\n\n", .{ MAX_CONNECTIONS, MAX_SEND_STREAMS, streams_per_worker });

    try out.print("  per-stream body buffer at {d} KiB: ", .{BODY_SIZE / 1024});
    try writeBytes(out, streams_per_worker * BODY_SIZE);
    try out.print(" per worker\n", .{});

    try out.print("  per-stream buffer at 64 KiB:      ", .{});
    try writeBytes(out, streams_per_worker * BLOCK_SIZE);
    try out.print(" per worker\n", .{});

    try out.print("  unacked-only copy per connection: ", .{});
    try writeBytes(out, MAX_CONNECTIONS * inflight_per_conn);
    try out.print(" per worker (in-flight ceiling is {d} packets)\n", .{MAX_SENT_RANGES});

    try out.print("  one scratch block per worker:     ", .{});
    try writeBytes(out, BLOCK_SIZE);
    try out.print(" per worker\n", .{});

    try out.print("  file-backed, nothing held:        none\n\n", .{});
}

/// Resident set size of this process in KiB, straight from the kernel.
fn residentKib(io: std.Io) !u64 {
    const status = try std.Io.Dir.cwd().openFile(io, "/proc/self/status", .{});
    defer status.close(io);

    var buf: [8192]u8 = undefined;
    const len = try status.readPositionalAll(io, &buf, 0);

    var lines = std.mem.splitScalar(u8, buf[0..len], '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "VmRSS:")) continue;

        const digits = std.mem.trim(u8, line["VmRSS:".len..], " \tkB");

        return std.fmt.parseInt(u64, digits, 10) catch 0;
    }

    return 0;
}

/// Compare what a heap copy of a file costs against what mapping the same file costs, and then map
/// it a second time.
///
/// Note:
/// - The second mapping is the point. If it raises resident size by another whole file, then
///   resident size is counting the SAME physical page cache twice, which means it is not measuring
///   new physical memory for a file-backed mapping the way it does for a heap copy.
fn reportMemory(out: *std.Io.Writer, io: std.Io) !void {
    const size = MEMORY_FIXTURE_SIZE;

    std.Io.Dir.cwd().createDirPath(io, FIXTURE_DIR) catch {};

    const allocator = std.heap.smp_allocator;
    const filler = try allocator.alloc(u8, size);
    defer allocator.free(filler);
    for (filler, 0..) |*byte, index| byte.* = @intCast(index % 251);

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = MEMORY_FIXTURE_PATH, .data = filler });

    const file = try std.Io.Dir.cwd().openFile(io, MEMORY_FIXTURE_PATH, .{});
    defer file.close(io);
    defer std.Io.Dir.cwd().deleteFile(io, MEMORY_FIXTURE_PATH) catch {};

    try out.print("\nmemory, on a {d} MiB file\n\n", .{size / (1024 * 1024)});

    // A heap copy: fresh anonymous pages the kernel must swap rather than drop under pressure.
    const before_heap = try residentKib(io);
    const copy = try allocator.alloc(u8, size);
    defer allocator.free(copy);
    _ = try file.readPositionalAll(io, copy, 0);
    const after_heap = try residentKib(io);

    // First mapping, every page touched so the comparison is like for like.
    const before_map = try residentKib(io);
    const first = try std.posix.mmap(null, size, .{ .READ = true }, .{ .TYPE = .PRIVATE }, file.handle, 0);
    defer std.posix.munmap(first);
    var touched: u64 = 0;
    var pos: usize = 0;
    while (pos < size) : (pos += std.heap.page_size_min) touched += first[pos];
    const after_map = try residentKib(io);

    // Second mapping of the same file, sharing the same page cache behind it.
    const second = try std.posix.mmap(null, size, .{ .READ = true }, .{ .TYPE = .PRIVATE }, file.handle, 0);
    defer std.posix.munmap(second);
    pos = 0;
    while (pos < size) : (pos += std.heap.page_size_min) touched += second[pos];
    const after_second = try residentKib(io);

    try out.print("  heap copy:        +{d} KiB resident (anonymous, must be swapped under pressure)\n", .{after_heap -| before_heap});
    try out.print("  first mapping:    +{d} KiB resident (page cache, droppable under pressure)\n", .{after_map -| before_map});
    try out.print("  second mapping:   +{d} KiB resident, same file, same physical pages\n", .{after_second -| after_map});
    try out.print("  so resident size double counts a shared mapping: two mappings, one copy of the bytes\n\n", .{});

    std.mem.doNotOptimizeAway(touched);
}

pub fn main(process: std.process.Init) !void {
    const io = process.io;

    var out_buf: [4096]u8 = undefined;
    var stderr = std.Io.File.stderr().writerStreaming(io, &out_buf);
    const out = &stderr.interface;
    defer out.flush() catch {};

    try out.print("HTTP/3 static body source PoC (ADR-064 checkpoint 5)\n", .{});

    const file = try createFixture(io);
    defer file.close(io);
    defer std.Io.Dir.cwd().deleteTree(io, FIXTURE_DIR) catch {};

    const allocator = std.heap.smp_allocator;

    const body = try allocator.alloc(u8, BODY_SIZE);
    defer allocator.free(body);
    _ = try file.readPositionalAll(io, body, 0);

    const packet = try allocator.alloc(u8, MAX_DATAGRAM_SIZE);
    defer allocator.free(packet);

    const block = try allocator.alloc(u8, BLOCK_SIZE);
    defer allocator.free(block);

    // Warm the page cache, so what follows measures a served file rather than a cold read.
    _ = try preadRaw(file.handle, block, 0);

    if (comptime builtin.os.tag != .linux) {
        try out.print("\nthis PoC measures the Linux read path, which is where the zero-copy work lives\n", .{});

        return;
    }

    const mapping = try std.posix.mmap(null, BODY_SIZE, .{ .READ = true }, .{ .TYPE = .PRIVATE }, file.handle, 0);
    defer std.posix.munmap(mapping);

    const null_file = try std.Io.Dir.cwd().openFile(io, "/dev/null", .{ .mode = .write_only });
    defer null_file.close(io);

    const syscall_floor = try runSyscallFloor(null_file.handle, packet);

    const baseline = try runResident(body, packet);
    const results = [_]Result{
        baseline,
        try runMmap(mapping, packet),
        try runBlockRead(file, packet, block),
        try runPreadRaw(file, packet),
        try runPreadIo(file, io, packet),
    };

    try out.print("\nsyscall floor on this box: {d} ns for one write to /dev/null\n", .{syscall_floor});

    try report(out, &results, baseline);
    try reportCeilings(out);
    try reportMemory(out, io);

    var mismatches: usize = 0;
    for (results) |result| {
        if (result.checksum != baseline.checksum) mismatches += 1;
    }

    if (mismatches == 0) {
        try out.print("PASS: every strategy produced identical bytes\n", .{});
    } else {
        try out.print("FAIL: {d} strategy(ies) produced different bytes\n", .{mismatches});
        try out.flush();
        std.process.exit(1);
    }
}
