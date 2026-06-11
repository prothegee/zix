const std = @import("std");
const zix = @import("zix");

const IP: []const u8 = "127.0.0.1";
const PORT: u16 = 9106;
const DISPATCH_MODEL: zix.Http1.DispatchModel = .POOL;
const KERNEL_BACKLOG: u31 = 1024;
const MAX_RECV_BUF: usize = 16 * 1024;
const MAX_GZIP_OUT: usize = 256 * 1024;
const MAX_HEADERS: u8 = 16;
const WORKERS: usize = 0; // 0 = cpu_count accept threads
const POOL_SIZE: usize = 0; // 0 = max(10, cpu_count * 2) pool threads

const PUBLIC_DIR = "./public";
const UPLOAD_SUBDIR = "u";
const UPLOAD_DIR = PUBLIC_DIR ++ "/" ++ UPLOAD_SUBDIR;
const SECRET_SUBDIR = "secret";
const SECRET_DIR = PUBLIC_DIR ++ "/" ++ SECRET_SUBDIR;

const SEC_KEY = "sec";
const SEC_VAL = "abc123";

// Handlers use g_io for file I/O since the Http1 handler signature has no io param.
// Set once in main before the server starts, safe for concurrent reads.
var g_io: std.Io = undefined;

// --------------------------------------------------------- //

fn createInitDirs(io: std.Io) void {
    std.Io.Dir.cwd().createDirPath(io, PUBLIC_DIR) catch {};
    std.Io.Dir.cwd().createDirPath(io, UPLOAD_DIR) catch {};
    std.Io.Dir.cwd().createDirPath(io, SECRET_DIR) catch {};
}

fn detectContentType(path: []const u8) []const u8 {
    if (std.mem.endsWith(u8, path, ".html") or std.mem.endsWith(u8, path, ".htm"))
        return "text/html";
    if (std.mem.endsWith(u8, path, ".css"))
        return "text/css";
    if (std.mem.endsWith(u8, path, ".js"))
        return "application/javascript";
    if (std.mem.endsWith(u8, path, ".json"))
        return "application/json";
    if (std.mem.endsWith(u8, path, ".png"))
        return "image/png";
    if (std.mem.endsWith(u8, path, ".jpg") or std.mem.endsWith(u8, path, ".jpeg"))
        return "image/jpeg";
    if (std.mem.endsWith(u8, path, ".svg"))
        return "image/svg+xml";
    if (std.mem.endsWith(u8, path, ".ico"))
        return "image/x-icon";
    if (std.mem.endsWith(u8, path, ".txt"))
        return "text/plain";
    return "application/octet-stream";
}

// --------------------------------------------------------- //

// GET /
// curl usage: curl -X GET "http://localhost:9106/"
fn homeHandler(head: *const zix.Http1.ParsedHead, body: []const u8, fd: std.posix.fd_t) void {
    _ = head;
    _ = body;
    zix.Http1.writeSimple(fd, 200, "text/plain", "home") catch {};
}

// POST /upload
// Reads the raw request body and writes it to UPLOAD_DIR/<filename>.
// Filename comes from query param: /upload?name=file.txt
//
// curl usage:
// curl -X POST "http://localhost:9106/upload?name=file.txt" --data-binary @/path/to/file.txt
//
// Body-size limit (zix.Http1 has no per-request arena, unlike zix.Http): the body handed to
// a handler is capped by the dispatch model, NOT by max_recv_buf.
// - .POOL / .ASYNC / .MIXED (blocking core.serveConn): body is capped at the fixed 8192-byte
//   body_buf. A larger upload is silently truncated to 8192 bytes.
// - .EPOLL (serveEpollConn): body must fit in max_recv_buf. A larger body arrives EMPTY (the
//   rest is drained off the socket), so the handler sees body.len == 0.
// For multipart or large uploads, use the high-level zix.Http static server instead.
//
// Verified 2026-06-10 against this example (.POOL, max_recv_buf = 16 KB):
//   19-byte body    -> {"size":19}    (ok)
//   8192-byte body  -> {"size":8192}  (ok, exactly at the body_buf cap)
//   12000-byte body -> {"size":8192}  (TRUNCATED, even though 12000 < 16 KB max_recv_buf)
//   40000-byte body -> {"size":8192}  (TRUNCATED)
fn uploadHandler(head: *const zix.Http1.ParsedHead, body: []const u8, fd: std.posix.fd_t) void {
    if (!std.mem.eql(u8, head.method, "POST")) {
        zix.Http1.writeJson(fd, 405, "{\"error\":\"method not allowed\"}") catch {};
        return;
    }

    const name = zix.Http1.queryParam(head, "name") orelse {
        zix.Http1.writeJson(fd, 400, "{\"error\":\"missing query param: name\"}") catch {};
        return;
    };

    if (std.mem.indexOf(u8, name, "..") != null or std.mem.indexOfScalar(u8, name, '/') != null) {
        zix.Http1.writeJson(fd, 400, "{\"error\":\"invalid filename\"}") catch {};
        return;
    }

    var path_buf: [512]u8 = undefined;
    const file_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ UPLOAD_DIR, name }) catch {
        zix.Http1.writeJson(fd, 500, "{\"error\":\"path too long\"}") catch {};
        return;
    };

    const file = std.Io.Dir.cwd().createFile(g_io, file_path, .{}) catch {
        zix.Http1.writeJson(fd, 500, "{\"error\":\"failed to create file\"}") catch {};
        return;
    };
    defer file.close(g_io);

    var write_buf: [8192]u8 = undefined;
    var writer = file.writer(g_io, &write_buf);
    writer.interface.writeAll(body) catch {
        zix.Http1.writeJson(fd, 500, "{\"error\":\"failed to write file\"}") catch {};
        return;
    };
    writer.interface.flush() catch {};

    var resp_buf: [512]u8 = undefined;
    const resp = std.fmt.bufPrint(
        &resp_buf,
        "{{\"file\":{{\"name\":\"{s}\",\"size\":{d},\"path\":\"{s}\"}}}}",
        .{ name, body.len, file_path },
    ) catch return;
    zix.Http1.writeJson(fd, 200, resp) catch {};
}

