//! zix http static

const std = @import("std");
const content = @import("content.zig");
const file_utils = @import("../../utils/file.zig");
const Request = @import("request.zig").Request;
const fdWriteAll = @import("response.zig").fdWriteAll;

// --------------------------------------------------------- //

/// Stack buffer for reading and copying a file in chunks during static serving.
const FILE_BUF_SIZE: usize = 8 * 1024;

// --------------------------------------------------------- //

const RangeRequest = struct {
    start: u64,
    end: ?u64,
};

fn parseRangeHeader(value: []const u8) ?RangeRequest {
    if (!std.mem.startsWith(u8, value, "bytes=")) return null;
    const spec = value[6..];
    const dash = std.mem.indexOfScalar(u8, spec, '-') orelse return null;
    const start = std.fmt.parseInt(u64, spec[0..dash], 10) catch return null;
    const end = if (dash + 1 < spec.len) std.fmt.parseInt(u64, spec[dash + 1 ..], 10) catch null else null;
    return .{ .start = start, .end = end };
}

/// Serve a static file from the public directory.
/// Rejects paths containing ".." to prevent directory traversal.
/// Supports Range requests (RFC 7233) for partial content (206).
///
/// Return:
/// - false if the file is not found or the path is invalid (caller sends 404)
pub fn serve(
    req: *Request,
    fd: std.posix.fd_t,
    req_path: []const u8,
    public_dir: []const u8,
    io: std.Io,
) !bool {
    if (std.mem.indexOf(u8, req_path, "..") != null) return false;

    var full_path_buf: [512]u8 = undefined;
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

    var header_buf: [2048]u8 = undefined;

    if (req.header("range")) |range_val| {
        if (parseRangeHeader(range_val)) |range| {
            const start = range.start;
            const end = range.end orelse stat.size - 1;
            const length = end - start + 1;

            if (start >= stat.size) {
                const s = std.fmt.bufPrint(&header_buf, "HTTP/1.1 416 Range Not Satisfiable\r\nContent-Range: bytes */{d}\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n", .{stat.size}) catch return false;
                fdWriteAll(fd, s) catch return false;
                return true;
            }

            const s = std.fmt.bufPrint(&header_buf, "HTTP/1.1 206 Partial Content\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nContent-Range: bytes {d}-{d}/{d}\r\nAccept-Ranges: bytes\r\nConnection: keep-alive\r\n\r\n", .{ content_type, length, start, end, stat.size }) catch return false;
            fdWriteAll(fd, s) catch return false;

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
                fdWriteAll(fd, copy_buf[0..n]) catch break;
                remaining -= n;
            }
            return true;
        }
    }

    // Full file response.
    const s = std.fmt.bufPrint(&header_buf, "HTTP/1.1 200 OK\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nAccept-Ranges: bytes\r\nConnection: keep-alive\r\n\r\n", .{ content_type, stat.size }) catch return false;
    fdWriteAll(fd, s) catch return false;

    var file_buf: [FILE_BUF_SIZE]u8 = undefined;
    var reader = f.reader(io, &file_buf);
    var copy_buf: [FILE_BUF_SIZE]u8 = undefined;
    var remaining = stat.size;
    while (remaining > 0) {
        const to_read = @min(remaining, copy_buf.len);
        const n = reader.interface.readSliceShort(copy_buf[0..to_read]) catch break;
        if (n == 0) break;
        fdWriteAll(fd, copy_buf[0..n]) catch break;
        remaining -= n;
    }
    return true;
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //

test "zix test: http static mimeType" {
    try std.testing.expectEqualStrings("text/html", content.fromExtension("html"));
    try std.testing.expectEqualStrings("text/css", content.fromExtension("css"));
    try std.testing.expectEqualStrings("application/json", content.fromExtension("json"));
    try std.testing.expectEqualStrings("image/png", content.fromExtension("png"));
    try std.testing.expectEqualStrings("application/octet-stream", content.fromExtension("unknown"));
}

test "zix test: http static parseRangeHeader" {
    const r1 = parseRangeHeader("bytes=0-499").?;
    try std.testing.expectEqual(@as(u64, 0), r1.start);
    try std.testing.expectEqual(@as(u64, 499), r1.end.?);

    const r2 = parseRangeHeader("bytes=500-").?;
    try std.testing.expectEqual(@as(u64, 500), r2.start);
    try std.testing.expect(r2.end == null);

    try std.testing.expect(parseRangeHeader("none") == null);
    try std.testing.expect(parseRangeHeader("bytes=abc") == null);
}
