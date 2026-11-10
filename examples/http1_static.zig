//! ZIX example http1 static
//!
//! ### file: examples/http1_static.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Http1 server example that serves public_dir through the static fallback,
//! plus one access-gated route.
//!
//! ### note:
//!
//! The static fallback serves any file under public_dir to anyone. /secret is a
//! PREFIX route, so the router answers it before the fallback and can check
//! access first.
//! Upload lives in http1_upload.zig.
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
const zix = @import("zix");

const builtin = @import("builtin");

// --------------------------------------------------------- //

const IP:[]const u8 = "127.0.0.1";
const PORT:u16 = 9032;
const WORKERS:usize = 0;
const KERNEL_BACKLOG:u31 = 1024;
const MAX_RECV_BUF:usize = 16 * 1024;
const DISPATCH_MODEL:zix.Http1.DispatchModel =
    if (builtin.os.tag == .linux) .URING else .ASYNC;

const PUBLIC_DIR:[]const u8 = "./public";
const SECRET_PREFIX:[]const u8 = "/secret";
const SECRET_DIR:[]const u8 = PUBLIC_DIR ++ SECRET_PREFIX;
const SECRET_MAX_BYTES:usize = 1024 * 1024;

const SEC_KEY:[]const u8 = "sec";
const SEC_VAL:[]const u8 = "abc123";

// --------------------------------------------------------- //

fn createDir(io: std.Io, path: []const u8) void {
    std.Io.Dir.cwd().createDirPath(io, path) catch |err| switch (err) {
        else => std.log.warn("could not create {s}: {s}", .{
            path,
            @errorName(err),
        }),
    };
}

fn writeDemoFile(io: std.Io, path: []const u8, data: []const u8) void {
    std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = path,
        .data = data,
    }) catch |err| switch (err) {
        else => std.log.warn("could not seed {s}: {s}", .{
            path,
            @errorName(err),
        }),
    };
}

/// Seed one public file and one secret file, so both paths work out of the box.
fn seedDemoFiles(io: std.Io) void {
    createDir(io, PUBLIC_DIR);
    createDir(io, SECRET_DIR);

    writeDemoFile(io, PUBLIC_DIR ++ "/hello.txt", "served from public_dir by zix.Http1\n");
    writeDemoFile(io, SECRET_DIR ++ "/file.txt", "served only with the right sec param\n");
}

fn sendNotFound(res: *zix.Http1.Response) !void {
    res.setStatus(.NOT_FOUND);
    res.setContentType(.TEXT_PLAIN);

    try res.send("Not Found");
}

fn sendForbidden(res: *zix.Http1.Response) !void {
    res.setStatus(.FORBIDDEN);

    try res.sendJson("{\"error\":\"forbidden\"}");
}

// GET /
// curl usage: curl "http://localhost:9032/"
fn homeHandler(_: *zix.Http1.Request, res: *zix.Http1.Response, _: *zix.Http1.Context) !void {
    res.setContentType(.TEXT_PLAIN);

    try res.send("home");
}

// GET /secret/<file>?sec=abc123
// The file is looked up first, so a missing file is 404 before the sec param
// is revealed.
// 1. File not found in SECRET_DIR        -> 404
// 2. File found, sec param missing/wrong -> 403
// 3. File found, sec=abc123              -> 200, MIME type from the extension
//
// curl usage:
// curl "http://localhost:9032/secret/file.txt?sec=abc123"
// curl "http://localhost:9032/secret/file.txt"               (403)
// curl "http://localhost:9032/secret/missing.txt?sec=abc123" (404)
fn secretHandler(
    req: *zix.Http1.Request,
    res: *zix.Http1.Response,
    ctx: *zix.Http1.Context,
) !void {
    if (req.method() != .GET) {
        res.setStatus(.METHOD_NOT_ALLOWED);

        try res.sendJson("{\"error\":\"method not allowed\"}");
        return;
    }

    const path = req.path();
    const has_subpath = path.len > SECRET_PREFIX.len and path[SECRET_PREFIX.len] == '/';
    const subpath = if (has_subpath) path[SECRET_PREFIX.len + 1 ..] else "";

    if (subpath.len == 0 or std.mem.indexOf(u8, subpath, "..") != null) {
        return sendNotFound(res);
    }

    var path_buf: [512]u8 = undefined;
    const file_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{
        SECRET_DIR,
        subpath,
    }) catch |err| switch (err) {
        error.NoSpaceLeft => return sendNotFound(res),
    };

    const body = zix.utils.File.load(
        ctx.io,
        ctx.allocator,
        file_path,
        SECRET_MAX_BYTES,
    ) catch |err| switch (err) {
        else => return sendNotFound(res),
    };

    const sec = req.queryParam(SEC_KEY) orelse return sendForbidden(res);
    if (!std.mem.eql(u8, sec, SEC_VAL)) return sendForbidden(res);

    const extension = zix.utils.File.extension(subpath);
    res.setContentType(zix.Http1.Content.typeFromExtension(extension));

    try res.send(body);
}

// --------------------------------------------------------- //

// Any GET that matches no route falls through to the static fallback, which
// serves files from PUBLIC_DIR with MIME from the extension and Range (206).
//
// curl usage:
// curl -i "http://localhost:9032/hello.txt"                        (200)
// curl -i "http://localhost:9032/hello.txt" -H "Range: bytes=0-4"  (206)
// curl -i "http://localhost:9032/missing.txt"                      (404)
const Routes = zix.Http1.Router(&[_]zix.Http1.Route{
    .{
        .path = "/",
        .handler = homeHandler,
    },
    .{
        .path = SECRET_PREFIX,
        .handler = secretHandler,
        .kind = .PREFIX,
    },
});

pub fn main(init: std.process.Init) !void {
    seedDemoFiles(init.io);

    var server = zix.Http1.Server.init(Routes.dispatch, .{
        .io = init.io,
        .ip = IP,
        .port = PORT,
        .workers = WORKERS,
        .kernel_backlog = KERNEL_BACKLOG,
        .max_recv_buf = MAX_RECV_BUF,
        .dispatch_model = DISPATCH_MODEL,
        .public_dir = PUBLIC_DIR,
    });
    defer server.deinit();

    try server.run();
}

