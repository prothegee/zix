//! ZIX Http2 static
//!
//! ### file: src/zix/tcp/http2/static.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Serve files from public_dir when no route matched, as one HEADERS frame and
//! DATA frames, with Range support and precompressed siblings.
//!
//! ### note:
//!
//! - sendfile is used only while frames go straight to the socket. A writer
//!   that batches frames must make zeroCopyAllowed refuse, or the body
//!   overtakes its own HEADERS frame.
//! - Once the file resolves, the request is answered here, write errors
//!   included. A broken peer is not a missing file, so no 404 follows.
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
const Context = @import("Context.zig");
const Request = @import("Request.zig");
const control = @import("control.zig");
const frame = @import("frame.zig");
const writer = @import("writer.zig");
const HpackEncoder = @import("hpack/HpackEncoder.zig");
const response_block = @import("hpack/response_block.zig");
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

/// Rendered Content-Range value staging buffer.
const CONTENT_RANGE_BUF: usize = 64;

/// What a frame write or a body send can fail with.
const SendError = writer.Error || static_body.Error;

/// One servable file, from the cache or opened per request.
const Source = struct {
    file: std.Io.File,
    size: u64,
    content_type: []const u8,
    /// Content-Encoding token. Empty for identity.
    content_encoding: []const u8,
    /// Whole body, resident while the hit is pinned. DATA frames are cut from
    /// it instead of reading the file again.
    bytes: ?[]const u8 = null,
};

/// Which bytes of a source to send, and under what status.
const Segment = struct {
    offset: u64 = 0,
    length: u64,
    status: u16 = 200,
    /// Rendered `bytes start-end/total`. Empty for a 200.
    content_range: []const u8 = "",
};

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

/// writer.writeAllFD in the static_body error set, for the copy path.
fn writeBody(fd: std.posix.fd_t, data: []const u8) static_body.Error!void {
    writer.writeAllFD(fd, data) catch |err| switch (err) {
        error.ZixHttp2_Writer_BrokenPipe,
        error.ZixHttp2_Writer_UnexpectedEOF,
        error.ZixHttp2_Writer_Overflow,
        error.ZixHttp2_Writer_BufferFull,
        => return static_body.Error.ZixUtils_Static_BrokenPipe,
    };
}

/// Whole-file 200 for a source.
fn wholeOf(source: Source) Segment {
    return .{ .length = source.size };
}

fn rangeAsk(req: *const Request, total: u64) RangeAsk {
    const value = req.header("range") orelse return .FULL;
    const spec = range_header.parseSpec(value) orelse return .FULL;
    const range = range_header.resolve(spec, total) orelse return .UNSATISFIABLE;

    return .{ .PARTIAL = range };
}

/// Render the Content-Range value of a 206.
///
/// Return:
/// - []const u8 (rendered slice inside buf)
/// - null when it does not fit
fn renderContentRange(buf: []u8, range: Range, total: u64) ?[]const u8 {
    return std.fmt.bufPrint(
        buf,
        "bytes {d}-{d}/{d}",
        .{ range.start, range.end, total },
    ) catch |err| switch (err) {
        error.NoSpaceLeft => null,
    };
}

/// Encode the HEADERS block for a segment of a source.
///
/// Note:
/// - Content-Length is the segment length, not the file size. On a 206 the
///   two differ, and the file size makes the client wait for bytes that
///   never arrive.
///
/// Return:
/// - []const u8 (header block inside buf)
/// - null when it does not fit
fn encodeHead(buf: []u8, source: Source, segment: Segment) ?[]const u8 {
    const content_length: ?u64 = if (segment.length > 0) segment.length else null;
    const prefix_len = response_block.respHeaderBlock(
        buf,
        segment.status,
        source.content_type,
        source.content_encoding,
        content_length,
    ) catch |err| switch (err) {
        error.ZixHttp2_ResponseBlock_UnexpectedEOF,
        error.ZixHttp2_ResponseBlock_Overflow,
        error.ZixHttp2_ResponseBlock_BufferFull,
        => return null,
    };

    if (segment.content_range.len == 0) return buf[0..prefix_len];

    var encoder = HpackEncoder{
        .buf = buf,
        .pos = prefix_len,
    };

    encoder.writeHeader("content-range", segment.content_range) catch |err| switch (err) {
        error.ZixHttp2_HpackEncoder_UnexpectedEOF,
        error.ZixHttp2_HpackEncoder_Overflow,
        error.ZixHttp2_HpackEncoder_BufferFull,
        => return null,
    };
    encoder.writeHeader("accept-ranges", "bytes") catch |err| switch (err) {
        error.ZixHttp2_HpackEncoder_UnexpectedEOF,
        error.ZixHttp2_HpackEncoder_Overflow,
        error.ZixHttp2_HpackEncoder_BufferFull,
        => return null,
    };

    return encoder.encoded();
}

