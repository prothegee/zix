//! HTTP/2 connection loop: h2c direct (PRI preface) and h2c upgrade (HTTP/1.1 Upgrade: h2c).

const std = @import("std");
const frame = @import("frame.zig");
const hpack = @import("hpack.zig");

/// Base64 decode scratch for the HTTP2-Settings header on an h2c upgrade.
const SETTINGS_DECODE_SCRATCH: usize = 256;

/// Request line and header read bound for an h2c upgrade (HeaderTooLarge over this).
const UPGRADE_HEAD_BUF: usize = 8192;

// --------------------------------------------------------- //

/// HTTP/2 handler function type. Called once per completed h2 stream.
///
/// Param:
/// method - []const u8 (HTTP method, e.g. "GET", "POST")
/// headers - []const hpack.Header (decoded request headers including pseudo-headers)
/// body - []const u8 (request body, empty for GET)
/// fd - std.posix.fd_t (connection fd for sending responses)
/// sid - u31 (HTTP/2 stream id)
pub const HandlerFn = *const fn (
    method: []const u8,
    headers: []const hpack.Header,
    body: []const u8,
    fd: std.posix.fd_t,
    sid: u31,
) void;

/// Route match strategy. EXACT matches the whole path, PREFIX matches a leading path segment
/// (longest registered prefix wins), mirroring the zix.Http1 router.
pub const RouteKind = enum(u8) { EXACT, PREFIX };

/// HTTP/2 route: path to handler mapping.
///
/// Param:
/// path - []const u8 (e.g. "/", "/json", "/static")
/// handler - HandlerFn
/// kind - RouteKind (EXACT by default, PREFIX for a path subtree)
pub const Route = struct {
    path: []const u8,
    handler: HandlerFn,
    kind: RouteKind = .EXACT,
};

/// Comptime path router. The query string is stripped before matching, so a route on "/json"
/// matches ":path" values like "/json/5?m=7". EXACT routes use a StaticStringMap (O(1) lookup),
/// PREFIX routes match the longest registered prefix on a path-segment boundary. Sends 404 when no
/// route matches. Mirrors the zix.Http1 router.
///
/// Return:
/// - type (zero-size, with a dispatch function)
pub fn Router(comptime routes: []const Route) type {
    const exact_count = blk: {
        var n: usize = 0;
        for (routes) |r| if (r.kind == .EXACT) {
            n += 1;
        };
        break :blk n;
    };
    const prefix_count = blk: {
        var n: usize = 0;
        for (routes) |r| if (r.kind == .PREFIX) {
            n += 1;
        };
        break :blk n;
    };

    const exact_pairs: [exact_count]struct { []const u8, HandlerFn } = blk: {
        var arr: [exact_count]struct { []const u8, HandlerFn } = undefined;
        var i: usize = 0;
        for (routes) |r| {
            if (r.kind == .EXACT) {
                arr[i] = .{ r.path, r.handler };
                i += 1;
            }
        }
        break :blk arr;
    };

    const prefix_routes: [prefix_count]Route = blk: {
        var arr: [prefix_count]Route = undefined;
        var i: usize = 0;
        for (routes) |r| {
            if (r.kind == .PREFIX) {
                arr[i] = r;
                i += 1;
            }
        }
        break :blk arr;
    };

    const exact_map = std.StaticStringMap(HandlerFn).initComptime(exact_pairs);

    return struct {
        /// Dispatch the request to the best matching route. The query string is stripped first, then
        /// EXACT is tried (O(1) hash lookup) before PREFIX (longest match wins).
        pub fn dispatch(
            method: []const u8,
            path: []const u8,
            headers: []const hpack.Header,
            body: []const u8,
            fd: std.posix.fd_t,
            sid: u31,
        ) void {
            const p = if (std.mem.indexOfScalar(u8, path, '?')) |q| path[0..q] else path;

            if (exact_map.get(p)) |handler| {
                handler(method, headers, body, fd, sid);
                return;
            }

            var best_len: usize = 0;
            var best_handler: ?HandlerFn = null;
            inline for (prefix_routes) |route| {
                if (std.mem.startsWith(u8, p, route.path)) {
                    const at_boundary = p.len == route.path.len or p[route.path.len] == '/';
                    if (at_boundary and route.path.len > best_len) {
                        best_len = route.path.len;
                        best_handler = route.handler;
                    }
                }
            }

            if (best_handler) |h| {
                h(method, headers, body, fd, sid);
                return;
            }

            frame.sendResponse(fd, sid, 404, "text/plain", "Not Found") catch {};
        }
    };
}

