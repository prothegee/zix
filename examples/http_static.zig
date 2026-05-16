const std = @import("std");
const zix = @import("zix");

const IP: []const u8 = "127.0.0.1";
const PORT: u16 = 9006;
const DISPATCH_MODEL: zix.Http.DispatchModel = .POOL;
const MAX_KERNEL_BACKLOG: usize = 1024 * 4;
const MAX_CLIENT_REQUEST: usize = 1024 * 64; // 64 KB streaming read buffer (supports file uploads)
const MAX_ALLOCATOR_SIZE: usize = 1024 * 64;
const MAX_CLIENT_RESPONSE: usize = 1024 * 4;
const WORKERS: usize = 0; // 0 = auto (cpu_count accept threads)
const POOL_SIZE: usize = 0; // 0 = auto (max(10, cpu_count * 2) pool threads)

const PUBLIC_DIR = "./public";
const UPLOAD_SUBDIR = "u";
const UPLOAD_DIR = PUBLIC_DIR ++ "/" ++ UPLOAD_SUBDIR;
const SECRET_SUBDIR = "secret";
const SECRET_DIR = PUBLIC_DIR ++ "/" ++ SECRET_SUBDIR;

const SEC_KEY = "sec";
const SEC_VAL = "abc123";

// --------------------------------------------------------- //

// Creates all required directories at startup.
// Silently ignores "already exists" errors — safe to call on every start.
fn createInitDirs(io: std.Io) void {
    std.Io.Dir.cwd().createDirPath(io, PUBLIC_DIR) catch {};
    std.Io.Dir.cwd().createDirPath(io, UPLOAD_DIR) catch {};
    std.Io.Dir.cwd().createDirPath(io, SECRET_DIR) catch {};
}

// --------------------------------------------------------- //

// GET /
// curl usage: curl -X GET "http://localhost:9006/"
pub fn homeHandler(req: *zix.Http.Request, res: *zix.Http.Response, ctx: *zix.Http.Context) !void {
    _ = req;
    _ = ctx;
    res.setContentType(.TEXT_PLAIN);
    try res.send("home");
}

// POST /upload
// Accepts multipart/form-data with two fields:
//   file  - the file to upload
//   data  - JSON string: {"userid": 0, "sessionid": "<uuidv7>"}
//
// curl usage:
//   curl -X POST "http://localhost:9006/upload" \
//     -F "file=@/path/to/file.txt" \
//     -F 'data={"userid":0,"sessionid":"01944f5a-0000-7000-8000-000000000000"}'
//
// Response: {"file":{"name":"file.txt","size":42,"path":"./public/u/file.txt"},"data":{"userid":0,"sessionid":"..."}}
pub fn uploadHandler(req: *zix.Http.Request, res: *zix.Http.Response, ctx: *zix.Http.Context) !void {
    if (req.method() != .POST) {
        res.setStatus(.METHOD_NOT_ALLOWED);
        try res.sendJson("{\"error\":\"method not allowed\"}");
        return;
    }

    const ct = req.header("content-type") orelse {
        res.setStatus(.BAD_REQUEST);
        try res.sendJson("{\"error\":\"missing content-type\"}");
        return;
    };

    const bprefix = "boundary=";
    const bi = std.mem.indexOf(u8, ct, bprefix) orelse {
        res.setStatus(.BAD_REQUEST);
        try res.sendJson("{\"error\":\"missing boundary in content-type\"}");
        return;
    };
    var boundary = ct[bi + bprefix.len ..];
    if (std.mem.indexOfScalar(u8, boundary, ';')) |semi| boundary = boundary[0..semi];
    boundary = std.mem.trim(u8, boundary, " \t\r\n\"");

    const body = try req.body();

    var parser = zix.Http.Multipart.init(ctx.allocator, boundary);
    defer parser.deinit();
    try parser.parse(body);

    const file_field = parser.getField("file") orelse {
        res.setStatus(.BAD_REQUEST);
        try res.sendJson("{\"error\":\"missing field: file\"}");
        return;
    };

    const data_field = parser.getField("data") orelse {
        res.setStatus(.BAD_REQUEST);
        try res.sendJson("{\"error\":\"missing field: data\"}");
        return;
    };

    const UploadData = struct {
        userid: i64 = 0,
        sessionid: []const u8 = "",
    };
    const parsed = std.json.parseFromSlice(UploadData, ctx.allocator, data_field.data, .{}) catch {
        res.setStatus(.BAD_REQUEST);
        try res.sendJson("{\"error\":\"invalid data field: expected JSON {\\\"userid\\\": int, \\\"sessionid\\\": string}\"}");
        return;
    };
    defer parsed.deinit();
    const upload_data = parsed.value;

    // You can rename file first before save by replacing `filename` with any string, e.g.:
    //   const filename = "custom_name.txt";
    // or build it dynamically from the parsed data fields:
    //   const filename = try std.fmt.allocPrint(ctx.allocator, "{s}_{s}", .{ upload_data.sessionid, file_field.filename orelse "upload" });
    const filename = file_field.filename orelse "upload";

    const saved_path = try zix.utils.file.save(ctx.io, ctx.allocator, UPLOAD_DIR, filename, file_field.data);

    var buf: [1024]u8 = undefined;
    const msg = try std.fmt.bufPrint(
        &buf,
        "{{\"file\":{{\"name\":\"{s}\",\"size\":{d},\"path\":\"{s}\"}},\"data\":{{\"userid\":{d},\"sessionid\":\"{s}\"}}}}",
        .{ filename, file_field.data.len, saved_path, upload_data.userid, upload_data.sessionid },
    );
    try res.sendJson(msg);
}

