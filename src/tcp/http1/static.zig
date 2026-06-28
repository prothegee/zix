//! zix http1 static file serving: the public_dir fallback for unmatched routes.
//!
//! The Http1 handler signature carries only (head, body, fd), never io, so the router reads the
//! configured public_dir and io from core threadlocals (core.setStatic, installed per worker) and
//! calls serve here. Writes go through core.fdWriteAll, so the response-coalescing sink and the TLS
//! buffering path are honored the same as any other Http1 response.

const std = @import("std");
const core = @import("core.zig");
const content = @import("../http/content.zig");
const file_utils = @import("../../utils/file.zig");

// --------------------------------------------------------- //

/// Stack buffer for reading and copying a file in chunks during static serving.
const FILE_BUF_SIZE: usize = 8 * 1024;
/// Served full-path stack buffer.
const FULL_PATH_BUF: usize = 512;
/// Static-serve response header staging buffer.
const HEADER_STAGING_BUF: usize = 2048;

// --------------------------------------------------------- //

/// Serve a static file from the public directory.
///
/// Rejects paths containing ".." to prevent directory traversal. Supports Range requests
/// (RFC 7233) for partial content (206). An unsatisfiable or malformed Range is ignored and
/// the full body is sent with 200, which RFC 7233 permits.
///
/// Param:
/// head - *const core.ParsedHead (request head, read for the Range header)
/// fd - std.posix.fd_t (socket the response is written to, via core.fdWriteAll)
/// req_path - []const u8 (request path with the leading slash already stripped)
/// public_dir - []const u8 (root directory, joined with req_path)
/// io - std.Io (file open / stat / read)
///
/// Return:
/// - true if the file was found and a response was written
/// - false if the file is not found or the path is invalid (caller sends 404)
pub fn serve(
    head: *const core.ParsedHead,
    fd: std.posix.fd_t,
    req_path: []const u8,
    public_dir: []const u8,
    io: std.Io,
) !bool {
    if (std.mem.indexOf(u8, req_path, "..") != null) return false;

    var full_path_buf: [FULL_PATH_BUF]u8 = undefined;
    if (public_dir.len + 1 + req_path.len > full_path_buf.len) return false;
    @memcpy(full_path_buf[0..public_dir.len], public_dir);
    full_path_buf[public_dir.len] = '/';
    @memcpy(full_path_buf[public_dir.len + 1 ..][0..req_path.len], req_path);
    const full_path = full_path_buf[0 .. public_dir.len + 1 + req_path.len];

    const f = std.Io.Dir.cwd().openFile(io, full_path, .{}) catch return false;
    defer f.close(io);

    const stat = f.stat(io) catch return false;
    if (stat.kind != .file) return false;

    const content_type = content.fromExtension(file_utils.extension(req_path));

    var header_buf: [HEADER_STAGING_BUF]u8 = undefined;

    if (core.getHeader(head, "range")) |range_val| {
        if (core.parseRange(range_val, stat.size)) |range| {
            const start = range.start;
            const end = range.end;
            const length = end - start + 1;

            const s = std.fmt.bufPrint(&header_buf, "HTTP/1.1 206 Partial Content\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nContent-Range: bytes {d}-{d}/{d}\r\nAccept-Ranges: bytes\r\nConnection: keep-alive\r\n\r\n", .{ content_type, length, start, end, stat.size }) catch return false;
            core.fdWriteAll(fd, s) catch return false;

            var file_buf: [FILE_BUF_SIZE]u8 = undefined;
            var reader = f.reader(io, &file_buf);
            var skipped: u64 = 0;
            while (skipped < start) {
                const to_skip = @min(start - skipped, file_buf.len);
                const n = reader.interface.readSliceShort(file_buf[0..@intCast(to_skip)]) catch break;
                if (n == 0) break;
                skipped += n;
            }

            var copy_buf: [FILE_BUF_SIZE]u8 = undefined;
            var remaining = length;
            while (remaining > 0) {
                const to_read = @min(remaining, copy_buf.len);
                const n = reader.interface.readSliceShort(copy_buf[0..@intCast(to_read)]) catch break;
                if (n == 0) break;
                core.fdWriteAll(fd, copy_buf[0..n]) catch break;
                remaining -= n;
            }
            return true;
        }
    }

    const s = std.fmt.bufPrint(&header_buf, "HTTP/1.1 200 OK\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nAccept-Ranges: bytes\r\nConnection: keep-alive\r\n\r\n", .{ content_type, stat.size }) catch return false;
    core.fdWriteAll(fd, s) catch return false;

    var file_buf: [FILE_BUF_SIZE]u8 = undefined;
    var reader = f.reader(io, &file_buf);
    var copy_buf: [FILE_BUF_SIZE]u8 = undefined;
    var remaining = stat.size;
    while (remaining > 0) {
        const to_read = @min(remaining, copy_buf.len);
        const n = reader.interface.readSliceShort(copy_buf[0..to_read]) catch break;
        if (n == 0) break;
        core.fdWriteAll(fd, copy_buf[0..n]) catch break;
        remaining -= n;
    }
    return true;
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //

const testing = std.testing;

fn testHead(path: []const u8, raw_headers: []const u8) core.ParsedHead {
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

test "zix http1: static serve rejects directory traversal" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();

    var head = testHead("/../etc/passwd", "");
    const served = try serve(&head, 1, "../etc/passwd", "./public", threaded.io());
    try testing.expect(!served);
}

test "zix http1: static serve returns false for a missing file" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();

    var head = testHead("/does-not-exist.txt", "");
    const served = try serve(&head, 1, "does-not-exist.txt", "./public", threaded.io());
    try testing.expect(!served);
}

test "zix http1: static serve returns false when the path overflows the join buffer" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();

    var long_buf: [600]u8 = undefined;
    @memset(&long_buf, 'a');
    const long_path: []const u8 = &long_buf;

    var head = testHead("/x", "");
    const served = try serve(&head, 1, long_path, "./public", threaded.io());
    try testing.expect(!served);
}

test "zix http1: static serve mime resolves from extension" {
    try testing.expectEqualStrings("text/html", content.fromExtension(file_utils.extension("index.html")));
    try testing.expectEqualStrings("text/css", content.fromExtension(file_utils.extension("style.css")));
    try testing.expectEqualStrings("application/json", content.fromExtension(file_utils.extension("data.json")));
    try testing.expectEqualStrings("application/octet-stream", content.fromExtension(file_utils.extension("blob.unknown")));
}
