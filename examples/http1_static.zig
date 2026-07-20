const std = @import("std");
const zix = @import("zix");

const IP: []const u8 = "127.0.0.1";
const PORT: u16 = 9024;
const DISPATCH_MODEL: zix.Http1.DispatchModel = .POOL;
const KERNEL_BACKLOG: u31 = 1024;
const MAX_RECV_BUF: usize = 16 * 1024;
const COMPRESSION_MAX_OUT: usize = 256 * 1024;
const WORKERS: usize = 0; // 0 = cpu_count accept threads
const POOL_SIZE: usize = 0; // 0 = max(10, cpu_count * 2) pool threads

const PUBLIC_DIR = "./public";
const UPLOAD_SUBDIR = "u";
const UPLOAD_DIR = PUBLIC_DIR ++ "/" ++ UPLOAD_SUBDIR;
const SECRET_SUBDIR = "secret";
const SECRET_DIR = PUBLIC_DIR ++ "/" ++ SECRET_SUBDIR;

const SEC_KEY = "sec";
const SEC_VAL = "abc123";

// Handlers reach the io backend and a per-request scratch arena through ctx (the
// trio's context), so file I/O and parsing use ctx.io and ctx.allocator directly.

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

fn detectContentType(path: []const u8) zix.Http1.ContentType {
    const dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse return .APPLICATION_OCTET_STREAM;

    return zix.Http1.Content.typeFromExtension(path[dot + 1 ..]);
}

// --------------------------------------------------------- //

// GET /
// curl usage: curl -X GET "http://localhost:9024/"
fn homeHandler(_: *zix.Http1.Request, res: *zix.Http1.Response, _: *zix.Http1.Context) !void {
    res.setContentType(.TEXT_PLAIN);

    try res.send("home");
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
// Body-size limit: the body handed to a handler is capped by the dispatch model, NOT by
// max_recv_buf.
// - .POOL / .ASYNC / .MIXED (blocking core.serveConn): body is capped at the fixed 8192-byte
//   body_buf. A larger upload is silently truncated to 8192 bytes.
// - .EPOLL (serveEpollConn): body must fit in max_recv_buf. A larger body arrives EMPTY (the
//   rest is drained off the socket), so the handler sees an empty req.body().
// For multipart or large uploads, use the high-level zix.Http static server instead.
fn uploadHandler(req: *zix.Http1.Request, res: *zix.Http1.Response, ctx: *zix.Http1.Context) !void {
    if (req.method() != .POST) {
        res.setStatus(.METHOD_NOT_ALLOWED);

        try res.sendJson("{\"error\":\"method not allowed\"}");
        return;
    }

    const name = req.queryParam("name") orelse {
        res.setStatus(.BAD_REQUEST);

        try res.sendJson("{\"error\":\"missing query param: name\"}");
        return;
    };

    if (std.mem.indexOf(u8, name, "..") != null or std.mem.indexOfScalar(u8, name, '/') != null) {
        res.setStatus(.BAD_REQUEST);

        try res.sendJson("{\"error\":\"invalid filename\"}");
        return;
    }

    var path_buf: [512]u8 = undefined;
    const file_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ UPLOAD_DIR, name }) catch {
        res.setStatus(.INTERNAL_SERVER_ERROR);

        try res.sendJson("{\"error\":\"path too long\"}");
        return;
    };

    const file = std.Io.Dir.cwd().createFile(ctx.io, file_path, .{}) catch {
        res.setStatus(.INTERNAL_SERVER_ERROR);

        try res.sendJson("{\"error\":\"failed to create file\"}");
        return;
    };
    defer file.close(ctx.io);

    var write_buf: [8192]u8 = undefined;
    var writer = file.writer(ctx.io, &write_buf);
    writer.interface.writeAll(try req.body()) catch {
        res.setStatus(.INTERNAL_SERVER_ERROR);

        try res.sendJson("{\"error\":\"failed to write file\"}");
        return;
    };
    writer.interface.flush() catch {};

    var resp_buf: [512]u8 = undefined;
    const resp = std.fmt.bufPrint(
        &resp_buf,
        "{{\"file\":{{\"name\":\"{s}\",\"size\":{d},\"path\":\"{s}\"}}}}",
        .{ name, (try req.body()).len, file_path },
    ) catch return;

    try res.sendJson(resp);
}