// GET /secret/<file>?sec=abc123
// Serves files from SECRET_DIR with a mandatory access param.
//
// Logic (file existence is checked before the param):
//   1. File not found in SECRET_DIR        -> 404
//   2. File found, sec param missing/wrong -> 403
//   3. File found, sec=abc123              -> 200 with MIME type resolved from extension
//                                            (browser-displayable types render inline,
//                                             unknown/binary types prompt a download)
//
// curl usage:
//   curl -X GET "http://localhost:9006/secret/file.txt?sec=abc123"
//   curl -X GET "http://localhost:9006/secret/file.txt"               (-> 403 if file exists)
//   curl -X GET "http://localhost:9006/secret/missing.txt?sec=abc123" (-> 404)
pub fn secretHandler(req: *zix.Http.Request, res: *zix.Http.Response, ctx: *zix.Http.Context) !void {
    if (req.method() != .GET) {
        res.setStatus(.METHOD_NOT_ALLOWED);
        try res.sendJson("{\"error\":\"method not allowed\"}");
        return;
    }

    // Strip "/secret/" prefix to get the sub-path
    const p = req.path();
    const prefix = "/secret";
    const sub = if (p.len > prefix.len and p[prefix.len] == '/') p[prefix.len + 1 ..] else "";

    if (sub.len == 0 or std.mem.indexOf(u8, sub, "..") != null) {
        res.setStatus(.NOT_FOUND);
        try res.send("Not Found");
        return;
    }

    // Build full path: SECRET_DIR + "/" + sub
    var path_buf: [512]u8 = undefined;
    if (SECRET_DIR.len + 1 + sub.len > path_buf.len) {
        res.setStatus(.NOT_FOUND);
        try res.send("Not Found");
        return;
    }
    @memcpy(path_buf[0..SECRET_DIR.len], SECRET_DIR);
    path_buf[SECRET_DIR.len] = '/';
    @memcpy(path_buf[SECRET_DIR.len + 1 ..][0..sub.len], sub);
    const full_path = path_buf[0 .. SECRET_DIR.len + 1 + sub.len];

    // Check file existence first — always 404 before revealing the sec requirement
    const f = std.Io.Dir.cwd().openFile(ctx.io, full_path, .{}) catch {
        res.setStatus(.NOT_FOUND);
        try res.send("Not Found");
        return;
    };
    defer f.close(ctx.io);

    const stat = f.stat(ctx.io) catch {
        res.setStatus(.NOT_FOUND);
        try res.send("Not Found");
        return;
    };
    if (stat.kind != .file) {
        res.setStatus(.NOT_FOUND);
        try res.send("Not Found");
        return;
    }

    // File exists — now enforce sec param
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

    // Read file
    const size: usize = @intCast(stat.size);
    const data = try ctx.allocator.alloc(u8, size);
    var file_buf: [8192]u8 = undefined;
    var reader = f.reader(ctx.io, &file_buf);
    var total: usize = 0;
    while (total < size) {
        const n = reader.interface.readSliceShort(data[total..]) catch break;
        if (n == 0) break;
        total += n;
    }

    // Resolve MIME from extension via Content.fromExtension — displayable types render
    // inline in the browser, unknown/binary types fall back to octet-stream and prompt
    // a download.
    const ext = if (std.mem.lastIndexOfScalar(u8, sub, '.')) |dot| sub[dot + 1 ..] else "";
    res.setContentType(zix.Http.Content.typeFromExtension(ext));
    try res.send(data[0..total]);

    // If you want to force download for all files regardless of type, use:
    // res.setContentType(.APPLICATION_OCTET_STREAM);
    // try res.send(data[0..total]);
}

// --------------------------------------------------------- //

pub fn main(process: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();

    createInitDirs(process.io);

    var server = try zix.Http.Server.init(4096, .{
        .io = process.io,
        .allocator = arena.allocator(),
        .ip = IP,
        .port = PORT,
        .dispatch_model = DISPATCH_MODEL,
        .max_kernel_backlog = MAX_KERNEL_BACKLOG,
        .max_client_request = MAX_CLIENT_REQUEST,
        .max_allocator_size = MAX_ALLOCATOR_SIZE,
        .max_client_response = MAX_CLIENT_RESPONSE,
        .public_dir = PUBLIC_DIR,
        .public_dir_upload = UPLOAD_SUBDIR,
        .workers = WORKERS,
        .pool_size = POOL_SIZE,
    });
    defer server.deinit();

    server.registerHandler("/", homeHandler);
    server.registerHandler("/upload", uploadHandler);
    server.registerPrefixHandler("/secret", secretHandler);

    try server.run();
}
