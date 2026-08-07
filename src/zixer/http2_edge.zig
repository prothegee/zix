//! zixer http2 edge: h2 client connections re-originated as http1 to the
//! pool, one stream served at a time with a bounded queue for the rest

const std = @import("std");
const zix = @import("zix");

const http1_head = @import("http1_head.zig");
const http1_proxy = @import("http1_proxy.zig");
const http2_frames = @import("http2_frames.zig");
const http2_translate = @import("http2_translate.zig");
const http2_ws_bridge = @import("http2_ws_bridge.zig");
const proxy_headers = @import("proxy_headers.zig");
const static_files = @import("static_files.zig");
const upstream_conn = @import("upstream_conn.zig");
const upstream_deadline = @import("upstream_deadline.zig");
const upstream_pool = @import("upstream_pool.zig");

const Http2 = zix.Http2;

/// Stream buffer size for the socket legs (matches the h1 edge).
const STREAM_BUF_SIZE: usize = 8 * 1024;

/// Streams the edge holds while one is being served, advertised as
/// SETTINGS_MAX_CONCURRENT_STREAMS. Overflow answers REFUSED_STREAM, the
/// safe retry signal.
const QUEUE_CAP: usize = 8;

/// Interim (1xx) responses relayed per exchange (parity with the h1 edge).
const MAX_INTERIM = 4;

/// The rfc 6455 accept-key suffix for validating the upstream handshake.
const WS_ACCEPT_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

/// How one stream serve ended: the stream closed but the connection
/// lives, or the client connection itself is gone.
const Outcome = enum {
    DONE,
    CONN_DEAD,
};

/// Result of handling one client frame.
const ProcessResult = enum {
    OK,
    CLOSED,
};

/// One queued stream: everything needed to serve it after the current
/// one finishes. The h1 head is prebuilt at HEADERS time (the hpack
/// decode scratch does not survive), static requests also carry the
/// target and accept-encoding for the file plane.
const Pending = struct {
    id: u31,
    dead: bool,
    kind: enum { STATIC, POOL },
    send_window: i64,
    is_head: bool,
    needs_body: bool,
    expects_continue: bool,
    content_length: ?u64,
    head_len: usize,
    head: [http1_head.MAX_HEAD_BYTES]u8,
    target_len: usize,
    target: [static_files.MAX_PATH]u8,
    accept_len: usize,
    has_accept: bool,
    accept: [256]u8,
};

/// The stream currently being served. send_window spends against the
/// client's grants, the pump reads request DATA through took_data.
const ActiveStream = struct {
    id: u31,
    send_window: i64,
    recv_done: bool = false,
    reset: bool = false,
    took_data: []const u8 = "",
    took_wire: u32 = 0,
};

/// One h2 edge connection. Sized for the stack of its own connection
/// task: the queue dominates, everything is fixed.
const Conn = struct {
    proxy: *const http1_proxy.Proxy,
    io: std.Io,
    client_r: *std.Io.Reader,
    client_w: *std.Io.Writer,
    client_addr: std.Io.net.IpAddress,
    client_stream: ?std.Io.net.Stream,
    decoder: Http2.HpackDecoder,
    write_lock: std.atomic.Value(bool) = .init(false),
    saw_settings: bool = false,
    goaway_received: bool = false,
    highest_stream: u31 = 0,
    peer_initial_window: i64 = Http2.DEFAULT_INITIAL_WINDOW,
    peer_max_frame: u32 = Http2.DEFAULT_MAX_FRAME_SIZE,
    conn_send_window: i64 = Http2.DEFAULT_INITIAL_WINDOW,
    queue: [QUEUE_CAP]Pending = undefined,
    queue_head: usize = 0,
    queue_len: usize = 0,
    connect_pending: bool = false,
    connect_id: u31 = 0,
    connect_key: [24]u8 = undefined,
    connect_head_len: usize = 0,
    connect_head: [http1_head.MAX_HEAD_BYTES]u8 = undefined,
    payload_buf: [http2_frames.MAX_PAYLOAD]u8 = undefined,
    block_buf: [http1_head.MAX_HEAD_BYTES]u8 = undefined,
    resp_block_buf: [http1_head.MAX_HEAD_BYTES]u8 = undefined,
    decoded: [Http2.MAX_HEADERS]Http2.Header = undefined,
    decode_scratch: [http1_head.MAX_HEAD_BYTES]u8 = undefined,
};

/// True when the buffered stream opens with the h2 client preface. Peeks
/// without consuming, so the h1 fallback parses the same bytes.
pub fn prefersH2(client_r: *std.Io.Reader) bool {
    const first = client_r.peek(Http2.PREFACE.len) catch return false;

    return std.mem.eql(u8, first[0..Http2.PREFACE.len], Http2.PREFACE);
}

/// Serve one accepted cleartext connection of an http2 site: the h2
/// preface picks the h2 loop, anything else falls back to the h1 edge
/// (rfc 9113 3.3, prior knowledge only, the h1 Upgrade path is gone).
pub fn serveConn(proxy: *const http1_proxy.Proxy, client_stream: std.Io.net.Stream) void {
    const io = proxy.io;
    defer client_stream.close(io);

    var read_buf: [STREAM_BUF_SIZE]u8 = undefined;
    var write_buf: [STREAM_BUF_SIZE]u8 = undefined;
    var client_reader = client_stream.reader(io, &read_buf);
    var client_writer = client_stream.writer(io, &write_buf);

    if (prefersH2(&client_reader.interface)) {
        serveSession(proxy, &client_reader.interface, &client_writer.interface, client_stream.socket.address, client_stream);
        return;
    }

    http1_proxy.serveLoop(proxy, &client_reader.interface, &client_writer.interface, client_stream.socket.address, client_stream);
}

/// The h2 request loop over reader / writer interfaces (plain stream or a
/// terminated TLS session).
///
/// Note:
/// - Every stream is re-originated as its own h1 exchange against the
///   pool, so the pick granularity is per client stream.
/// - One stream serves at a time. Bodyless streams arriving meanwhile
///   queue (up to QUEUE_CAP), bodied ones answer REFUSED_STREAM: their
///   DATA cannot wait, and the client retries safely.
/// - client_stream is the raw socket behind the interfaces, the rfc 8441
///   tunnel needs it to unblock a waiting frame read.
pub fn serveSession(proxy: *const http1_proxy.Proxy, client_r: *std.Io.Reader, client_w: *std.Io.Writer, client_addr: std.Io.net.IpAddress, client_stream: ?std.Io.net.Stream) void {
    var preface: [Http2.PREFACE.len]u8 = undefined;
    client_r.readSliceAll(&preface) catch return;
    if (!std.mem.eql(u8, &preface, Http2.PREFACE)) return;

    http2_frames.writeSettings(client_w, &.{
        .{ Http2.SETTINGS_MAX_CONCURRENT_STREAMS, QUEUE_CAP },
        .{ http2_frames.SETTINGS_ENABLE_CONNECT_PROTOCOL, 1 },
    }) catch return;
    client_w.flush() catch return;

    var conn = Conn{
        .proxy = proxy,
        .io = proxy.io,
        .client_r = client_r,
        .client_w = client_w,
        .client_addr = client_addr,
        .client_stream = client_stream,
        .decoder = Http2.HpackDecoder.init(),
    };

    mainLoop(&conn);
}

fn mainLoop(conn: *Conn) void {
    while (true) {
        while (conn.queue_len != 0) {
            const entry = &conn.queue[conn.queue_head];
            const outcome = if (entry.dead) Outcome.DONE else serveEntry(conn, entry);

            conn.queue_head = (conn.queue_head + 1) % QUEUE_CAP;
            conn.queue_len -= 1;
            if (outcome == .CONN_DEAD) return;
        }

        if (conn.connect_pending) {
            conn.connect_pending = false;
            if (serveConnect(conn) == .CONN_DEAD) return;
            continue;
        }

        if (conn.goaway_received) {
            lockWrite(conn);
            http2_frames.writeGoaway(conn.client_w, conn.highest_stream, Http2.ERR_NO_ERROR) catch {};
            conn.client_w.flush() catch {};
            unlockWrite(conn);

            return;
        }

        if (processFrame(conn, null) == .CLOSED) return;
    }
}

// --------------------------------------------------------- //
// frame processing

/// Read and handle one client frame. active is the stream being served
/// when the call is nested inside a body pump or a window wait.
fn processFrame(conn: *Conn, active: ?*ActiveStream) ProcessResult {
    const frame = http2_frames.readFrame(conn.client_r, &conn.payload_buf) catch |err| {
        if (err == error.FrameTooLarge) return connError(conn, Http2.ERR_FRAME_SIZE_ERROR);

        return .CLOSED;
    };

    // rfc 9113 3.4: the client preface ends with a SETTINGS frame.
    if (!conn.saw_settings and frame.head.frame_type != Http2.FRAME_TYPE_SETTINGS) {
        return connError(conn, Http2.ERR_PROTOCOL_ERROR);
    }

    switch (frame.head.frame_type) {
        Http2.FRAME_TYPE_DATA => return processData(conn, active, &frame),
        Http2.FRAME_TYPE_HEADERS => return processHeaders(conn, active, &frame),
        Http2.FRAME_TYPE_PRIORITY => return .OK,
        Http2.FRAME_TYPE_RST_STREAM => {
            if (frame.payload.len != 4) return connError(conn, Http2.ERR_FRAME_SIZE_ERROR);
            if (frame.head.stream_id == 0) return connError(conn, Http2.ERR_PROTOCOL_ERROR);

            if (active) |act| {
                if (frame.head.stream_id == act.id) {
                    act.reset = true;
                    return .OK;
                }
            }
            markQueueDead(conn, frame.head.stream_id);

            return .OK;
        },
        Http2.FRAME_TYPE_SETTINGS => return processSettings(conn, active, &frame),
        Http2.FRAME_TYPE_PUSH_PROMISE => return connError(conn, Http2.ERR_PROTOCOL_ERROR),
        Http2.FRAME_TYPE_PING => {
            if ((frame.head.flags & Http2.FLAG_ACK) != 0) return .OK;
            if (frame.payload.len != 8) return connError(conn, Http2.ERR_FRAME_SIZE_ERROR);

            lockWrite(conn);
            defer unlockWrite(conn);
            http2_frames.writePingAck(conn.client_w, frame.payload) catch return .CLOSED;
            conn.client_w.flush() catch return .CLOSED;

            return .OK;
        },
        Http2.FRAME_TYPE_GOAWAY => {
            conn.goaway_received = true;

            return .OK;
        },
        Http2.FRAME_TYPE_WINDOW_UPDATE => return processWindowUpdate(conn, active, &frame),
        Http2.FRAME_TYPE_CONTINUATION => return connError(conn, Http2.ERR_PROTOCOL_ERROR),
        else => return .OK,
    }
}

fn processData(conn: *Conn, active: ?*ActiveStream, frame: *const http2_frames.Frame) ProcessResult {
    if (frame.head.stream_id == 0) return connError(conn, Http2.ERR_PROTOCOL_ERROR);
    const data = http2_frames.dataPayload(frame) catch return connError(conn, Http2.ERR_PROTOCOL_ERROR);

    if (active) |act| {
        if (frame.head.stream_id == act.id and !act.recv_done) {
            act.took_data = data;
            act.took_wire = frame.head.length;
            if ((frame.head.flags & Http2.FLAG_END_STREAM) != 0) act.recv_done = true;

            return .OK;
        }
    }

    // Unclaimed DATA (a refused, reset, or finished stream): dropped, the
    // connection credit goes straight back so the client never stalls.
    if (frame.head.length > 0) {
        lockWrite(conn);
        defer unlockWrite(conn);
        http2_frames.writeWindowUpdate(conn.client_w, 0, @intCast(frame.head.length)) catch return .CLOSED;
        conn.client_w.flush() catch return .CLOSED;
    }

    return .OK;
}