pub const ServeOpts = struct {
    /// Maximum concurrent streams per connection.
    max_streams: usize = 16,
    /// MAX_FRAME_SIZE sent in server SETTINGS.
    max_frame_size: u32 = frame.DEFAULT_MAX_FRAME_SIZE,
    /// HPACK scratch buffer size per connection (header string storage).
    max_header_scratch: usize = 4096,
    /// Maximum body buffer per stream in bytes.
    max_body: usize = 65536,
    /// Per-connection read buffer floor in bytes. The reader is sized to the larger of this and
    /// one max frame, so a larger floor cuts read() and compaction for big frames.
    conn_read_buf_min: usize = 32 * 1024,
    /// Initial capacity in bytes of the per-connection TLS pending-write buffer (it grows on demand).
    /// A larger initial avoids early reallocation under big responses on the TLS path.
    tls_write_buf_initial: usize = 16 * 1024,
};

// --------------------------------------------------------- //

const StreamState = enum { IDLE, OPEN, HALF_CLOSED_REMOTE, CLOSED };

const Stream = struct {
    id: u31,
    state: StreamState,
    headers: [frame.MAX_HEADERS]hpack.Header,
    header_count: usize,
    body: [65536]u8,
    body_len: usize,
    header_scratch: [4096]u8,
    end_headers: bool,
    end_stream: bool,
};

// --------------------------------------------------------- //

/// Serve one h2c connection. Takes raw fd extracted by the server dispatch layer.
/// Caller owns the fd and must close it after this exits.
pub fn serveConn(comptime routes: []const Route, fd: std.posix.fd_t, opts: ServeOpts) void {
    if (comptime @import("builtin").target.os.tag != .windows) {
        std.posix.setsockopt(
            fd,
            std.posix.IPPROTO.TCP,
            std.posix.TCP.NODELAY,
            std.mem.asBytes(&@as(c_int, 1)),
        ) catch {};
    }
    serveConnInner(routes, fd, opts) catch {};
}

fn serveConnInner(comptime routes: []const Route, fd: std.posix.fd_t, opts: ServeOpts) !void {
    var peek: [3]u8 = undefined;
    try frame.recvExact(fd, &peek);

    if (std.mem.eql(u8, &peek, "PRI")) {
        var rest: [21]u8 = undefined;
        try frame.recvExact(fd, &rest);
        var preface: [24]u8 = undefined;
        @memcpy(preface[0..3], &peek);
        @memcpy(preface[3..], &rest);
        if (!std.mem.eql(u8, &preface, frame.PREFACE)) {
            frame.sendGoaway(fd, 0, frame.ERR_PROTOCOL_ERROR) catch {};
            return error.BadPreface;
        }
        try frame.sendSettings(fd, &.{
            .{ frame.SETTINGS_MAX_CONCURRENT_STREAMS, @as(u32, @intCast(opts.max_streams)) },
            .{ frame.SETTINGS_INITIAL_WINDOW_SIZE, 65535 },
            .{ frame.SETTINGS_MAX_FRAME_SIZE, opts.max_frame_size },
            .{ frame.SETTINGS_ENABLE_PUSH, 0 },
        });
        var hpack_dec = hpack.HpackDecoder.init();
        try serveH2cLoop(routes, fd, &hpack_dec, opts, 0);
    } else {
        try serveH2cUpgrade(routes, fd, opts, &peek);
    }
}

fn getHttp1Header(buf: []const u8, name: []const u8) ?[]const u8 {
    const first_crlf = std.mem.indexOf(u8, buf, "\r\n") orelse return null;
    var pos = first_crlf + 2;
    while (pos < buf.len) {
        const line_end = std.mem.indexOfPos(u8, buf, pos, "\r\n") orelse break;
        const line = buf[pos..line_end];
        if (line.len == 0) break;
        if (std.mem.indexOfScalar(u8, line, ':')) |colon| {
            if (std.ascii.eqlIgnoreCase(line[0..colon], name)) {
                var val_start: usize = colon + 1;
                while (val_start < line.len and line[val_start] == ' ') val_start += 1;
                return line[val_start..];
            }
        }
        pos = line_end + 2;
    }
    return null;
}