/// Encode the 416 HEADERS block for a file of total bytes.
///
/// Return:
/// - []const u8 (header block inside buf)
/// - null when it does not fit
fn encodeUnsatisfiable(buf: []u8, total: u64) ?[]const u8 {
    var range_buf: [CONTENT_RANGE_BUF]u8 = undefined;
    const content_range = std.fmt.bufPrint(&range_buf, "bytes */{d}", .{total}) catch |err|
        switch (err) {
            error.NoSpaceLeft => return null,
        };

    const prefix_len = response_block.respHeaderBlock(buf, 416, "text/plain", "", 0) catch |err|
        switch (err) {
            error.ZixHttp2_ResponseBlock_UnexpectedEOF,
            error.ZixHttp2_ResponseBlock_Overflow,
            error.ZixHttp2_ResponseBlock_BufferFull,
            => return null,
        };

    var encoder = HpackEncoder{
        .buf = buf,
        .pos = prefix_len,
    };

    encoder.writeHeader("content-range", content_range) catch |err| switch (err) {
        error.ZixHttp2_HpackEncoder_UnexpectedEOF,
        error.ZixHttp2_HpackEncoder_Overflow,
        error.ZixHttp2_HpackEncoder_BufferFull,
        => return null,
    };

    return encoder.encoded();
}

/// Write one HEADERS frame for a block.
fn writeHeaders(
    fd: std.posix.fd_t,
    sid: u31,
    block: []const u8,
    end_stream: bool,
) SendError!void {
    const end_flag: u8 = if (end_stream) frame.FLAG_END_STREAM else 0;

    try writer.writeFrameHeaderFD(fd, .{
        .length = @intCast(block.len),
        .frame_type = frame.FRAME_TYPE_HEADERS,
        .flags = frame.FLAG_END_HEADERS | end_flag,
        .stream_id = sid,
    });
    try writer.writeAllFD(fd, block);
}

/// Send one HEADERS frame, then the segment as DATA frames.
///
/// Note:
/// - Each DATA frame is capped at max_frame_size. A larger frame is a
///   FRAME_SIZE_ERROR at the peer. The last one carries END_STREAM.
/// - An empty segment closes the stream on the HEADERS frame.
fn sendFramed(
    ctx: *const Context,
    source: Source,
    segment: Segment,
    block: []const u8,
    max_frame_size: u32,
) SendError!void {
    try writeHeaders(ctx.fd, ctx.sid, block, segment.length == 0);

    if (segment.length == 0) return;

    const zero_copy = zeroCopyAllowed(ctx.fd);
    const chunk_cap: u64 = @max(1, max_frame_size);
    const end = segment.offset + segment.length;
    var offset: u64 = segment.offset;

    while (offset < end) {
        const chunk = @min(end - offset, chunk_cap);
        const last = offset + chunk == end;

        try writer.writeFrameHeaderFD(ctx.fd, .{
            .length = @intCast(chunk),
            .frame_type = frame.FRAME_TYPE_DATA,
            .flags = if (last) frame.FLAG_END_STREAM else 0,
            .stream_id = ctx.sid,
        });

        if (source.bytes) |body| {
            try writer.writeAllFD(ctx.fd, body[@intCast(offset)..][0..@intCast(chunk)]);
        } else {
            try static_body.sendBody(
                ctx.fd,
                ctx.io,
                source.file,
                offset,
                chunk,
                zero_copy,
                writeBody,
            );
        }

        offset += chunk;
    }
}

/// Close the stream with INTERNAL_ERROR when no response can be framed.
fn resetStream(ctx: *const Context) void {
    control.sendRstStreamFD(ctx.fd, ctx.sid, frame.ERR_INTERNAL_ERROR) catch |err|
        switch (err) {
            // Peer gone, nothing left to answer.
            else => {},
        };
}