fn processHeaders(conn: *Conn, active: ?*ActiveStream, first: *const http2_frames.Frame) ProcessResult {
    const id = first.head.stream_id;
    if (id == 0) return connError(conn, Http2.ERR_PROTOCOL_ERROR);

    const fragment = http2_frames.headersFragment(first) catch return connError(conn, Http2.ERR_PROTOCOL_ERROR);
    if (fragment.len > conn.block_buf.len) return connError(conn, Http2.ERR_ENHANCE_YOUR_CALM);
    @memcpy(conn.block_buf[0..fragment.len], fragment);
    var block_len: usize = fragment.len;
    const end_stream = (first.head.flags & Http2.FLAG_END_STREAM) != 0;

    // CONTINUATION frames extend the block until END_HEADERS. A block the
    // buffer cannot hold kills the connection: skipping it would desync
    // the shared hpack state.
    var end_headers = (first.head.flags & Http2.FLAG_END_HEADERS) != 0;
    while (!end_headers) {
        const next = http2_frames.readFrame(conn.client_r, &conn.payload_buf) catch return .CLOSED;
        if (next.head.frame_type != Http2.FRAME_TYPE_CONTINUATION or next.head.stream_id != id) {
            return connError(conn, Http2.ERR_PROTOCOL_ERROR);
        }
        if (block_len + next.payload.len > conn.block_buf.len) return connError(conn, Http2.ERR_ENHANCE_YOUR_CALM);

        @memcpy(conn.block_buf[block_len..][0..next.payload.len], next.payload);
        block_len += next.payload.len;
        end_headers = (next.head.flags & Http2.FLAG_END_HEADERS) != 0;
    }

    const count = conn.decoder.decode(conn.block_buf[0..block_len], &conn.decoded, &conn.decode_scratch) catch {
        return connError(conn, Http2.ERR_COMPRESSION_ERROR);
    };
    const headers = conn.decoded[0..count];

    // Trailers of the stream being served: the h1 leg has no place for
    // them once the head is on the wire, decoded (hpack stays synced) and
    // dropped, they only end the request body.
    if (active) |act| {
        if (id == act.id) {
            if (!end_stream) return connError(conn, Http2.ERR_PROTOCOL_ERROR);
            act.recv_done = true;

            return .OK;
        }
    }

    if (id % 2 == 0) return connError(conn, Http2.ERR_PROTOCOL_ERROR);
    if (id <= conn.highest_stream) return streamError(conn, id, Http2.ERR_STREAM_CLOSED);
    conn.highest_stream = id;

    if (conn.goaway_received) return streamError(conn, id, Http2.ERR_REFUSED_STREAM);

    const request = http2_translate.assemble(headers, end_stream) catch |err| switch (err) {
        error.Malformed => return streamError(conn, id, Http2.ERR_PROTOCOL_ERROR),
        error.UnsupportedConnect => return localAnswer(conn, id, 501, null),
    };

    // rfc 9110 7.4: under TLS, an authority this certificate does not
    // serve is a misdirected request.
    if (misdirected(conn, &request)) return localAnswer(conn, id, 421, null);

    if (request.is_connect) return acceptConnect(conn, active, id, &request, headers);

    return acceptStream(conn, active, id, &request, headers);
}

/// Queue a plain stream for serving, or answer it locally right away.
fn acceptStream(conn: *Conn, active: ?*ActiveStream, id: u31, request: *const http2_translate.Request, headers: []const Http2.Header) ProcessResult {
    const has_pool = conn.proxy.pool != null;

    // The static plane decision mirrors the h1 answer order: a handled
    // target tries the file plane first, a static-only site answers
    // everything else locally.
    var wants_static = false;
    if (conn.proxy.static) |*site| {
        wants_static = static_files.handles(site, request.method, request.target) and
            request.target.len <= static_files.MAX_PATH;
    }
    if (!wants_static and !has_pool) {
        if (!static_files.fileMethod(request.method)) return localAnswer(conn, id, 405, null);

        return localAnswer(conn, id, 404, null);
    }

    if (request.has_body and active != null) return streamError(conn, id, Http2.ERR_REFUSED_STREAM);
    if (conn.queue_len == QUEUE_CAP) return streamError(conn, id, Http2.ERR_REFUSED_STREAM);

    const entry = &conn.queue[(conn.queue_head + conn.queue_len) % QUEUE_CAP];
    entry.* = .{
        .id = id,
        .dead = false,
        .kind = if (wants_static) .STATIC else .POOL,
        .send_window = conn.peer_initial_window,
        .is_head = request.is_head,
        .needs_body = request.has_body,
        .expects_continue = request.expects_continue,
        .content_length = request.content_length,
        .head_len = 0,
        .head = undefined,
        .target_len = 0,
        .target = undefined,
        .accept_len = 0,
        .has_accept = false,
        .accept = undefined,
    };

    if (wants_static) {
        @memcpy(entry.target[0..request.target.len], request.target);
        entry.target_len = request.target.len;

        for (headers) |header| {
            if (!std.mem.eql(u8, header.name, "accept-encoding")) continue;

            const take = @min(header.value.len, entry.accept.len);
            @memcpy(entry.accept[0..take], header.value[0..take]);
            entry.accept_len = take;
            entry.has_accept = true;
            break;
        }
    }

    if (has_pool) {
        const head = http2_translate.buildUpstreamHead(&entry.head, request, headers, conn.client_addr) catch {
            return localAnswer(conn, id, 400, "http_request_error");
        };
        entry.head_len = head.len;
    }

    conn.queue_len += 1;

    return .OK;
}

/// Stage an rfc 8441 extended CONNECT: the main loop runs the tunnel once
/// the edge is idle, a busy edge refuses so the client retries fresh.
fn acceptConnect(conn: *Conn, active: ?*ActiveStream, id: u31, request: *const http2_translate.Request, headers: []const Http2.Header) ProcessResult {
    if (active != null or conn.queue_len != 0) return streamError(conn, id, Http2.ERR_REFUSED_STREAM);
    if (conn.proxy.pool == null) return localAnswer(conn, id, 503, "destination_unavailable");

    // The h1 leg needs the Sec-WebSocket-Key the h2 handshake never
    // carries, zixer generates its own and validates the accept answer.
    var key_raw: [16]u8 = undefined;
    conn.io.randomSecure(&key_raw) catch return streamError(conn, id, Http2.ERR_INTERNAL_ERROR);
    _ = std.base64.standard.Encoder.encode(&conn.connect_key, &key_raw);

    const head = http2_translate.buildConnectHead(&conn.connect_head, request, headers, conn.client_addr, &conn.connect_key) catch {
        return localAnswer(conn, id, 400, "http_request_error");
    };
    conn.connect_head_len = head.len;
    conn.connect_id = id;
    conn.connect_pending = true;

    return .OK;
}

fn processSettings(conn: *Conn, active: ?*ActiveStream, frame: *const http2_frames.Frame) ProcessResult {
    if ((frame.head.flags & Http2.FLAG_ACK) != 0) return .OK;
    if (frame.payload.len % 6 != 0) return connError(conn, Http2.ERR_FRAME_SIZE_ERROR);

    var params = http2_frames.SettingsIterator.init(frame.payload);
    while (params.next()) |param| {
        switch (param[0]) {
            Http2.SETTINGS_INITIAL_WINDOW_SIZE => {
                if (param[1] > 0x7FFF_FFFF) return connError(conn, Http2.ERR_FLOW_CONTROL_ERROR);

                // rfc 9113 6.9.2: the delta applies to every open stream.
                const delta = @as(i64, param[1]) - conn.peer_initial_window;
                conn.peer_initial_window = param[1];
                if (active) |act| act.send_window += delta;
                var offset: usize = 0;
                while (offset < conn.queue_len) : (offset += 1) {
                    conn.queue[(conn.queue_head + offset) % QUEUE_CAP].send_window += delta;
                }
            },
            Http2.SETTINGS_MAX_FRAME_SIZE => {
                if (param[1] < Http2.DEFAULT_MAX_FRAME_SIZE or param[1] > 0xFF_FFFF) {
                    return connError(conn, Http2.ERR_PROTOCOL_ERROR);
                }
                conn.peer_max_frame = param[1];
            },
            Http2.SETTINGS_ENABLE_PUSH => {
                if (param[1] > 1) return connError(conn, Http2.ERR_PROTOCOL_ERROR);
            },
            else => {},
        }
    }
    conn.saw_settings = true;

    lockWrite(conn);
    defer unlockWrite(conn);
    http2_frames.writeSettingsAck(conn.client_w) catch return .CLOSED;
    conn.client_w.flush() catch return .CLOSED;

    return .OK;
}

fn processWindowUpdate(conn: *Conn, active: ?*ActiveStream, frame: *const http2_frames.Frame) ProcessResult {
    const increment = http2_frames.windowIncrement(frame.payload) catch {
        return connError(conn, Http2.ERR_FRAME_SIZE_ERROR);
    };

    if (frame.head.stream_id == 0) {
        if (increment == 0) return connError(conn, Http2.ERR_PROTOCOL_ERROR);

        conn.conn_send_window += increment;
        if (conn.conn_send_window > 0x7FFF_FFFF) return connError(conn, Http2.ERR_FLOW_CONTROL_ERROR);

        return .OK;
    }

    if (increment == 0) return streamError(conn, frame.head.stream_id, Http2.ERR_PROTOCOL_ERROR);

    if (active) |act| {
        if (frame.head.stream_id == act.id) {
            act.send_window += increment;

            return .OK;
        }
    }

    var offset: usize = 0;
    while (offset < conn.queue_len) : (offset += 1) {
        const entry = &conn.queue[(conn.queue_head + offset) % QUEUE_CAP];
        if (entry.id == frame.head.stream_id) {
            entry.send_window += increment;

            return .OK;
        }
    }

    return .OK;
}

fn markQueueDead(conn: *Conn, id: u31) void {
    var offset: usize = 0;
    while (offset < conn.queue_len) : (offset += 1) {
        const entry = &conn.queue[(conn.queue_head + offset) % QUEUE_CAP];
        if (entry.id == id) entry.dead = true;
    }
}

/// Whether a TLS-terminated request names an authority the site's
/// certificate does not serve. Cleartext edges never arm this.
fn misdirected(conn: *Conn, request: *const http2_translate.Request) bool {
    const cert_der = conn.proxy.tls_cert_der orelse return false;
    if (request.authority.len == 0) return false;

    const host = proxy_headers.stripHostPort(request.authority);
    zix.Tls.verifyCertIdentity(cert_der, host) catch return true;

    return false;
}

// --------------------------------------------------------- //
// stream serving

fn serveEntry(conn: *Conn, entry: *Pending) Outcome {
    var active = ActiveStream{
        .id = entry.id,
        .send_window = entry.send_window,
        .recv_done = !entry.needs_body,
    };

    if (entry.kind == .STATIC) {
        const site = &conn.proxy.static.?;
        const accept: ?[]const u8 = if (entry.has_accept) entry.accept[0..entry.accept_len] else null;
        const target = entry.target[0..entry.target_len];

        if (static_files.open(conn.io, site.public_dir, target, accept)) |resolved| {
            return serveStaticFile(conn, &active, resolved, entry.is_head);
        }

        // File miss: the fallback page of a client-side routed app, then
        // the pool on a mixed site, a local 404 otherwise.
        if (site.spa_fallback) |fallback| {
            var target_buf: [static_files.MAX_PATH]u8 = undefined;
            if (std.fmt.bufPrint(&target_buf, "/{s}", .{fallback}) catch null) |fallback_target| {
                if (static_files.open(conn.io, site.public_dir, fallback_target, accept)) |resolved| {
                    return serveStaticFile(conn, &active, resolved, entry.is_head);
                }
            }
        }

        if (conn.proxy.pool == null) {
            return if (localAnswer(conn, entry.id, 404, null) == .CLOSED) .CONN_DEAD else .DONE;
        }
    }

    return servePool(conn, &active, entry);
}

