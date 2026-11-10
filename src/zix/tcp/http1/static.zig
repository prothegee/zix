//! ZIX Http1 static
//!
//! ### file: src/zix/tcp/http1/static.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Serve files from public_dir when no route matched, with Range support and
//! precompressed siblings.
//!
//! ### note:
//!
//! The router reads public_dir and io from threadlocals, installed per worker
//! by setStatic, since the fallback runs before any handler.
//! The cached path is tried first. Without a cache, or when the cache declines,
//! the uncached open, stat, and send path runs.
//!
//! ---------------------------------------------------------
//!
//! ### licenses:
//!
//! - BSD-3-Clause
//!
//! ### copyright:
//!
//! - (c) Prana Ron // @prothegee // prothegee@pm.me
//!
//! ### contributors:
//!
//! - Prana Ron // @prothegee // prothegee@pm.me
//!

const std = @import("std");
const builtin = @import("builtin");
const ParsedHead = @import("ParsedHead.zig");
const parser = @import("parser.zig");
const writer = @import("writer.zig");
const content = @import("../../utils/http/content.zig");
const Range = @import("../../utils/http/Range.zig");
const range_header = @import("../../utils/http/range_header.zig");
const file_utils = @import("../../utils/file.zig");
const StaticCache = @import("../../utils/static/StaticCache.zig");
const StaticCacheRegistry = @import("../../utils/static/StaticCacheRegistry.zig");
const StaticHit = @import("../../utils/static/StaticHit.zig");
const cache_path = @import("../../utils/static/cache_path.zig");
const static_body = @import("../../utils/static/static.zig");

// --------------------------------------------------------- //
// Private:

/// Response header staging buffer for 206 and the uncached 200.
const HEADER_STAGING_BUF: usize = 2048;

/// Static root for this worker. Empty disables the fallback.
threadlocal var tl_public_dir: []const u8 = "";

/// Io for this worker's static file access.
threadlocal var tl_io: ?std.Io = null;

/// What the Range header asks for, against a known size.
const RangeAsk = union(enum) {
    /// No header or a malformed one: send the whole file.
    FULL,
    /// A satisfiable range: send 206.
    PARTIAL: Range,
    /// A valid range past the end: send 416.
    UNSATISFIABLE,
};

/// Coarse monotonic clock for the cache TTL.
fn nowMillis(io: std.Io) u64 {
    return @intCast(std.Io.Clock.Timestamp.now(io, .awake).raw.toMilliseconds());
}

/// Whether the body may go straight from the file to the socket.
fn zeroCopyAllowed(fd: std.posix.fd_t) bool {
    if (comptime builtin.os.tag != .linux) return false;

    return fd >= 0;
}

/// Flush anything staged in this worker's sink for fd, so a zero-copy body
/// cannot overtake its own header.
fn flushPending(fd: std.posix.fd_t) void {
    const sink = writer.tl_resp_sink orelse return;
    if (sink.fd != fd) return;

    sink.materializeDirect();
    sink.flush();
}

/// writer.writeAllFD in the static_body error set, for the copy path.
fn writeBody(fd: std.posix.fd_t, data: []const u8) static_body.Error!void {
    writer.writeAllFD(fd, data) catch |err| switch (err) {
        error.ZixHttp1_Writer_BrokenPipe,
        error.ZixHttp1_Writer_HeadBuild,
        => return static_body.Error.ZixUtils_Static_BrokenPipe,
    };
}

