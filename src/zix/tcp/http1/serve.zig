//! ZIX Http1 serve
//!
//! ### file: src/zix/tcp/http1/serve.zig
//! 
//! ### author: Prana Ron
//! 
//! ---------------------------------------------------------
//! 
//! ### brief:
//! 
//! Keep-alive connection loop for a blocking descriptor.
//! 
//! ### note:
//! 
//! n/a
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
const builtin = @import("builtin");
const chunk = @import("chunk.zig");
const Context = @import("Context.zig");
const handler = @import("handler.zig");
const parser = @import("parser.zig");
const reader = @import("reader.zig");
const Request = @import("Request.zig");
const Response = @import("Response.zig");
const ServeOpts = @import("ServeOpts.zig");
const writer = @import("writer.zig");
const ws_pending = @import("websocket/pending.zig");
const ws_pump = @import("websocket/pump.zig");

// --------------------------------------------------------- //
// Private:

/// Staging for one blocking WebSocket pump pass, so a pipelined burst of
/// replies costs one write.
const WS_OUT_SIZE: usize = 4 * 1024;

/// This pool thread's receive and body buffers.
///
/// Note:
/// - io.async hands each connection to whichever pool thread is free, so a
///   thread keeps one pair and every connection it serves reuses them. That is
///   the same shape an .EPOLL or .URING worker already has, one body scratch
///   shared by every connection the worker owns, rather than a fresh reservation
///   per connection.
threadlocal var tl_recv_buf: []u8 = &.{};
threadlocal var tl_body_buf: []u8 = &.{};

/// The pair of buffers this pool thread serves connections with, allocated on
/// first use and grown only when a later connection asks for more.
///
/// Note:
/// - They live for the thread's lifetime rather than the connection's. That is
///   the trade the event-loop models already make, and it is what keeps a
///   request allocation-free.
/// - Resident is bounded by pool threads, not by connection count.
///
/// Param:
/// size - usize (bytes each buffer must hold, from config.max_recv_buf)
///
/// Return:
/// - the two buffers, each exactly size bytes
/// - null when the allocation failed, the caller drops the connection
fn threadConnBufs(size: usize) ?struct { recv: []u8, body: []u8 } {
    if (tl_recv_buf.len < size) {
        const grown = std.heap.smp_allocator.realloc(
            tl_recv_buf, size,
        ) catch |err| switch (err) {
            error.OutOfMemory => return null,
        };
        tl_recv_buf = grown;
    }

    if (tl_body_buf.len < size) {
        const grown = std.heap.smp_allocator.realloc(
            tl_body_buf, size,
        ) catch |err| switch (err) {
            error.OutOfMemory => return null,
        };
        tl_body_buf = grown;
    }

    return .{ .recv = tl_recv_buf[0..size], .body = tl_body_buf[0..size] };
}

/// This pool thread's WebSocket frame buffer and unmask scratch, apart from
/// the HTTP buffers so ws_recv_buf stays independent of max_recv_buf.
threadlocal var tl_ws_recv_buf: []u8 = &.{};
threadlocal var tl_ws_payload_buf: []u8 = &.{};

/// The pair of WebSocket buffers this pool thread serves frames with,
/// allocated on the first upgrade and grown only when a later one asks for
/// more.
///
/// Param:
/// size - usize (bytes each buffer must hold, from config.ws_recv_buf)
///
/// Return:
/// - the two buffers, each exactly size bytes
/// - null when the allocation failed, the caller drops the connection
fn threadWsBufs(size: usize) ?struct { recv: []u8, payload: []u8 } {
    if (tl_ws_recv_buf.len < size) {
        const grown = std.heap.smp_allocator.realloc(
            tl_ws_recv_buf, size,
        ) catch |err| switch (err) {
            error.OutOfMemory => return null,
        };
        tl_ws_recv_buf = grown;
    }

    if (tl_ws_payload_buf.len < size) {
        const grown = std.heap.smp_allocator.realloc(
            tl_ws_payload_buf, size,
        ) catch |err| switch (err) {
            error.OutOfMemory => return null,
        };
        tl_ws_payload_buf = grown;
    }

    return .{
        .recv = tl_ws_recv_buf[0..size],
        .payload = tl_ws_payload_buf[0..size],
    };
}