/// One exchange against the pool: pick, forward, relay, bounded retry.
/// Mirrors the h1 exchange, with the client leg speaking frames.
fn servePool(conn: *Conn, active: *ActiveStream, entry: *const Pending) Outcome {
    const io = conn.io;
    const pool = conn.proxy.pool.?;
    const idle = conn.proxy.idle.?;
    const upstream_head = entry.head[0..entry.head_len];
    var continue_sent = false;

    var attempts: usize = pool.slots.len + 1;
    var failed_here = false;
    while (attempts > 0) : (attempts -= 1) {
        const picked = pool.pick(nowMs(io)) orelse {
            if (failed_here) break;

            return if (localAnswer(conn, active.id, 503, "destination_unavailable") == .CLOSED) .CONN_DEAD else .DONE;
        };

        const conn_up = idle.acquire(io, picked.index, nowMs(io)) orelse
            upstream_conn.connect(io, picked.host, picked.port, picked.index) catch {
            pool.markDown(picked.index, nowMs(io));
            failed_here = true;
            continue;
        };
        const gate = upstreamGate(conn, conn_up);

        var up_read_buf: [STREAM_BUF_SIZE]u8 = undefined;
        var up_write_buf: [STREAM_BUF_SIZE]u8 = undefined;
        var up_reader = conn_up.stream.reader(io, &up_read_buf);
        var up_writer = conn_up.stream.writer(io, &up_write_buf);

        up_writer.interface.writeAll(upstream_head) catch {
            conn_up.stream.close(io);
            if (!conn_up.reused) pool.markDown(picked.index, nowMs(io));
            failed_here = true;
            continue;
        };

        if (entry.needs_body) {
            // The client may hold the body for a 100 (rfc 9113 8.5 allows
            // the interim HEADERS), answered here once, the h1 leg
            // dropped the Expect header.
            if (entry.expects_continue and !continue_sent) {
                if (sendLocalHead(conn, active.id, 100, null, false) == .CLOSED) {
                    conn_up.stream.close(io);
                    return .CONN_DEAD;
                }
                continue_sent = true;
            }

            pumpBodyToUpstream(conn, active, &up_writer.interface, entry.content_length) catch |err| {
                conn_up.stream.close(io);
                switch (err) {
                    error.ClientDead => return .CONN_DEAD,
                    error.Reset => return .DONE,
                    error.BadBody => return if (streamError(conn, active.id, Http2.ERR_PROTOCOL_ERROR) == .CLOSED) .CONN_DEAD else .DONE,
                    error.UpstreamDead => return if (localAnswer(conn, active.id, 502, "connection_terminated") == .CLOSED) .CONN_DEAD else .DONE,
                }
            };
        }

        up_writer.interface.flush() catch {
            conn_up.stream.close(io);
            if (!entry.needs_body) {
                if (!conn_up.reused) pool.markDown(picked.index, nowMs(io));
                failed_here = true;
                continue;
            }

            return if (localAnswer(conn, active.id, 502, "connection_terminated") == .CLOSED) .CONN_DEAD else .DONE;
        };

        var resp_head_buf: [http1_head.MAX_HEAD_BYTES]u8 = undefined;
        const method: []const u8 = if (entry.is_head) "HEAD" else "GET";
        const response = readUpstreamHead(conn, active, &up_reader.interface, &resp_head_buf, method, gate) catch |err| {
            conn_up.stream.close(io);
            switch (err) {
                error.ClientDead => return .CONN_DEAD,

                // A silent upstream is not a dead one: the request was
                // already delivered, so it is neither replayed elsewhere
                // nor is the slot taken out of rotation.
                error.UpstreamTimeout => return if (localAnswer(conn, active.id, 504, "http_response_timeout") == .CLOSED) .CONN_DEAD else .DONE,
                else => {},
            }
            if (!entry.needs_body) {
                if (!conn_up.reused) pool.markDown(picked.index, nowMs(io));
                failed_here = true;
                continue;
            }

            return if (localAnswer(conn, active.id, 502, "connection_terminated") == .CLOSED) .CONN_DEAD else .DONE;
        };

        return relayResponse(conn, active, &response, conn_up, &up_reader.interface);
    }

    return if (localAnswer(conn, active.id, 502, "connection_refused") == .CLOSED) .CONN_DEAD else .DONE;
}

/// Read the upstream response head, relaying interim 1xx heads as h2
/// informational HEADERS. A 101 was never asked for on a plain exchange
/// and counts as an upstream failure.
fn readUpstreamHead(conn: *Conn, active: *ActiveStream, up_r: *std.Io.Reader, head_buf: []u8, method: []const u8, gate: upstream_deadline.Gate) !http1_head.ResponseHead {
    var interim: usize = 0;
    while (interim <= MAX_INTERIM) : (interim += 1) {
        if (!gate.ready(up_r)) return error.UpstreamTimeout;

        const bytes = http1_head.readHead(up_r, head_buf) catch return error.UpstreamDead;
        const response = http1_head.parseResponse(bytes, method) catch return error.UpstreamDead;

        if (response.status == 101) return error.UpstreamDead;
        if (response.status / 100 != 1) return response;

        const block = http2_translate.encodeResponseBlock(&conn.resp_block_buf, &response, null) catch return error.UpstreamDead;
        if (writeBlock(conn, active.id, block, false) == .CLOSED) return error.ClientDead;
    }

    return error.UpstreamDead;
}

/// Relay one upstream response onto the stream: head as a header block,
/// body as flow-controlled DATA, chunked trailers as a trailing block.
fn relayResponse(conn: *Conn, active: *ActiveStream, response: *const http1_head.ResponseHead, conn_up: upstream_conn.UpstreamConn, up_r: *std.Io.Reader) Outcome {
    const io = conn.io;

    const block_length: ?u64 = switch (response.framing) {
        .content_length => |len| len,
        .none => if (response.status == 204 or response.status == 304 or response.status / 100 == 1) null else 0,
        else => null,
    };
    const head_only = response.framing == .none;

    const block = http2_translate.encodeResponseBlock(&conn.resp_block_buf, response, block_length) catch {
        conn_up.stream.close(io);
        return if (streamError(conn, active.id, Http2.ERR_INTERNAL_ERROR) == .CLOSED) .CONN_DEAD else .DONE;
    };
    if (writeBlock(conn, active.id, block, head_only) == .CLOSED) {
        conn_up.stream.close(io);
        return .CONN_DEAD;
    }

    var relay_failed = false;
    var relay_result: Outcome = .DONE;
    if (!head_only) {
        const relayed: RelayError!void = switch (response.framing) {
            .content_length => |len| relayExact(conn, active, up_r, len, upstreamGate(conn, conn_up)),
            .chunked => relayChunked(conn, active, up_r),
            .until_close => relayUntilClose(conn, active, up_r),
            .none => unreachable,
        };

        relayed catch |err| switch (err) {
            error.ClientDead => {
                conn_up.stream.close(io);
                return .CONN_DEAD;
            },
            error.Reset => relay_failed = true,
            error.UpstreamDead, error.BadBody => {
                relay_failed = true;
                relay_result = if (streamError(conn, active.id, Http2.ERR_INTERNAL_ERROR) == .CLOSED) .CONN_DEAD else .DONE;
            },
        };
    }

    const reusable = !relay_failed and !response.connection_close and response.framing != .until_close;
    if (reusable) conn.proxy.idle.?.release(io, conn_up, nowMs(io)) else conn_up.stream.close(io);

    return relay_result;
}

// --------------------------------------------------------- //
// body relays

const RelayError = error{
    ClientDead,
    Reset,
    UpstreamDead,
    BadBody,
};

/// Pump the request DATA frames onto the upstream leg, granting the flow
/// credit back as each frame lands. content_length null re-frames as
/// chunked (the h1 leg always carries explicit framing).
fn pumpBodyToUpstream(conn: *Conn, active: *ActiveStream, up_w: *std.Io.Writer, content_length: ?u64) RelayError!void {
    var remaining: u64 = content_length orelse 0;
    const chunked = content_length == null;

    while (!active.recv_done) {
        active.took_data = "";
        active.took_wire = 0;
        if (processFrame(conn, active) == .CLOSED) return error.ClientDead;
        if (active.reset) return error.Reset;

        if (active.took_data.len > 0) {
            const data = active.took_data;
            if (chunked) {
                up_w.print("{x}\r\n", .{data.len}) catch return error.UpstreamDead;
                up_w.writeAll(data) catch return error.UpstreamDead;
                up_w.writeAll("\r\n") catch return error.UpstreamDead;
            } else {
                if (data.len > remaining) return error.BadBody;
                up_w.writeAll(data) catch return error.UpstreamDead;
                remaining -= data.len;
            }
        }

        if (active.took_wire > 0) grantCredit(conn, active.id, active.took_wire) catch return error.ClientDead;
    }

    if (!chunked and remaining != 0) return error.BadBody;
    if (chunked) up_w.writeAll("0\r\n\r\n") catch return error.UpstreamDead;
}

/// Hand consumed request-body credit back on the connection and stream.
fn grantCredit(conn: *Conn, stream_id: u31, consumed: u32) !void {
    lockWrite(conn);
    defer unlockWrite(conn);
    try http2_frames.writeWindowUpdate(conn.client_w, 0, @intCast(consumed));
    try http2_frames.writeWindowUpdate(conn.client_w, stream_id, @intCast(consumed));
    try conn.client_w.flush();
}

/// Send one run of response bytes as DATA frames inside the send windows,
/// reading client frames whenever credit runs dry.
fn sendData(conn: *Conn, active: *ActiveStream, bytes: []const u8, end_stream: bool) RelayError!void {
    if (bytes.len == 0) {
        if (!end_stream) return;

        lockWrite(conn);
        defer unlockWrite(conn);
        http2_frames.writeFrame(conn.client_w, Http2.FRAME_TYPE_DATA, Http2.FLAG_END_STREAM, active.id, "") catch return error.ClientDead;
        conn.client_w.flush() catch return error.ClientDead;

        return;
    }

    var offset: usize = 0;
    while (offset < bytes.len) {
        const window = @min(conn.conn_send_window, active.send_window);
        if (window <= 0) {
            // Everything staged must reach the client before blocking on
            // its next grant, an unflushed frame cannot be acknowledged.
            conn.client_w.flush() catch return error.ClientDead;
            if (processFrame(conn, active) == .CLOSED) return error.ClientDead;
            if (active.reset) return error.Reset;
            continue;
        }

        const take = @min(bytes.len - offset, @min(@as(usize, @intCast(window)), effectiveMaxFrame(conn)));
        const last = offset + take == bytes.len;
        const flags: u8 = if (last and end_stream) Http2.FLAG_END_STREAM else 0;

        lockWrite(conn);
        http2_frames.writeFrame(conn.client_w, Http2.FRAME_TYPE_DATA, flags, active.id, bytes[offset..][0..take]) catch {
            unlockWrite(conn);
            return error.ClientDead;
        };
        unlockWrite(conn);

        conn.conn_send_window -= @intCast(take);
        active.send_window -= @intCast(take);
        offset += take;
    }
}

