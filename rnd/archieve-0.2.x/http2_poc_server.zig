//! HTTP/2 PoC server — h2c direct (PRI preface), ASYNC model.
//!
//! Run:
//!   zig run rnd/http2_poc_server.zig
//!   zig run rnd/http2_poc_server.zig -- --ip 0.0.0.0 --port 8082
//!
//! Test with curl (requires curl built with nghttp2):
//!   curl --http2-prior-knowledge http://127.0.0.1:8082/
//!   curl --http2-prior-knowledge -d "hello" http://127.0.0.1:8082/echo
//!   curl --http2-prior-knowledge http://127.0.0.1:8082/no-such-path

const std = @import("std");
const core = @import("http2_poc_core.zig");

const DEFAULT_IP: []const u8 = "127.0.0.1";
const DEFAULT_PORT: u16 = 8082;

// ------------------------------------------------------------------ //
// Route handler                                                       //
// ------------------------------------------------------------------ //

fn handler(
    method: []const u8,
    path: []const u8,
    headers: []const core.Header,
    body: []const u8,
    fd: std.posix.fd_t,
    sid: u31,
) void {
    _ = headers;
    _ = method;

    if (std.mem.eql(u8, path, "/")) {
        core.sendResponse(fd, sid, 200, "text/plain", "Hello, World!") catch {};
    } else if (std.mem.eql(u8, path, "/echo")) {
        core.sendResponse(fd, sid, 200, "text/plain", body) catch {};
    } else {
        core.sendResponse(fd, sid, 404, "text/plain", "Not Found\n") catch {};
    }
}

// ------------------------------------------------------------------ //
// ASYNC dispatch                                                      //
// ------------------------------------------------------------------ //

const ConnArgs = struct { stream: std.Io.net.Stream, io: std.Io };

fn handleConnection(args: ConnArgs) void {
    core.serveConn(args.stream, args.io, handler);
}

// ------------------------------------------------------------------ //
// main                                                                //
// ------------------------------------------------------------------ //

pub fn main(process: std.process.Init) !void {
    var ip: []const u8 = DEFAULT_IP;
    var port: u16 = DEFAULT_PORT;

    var args = std.process.Args.Iterator.init(process.minimal.args);
    _ = args.next();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--ip")) {
            ip = args.next() orelse ip;
        } else if (std.mem.eql(u8, arg, "--port")) {
            const s = args.next() orelse continue;
            port = std.fmt.parseInt(u16, s, 10) catch port;
        }
    }

    const io = process.io;

    const addr = try std.Io.net.IpAddress.resolve(io, ip, port);
    var srv = try addr.listen(io, .{
        .mode = .stream,
        .kernel_backlog = 1024,
        .reuse_address = true,
    });
    defer srv.deinit(io);

    std.debug.print("http2 server (h2c, async): {s}:{d}\n", .{ ip, port });

    while (true) {
        const stream = srv.accept(io) catch |e| {
            if (e != error.ConnectionAborted) std.debug.print("h2: accept error: {}\n", .{e});
            continue;
        };
        _ = io.async(handleConnection, .{ConnArgs{ .stream = stream, .io = io }});
    }
}