/// Render a 206 header.
///
/// Param:
/// buf - []u8 (output)
/// content_type - []const u8 (MIME type)
/// coding - ?[]const u8 (Content-Encoding token, null for identity)
/// vary - bool (true when the body was negotiated)
/// range - Range (resolved range)
/// total - u64 (full representation size)
///
/// Return:
/// - []const u8 (rendered slice inside buf)
/// - null when it does not fit
fn renderPartial(
    buf: []u8,
    content_type: []const u8,
    coding: ?[]const u8,
    vary: bool,
    range: Range,
    total: u64,
) ?[]const u8 {
    var stream: std.Io.Writer = .fixed(buf);

    stream.print(
        "HTTP/1.1 206 Partial Content\r\nContent-Type: {s}\r\nContent-Length: {d}\r\n",
        .{ content_type, range.length() },
    ) catch |err| switch (err) {
        error.WriteFailed => return null,
    };

    if (coding) |token| {
        stream.print("Content-Encoding: {s}\r\n", .{token}) catch |err| switch (err) {
            error.WriteFailed => return null,
        };
    }

    stream.print(
        "Content-Range: bytes {d}-{d}/{d}\r\nAccept-Ranges: bytes\r\n",
        .{ range.start, range.end, total },
    ) catch |err| switch (err) {
        error.WriteFailed => return null,
    };

    if (vary) stream.writeAll("Vary: Accept-Encoding\r\n") catch |err| switch (err) {
        error.WriteFailed => return null,
    };

    stream.writeAll("Connection: keep-alive\r\n\r\n") catch |err| switch (err) {
        error.WriteFailed => return null,
    };

    return stream.buffered();
}

/// Render the 416 answer for a valid range past the end of the file.
fn renderUnsatisfiable(buf: []u8, total: u64) ?[]const u8 {
    return std.fmt.bufPrint(
        buf,
        "HTTP/1.1 416 Range Not Satisfiable\r\nContent-Range: bytes */{d}\r\n" ++
            "Content-Length: 0\r\nConnection: keep-alive\r\n\r\n",
        .{total},
    ) catch |err| switch (err) {
        error.NoSpaceLeft => null,
    };
}

/// Render the uncached 200 header.
fn renderFull(buf: []u8, content_type: []const u8, size: u64) ?[]const u8 {
    return std.fmt.bufPrint(
        buf,
        "HTTP/1.1 200 OK\r\nContent-Type: {s}\r\nContent-Length: {d}\r\n" ++
            "Accept-Ranges: bytes\r\nConnection: keep-alive\r\n\r\n",
        .{ content_type, size },
    ) catch |err| switch (err) {
        error.NoSpaceLeft => null,
    };
}

fn rangeAsk(head: *const ParsedHead, total: u64) RangeAsk {
    const value = parser.getHeader(head, "range") orelse return .FULL;
    const spec = range_header.parseSpec(value) orelse return .FULL;
    const range = range_header.resolve(spec, total) orelse return .UNSATISFIABLE;

    return .{ .PARTIAL = range };
}

/// Write a header, then a body range of the file.
///
/// Note:
/// - Write errors end the response here. A broken peer is not a missing file.
fn sendFile(
    fd: std.posix.fd_t,
    io: std.Io,
    file: std.Io.File,
    resident: ?[]const u8,
    header: []const u8,
    offset: u64,
    length: u64,
) void {
    const zero_copy = zeroCopyAllowed(fd);

    writer.writeAllFD(fd, header) catch |err| switch (err) {
        error.ZixHttp1_Writer_BrokenPipe,
        error.ZixHttp1_Writer_HeadBuild,
        => return,
    };

    if (resident) |body| {
        const slice = body[@intCast(offset)..][0..@intCast(length)];

        writer.writeAllFD(fd, slice) catch |err| switch (err) {
            // Peer gone mid body, nothing left to answer.
            error.ZixHttp1_Writer_BrokenPipe,
            error.ZixHttp1_Writer_HeadBuild,
            => {},
        };

        return;
    }

    if (zero_copy) flushPending(fd);

    const sent = static_body.sendBody(fd, io, file, offset, length, zero_copy, writeBody);

    sent catch |err| switch (err) {
        // Peer gone or file changed under the handle, the header is already out.
        error.ZixUtils_Static_BrokenPipe,
        error.ZixUtils_Static_FileUnreadable,
        error.ZixUtils_Static_FileTruncated,
        => {},
    };
}