/// Relay exactly len upstream bytes as DATA, END_STREAM on the last run.
fn relayExact(conn: *Conn, active: *ActiveStream, up_r: *std.Io.Reader, len: u64, gate: upstream_deadline.Gate) RelayError!void {
    var chunk: [http2_frames.MAX_PAYLOAD]u8 = undefined;
    var remaining = len;
    while (remaining > 0) {
        // The head is already on the wire, so a stall here can only end the
        // stream. The client sees a reset rather than a body that never ends.
        if (!gate.ready(up_r)) return error.UpstreamDead;

        const want: usize = @intCast(@min(remaining, chunk.len));
        const got = up_r.readSliceShort(chunk[0..want]) catch return error.UpstreamDead;
        if (got == 0) return error.UpstreamDead;

        remaining -= got;
        try sendData(conn, active, chunk[0..got], remaining == 0);
    }

    conn.client_w.flush() catch return error.ClientDead;
}

/// Relay a chunked upstream body: each chunk flushes as its own DATA so
/// stream semantics survive the hop, the trailer section becomes the
/// trailing header block.
fn relayChunked(conn: *Conn, active: *ActiveStream, up_r: *std.Io.Reader) RelayError!void {
    while (true) {
        var line_buf: [256]u8 = undefined;
        const size_line = readLine(up_r, &line_buf) catch return error.UpstreamDead;

        const semicolon = std.mem.indexOfScalar(u8, size_line, ';');
        const size_text = std.mem.trim(u8, if (semicolon) |pos| size_line[0..pos] else size_line, " \t");
        const size = std.fmt.parseInt(u64, size_text, 16) catch return error.BadBody;

        if (size == 0) return relayTrailers(conn, active, up_r);

        var remaining = size;
        var chunk: [http2_frames.MAX_PAYLOAD]u8 = undefined;
        while (remaining > 0) {
            const want: usize = @intCast(@min(remaining, chunk.len));
            const got = up_r.readSliceShort(chunk[0..want]) catch return error.UpstreamDead;
            if (got == 0) return error.UpstreamDead;

            remaining -= got;
            try sendData(conn, active, chunk[0..got], false);
        }

        const after = readLine(up_r, &line_buf) catch return error.UpstreamDead;
        if (after.len != 0) return error.BadBody;

        conn.client_w.flush() catch return error.ClientDead;
    }
}

/// Consume the trailer section and end the stream: named trailers ride a
/// trailing header block, an empty section ends with bare END_STREAM.
fn relayTrailers(conn: *Conn, active: *ActiveStream, up_r: *std.Io.Reader) RelayError!void {
    var trailers: [16]http1_head.Header = undefined;
    var trailer_count: usize = 0;
    var text_buf: [2048]u8 = undefined;
    var text_len: usize = 0;

    while (true) {
        var line_buf: [512]u8 = undefined;
        const line = readLine(up_r, &line_buf) catch return error.UpstreamDead;
        if (line.len == 0) break;
        if (trailer_count == trailers.len) continue;
        if (text_len + line.len > text_buf.len) continue;

        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        @memcpy(text_buf[text_len..][0..line.len], line);
        const stored = text_buf[text_len..][0..line.len];
        text_len += line.len;

        trailers[trailer_count] = .{
            .name = stored[0..colon],
            .value = std.mem.trim(u8, stored[colon + 1 ..], " \t"),
        };
        trailer_count += 1;
    }

    if (trailer_count > 0) {
        const block = http2_translate.encodeTrailerBlock(&conn.resp_block_buf, trailers[0..trailer_count]) catch {
            return try sendData(conn, active, "", true);
        };
        if (block.len > 0) {
            if (writeBlock(conn, active.id, block, true) == .CLOSED) return error.ClientDead;

            return;
        }
    }

    try sendData(conn, active, "", true);
}

/// Relay until the upstream closes, each burst flushed as it arrives (a
/// filling read would hold streamed events until the buffer topped up),
/// then END_STREAM.
fn relayUntilClose(conn: *Conn, active: *ActiveStream, up_r: *std.Io.Reader) RelayError!void {
    while (true) {
        const burst = up_r.peekGreedy(1) catch break;

        try sendData(conn, active, burst, false);
        conn.client_w.flush() catch return error.ClientDead;
        up_r.toss(burst.len);
    }

    try sendData(conn, active, "", true);
}

/// One CRLF-terminated line, returned without its terminator.
fn readLine(src: *std.Io.Reader, buf: []u8) ![]const u8 {
    var len: usize = 0;
    while (len < buf.len) {
        const got = src.readSliceShort(buf[len .. len + 1]) catch return error.ConnectionClosed;
        if (got == 0) return error.ConnectionClosed;

        len += 1;
        if (len >= 2 and buf[len - 2] == '\r' and buf[len - 1] == '\n') return buf[0 .. len - 2];
    }

    return error.BadChunk;
}

// --------------------------------------------------------- //
// static plane

/// Serve one resolved file on the stream, mirroring the h1 static plane.
fn serveStaticFile(conn: *Conn, active: *ActiveStream, resolved: static_files.Resolved, is_head: bool) Outcome {
    const io = conn.io;
    defer resolved.file.close(io);

    var block_buf: [1024]u8 = undefined;
    const block = http2_translate.encodeStaticBlock(&block_buf, resolved.content_type, resolved.size, resolved.encoding.contentEncoding()) catch {
        return if (streamError(conn, active.id, Http2.ERR_INTERNAL_ERROR) == .CLOSED) .CONN_DEAD else .DONE;
    };

    const head_only = is_head or resolved.size == 0;
    if (writeBlock(conn, active.id, block, head_only) == .CLOSED) return .CONN_DEAD;
    if (head_only) return .DONE;

    var chunk: [http2_frames.MAX_PAYLOAD]u8 = undefined;
    var offset: u64 = 0;
    while (offset < resolved.size) {
        const want: usize = @intCast(@min(resolved.size - offset, chunk.len));
        const got = resolved.file.readPositionalAll(io, chunk[0..want], offset) catch {
            return if (streamError(conn, active.id, Http2.ERR_INTERNAL_ERROR) == .CLOSED) .CONN_DEAD else .DONE;
        };
        if (got == 0) {
            return if (streamError(conn, active.id, Http2.ERR_INTERNAL_ERROR) == .CLOSED) .CONN_DEAD else .DONE;
        }

        offset += got;
        sendData(conn, active, chunk[0..got], offset == resolved.size) catch |err| switch (err) {
            error.ClientDead => return .CONN_DEAD,
            else => return .DONE,
        };
    }
    conn.client_w.flush() catch return .CONN_DEAD;

    return .DONE;
}

// --------------------------------------------------------- //
// rfc 8441 tunnel

/// Run the staged extended CONNECT: the pool pick pins for the tunnel
/// life and the edge connection always closes with it. A refused upgrade
/// relays the upstream's plain response instead.
fn serveConnect(conn: *Conn) Outcome {
    const io = conn.io;
    const pool = conn.proxy.pool.?;
    const idle = conn.proxy.idle.?;
    const upstream_head = conn.connect_head[0..conn.connect_head_len];
    var active = ActiveStream{ .id = conn.connect_id, .send_window = conn.peer_initial_window, .recv_done = true };

    var attempts: usize = pool.slots.len + 1;
    var failed_here = false;
    while (attempts > 0) : (attempts -= 1) {
        const picked = pool.pick(nowMs(io)) orelse {
            if (failed_here) break;

            return if (localAnswer(conn, active.id, 503, "destination_unavailable") == .CLOSED) .CONN_DEAD else .DONE;
        };

        const conn_up = idle.acquire(io, picked.index, nowMs(io)) orelse
            upstream_conn.connect(io, picked.host, picked.port, picked.index) catch {
            pool.markDown(picked.index, nowMs(io));
            failed_here = true;
            continue;
        };

        var up_read_buf: [STREAM_BUF_SIZE]u8 = undefined;
        var up_write_buf: [STREAM_BUF_SIZE]u8 = undefined;
        var up_reader = conn_up.stream.reader(io, &up_read_buf);
        var up_writer = conn_up.stream.writer(io, &up_write_buf);

        const sent = blk: {
            up_writer.interface.writeAll(upstream_head) catch break :blk false;
            up_writer.interface.flush() catch break :blk false;
            break :blk true;
        };
        if (!sent) {
            conn_up.stream.close(io);
            if (!conn_up.reused) pool.markDown(picked.index, nowMs(io));
            failed_here = true;
            continue;
        }

        var resp_head_buf: [http1_head.MAX_HEAD_BYTES]u8 = undefined;
        if (!upstreamGate(conn, conn_up).ready(&up_reader.interface)) {
            conn_up.stream.close(io);

            return if (localAnswer(conn, active.id, 504, "http_response_timeout") == .CLOSED) .CONN_DEAD else .DONE;
        }

        const head_bytes = http1_head.readHead(&up_reader.interface, &resp_head_buf) catch {
            conn_up.stream.close(io);
            if (!conn_up.reused) pool.markDown(picked.index, nowMs(io));
            failed_here = true;
            continue;
        };
        const response = http1_head.parseResponse(head_bytes, "GET") catch {
            conn_up.stream.close(io);
            failed_here = true;
            continue;
        };

        // The upstream refused the upgrade: its plain response relays on
        // the CONNECT stream, the edge keeps serving.
        if (response.status != 101) {
            return relayResponse(conn, &active, &response, conn_up, &up_reader.interface);
        }

        if (!acceptMatches(&response, &conn.connect_key)) {
            conn_up.stream.close(io);
            return if (localAnswer(conn, active.id, 502, "connection_terminated") == .CLOSED) .CONN_DEAD else .DONE;
        }

        const block = http2_translate.encodeConnectResponseBlock(&conn.resp_block_buf, &response) catch {
            conn_up.stream.close(io);
            return if (streamError(conn, active.id, Http2.ERR_INTERNAL_ERROR) == .CLOSED) .CONN_DEAD else .DONE;
        };
        if (writeBlock(conn, active.id, block, false) == .CLOSED) {
            conn_up.stream.close(io);
            return .CONN_DEAD;
        }

        var conn_window = std.atomic.Value(i64).init(conn.conn_send_window);
        var stream_window = std.atomic.Value(i64).init(active.send_window);
        var stop = std.atomic.Value(bool).init(false);
        http2_ws_bridge.run(.{
            .io = io,
            .client_r = conn.client_r,
            .client_w = conn.client_w,
            .write_lock = &conn.write_lock,
            .client_stream = conn.client_stream,
            .stream_id = active.id,
            .up_stream = conn_up.stream,
            .up_r = &up_reader.interface,
            .up_w = &up_writer.interface,
            .conn_window = &conn_window,
            .stream_window = &stream_window,
            .max_frame = effectiveMaxFrame(conn),
            .stop = &stop,
        });
        conn_up.stream.close(io);

        lockWrite(conn);
        http2_frames.writeGoaway(conn.client_w, conn.highest_stream, Http2.ERR_NO_ERROR) catch {};
        conn.client_w.flush() catch {};
        unlockWrite(conn);

        return .CONN_DEAD;
    }

    return if (localAnswer(conn, active.id, 502, "connection_refused") == .CLOSED) .CONN_DEAD else .DONE;
}

/// Validate the upstream's Sec-WebSocket-Accept against zixer's own key
/// (rfc 6455 4.2.2).
fn acceptMatches(response: *const http1_head.ResponseHead, key_b64: []const u8) bool {
    var sha = std.crypto.hash.Sha1.init(.{});
    sha.update(key_b64);
    sha.update(WS_ACCEPT_GUID);
    var digest: [20]u8 = undefined;
    sha.final(&digest);

    var expected: [28]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&expected, &digest);

    for (response.headerSlice()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "sec-websocket-accept")) {
            return std.mem.eql(u8, std.mem.trim(u8, header.value, " \t"), &expected);
        }
    }

    return false;
}