fn serveH2cUpgrade(comptime routes: []const Route, fd: std.posix.fd_t, opts: ServeOpts, prefix: *const [3]u8) !void {
    var head_buf: [UPGRADE_HEAD_BUF]u8 = undefined;
    var filled: usize = 3;
    @memcpy(head_buf[0..3], prefix);
    while (std.mem.indexOf(u8, head_buf[0..filled], "\r\n\r\n") == null) {
        if (filled >= head_buf.len) return error.HeaderTooLarge;
        const n = std.posix.read(fd, head_buf[filled..]) catch return error.Closed;
        if (n == 0) return error.Closed;
        filled += n;
    }
    const hdr_end = std.mem.indexOf(u8, head_buf[0..filled], "\r\n\r\n").? + 4;

    const upgrade = getHttp1Header(head_buf[0..hdr_end], "upgrade") orelse {
        frame.fdWriteAll(fd, "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n") catch {};
        return error.BadRequest;
    };
    if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, upgrade, " "), "h2c")) {
        frame.fdWriteAll(fd, "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n") catch {};
        return error.BadRequest;
    }

    var method: []const u8 = "GET";
    var path: []const u8 = "/";
    if (std.mem.indexOfScalar(u8, head_buf[0..hdr_end], ' ')) |sp1| {
        method = head_buf[0..sp1];
        const after = head_buf[sp1 + 1 .. hdr_end];
        if (std.mem.indexOfScalar(u8, after, ' ')) |sp2| path = after[0..sp2];
    }

    try frame.fdWriteAll(
        fd,
        "HTTP/1.1 101 Switching Protocols\r\n" ++
            "Connection: Upgrade\r\nUpgrade: h2c\r\n\r\n",
    );

    var preface: [24]u8 = undefined;
    try frame.recvExact(fd, &preface);
    if (!std.mem.eql(u8, &preface, frame.PREFACE)) {
        frame.sendGoaway(fd, 0, frame.ERR_PROTOCOL_ERROR) catch {};
        return error.BadPreface;
    }

    var hpack_dec = hpack.HpackDecoder.init();
    if (getHttp1Header(head_buf[0..hdr_end], "http2-settings")) |b64| {
        const trimmed = std.mem.trim(u8, b64, " ");
        var decoded: [SETTINGS_DECODE_SCRATCH]u8 = undefined;
        const dlen = std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(trimmed) catch 0;
        if (dlen > 0 and dlen <= decoded.len) {
            std.base64.url_safe_no_pad.Decoder.decode(decoded[0..dlen], trimmed) catch {};
            var i: usize = 0;
            while (i + 6 <= dlen) : (i += 6) {
                const id: u16 = (@as(u16, decoded[i]) << 8) | decoded[i + 1];
                const val: u32 = (@as(u32, decoded[i + 2]) << 24) | (@as(u32, decoded[i + 3]) << 16) |
                    (@as(u32, decoded[i + 4]) << 8) | decoded[i + 5];
                if (id == frame.SETTINGS_HEADER_TABLE_SIZE) {
                    hpack_dec.max_size = val;
                    hpack_dec.evictTo(val);
                }
            }
        }
    }

    try frame.sendSettings(fd, &.{
        .{ frame.SETTINGS_MAX_CONCURRENT_STREAMS, @as(u32, @intCast(opts.max_streams)) },
        .{ frame.SETTINGS_INITIAL_WINDOW_SIZE, 65535 },
        .{ frame.SETTINGS_MAX_FRAME_SIZE, opts.max_frame_size },
        .{ frame.SETTINGS_ENABLE_PUSH, 0 },
    });

    var s1_hdrs = [3]hpack.Header{
        .{ .name = ":method", .value = method },
        .{ .name = ":path", .value = path },
        .{ .name = ":scheme", .value = "http" },
    };
    Router(routes).dispatch(method, path, &s1_hdrs, &.{}, fd, 1);

    try serveH2cLoop(routes, fd, &hpack_dec, opts, 1);
}