/// Answer one request from file bytes, honouring Range.
fn answer(
    fd: std.posix.fd_t,
    io: std.Io,
    head: *const ParsedHead,
    file: std.Io.File,
    resident: ?[]const u8,
    full_header: []const u8,
    content_type: []const u8,
    coding: ?[]const u8,
    vary: bool,
    size: u64,
) void {
    var header_buf: [HEADER_STAGING_BUF]u8 = undefined;

    switch (rangeAsk(head, size)) {
        .FULL => sendFile(fd, io, file, resident, full_header, 0, size),
        .PARTIAL => |range| {
            const partial =
                renderPartial(&header_buf, content_type, coding, vary, range, size) orelse
                return sendFile(fd, io, file, resident, full_header, 0, size);

            sendFile(fd, io, file, resident, partial, range.start, range.length());
        },
        .UNSATISFIABLE => {
            const refused = renderUnsatisfiable(&header_buf, size) orelse return;

            writer.writeAllFD(fd, refused) catch |err| switch (err) {
                error.ZixHttp1_Writer_BrokenPipe,
                error.ZixHttp1_Writer_HeadBuild,
                => {},
            };
        },
    }
}

/// Take a cache hit, with resident bytes when sendfile cannot carry the body.
fn acquireHit(
    cache: *StaticCache,
    head: *const ParsedHead,
    fd: std.posix.fd_t,
    req_path: []const u8,
    public_dir: []const u8,
    io: std.Io,
) ?StaticHit {
    const accept_encoding = parser.acceptEncoding(head);
    const ttl_ms = StaticCacheRegistry.shared.ttl_ms;
    const now_ms = nowMillis(io);

    if (!zeroCopyAllowed(fd)) {
        const resident = cache.acquireMapped(
            io,
            public_dir,
            req_path,
            accept_encoding,
            ttl_ms,
            now_ms,
        );
        if (resident) |pinned| return pinned;
    }

    return cache.acquire(io, public_dir, req_path, accept_encoding, ttl_ms, now_ms);
}

/// Serve from the static cache when one is installed and takes the path.
///
/// Return:
/// - bool (false when there is no cache or it declined, the caller falls back)
fn serveCached(
    head: *const ParsedHead,
    fd: std.posix.fd_t,
    req_path: []const u8,
    public_dir: []const u8,
    io: std.Io,
) bool {
    const cache = StaticCacheRegistry.shared.instance() orelse return false;
    const pinned = acquireHit(cache, head, fd, req_path, public_dir, io) orelse return false;
    defer cache.release(pinned);

    answer(
        fd,
        io,
        head,
        pinned.file,
        pinned.bytes,
        pinned.header,
        pinned.content_type,
        pinned.encoding.contentEncoding(),
        true,
        pinned.size,
    );

    return true;
}

/// Open, stat, and send the file without the cache.
///
/// Return:
/// - bool (false when the path is unsafe or the file is missing)
fn serveUncached(
    head: *const ParsedHead,
    fd: std.posix.fd_t,
    req_path: []const u8,
    public_dir: []const u8,
    io: std.Io,
) bool {
    var path_buf: [cache_path.PUBLIC_PATH_MAX]u8 = undefined;
    const full_path = cache_path.resolve(&path_buf, public_dir, req_path) orelse return false;

    const file = std.Io.Dir.cwd().openFile(io, full_path, .{}) catch |err| switch (err) {
        else => return false,
    };
    defer file.close(io);

    const stat = file.stat(io) catch |err| switch (err) {
        else => return false,
    };
    if (stat.kind != .file) return false;

    const content_type = content.fromExtension(file_utils.extension(req_path));

    var header_buf: [HEADER_STAGING_BUF]u8 = undefined;
    const full_header = renderFull(&header_buf, content_type, stat.size) orelse return false;

    answer(fd, io, head, file, null, full_header, content_type, null, false, stat.size);

    return true;
}

// --------------------------------------------------------- //
// Public:

/// Install this worker's static root. An empty public_dir turns the fallback
/// off.
///
/// Param:
/// public_dir - []const u8 (static root, must outlive the worker)
/// io - std.Io (file access)
pub fn setStatic(public_dir: []const u8, io: std.Io) void {
    tl_public_dir = public_dir;
    tl_io = io;
}

