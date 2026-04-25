//! zix http static

const std = @import("std");
const content = @import("content.zig");
const file_utils = @import("../../utils/file.zig");

const RangeRequest = struct {
    start: u64,
    end: ?u64,
};

/// Brief:
/// Parse a Range request header value into a RangeRequest
///
/// Note:
/// - Only supports "bytes=" unit prefix (RFC 7233)
/// - Returns null if the header is malformed or missing the bytes= prefix
///
/// Param:
/// value - []const u8 (raw Range header value)
///
/// Return:
/// ?RangeRequest
fn parseRangeHeader(value: []const u8) ?RangeRequest {
    if (!std.mem.startsWith(u8, value, "bytes=")) return null;
    const spec = value[6..];
    const dash = std.mem.indexOfScalar(u8, spec, '-') orelse return null;
    const start = std.fmt.parseInt(u64, spec[0..dash], 10) catch return null;
    const end = if (dash + 1 < spec.len) std.fmt.parseInt(u64, spec[dash + 1 ..], 10) catch null else null;
    return .{ .start = start, .end = end };
}

/// Brief:
/// Serve a static file from the public directory
///
/// Note:
/// - Rejects paths containing ".." to prevent directory traversal
/// - Supports Range requests (RFC 7233) for partial content (206)
/// - Returns false if the file is not found or path is invalid, caller sends 404
///
/// Param:
/// req        - *std.http.Server.Request
/// req_path   - []const u8 (path relative to public_dir, no leading slash)
/// public_dir - []const u8 (directory to serve files from)
/// io         - std.Io
///
/// Return:
/// !bool
pub fn serve(
    req: *std.http.Server.Request,
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

    var range_req: ?RangeRequest = null;
    var it = req.iterateHeaders();
    while (it.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "range")) {
            range_req = parseRangeHeader(h.value);
            break;
        }
    }

    var header_buf: [2048]u8 = undefined;

    if (range_req) |range| {
        const start = range.start;
        const end = range.end orelse stat.size - 1;
        const length = end - start + 1;

        if (start >= stat.size) {
            const s = std.fmt.bufPrint(&header_buf, "HTTP/1.1 416 Range Not Satisfiable\r\nContent-Range: bytes */{d}\r\nConnection: keep-alive\r\n\r\n", .{stat.size}) catch return false;
            req.server.out.writeAll(s) catch return false;
            req.server.out.flush() catch return false;
            return true;
        }

        const s = std.fmt.bufPrint(&header_buf, "HTTP/1.1 206 Partial Content\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nContent-Range: bytes {d}-{d}/{d}\r\nAccept-Ranges: bytes\r\nConnection: keep-alive\r\n\r\n", .{ content_type, length, start, end, stat.size }) catch return false;
        req.server.out.writeAll(s) catch return false;

        var file_buf: [8192]u8 = undefined;
        var reader = f.reader(io, &file_buf);
        var copy_buf: [8192]u8 = undefined;
        var skipped: u64 = 0;
        while (skipped < start) {
            const to_skip = @min(start - skipped, file_buf.len);
            const n = reader.interface.readSliceShort(file_buf[0..@intCast(to_skip)]) catch break;
            if (n == 0) break;
            skipped += n;
        }
        var remaining = length;
        while (remaining > 0) {
            const to_read = @min(remaining, copy_buf.len);
            const n = reader.interface.readSliceShort(copy_buf[0..@intCast(to_read)]) catch break;
            if (n == 0) break;
            req.server.out.writeAll(copy_buf[0..n]) catch break;
            remaining -= n;
        }
    } else {
        const s = std.fmt.bufPrint(&header_buf, "HTTP/1.1 200 OK\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nAccept-Ranges: bytes\r\nConnection: keep-alive\r\n\r\n", .{ content_type, stat.size }) catch return false;
        req.server.out.writeAll(s) catch return false;

        var file_buf: [8192]u8 = undefined;
        var reader = f.reader(io, &file_buf);
        var copy_buf: [8192]u8 = undefined;
        var remaining = stat.size;
        while (remaining > 0) {
            const to_read = @min(remaining, copy_buf.len);
            const n = reader.interface.readSliceShort(copy_buf[0..to_read]) catch break;
            if (n == 0) break;
            req.server.out.writeAll(copy_buf[0..n]) catch break;
            remaining -= n;
        }
    }

    req.server.out.flush() catch return false;
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