/// Answer one request from a source, honouring Range.
fn answer(ctx: *const Context, req: *const Request, source: Source, max_frame_size: u32) void {
    var head_buf: [frame.HPACK_ENCODE_SCRATCH]u8 = undefined;
    var range_buf: [CONTENT_RANGE_BUF]u8 = undefined;

    var segment = switch (rangeAsk(req, source.size)) {
        .FULL => wholeOf(source),
        .PARTIAL => |range| Segment{
            .offset = range.start,
            .length = range.length(),
            .status = 206,
            .content_range = renderContentRange(&range_buf, range, source.size) orelse "",
        },
        .UNSATISFIABLE => {
            const refused = encodeUnsatisfiable(&head_buf, source.size) orelse
                return resetStream(ctx);

            return writeHeaders(ctx.fd, ctx.sid, refused, true) catch |err| switch (err) {
                // Peer gone, nothing left to answer.
                else => {},
            };
        },
    };

    // A 206 whose headers do not fit falls back to the whole file.
    if (segment.status == 206 and segment.content_range.len == 0) segment = wholeOf(source);

    const block = encodeHead(&head_buf, source, segment) orelse blk: {
        segment = wholeOf(source);

        break :blk encodeHead(&head_buf, source, segment) orelse return resetStream(ctx);
    };

    sendFramed(ctx, source, segment, block, max_frame_size) catch |err| switch (err) {
        // Peer gone or file changed under the handle, the headers may be out.
        else => {},
    };
}

/// Take a cache hit, with resident bytes when sendfile cannot carry the body.
///
/// Note:
/// - acquireMapped declines a file past its snapshot cap, so the plain hit
///   still serves it from the open descriptor.
fn acquireHit(
    cache: *StaticCache,
    req: *const Request,
    ctx: *const Context,
    req_path: []const u8,
) ?StaticHit {
    const accept_encoding = req.header("accept-encoding");
    const ttl_ms = StaticCacheRegistry.shared.ttl_ms;
    const now_ms = nowMillis(ctx.io);

    if (!zeroCopyAllowed(ctx.fd)) {
        const resident = cache.acquireMapped(
            ctx.io,
            ctx.public_dir,
            req_path,
            accept_encoding,
            ttl_ms,
            now_ms,
        );
        if (resident) |pinned| return pinned;
    }

    return cache.acquire(ctx.io, ctx.public_dir, req_path, accept_encoding, ttl_ms, now_ms);
}

/// Serve from the static cache when one is installed and takes the path.
///
/// Return:
/// - bool (false when there is no cache or it declined, the caller falls back)
fn serveCached(
    req: *const Request,
    ctx: *const Context,
    req_path: []const u8,
    max_frame_size: u32,
) bool {
    const cache = StaticCacheRegistry.shared.instance() orelse return false;
    const pinned = acquireHit(cache, req, ctx, req_path) orelse return false;
    defer cache.release(pinned);

    answer(ctx, req, .{
        .file = pinned.file,
        .size = pinned.size,
        .content_type = pinned.content_type,
        .content_encoding = pinned.encoding.contentEncoding() orelse "",
        .bytes = pinned.bytes,
    }, max_frame_size);

    return true;
}

/// Open, stat, and send the file without the cache.
///
/// Return:
/// - bool (false when the path is unsafe or the file is missing)
fn serveUncached(
    req: *const Request,
    ctx: *const Context,
    req_path: []const u8,
    max_frame_size: u32,
) bool {
    var path_buf: [cache_path.PUBLIC_PATH_MAX]u8 = undefined;
    const full_path = cache_path.resolve(&path_buf, ctx.public_dir, req_path) orelse
        return false;

    const file = std.Io.Dir.cwd().openFile(ctx.io, full_path, .{}) catch |err| switch (err) {
        else => return false,
    };
    defer file.close(ctx.io);

    const stat = file.stat(ctx.io) catch |err| switch (err) {
        else => return false,
    };
    if (stat.kind != .file) return false;

    answer(ctx, req, .{
        .file = file,
        .size = stat.size,
        .content_type = content.fromExtension(file_utils.extension(req_path)),
        .content_encoding = "",
    }, max_frame_size);

    return true;
}

// --------------------------------------------------------- //
// Public:

/// Serve a file from ctx.public_dir.
///
/// Note:
/// - `..`, an absolute path, and a directory are refused.
/// - A malformed Range is ignored (200). A valid Range past the end is 416.
///
/// Param:
/// req - *const Request (Range and Accept-Encoding are read from it)
/// ctx - *const Context (fd, stream id, io, and public_dir)
/// req_path - []const u8 (request path with the leading slash stripped)
/// max_frame_size - u32 (the peer's SETTINGS_MAX_FRAME_SIZE, caps every DATA frame)
///
/// Return:
/// - bool (true when a response was framed, false when the caller sends 404)
pub fn serve(
    req: *const Request,
    ctx: *const Context,
    req_path: []const u8,
    max_frame_size: u32,
) bool {
    if (serveCached(req, ctx, req_path, max_frame_size)) return true;

    return serveUncached(req, ctx, req_path, max_frame_size);
}