/// Serve a file from public_dir.
///
/// Note:
/// - `..`, an absolute path, and a directory are refused.
/// - A malformed Range is ignored (200). A valid Range past the end is 416.
///
/// Param:
/// head - *const ParsedHead (Range and Accept-Encoding are read from it)
/// fd - std.posix.fd_t (socket)
/// req_path - []const u8 (request path with the leading slash stripped)
/// public_dir - []const u8 (static root)
/// io - std.Io (file access)
///
/// Return:
/// - bool (true when a response was written, false when the caller sends 404)
pub fn serve(
    head: *const ParsedHead,
    fd: std.posix.fd_t,
    req_path: []const u8,
    public_dir: []const u8,
    io: std.Io,
) bool {
    if (serveCached(head, fd, req_path, public_dir, io)) return true;

    return serveUncached(head, fd, req_path, public_dir, io);
}

/// The router fallback: serve the request path from this worker's root.
///
/// Param:
/// head - *const ParsedHead (request head)
/// fd - std.posix.fd_t (socket)
///
/// Return:
/// - bool (true when a response was written)
pub fn fallback(head: *const ParsedHead, fd: std.posix.fd_t) bool {
    if (tl_public_dir.len == 0) return false;

    const io = tl_io orelse return false;
    const path = head.path;
    const stripped = if (path.len > 0 and path[0] == '/') path[1..] else path;
    if (stripped.len == 0) return false;

    return serve(head, fd, stripped, tl_public_dir, io);
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const pair = @import("../../utils/socket/pair.zig");

/// A descriptor no test path writes to.
const NO_FD: std.posix.fd_t = if (builtin.os.tag == .windows)
    std.os.windows.INVALID_HANDLE_VALUE
else
    -1;

fn testHead(path: []const u8, raw_headers: []const u8) ParsedHead {
    return .{
        .method = "GET",
        .path = path,
        .query = "",
        .raw_headers = raw_headers,
        .version_minor = 1,
        .keep_alive = true,
        .content_length = 0,
        .chunked_request = false,
        .expect_continue = false,
    };
}

fn writeFixture(tmp: *std.testing.TmpDir, name: []const u8, data: []const u8) void {
    tmp.dir.writeFile(std.testing.io, .{
        .sub_path = name,
        .data = data,
    }) catch |err| switch (err) {
        else => @panic("fixture write failed"),
    };
}

fn fixtureRoot(tmp: *std.testing.TmpDir, buf: []u8) []const u8 {
    const root = std.fmt.bufPrint(buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    return root catch |err| switch (err) {
        error.NoSpaceLeft => @panic("fixture path too long"),
    };
}

/// Read what the peer end holds right now.
fn readPeer(peer: std.posix.fd_t, buf: []u8) []const u8 {
    const rc = std.posix.system.read(peer, buf.ptr, buf.len);
    if (std.posix.errno(rc) != .SUCCESS) return &.{};

    return buf[0..@intCast(rc)];
}

/// Serve one request over a socket pair and return what reached the peer.
fn serveWire(
    root: []const u8,
    req_path: []const u8,
    raw_headers: []const u8,
    wire_buf: []u8,
) ![]const u8 {
    // The wire is read back with a POSIX read.
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;

    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    const head = testHead(req_path, raw_headers);
    try std.testing.expect(serve(&head, fds[0], req_path, root, std.testing.io));

    return readPeer(fds[1], wire_buf);
}

test "zix http1: static, renderPartial states the range" {
    var buf: [HEADER_STAGING_BUF]u8 = undefined;
    const header = renderPartial(&buf, "text/plain", null, false, .{
        .start = 10,
        .end = 19,
    }, 100).?;

    try std.testing.expect(std.mem.startsWith(u8, header, "HTTP/1.1 206 Partial Content\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, header, "Content-Length: 10\r\n") != null);
    const content_range = "Content-Range: bytes 10-19/100\r\n";

    try std.testing.expect(std.mem.indexOf(u8, header, content_range) != null);
}

test "zix http1: static, renderPartial identity has no Content-Encoding" {
    var buf: [HEADER_STAGING_BUF]u8 = undefined;
    const header = renderPartial(&buf, "text/plain", null, false, .{
        .start = 0,
        .end = 0,
    }, 1).?;

    try std.testing.expect(std.mem.indexOf(u8, header, "Content-Encoding") == null);
    try std.testing.expect(std.mem.indexOf(u8, header, "Vary") == null);
}

test "zix http1: static, renderPartial repeats the coding" {
    var buf: [HEADER_STAGING_BUF]u8 = undefined;
    const header = renderPartial(&buf, "application/javascript", "br", true, .{
        .start = 0,
        .end = 9,
    }, 40).?;

    try std.testing.expect(std.mem.indexOf(u8, header, "Content-Encoding: br\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, header, "Vary: Accept-Encoding\r\n") != null);
}

test "zix http1: static, renderPartial too small buffer is null" {
    var tiny: [16]u8 = undefined;

    try std.testing.expect(renderPartial(&tiny, "text/plain", null, false, .{
        .start = 0,
        .end = 0,
    }, 1) == null);
}

test "zix http1: static, renderUnsatisfiable names the size" {
    var buf: [HEADER_STAGING_BUF]u8 = undefined;
    const header = renderUnsatisfiable(&buf, 10).?;

    try std.testing.expect(std.mem.startsWith(u8, header, "HTTP/1.1 416 "));
    try std.testing.expect(std.mem.indexOf(u8, header, "Content-Range: bytes */10\r\n") != null);
}

test "zix http1: static, rangeAsk without a header is FULL" {
    const head = testHead("/a", "");

    try std.testing.expect(rangeAsk(&head, 10) == .FULL);
}

test "zix http1: static, rangeAsk malformed is FULL" {
    const head = testHead("/a", "Range: items=0-1\r\n");

    try std.testing.expect(rangeAsk(&head, 10) == .FULL);
}

test "zix http1: static, rangeAsk past the end is UNSATISFIABLE" {
    const head = testHead("/a", "Range: bytes=50-\r\n");

    try std.testing.expect(rangeAsk(&head, 10) == .UNSATISFIABLE);
}

test "zix http1: static, rangeAsk valid range is PARTIAL" {
    const head = testHead("/a", "Range: bytes=2-5\r\n");
    const ask = rangeAsk(&head, 10);

    try std.testing.expectEqual(@as(u64, 4), ask.PARTIAL.length());
}

test "zix http1: static, serve traversal is false" {
    const head = testHead("/../etc/passwd", "");

    try std.testing.expect(!serve(&head, NO_FD, "../etc/passwd", "./public", std.testing.io));
}

test "zix http1: static, serve missing file is false" {
    const head = testHead("/none.txt", "");

    try std.testing.expect(!serve(&head, NO_FD, "none.txt", "./public", std.testing.io));
}

test "zix http1: static, serve directory is false" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDir(std.testing.io, "sub", .default_dir);

    var root_buf: [64]u8 = undefined;
    const root = fixtureRoot(&tmp, &root_buf);
    const head = testHead("/sub", "");

    try std.testing.expect(!serve(&head, NO_FD, "sub", root, std.testing.io));
}

test "zix http1: static, serve path past PUBLIC_PATH_MAX is false" {
    const long: [cache_path.PUBLIC_PATH_MAX]u8 = @splat('a');
    const head = testHead("/x", "");

    try std.testing.expect(!serve(&head, NO_FD, &long, "./public", std.testing.io));
}

test "zix http1: static, uncached serve sends 200 with the body" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    writeFixture(&tmp, "plain.txt", "uncached body");

    var root_buf: [64]u8 = undefined;
    var wire_buf: [512]u8 = undefined;
    const wire = try serveWire(fixtureRoot(&tmp, &root_buf), "plain.txt", "", &wire_buf);

    try std.testing.expect(std.mem.startsWith(u8, wire, "HTTP/1.1 200 OK\r\n"));
    try std.testing.expect(std.mem.endsWith(u8, wire, "\r\n\r\nuncached body"));
}

test "zix http1: static, uncached serve resolves the MIME type" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    writeFixture(&tmp, "page.html", "<h1>x</h1>");

    var root_buf: [64]u8 = undefined;
    var wire_buf: [512]u8 = undefined;
    const wire = try serveWire(fixtureRoot(&tmp, &root_buf), "page.html", "", &wire_buf);

    try std.testing.expect(std.mem.indexOf(u8, wire, "Content-Type: text/html\r\n") != null);
}

test "zix http1: static, uncached serve emits no Vary" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    writeFixture(&tmp, "plain.txt", "body");

    var root_buf: [64]u8 = undefined;
    var wire_buf: [512]u8 = undefined;
    const wire = try serveWire(fixtureRoot(&tmp, &root_buf), "plain.txt", "", &wire_buf);

    try std.testing.expect(std.mem.indexOf(u8, wire, "Vary") == null);
}

test "zix http1: static, uncached Range is 206" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    writeFixture(&tmp, "clip.bin", "0123456789");

    var root_buf: [64]u8 = undefined;
    var wire_buf: [512]u8 = undefined;
    const root = fixtureRoot(&tmp, &root_buf);
    const wire = try serveWire(root, "clip.bin", "Range: bytes=2-5\r\n", &wire_buf);

    try std.testing.expect(std.mem.startsWith(u8, wire, "HTTP/1.1 206 Partial Content\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, wire, "Content-Range: bytes 2-5/10\r\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, wire, "\r\n\r\n2345"));
}

test "zix http1: static, uncached Range past the end is 416" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    writeFixture(&tmp, "clip.bin", "0123456789");

    var root_buf: [64]u8 = undefined;
    var wire_buf: [512]u8 = undefined;
    const root = fixtureRoot(&tmp, &root_buf);
    const wire = try serveWire(root, "clip.bin", "Range: bytes=50-\r\n", &wire_buf);

    const status_line = "HTTP/1.1 416 Range Not Satisfiable\r\n";

    try std.testing.expect(std.mem.startsWith(u8, wire, status_line));
    try std.testing.expect(std.mem.endsWith(u8, wire, "\r\n\r\n"));
}

