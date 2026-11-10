//! ZIX example http1 upload
//!
//! ### file: examples/http1_upload.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Http1 server example that saves a raw body or a multipart/form-data file
//! into an upload directory and answers with JSON.
//!
//! ### note:
//!
//! max_request_body is the largest body the server accepts. A larger declared
//! body gets 413 from the engine before the handler runs.
//! max_recv_buf is the slice the handler receives. Both are 2 MiB here, so an
//! accepted body always reaches the handler whole. Multipart framing counts
//! toward the limit.
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
const PORT:u16 = 9024;
const WORKERS:usize = 0;
const KERNEL_BACKLOG:u31 = 1024;
const DISPATCH_MODEL:zix.Http1.DispatchModel =
    if (builtin.os.tag == .linux) .URING else .ASYNC;
const MAX_REQUEST_BODY:usize = 2 * 1024 * 1024;
const MAX_RECV_BUF:usize = 2 * 1024 * 1024;

const UPLOAD_DIR:[]const u8 = "./public/u";

// --------------------------------------------------------- //

/// Whether a client-supplied file name is safe to join under UPLOAD_DIR.
fn isSafeFilename(name: []const u8) bool {
    if (name.len == 0) return false;

    return std.mem.indexOf(u8, name, "..") == null and
        std.mem.indexOfScalar(u8, name, '/') == null;
}

/// Boundary value from a multipart/form-data Content-Type header.
fn boundaryFromContentType(content_type: []const u8) ?[]const u8 {
    const prefix = "boundary=";
    const offset = std.mem.indexOf(u8, content_type, prefix) orelse return null;

    var boundary = content_type[offset + prefix.len ..];
    if (std.mem.indexOfScalar(u8, boundary, ';')) |semicolon| {
        boundary = boundary[0..semicolon];
    }

    boundary = std.mem.trim(u8, boundary, " \t\r\n\"");

    return if (boundary.len == 0) null else boundary;
}

/// Answer an error and return false when the handler did not get the whole
/// body. Saving a fragment as a finished file is the failure this guards.
fn requireWholeBody(req: *zix.Http1.Request, res: *zix.Http1.Response) !bool {
    if (!req.bodyComplete()) {
        res.setStatus(.BAD_REQUEST);

        try res.sendJson("{\"error\":\"incomplete body: the client stopped sending\"}");
        return false;
    }

    if (req.bodyReceived() != req.body().len) {
        res.setStatus(.PAYLOAD_TOO_LARGE);

        try res.sendJson("{\"error\":\"body larger than max_recv_buf\"}");
        return false;
    }

    return true;
}

/// Answer the saved file as JSON.
fn sendSaved(
    res: *zix.Http1.Response,
    name: []const u8,
    size: usize,
    saved_path: []const u8,
) !void {
    var buf: [512]u8 = undefined;
    const json = try std.fmt.bufPrint(
        &buf,
        "{{\"file\":{{\"name\":\"{s}\",\"size\":{d},\"path\":\"{s}\"}}}}",
        .{
            name,
            size,
            saved_path,
        },
    );

    try res.sendJson(json);
}

// --------------------------------------------------------- //

// Saves the raw body as UPLOAD_DIR/<name>.
// curl usage:
// curl -X POST "http://localhost:9024/upload?name=file.txt" --data-binary @/path/to/file.txt
fn uploadHandler(
    req: *zix.Http1.Request,
    res: *zix.Http1.Response,
    ctx: *zix.Http1.Context,
) !void {
    if (req.method() != .POST) {
        res.setStatus(.METHOD_NOT_ALLOWED);

        try res.sendJson("{\"error\":\"method not allowed\"}");
        return;
    }

    if (!try requireWholeBody(req, res)) return;

    const name = req.queryParam("name") orelse {
        res.setStatus(.BAD_REQUEST);

        try res.sendJson("{\"error\":\"missing query param: name\"}");
        return;
    };

    if (!isSafeFilename(name)) {
        res.setStatus(.BAD_REQUEST);

        try res.sendJson("{\"error\":\"invalid filename\"}");
        return;
    }

    const body = req.body();

    // ctx.allocator is the per-request scratch, reset by the engine after the
    // request, so the returned path needs no manual free.
    const saved_path = zix.utils.File.save(
        ctx.io,
        ctx.allocator,
        UPLOAD_DIR,
        name,
        body,
    ) catch {
        res.setStatus(.INTERNAL_SERVER_ERROR);

        try res.sendJson("{\"error\":\"failed to save file\"}");
        return;
    };

    try sendSaved(res, name, body.len, saved_path);
}

// Saves the "file" field of a multipart/form-data body as UPLOAD_DIR/<filename>.
// curl usage:
// curl -X POST "http://localhost:9024/upload-multipart" -F "file=@/path/to/file.txt"
fn uploadMultipartHandler(
    req: *zix.Http1.Request,
    res: *zix.Http1.Response,
    ctx: *zix.Http1.Context,
) !void {
    if (req.method() != .POST) {
        res.setStatus(.METHOD_NOT_ALLOWED);

        try res.sendJson("{\"error\":\"method not allowed\"}");
        return;
    }

    if (!try requireWholeBody(req, res)) return;

    const content_type = req.header("content-type") orelse {
        res.setStatus(.BAD_REQUEST);

        try res.sendJson("{\"error\":\"missing content-type\"}");
        return;
    };

    const boundary = boundaryFromContentType(content_type) orelse {
        res.setStatus(.BAD_REQUEST);

        try res.sendJson("{\"error\":\"missing boundary in content-type\"}");
        return;
    };

    var parser = zix.Http1.Multipart.init(ctx.allocator, boundary);
    defer parser.deinit();

    parser.parse(req.body()) catch {
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
    if (!isSafeFilename(filename)) {
        res.setStatus(.BAD_REQUEST);

        try res.sendJson("{\"error\":\"invalid filename\"}");
        return;
    }

    const saved_path = zix.utils.File.save(
        ctx.io,
        ctx.allocator,
        UPLOAD_DIR,
        filename,
        file_field.data,
    ) catch {
        res.setStatus(.INTERNAL_SERVER_ERROR);

        try res.sendJson("{\"error\":\"failed to save file\"}");
        return;
    };

    try sendSaved(res, filename, file_field.data.len, saved_path);
}

// --------------------------------------------------------- //

const Routes = zix.Http1.Router(&[_]zix.Http1.Route{
    .{
        .path = "/upload",
        .handler = uploadHandler,
    },
    .{
        .path = "/upload-multipart",
        .handler = uploadMultipartHandler,
    },
});

pub fn main(init: std.process.Init) !void {
    var server = zix.Http1.Server.init(Routes.dispatch, .{
        .io = init.io,
        .ip = IP,
        .port = PORT,
        .workers = WORKERS,
        .kernel_backlog = KERNEL_BACKLOG,
        .dispatch_model = DISPATCH_MODEL,
        .max_request_body = MAX_REQUEST_BODY,
        .max_recv_buf = MAX_RECV_BUF,
    });
    defer server.deinit();

    try server.run();
}