// GET /secret/<file>?sec=abc123
// Serves files from SECRET_DIR with a mandatory access param.
//
// Logic (file existence is checked before the param):
// 1. File not found in SECRET_DIR        -> 404
// 2. File found, sec param missing/wrong -> 403
// 3. File found, sec=abc123              -> 200 with MIME type resolved from extension
//
// curl usage:
// curl -X GET "http://localhost:9106/secret/file.txt?sec=abc123"
// curl -X GET "http://localhost:9106/secret/file.txt"               (-> 403 if file exists)
// curl -X GET "http://localhost:9106/secret/missing.txt?sec=abc123" (-> 404)
fn secretHandler(head: *const zix.Http1.ParsedHead, body: []const u8, fd: std.posix.fd_t) void {
    _ = body;
    if (!std.mem.eql(u8, head.method, "GET")) {
        zix.Http1.writeJson(fd, 405, "{\"error\":\"method not allowed\"}") catch {};
        return;
    }

    const prefix = "/secret";
    const subpath = if (head.path.len > prefix.len and head.path[prefix.len] == '/') head.path[prefix.len + 1 ..] else "";

    if (subpath.len == 0 or std.mem.indexOf(u8, subpath, "..") != null) {
        zix.Http1.writeSimple(fd, 404, "text/plain", "Not Found") catch {};
        return;
    }

    var path_buf: [512]u8 = undefined;
    const file_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ SECRET_DIR, subpath }) catch {
        zix.Http1.writeSimple(fd, 404, "text/plain", "Not Found") catch {};
        return;
    };

    // Check file existence first: always 404 before revealing the sec requirement
    const file = std.Io.Dir.cwd().openFile(g_io, file_path, .{}) catch {
        zix.Http1.writeSimple(fd, 404, "text/plain", "Not Found") catch {};
        return;
    };
    defer file.close(g_io);

    const stat = file.stat(g_io) catch {
        zix.Http1.writeSimple(fd, 404, "text/plain", "Not Found") catch {};
        return;
    };

    if (stat.kind != .file) {
        zix.Http1.writeSimple(fd, 404, "text/plain", "Not Found") catch {};
        return;
    }

    // File exists, now enforce sec param
    const sec = zix.Http1.queryParam(head, SEC_KEY) orelse {
        zix.Http1.writeJson(fd, 403, "{\"error\":\"forbidden\"}") catch {};
        return;
    };

    if (!std.mem.eql(u8, sec, SEC_VAL)) {
        zix.Http1.writeJson(fd, 403, "{\"error\":\"forbidden\"}") catch {};
        return;
    }

    const content_type = detectContentType(subpath);

    var file_buf: [8192]u8 = undefined;
    var reader = file.reader(g_io, &file_buf);

    var all: std.ArrayList(u8) = .empty;
    defer all.deinit(std.heap.smp_allocator);

    var remaining = stat.size;
    while (remaining > 0) {
        const to_read = @min(remaining, file_buf.len);
        const n = reader.interface.readSliceShort(file_buf[0..to_read]) catch break;
        if (n == 0) break;
        all.appendSlice(std.heap.smp_allocator, file_buf[0..n]) catch break;
        remaining -= n;
    }

    zix.Http1.writeSimple(fd, 200, content_type, all.items) catch {};
}

// --------------------------------------------------------- //

const Router = zix.Http1.Router(&[_]zix.Http1.Route{
    .{ .path = "/", .handler = homeHandler },
    .{ .path = "/upload", .handler = uploadHandler },
    .{ .path = "/secret", .handler = secretHandler, .kind = .PREFIX },
});

pub fn main(process: std.process.Init) !void {
    g_io = process.io;
    createInitDirs(process.io);

    var server = zix.Http1.Server.init(Router.dispatch, .{
        .io = process.io,
        .ip = IP,
        .port = PORT,
        .dispatch_model = DISPATCH_MODEL,
        .kernel_backlog = KERNEL_BACKLOG,
        .max_recv_buf = MAX_RECV_BUF,
        .max_gzip_out = MAX_GZIP_OUT,
        .max_headers = MAX_HEADERS,
        .workers = WORKERS,
        .pool_size = POOL_SIZE,
    });
    defer server.deinit();

    try server.run();
}