test "zix http1: static, uncached malformed Range falls back to 200" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    writeFixture(&tmp, "clip.bin", "0123456789");

    var root_buf: [64]u8 = undefined;
    var wire_buf: [512]u8 = undefined;
    const root = fixtureRoot(&tmp, &root_buf);
    const wire = try serveWire(root, "clip.bin", "Range: bytes=-5\r\n", &wire_buf);

    try std.testing.expect(std.mem.startsWith(u8, wire, "HTTP/1.1 200 OK\r\n"));
    try std.testing.expect(std.mem.endsWith(u8, wire, "\r\n\r\n0123456789"));
}

test "zix http1: static, cached serve replays the 200 with Vary" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    writeFixture(&tmp, "page.html", "<h1>cached</h1>");

    _ = try StaticCacheRegistry.shared.install(16, 60_000);
    defer StaticCacheRegistry.shared.shutdown(std.testing.io);

    var root_buf: [64]u8 = undefined;
    var wire_buf: [512]u8 = undefined;
    const wire = try serveWire(fixtureRoot(&tmp, &root_buf), "page.html", "", &wire_buf);

    try std.testing.expect(std.mem.indexOf(u8, wire, "Vary: Accept-Encoding\r\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, wire, "\r\n\r\n<h1>cached</h1>"));
}

test "zix http1: static, cached serve hit keeps the slot" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    writeFixture(&tmp, "page.html", "<h1>cached</h1>");

    _ = try StaticCacheRegistry.shared.install(16, 60_000);
    defer StaticCacheRegistry.shared.shutdown(std.testing.io);

    var root_buf: [64]u8 = undefined;
    var wire_buf: [512]u8 = undefined;
    const root = fixtureRoot(&tmp, &root_buf);
    _ = try serveWire(root, "page.html", "", &wire_buf);
    _ = try serveWire(root, "page.html", "", &wire_buf);

    var live: usize = 0;
    const cache = StaticCacheRegistry.shared.instance().?;
    for (cache.slots) |*slot| {
        if (slot.isLive()) live += 1;
    }

    try std.testing.expectEqual(@as(usize, 1), live);
}