fn serveH2cLoop(
    comptime routes: []const Route,
    fd: std.posix.fd_t,
    hpack_dec: *hpack.HpackDecoder,
    opts: ServeOpts,
    initial_last_stream: u31,
) !void {
    const max_payload = opts.max_frame_size + frame.FRAME_PAYLOAD_SLACK;
    const payload_buf = try std.heap.smp_allocator.alloc(u8, max_payload);
    defer std.heap.smp_allocator.free(payload_buf);

    const streams = try std.heap.smp_allocator.alloc(Stream, opts.max_streams);
    defer std.heap.smp_allocator.free(streams);
    const stream_slots = try std.heap.smp_allocator.alloc(bool, opts.max_streams);
    defer std.heap.smp_allocator.free(stream_slots);
    @memset(stream_slots, false);

    var last_stream_id: u31 = initial_last_stream;

    while (true) {
        const fh = try frame.readFrameHeader(fd);

        if (fh.length > max_payload) {
            frame.sendGoaway(fd, last_stream_id, frame.ERR_FRAME_SIZE_ERROR) catch {};
            return error.FrameTooLarge;
        }

        const payload = payload_buf[0..fh.length];
        if (fh.length > 0) try frame.recvExact(fd, payload);

        switch (fh.frame_type) {
            frame.FRAME_TYPE_SETTINGS => {
                if ((fh.flags & frame.FLAG_ACK) != 0) continue;
                var i: usize = 0;
                while (i + 6 <= payload.len) : (i += 6) {
                    const id: u16 = (@as(u16, payload[i]) << 8) | payload[i + 1];
                    const val: u32 = (@as(u32, payload[i + 2]) << 24) | (@as(u32, payload[i + 3]) << 16) |
                        (@as(u32, payload[i + 4]) << 8) | payload[i + 5];
                    if (id == frame.SETTINGS_HEADER_TABLE_SIZE) {
                        hpack_dec.max_size = val;
                        hpack_dec.evictTo(val);
                    }
                }
                try frame.sendSettingsAck(fd);
                try frame.sendWindowUpdate(fd, 0, frame.DEFAULT_WINDOW_SIZE);
            },

            frame.FRAME_TYPE_WINDOW_UPDATE => {},

            frame.FRAME_TYPE_PING => {
                if ((fh.flags & frame.FLAG_ACK) != 0) continue;
                if (payload.len != 8) {
                    frame.sendGoaway(fd, last_stream_id, frame.ERR_FRAME_SIZE_ERROR) catch {};
                    return error.ProtocolError;
                }
                var p8: [8]u8 = undefined;
                @memcpy(&p8, payload[0..8]);
                try frame.sendPingAck(fd, p8);
            },

            frame.FRAME_TYPE_HEADERS => {
                const sid = fh.stream_id;
                if (sid == 0) {
                    frame.sendGoaway(fd, last_stream_id, frame.ERR_PROTOCOL_ERROR) catch {};
                    return error.ProtocolError;
                }
                if (sid <= last_stream_id and sid % 2 == 1) {
                    frame.sendRstStream(fd, sid, frame.ERR_STREAM_CLOSED) catch {};
                    continue;
                }
                last_stream_id = @max(last_stream_id, sid);

                const slot = slotFor(sid, streams, stream_slots) orelse {
                    frame.sendRstStream(fd, sid, frame.ERR_REFUSED_STREAM) catch {};
                    continue;
                };
                const s = &streams[slot];
                s.* = std.mem.zeroes(Stream);
                s.id = sid;
                s.state = .OPEN;

                var block = payload;
                var offset: usize = 0;
                var pad_len: usize = 0;
                if ((fh.flags & frame.FLAG_PADDED) != 0 and block.len > 0) {
                    pad_len = block[0];
                    offset = 1;
                }
                if ((fh.flags & frame.FLAG_PRIORITY) != 0 and offset + 5 <= block.len) {
                    offset += 5;
                }
                if (pad_len + offset > block.len) {
                    frame.sendGoaway(fd, last_stream_id, frame.ERR_PROTOCOL_ERROR) catch {};
                    return error.ProtocolError;
                }
                block = block[offset .. block.len - pad_len];

                s.header_count = hpack_dec.decode(block, &s.headers, &s.header_scratch) catch {
                    frame.sendRstStream(fd, sid, frame.ERR_COMPRESSION_ERROR) catch {};
                    stream_slots[slot] = false;
                    continue;
                };
                s.end_headers = (fh.flags & frame.FLAG_END_HEADERS) != 0;
                s.end_stream = (fh.flags & frame.FLAG_END_STREAM) != 0;

                if (s.end_headers and s.end_stream) {
                    dispatchStream(routes, s, fd);
                    stream_slots[slot] = false;
                }
            },

            frame.FRAME_TYPE_CONTINUATION => {
                const sid = fh.stream_id;
                const slot = findSlot(sid, streams, stream_slots) orelse {
                    frame.sendGoaway(fd, last_stream_id, frame.ERR_PROTOCOL_ERROR) catch {};
                    return error.ProtocolError;
                };
                const s = &streams[slot];
                const count = hpack_dec.decode(payload, s.headers[s.header_count..], &s.header_scratch) catch {
                    frame.sendRstStream(fd, sid, frame.ERR_COMPRESSION_ERROR) catch {};
                    stream_slots[slot] = false;
                    continue;
                };
                s.header_count += count;
                s.end_headers = (fh.flags & frame.FLAG_END_HEADERS) != 0;
                if (s.end_headers and s.end_stream) {
                    dispatchStream(routes, s, fd);
                    stream_slots[slot] = false;
                }
            },

            frame.FRAME_TYPE_DATA => {
                const sid = fh.stream_id;
                if (sid == 0) {
                    frame.sendGoaway(fd, last_stream_id, frame.ERR_PROTOCOL_ERROR) catch {};
                    return error.ProtocolError;
                }
                const slot = findSlot(sid, streams, stream_slots) orelse {
                    frame.sendRstStream(fd, sid, frame.ERR_STREAM_CLOSED) catch {};
                    continue;
                };
                const s = &streams[slot];

                var data = payload;
                var pad_len: usize = 0;
                if ((fh.flags & frame.FLAG_PADDED) != 0 and data.len > 0) {
                    pad_len = data[0];
                    data = data[1..];
                }
                if (pad_len > data.len) {
                    frame.sendGoaway(fd, last_stream_id, frame.ERR_PROTOCOL_ERROR) catch {};
                    return error.ProtocolError;
                }
                data = data[0 .. data.len - pad_len];

                if (data.len > 0) {
                    frame.sendWindowUpdate(fd, 0, @intCast(data.len)) catch {};
                    frame.sendWindowUpdate(fd, sid, @intCast(data.len)) catch {};
                }

                const to_copy = @min(data.len, s.body.len - s.body_len);
                @memcpy(s.body[s.body_len..][0..to_copy], data[0..to_copy]);
                s.body_len += to_copy;

                s.end_stream = (fh.flags & frame.FLAG_END_STREAM) != 0;
                if (s.end_stream) {
                    dispatchStream(routes, s, fd);
                    stream_slots[slot] = false;
                }
            },

            frame.FRAME_TYPE_RST_STREAM => {
                const sid = fh.stream_id;
                if (findSlot(sid, streams, stream_slots)) |slot| {
                    stream_slots[slot] = false;
                }
            },

            frame.FRAME_TYPE_GOAWAY => return,

            frame.FRAME_TYPE_PRIORITY => {},

            else => {},
        }
    }
}