/// The router fallback: serve the request path from ctx.public_dir.
///
/// Param:
/// req - *const Request (request)
/// ctx - *const Context (empty public_dir turns the fallback off)
///
/// Return:
/// - bool (true when a response was framed)
pub fn fallback(req: *const Request, ctx: *const Context) bool {
    if (ctx.public_dir.len == 0) return false;

    const path = req.path;
    const stripped = if (path.len > 0 and path[0] == '/') path[1..] else path;
    if (stripped.len == 0) return false;

    return serve(req, ctx, stripped, ctx.max_frame_size);
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const pair = @import("../../utils/socket/pair.zig");
const Header = @import("hpack/Header.zig");
const HpackDecoder = @import("hpack/HpackDecoder.zig");

/// A descriptor no test path writes to.
const NO_FD: std.posix.fd_t = if (builtin.os.tag == .windows)
    std.os.windows.INVALID_HANDLE_VALUE
else
    -1;

/// What the frames on a wire add up to.
const FrameSummary = struct {
    header_count: usize = 0,
    first_flags: u8 = 0,
    data_bytes: u64 = 0,
    largest_data: u32 = 0,
    last_data_flags: u8 = 0,
    header_block: []const u8 = &.{},
};

fn testRequest(path: []const u8, headers: []const Header) Request {
    return .{
        .method = "GET",
        .path = path,
        .query = "",
        .headers = headers,
        .body = "",
    };
}

fn testContext(fd: std.posix.fd_t, public_dir: []const u8) Context {
    var ctx = Context.init(std.testing.io, std.testing.allocator, fd, 1);
    ctx.public_dir = public_dir;

    return ctx;
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

/// Read the peer end until the writer end is closed.
fn drainPeer(peer: std.posix.fd_t, buf: []u8) []const u8 {
    var total: usize = 0;

    while (total < buf.len) {
        const rc = std.posix.system.read(peer, buf[total..].ptr, buf.len - total);
        if (std.posix.errno(rc) != .SUCCESS or rc == 0) break;

        total += @intCast(rc);
    }

    return buf[0..total];
}

/// Serve one request over a socket pair and return what reached the peer.
fn serveWire(
    root: []const u8,
    req: *const Request,
    req_path: []const u8,
    max_frame_size: u32,
    wire_buf: []u8,
) ![]const u8 {
    // The wire is read back with a POSIX read.
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;

    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[1]);

    const ctx = testContext(fds[0], root);
    const served = serve(req, &ctx, req_path, max_frame_size);
    _ = std.posix.system.close(fds[0]);

    try std.testing.expect(served);

    return drainPeer(fds[1], wire_buf);
}

fn summarizeFrames(wire: []const u8) FrameSummary {
    var summary: FrameSummary = .{};
    var offset: usize = 0;

    while (offset + frame.FRAME_HEADER_LEN <= wire.len) {
        const header = frame.parseFrameHeader(wire[offset..][0..frame.FRAME_HEADER_LEN]);
        if (offset == 0) summary.first_flags = header.flags;

        offset += frame.FRAME_HEADER_LEN;
        if (offset + header.length > wire.len) break;

        if (header.frame_type == frame.FRAME_TYPE_HEADERS) {
            summary.header_count += 1;
            summary.header_block = wire[offset..][0..header.length];
        }
        if (header.frame_type == frame.FRAME_TYPE_DATA) {
            summary.data_bytes += header.length;
            summary.largest_data = @max(summary.largest_data, header.length);
            summary.last_data_flags = header.flags;
        }

        offset += header.length;
    }

    return summary;
}

/// Collect the payload of every DATA frame in order.
fn collectData(wire: []const u8, out: []u8) []const u8 {
    var offset: usize = 0;
    var written: usize = 0;

    while (offset + frame.FRAME_HEADER_LEN <= wire.len) {
        const header = frame.parseFrameHeader(wire[offset..][0..frame.FRAME_HEADER_LEN]);
        offset += frame.FRAME_HEADER_LEN;
        if (offset + header.length > wire.len) break;

        if (header.frame_type == frame.FRAME_TYPE_DATA) {
            @memcpy(out[written..][0..header.length], wire[offset..][0..header.length]);
            written += header.length;
        }

        offset += header.length;
    }

    return out[0..written];
}

/// Decode the block of the last HEADERS frame on the wire.
fn decodeHeaders(wire: []const u8, out: []Header, scratch: []u8) ![]const Header {
    const summary = summarizeFrames(wire);
    var decoder = HpackDecoder.init();
    const count = try decoder.decode(summary.header_block, out, scratch);

    return out[0..count];
}

fn headerValue(headers: []const Header, name: []const u8) ?[]const u8 {
    for (headers) |header| {
        if (std.mem.eql(u8, header.name, name)) return header.value;
    }

    return null;
}

/// Decode the wire headers and return one header value, or null.
fn wireHeader(wire: []const u8, name: []const u8) !?[]const u8 {
    const holder = struct {
        threadlocal var headers: [16]Header = undefined;
        threadlocal var scratch: [512]u8 = undefined;
    };
    const decoded = try decodeHeaders(wire, &holder.headers, &holder.scratch);

    return headerValue(decoded, name);
}

test "zix http2: static, zeroCopyAllowed refuses the sentinel fd" {
    try std.testing.expect(!zeroCopyAllowed(NO_FD));
}

test "zix http2: static, zeroCopyAllowed takes a real fd on linux" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;

    try std.testing.expect(zeroCopyAllowed(3));
}