// --------------------------------------------------------- //
// local answers and small helpers

/// Answer a stream locally with a bodyless head, END_STREAM set.
fn localAnswer(conn: *Conn, stream_id: u31, status: u16, proxy_error: ?[]const u8) ProcessResult {
    return sendLocalHead(conn, stream_id, status, proxy_error, true);
}

fn sendLocalHead(conn: *Conn, stream_id: u31, status: u16, proxy_error: ?[]const u8, end_stream: bool) ProcessResult {
    var block_buf: [256]u8 = undefined;
    const block = http2_translate.encodeLocalBlock(&block_buf, status, proxy_error) catch return .OK;

    return writeBlock(conn, stream_id, block, end_stream);
}

/// Write one header block and flush it, under the shared write lock.
fn writeBlock(conn: *Conn, stream_id: u31, block: []const u8, end_stream: bool) ProcessResult {
    lockWrite(conn);
    defer unlockWrite(conn);
    http2_frames.writeHeaderBlock(conn.client_w, stream_id, block, end_stream, effectiveMaxFrame(conn)) catch return .CLOSED;
    conn.client_w.flush() catch return .CLOSED;

    return .OK;
}

/// Reset one stream, the connection keeps serving.
fn streamError(conn: *Conn, stream_id: u31, code: u32) ProcessResult {
    lockWrite(conn);
    defer unlockWrite(conn);
    http2_frames.writeRstStream(conn.client_w, stream_id, code) catch return .CLOSED;
    conn.client_w.flush() catch return .CLOSED;

    return .OK;
}

/// Fatal connection error: best-effort GOAWAY, then the caller closes.
fn connError(conn: *Conn, code: u32) ProcessResult {
    lockWrite(conn);
    defer unlockWrite(conn);
    http2_frames.writeGoaway(conn.client_w, conn.highest_stream, code) catch return .CLOSED;
    conn.client_w.flush() catch return .CLOSED;

    return .CLOSED;
}

/// Largest DATA payload one send may carry: the peer's advertised frame
/// size, capped by zixer's own staging.
fn effectiveMaxFrame(conn: *const Conn) usize {
    return @min(conn.peer_max_frame, http2_frames.MAX_PAYLOAD);
}

fn lockWrite(conn: *Conn) void {
    while (conn.write_lock.swap(true, .acquire)) std.atomic.spinLoopHint();
}

fn unlockWrite(conn: *Conn) void {
    conn.write_lock.store(false, .release);
}

/// The read bound for one upstream leg of this site.
fn upstreamGate(conn: *Conn, conn_up: upstream_conn.UpstreamConn) upstream_deadline.Gate {
    return .{ .stream = conn_up.stream, .budget_ms = conn.proxy.upstream_timeout_ms };
}

fn nowMs(io: std.Io) i64 {
    return std.Io.Clock.Timestamp.now(io, .real).raw.toMilliseconds();
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //

const testing = std.testing;
const site_cfg = @import("site_cfg.zig");

fn edgeStream(handle: std.posix.fd_t) std.Io.net.Stream {
    return .{ .socket = .{ .handle = handle, .address = .{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = 40012 } } } };
}

fn spawnServeConn(proxy: *const http1_proxy.Proxy, stream: std.Io.net.Stream) !std.Thread {
    return std.Thread.spawn(.{}, serveConnThread, .{ proxy, stream });
}

fn serveConnThread(proxy: *const http1_proxy.Proxy, stream: std.Io.net.Stream) void {
    serveConn(proxy, stream);
}

/// h2 test client over one socketpair end: buffered stream interfaces
/// plus its own frame and hpack state.
const TestClient = struct {
    io: std.Io,
    stream: std.Io.net.Stream,
    read_buf: [16 * 1024]u8 = undefined,
    write_buf: [8 * 1024]u8 = undefined,
    reader: std.Io.net.Stream.Reader = undefined,
    writer: std.Io.net.Stream.Writer = undefined,
    payload_buf: [http2_frames.MAX_PAYLOAD]u8 = undefined,
    decoder: Http2.HpackDecoder = undefined,
    decoded: [32]Http2.Header = undefined,
    scratch: [8 * 1024]u8 = undefined,
    head_end_stream: bool = false,

    /// Bind the interfaces, run the connection preface both ways.
    fn start(client: *TestClient) !void {
        client.reader = client.stream.reader(client.io, &client.read_buf);
        client.writer = client.stream.writer(client.io, &client.write_buf);
        client.decoder = Http2.HpackDecoder.init();

        try client.writer.interface.writeAll(Http2.PREFACE);
        try http2_frames.writeSettings(&client.writer.interface, &.{});
        try client.writer.interface.flush();

        const server_settings = try client.nextFrame();
        try testing.expectEqual(@as(u8, Http2.FRAME_TYPE_SETTINGS), server_settings.head.frame_type);
        try testing.expectEqual(@as(u8, 0), server_settings.head.flags & Http2.FLAG_ACK);

        try http2_frames.writeSettingsAck(&client.writer.interface);
        try client.writer.interface.flush();

        const settings_ack = try client.nextFrame();
        try testing.expectEqual(@as(u8, Http2.FRAME_TYPE_SETTINGS), settings_ack.head.frame_type);
        try testing.expectEqual(Http2.FLAG_ACK, settings_ack.head.flags & Http2.FLAG_ACK);
    }

    fn nextFrame(client: *TestClient) !http2_frames.Frame {
        return http2_frames.readFrame(&client.reader.interface, &client.payload_buf);
    }

    fn sendHeaders(client: *TestClient, stream_id: u31, headers: []const Http2.Header, end_stream: bool) !void {
        var block_buf: [2048]u8 = undefined;
        var encoder = Http2.HpackEncoder.init(&block_buf);
        for (headers) |entry| try encoder.writeHeader(entry.name, entry.value);

        try http2_frames.writeHeaderBlock(&client.writer.interface, stream_id, encoder.encoded(), end_stream, http2_frames.MAX_PAYLOAD);
        try client.writer.interface.flush();
    }

    fn sendData(client: *TestClient, stream_id: u31, bytes: []const u8, end_stream: bool) !void {
        const flags: u8 = if (end_stream) Http2.FLAG_END_STREAM else 0;
        try http2_frames.writeFrame(&client.writer.interface, Http2.FRAME_TYPE_DATA, flags, stream_id, bytes);
        try client.writer.interface.flush();
    }

    fn sendPing(client: *TestClient) !void {
        try http2_frames.writeFrame(&client.writer.interface, Http2.FRAME_TYPE_PING, 0, 0, "pingpong");
        try client.writer.interface.flush();
    }

    /// Read frames until this stream's response head arrives, decode it
    /// into client.decoded. Grants and acks on the way are skipped.
    fn readHead(client: *TestClient, stream_id: u31) !usize {
        while (true) {
            const frame = try client.nextFrame();
            if (frame.head.frame_type != Http2.FRAME_TYPE_HEADERS or frame.head.stream_id != stream_id) {
                if (frame.head.frame_type == Http2.FRAME_TYPE_RST_STREAM or
                    frame.head.frame_type == Http2.FRAME_TYPE_GOAWAY) return error.TestUnexpectedResult;
                continue;
            }

            try testing.expect((frame.head.flags & Http2.FLAG_END_HEADERS) != 0);
            client.head_end_stream = (frame.head.flags & Http2.FLAG_END_STREAM) != 0;
            const fragment = try http2_frames.headersFragment(&frame);

            return try client.decoder.decode(fragment, &client.decoded, &client.scratch);
        }
    }

    fn headerValue(client: *TestClient, count: usize, name: []const u8) ?[]const u8 {
        for (client.decoded[0..count]) |entry| {
            if (std.mem.eql(u8, entry.name, name)) return entry.value;
        }

        return null;
    }

    /// Collect DATA for one stream until END_STREAM, granting the flow
    /// credit back as a well-behaved peer.
    fn collectBody(client: *TestClient, stream_id: u31, out: []u8) !usize {
        var total: usize = 0;
        while (true) {
            const frame = try client.nextFrame();
            if (frame.head.frame_type != Http2.FRAME_TYPE_DATA or frame.head.stream_id != stream_id) {
                if (frame.head.frame_type == Http2.FRAME_TYPE_RST_STREAM or
                    frame.head.frame_type == Http2.FRAME_TYPE_GOAWAY) return error.TestUnexpectedResult;
                continue;
            }

            const data = try http2_frames.dataPayload(&frame);
            if (total + data.len > out.len) return error.TestUnexpectedResult;
            @memcpy(out[total..][0..data.len], data);
            total += data.len;

            if (frame.head.length > 0) {
                try http2_frames.writeWindowUpdate(&client.writer.interface, 0, @intCast(frame.head.length));
                try http2_frames.writeWindowUpdate(&client.writer.interface, stream_id, @intCast(frame.head.length));
                try client.writer.interface.flush();
            }

            if ((frame.head.flags & Http2.FLAG_END_STREAM) != 0) return total;
        }
    }
};

