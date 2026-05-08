const std = @import("std");
const zix = @import("zix");

const IP: []const u8 = "127.0.0.1";
const PORT: u16 = 9008;
const MAX_KERNEL_BACKLOG: usize = 1024 * 4;
const MAX_CLIENT_REQUEST: usize = 1024 * 8; // 8 KB read buffer per connection
const MAX_ALLOCATOR_SIZE: usize = 1024 * 4;
const MAX_CLIENT_RESPONSE: usize = 1024 * 4;
const WORKERS: usize = 0; // 0 = auto (2 accept threads)
const POOL_SIZE: usize = 0; // 0 = auto (max(10, cpu_count * 2) pool threads)

// Global room registry — lives for the process lifetime.
// join() and leave() are called by each WebSocket handler task.
var ws_rooms: zix.Http.WebSocket.RoomMap = undefined;

// --------------------------------------------------------- //

// GET /ws/:room-id?name=alice
// WebSocket upgrade handler.
//
// Query params MUST be read before zix.Http.WebSocket.upgrade() is called.
// After the 101 handshake the HTTP request context is gone — the connection
// becomes a raw WebSocket stream. Capture anything you need from the request
// (path params, query params, headers) before calling upgrade().
//
// After a successful handshake the connection enters a broadcast loop:
//   text/binary frames → broadcast "[name] message" to everyone in the room
//   ping             → pong
//   close            → echo close frame, end loop
//
// Connect (wscat / websocat):
//   wscat    -c "ws://localhost:9008/ws/lobby?name=alice"
//   websocat    "ws://localhost:9008/ws/lobby?name=alice"
//
// If ?name is omitted the display name defaults to "anonymous":
//   wscat    -c "ws://localhost:9008/ws/lobby"
//
// After connecting, any message you type is broadcast to every other client
// in the same room, prefixed with the sender's display name.
pub fn wsHandler(req: *zix.Http.Request, res: *zix.Http.Response, ctx: *zix.Http.Context) !void {
    if (req.method() != .GET) {
        res.setStatus(.METHOD_NOT_ALLOWED);
        try res.sendJson("{\"error\":\"method not allowed\"}");
        return;
    }

    const room_id = req.pathParam("room-id") orelse {
        res.setStatus(.BAD_REQUEST);
        try res.sendJson("{\"error\":\"missing room-id\"}");
        return;
    };

    // Read query params NOW — they are unavailable after upgrade().
    const display_name = req.queryParam("name") orelse "anonymous";

    // Validate WebSocket upgrade headers
    var ws_key: ?[]const u8 = null;
    var is_upgrade = false;
    var it = req.inner.iterateHeaders();
    while (it.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "upgrade")) {
            is_upgrade = std.ascii.eqlIgnoreCase(h.value, "websocket");
        } else if (std.ascii.eqlIgnoreCase(h.name, "sec-websocket-key")) {
            ws_key = h.value;
        }
    }

    if (!is_upgrade or ws_key == null) {
        res.setStatus(.BAD_REQUEST);
        try res.sendJson("{\"error\":\"not a websocket upgrade request\"}");
        return;
    }

    // Compute and send 101 handshake
    var accept_buf: [64]u8 = undefined;
    const accept = zix.Http.WebSocket.acceptKey(ws_key.?, &accept_buf) catch {
        res.setStatus(.INTERNAL_SERVER_ERROR);
        try res.sendJson("{\"error\":\"handshake failed\"}");
        return;
    };

    zix.Http.WebSocket.upgrade(ctx.stream, ctx.io, accept) catch return;

    // Register this connection in the room
    const conn = try std.heap.smp_allocator.create(zix.Http.WebSocket.Conn);
    conn.* = .{ .stream = ctx.stream, .io = ctx.io };
    defer std.heap.smp_allocator.destroy(conn);

    ws_rooms.join(room_id, conn, ctx.io);
    defer ws_rooms.leave(room_id, conn, ctx.io);

    // WebSocket frame loop
    var frame_buf: [MAX_CLIENT_REQUEST]u8 = undefined;
    var buf_used: usize = 0;
    var clean_close = false; // set to true only when the peer sends a .close frame

    outer: while (true) {
        // Read one syscall's worth of bytes into the frame buffer.
        // std.Io.Writer.fixed + reader.stream() does exactly ONE readv and returns
        // whatever arrived — unlike readSliceShort which loops until the buffer is
        // full (blocks until 8 KB accumulate or the connection closes).
        var tw = std.Io.Writer.fixed(frame_buf[buf_used..]);
        const n = req.reader.stream(&tw, .unlimited) catch break;
        if (n == 0) break;
        buf_used += n;

        // Parse and dispatch all complete frames in the accumulated buffer
        var offset: usize = 0;
        while (offset < buf_used) {
            var payload_buf: [4096]u8 = undefined;
            const result = zix.Http.WebSocket.parseFrame(frame_buf[offset..buf_used], &payload_buf) orelse break;

            switch (result.frame.opcode) {
                .text, .binary => {
                    // Prefix the payload with the sender's display name before broadcasting.
                    var msg_buf: [4096 + 64]u8 = undefined;
                    const msg = std.fmt.bufPrint(
                        &msg_buf,
                        "[{s}] {s}",
                        .{ display_name, result.frame.payload },
                    ) catch result.frame.payload;
                    ws_rooms.broadcast(room_id, msg, ctx.io);
                },
                .ping => {
                    var pong_frame: [128]u8 = undefined;
                    const plen = zix.Http.WebSocket.buildFrame(&pong_frame, .pong, result.frame.payload);
                    var wb: [128]u8 = undefined;
                    var w = ctx.stream.writer(ctx.io, &wb);
                    w.interface.writeAll(pong_frame[0..plen]) catch break :outer;
                    w.interface.flush() catch break :outer;
                },
                .close => {
                    // Echo close frame back then exit — RFC 6455 5.5.1
                    var close_frame: [16]u8 = undefined;
                    const clen = zix.Http.WebSocket.buildFrame(&close_frame, .close, &.{});
                    var wb: [16]u8 = undefined;
                    var w = ctx.stream.writer(ctx.io, &wb);
                    w.interface.writeAll(close_frame[0..clen]) catch {};
                    w.interface.flush() catch {};
                    clean_close = true;
                    break :outer;
                },
                else => {},
            }
            offset += result.consumed;
        }

        // Compact the buffer — discard processed bytes, keep remainder
        if (offset > 0 and offset < buf_used) {
            @memmove(frame_buf[0 .. buf_used - offset], frame_buf[offset..buf_used]);
            buf_used -= offset;
        } else if (offset >= buf_used) {
            buf_used = 0;
        }
    }

    // Peer dropped without a close frame (TCP EOF / RST / network error).
    // Send a close frame so the other side knows we're gone, then fall through
    // to defers.  Best-effort: ignore write failures on a dying connection.
    if (!clean_close) {
        var close_frame: [16]u8 = undefined;
        const clen = zix.Http.WebSocket.buildFrame(&close_frame, .close, &.{});
        var wb: [16]u8 = undefined;
        var w = ctx.stream.writer(ctx.io, &wb);
        w.interface.writeAll(close_frame[0..clen]) catch {};
        w.interface.flush() catch {};
    }
    // defers: ws_rooms.leave → smp_allocator.destroy(conn)
}

// --------------------------------------------------------- //

pub fn main(process: std.process.Init) !void {
    ws_rooms = zix.Http.WebSocket.RoomMap.init(std.heap.smp_allocator);
    defer ws_rooms.deinit();

    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();

    var server = try zix.Http.Server.init(4096, .{
        .io = process.io,
        .allocator = arena.allocator(),
        .ip = IP,
        .port = PORT,
        .max_kernel_backlog = MAX_KERNEL_BACKLOG,
        .max_client_request = MAX_CLIENT_REQUEST,
        .max_allocator_size = MAX_ALLOCATOR_SIZE,
        .max_client_response = MAX_CLIENT_RESPONSE,
        .workers = WORKERS,
        .pool_size = POOL_SIZE,
    });
    defer server.deinit();

    server.registerParamHandler("/ws/:room-id", wsHandler);

    try server.run();
}