test "zix http2: static, rangeAsk without a header is FULL" {
    const req = testRequest("/a", &.{});

    try std.testing.expect(rangeAsk(&req, 10) == .FULL);
}

test "zix http2: static, rangeAsk malformed is FULL" {
    const headers = [_]Header{.{
        .name = "range",
        .value = "furlongs=1-2",
    }};
    const req = testRequest("/a", &headers);

    try std.testing.expect(rangeAsk(&req, 10) == .FULL);
}

test "zix http2: static, rangeAsk past the end is UNSATISFIABLE" {
    const headers = [_]Header{.{
        .name = "range",
        .value = "bytes=50-60",
    }};
    const req = testRequest("/a", &headers);

    try std.testing.expect(rangeAsk(&req, 10) == .UNSATISFIABLE);
}

test "zix http2: static, rangeAsk valid range is PARTIAL" {
    const headers = [_]Header{.{
        .name = "range",
        .value = "bytes=2-5",
    }};
    const req = testRequest("/a", &headers);
    const ask = rangeAsk(&req, 10);

    try std.testing.expectEqual(@as(u64, 2), ask.PARTIAL.start);
    try std.testing.expectEqual(@as(u64, 5), ask.PARTIAL.end);
}

test "zix http2: static, renderContentRange states the range" {
    var buf: [CONTENT_RANGE_BUF]u8 = undefined;
    const rendered = renderContentRange(&buf, .{
        .start = 10,
        .end = 19,
    }, 100).?;

    try std.testing.expectEqualStrings("bytes 10-19/100", rendered);
}

test "zix http2: static, renderContentRange too small buffer is null" {
    var tiny: [4]u8 = undefined;

    try std.testing.expect(renderContentRange(&tiny, .{
        .start = 10,
        .end = 19,
    }, 100) == null);
}

test "zix http2: static, encodeHead too small buffer is null" {
    var tiny: [2]u8 = undefined;
    const source = Source{
        .file = undefined,
        .size = 10,
        .content_type = "text/plain",
        .content_encoding = "",
    };

    try std.testing.expect(encodeHead(&tiny, source, wholeOf(source)) == null);
}

test "zix http2: static, encodeUnsatisfiable too small buffer is null" {
    var tiny: [2]u8 = undefined;

    try std.testing.expect(encodeUnsatisfiable(&tiny, 10) == null);
}

test "zix http2: static, serve traversal is false" {
    const req = testRequest("/x", &.{});
    const ctx = testContext(NO_FD, "./public");

    try std.testing.expect(!serve(&req, &ctx, "../etc/passwd", frame.DEFAULT_MAX_FRAME_SIZE));
}

test "zix http2: static, serve missing file is false" {
    const req = testRequest("/x", &.{});
    const ctx = testContext(NO_FD, "./public");

    try std.testing.expect(!serve(&req, &ctx, "absent.txt", frame.DEFAULT_MAX_FRAME_SIZE));
}

test "zix http2: static, serve directory is false" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDir(std.testing.io, "sub", .default_dir);

    var root_buf: [64]u8 = undefined;
    const req = testRequest("/sub", &.{});
    const ctx = testContext(NO_FD, fixtureRoot(&tmp, &root_buf));

    try std.testing.expect(!serve(&req, &ctx, "sub", frame.DEFAULT_MAX_FRAME_SIZE));
}

test "zix http2: static, serve path past PUBLIC_PATH_MAX is false" {
    const long_path: [cache_path.PUBLIC_PATH_MAX + 8]u8 = @splat('a');
    const req = testRequest("/x", &.{});
    const ctx = testContext(NO_FD, "./public");

    try std.testing.expect(!serve(&req, &ctx, &long_path, frame.DEFAULT_MAX_FRAME_SIZE));
}

