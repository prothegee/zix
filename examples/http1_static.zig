const std = @import("std");
const zix = @import("zix");

const IP: []const u8 = "127.0.0.1";
const PORT: u16 = 9024;
const DISPATCH_MODEL: zix.Http1.DispatchModel = .POOL;
const KERNEL_BACKLOG: u31 = 1024;
const MAX_RECV_BUF: usize = 16 * 1024;
const COMPRESSION_MAX_OUT: usize = 256 * 1024;
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

// Seed one demo file so the engine static fallback is reachable out of the box:
//   curl http://localhost:9024/hello.txt
fn seedDemoFile(io: std.Io) void {
    const file = std.Io.Dir.cwd().createFile(io, PUBLIC_DIR ++ "/hello.txt", .{}) catch return;
    defer file.close(io);

    var write_buf: [256]u8 = undefined;
    var writer = file.writer(io, &write_buf);
    writer.interface.writeAll("served from public_dir by the zix.Http1 engine\n") catch {};
    writer.interface.flush() catch {};
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
    if (std.mem.endsWith(u8, path, ".txt"))
        return "text/plain";
    return "application/octet-stream";
}

// --------------------------------------------------------- //

// GET /
// curl usage: curl -X GET "http://localhost:9024/"
fn homeHandler(head: *const zix.Http1.ParsedHead, body: []const u8, fd: std.posix.fd_t) void {
    _ = head;
    _ = body;
    zix.Http1.sendSimpleFD(fd, 200, "text/plain", "home") catch {};
}

// POST /upload
// Reads the raw request body and writes it to UPLOAD_DIR/<filename>. UPLOAD_DIR is
// public_dir/public_dir_upload, so an uploaded file is then reachable through the engine
// static fallback at /<public_dir_upload>/<filename> (e.g. GET /u/file.txt).
// Filename comes from query param: /upload?name=file.txt
//
// curl usage:
// curl -X POST "http://localhost:9024/upload?name=file.txt" --data-binary @/path/to/file.txt
//
// Body-size limit (zix.Http1 has no per-request arena, unlike zix.Http): the body handed to
// a handler is capped by the dispatch model, NOT by max_recv_buf.
// - .POOL / .ASYNC / .MIXED (blocking core.serveConn): body is capped at the fixed 8192-byte
//   body_buf. A larger upload is silently truncated to 8192 bytes.
// - .EPOLL (serveEpollConn): body must fit in max_recv_buf. A larger body arrives EMPTY (the
//   rest is drained off the socket), so the handler sees body.len == 0.
// For multipart or large uploads, use the high-level zix.Http static server instead.
fn uploadHandler(head: *const zix.Http1.ParsedHead, body: []const u8, fd: std.posix.fd_t) void {
    if (!std.mem.eql(u8, head.method, "POST")) {
        zix.Http1.sendJsonFD(fd, 405, "{\"error\":\"method not allowed\"}") catch {};
        return;
    }

    const name = zix.Http1.queryParam(head, "name") orelse {
        zix.Http1.sendJsonFD(fd, 400, "{\"error\":\"missing query param: name\"}") catch {};
        return;
    };

    if (std.mem.indexOf(u8, name, "..") != null or std.mem.indexOfScalar(u8, name, '/') != null) {
        zix.Http1.sendJsonFD(fd, 400, "{\"error\":\"invalid filename\"}") catch {};
        return;
    }

    var path_buf: [512]u8 = undefined;
    const file_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ UPLOAD_DIR, name }) catch {
        zix.Http1.sendJsonFD(fd, 500, "{\"error\":\"path too long\"}") catch {};
        return;
    };

    const file = std.Io.Dir.cwd().createFile(g_io, file_path, .{}) catch {
        zix.Http1.sendJsonFD(fd, 500, "{\"error\":\"failed to create file\"}") catch {};
        return;
    };
    defer file.close(g_io);

    var write_buf: [8192]u8 = undefined;
    var writer = file.writer(g_io, &write_buf);
    writer.interface.writeAll(body) catch {
        zix.Http1.sendJsonFD(fd, 500, "{\"error\":\"failed to write file\"}") catch {};
        return;
    };
    writer.interface.flush() catch {};

    var resp_buf: [512]u8 = undefined;
    const resp = std.fmt.bufPrint(
        &resp_buf,
        "{{\"file\":{{\"name\":\"{s}\",\"size\":{d},\"path\":\"{s}\"}}}}",
        .{ name, body.len, file_path },
    ) catch return;
    zix.Http1.sendJsonFD(fd, 200, resp) catch {};
}