/// h1 upstream fake for the edge tests: accepts loopback conns, answers
/// per mode, records the first head and body it saw.
const FakeBackend = struct {
    io: std.Io,
    port: u16,
    request_quota: usize,
    mode: enum { ECHO, BIG, WS, PLAIN_403 },
    seen_head: [8192]u8 = undefined,
    seen_len: usize = 0,
    seen_body: [4096]u8 = undefined,
    seen_body_len: usize = 0,
    conns_accepted: usize = 0,
    ready: std.atomic.Value(bool) = .init(false),

    fn serve(fake: *FakeBackend) void {
        const io = fake.io;

        const addr = std.Io.net.IpAddress.parse("127.0.0.1", fake.port) catch return;
        var server = addr.listen(io, .{ .reuse_address = true, .kernel_backlog = 8 }) catch return;
        defer server.deinit(io);
        fake.ready.store(true, .release);

        var answered: usize = 0;
        while (answered < fake.request_quota) {
            const stream = server.accept(io) catch return;
            fake.conns_accepted += 1;

            var read_buf: [8192]u8 = undefined;
            var write_buf: [8192]u8 = undefined;
            var reader = stream.reader(io, &read_buf);
            var writer = stream.writer(io, &write_buf);

            conn: while (answered < fake.request_quota) {
                var head_buf: [8192]u8 = undefined;
                const head = http1_head.readHead(&reader.interface, &head_buf) catch break :conn;
                const request = http1_head.parseRequest(head) catch break :conn;

                if (fake.seen_len == 0) {
                    @memcpy(fake.seen_head[0..head.len], head);
                    fake.seen_len = head.len;
                }
                fake.readBody(&reader.interface, &request) catch break :conn;

                fake.answer(&writer.interface, &reader.interface) catch break :conn;
                answered += 1;
                if (fake.mode == .WS) break :conn;
            }

            stream.close(io);
        }
    }

    fn readBody(fake: *FakeBackend, src: *std.Io.Reader, request: *const http1_head.RequestHead) !void {
        switch (request.framing) {
            .none, .until_close => {},
            .content_length => |len| {
                const want: usize = @intCast(len);
                var got: usize = 0;
                while (got < want) {
                    const step = try src.readSliceShort(fake.seen_body[got..want]);
                    if (step == 0) return error.EndOfStream;
                    got += step;
                }
                fake.seen_body_len = want;
            },
            .chunked => {
                var line_buf: [64]u8 = undefined;
                while (true) {
                    const size_line = try readLine(src, &line_buf);
                    const size = try std.fmt.parseInt(usize, size_line, 16);
                    if (size == 0) {
                        _ = try readLine(src, &line_buf);
                        return;
                    }

                    var got: usize = 0;
                    while (got < size) {
                        const step = try src.readSliceShort(fake.seen_body[fake.seen_body_len + got ..][0 .. size - got]);
                        if (step == 0) return error.EndOfStream;
                        got += step;
                    }
                    fake.seen_body_len += size;
                    _ = try readLine(src, &line_buf);
                }
            },
        }
    }

    fn answer(fake: *FakeBackend, out: *std.Io.Writer, src: *std.Io.Reader) !void {
        switch (fake.mode) {
            .ECHO => {
                try out.print(
                    "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nKeep-Alive: timeout=5\r\nContent-Length: {d}\r\n\r\necho:{s}",
                    .{ fake.seen_body_len + 5, fake.seen_body[0..fake.seen_body_len] },
                );
                try out.flush();
            },
            .BIG => {
                try out.print("HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: {d}\r\n\r\n", .{BIG_BODY_LEN});
                var block: [4096]u8 = undefined;
                @memset(&block, 'b');
                var sent: usize = 0;
                while (sent < BIG_BODY_LEN) {
                    const take = @min(BIG_BODY_LEN - sent, block.len);
                    try out.writeAll(block[0..take]);
                    sent += take;
                }
                try out.flush();
            },
            .WS => {
                const key = headOf(fake, "sec-websocket-key") orelse return error.TestUnexpectedResult;
                var accept: [28]u8 = undefined;
                wsAccept(key, &accept);
                try out.print(
                    "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {s}\r\n\r\n",
                    .{&accept},
                );
                try out.flush();

                // raw echo until the tunnel half-closes.
                while (true) {
                    const burst = src.peekGreedy(1) catch return;
                    try out.writeAll(burst);
                    try out.flush();
                    src.toss(burst.len);
                }
            },
            .PLAIN_403 => {
                try out.writeAll("HTTP/1.1 403 Forbidden\r\nContent-Length: 2\r\n\r\nno");
                try out.flush();
            },
        }
    }

    /// The value of one header in the recorded head, null when absent.
    fn headOf(fake: *FakeBackend, name: []const u8) ?[]const u8 {
        const request = http1_head.parseRequest(fake.seen_head[0..fake.seen_len]) catch return null;
        for (request.headers[0..request.header_count]) |entry| {
            if (std.ascii.eqlIgnoreCase(entry.name, name)) return entry.value;
        }

        return null;
    }
};

const BIG_BODY_LEN: usize = 100000;

/// rfc 6455 4.2.2 accept answer for a handshake key.
fn wsAccept(key: []const u8, out: *[28]u8) void {
    var sha = std.crypto.hash.Sha1.init(.{});
    sha.update(key);
    sha.update(WS_ACCEPT_GUID);
    var digest: [20]u8 = undefined;
    sha.final(&digest);

    _ = std.base64.standard.Encoder.encode(out, &digest);
}

fn waitBackend(io: std.Io, fake: *FakeBackend) !void {
    var tries: usize = 0;
    while (tries < 100 and !fake.ready.load(.acquire)) : (tries += 1) {
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(10), .awake) catch {};
    }

    try testing.expect(tries < 100);
}

fn openEdgePair(fds: *[2]std.posix.fd_t) !void {
    try testing.expectEqual(@as(usize, 0), std.os.linux.socketpair(std.os.linux.AF.UNIX, std.os.linux.SOCK.STREAM, 0, fds));
}

test "zix zixer: http2 edge, preface sniff serves h2 and falls back to h1" {
    if (comptime @import("builtin").os.tag != .linux) return error.SkipZigTest;

    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const proxy = http1_proxy.Proxy{ .io = io };

    // an h1 request on the http2 site runs the h1 loop.
    var h1_fds: [2]std.posix.fd_t = undefined;
    try openEdgePair(&h1_fds);
    const h1_thread = try spawnServeConn(&proxy, edgeStream(h1_fds[0]));
    const h1_client = edgeStream(h1_fds[1]);

    var h1_write_buf: [256]u8 = undefined;
    var h1_writer = h1_client.writer(io, &h1_write_buf);
    try h1_writer.interface.writeAll("GET / HTTP/1.1\r\nHost: t\r\nConnection: close\r\n\r\n");
    try h1_writer.interface.flush();

    var h1_reply: [512]u8 = undefined;
    var h1_read_buf: [512]u8 = undefined;
    var h1_reader = h1_client.reader(io, &h1_read_buf);
    var h1_len: usize = 0;
    while (h1_len < h1_reply.len) {
        const got = h1_reader.interface.readSliceShort(h1_reply[h1_len .. h1_len + 1]) catch break;
        if (got == 0) break;
        h1_len += got;
    }
    try testing.expect(std.mem.startsWith(u8, h1_reply[0..h1_len], "HTTP/1.1 404 "));
    h1_client.close(io);
    h1_thread.join();

    // the h2 preface reaches the frame loop: settings come back.
    var h2_fds: [2]std.posix.fd_t = undefined;
    try openEdgePair(&h2_fds);
    const h2_thread = try spawnServeConn(&proxy, edgeStream(h2_fds[0]));

    var client = TestClient{ .io = io, .stream = edgeStream(h2_fds[1]) };
    try client.start();

    client.stream.close(io);
    h2_thread.join();
}

test "zix zixer: http2 edge, get proxies end to end and reuses the upstream conn" {
    if (comptime @import("builtin").os.tag != .linux) return error.SkipZigTest;

    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var fake = FakeBackend{ .io = io, .port = 39857, .request_quota = 2, .mode = .ECHO };
    const fake_thread = try std.Thread.spawn(.{}, FakeBackend.serve, .{&fake});
    try waitBackend(io, &fake);

    const upstreams = [_]site_cfg.Upstream{.{ .host = "127.0.0.1", .port = 39857 }};
    var pool = try upstream_pool.Pool.init(testing.allocator, &upstreams, upstream_pool.DEFAULT_COOLDOWN_MS);
    defer pool.deinit(testing.allocator);
    var idle = try upstream_conn.IdleCache.init(testing.allocator, 1);
    defer idle.deinit(testing.allocator, io);
    const proxy = http1_proxy.Proxy{ .io = io, .pool = &pool, .idle = &idle };

    var fds: [2]std.posix.fd_t = undefined;
    try openEdgePair(&fds);
    const edge_thread = try spawnServeConn(&proxy, edgeStream(fds[0]));

    var client = TestClient{ .io = io, .stream = edgeStream(fds[1]) };
    try client.start();

    const get_headers = [_]Http2.Header{
        .{ .name = ":method", .value = "GET" },
        .{ .name = ":scheme", .value = "http" },
        .{ .name = ":path", .value = "/api/one" },
        .{ .name = ":authority", .value = "app.example" },
        .{ .name = "accept", .value = "*/*" },
    };
    try client.sendHeaders(1, &get_headers, true);

    const count = try client.readHead(1);
    try testing.expectEqualStrings("200", client.headerValue(count, ":status").?);
    try testing.expectEqualStrings("1.1 zixer", client.headerValue(count, "via").?);
    try testing.expectEqualStrings("5", client.headerValue(count, "content-length").?);
    try testing.expect(client.headerValue(count, "keep-alive") == null);
    try testing.expect(!client.head_end_stream);

    var body: [64]u8 = undefined;
    try testing.expectEqualStrings("echo:", body[0..try client.collectBody(1, &body)]);

    // a ping between exchanges answers.
    try client.sendPing();
    const pong = try client.nextFrame();
    try testing.expectEqual(@as(u8, Http2.FRAME_TYPE_PING), pong.head.frame_type);
    try testing.expectEqual(Http2.FLAG_ACK, pong.head.flags & Http2.FLAG_ACK);
    try testing.expectEqualStrings("pingpong", pong.payload);

    // the second stream reuses the idle upstream conn.
    try client.sendHeaders(3, &get_headers, true);
    const second_count = try client.readHead(3);
    try testing.expectEqualStrings("200", client.headerValue(second_count, ":status").?);
    _ = try client.collectBody(3, &body);

    // the rebuilt upstream head carried the intermediary fields.
    const seen = fake.seen_head[0..fake.seen_len];
    try testing.expect(std.mem.startsWith(u8, seen, "GET /api/one HTTP/1.1\r\n"));
    try testing.expect(std.mem.indexOf(u8, seen, "Host: app.example\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, seen, "Via: 1.1 zixer\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, seen, "Forwarded: for=") != null);

    try testing.expectEqual(@as(usize, 1), fake.conns_accepted);

    client.stream.close(io);
    edge_thread.join();
    fake_thread.join();
}

test "zix zixer: http2 edge, post with content length reaches the upstream intact" {
    if (comptime @import("builtin").os.tag != .linux) return error.SkipZigTest;

    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var fake = FakeBackend{ .io = io, .port = 39858, .request_quota = 1, .mode = .ECHO };
    const fake_thread = try std.Thread.spawn(.{}, FakeBackend.serve, .{&fake});
    try waitBackend(io, &fake);

    const upstreams = [_]site_cfg.Upstream{.{ .host = "127.0.0.1", .port = 39858 }};
    var pool = try upstream_pool.Pool.init(testing.allocator, &upstreams, upstream_pool.DEFAULT_COOLDOWN_MS);
    defer pool.deinit(testing.allocator);
    var idle = try upstream_conn.IdleCache.init(testing.allocator, 1);
    defer idle.deinit(testing.allocator, io);
    const proxy = http1_proxy.Proxy{ .io = io, .pool = &pool, .idle = &idle };

    var fds: [2]std.posix.fd_t = undefined;
    try openEdgePair(&fds);
    const edge_thread = try spawnServeConn(&proxy, edgeStream(fds[0]));

    var client = TestClient{ .io = io, .stream = edgeStream(fds[1]) };
    try client.start();

    const post_headers = [_]Http2.Header{
        .{ .name = ":method", .value = "POST" },
        .{ .name = ":scheme", .value = "http" },
        .{ .name = ":path", .value = "/submit" },
        .{ .name = ":authority", .value = "app.example" },
        .{ .name = "content-length", .value = "9" },
    };
    try client.sendHeaders(1, &post_headers, false);
    try client.sendData(1, "ping-", false);
    try client.sendData(1, "body", true);

    const count = try client.readHead(1);
    try testing.expectEqualStrings("200", client.headerValue(count, ":status").?);

    var body: [64]u8 = undefined;
    try testing.expectEqualStrings("echo:ping-body", body[0..try client.collectBody(1, &body)]);

    try testing.expectEqualStrings("ping-body", fake.seen_body[0..fake.seen_body_len]);
    const seen = fake.seen_head[0..fake.seen_len];
    try testing.expect(std.mem.indexOf(u8, seen, "Content-Length: 9\r\n") != null);

    client.stream.close(io);
    edge_thread.join();
    fake_thread.join();
}