test "zix http2: static, serve frames a file as HEADERS plus DATA" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    writeFixture(&tmp, "app.json", "{\"ok\":true}");

    var root_buf: [64]u8 = undefined;
    var wire_buf: [1024]u8 = undefined;
    var body_buf: [64]u8 = undefined;
    const req = testRequest("/app.json", &.{});
    const wire = try serveWire(
        fixtureRoot(&tmp, &root_buf),
        &req,
        "app.json",
        frame.DEFAULT_MAX_FRAME_SIZE,
        &wire_buf,
    );
    const summary = summarizeFrames(wire);

    try std.testing.expectEqual(@as(usize, 1), summary.header_count);
    try std.testing.expect((summary.last_data_flags & frame.FLAG_END_STREAM) != 0);
    try std.testing.expectEqualStrings("{\"ok\":true}", collectData(wire, &body_buf));
}

test "zix http2: static, serve resolves the MIME type" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    writeFixture(&tmp, "app.json", "{}");

    var root_buf: [64]u8 = undefined;
    var wire_buf: [1024]u8 = undefined;
    const req = testRequest("/app.json", &.{});
    const wire = try serveWire(
        fixtureRoot(&tmp, &root_buf),
        &req,
        "app.json",
        frame.DEFAULT_MAX_FRAME_SIZE,
        &wire_buf,
    );

    try std.testing.expectEqualStrings(
        content.fromExtension("json"),
        (try wireHeader(wire, "content-type")).?,
    );
}

test "zix http2: static, serve chunks a body past the max frame size" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var payload: [700]u8 = undefined;
    for (&payload, 0..) |*byte, index| byte.* = @intCast('a' + index % 26);
    writeFixture(&tmp, "big.bin", &payload);

    var root_buf: [64]u8 = undefined;
    var wire_buf: [4096]u8 = undefined;
    var body_buf: [1024]u8 = undefined;
    const req = testRequest("/big.bin", &.{});
    const wire = try serveWire(fixtureRoot(&tmp, &root_buf), &req, "big.bin", 256, &wire_buf);
    const summary = summarizeFrames(wire);

    try std.testing.expect(summary.largest_data <= 256);
    try std.testing.expect((summary.last_data_flags & frame.FLAG_END_STREAM) != 0);
    try std.testing.expectEqualStrings(&payload, collectData(wire, &body_buf));
}

test "zix http2: static, serve empty file closes the stream on HEADERS" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    writeFixture(&tmp, "empty.txt", "");

    var root_buf: [64]u8 = undefined;
    var wire_buf: [1024]u8 = undefined;
    const req = testRequest("/empty.txt", &.{});
    const wire = try serveWire(
        fixtureRoot(&tmp, &root_buf),
        &req,
        "empty.txt",
        frame.DEFAULT_MAX_FRAME_SIZE,
        &wire_buf,
    );
    const summary = summarizeFrames(wire);

    try std.testing.expectEqual(@as(u64, 0), summary.data_bytes);
    try std.testing.expect((summary.first_flags & frame.FLAG_END_STREAM) != 0);
}

test "zix http2: static, serve Range is 206 with Content-Range" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    writeFixture(&tmp, "clip.bin", "0123456789");

    const headers = [_]Header{.{
        .name = "range",
        .value = "bytes=2-5",
    }};
    var root_buf: [64]u8 = undefined;
    var wire_buf: [1024]u8 = undefined;
    var body_buf: [64]u8 = undefined;
    const req = testRequest("/clip.bin", &headers);
    const wire = try serveWire(
        fixtureRoot(&tmp, &root_buf),
        &req,
        "clip.bin",
        frame.DEFAULT_MAX_FRAME_SIZE,
        &wire_buf,
    );
    const content_range = (try wireHeader(wire, "content-range")).?;

    try std.testing.expectEqualStrings("206", (try wireHeader(wire, ":status")).?);
    try std.testing.expectEqualStrings("bytes 2-5/10", content_range);
    try std.testing.expectEqualStrings("bytes", (try wireHeader(wire, "accept-ranges")).?);
    try std.testing.expectEqualStrings("2345", collectData(wire, &body_buf));
}