// POST /upload-multipart
// Multipart counterpart to /upload: accepts multipart/form-data (curl -F) and uses
// zix.utils.multipart.Parser, the protocol-agnostic parser shared with the zix.Http static
// example, to pull the "file" field out of the body. The saved file is then reachable through
// the engine static fallback at /<public_dir_upload>/<filename> (e.g. GET /u/file.txt).
//
// zix.Http1 has no per-request arena (unlike zix.Http), so the handler owns a short-lived arena
// for the parser and the save path.
//
// curl usage:
// curl -X POST "http://localhost:9024/upload-multipart" -F "file=@/path/to/file.txt"
//
// Body-size cap: the multipart body is bounded by the same dispatch-model limit as /upload
// (see above), so this demonstrates SMALL uploads only. For real or large multipart uploads,
// use the high-level zix.Http static server instead.
fn uploadMultipartHandler(head: *const zix.Http1.ParsedHead, body: []const u8, fd: std.posix.fd_t) void {
    if (!std.mem.eql(u8, head.method, "POST")) {
        zix.Http1.sendJsonFD(fd, 405, "{\"error\":\"method not allowed\"}") catch {};
        return;
    }

    const content_type = zix.Http1.getHeader(head, "content-type") orelse {
        zix.Http1.sendJsonFD(fd, 400, "{\"error\":\"missing content-type\"}") catch {};
        return;
    };

    const boundary_prefix = "boundary=";
    const boundary_offset = std.mem.indexOf(u8, content_type, boundary_prefix) orelse {
        zix.Http1.sendJsonFD(fd, 400, "{\"error\":\"missing boundary in content-type\"}") catch {};
        return;
    };
    var boundary = content_type[boundary_offset + boundary_prefix.len ..];
    if (std.mem.indexOfScalar(u8, boundary, ';')) |semi| boundary = boundary[0..semi];
    boundary = std.mem.trim(u8, boundary, " \t\r\n\"");

    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();

    var parser = zix.utils.multipart.Parser.init(arena.allocator(), boundary);
    defer parser.deinit();

    parser.parse(body) catch {
        zix.Http1.sendJsonFD(fd, 400, "{\"error\":\"invalid multipart body\"}") catch {};
        return;
    };

    const file_field = parser.getField("file") orelse {
        zix.Http1.sendJsonFD(fd, 400, "{\"error\":\"missing field: file\"}") catch {};
        return;
    };

    const filename = file_field.filename orelse "upload";
    if (std.mem.indexOf(u8, filename, "..") != null or std.mem.indexOfScalar(u8, filename, '/') != null) {
        zix.Http1.sendJsonFD(fd, 400, "{\"error\":\"invalid filename\"}") catch {};
        return;
    }

    const saved_path = zix.utils.file.save(g_io, arena.allocator(), UPLOAD_DIR, filename, file_field.data) catch {
        zix.Http1.sendJsonFD(fd, 500, "{\"error\":\"failed to save file\"}") catch {};
        return;
    };

    var resp_buf: [512]u8 = undefined;
    const resp = std.fmt.bufPrint(
        &resp_buf,
        "{{\"file\":{{\"name\":\"{s}\",\"size\":{d},\"path\":\"{s}\"}}}}",
        .{ filename, file_field.data.len, saved_path },
    ) catch return;
    zix.Http1.sendJsonFD(fd, 200, resp) catch {};
}