// --------------------------------------------------------- //
// Public:

/// Keep-alive connection loop. The caller owns closing the fd. Pass a raw fd
/// extracted from the accepted stream.
///
/// Param:
/// fd - std.posix.fd_t (the connection)
/// handler_fn - handler.HandlerFn (the route or top-level handler)
/// opts - ServeOpts (per-connection serve knobs)
/// io - std.Io (the worker io)
pub fn serveConn(
    fd: std.posix.fd_t,
    handler_fn: handler.HandlerFn,
    opts: ServeOpts,
    io: std.Io,
) void {
    if (opts.nodelay) {
        if (comptime builtin.target.os.tag != .windows) {
            // std.posix.TCP is void on the BSDs in Zig 0.16: TCP_NODELAY is 1 there.
            const nodelay: u32 =
                if (comptime std.posix.TCP != void) std.posix.TCP.NODELAY else 1;

            std.posix.setsockopt(
                fd,
                std.posix.IPPROTO.TCP,
                nodelay,
                std.mem.asBytes(&@as(c_int, 1)),
            ) catch |err| switch (err) {
                else => {},
            };
        }
    }

    // Per-connection scratch for the handler trio, reset before each request so
    // a long keep-alive connection never grows without bound.
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();

    // Both buffers are cut from config.max_recv_buf, the same knob the .EPOLL
    // and .URING connection slots use, so the body a handler is given has one
    // size across every dispatch model.
    const recv_size = if (opts.max_recv_buf == 0) ServeOpts.BUF_SIZE else opts.max_recv_buf;

    const bufs = threadConnBufs(recv_size) orelse return;
    const recv_buf = bufs.recv;
    const body_buf = bufs.body;

    var leftover: usize = 0;

    while (true) {
        const hdr = reader.recvHead(fd, recv_buf, leftover) catch |err| switch (err) {
            error.ZixHttp1_Reader_HeaderTooLarge => {
                writer.writeAllFD(
                    fd,
                    "HTTP/1.1 431 Request Header Fields Too Large\r\nContent-Length: 0\r\n\r\n",
                ) catch |write_err| switch (write_err) {
                    error.ZixHttp1_Writer_BrokenPipe,
                    error.ZixHttp1_Writer_HeadBuild,
                    => {},
                };

                return;
            },
            error.ZixHttp1_Reader_Closed,
            error.ZixHttp1_Reader_ReadFailed,
            error.ZixHttp1_Reader_SetBufFailed,
            => return,
        };

        const result = parser.parseHead(recv_buf[0..hdr.filled]) catch |err| switch (err) {
            error.ZixHttp1_Parser_IncompleteHeader,
            error.ZixHttp1_Parser_InvalidRequest,
            error.ZixHttp1_Parser_UnknownMethod,
            => {
                writer.writeAllFD(
                    fd, parser.parseErrorResponse(err),
                ) catch |write_err| switch (write_err) {
                    error.ZixHttp1_Writer_BrokenPipe,
                    error.ZixHttp1_Writer_HeadBuild,
                    => {},
                };

                return;
            },
        };
        const head = result.head;

        if (head.expect_continue and (head.content_length > 0 or head.chunked_request)) {
            writer.send100ContinueFD(fd) catch |err| switch (err) {
                error.ZixHttp1_Writer_BrokenPipe,
                error.ZixHttp1_Writer_HeadBuild,
                => return,
            };
        }

        var body_len: usize = 0;
        var received: u64 = 0;
        var drained_large = false;
        // Whether this request declared a body at all, and whether reading it
        // reached the end. A request with no body skips the handoff below
        // entirely, so the bodyless path pays one compare and no store.
        var has_body = false;
        var body_complete = true;
        var chunked_leftover: usize = 0;
        var chunked_leftover_off: usize = 0;
        if (head.chunked_request) {
            // The body reads into body_buf and is decoded over itself there.
            // recv_buf cannot be used as that scratch: head still points into
            // it, and the handler is about to be given those slices.
            const peeked = hdr.filled - hdr.body_offset;
            if (peeked > 0) @memcpy(body_buf[0..peeked], recv_buf[hdr.body_offset..hdr.filled]);

            const chunked = chunk.readChunkedBody(fd, body_buf, peeked);
            switch (chunked.stop) {
                .COMPLETE => {},
                .MALFORMED => {
                    // The rest of the body cannot be framed, so there is no way
                    // to find where the next request would start. Answer and
                    // close.
                    writer.writeAllFD(
                        fd,
                        "HTTP/1.1 400 Bad Request\r\n" ++
                        "Content-Length: 0\r\n" ++
                        "Connection: close\r\n\r\n",
                    ) catch |write_err| switch (write_err) {
                        error.ZixHttp1_Writer_BrokenPipe,
                        error.ZixHttp1_Writer_HeadBuild,
                        => {},
                    };

                    return;
                },
                .TOO_LARGE => {
                    writer.writeAllFD(
                        fd,
                        "HTTP/1.1 413 Payload Too Large\r\n" ++
                        "Content-Length: 0\r\n" ++
                        "Connection: close\r\n\r\n",
                    ) catch |write_err| switch (write_err) {
                        error.ZixHttp1_Writer_BrokenPipe,
                        error.ZixHttp1_Writer_HeadBuild,
                        => {},
                    };

                    return;
                },
                .NEED_MORE => return,
            }

            has_body = true;
            body_len = chunked.len;
            received = chunked.received;
            chunked_leftover_off = chunked.leftover_off;
            chunked_leftover = chunked.leftover;
        } else if (head.content_length > 0) {
            // Refused before a byte of it is read or discarded, so a declared
            // length cannot make this thread consume an arbitrary body.
            if (opts.max_request_body != 0 and head.content_length > opts.max_request_body) {
                writer.writeAllFD(
                    fd,
                    "HTTP/1.1 413 Payload Too Large\r\n" ++
                    "Content-Length: 0\r\n" ++
                    "Connection: close\r\n\r\n",
                ) catch |write_err| switch (write_err) {
                    error.ZixHttp1_Writer_BrokenPipe,
                    error.ZixHttp1_Writer_HeadBuild,
                    => {},
                };

                return;
            }

            has_body = true;

            const content_length: usize = @intCast(head.content_length);
            const to_read: usize = @min(content_length, body_buf.len);
            const peeked = hdr.filled - hdr.body_offset;
            const from_peek = @min(peeked, to_read);
            if (from_peek > 0) {
                @memcpy(body_buf[0..from_peek], recv_buf[hdr.body_offset..][0..from_peek]);
            }
            body_len = from_peek;
            while (body_len < to_read) {
                const n = reader.readOnceFD(
                    fd, body_buf[body_len..to_read],
                ) catch |err| switch (err) {
                    else => break,
                };
                if (n == 0) break;
                body_len += n;
            }

            // Body bytes already off the socket: the ones that arrived with the
            // head, plus the ones the fill loop pulled. Counting only the
            // head-side bytes here would make the drain below ask for the fill
            // loop's bytes a second time, taking them from the next request on
            // the connection.
            received = @min(peeked, content_length) + (body_len - from_peek);

            // Body larger than the handler buffer: consume the rest off the
            // socket so the connection stays usable for keep-alive (the leftover
            // would otherwise be misparsed as the next request). drainBody never
            // touches body_buf, so the slice handed to the handler stays the
            // start of the request instead of the tail of the drain. A wider
            // SO_RCVBUF (opts.large_body_recv_buf) speeds this on uploads.
            if (received < content_length) {
                reader.setRecvBuf(fd, opts.large_body_recv_buf) catch |err| switch (err) {
                    else => {},
                };

                received += reader.drainBody(fd, content_length - received);
                drained_large = true;
            }

            // A peer that stopped early leaves the drain short of the declared
            // length. The handler still runs, so it needs a way to tell that
            // upload apart from one that finished.
            body_complete = received >= content_length;
        }

        handler.setTimeout(io, opts.handler_timeout_ms);
        _ = arena.reset(.retain_capacity);

        // The delivered slice is capped by body_buf, the count is everything the
        // socket gave up, so a handler comparing the two can tell a truncated
        // body from a complete one.
        if (has_body) {
            handler.tl_body_info = .{
                .received = received,
                .complete = body_complete,
            };
        }
        handler.invokeHandler(
            handler_fn, &head, body_buf[0..body_len], fd, io, arena.allocator(),
        );

        // A handler that called WebSocket.serve owns the connection from here:
        // the frame loop runs until the peer leaves, then the connection ends.
        if (ws_pending.take()) |pending| {
            const ws_size =
                if (opts.ws_recv_buf == 0) ServeOpts.WS_RECV_BUF_DEFAULT else opts.ws_recv_buf;
            const ws_bufs = threadWsBufs(ws_size) orelse return;
            var ws_out_buf: [WS_OUT_SIZE]u8 = undefined;

            ws_pump.serveBlocking(
                pending.fd,
                pending.on_frame,
                ws_bufs.recv,
                ws_bufs.payload,
                &ws_out_buf,
            );

            return;
        }

        if (!head.keep_alive) return;

        if (head.chunked_request) {
            // Bytes the chunked read pulled past the end of the body: a
            // pipelined request, carried to the front of recv_buf for the next
            // pass. The handler has returned, so overwriting the head bytes is
            // safe now.
            leftover = chunked_leftover;
            if (leftover > 0) {
                @memcpy(recv_buf[0..leftover], body_buf[chunked_leftover_off..][0..leftover]);
            }
        } else if (drained_large) {
            // The whole body was consumed off the socket, and a large body has
            // no pipelined request after it, so nothing is left to carry.
            leftover = 0;
        } else {
            const body_consumed: usize = @intCast(
                @min(head.content_length, @as(u64, body_buf.len)),
            );
            const request_end = hdr.body_offset + body_consumed;
            if (hdr.filled > request_end) {
                leftover = hdr.filled - request_end;
                std.mem.copyForwards(
                    u8, recv_buf[0..leftover], recv_buf[request_end..hdr.filled],
                );
            } else {
                leftover = 0;
            }
        }
    }
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const pair = @import("../../utils/socket/pair.zig");
const websocket = @import("websocket.zig");

fn testWriteAll(fd: std.posix.fd_t, data: []const u8) !void {
    var written: usize = 0;
    while (written < data.len) {
        const rc = std.posix.system.write(fd, data[written..].ptr, data.len - written);
        switch (std.posix.errno(rc)) {
            .SUCCESS => {
                const n: usize = @intCast(rc);
                if (n == 0) return error.TestWriteClosed;
                written += n;
            },
            .INTR => continue,
            else => return error.TestWriteFailed,
        }
    }
}

fn okHandler(req: *Request, res: *Response, _: *Context) anyerror!void {
    _ = req;

    try res.send("ok");
}

fn testWsEcho(fd: std.posix.fd_t, opcode: u8, payload: []const u8) void {
    websocket.sendFD(fd, @enumFromInt(opcode), payload) catch |err| switch (err) {
        error.ZixHttp1_WebSocketSend_BrokenPipe,
        error.ZixHttp1_WebSocketSend_HeadBuild,
        => {},
    };
}

fn wsHandler(req: *Request, _: *Response, _: *Context) anyerror!void {
    try websocket.serve(req.fd, req.header("sec-websocket-key").?, testWsEcho);
}

fn testReadExact(fd: std.posix.fd_t, out: []u8) !void {
    var got: usize = 0;
    while (got < out.len) {
        const n = try reader.readOnceFD(fd, out[got..]);
        if (n == 0) return error.TestReadClosed;
        got += n;
    }
}

test "zix http1: serve, answers one request" {
    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    const head_module = @import("head.zig");
    head_module.setDateHeader(false);
    defer head_module.setDateHeader(true);

    try testWriteAll(fds[0], "GET / HTTP/1.1\r\nConnection: close\r\n\r\n");
    serveConn(fds[1], okHandler, .{ .max_recv_buf = ServeOpts.BUF_SIZE }, std.testing.io);

    var buf: [256]u8 = undefined;
    const n = try std.posix.read(fds[0], &buf);

    try std.testing.expectEqualStrings(
        "HTTP/1.1 200 Ok\r\nContent-Length: 2\r\n\r\nok",
        buf[0..n],
    );
}

test "zix http1: serve, answers 431 for an oversized head" {
    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    const filler: [100]u8 = @splat('a');

    try testWriteAll(fds[0], "GET / HTTP/1.1\r\nX-Fill: ");
    try testWriteAll(fds[0], &filler);
    try testWriteAll(fds[0], "\r\n");

    serveConn(fds[1], okHandler, .{ .max_recv_buf = 64 }, std.testing.io);

    var buf: [256]u8 = undefined;
    const n = try std.posix.read(fds[0], &buf);

    try std.testing.expectEqualStrings(
        "HTTP/1.1 431 Request Header Fields Too Large\r\nContent-Length: 0\r\n\r\n",
        buf[0..n],
    );
}

test "zix http1: serve, runs the WebSocket frame loop after serve" {
    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    const thread = try std.Thread.spawn(.{}, serveConn, .{
        fds[1],
        wsHandler,
        ServeOpts{ .max_recv_buf = ServeOpts.BUF_SIZE },
        std.testing.io,
    });

    try testWriteAll(
        fds[0],
        "GET /ws HTTP/1.1\r\n" ++
            "Upgrade: websocket\r\n" ++
            "Connection: Upgrade\r\n" ++
            "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n",
    );

    const expected_head =
        "HTTP/1.1 101 Switching Protocols\r\n" ++
        "Upgrade: websocket\r\n" ++
        "Connection: Upgrade\r\n" ++
        "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n\r\n";
    var head_buf: [expected_head.len]u8 = undefined;
    try testReadExact(fds[0], &head_buf);

    // Masked "Hello" from RFC 6455 section 5.7, then a masked empty close.
    const hello = [_]u8{ 0x81, 0x85, 0x37, 0xfa, 0x21, 0x3d, 0x7f, 0x9f, 0x4d, 0x51, 0x58 };
    try testWriteAll(fds[0], &hello);
    var echo: [7]u8 = undefined;
    try testReadExact(fds[0], &echo);

    try testWriteAll(fds[0], &[_]u8{ 0x88, 0x80, 1, 2, 3, 4 });
    var close: [2]u8 = undefined;
    try testReadExact(fds[0], &close);

    thread.join();

    try std.testing.expectEqualStrings(expected_head, &head_buf);
    try std.testing.expectEqualStrings("Hello", echo[2..]);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x88, 0 }, &close);
}

test "zix http1: serve, WebSocket frame past ws_recv_buf gets 1009" {
    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    const thread = try std.Thread.spawn(.{}, serveConn, .{
        fds[1],
        wsHandler,
        ServeOpts{
            .max_recv_buf = 64 * 1024,
            .ws_recv_buf = 4,
        },
        std.testing.io,
    });

    try testWriteAll(
        fds[0],
        "GET /ws HTTP/1.1\r\n" ++
            "Upgrade: websocket\r\n" ++
            "Connection: Upgrade\r\n" ++
            "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n",
    );

    var head_buf: [129]u8 = undefined;
    try testReadExact(fds[0], &head_buf);

    const hello = [_]u8{ 0x81, 0x85, 0x37, 0xfa, 0x21, 0x3d, 0x7f, 0x9f, 0x4d, 0x51, 0x58 };
    try testWriteAll(fds[0], &hello);

    var close: [4]u8 = undefined;
    try testReadExact(fds[0], &close);

    thread.join();

    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x88, 2, 0x03, 0xF1 }, &close);
}