test "zix http2: static, serve Range Content-Length is the range length" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    writeFixture(&tmp, "clip.bin", "0123456789");

    const headers = [_]Header{.{
        .name = "range",
        .value = "bytes=2-5",
    }};
    var root_buf: [64]u8 = undefined;
    var wire_buf: [1024]u8 = undefined;
    const req = testRequest("/clip.bin", &headers);
    const wire = try serveWire(
        fixtureRoot(&tmp, &root_buf),
        &req,
        "clip.bin",
        frame.DEFAULT_MAX_FRAME_SIZE,
        &wire_buf,
    );

    try std.testing.expectEqualStrings("4", (try wireHeader(wire, "content-length")).?);
}

test "zix http2: static, serve open-ended Range fills to the last byte" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    writeFixture(&tmp, "open.bin", "0123456789");

    const headers = [_]Header{.{
        .name = "range",
        .value = "bytes=7-",
    }};
    var root_buf: [64]u8 = undefined;
    var wire_buf: [1024]u8 = undefined;
    var body_buf: [64]u8 = undefined;
    const req = testRequest("/open.bin", &headers);
    const wire = try serveWire(
        fixtureRoot(&tmp, &root_buf),
        &req,
        "open.bin",
        frame.DEFAULT_MAX_FRAME_SIZE,
        &wire_buf,
    );
    const content_range = (try wireHeader(wire, "content-range")).?;

    try std.testing.expectEqualStrings("bytes 7-9/10", content_range);
    try std.testing.expectEqualStrings("789", collectData(wire, &body_buf));
}

test "zix http2: static, serve Range past the end is 416" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    writeFixture(&tmp, "short.bin", "0123456789");

    const headers = [_]Header{.{
        .name = "range",
        .value = "bytes=50-60",
    }};
    var root_buf: [64]u8 = undefined;
    var wire_buf: [1024]u8 = undefined;
    const req = testRequest("/short.bin", &headers);
    const wire = try serveWire(
        fixtureRoot(&tmp, &root_buf),
        &req,
        "short.bin",
        frame.DEFAULT_MAX_FRAME_SIZE,
        &wire_buf,
    );

    try std.testing.expectEqualStrings("416", (try wireHeader(wire, ":status")).?);
    try std.testing.expectEqualStrings("bytes */10", (try wireHeader(wire, "content-range")).?);
}

test "zix http2: static, serve Range past the end closes the stream on HEADERS" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    writeFixture(&tmp, "short.bin", "0123456789");

    const headers = [_]Header{.{
        .name = "range",
        .value = "bytes=50-60",
    }};
    var root_buf: [64]u8 = undefined;
    var wire_buf: [1024]u8 = undefined;
    const req = testRequest("/short.bin", &headers);
    const wire = try serveWire(
        fixtureRoot(&tmp, &root_buf),
        &req,
        "short.bin",
        frame.DEFAULT_MAX_FRAME_SIZE,
        &wire_buf,
    );
    const summary = summarizeFrames(wire);

    try std.testing.expectEqual(@as(u64, 0), summary.data_bytes);
    try std.testing.expect((summary.first_flags & frame.FLAG_END_STREAM) != 0);
}

test "zix http2: static, serve malformed Range falls back to 200" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    writeFixture(&tmp, "whole.bin", "0123456789");

    const headers = [_]Header{.{
        .name = "range",
        .value = "furlongs=1-2",
    }};
    var root_buf: [64]u8 = undefined;
    var wire_buf: [1024]u8 = undefined;
    var body_buf: [64]u8 = undefined;
    const req = testRequest("/whole.bin", &headers);
    const wire = try serveWire(
        fixtureRoot(&tmp, &root_buf),
        &req,
        "whole.bin",
        frame.DEFAULT_MAX_FRAME_SIZE,
        &wire_buf,
    );

    try std.testing.expectEqualStrings("200", (try wireHeader(wire, ":status")).?);
    try std.testing.expect((try wireHeader(wire, "content-range")) == null);
    try std.testing.expectEqualStrings("0123456789", collectData(wire, &body_buf));
}

test "zix http2: static, serve Range is chunked at the peer frame size" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var payload: [900]u8 = undefined;
    for (&payload, 0..) |*byte, index| byte.* = @intCast('a' + index % 26);
    writeFixture(&tmp, "big.bin", &payload);

    const headers = [_]Header{.{
        .name = "range",
        .value = "bytes=100-699",
    }};
    var root_buf: [64]u8 = undefined;
    var wire_buf: [4096]u8 = undefined;
    var body_buf: [1024]u8 = undefined;
    const req = testRequest("/big.bin", &headers);
    const wire = try serveWire(fixtureRoot(&tmp, &root_buf), &req, "big.bin", 128, &wire_buf);
    const summary = summarizeFrames(wire);

    try std.testing.expect(summary.largest_data <= 128);
    try std.testing.expectEqualSlices(u8, payload[100..700], collectData(wire, &body_buf));
}