// GET /secret/<file>?sec=abc123
// Serves files from SECRET_DIR with a mandatory access param. This is the hand-served
// counterpart to the engine public_dir fallback: a route handler keeps full control over
// access (the engine static fallback serves any file under public_dir unconditionally, so
// access-gated files live OUTSIDE public_dir and are served here instead).
//
// Logic (file existence is checked before the param):
// 1. File not found in SECRET_DIR        -> 404
// 2. File found, sec param missing/wrong -> 403
// 3. File found, sec=abc123              -> 200 with MIME type resolved from extension
//
// curl usage:
// curl -X GET "http://localhost:9024/secret/file.txt?sec=abc123"
// curl -X GET "http://localhost:9024/secret/file.txt"               (-> 403 if file exists)
// curl -X GET "http://localhost:9024/secret/missing.txt?sec=abc123" (-> 404)
fn secretHandler(head: *const zix.Http1.ParsedHead, body: []const u8, fd: std.posix.fd_t) void {
    _ = body;
    if (!std.mem.eql(u8, head.method, "GET")) {
        zix.Http1.sendJsonFD(fd, 405, "{\"error\":\"method not allowed\"}") catch {};
        return;
    }

    const prefix = "/secret";
    const subpath = if (head.path.len > prefix.len and head.path[prefix.len] == '/') head.path[prefix.len + 1 ..] else "";

    if (subpath.len == 0 or std.mem.indexOf(u8, subpath, "..") != null) {
        zix.Http1.sendSimpleFD(fd, 404, "text/plain", "Not Found") catch {};
        return;
    }

    var path_buf: [512]u8 = undefined;
    const file_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ SECRET_DIR, subpath }) catch {
        zix.Http1.sendSimpleFD(fd, 404, "text/plain", "Not Found") catch {};
        return;
    };

    // Check file existence first: always 404 before revealing the sec requirement
    const file = std.Io.Dir.cwd().openFile(g_io, file_path, .{}) catch {
        zix.Http1.sendSimpleFD(fd, 404, "text/plain", "Not Found") catch {};
        return;
    };
    defer file.close(g_io);

    const stat = file.stat(g_io) catch {
        zix.Http1.sendSimpleFD(fd, 404, "text/plain", "Not Found") catch {};
        return;
    };

    if (stat.kind != .file) {
        zix.Http1.sendSimpleFD(fd, 404, "text/plain", "Not Found") catch {};
        return;
    }

    // File exists, now enforce sec param
    const sec = zix.Http1.queryParam(head, SEC_KEY) orelse {
        zix.Http1.sendJsonFD(fd, 403, "{\"error\":\"forbidden\"}") catch {};
        return;
    };

    if (!std.mem.eql(u8, sec, SEC_VAL)) {
        zix.Http1.sendJsonFD(fd, 403, "{\"error\":\"forbidden\"}") catch {};
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

    zix.Http1.sendSimpleFD(fd, 200, content_type, all.items) catch {};
}

// --------------------------------------------------------- //

// Routes own the dynamic paths (/, /upload, /upload-multipart, /secret). Any GET that matches no
// route falls through to the engine static fallback, which serves files from public_dir (set
// below) with MIME-from-extension and Range (206) support. So GET /hello.txt is served by the
// engine, no route handler needed.
const Router = zix.Http1.Router(&[_]zix.Http1.Route{
    .{ .path = "/", .handler = homeHandler },
    .{ .path = "/upload", .handler = uploadHandler },
    .{ .path = "/upload-multipart", .handler = uploadMultipartHandler },
    .{ .path = "/secret", .handler = secretHandler, .kind = .PREFIX },
});

pub fn main(process: std.process.Init) !void {
    g_io = process.io;
    createInitDirs(process.io);
    seedDemoFile(process.io);

    var server = zix.Http1.Server.init(Router.dispatch, .{
        .io = process.io,
        .ip = IP,
        .port = PORT,
        .dispatch_model = DISPATCH_MODEL,
        .kernel_backlog = KERNEL_BACKLOG,
        .max_recv_buf = MAX_RECV_BUF,
        .compression_max_out = COMPRESSION_MAX_OUT,
        .max_headers = MAX_HEADERS,
        .public_dir = PUBLIC_DIR,
        .public_dir_upload = UPLOAD_SUBDIR,
        .workers = WORKERS,
        .pool_size = POOL_SIZE,
    });
    defer server.deinit();

    try server.run();
}