test "zix http1: static, cached Range is 206" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    writeFixture(&tmp, "clip.bin", "0123456789");

    _ = try StaticCacheRegistry.shared.install(16, 60_000);
    defer StaticCacheRegistry.shared.shutdown(std.testing.io);

    var root_buf: [64]u8 = undefined;
    var wire_buf: [512]u8 = undefined;
    const root = fixtureRoot(&tmp, &root_buf);
    const wire = try serveWire(root, "clip.bin", "Range: bytes=2-5\r\n", &wire_buf);

    try std.testing.expect(std.mem.indexOf(u8, wire, "Content-Range: bytes 2-5/10\r\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, wire, "\r\n\r\n2345"));
}

test "zix http1: static, cached serve sends the brotli sibling" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    writeFixture(&tmp, "bundle.js", "the plain bundle");
    writeFixture(&tmp, "bundle.js.br", "brotli");

    _ = try StaticCacheRegistry.shared.install(16, 60_000);
    defer StaticCacheRegistry.shared.shutdown(std.testing.io);

    var root_buf: [64]u8 = undefined;
    var wire_buf: [512]u8 = undefined;
    const root = fixtureRoot(&tmp, &root_buf);
    const wire = try serveWire(root, "bundle.js", "Accept-Encoding: br, gzip\r\n", &wire_buf);

    try std.testing.expect(std.mem.indexOf(u8, wire, "Content-Encoding: br\r\n") != null);
    const content_type = "Content-Type: application/javascript\r\n";

    try std.testing.expect(std.mem.indexOf(u8, wire, content_type) != null);
    try std.testing.expect(std.mem.endsWith(u8, wire, "\r\n\r\nbrotli"));
}