test "zix http2: static, cache off leaves the table empty" {
    try std.testing.expect(StaticCacheRegistry.shared.instance() == null);
}

test "zix http2: static, cached Range is 206 on a repeat hit" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    writeFixture(&tmp, "cached.bin", "abcdefghij");

    _ = try StaticCacheRegistry.shared.install(16, 60_000);
    defer StaticCacheRegistry.shared.shutdown(std.testing.io);

    const headers = [_]Header{.{
        .name = "range",
        .value = "bytes=3-6",
    }};
    var root_buf: [64]u8 = undefined;
    const root = fixtureRoot(&tmp, &root_buf);
    const req = testRequest("/cached.bin", &headers);

    // The first request inserts, the second is served from the cached entry.
    for (0..2) |_| {
        var wire_buf: [1024]u8 = undefined;
        var body_buf: [64]u8 = undefined;
        const wire = try serveWire(
            root,
            &req,
            "cached.bin",
            frame.DEFAULT_MAX_FRAME_SIZE,
            &wire_buf,
        );

        try std.testing.expectEqualStrings("206", (try wireHeader(wire, ":status")).?);
        try std.testing.expectEqualStrings("defg", collectData(wire, &body_buf));
    }
}

test "zix http2: static, cached serve sends the brotli sibling" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    writeFixture(&tmp, "vendor.js", "the plain vendor bundle");
    writeFixture(&tmp, "vendor.js.br", "squeezed");

    _ = try StaticCacheRegistry.shared.install(16, 60_000);
    defer StaticCacheRegistry.shared.shutdown(std.testing.io);

    const headers = [_]Header{.{
        .name = "accept-encoding",
        .value = "br, gzip",
    }};
    var root_buf: [64]u8 = undefined;
    var wire_buf: [1024]u8 = undefined;
    var body_buf: [64]u8 = undefined;
    const req = testRequest("/vendor.js", &headers);
    const wire = try serveWire(
        fixtureRoot(&tmp, &root_buf),
        &req,
        "vendor.js",
        frame.DEFAULT_MAX_FRAME_SIZE,
        &wire_buf,
    );

    try std.testing.expectEqualStrings("br", (try wireHeader(wire, "content-encoding")).?);
    try std.testing.expectEqualStrings("squeezed", collectData(wire, &body_buf));
}

test "zix http2: static, acquireHit takes resident bytes when zero copy is refused" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    writeFixture(&tmp, "resident.css", "body{margin:0}");

    _ = try StaticCacheRegistry.shared.install(16, 60_000);
    defer StaticCacheRegistry.shared.shutdown(std.testing.io);

    var root_buf: [64]u8 = undefined;
    const cache = StaticCacheRegistry.shared.instance().?;
    const req = testRequest("/resident.css", &.{});
    const ctx = testContext(NO_FD, fixtureRoot(&tmp, &root_buf));

    const resident = acquireHit(cache, &req, &ctx, "resident.css").?;
    defer cache.release(resident);

    try std.testing.expectEqualStrings("body{margin:0}", resident.bytes.?);
}

test "zix http2: static, acquireHit leaves the body unread for sendfile" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    writeFixture(&tmp, "direct.css", "body{margin:0}");

    _ = try StaticCacheRegistry.shared.install(16, 60_000);
    defer StaticCacheRegistry.shared.shutdown(std.testing.io);

    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    var root_buf: [64]u8 = undefined;
    const cache = StaticCacheRegistry.shared.instance().?;
    const req = testRequest("/direct.css", &.{});
    const ctx = testContext(fds[0], fixtureRoot(&tmp, &root_buf));

    const direct = acquireHit(cache, &req, &ctx, "direct.css").?;
    defer cache.release(direct);

    try std.testing.expect(direct.bytes == null);
}

test "zix http2: static, fallback without a root is false" {
    const req = testRequest("/a.txt", &.{});
    const ctx = testContext(NO_FD, "");

    try std.testing.expect(!fallback(&req, &ctx));
}

test "zix http2: static, fallback for the root path is false" {
    const req = testRequest("/", &.{});
    const ctx = testContext(NO_FD, "./public");

    try std.testing.expect(!fallback(&req, &ctx));
}

test "zix http2: static, fallback strips the leading slash" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    writeFixture(&tmp, "a.txt", "hi");

    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    var root_buf: [64]u8 = undefined;
    const req = testRequest("/a.txt", &.{});
    const ctx = testContext(fds[0], fixtureRoot(&tmp, &root_buf));

    try std.testing.expect(fallback(&req, &ctx));
}