fn slotFor(sid: u31, streams: []Stream, used: []bool) ?usize {
    for (used, 0..) |u, i| {
        if (!u) {
            used[i] = true;
            streams[i].id = sid;
            return i;
        }
    }
    return null;
}

fn findSlot(sid: u31, streams: []Stream, used: []bool) ?usize {
    for (used, 0..) |u, i| {
        if (u and streams[i].id == sid) return i;
    }
    return null;
}

fn dispatchStream(comptime routes: []const Route, s: *Stream, fd: std.posix.fd_t) void {
    var method: []const u8 = "GET";
    var path: []const u8 = "/";
    for (s.headers[0..s.header_count]) |h| {
        // The two pseudo-headers have distinct lengths (":path" 5, ":method" 7),
        // so dispatch on length first and do at most one compare per header.
        switch (h.name.len) {
            5 => if (std.mem.eql(u8, h.name, ":path")) {
                path = h.value;
            },
            7 => if (std.mem.eql(u8, h.name, ":method")) {
                method = h.value;
            },
            else => {},
        }
    }
    Router(routes).dispatch(method, path, s.headers[0..s.header_count], s.body[0..s.body_len], fd, s.id);
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //

test "zix test: ServeOpts defaults" {
    const opts = ServeOpts{};
    try std.testing.expectEqual(@as(usize, 16), opts.max_streams);
    try std.testing.expectEqual(frame.DEFAULT_MAX_FRAME_SIZE, opts.max_frame_size);
}

test "zix test: HandlerFn is a function pointer type" {
    const h: HandlerFn = struct {
        fn f(
            method: []const u8,
            headers: []const hpack.Header,
            body: []const u8,
            fd: std.posix.fd_t,
            sid: u31,
        ) void {
            _ = method;
            _ = headers;
            _ = body;
            _ = fd;
            _ = sid;
        }
    }.f;
    _ = h;
}

// Router test scaffolding: each handler records which route fired so a dispatch can be asserted
// without inspecting the on-wire frames.
var tl_router_hit: u8 = 0;

fn routeHandler(comptime id: u8) HandlerFn {
    return struct {
        fn f(_: []const u8, _: []const hpack.Header, _: []const u8, _: std.posix.fd_t, _: u31) void {
            tl_router_hit = id;
        }
    }.f;
}

test "zix test: Router strips the query before matching" {
    const R = Router(&[_]Route{
        .{ .path = "/baseline2", .handler = routeHandler(1) },
    });

    tl_router_hit = 0;
    R.dispatch("GET", "/baseline2?a=1&b=1", &.{}, "", -1, 1);

    try std.testing.expectEqual(@as(u8, 1), tl_router_hit);
}

test "zix test: Router PREFIX matches a path subtree on a boundary" {
    const R = Router(&[_]Route{
        .{ .path = "/json", .handler = routeHandler(2), .kind = .PREFIX },
        .{ .path = "/static", .handler = routeHandler(3), .kind = .PREFIX },
    });

    tl_router_hit = 0;
    R.dispatch("GET", "/json/5?m=7", &.{}, "", -1, 1);
    try std.testing.expectEqual(@as(u8, 2), tl_router_hit);

    tl_router_hit = 0;
    R.dispatch("GET", "/static/app.js", &.{}, "", -1, 1);
    try std.testing.expectEqual(@as(u8, 3), tl_router_hit);
}

test "zix test: Router EXACT wins over PREFIX and longest prefix wins" {
    const R = Router(&[_]Route{
        .{ .path = "/json", .handler = routeHandler(1) },
        .{ .path = "/json", .handler = routeHandler(2), .kind = .PREFIX },
        .{ .path = "/json/special", .handler = routeHandler(3), .kind = .PREFIX },
    });

    // EXACT "/json" beats the "/json" PREFIX for the bare path.
    tl_router_hit = 0;
    R.dispatch("GET", "/json", &.{}, "", -1, 1);
    try std.testing.expectEqual(@as(u8, 1), tl_router_hit);

    // Longest matching prefix wins for a deeper path.
    tl_router_hit = 0;
    R.dispatch("GET", "/json/special/x", &.{}, "", -1, 1);
    try std.testing.expectEqual(@as(u8, 3), tl_router_hit);
}

test "zix test: Router PREFIX respects the segment boundary" {
    const R = Router(&[_]Route{
        .{ .path = "/json", .handler = routeHandler(2), .kind = .PREFIX },
    });

    // "/jsonx" is not under the "/json" subtree (no boundary), so it 404s. The fallback writes to a
    // pipe so no real socket is needed.
    const fds = try std.Io.Threaded.pipe2(.{});
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    tl_router_hit = 0;
    R.dispatch("GET", "/jsonx", &.{}, "", fds[1], 1);

    try std.testing.expectEqual(@as(u8, 0), tl_router_hit);
}