test "zix http1: static, cache off leaves the table empty" {
    try std.testing.expect(StaticCacheRegistry.shared.instance() == null);

    const head = testHead("/x.txt", "");

    try std.testing.expect(!serveCached(&head, NO_FD, "x.txt", "./public", std.testing.io));
}

test "zix http1: static, cached entry past its TTL is re-opened" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    writeFixture(&tmp, "ttl.txt", "first");

    _ = try StaticCacheRegistry.shared.install(16, 1);
    defer StaticCacheRegistry.shared.shutdown(std.testing.io);

    var root_buf: [64]u8 = undefined;
    var wire_buf: [512]u8 = undefined;
    const root = fixtureRoot(&tmp, &root_buf);
    _ = try serveWire(root, "ttl.txt", "", &wire_buf);

    writeFixture(&tmp, "ttl.txt", "second-longer");
    try std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(5), .awake);

    // The expired lookup reclaims the slot, the next request re-opens it.
    _ = try serveWire(root, "ttl.txt", "", &wire_buf);
    const wire = try serveWire(root, "ttl.txt", "", &wire_buf);

    try std.testing.expect(std.mem.endsWith(u8, wire, "\r\n\r\nsecond-longer"));
}

test "zix http1: static, fallback without a root is false" {
    setStatic("", std.testing.io);

    const head = testHead("/a.txt", "");

    try std.testing.expect(!fallback(&head, NO_FD));
}

test "zix http1: static, fallback for the root path is false" {
    setStatic("./public", std.testing.io);
    defer setStatic("", std.testing.io);

    const head = testHead("/", "");

    try std.testing.expect(!fallback(&head, NO_FD));
}

test "zix http1: static, fallback strips the leading slash" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    writeFixture(&tmp, "f.txt", "fallback");

    var root_buf: [64]u8 = undefined;
    setStatic(fixtureRoot(&tmp, &root_buf), std.testing.io);
    defer setStatic("", std.testing.io);

    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    const head = testHead("/f.txt", "");
    try std.testing.expect(fallback(&head, fds[0]));

    var wire_buf: [256]u8 = undefined;

    try std.testing.expect(std.mem.endsWith(u8, readPeer(fds[1], &wire_buf), "fallback"));
}