// POST /upload-multipart
// Multipart counterpart to /upload: accepts multipart/form-data (curl -F) and uses
// zix.utils.multipart.Parser, the protocol-agnostic parser shared with the zix.Http static
// example, to pull the "file" field out of the body. The saved file is then reachable through
// the engine static fallback at /<public_dir_upload>/<filename> (e.g. GET /u/file.txt).
//
// The trio's ctx.allocator is a per-request arena (reset after the handler returns), so the
// parser and the save path allocate into it directly with no manual teardown.
//
// curl usage:
// curl -X POST "http://localhost:9024/upload-multipart" -F "file=@/path/to/file.txt"
//
// Body-size cap: the multipart body is bounded by the same dispatch-model limit as /upload
// (see above), so this demonstrates SMALL uploads only. For real or large multipart uploads,
// use the high-level zix.Http static server instead.
fn uploadMultipartHandler(req: *zix.Http1.Request, res: *zix.Http1.Response, ctx: *zix.Http1.Context) !void {
    if (req.method() != .POST) {
        res.setStatus(.METHOD_NOT_ALLOWED);

        try res.sendJson("{\"error\":\"method not allowed\"}");
        return;
    }

    const content_type = req.header("content-type") orelse {
        res.setStatus(.BAD_REQUEST);

        try res.sendJson("{\"error\":\"missing content-type\"}");
        return;
    };

    const boundary_prefix = "boundary=";
    const boundary_offset = std.mem.indexOf(u8, content_type, boundary_prefix) orelse {
        res.setStatus(.BAD_REQUEST);

        try res.sendJson("{\"error\":\"missing boundary in content-type\"}");
        return;
    };
    var boundary = content_type[boundary_offset + boundary_prefix.len ..];
    if (std.mem.indexOfScalar(u8, boundary, ';')) |semi| boundary = boundary[0..semi];
    boundary = std.mem.trim(u8, boundary, " \t\r\n\"");

    var parser = zix.utils.multipart.Parser.init(ctx.allocator, boundary);
    defer parser.deinit();

    parser.parse(try req.body()) catch {
        res.setStatus(.BAD_REQUEST);

        try res.sendJson("{\"error\":\"invalid multipart body\"}");
        return;
    };

    const file_field = parser.getField("file") orelse {
        res.setStatus(.BAD_REQUEST);

        try res.sendJson("{\"error\":\"missing field: file\"}");
        return;
    };

    const filename = file_field.filename orelse "upload";
    if (std.mem.indexOf(u8, filename, "..") != null or std.mem.indexOfScalar(u8, filename, '/') != null) {
        res.setStatus(.BAD_REQUEST);

        try res.sendJson("{\"error\":\"invalid filename\"}");
        return;
    }

    const saved_path = zix.utils.file.save(ctx.io, ctx.allocator, UPLOAD_DIR, filename, file_field.data) catch {
        res.setStatus(.INTERNAL_SERVER_ERROR);

        try res.sendJson("{\"error\":\"failed to save file\"}");
        return;
    };

    var resp_buf: [512]u8 = undefined;
    const resp = std.fmt.bufPrint(
        &resp_buf,
        "{{\"file\":{{\"name\":\"{s}\",\"size\":{d},\"path\":\"{s}\"}}}}",
        .{ filename, file_field.data.len, saved_path },
    ) catch return;

    try res.sendJson(resp);
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
fn secretHandler(req: *zix.Http1.Request, res: *zix.Http1.Response, ctx: *zix.Http1.Context) !void {
    if (req.method() != .GET) {
        res.setStatus(.METHOD_NOT_ALLOWED);

        try res.sendJson("{\"error\":\"method not allowed\"}");
        return;
    }

    const prefix = "/secret";
    const path = req.path();
    const subpath = if (path.len > prefix.len and path[prefix.len] == '/') path[prefix.len + 1 ..] else "";

    if (subpath.len == 0 or std.mem.indexOf(u8, subpath, "..") != null) {
        res.setStatus(.NOT_FOUND);
        res.setContentType(.TEXT_PLAIN);

        try res.send("Not Found");
        return;
    }

    var path_buf: [512]u8 = undefined;
    const file_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ SECRET_DIR, subpath }) catch {
        res.setStatus(.NOT_FOUND);
        res.setContentType(.TEXT_PLAIN);

        try res.send("Not Found");
        return;
    };

    // Check file existence first: always 404 before revealing the sec requirement
    const file = std.Io.Dir.cwd().openFile(ctx.io, file_path, .{}) catch {
        res.setStatus(.NOT_FOUND);
        res.setContentType(.TEXT_PLAIN);

        try res.send("Not Found");
        return;
    };
    defer file.close(ctx.io);

    const stat = file.stat(ctx.io) catch {
        res.setStatus(.NOT_FOUND);
        res.setContentType(.TEXT_PLAIN);

        try res.send("Not Found");
        return;
    };

    if (stat.kind != .file) {
        res.setStatus(.NOT_FOUND);
        res.setContentType(.TEXT_PLAIN);

        try res.send("Not Found");
        return;
    }

    // File exists, now enforce sec param
    const sec = req.queryParam(SEC_KEY) orelse {
        res.setStatus(.FORBIDDEN);

        try res.sendJson("{\"error\":\"forbidden\"}");
        return;
    };

    if (!std.mem.eql(u8, sec, SEC_VAL)) {
        res.setStatus(.FORBIDDEN);

        try res.sendJson("{\"error\":\"forbidden\"}");
        return;
    }

    const content_type = detectContentType(subpath);

    var file_buf: [8192]u8 = undefined;
    var reader = file.reader(ctx.io, &file_buf);

    var all: std.ArrayList(u8) = .empty;
    defer all.deinit(ctx.allocator);

    var remaining = stat.size;
    while (remaining > 0) {
        const to_read = @min(remaining, file_buf.len);
        const n = reader.interface.readSliceShort(file_buf[0..to_read]) catch break;
        if (n == 0) break;
        all.appendSlice(ctx.allocator, file_buf[0..n]) catch break;
        remaining -= n;
    }

    res.setContentType(content_type);

    try res.send(all.items);
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
        .public_dir = PUBLIC_DIR,
        .public_dir_upload = UPLOAD_SUBDIR,
        .workers = WORKERS,
        .pool_size = POOL_SIZE,
    });
    defer server.deinit();

    try server.run();
}