test "zix zixer: http2 edge, post without length re-frames as chunked" {
    if (comptime @import("builtin").os.tag != .linux) return error.SkipZigTest;

    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var fake = FakeBackend{ .io = io, .port = 39868, .request_quota = 1, .mode = .ECHO };
    const fake_thread = try std.Thread.spawn(.{}, FakeBackend.serve, .{&fake});
    try waitBackend(io, &fake);

    const upstreams = [_]site_cfg.Upstream{.{ .host = "127.0.0.1", .port = 39868 }};
    var pool = try upstream_pool.Pool.init(testing.allocator, &upstreams, upstream_pool.DEFAULT_COOLDOWN_MS);
    defer pool.deinit(testing.allocator);
    var idle = try upstream_conn.IdleCache.init(testing.allocator, 1);
    defer idle.deinit(testing.allocator, io);
    const proxy = http1_proxy.Proxy{ .io = io, .pool = &pool, .idle = &idle };

    var fds: [2]std.posix.fd_t = undefined;
    try openEdgePair(&fds);
    const edge_thread = try spawnServeConn(&proxy, edgeStream(fds[0]));

    var client = TestClient{ .io = io, .stream = edgeStream(fds[1]) };
    try client.start();

    const post_headers = [_]Http2.Header{
        .{ .name = ":method", .value = "POST" },
        .{ .name = ":scheme", .value = "http" },
        .{ .name = ":path", .value = "/stream" },
        .{ .name = ":authority", .value = "app.example" },
    };
    try client.sendHeaders(1, &post_headers, false);
    try client.sendData(1, "part-one", false);
    try client.sendData(1, "two", true);

    const count = try client.readHead(1);
    try testing.expectEqualStrings("200", client.headerValue(count, ":status").?);

    var body: [64]u8 = undefined;
    _ = try client.collectBody(1, &body);

    try testing.expectEqualStrings("part-onetwo", fake.seen_body[0..fake.seen_body_len]);
    const seen = fake.seen_head[0..fake.seen_len];
    try testing.expect(std.mem.indexOf(u8, seen, "Transfer-Encoding: chunked\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, seen, "Content-Length") == null);

    client.stream.close(io);
    edge_thread.join();
    fake_thread.join();
}

test "zix zixer: http2 edge, queued streams answer in order and pick per stream" {
    if (comptime @import("builtin").os.tag != .linux) return error.SkipZigTest;

    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var fake_a = FakeBackend{ .io = io, .port = 39850, .request_quota = 1, .mode = .ECHO };
    var fake_b = FakeBackend{ .io = io, .port = 39851, .request_quota = 1, .mode = .ECHO };
    const thread_a = try std.Thread.spawn(.{}, FakeBackend.serve, .{&fake_a});
    const thread_b = try std.Thread.spawn(.{}, FakeBackend.serve, .{&fake_b});
    try waitBackend(io, &fake_a);
    try waitBackend(io, &fake_b);

    const upstreams = [_]site_cfg.Upstream{
        .{ .host = "127.0.0.1", .port = 39850 },
        .{ .host = "127.0.0.1", .port = 39851 },
    };
    var pool = try upstream_pool.Pool.init(testing.allocator, &upstreams, upstream_pool.DEFAULT_COOLDOWN_MS);
    defer pool.deinit(testing.allocator);
    var idle = try upstream_conn.IdleCache.init(testing.allocator, 2);
    defer idle.deinit(testing.allocator, io);
    const proxy = http1_proxy.Proxy{ .io = io, .pool = &pool, .idle = &idle };

    var fds: [2]std.posix.fd_t = undefined;
    try openEdgePair(&fds);
    const edge_thread = try spawnServeConn(&proxy, edgeStream(fds[0]));

    var client = TestClient{ .io = io, .stream = edgeStream(fds[1]) };
    try client.start();

    // both streams land before either response is read: the second one
    // queues while the first serves.
    const get_headers = [_]Http2.Header{
        .{ .name = ":method", .value = "GET" },
        .{ .name = ":scheme", .value = "http" },
        .{ .name = ":path", .value = "/burst" },
        .{ .name = ":authority", .value = "app.example" },
    };
    try client.sendHeaders(1, &get_headers, true);
    try client.sendHeaders(3, &get_headers, true);

    var body: [64]u8 = undefined;
    const first_count = try client.readHead(1);
    try testing.expectEqualStrings("200", client.headerValue(first_count, ":status").?);
    _ = try client.collectBody(1, &body);

    const second_count = try client.readHead(3);
    try testing.expectEqualStrings("200", client.headerValue(second_count, ":status").?);
    _ = try client.collectBody(3, &body);

    // per-stream pick: round-robin sent one exchange to each upstream.
    try testing.expectEqual(@as(usize, 1), fake_a.conns_accepted);
    try testing.expectEqual(@as(usize, 1), fake_b.conns_accepted);

    client.stream.close(io);
    edge_thread.join();
    thread_a.join();
    thread_b.join();
}

test "zix zixer: http2 edge, big body crosses the flow windows complete" {
    if (comptime @import("builtin").os.tag != .linux) return error.SkipZigTest;

    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var fake = FakeBackend{ .io = io, .port = 39856, .request_quota = 1, .mode = .BIG };
    const fake_thread = try std.Thread.spawn(.{}, FakeBackend.serve, .{&fake});
    try waitBackend(io, &fake);

    const upstreams = [_]site_cfg.Upstream{.{ .host = "127.0.0.1", .port = 39856 }};
    var pool = try upstream_pool.Pool.init(testing.allocator, &upstreams, upstream_pool.DEFAULT_COOLDOWN_MS);
    defer pool.deinit(testing.allocator);
    var idle = try upstream_conn.IdleCache.init(testing.allocator, 1);
    defer idle.deinit(testing.allocator, io);
    const proxy = http1_proxy.Proxy{ .io = io, .pool = &pool, .idle = &idle };

    var fds: [2]std.posix.fd_t = undefined;
    try openEdgePair(&fds);
    const edge_thread = try spawnServeConn(&proxy, edgeStream(fds[0]));

    var client = TestClient{ .io = io, .stream = edgeStream(fds[1]) };
    try client.start();

    const get_headers = [_]Http2.Header{
        .{ .name = ":method", .value = "GET" },
        .{ .name = ":scheme", .value = "http" },
        .{ .name = ":path", .value = "/big" },
        .{ .name = ":authority", .value = "app.example" },
    };
    try client.sendHeaders(1, &get_headers, true);

    const count = try client.readHead(1);
    try testing.expectEqualStrings("200", client.headerValue(count, ":status").?);

    // The body outsizes both 65535 windows: it only completes because
    // collectBody grants credit back, and every frame stays inside the
    // default max frame size.
    var total: usize = 0;
    var frames: usize = 0;
    while (true) {
        const frame = try client.nextFrame();
        if (frame.head.frame_type != Http2.FRAME_TYPE_DATA or frame.head.stream_id != 1) continue;

        try testing.expect(frame.head.length <= Http2.DEFAULT_MAX_FRAME_SIZE);
        const data = try http2_frames.dataPayload(&frame);
        for (data) |byte| try testing.expectEqual(@as(u8, 'b'), byte);
        total += data.len;
        frames += 1;

        if (frame.head.length > 0) {
            try http2_frames.writeWindowUpdate(&client.writer.interface, 0, @intCast(frame.head.length));
            try http2_frames.writeWindowUpdate(&client.writer.interface, 1, @intCast(frame.head.length));
            try client.writer.interface.flush();
        }

        if ((frame.head.flags & Http2.FLAG_END_STREAM) != 0) break;
    }
    try testing.expectEqual(BIG_BODY_LEN, total);
    try testing.expect(frames >= BIG_BODY_LEN / Http2.DEFAULT_MAX_FRAME_SIZE);

    client.stream.close(io);
    edge_thread.join();
    fake_thread.join();
}

test "zix zixer: http2 edge, extended connect tunnels through the h1 upgrade" {
    if (comptime @import("builtin").os.tag != .linux) return error.SkipZigTest;

    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var fake = FakeBackend{ .io = io, .port = 39852, .request_quota = 1, .mode = .WS };
    const fake_thread = try std.Thread.spawn(.{}, FakeBackend.serve, .{&fake});
    try waitBackend(io, &fake);

    const upstreams = [_]site_cfg.Upstream{.{ .host = "127.0.0.1", .port = 39852 }};
    var pool = try upstream_pool.Pool.init(testing.allocator, &upstreams, upstream_pool.DEFAULT_COOLDOWN_MS);
    defer pool.deinit(testing.allocator);
    var idle = try upstream_conn.IdleCache.init(testing.allocator, 1);
    defer idle.deinit(testing.allocator, io);
    const proxy = http1_proxy.Proxy{ .io = io, .pool = &pool, .idle = &idle };

    var fds: [2]std.posix.fd_t = undefined;
    try openEdgePair(&fds);
    const edge_thread = try spawnServeConn(&proxy, edgeStream(fds[0]));

    var client = TestClient{ .io = io, .stream = edgeStream(fds[1]) };
    try client.start();

    const connect_headers = [_]Http2.Header{
        .{ .name = ":method", .value = "CONNECT" },
        .{ .name = ":protocol", .value = "websocket" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":path", .value = "/chat" },
        .{ .name = ":authority", .value = "app.example" },
        .{ .name = "sec-websocket-version", .value = "13" },
    };
    try client.sendHeaders(1, &connect_headers, false);

    const count = try client.readHead(1);
    try testing.expectEqualStrings("200", client.headerValue(count, ":status").?);
    try testing.expectEqualStrings("1.1 zixer", client.headerValue(count, "via").?);
    try testing.expect(client.headerValue(count, "sec-websocket-accept") == null);
    try testing.expect(!client.head_end_stream);

    // raw websocket bytes echo through the pinned tunnel.
    try client.sendData(1, "frame-one", false);
    var echoed: [9]u8 = undefined;
    var echo_len: usize = 0;
    while (echo_len < echoed.len) {
        const frame = try client.nextFrame();
        if (frame.head.frame_type != Http2.FRAME_TYPE_DATA or frame.head.stream_id != 1) continue;

        const data = try http2_frames.dataPayload(&frame);
        @memcpy(echoed[echo_len..][0..data.len], data);
        echo_len += data.len;
    }
    try testing.expectEqualStrings("frame-one", &echoed);

    // the h1 leg carried zixer's own generated key and the upgrade pair.
    const seen = fake.seen_head[0..fake.seen_len];
    try testing.expect(std.mem.startsWith(u8, seen, "GET /chat HTTP/1.1\r\n"));
    try testing.expect(std.mem.indexOf(u8, seen, "Sec-WebSocket-Key: ") != null);
    try testing.expect(std.mem.indexOf(u8, seen, "Connection: Upgrade\r\nUpgrade: websocket\r\n") != null);

    // client end: the edge closes with the tunnel, a goaway on the way out.
    try client.sendData(1, "", true);
    var saw_goaway = false;
    while (client.nextFrame()) |frame| {
        if (frame.head.frame_type == Http2.FRAME_TYPE_GOAWAY) saw_goaway = true;
    } else |_| {}
    try testing.expect(saw_goaway);

    client.stream.close(io);
    edge_thread.join();
    fake_thread.join();
}

test "zix zixer: http2 edge, refused upgrade relays the plain response" {
    if (comptime @import("builtin").os.tag != .linux) return error.SkipZigTest;

    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var fake = FakeBackend{ .io = io, .port = 39853, .request_quota = 1, .mode = .PLAIN_403 };
    const fake_thread = try std.Thread.spawn(.{}, FakeBackend.serve, .{&fake});
    try waitBackend(io, &fake);

    const upstreams = [_]site_cfg.Upstream{.{ .host = "127.0.0.1", .port = 39853 }};
    var pool = try upstream_pool.Pool.init(testing.allocator, &upstreams, upstream_pool.DEFAULT_COOLDOWN_MS);
    defer pool.deinit(testing.allocator);
    var idle = try upstream_conn.IdleCache.init(testing.allocator, 1);
    defer idle.deinit(testing.allocator, io);
    const proxy = http1_proxy.Proxy{ .io = io, .pool = &pool, .idle = &idle };

    var fds: [2]std.posix.fd_t = undefined;
    try openEdgePair(&fds);
    const edge_thread = try spawnServeConn(&proxy, edgeStream(fds[0]));

    var client = TestClient{ .io = io, .stream = edgeStream(fds[1]) };
    try client.start();

    const connect_headers = [_]Http2.Header{
        .{ .name = ":method", .value = "CONNECT" },
        .{ .name = ":protocol", .value = "websocket" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":path", .value = "/chat" },
        .{ .name = ":authority", .value = "app.example" },
        .{ .name = "sec-websocket-version", .value = "13" },
    };
    try client.sendHeaders(1, &connect_headers, false);

    const count = try client.readHead(1);
    try testing.expectEqualStrings("403", client.headerValue(count, ":status").?);

    var body: [16]u8 = undefined;
    try testing.expectEqualStrings("no", body[0..try client.collectBody(1, &body)]);

    // the connection lives on after the refusal.
    try client.sendPing();
    const pong = try client.nextFrame();
    try testing.expectEqual(@as(u8, Http2.FRAME_TYPE_PING), pong.head.frame_type);
    try testing.expectEqual(Http2.FLAG_ACK, pong.head.flags & Http2.FLAG_ACK);

    client.stream.close(io);
    edge_thread.join();
    fake_thread.join();
}

test "zix zixer: http2 edge, static plane serves files head and misses" {
    if (comptime @import("builtin").os.tag != .linux) return error.SkipZigTest;

    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    tmp.dir.writeFile(testing.io, .{ .sub_path = "page.html", .data = "<h1>h2 static</h1>" }) catch @panic("fixture write failed");

    var root_buf: [128]u8 = undefined;
    const root = std.fmt.bufPrint(&root_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path}) catch unreachable;

    const proxy = http1_proxy.Proxy{ .io = io, .static = .{
        .public_dir = root,
        .public_prefix = null,
        .spa_fallback = null,
    } };

    var fds: [2]std.posix.fd_t = undefined;
    try openEdgePair(&fds);
    const edge_thread = try spawnServeConn(&proxy, edgeStream(fds[0]));

    var client = TestClient{ .io = io, .stream = edgeStream(fds[1]) };
    try client.start();

    const get_headers = [_]Http2.Header{
        .{ .name = ":method", .value = "GET" },
        .{ .name = ":scheme", .value = "http" },
        .{ .name = ":path", .value = "/page.html" },
        .{ .name = ":authority", .value = "site.test" },
    };
    try client.sendHeaders(1, &get_headers, true);

    const count = try client.readHead(1);
    try testing.expectEqualStrings("200", client.headerValue(count, ":status").?);
    try testing.expectEqualStrings("text/html", client.headerValue(count, "content-type").?);
    try testing.expectEqualStrings("18", client.headerValue(count, "content-length").?);
    try testing.expectEqualStrings("Accept-Encoding", client.headerValue(count, "vary").?);

    var body: [64]u8 = undefined;
    try testing.expectEqualStrings("<h1>h2 static</h1>", body[0..try client.collectBody(1, &body)]);

    // HEAD answers the same head bodyless, END_STREAM on the headers.
    const head_headers = [_]Http2.Header{
        .{ .name = ":method", .value = "HEAD" },
        .{ .name = ":scheme", .value = "http" },
        .{ .name = ":path", .value = "/page.html" },
        .{ .name = ":authority", .value = "site.test" },
    };
    try client.sendHeaders(3, &head_headers, true);
    const head_count = try client.readHead(3);
    try testing.expectEqualStrings("200", client.headerValue(head_count, ":status").?);
    try testing.expect(client.head_end_stream);

    // a miss on the static-only site answers a local 404.
    const miss_headers = [_]Http2.Header{
        .{ .name = ":method", .value = "GET" },
        .{ .name = ":scheme", .value = "http" },
        .{ .name = ":path", .value = "/absent.html" },
        .{ .name = ":authority", .value = "site.test" },
    };
    try client.sendHeaders(5, &miss_headers, true);
    const miss_count = try client.readHead(5);
    try testing.expectEqualStrings("404", client.headerValue(miss_count, ":status").?);
    try testing.expect(client.head_end_stream);

    client.stream.close(io);
    edge_thread.join();
}

test "zix zixer: http2 edge, tls certificate gate answers 421 on a foreign authority" {
    if (comptime @import("builtin").os.tag != .linux) return error.SkipZigTest;

    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const cert_pem = try std.Io.Dir.cwd().readFileAlloc(io, "examples/certs/ecdsa_p256_cert.pem", testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(cert_pem);
    var der_buf: [4096]u8 = undefined;
    const cert_der = try zix.Tls.pemToDer(&der_buf, cert_pem);

    const proxy = http1_proxy.Proxy{ .io = io, .tls_cert_der = cert_der };

    var fds: [2]std.posix.fd_t = undefined;
    try openEdgePair(&fds);
    const edge_thread = try spawnServeConn(&proxy, edgeStream(fds[0]));

    var client = TestClient{ .io = io, .stream = edgeStream(fds[1]) };
    try client.start();

    const foreign_headers = [_]Http2.Header{
        .{ .name = ":method", .value = "GET" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":path", .value = "/" },
        .{ .name = ":authority", .value = "evil.example" },
    };
    try client.sendHeaders(1, &foreign_headers, true);
    const foreign_count = try client.readHead(1);
    try testing.expectEqualStrings("421", client.headerValue(foreign_count, ":status").?);
    try testing.expect(client.head_end_stream);

    // the certificate's own SAN passes the gate and reaches the next
    // plane (here: the local 404 of a site with no planes).
    const own_headers = [_]Http2.Header{
        .{ .name = ":method", .value = "GET" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":path", .value = "/" },
        .{ .name = ":authority", .value = "localhost:443" },
    };
    try client.sendHeaders(3, &own_headers, true);
    const own_count = try client.readHead(3);
    try testing.expectEqualStrings("404", client.headerValue(own_count, ":status").?);

    client.stream.close(io);
    edge_thread.join();
}

test "zix zixer: http2 edge, malformed stream resets and the connection survives" {
    if (comptime @import("builtin").os.tag != .linux) return error.SkipZigTest;

    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const proxy = http1_proxy.Proxy{ .io = io };

    var fds: [2]std.posix.fd_t = undefined;
    try openEdgePair(&fds);
    const edge_thread = try spawnServeConn(&proxy, edgeStream(fds[0]));

    var client = TestClient{ .io = io, .stream = edgeStream(fds[1]) };
    try client.start();

    // an uppercase field name is malformed in h2 (rfc 9113 8.2).
    const malformed_headers = [_]Http2.Header{
        .{ .name = ":method", .value = "GET" },
        .{ .name = ":scheme", .value = "http" },
        .{ .name = ":path", .value = "/" },
        .{ .name = ":authority", .value = "t" },
        .{ .name = "X-Bad", .value = "1" },
    };
    try client.sendHeaders(1, &malformed_headers, true);

    const reset = try client.nextFrame();
    try testing.expectEqual(@as(u8, Http2.FRAME_TYPE_RST_STREAM), reset.head.frame_type);
    try testing.expectEqual(@as(u31, 1), reset.head.stream_id);
    try testing.expectEqual(Http2.ERR_PROTOCOL_ERROR, std.mem.readInt(u32, reset.payload[0..4], .big));

    // the stream died, the connection did not.
    try client.sendPing();
    const pong = try client.nextFrame();
    try testing.expectEqual(@as(u8, Http2.FRAME_TYPE_PING), pong.head.frame_type);
    try testing.expectEqual(Http2.FLAG_ACK, pong.head.flags & Http2.FLAG_ACK);

    client.stream.close(io);
    edge_thread.join();
}

test "zix zixer: http2 edge, client goaway drains and closes the connection" {
    if (comptime @import("builtin").os.tag != .linux) return error.SkipZigTest;

    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const proxy = http1_proxy.Proxy{ .io = io };

    var fds: [2]std.posix.fd_t = undefined;
    try openEdgePair(&fds);
    const edge_thread = try spawnServeConn(&proxy, edgeStream(fds[0]));

    var client = TestClient{ .io = io, .stream = edgeStream(fds[1]) };
    try client.start();

    try http2_frames.writeGoaway(&client.writer.interface, 0, Http2.ERR_NO_ERROR);
    try client.writer.interface.flush();

    const answer_frame = try client.nextFrame();
    try testing.expectEqual(@as(u8, Http2.FRAME_TYPE_GOAWAY), answer_frame.head.frame_type);
    try testing.expectError(error.ConnectionClosed, client.nextFrame());

    client.stream.close(io);
    edge_thread.join();
}

/// Test upstream that accepts and then says nothing, the stall an upstream
/// read deadline exists for.
const SilentBackend = struct {
    io: std.Io,
    port: u16,
    ready: std.atomic.Value(bool) = .init(false),
    release: std.atomic.Value(bool) = .init(false),

    fn serve(fake: *SilentBackend) void {
        const io = fake.io;

        const addr = std.Io.net.IpAddress.parse("127.0.0.1", fake.port) catch return;
        var server = addr.listen(io, .{ .reuse_address = true, .kernel_backlog = 8 }) catch return;
        defer server.deinit(io);
        fake.ready.store(true, .release);

        const stream = server.accept(io) catch return;
        defer stream.close(io);

        while (!fake.release.load(.acquire)) {
            std.Io.sleep(io, std.Io.Duration.fromMilliseconds(10), .awake) catch break;
        }
    }
};

test "zix zixer: http2 edge, a silent upstream answers 504 with proxy status" {
    if (comptime @import("builtin").os.tag != .linux) return error.SkipZigTest;

    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var fake = SilentBackend{ .io = io, .port = 18950 };
    const fake_thread = try std.Thread.spawn(.{}, SilentBackend.serve, .{&fake});
    var tries: usize = 0;
    while (tries < 100 and !fake.ready.load(.acquire)) : (tries += 1) {
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(10), .awake) catch {};
    }
    try testing.expect(tries < 100);

    const upstreams = [_]site_cfg.Upstream{.{ .host = "127.0.0.1", .port = 18950 }};
    var pool = try upstream_pool.Pool.init(testing.allocator, &upstreams, upstream_pool.DEFAULT_COOLDOWN_MS);
    defer pool.deinit(testing.allocator);
    var idle = try upstream_conn.IdleCache.init(testing.allocator, 1);
    defer idle.deinit(testing.allocator, io);
    const proxy = http1_proxy.Proxy{ .io = io, .pool = &pool, .idle = &idle, .upstream_timeout_ms = 200 };

    var fds: [2]std.posix.fd_t = undefined;
    try openEdgePair(&fds);
    const edge_thread = try spawnServeConn(&proxy, edgeStream(fds[0]));

    var client = TestClient{ .io = io, .stream = edgeStream(fds[1]) };
    try client.start();

    const get_headers = [_]Http2.Header{
        .{ .name = ":method", .value = "GET" },
        .{ .name = ":scheme", .value = "http" },
        .{ .name = ":path", .value = "/stalled" },
        .{ .name = ":authority", .value = "app.example" },
    };
    try client.sendHeaders(1, &get_headers, true);

    const count = try client.readHead(1);
    try testing.expectEqualStrings("504", client.headerValue(count, ":status").?);
    try testing.expectEqualStrings("zixer; error=\"http_response_timeout\"", client.headerValue(count, "proxy-status").?);

    // A slow backend is still a serving one, so the slot stays in rotation.
    try testing.expectEqual(@as(usize, 1), pool.upCount());

    client.stream.close(io);
    edge_thread.join();
    fake.release.store(true, .release);
    fake_thread.join();
}
