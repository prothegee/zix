const std = @import("std");
const zix = @import("zix");

const IP: []const u8 = "127.0.0.1";
const PORT: u16 = 9106;
const WORKERS: usize = 0;
const POOL_SIZE: usize = 0;

const PUBLIC_DIR = "./public";
const UPLOAD_SUBDIR = "u";
const UPLOAD_DIR = PUBLIC_DIR ++ "/" ++ UPLOAD_SUBDIR;

// Handlers use g_io for file I/O since the Http1 handler signature has no io param.
// Set once in main before the server starts — safe for concurrent reads.
var g_io: std.Io = undefined;

// --------------------------------------------------------- //

fn createInitDirs(io: std.Io) void {
    std.Io.Dir.cwd().createDirPath(io, PUBLIC_DIR) catch {};
    std.Io.Dir.cwd().createDirPath(io, UPLOAD_DIR) catch {};
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
// Reads raw body and writes it to UPLOAD_DIR/<filename>.
// Filename comes from query param: /upload?name=file.txt
//
// curl usage:
// curl -X POST "http://localhost:9106/upload?name=file.txt" --data-binary @/path/to/file.txt
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

// GET /static/*
// Serves files from PUBLIC_DIR. Path after /static maps directly to PUBLIC_DIR.
//
// curl usage:
// curl -X GET "http://localhost:9106/static/index.html"
// curl -X GET "http://localhost:9106/static/u/file.txt"
fn staticHandler(head: *const zix.Http1.ParsedHead, body: []const u8, fd: std.posix.fd_t) void {
    _ = body;
    if (!std.mem.eql(u8, head.method, "GET") and !std.mem.eql(u8, head.method, "HEAD")) {
        zix.Http1.writeJson(fd, 405, "{\"error\":\"method not allowed\"}") catch {};
        return;
    }

    const prefix = "/static";
    const sub = if (std.mem.startsWith(u8, head.path, prefix)) head.path[prefix.len..] else "/";
    const rel = if (std.mem.startsWith(u8, sub, "/")) sub[1..] else sub;

    if (std.mem.indexOf(u8, rel, "..") != null) {
        zix.Http1.writeSimple(fd, 403, "text/plain", "Forbidden") catch {};
        return;
    }

    var path_buf: [512]u8 = undefined;
    const file_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ PUBLIC_DIR, rel }) catch {
        zix.Http1.writeSimple(fd, 500, "text/plain", "Internal Server Error") catch {};
        return;
    };

    const file = std.Io.Dir.cwd().openFile(g_io, file_path, .{}) catch {
        zix.Http1.writeSimple(fd, 404, "text/plain", "Not Found") catch {};
        return;
    };
    defer file.close(g_io);

    const stat = file.stat(g_io) catch {
        zix.Http1.writeSimple(fd, 500, "text/plain", "Internal Server Error") catch {};
        return;
    };

    const range_hdr = zix.Http1.getHeader(head, "range");
    const content_type = detectContentType(rel);

    if (std.mem.eql(u8, head.method, "HEAD")) {
        zix.Http1.writeSimpleNoBody(fd, 200, content_type, @intCast(stat.size)) catch {};
        return;
    }

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

    if (range_hdr) |range_val| {
        zix.Http1.writeRange(fd, content_type, all.items, range_val) catch {};
    } else {
        zix.Http1.writeSimple(fd, 200, content_type, all.items) catch {};
    }
}

// --------------------------------------------------------- //

fn dispatch(head: *const zix.Http1.ParsedHead, body: []const u8, fd: std.posix.fd_t) void {
    if (std.mem.eql(u8, head.path, "/")) {
        homeHandler(head, body, fd);
    } else if (std.mem.eql(u8, head.path, "/upload")) {
        uploadHandler(head, body, fd);
    } else if (std.mem.startsWith(u8, head.path, "/static")) {
        staticHandler(head, body, fd);
    } else {
        zix.Http1.writeSimple(fd, 404, "text/plain", "Not Found") catch {};
    }
}

pub fn main(process: std.process.Init) !void {
    g_io = process.io;
    createInitDirs(process.io);

    var server = zix.Http1.Server.init(.{
        .io = process.io,
        .ip = IP,
        .port = PORT,
        .dispatch_model = .POOL,
        .workers = WORKERS,
        .pool_size = POOL_SIZE,
    });
    defer server.deinit();

    try server.run(dispatch);
}
