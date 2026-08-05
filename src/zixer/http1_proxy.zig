//! zixer http1 proxy edge: one client connection, re-originate to the pool

const std = @import("std");
const zix = @import("zix");

const acme_challenge = @import("acme_challenge.zig");
const http1_head = @import("http1_head.zig");
const proxy_headers = @import("proxy_headers.zig");
const static_files = @import("static_files.zig");
const upstream_conn = @import("upstream_conn.zig");
const upstream_pool = @import("upstream_pool.zig");
const ws_tunnel = @import("ws_tunnel.zig");

/// Stream buffer size for each leg of the relay.
const STREAM_BUF_SIZE: usize = 8 * 1024;

/// Copy chunk size for the body pumps.
const PUMP_CHUNK: usize = 16 * 1024;

/// Interim (1xx) responses relayed per exchange before giving up.
const MAX_INTERIM = 4;

/// What one site's edge connections share. A proxied site carries pool and
/// idle together, a static-only site leaves both null and serves public_dir
/// alone. acme answers the challenge path ahead of everything, and
/// tls_cert_der (set on a terminated TLS edge) arms the misdirected-request
/// gate.
pub const Proxy = struct {
    io: std.Io,
    pool: ?*upstream_pool.Pool = null,
    idle: ?*upstream_conn.IdleCache = null,
    static: ?static_files.StaticSite = null,
    acme: ?acme_challenge.AcmeSite = null,
    tls_cert_der: ?[]const u8 = null,
    /// The acme companion listener sets this to the site's https port:
    /// everything past the challenge path answers 301 to https (443 keeps
    /// the Location port-free).
    redirect_https: ?u16 = null,
};

/// After one exchange: keep the edge connection or close it.
const EdgeResult = enum {
    KEEP,
    CLOSE,
};

/// Serve one accepted cleartext client connection until it closes. A TLS
/// site reaches the same loop through tls_edge.serveConn instead.
pub fn serveConn(proxy: *const Proxy, client_stream: std.Io.net.Stream) void {
    const io = proxy.io;
    defer client_stream.close(io);

    var read_buf: [STREAM_BUF_SIZE]u8 = undefined;
    var write_buf: [STREAM_BUF_SIZE]u8 = undefined;
    var client_reader = client_stream.reader(io, &read_buf);
    var client_writer = client_stream.writer(io, &write_buf);

    serveLoop(proxy, &client_reader.interface, &client_writer.interface, client_stream.socket.address, client_stream);
}

/// The edge request loop over reader / writer interfaces (plain stream or
/// a terminated TLS session).
///
/// Note:
/// - Every request is re-originated: zixer parses the client framing and
///   builds its own upstream message, raw client bytes never splice through
///   (rfc 9112 smuggling defense).
/// - Answer order per request: misdirected gate (TLS only), the acme
///   challenge plane, the static plane, then the pool. An earlier plane
///   answering means the later ones never see the request.
/// - A websocket upgrade request reaching the pool becomes a raw tunnel
///   after the upstream's 101, pick pinned for the tunnel life.
/// - client_stream is the raw client socket behind the interfaces, the
///   tunnel needs it to unblock a waiting read. Null (socket-less rigs)
///   only softens tunnel teardown when the upstream ends first.
pub fn serveLoop(proxy: *const Proxy, client_r: *std.Io.Reader, client_w: *std.Io.Writer, client_addr: std.Io.net.IpAddress, client_stream: ?std.Io.net.Stream) void {
    while (true) {
        var head_buf: [http1_head.MAX_HEAD_BYTES]u8 = undefined;
        const head_bytes = http1_head.readHead(client_r, &head_buf) catch |err| {
            if (err == error.HeadTooLarge) writeEdgeError(client_w, 431, "head too large", "http_request_error");
            return;
        };

        const request = http1_head.parseRequest(head_bytes) catch {
            writeEdgeError(client_w, 400, "bad request", "http_request_error");
            return;
        };

        // RFC 9110 7.4: under TLS, a Host this certificate does not serve
        // is a misdirected request. 421, then close.
        if (misdirected(proxy, &request)) {
            writeLocalStatus(client_w, 421, "misdirected request", "", true);
            client_w.flush() catch {};
            return;
        }

        if (acmeAnswer(proxy, &request, client_w)) |result| {
            client_w.flush() catch return;
            if (result == .CLOSE) return;

            continue;
        }

        // The companion listener proxies nothing: past the challenge path
        // everything moves to https.
        if (proxy.redirect_https) |https_port| {
            const result = httpsRedirectAnswer(&request, client_w, https_port);

            client_w.flush() catch return;
            if (result == .CLOSE) return;

            continue;
        }

        // The static plane answers next: on a hit or a local status the
        // upstream never sees the request.
        if (staticAnswer(proxy, &request, client_w)) |result| {
            client_w.flush() catch return;
            if (result == .CLOSE) return;

            continue;
        }

        const upgrade = ws_tunnel.wantsUpgrade(&request);

        var build_buf: [http1_head.MAX_HEAD_BYTES + 512]u8 = undefined;
        const upstream_head = buildUpstreamHead(&build_buf, &request, client_addr, upgrade) catch {
            writeEdgeError(client_w, 400, "bad request", "http_request_error");
            return;
        };

        // The client may be waiting on Expect: 100-continue before it sends
        // the body. zixer answers the interim itself, the Expect header was
        // dropped from the rebuilt head.
        if (expectsContinue(&request)) {
            client_w.writeAll("HTTP/1.1 100 Continue\r\n\r\n") catch return;
            client_w.flush() catch return;
        }

        const outcome = exchange(proxy, client_r, client_w, client_stream, &request, upstream_head, upgrade);

        client_w.flush() catch return;
        if (outcome == .CLOSE) return;
    }
}

/// Whether a TLS-terminated request names an authority the site's
/// certificate does not serve. Cleartext edges never arm this.
fn misdirected(proxy: *const Proxy, request: *const http1_head.RequestHead) bool {
    const cert_der = proxy.tls_cert_der orelse return false;
    if (request.host.len == 0) return false;

    const host = stripHostPort(request.host);
    zix.Tls.verifyCertIdentity(cert_der, host) catch return true;

    return false;
}

/// The Host value without its port. A bracketed IPv6 literal keeps its
/// inner address, a bare IPv6 literal (several colons) stays whole.
fn stripHostPort(host: []const u8) []const u8 {
    if (host.len == 0) return host;

    if (host[0] == '[') {
        if (std.mem.indexOfScalar(u8, host, ']')) |close| return host[1..close];

        return host;
    }

    if (std.mem.indexOfScalar(u8, host, ':')) |first| {
        if (std.mem.lastIndexOfScalar(u8, host, ':').? == first) return host[0..first];
    }

    return host;
}

/// Answer the acme challenge path (rfc 8555 8.3) ahead of any site logic.
///
/// Return:
/// - EdgeResult when a response was written here
/// - null when the request is not the challenge path or acme is off
fn acmeAnswer(proxy: *const Proxy, request: *const http1_head.RequestHead, client_w: *std.Io.Writer) ?EdgeResult {
    const acme: *const acme_challenge.AcmeSite = if (proxy.acme) |*inner| inner else return null;
    if (!acme_challenge.handles(request.target)) return null;

    if (!static_files.fileMethod(request.method)) {
        writeLocalStatus(client_w, 405, "method not allowed", "Allow: GET, HEAD\r\n", requestCloses(request));
        return closeOrKeep(request);
    }

    if (acme.webroot) |webroot| {
        if (acme_challenge.resolveWebroot(proxy.io, webroot, request.target)) |resolved| {
            return sendResolved(proxy.io, client_w, resolved, request);
        }

        writeLocalStatus(client_w, 404, "not found", "", requestCloses(request));
        return closeOrKeep(request);
    }

    if (acme.relay) |upstream| {
        if (acme_challenge.relay(proxy.io, upstream, request.method, request.target, request.host, client_w)) return .CLOSE;

        writeEdgeError(client_w, 502, "acme relay unreachable", "connection_refused");
        return .CLOSE;
    }

    return null;
}

/// 301 to the https origin. Without a Host there is no authority to form
/// the Location from, so the reply is a local 404.
fn httpsRedirectAnswer(request: *const http1_head.RequestHead, client_w: *std.Io.Writer, https_port: u16) EdgeResult {
    if (request.host.len == 0) {
        writeLocalStatus(client_w, 404, "not found", "", requestCloses(request));
        return closeOrKeep(request);
    }

    const host = stripHostPort(request.host);
    const edge_close = requestCloses(request);

    client_w.writeAll("HTTP/1.1 301 Moved Permanently\r\n") catch return .CLOSE;
    if (https_port == 443) {
        client_w.print("Location: https://{s}{s}\r\n", .{ host, request.target }) catch return .CLOSE;
    } else {
        client_w.print("Location: https://{s}:{d}{s}\r\n", .{ host, https_port, request.target }) catch return .CLOSE;
    }
    client_w.writeAll("Content-Length: 0\r\n") catch return .CLOSE;
    if (edge_close) client_w.writeAll("Connection: close\r\n") catch return .CLOSE;
    client_w.writeAll("\r\n") catch return .CLOSE;

    return if (edge_close) .CLOSE else .KEEP;
}

/// Answer the request from public_dir when the site serves static files.
///
/// Return:
/// - EdgeResult when a response was written here
/// - null when the request continues to the upstream pool
fn staticAnswer(proxy: *const Proxy, request: *const http1_head.RequestHead, client_w: *std.Io.Writer) ?EdgeResult {
    const io = proxy.io;
    const static_only = proxy.pool == null;

    const site: *const static_files.StaticSite = if (proxy.static) |*inner| inner else {
        if (!static_only) return null;

        // Validation never lets a site carry neither upstreams nor
        // public_dir, answering locally beats reaching into a null pool.
        writeLocalStatus(client_w, 404, "not found", "", requestCloses(request));
        return closeOrKeep(request);
    };

    if (static_files.handles(site, request.method, request.target)) {
        const accept = acceptEncoding(request);
        if (static_files.open(io, site.public_dir, request.target, accept)) |resolved| {
            return sendResolved(io, client_w, resolved, request);
        }

        // File miss: a client-side routed app answers its fallback page.
        // Validation ties spa_fallback to static-only sites or a bounded
        // public_prefix, so a backend 404 never swallows into it.
        if (site.spa_fallback) |fallback| {
            var target_buf: [static_files.MAX_PATH]u8 = undefined;
            if (std.fmt.bufPrint(&target_buf, "/{s}", .{fallback}) catch null) |fallback_target| {
                if (static_files.open(io, site.public_dir, fallback_target, accept)) |resolved| {
                    return sendResolved(io, client_w, resolved, request);
                }
            }
        }
    }

    if (!static_only) return null;

    if (!static_files.fileMethod(request.method)) {
        writeLocalStatus(client_w, 405, "method not allowed", "Allow: GET, HEAD\r\n", requestCloses(request));
        return closeOrKeep(request);
    }

    writeLocalStatus(client_w, 404, "not found", "", requestCloses(request));
    return closeOrKeep(request);
}

/// Write the resolved file as the response, closing it after.
fn sendResolved(io: std.Io, client_w: *std.Io.Writer, resolved: static_files.Resolved, request: *const http1_head.RequestHead) EdgeResult {
    defer resolved.file.close(io);

    const edge_close = requestCloses(request);
    static_files.writeResolvedHead(client_w, &resolved, edge_close) catch return .CLOSE;

    if (!std.mem.eql(u8, request.method, "HEAD")) {
        var chunk: [PUMP_CHUNK]u8 = undefined;
        var offset: u64 = 0;
        while (offset < resolved.size) {
            const want: usize = @intCast(@min(resolved.size - offset, chunk.len));
            const got = resolved.file.readPositionalAll(io, chunk[0..want], offset) catch return .CLOSE;
            if (got == 0) return .CLOSE;

            client_w.writeAll(chunk[0..got]) catch return .CLOSE;
            offset += got;
        }
    }

    return if (edge_close) .CLOSE else .KEEP;
}

/// A request whose body was never read cannot keep the edge conn: the next
/// head parse on this connection would read body bytes.
fn requestCloses(request: *const http1_head.RequestHead) bool {
    return request.connection_close or request.framing != .none;
}

fn closeOrKeep(request: *const http1_head.RequestHead) EdgeResult {
    return if (requestCloses(request)) .CLOSE else .KEEP;
}

/// The request Accept-Encoding value, null when the header is absent.
fn acceptEncoding(request: *const http1_head.RequestHead) ?[]const u8 {
    for (request.headerSlice()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "accept-encoding")) return header.value;
    }

    return null;
}

/// Local origin reply for the static plane: no Proxy-Status, since zixer
/// answers as the origin here, not as an intermediary.
fn writeLocalStatus(client_w: *std.Io.Writer, status: u16, reason: []const u8, extra_header: []const u8, edge_close: bool) void {
    client_w.print(
        "HTTP/1.1 {d} {s}\r\nContent-Length: {d}\r\n{s}",
        .{ status, reason, reason.len + 1, extra_header },
    ) catch return;
    if (edge_close) client_w.writeAll("Connection: close\r\n") catch return;
    client_w.print("\r\n{s}\n", .{reason}) catch return;
}

/// One request against the pool: pick, forward, relay, bounded retry. An
/// upgrade exchange whose upstream answers 101 becomes the raw tunnel and
/// always closes the edge after.
fn exchange(
    proxy: *const Proxy,
    client_r: *std.Io.Reader,
    client_w: *std.Io.Writer,
    client_stream: ?std.Io.net.Stream,
    request: *const http1_head.RequestHead,
    upstream_head: []const u8,
    upgrade: bool,
) EdgeResult {
    const io = proxy.io;
    const no_body = request.framing == .none;

    // serveConn only reaches the exchange when the pool exists: the static
    // branch answered everything else on a static-only site.
    const pool = proxy.pool.?;
    const idle = proxy.idle.?;

    // Bounded retry: one try per configured upstream, plus one spare so a
    // single stale idle conn never eats a slot's only chance.
    var attempts: usize = pool.slots.len + 1;
    var failed_here: bool = false;
    while (attempts > 0) : (attempts -= 1) {
        const picked = pool.pick(nowMs(io)) orelse {
            // Nothing left to pick. When this exchange itself emptied the
            // pool the honest answer is the failure it saw, not 503.
            if (failed_here) break;

            writeEdgeError(client_w, 503, "no upstream available", "destination_unavailable");
            return .CLOSE;
        };

        const conn = idle.acquire(picked.index) orelse
            upstream_conn.connect(io, picked.host, picked.port, picked.index) catch {
            pool.markDown(picked.index, nowMs(io));
            failed_here = true;
            continue;
        };

        var up_read_buf: [STREAM_BUF_SIZE]u8 = undefined;
        var up_write_buf: [STREAM_BUF_SIZE]u8 = undefined;
        var up_reader = conn.stream.reader(io, &up_read_buf);
        var up_writer = conn.stream.writer(io, &up_write_buf);

        up_writer.interface.writeAll(upstream_head) catch {
            conn.stream.close(io);
            if (!conn.reused) pool.markDown(picked.index, nowMs(io));
            failed_here = true;
            continue;
        };

        // The body is not replayable: any failure past this point cannot
        // retry another upstream for a request that carries one.
        switch (request.framing) {
            .none => {},
            .content_length => |len| pumpExact(client_r, &up_writer.interface, len) catch {
                conn.stream.close(io);
                writeEdgeError(client_w, 502, "upstream send failed", "connection_terminated");
                return .CLOSE;
            },
            .chunked => pumpChunked(client_r, &up_writer.interface, false) catch {
                conn.stream.close(io);
                writeEdgeError(client_w, 502, "upstream send failed", "connection_terminated");
                return .CLOSE;
            },
            .until_close => unreachable,
        }
        up_writer.interface.flush() catch {
            conn.stream.close(io);
            if (no_body) {
                if (!conn.reused) pool.markDown(picked.index, nowMs(io));
                failed_here = true;
                continue;
            }
            writeEdgeError(client_w, 502, "upstream send failed", "connection_terminated");
            return .CLOSE;
        };

        var resp_head_buf: [http1_head.MAX_HEAD_BYTES]u8 = undefined;
        const response = readResponseHead(&up_reader.interface, &resp_head_buf, request.method, client_w, upgrade) orelse {
            conn.stream.close(io);
            if (no_body) {
                // A stale idle conn answers EOF here. Bodyless requests are
                // safe to replay, with a body the client already spent it.
                if (!conn.reused) pool.markDown(picked.index, nowMs(io));
                failed_here = true;
                continue;
            }
            writeEdgeError(client_w, 502, "upstream closed early", "connection_terminated");
            return .CLOSE;
        };

        // The upstream took the upgrade: relay the 101 and hand both legs
        // to the tunnel. The pick stays pinned on this one connection for
        // the whole session, and the edge closes with it.
        if (upgrade and response.status == 101) {
            const switched = blk: {
                ws_tunnel.writeSwitchHead(client_w, &response) catch break :blk false;
                client_w.flush() catch break :blk false;
                break :blk true;
            };

            if (switched) ws_tunnel.run(.{
                .io = io,
                .client_r = client_r,
                .client_w = client_w,
                .client_stream = client_stream,
                .up_stream = conn.stream,
                .up_r = &up_reader.interface,
                .up_w = &up_writer.interface,
            });
            conn.stream.close(io);

            return .CLOSE;
        }

        const edge_close = request.connection_close or response.framing == .until_close;
        writeResponseHead(client_w, &response, edge_close) catch {
            conn.stream.close(io);
            return .CLOSE;
        };

        var relay_failed = false;
        switch (response.framing) {
            .none => {},
            .content_length => |len| pumpExact(&up_reader.interface, client_w, len) catch {
                relay_failed = true;
            },
            .chunked => pumpChunked(&up_reader.interface, client_w, true) catch {
                relay_failed = true;
            },
            .until_close => pumpUntilClose(&up_reader.interface, client_w),
        }

        const reusable = !relay_failed and !response.connection_close and response.framing != .until_close;
        if (reusable) idle.release(io, conn) else conn.stream.close(io);

        if (relay_failed or edge_close) return .CLOSE;

        return .KEEP;
    }

    writeEdgeError(client_w, 502, "all upstreams failed", "connection_refused");

    return .CLOSE;
}

/// Read the upstream response head, relaying interim 1xx responses to the
/// client on the way. Null when the upstream connection failed first. A
/// 101 is final on an upgrade exchange (tunnel bytes follow it), on any
/// other exchange it was never asked for and counts as a failure.
fn readResponseHead(up_r: *std.Io.Reader, head_buf: []u8, method: []const u8, client_w: *std.Io.Writer, upgrade: bool) ?http1_head.ResponseHead {
    var interim: usize = 0;
    while (interim <= MAX_INTERIM) : (interim += 1) {
        const bytes = http1_head.readHead(up_r, head_buf) catch return null;
        const response = http1_head.parseResponse(bytes, method) catch return null;

        if (response.status == 101) return if (upgrade) response else null;
        if (response.status / 100 != 1) return response;

        client_w.writeAll(bytes) catch return null;
        client_w.flush() catch return null;
    }

    return null;
}

/// Rebuild the client head for the upstream leg: filtered headers plus Via,
/// Forwarded, and zixer's own framing header. An upgrade rebuild re-adds
/// the websocket pair the hop-by-hop strip removed.
fn buildUpstreamHead(buf: []u8, request: *const http1_head.RequestHead, client_addr: std.Io.net.IpAddress, upgrade: bool) ![]const u8 {
    var fixed = std.Io.Writer.fixed(buf);

    try fixed.print("{s} {s} HTTP/1.1\r\n", .{ request.method, request.target });
    for (request.headerSlice()) |header| {
        if (proxy_headers.isStripped(header.name)) continue;
        if (proxy_headers.namedInConnection(header.name, request.connection_value)) continue;
        if (std.ascii.eqlIgnoreCase(header.name, "expect")) continue;

        try fixed.print("{s}: {s}\r\n", .{ header.name, header.value });
    }

    try fixed.print("Via: {s}\r\n", .{proxy_headers.VIA});
    try proxy_headers.writeForwarded(&fixed, client_addr, request.host);

    switch (request.framing) {
        .none => {},
        .content_length => |len| try fixed.print("Content-Length: {d}\r\n", .{len}),
        .chunked => try fixed.writeAll("Transfer-Encoding: chunked\r\n"),
        .until_close => unreachable,
    }
    if (upgrade) try ws_tunnel.writeUpgradeHeaders(&fixed);

    try fixed.writeAll("\r\n");

    return fixed.buffered();
}

/// Relay the upstream head to the client: filtered headers plus Via and
/// zixer's framing, Connection: close when this exchange ends the edge conn.
fn writeResponseHead(client_w: *std.Io.Writer, response: *const http1_head.ResponseHead, edge_close: bool) !void {
    try client_w.print("HTTP/1.1 {d} {s}\r\n", .{ response.status, response.reason });
    for (response.headerSlice()) |header| {
        if (proxy_headers.isStripped(header.name)) continue;
        if (proxy_headers.namedInConnection(header.name, response.connection_value)) continue;

        try client_w.print("{s}: {s}\r\n", .{ header.name, header.value });
    }

    try client_w.print("Via: {s}\r\n", .{proxy_headers.VIA});

    switch (response.framing) {
        .none => {
            if (response.status / 100 != 1 and response.status != 204 and response.status != 304)
                try client_w.writeAll("Content-Length: 0\r\n");
        },
        .content_length => |len| try client_w.print("Content-Length: {d}\r\n", .{len}),
        .chunked => try client_w.writeAll("Transfer-Encoding: chunked\r\n"),
        .until_close => {},
    }
    if (edge_close) try client_w.writeAll("Connection: close\r\n");

    try client_w.writeAll("\r\n");
}

fn expectsContinue(request: *const http1_head.RequestHead) bool {
    for (request.headerSlice()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "expect") and
            std.ascii.eqlIgnoreCase(header.value, "100-continue")) return true;
    }

    return false;
}

/// Local error reply with the rfc 9209 Proxy-Status parameter, then close.
fn writeEdgeError(client_w: *std.Io.Writer, status: u16, reason: []const u8, proxy_error: []const u8) void {
    client_w.print(
        "HTTP/1.1 {d} {s}\r\nContent-Length: {d}\r\nProxy-Status: zixer; error=\"{s}\"\r\nConnection: close\r\n\r\n{s}\n",
        .{ status, reason, reason.len + 1, proxy_error, reason },
    ) catch return;
    client_w.flush() catch return;
}

fn nowMs(io: std.Io) i64 {
    return std.Io.Clock.Timestamp.now(io, .real).raw.toMilliseconds();
}

// --------------------------------------------------------- //

/// Copy exactly len bytes from src to dst.
fn pumpExact(src: *std.Io.Reader, dst: *std.Io.Writer, len: u64) !void {
    var chunk: [PUMP_CHUNK]u8 = undefined;
    var remaining = len;
    while (remaining > 0) {
        const want: usize = @intCast(@min(remaining, chunk.len));
        const got = src.readSliceShort(chunk[0..want]) catch return error.ConnectionClosed;
        if (got == 0) return error.ConnectionClosed;

        try dst.writeAll(chunk[0..got]);
        remaining -= got;
    }
}

/// Relay a chunked body, re-emitting the chunk framing zixer parsed. The
/// trailer section is relayed line by line. flush_each delivers every
/// chunk as it completes (the client leg of a streamed response, an SSE
/// backend sends one event per chunk), the upstream leg leaves batching
/// to the writer buffer.
fn pumpChunked(src: *std.Io.Reader, dst: *std.Io.Writer, flush_each: bool) !void {
    while (true) {
        var line_buf: [256]u8 = undefined;
        const size_line = try readLine(src, &line_buf);

        const semicolon = std.mem.indexOfScalar(u8, size_line, ';');
        const size_text = std.mem.trim(u8, if (semicolon) |pos| size_line[0..pos] else size_line, " \t");
        const size = std.fmt.parseInt(u64, size_text, 16) catch return error.BadChunk;

        try dst.print("{x}\r\n", .{size});

        if (size == 0) {
            while (true) {
                const trailer = try readLine(src, &line_buf);
                try dst.writeAll(trailer);
                try dst.writeAll("\r\n");
                if (trailer.len == 0) return;
            }
        }

        try pumpExact(src, dst, size);

        const after = try readLine(src, &line_buf);
        if (after.len != 0) return error.BadChunk;
        try dst.writeAll("\r\n");
        if (flush_each) try dst.flush();
    }
}

/// Relay until the source closes, delivering each burst as it arrives so
/// stream semantics survive the hop (an SSE event reaches the client when
/// the upstream sends it, not when a buffer fills). The destination is
/// closed by the caller.
fn pumpUntilClose(src: *std.Io.Reader, dst: *std.Io.Writer) void {
    while (true) {
        // A zero return stored into the reader buffer instead of the
        // writer (interface readers may), the next pass drains it.
        const got = src.stream(dst, .limited(PUMP_CHUNK)) catch return;
        if (got == 0) continue;

        dst.flush() catch return;
    }
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
// --------------------------------------------------------- //

test "zix zixer: http1 proxy, upstream head is rebuilt with forwarded and via" {
    const request = try http1_head.parseRequest("POST /api HTTP/1.1\r\nHost: app.example\r\nConnection: close, X-Hop\r\nX-Hop: secret\r\nAccept: */*\r\nContent-Length: 4\r\nExpect: 100-continue\r\n\r\n");

    var build_buf: [http1_head.MAX_HEAD_BYTES + 512]u8 = undefined;
    const addr = std.Io.net.IpAddress{ .ip4 = .{ .bytes = .{ 192, 0, 2, 7 }, .port = 55000 } };
    const head = try buildUpstreamHead(&build_buf, &request, addr, false);

    try std.testing.expect(std.mem.startsWith(u8, head, "POST /api HTTP/1.1\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, head, "Host: app.example\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, head, "Accept: */*\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, head, "Via: 1.1 zixer\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, head, "Forwarded: for=\"192.0.2.7:55000\";proto=http;host=\"app.example\"\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, head, "Content-Length: 4\r\n") != null);

    try std.testing.expect(std.mem.indexOf(u8, head, "Connection") == null);
    try std.testing.expect(std.mem.indexOf(u8, head, "X-Hop") == null);
    try std.testing.expect(std.mem.indexOf(u8, head, "Expect") == null);
    try std.testing.expect(std.mem.endsWith(u8, head, "\r\n\r\n"));
}

test "zix zixer: http1 proxy, response head relays filtered with edge framing" {
    const response = try http1_head.parseResponse("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nConnection: keep-alive\r\nKeep-Alive: timeout=5\r\nContent-Length: 2\r\n\r\n", "GET");

    var out_buf: [1024]u8 = undefined;
    var out = std.Io.Writer.fixed(&out_buf);
    try writeResponseHead(&out, &response, false);
    const head = out.buffered();

    try std.testing.expect(std.mem.startsWith(u8, head, "HTTP/1.1 200 OK\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, head, "Content-Type: text/plain\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, head, "Content-Length: 2\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, head, "Via: 1.1 zixer\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, head, "Keep-Alive") == null);
    try std.testing.expect(std.mem.indexOf(u8, head, "Connection") == null);

    var close_buf: [1024]u8 = undefined;
    var close_out = std.Io.Writer.fixed(&close_buf);
    try writeResponseHead(&close_out, &response, true);
    try std.testing.expect(std.mem.indexOf(u8, close_out.buffered(), "Connection: close\r\n") != null);
}

test "zix zixer: http1 proxy, pumpExact moves exactly the length" {
    var src = std.Io.Reader.fixed("hello worldEXTRA");
    var out_buf: [64]u8 = undefined;
    var out = std.Io.Writer.fixed(&out_buf);

    try pumpExact(&src, &out, 11);
    try std.testing.expectEqualStrings("hello world", out.buffered());

    var short = std.Io.Reader.fixed("abc");
    var short_out = std.Io.Writer.fixed(&out_buf);
    try std.testing.expectError(error.ConnectionClosed, pumpExact(&short, &short_out, 5));
}

test "zix zixer: http1 proxy, pumpChunked re-emits chunks and the trailer" {
    var src = std.Io.Reader.fixed("5\r\nhello\r\n6;ext=1\r\n world\r\n0\r\nX-Sum: ok\r\n\r\n");
    var out_buf: [128]u8 = undefined;
    var out = std.Io.Writer.fixed(&out_buf);

    try pumpChunked(&src, &out, false);
    try std.testing.expectEqualStrings("5\r\nhello\r\n6\r\n world\r\n0\r\nX-Sum: ok\r\n\r\n", out.buffered());

    var bad = std.Io.Reader.fixed("nope\r\n");
    var bad_out = std.Io.Writer.fixed(&out_buf);
    try std.testing.expectError(error.BadChunk, pumpChunked(&bad, &bad_out, false));
}

test "zix zixer: http1 proxy, edge error carries proxy-status" {
    var out_buf: [512]u8 = undefined;
    var out = std.Io.Writer.fixed(&out_buf);

    writeEdgeError(&out, 502, "all upstreams failed", "connection_refused");
    const reply = out.buffered();

    try std.testing.expect(std.mem.startsWith(u8, reply, "HTTP/1.1 502 all upstreams failed\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, reply, "Proxy-Status: zixer; error=\"connection_refused\"\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, reply, "Connection: close\r\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, reply, "\r\n\r\nall upstreams failed\n"));
}

// --------------------------------------------------------- //

const site_cfg = @import("site_cfg.zig");

/// Test upstream: accepts conns on a loopback port, records the first request
/// head, answers each request with a canned response.
const FakeUpstream = struct {
    io: std.Io,
    port: u16,
    /// Requests answered before the thread exits, across any number of conns.
    request_quota: usize,
    /// Canned payload the response body echoes when the request had one.
    seen_head: [4096]u8 = undefined,
    seen_len: usize = 0,
    conns_accepted: usize = 0,
    ready: std.atomic.Value(bool) = .init(false),

    fn serve(fake: *FakeUpstream) void {
        const io = fake.io;

        const addr = std.Io.net.IpAddress.parse("127.0.0.1", fake.port) catch return;
        var server = addr.listen(io, .{ .reuse_address = true, .kernel_backlog = 8 }) catch return;
        defer server.deinit(io);
        fake.ready.store(true, .release);

        var answered: usize = 0;
        while (answered < fake.request_quota) {
            const stream = server.accept(io) catch return;
            fake.conns_accepted += 1;

            var read_buf: [4096]u8 = undefined;
            var write_buf: [4096]u8 = undefined;
            var reader = stream.reader(io, &read_buf);
            var writer = stream.writer(io, &write_buf);

            conn: while (answered < fake.request_quota) {
                var head_buf: [4096]u8 = undefined;
                const head = http1_head.readHead(&reader.interface, &head_buf) catch break :conn;
                const request = http1_head.parseRequest(head) catch break :conn;

                if (fake.seen_len == 0) {
                    @memcpy(fake.seen_head[0..head.len], head);
                    fake.seen_len = head.len;
                }

                var body_buf: [256]u8 = undefined;
                var body_len: usize = 0;
                if (request.framing == .content_length) {
                    body_len = @intCast(request.framing.content_length);
                    var got: usize = 0;
                    while (got < body_len) {
                        const n = reader.interface.readSliceShort(body_buf[got..body_len]) catch break :conn;
                        if (n == 0) break :conn;
                        got += n;
                    }
                }

                writer.interface.print(
                    "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nKeep-Alive: timeout=5\r\nContent-Length: {d}\r\n\r\necho:{s}",
                    .{ body_len + 5, body_buf[0..body_len] },
                ) catch break :conn;
                writer.interface.flush() catch break :conn;
                answered += 1;
            }

            stream.close(io);
        }
    }
};

fn spawnServeConn(proxy: *const Proxy, stream: std.Io.net.Stream) !std.Thread {
    return std.Thread.spawn(.{}, serveConnThread, .{ proxy, stream });
}

fn serveConnThread(proxy: *const Proxy, stream: std.Io.net.Stream) void {
    serveConn(proxy, stream);
}

fn edgeStream(handle: std.posix.fd_t) std.Io.net.Stream {
    return .{ .socket = .{ .handle = handle, .address = .{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = 40000 } } } };
}

fn readAllAvailable(io: std.Io, stream: std.Io.net.Stream, buf: []u8) usize {
    var read_buf: [4096]u8 = undefined;
    var reader = stream.reader(io, &read_buf);
    var len: usize = 0;
    while (len < buf.len) {
        const got = reader.interface.readSliceShort(buf[len .. len + 1]) catch break;
        if (got == 0) break;
        len += got;
    }

    return len;
}

fn waitReady(io: std.Io, fake: *FakeUpstream) !void {
    var tries: usize = 0;
    while (tries < 100 and !fake.ready.load(.acquire)) : (tries += 1) {
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(10), .awake) catch {};
    }

    try std.testing.expect(tries < 100);
}

test "zix zixer: http1 proxy, round trip relays body and rewrites both heads" {
    if (comptime @import("builtin").os.tag != .linux) return error.SkipZigTest;

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var fake = FakeUpstream{ .io = io, .port = 39873, .request_quota = 1 };
    const fake_thread = try std.Thread.spawn(.{}, FakeUpstream.serve, .{&fake});
    try waitReady(io, &fake);

    const upstreams = [_]site_cfg.Upstream{.{ .host = "127.0.0.1", .port = 39873 }};
    var pool = try upstream_pool.Pool.init(std.testing.allocator, &upstreams, upstream_pool.DEFAULT_COOLDOWN_MS);
    defer pool.deinit(std.testing.allocator);
    var idle = try upstream_conn.IdleCache.init(std.testing.allocator, 1);
    defer idle.deinit(std.testing.allocator, io);
    const proxy = Proxy{ .io = io, .pool = &pool, .idle = &idle };

    var fds: [2]std.posix.fd_t = undefined;
    try std.testing.expectEqual(@as(usize, 0), std.os.linux.socketpair(std.os.linux.AF.UNIX, std.os.linux.SOCK.STREAM, 0, &fds));
    const edge_thread = try spawnServeConn(&proxy, edgeStream(fds[0]));

    const client = edgeStream(fds[1]);
    {
        var write_buf: [512]u8 = undefined;
        var writer = client.writer(io, &write_buf);
        try writer.interface.writeAll("POST /api HTTP/1.1\r\nHost: t.example\r\nContent-Length: 4\r\nConnection: close\r\n\r\nping");
        try writer.interface.flush();
    }

    var reply_buf: [2048]u8 = undefined;
    const reply_len = readAllAvailable(io, client, &reply_buf);
    const reply = reply_buf[0..reply_len];
    client.close(io);

    edge_thread.join();
    fake_thread.join();

    try std.testing.expect(std.mem.startsWith(u8, reply, "HTTP/1.1 200 OK\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, reply, "Via: 1.1 zixer\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, reply, "Connection: close\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, reply, "Keep-Alive") == null);
    try std.testing.expect(std.mem.endsWith(u8, reply, "\r\n\r\necho:ping"));

    const seen = fake.seen_head[0..fake.seen_len];
    try std.testing.expect(std.mem.startsWith(u8, seen, "POST /api HTTP/1.1\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, seen, "Host: t.example\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, seen, "Via: 1.1 zixer\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, seen, "Forwarded: for=\"127.0.0.1:40000\";proto=http;host=\"t.example\"\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, seen, "Connection") == null);
}

test "zix zixer: http1 proxy, edge keep-alive reuses one upstream conn" {
    if (comptime @import("builtin").os.tag != .linux) return error.SkipZigTest;

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var fake = FakeUpstream{ .io = io, .port = 39874, .request_quota = 2 };
    const fake_thread = try std.Thread.spawn(.{}, FakeUpstream.serve, .{&fake});
    try waitReady(io, &fake);

    const upstreams = [_]site_cfg.Upstream{.{ .host = "127.0.0.1", .port = 39874 }};
    var pool = try upstream_pool.Pool.init(std.testing.allocator, &upstreams, upstream_pool.DEFAULT_COOLDOWN_MS);
    defer pool.deinit(std.testing.allocator);
    var idle = try upstream_conn.IdleCache.init(std.testing.allocator, 1);
    defer idle.deinit(std.testing.allocator, io);
    const proxy = Proxy{ .io = io, .pool = &pool, .idle = &idle };

    var fds: [2]std.posix.fd_t = undefined;
    try std.testing.expectEqual(@as(usize, 0), std.os.linux.socketpair(std.os.linux.AF.UNIX, std.os.linux.SOCK.STREAM, 0, &fds));
    const edge_thread = try spawnServeConn(&proxy, edgeStream(fds[0]));

    const client = edgeStream(fds[1]);
    var read_buf: [4096]u8 = undefined;
    var write_buf: [512]u8 = undefined;
    var reader = client.reader(io, &read_buf);
    var writer = client.writer(io, &write_buf);

    try writer.interface.writeAll("GET /a HTTP/1.1\r\nHost: t\r\n\r\n");
    try writer.interface.flush();
    var head_buf: [2048]u8 = undefined;
    const first_head = try http1_head.readHead(&reader.interface, &head_buf);
    const first = try http1_head.parseResponse(first_head, "GET");
    try std.testing.expectEqual(@as(u16, 200), first.status);
    var body: [64]u8 = undefined;
    const first_len: usize = @intCast(first.framing.content_length);
    _ = try reader.interface.readSliceShort(body[0..first_len]);

    try writer.interface.writeAll("GET /b HTTP/1.1\r\nHost: t\r\nConnection: close\r\n\r\n");
    try writer.interface.flush();
    var head_buf2: [2048]u8 = undefined;
    const second_head = try http1_head.readHead(&reader.interface, &head_buf2);
    const second = try http1_head.parseResponse(second_head, "GET");
    try std.testing.expectEqual(@as(u16, 200), second.status);

    client.close(io);
    edge_thread.join();
    fake_thread.join();

    // Both requests crossed one upstream tcp conn: the second came from the
    // idle cache instead of a fresh handshake.
    try std.testing.expectEqual(@as(usize, 1), fake.conns_accepted);
}

test "zix zixer: http1 proxy, dead upstream fails over inside one request" {
    if (comptime @import("builtin").os.tag != .linux) return error.SkipZigTest;

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var fake = FakeUpstream{ .io = io, .port = 39875, .request_quota = 1 };
    const fake_thread = try std.Thread.spawn(.{}, FakeUpstream.serve, .{&fake});
    try waitReady(io, &fake);

    // The dead upstream sits first in round-robin order, so the request must
    // fail over to the live one.
    const upstreams = [_]site_cfg.Upstream{
        .{ .host = "127.0.0.1", .port = 39877 },
        .{ .host = "127.0.0.1", .port = 39875 },
    };
    var pool = try upstream_pool.Pool.init(std.testing.allocator, &upstreams, upstream_pool.DEFAULT_COOLDOWN_MS);
    defer pool.deinit(std.testing.allocator);
    var idle = try upstream_conn.IdleCache.init(std.testing.allocator, 2);
    defer idle.deinit(std.testing.allocator, io);
    const proxy = Proxy{ .io = io, .pool = &pool, .idle = &idle };

    var fds: [2]std.posix.fd_t = undefined;
    try std.testing.expectEqual(@as(usize, 0), std.os.linux.socketpair(std.os.linux.AF.UNIX, std.os.linux.SOCK.STREAM, 0, &fds));
    const edge_thread = try spawnServeConn(&proxy, edgeStream(fds[0]));

    const client = edgeStream(fds[1]);
    {
        var write_buf: [512]u8 = undefined;
        var writer = client.writer(io, &write_buf);
        try writer.interface.writeAll("GET / HTTP/1.1\r\nHost: t\r\nConnection: close\r\n\r\n");
        try writer.interface.flush();
    }

    var reply_buf: [2048]u8 = undefined;
    const reply_len = readAllAvailable(io, client, &reply_buf);
    const reply = reply_buf[0..reply_len];
    client.close(io);

    edge_thread.join();
    fake_thread.join();

    try std.testing.expect(std.mem.startsWith(u8, reply, "HTTP/1.1 200 OK\r\n"));
    try std.testing.expectEqual(@as(usize, 1), pool.upCount());
}

test "zix zixer: http1 proxy, every upstream down answers 502 with proxy-status" {
    if (comptime @import("builtin").os.tag != .linux) return error.SkipZigTest;

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const upstreams = [_]site_cfg.Upstream{.{ .host = "127.0.0.1", .port = 39878 }};
    var pool = try upstream_pool.Pool.init(std.testing.allocator, &upstreams, upstream_pool.DEFAULT_COOLDOWN_MS);
    defer pool.deinit(std.testing.allocator);
    var idle = try upstream_conn.IdleCache.init(std.testing.allocator, 1);
    defer idle.deinit(std.testing.allocator, io);
    const proxy = Proxy{ .io = io, .pool = &pool, .idle = &idle };

    var fds: [2]std.posix.fd_t = undefined;
    try std.testing.expectEqual(@as(usize, 0), std.os.linux.socketpair(std.os.linux.AF.UNIX, std.os.linux.SOCK.STREAM, 0, &fds));
    const edge_thread = try spawnServeConn(&proxy, edgeStream(fds[0]));

    const client = edgeStream(fds[1]);
    {
        var write_buf: [512]u8 = undefined;
        var writer = client.writer(io, &write_buf);
        try writer.interface.writeAll("GET / HTTP/1.1\r\nHost: t\r\n\r\n");
        try writer.interface.flush();
    }

    var reply_buf: [2048]u8 = undefined;
    const reply_len = readAllAvailable(io, client, &reply_buf);
    const reply = reply_buf[0..reply_len];
    client.close(io);

    edge_thread.join();

    try std.testing.expect(std.mem.startsWith(u8, reply, "HTTP/1.1 502 "));
    try std.testing.expect(std.mem.indexOf(u8, reply, "Proxy-Status: zixer; error=\"connection_refused\"") != null);

    // A fresh edge conn while the pool is still empty gets the 503: nothing
    // failed inside that exchange, there was just nothing to pick.
    var fds2: [2]std.posix.fd_t = undefined;
    try std.testing.expectEqual(@as(usize, 0), std.os.linux.socketpair(std.os.linux.AF.UNIX, std.os.linux.SOCK.STREAM, 0, &fds2));
    const second_edge = try spawnServeConn(&proxy, edgeStream(fds2[0]));

    const client2 = edgeStream(fds2[1]);
    {
        var write_buf: [512]u8 = undefined;
        var writer = client2.writer(io, &write_buf);
        try writer.interface.writeAll("GET / HTTP/1.1\r\nHost: t\r\n\r\n");
        try writer.interface.flush();
    }

    var reply2_buf: [2048]u8 = undefined;
    const reply2_len = readAllAvailable(io, client2, &reply2_buf);
    const reply2 = reply2_buf[0..reply2_len];
    client2.close(io);
    second_edge.join();

    try std.testing.expect(std.mem.startsWith(u8, reply2, "HTTP/1.1 503 "));
    try std.testing.expect(std.mem.indexOf(u8, reply2, "Proxy-Status: zixer; error=\"destination_unavailable\"") != null);
}

// --------------------------------------------------------- //

const testing = std.testing;

fn writeFixture(dir: std.Io.Dir, name: []const u8, data: []const u8) void {
    dir.writeFile(testing.io, .{ .sub_path = name, .data = data }) catch @panic("fixture write failed");
}

fn fixtureRoot(buf: []u8, tmp: *const testing.TmpDir) []const u8 {
    return std.fmt.bufPrint(buf, ".zig-cache/tmp/{s}", .{tmp.sub_path}) catch unreachable;
}

test "zix zixer: http1 proxy, static hit serves the file and keeps alive" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    writeFixture(tmp.dir, "app.js", "console.log(1)");

    var root_buf: [64]u8 = undefined;
    const root = fixtureRoot(&root_buf, &tmp);
    const proxy = Proxy{ .io = testing.io, .static = .{ .public_dir = root, .public_prefix = null, .spa_fallback = null } };

    const request = try http1_head.parseRequest("GET /app.js HTTP/1.1\r\nHost: t\r\n\r\n");
    var out_buf: [1024]u8 = undefined;
    var out = std.Io.Writer.fixed(&out_buf);

    const result = staticAnswer(&proxy, &request, &out).?;
    const reply = out.buffered();

    try testing.expectEqual(EdgeResult.KEEP, result);
    try testing.expect(std.mem.startsWith(u8, reply, "HTTP/1.1 200 OK\r\n"));
    try testing.expect(std.mem.indexOf(u8, reply, "Content-Type: application/javascript\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, reply, "Content-Length: 14\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, reply, "Vary: Accept-Encoding\r\n") != null);
    try testing.expect(std.mem.endsWith(u8, reply, "\r\n\r\nconsole.log(1)"));
}

test "zix zixer: http1 proxy, static head request sends no body" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    writeFixture(tmp.dir, "page.html", "<h1>hi</h1>");

    var root_buf: [64]u8 = undefined;
    const root = fixtureRoot(&root_buf, &tmp);
    const proxy = Proxy{ .io = testing.io, .static = .{ .public_dir = root, .public_prefix = null, .spa_fallback = null } };

    const request = try http1_head.parseRequest("HEAD /page.html HTTP/1.1\r\nHost: t\r\n\r\n");
    var out_buf: [1024]u8 = undefined;
    var out = std.Io.Writer.fixed(&out_buf);

    const result = staticAnswer(&proxy, &request, &out).?;
    const reply = out.buffered();

    try testing.expectEqual(EdgeResult.KEEP, result);
    try testing.expect(std.mem.indexOf(u8, reply, "Content-Length: 11\r\n") != null);
    try testing.expect(std.mem.endsWith(u8, reply, "\r\n\r\n"));
}

test "zix zixer: http1 proxy, static miss falls back to the spa page" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    writeFixture(tmp.dir, "index.html", "<app/>");

    var root_buf: [64]u8 = undefined;
    const root = fixtureRoot(&root_buf, &tmp);
    const proxy = Proxy{ .io = testing.io, .static = .{ .public_dir = root, .public_prefix = null, .spa_fallback = "index.html" } };

    // A deep link misses on disk and serves the fallback page instead.
    const request = try http1_head.parseRequest("GET /users/42 HTTP/1.1\r\nHost: t\r\n\r\n");
    var out_buf: [1024]u8 = undefined;
    var out = std.Io.Writer.fixed(&out_buf);

    const result = staticAnswer(&proxy, &request, &out).?;
    const reply = out.buffered();

    try testing.expectEqual(EdgeResult.KEEP, result);
    try testing.expect(std.mem.startsWith(u8, reply, "HTTP/1.1 200 OK\r\n"));
    try testing.expect(std.mem.indexOf(u8, reply, "Content-Type: text/html\r\n") != null);
    try testing.expect(std.mem.endsWith(u8, reply, "\r\n\r\n<app/>"));
}

test "zix zixer: http1 proxy, static-only site answers 404 and 405 locally" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var root_buf: [64]u8 = undefined;
    const root = fixtureRoot(&root_buf, &tmp);
    const proxy = Proxy{ .io = testing.io, .static = .{ .public_dir = root, .public_prefix = null, .spa_fallback = null } };

    const miss = try http1_head.parseRequest("GET /absent.txt HTTP/1.1\r\nHost: t\r\n\r\n");
    var miss_buf: [512]u8 = undefined;
    var miss_out = std.Io.Writer.fixed(&miss_buf);
    try testing.expectEqual(EdgeResult.KEEP, staticAnswer(&proxy, &miss, &miss_out).?);
    try testing.expect(std.mem.startsWith(u8, miss_out.buffered(), "HTTP/1.1 404 not found\r\n"));
    try testing.expect(std.mem.indexOf(u8, miss_out.buffered(), "Proxy-Status") == null);

    const post = try http1_head.parseRequest("POST /submit HTTP/1.1\r\nHost: t\r\nContent-Length: 4\r\n\r\n");
    var post_buf: [512]u8 = undefined;
    var post_out = std.Io.Writer.fixed(&post_buf);

    // The unread body forces the close, the method earns the 405.
    try testing.expectEqual(EdgeResult.CLOSE, staticAnswer(&proxy, &post, &post_out).?);
    try testing.expect(std.mem.startsWith(u8, post_out.buffered(), "HTTP/1.1 405 method not allowed\r\n"));
    try testing.expect(std.mem.indexOf(u8, post_out.buffered(), "Allow: GET, HEAD\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, post_out.buffered(), "Connection: close\r\n") != null);
}

test "zix zixer: http1 proxy, mixed site miss continues to the pool" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    tmp.dir.createDirPath(testing.io, "assets") catch @panic("fixture dir failed");
    writeFixture(tmp.dir, "assets/app.css", "body{}");

    var root_buf: [64]u8 = undefined;
    const root = fixtureRoot(&root_buf, &tmp);

    const upstreams = [_]site_cfg.Upstream{.{ .host = "127.0.0.1", .port = 39879 }};
    var pool = try upstream_pool.Pool.init(testing.allocator, &upstreams, upstream_pool.DEFAULT_COOLDOWN_MS);
    defer pool.deinit(testing.allocator);
    var idle = try upstream_conn.IdleCache.init(testing.allocator, 1);
    defer idle.deinit(testing.allocator, testing.io);
    const proxy = Proxy{
        .io = testing.io,
        .pool = &pool,
        .idle = &idle,
        .static = .{ .public_dir = root, .public_prefix = "/assets", .spa_fallback = null },
    };

    // Outside the prefix nothing is written and the request proxies.
    const api = try http1_head.parseRequest("GET /api/users HTTP/1.1\r\nHost: t\r\n\r\n");
    var api_buf: [512]u8 = undefined;
    var api_out = std.Io.Writer.fixed(&api_buf);
    try testing.expect(staticAnswer(&proxy, &api, &api_out) == null);
    try testing.expectEqual(@as(usize, 0), api_out.buffered().len);

    // A miss under the prefix also proxies on a mixed site.
    const miss = try http1_head.parseRequest("GET /assets/gone.css HTTP/1.1\r\nHost: t\r\n\r\n");
    var miss_buf: [512]u8 = undefined;
    var miss_out = std.Io.Writer.fixed(&miss_buf);
    try testing.expect(staticAnswer(&proxy, &miss, &miss_out) == null);

    // A hit under the prefix serves from disk.
    const hit = try http1_head.parseRequest("GET /assets/app.css HTTP/1.1\r\nHost: t\r\n\r\n");
    var hit_buf: [512]u8 = undefined;
    var hit_out = std.Io.Writer.fixed(&hit_buf);
    try testing.expectEqual(EdgeResult.KEEP, staticAnswer(&proxy, &hit, &hit_out).?);
    try testing.expect(std.mem.indexOf(u8, hit_out.buffered(), "Content-Type: text/css\r\n") != null);
}

test "zix zixer: http1 proxy, static request carrying a body closes the edge" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    writeFixture(tmp.dir, "app.js", "x()");

    var root_buf: [64]u8 = undefined;
    const root = fixtureRoot(&root_buf, &tmp);
    const proxy = Proxy{ .io = testing.io, .static = .{ .public_dir = root, .public_prefix = null, .spa_fallback = null } };

    const request = try http1_head.parseRequest("GET /app.js HTTP/1.1\r\nHost: t\r\nContent-Length: 3\r\n\r\n");
    var out_buf: [512]u8 = undefined;
    var out = std.Io.Writer.fixed(&out_buf);

    // The body was never read, so the head says close and the edge closes.
    try testing.expectEqual(EdgeResult.CLOSE, staticAnswer(&proxy, &request, &out).?);
    try testing.expect(std.mem.indexOf(u8, out.buffered(), "Connection: close\r\n") != null);
}

test "zix zixer: http1 proxy, mixed site serves static beside the pool end to end" {
    if (comptime @import("builtin").os.tag != .linux) return error.SkipZigTest;

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    tmp.dir.createDirPath(io, "assets") catch @panic("fixture dir failed");
    tmp.dir.writeFile(io, .{ .sub_path = "assets/app.js", .data = "let n=1" }) catch @panic("fixture write failed");

    var root_buf: [64]u8 = undefined;
    const root = fixtureRoot(&root_buf, &tmp);

    var fake = FakeUpstream{ .io = io, .port = 39880, .request_quota = 1 };
    const fake_thread = try std.Thread.spawn(.{}, FakeUpstream.serve, .{&fake});
    try waitReady(io, &fake);

    const upstreams = [_]site_cfg.Upstream{.{ .host = "127.0.0.1", .port = 39880 }};
    var pool = try upstream_pool.Pool.init(std.testing.allocator, &upstreams, upstream_pool.DEFAULT_COOLDOWN_MS);
    defer pool.deinit(std.testing.allocator);
    var idle = try upstream_conn.IdleCache.init(std.testing.allocator, 1);
    defer idle.deinit(std.testing.allocator, io);
    const proxy = Proxy{
        .io = io,
        .pool = &pool,
        .idle = &idle,
        .static = .{ .public_dir = root, .public_prefix = "/assets", .spa_fallback = null },
    };

    var fds: [2]std.posix.fd_t = undefined;
    try std.testing.expectEqual(@as(usize, 0), std.os.linux.socketpair(std.os.linux.AF.UNIX, std.os.linux.SOCK.STREAM, 0, &fds));
    const edge_thread = try spawnServeConn(&proxy, edgeStream(fds[0]));

    const client = edgeStream(fds[1]);
    var read_buf: [4096]u8 = undefined;
    var write_buf: [512]u8 = undefined;
    var reader = client.reader(io, &read_buf);
    var writer = client.writer(io, &write_buf);

    // First request hits the static plane and keeps the connection.
    try writer.interface.writeAll("GET /assets/app.js HTTP/1.1\r\nHost: t\r\n\r\n");
    try writer.interface.flush();
    var head_buf: [2048]u8 = undefined;
    const static_head = try http1_head.readHead(&reader.interface, &head_buf);
    const static_response = try http1_head.parseResponse(static_head, "GET");
    try std.testing.expectEqual(@as(u16, 200), static_response.status);
    var body: [64]u8 = undefined;
    const static_len: usize = @intCast(static_response.framing.content_length);
    _ = try reader.interface.readSliceShort(body[0..static_len]);
    try std.testing.expectEqualStrings("let n=1", body[0..static_len]);

    // Second request misses the prefix and crosses the pool.
    try writer.interface.writeAll("GET /api HTTP/1.1\r\nHost: t\r\nConnection: close\r\n\r\n");
    try writer.interface.flush();
    var head_buf2: [2048]u8 = undefined;
    const proxied_head = try http1_head.readHead(&reader.interface, &head_buf2);
    const proxied = try http1_head.parseResponse(proxied_head, "GET");
    try std.testing.expectEqual(@as(u16, 200), proxied.status);
    try std.testing.expect(std.mem.indexOf(u8, proxied_head, "Via: 1.1 zixer\r\n") != null);

    client.close(io);
    edge_thread.join();
    fake_thread.join();

    try std.testing.expectEqual(@as(usize, 1), fake.conns_accepted);
}

test "zix zixer: http1 proxy, acme webroot answers ahead of the static plane" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    tmp.dir.createDirPath(testing.io, "www") catch @panic("fixture dir failed");
    tmp.dir.createDirPath(testing.io, "acme/.well-known/acme-challenge") catch @panic("fixture dir failed");
    writeFixture(tmp.dir, "www/index.html", "static-index");
    writeFixture(tmp.dir, "acme/.well-known/acme-challenge/tok1", "acme-answer");

    var www_buf: [128]u8 = undefined;
    var acme_buf: [128]u8 = undefined;
    var root_buf: [64]u8 = undefined;
    const root = fixtureRoot(&root_buf, &tmp);
    const www = std.fmt.bufPrint(&www_buf, "{s}/www", .{root}) catch unreachable;
    const webroot = std.fmt.bufPrint(&acme_buf, "{s}/acme", .{root}) catch unreachable;

    const proxy = Proxy{
        .io = testing.io,
        .static = .{ .public_dir = www, .public_prefix = null, .spa_fallback = null },
        .acme = .{ .webroot = webroot },
    };

    var src = std.Io.Reader.fixed("GET /.well-known/acme-challenge/tok1 HTTP/1.1\r\nHost: t\r\n\r\n" ++
        "GET / HTTP/1.1\r\nHost: t\r\n\r\n");
    var out_buf: [2048]u8 = undefined;
    var out = std.Io.Writer.fixed(&out_buf);
    const addr = std.Io.net.IpAddress{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = 40001 } };

    serveLoop(&proxy, &src, &out, addr, null);
    const reply = out.buffered();

    const first = std.mem.indexOf(u8, reply, "acme-answer") orelse return error.TestUnexpectedResult;
    const second = std.mem.indexOf(u8, reply, "static-index") orelse return error.TestUnexpectedResult;
    try testing.expect(first < second);

    // the challenge reply is identity with no content negotiation promise.
    try testing.expect(std.mem.indexOf(u8, reply[0..first], "Content-Encoding") == null);
}

test "zix zixer: http1 proxy, acme relay unreachable answers 502 proxy-status" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const proxy = Proxy{
        .io = io,
        .acme = .{ .relay = .{ .host = "127.0.0.1", .port = 39892 } },
    };

    const request = try http1_head.parseRequest("GET /.well-known/acme-challenge/tok HTTP/1.1\r\nHost: t\r\n\r\n");
    var out_buf: [512]u8 = undefined;
    var out = std.Io.Writer.fixed(&out_buf);

    const result = acmeAnswer(&proxy, &request, &out).?;
    const reply = out.buffered();

    try testing.expectEqual(EdgeResult.CLOSE, result);
    try testing.expect(std.mem.startsWith(u8, reply, "HTTP/1.1 502 "));
    try testing.expect(std.mem.indexOf(u8, reply, "Proxy-Status: zixer; error=\"connection_refused\"\r\n") != null);
}

test "zix zixer: http1 proxy, tls certificate gate answers 421 on a foreign host" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const cert_pem = try std.Io.Dir.cwd().readFileAlloc(io, "examples/certs/ecdsa_p256_cert.pem", testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(cert_pem);
    var der_buf: [4096]u8 = undefined;
    const cert_der = try zix.Tls.pemToDer(&der_buf, cert_pem);

    const proxy = Proxy{ .io = io, .tls_cert_der = cert_der };
    const addr = std.Io.net.IpAddress{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = 40002 } };

    var foreign = std.Io.Reader.fixed("GET / HTTP/1.1\r\nHost: evil.example\r\n\r\n");
    var foreign_buf: [512]u8 = undefined;
    var foreign_out = std.Io.Writer.fixed(&foreign_buf);
    serveLoop(&proxy, &foreign, &foreign_out, addr, null);

    try testing.expect(std.mem.startsWith(u8, foreign_out.buffered(), "HTTP/1.1 421 misdirected request\r\n"));
    try testing.expect(std.mem.indexOf(u8, foreign_out.buffered(), "Connection: close\r\n") != null);

    // the certificate's own SAN passes the gate and reaches the next plane
    // (here: the static-only local 404).
    var own = std.Io.Reader.fixed("GET / HTTP/1.1\r\nHost: localhost:443\r\n\r\n");
    var own_buf: [512]u8 = undefined;
    var own_out = std.Io.Writer.fixed(&own_buf);
    serveLoop(&proxy, &own, &own_out, addr, null);

    try testing.expect(std.mem.startsWith(u8, own_out.buffered(), "HTTP/1.1 404 "));
}

test "zix zixer: http1 proxy, https redirect carries the site port" {
    const proxy = Proxy{ .io = testing.io, .redirect_https = 8443 };
    const addr = std.Io.net.IpAddress{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = 40003 } };

    var src = std.Io.Reader.fixed("GET /app/page HTTP/1.1\r\nHost: site.test:80\r\n\r\n");
    var out_buf: [512]u8 = undefined;
    var out = std.Io.Writer.fixed(&out_buf);
    serveLoop(&proxy, &src, &out, addr, null);

    try testing.expect(std.mem.startsWith(u8, out.buffered(), "HTTP/1.1 301 Moved Permanently\r\n"));
    try testing.expect(std.mem.indexOf(u8, out.buffered(), "Location: https://site.test:8443/app/page\r\n") != null);

    // port 443 keeps the Location port-free, no Host answers a local 404.
    const on_443 = try http1_head.parseRequest("GET /x HTTP/1.1\r\nHost: site.test\r\n\r\n");
    var plain_buf: [512]u8 = undefined;
    var plain_out = std.Io.Writer.fixed(&plain_buf);
    try testing.expectEqual(EdgeResult.KEEP, httpsRedirectAnswer(&on_443, &plain_out, 443));
    try testing.expect(std.mem.indexOf(u8, plain_out.buffered(), "Location: https://site.test/x\r\n") != null);

    const no_host = try http1_head.parseRequest("GET /x HTTP/1.1\r\n\r\n");
    var nh_buf: [512]u8 = undefined;
    var nh_out = std.Io.Writer.fixed(&nh_buf);
    _ = httpsRedirectAnswer(&no_host, &nh_out, 443);
    try testing.expect(std.mem.startsWith(u8, nh_out.buffered(), "HTTP/1.1 404 "));
}

// --------------------------------------------------------- //

test "zix zixer: http1 proxy, upgrade head rebuild carries the handshake pair" {
    const request = try http1_head.parseRequest("GET /chat HTTP/1.1\r\nHost: app.example\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Key: c2FtcGxlIG5vbmNl\r\nSec-WebSocket-Version: 13\r\n\r\n");

    var build_buf: [http1_head.MAX_HEAD_BYTES + 512]u8 = undefined;
    const addr = std.Io.net.IpAddress{ .ip4 = .{ .bytes = .{ 192, 0, 2, 7 }, .port = 55001 } };
    const head = try buildUpstreamHead(&build_buf, &request, addr, true);

    try testing.expect(std.mem.startsWith(u8, head, "GET /chat HTTP/1.1\r\n"));
    try testing.expect(std.mem.indexOf(u8, head, "Sec-WebSocket-Key: c2FtcGxlIG5vbmNl\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, head, "Sec-WebSocket-Version: 13\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, head, "Via: 1.1 zixer\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, head, "Connection: Upgrade\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, head, "Upgrade: websocket\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, head, "Content-Length") == null);

    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, head, "Connection:"));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, head, "Upgrade:"));
}

/// Writer probe for flush timing: records what the first flush delivered
/// and everything delivered overall.
const FlushProbe = struct {
    writer: std.Io.Writer,
    stage: [256]u8,
    delivered: [1024]u8,
    delivered_len: usize,
    first_flush: [256]u8,
    first_flush_len: usize,
    flush_count: usize,

    const vtable = std.Io.Writer.VTable{ .drain = drain, .flush = flush };

    fn bind(probe: *FlushProbe) void {
        probe.writer = .{ .vtable = &vtable, .buffer = &probe.stage, .end = 0 };
        probe.delivered_len = 0;
        probe.first_flush_len = 0;
        probe.flush_count = 0;
    }

    fn deliver(probe: *FlushProbe, bytes: []const u8) void {
        @memcpy(probe.delivered[probe.delivered_len..][0..bytes.len], bytes);
        probe.delivered_len += bytes.len;
    }

    fn drain(interface: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const probe: *FlushProbe = @alignCast(@fieldParentPtr("writer", interface));

        probe.deliver(interface.buffer[0..interface.end]);
        interface.end = 0;

        var consumed: usize = 0;
        for (data[0 .. data.len - 1]) |slice| {
            probe.deliver(slice);
            consumed += slice.len;
        }
        const last = data[data.len - 1];
        for (0..splat) |_| {
            probe.deliver(last);
            consumed += last.len;
        }

        return consumed;
    }

    fn flush(interface: *std.Io.Writer) std.Io.Writer.Error!void {
        const probe: *FlushProbe = @alignCast(@fieldParentPtr("writer", interface));

        probe.flush_count += 1;
        if (probe.flush_count == 1) {
            const staged = interface.buffer[0..interface.end];
            @memcpy(probe.first_flush[0..staged.len], staged);
            probe.first_flush_len = staged.len;
        }

        probe.deliver(interface.buffer[0..interface.end]);
        interface.end = 0;
    }
};

test "zix zixer: http1 proxy, chunked response relay flushes each chunk" {
    var src = std.Io.Reader.fixed("3\r\none\r\n3\r\ntwo\r\n0\r\n\r\n");
    var probe: FlushProbe = undefined;
    probe.bind();

    try pumpChunked(&src, &probe.writer, true);
    try probe.writer.flush();

    // The first chunk left on its own flush, ahead of the second chunk.
    try testing.expectEqualStrings("3\r\none\r\n", probe.first_flush[0..probe.first_flush_len]);
    try testing.expect(probe.flush_count >= 3);
    try testing.expectEqualStrings("3\r\none\r\n3\r\ntwo\r\n0\r\n\r\n", probe.delivered[0..probe.delivered_len]);
}

// --------------------------------------------------------- //

/// Test upstream that takes the websocket upgrade: answers 101, echoes raw
/// bytes until the peer ends, serves one session then exits. A connection
/// that never sends a head unblocks the accept wait (test teardown).
const FakeWsUpstream = struct {
    io: std.Io,
    port: u16,
    seen_head: [2048]u8 = undefined,
    seen_len: usize = 0,
    sessions: usize = 0,
    ready: std.atomic.Value(bool) = .init(false),

    fn serve(fake: *FakeWsUpstream) void {
        const io = fake.io;

        const addr = std.Io.net.IpAddress.parse("127.0.0.1", fake.port) catch return;
        var server = addr.listen(io, .{ .reuse_address = true, .kernel_backlog = 8 }) catch return;
        defer server.deinit(io);
        fake.ready.store(true, .release);

        const stream = server.accept(io) catch return;
        defer stream.close(io);

        var read_buf: [4096]u8 = undefined;
        var write_buf: [4096]u8 = undefined;
        var reader = stream.reader(io, &read_buf);
        var writer = stream.writer(io, &write_buf);

        const head = http1_head.readHead(&reader.interface, fake.seen_head[0..]) catch return;
        fake.seen_len = head.len;

        writer.interface.writeAll("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: test-accept\r\n\r\n") catch return;
        writer.interface.flush() catch return;
        fake.sessions += 1;

        while (true) {
            const got = reader.interface.stream(&writer.interface, .limited(1024)) catch break;
            if (got == 0) continue;

            writer.interface.flush() catch break;
        }
    }
};

/// Connect and close: unblocks a fake stuck in accept during teardown.
fn poke(io: std.Io, port: u16) void {
    const addr = std.Io.net.IpAddress.parse("127.0.0.1", port) catch return;
    const stream = addr.connect(io, .{ .mode = .stream, .protocol = .tcp }) catch return;

    stream.close(io);
}

fn waitReadyFlag(io: std.Io, flag: *std.atomic.Value(bool)) !void {
    var tries: usize = 0;
    while (tries < 100 and !flag.load(.acquire)) : (tries += 1) {
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(10), .awake) catch {};
    }

    try std.testing.expect(tries < 100);
}

test "zix zixer: http1 proxy, ws upgrade tunnels end to end and pins one upstream" {
    if (comptime @import("builtin").os.tag != .linux) return error.SkipZigTest;

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var fake_a = FakeWsUpstream{ .io = io, .port = 39883 };
    var fake_b = FakeWsUpstream{ .io = io, .port = 39884 };
    const thread_a = try std.Thread.spawn(.{}, FakeWsUpstream.serve, .{&fake_a});
    const thread_b = try std.Thread.spawn(.{}, FakeWsUpstream.serve, .{&fake_b});
    try waitReadyFlag(io, &fake_a.ready);
    try waitReadyFlag(io, &fake_b.ready);

    const upstreams = [_]site_cfg.Upstream{
        .{ .host = "127.0.0.1", .port = 39883 },
        .{ .host = "127.0.0.1", .port = 39884 },
    };
    var pool = try upstream_pool.Pool.init(std.testing.allocator, &upstreams, upstream_pool.DEFAULT_COOLDOWN_MS);
    defer pool.deinit(std.testing.allocator);
    var idle = try upstream_conn.IdleCache.init(std.testing.allocator, 2);
    defer idle.deinit(std.testing.allocator, io);
    const proxy = Proxy{ .io = io, .pool = &pool, .idle = &idle };

    var fds: [2]std.posix.fd_t = undefined;
    try std.testing.expectEqual(@as(usize, 0), std.os.linux.socketpair(std.os.linux.AF.UNIX, std.os.linux.SOCK.STREAM, 0, &fds));
    const edge_thread = try spawnServeConn(&proxy, edgeStream(fds[0]));

    const client = edgeStream(fds[1]);
    var read_buf: [4096]u8 = undefined;
    var write_buf: [512]u8 = undefined;
    var reader = client.reader(io, &read_buf);
    var writer = client.writer(io, &write_buf);

    try writer.interface.writeAll("GET /chat HTTP/1.1\r\nHost: t\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Key: c2FtcGxlIG5vbmNl\r\nSec-WebSocket-Version: 13\r\n\r\n");
    try writer.interface.flush();

    var head_buf: [2048]u8 = undefined;
    const switch_head = try http1_head.readHead(&reader.interface, &head_buf);
    try std.testing.expect(std.mem.startsWith(u8, switch_head, "HTTP/1.1 101 "));
    try std.testing.expect(std.mem.indexOf(u8, switch_head, "Sec-WebSocket-Accept: test-accept\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, switch_head, "Connection: Upgrade\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, switch_head, "Upgrade: websocket\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, switch_head, "Via: 1.1 zixer\r\n") != null);

    // Two echoes across one tunnel: both frames cross the same upstream.
    var echo: [9]u8 = undefined;
    try writer.interface.writeAll("frame-one");
    try writer.interface.flush();
    try reader.interface.readSliceAll(&echo);
    try std.testing.expectEqualStrings("frame-one", &echo);

    try writer.interface.writeAll("frame-two");
    try writer.interface.flush();
    try reader.interface.readSliceAll(&echo);
    try std.testing.expectEqualStrings("frame-two", &echo);

    client.close(io);
    edge_thread.join();

    poke(io, 39883);
    poke(io, 39884);
    thread_a.join();
    thread_b.join();

    // The pinned pick: exactly one upstream carried the whole session.
    try std.testing.expectEqual(@as(usize, 1), fake_a.sessions + fake_b.sessions);

    const seen = if (fake_a.seen_len != 0) fake_a.seen_head[0..fake_a.seen_len] else fake_b.seen_head[0..fake_b.seen_len];
    try std.testing.expect(std.mem.indexOf(u8, seen, "Connection: Upgrade\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, seen, "Upgrade: websocket\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, seen, "Sec-WebSocket-Key: c2FtcGxlIG5vbmNl\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, seen, "Via: 1.1 zixer\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, seen, "Forwarded: ") != null);
}

test "zix zixer: http1 proxy, ws upgrade refused relays the plain response" {
    if (comptime @import("builtin").os.tag != .linux) return error.SkipZigTest;

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // FakeUpstream never upgrades: the offer crosses, the answer is 200.
    var fake = FakeUpstream{ .io = io, .port = 39889, .request_quota = 1 };
    const fake_thread = try std.Thread.spawn(.{}, FakeUpstream.serve, .{&fake});
    try waitReady(io, &fake);

    const upstreams = [_]site_cfg.Upstream{.{ .host = "127.0.0.1", .port = 39889 }};
    var pool = try upstream_pool.Pool.init(std.testing.allocator, &upstreams, upstream_pool.DEFAULT_COOLDOWN_MS);
    defer pool.deinit(std.testing.allocator);
    var idle = try upstream_conn.IdleCache.init(std.testing.allocator, 1);
    defer idle.deinit(std.testing.allocator, io);
    const proxy = Proxy{ .io = io, .pool = &pool, .idle = &idle };

    var fds: [2]std.posix.fd_t = undefined;
    try std.testing.expectEqual(@as(usize, 0), std.os.linux.socketpair(std.os.linux.AF.UNIX, std.os.linux.SOCK.STREAM, 0, &fds));
    const edge_thread = try spawnServeConn(&proxy, edgeStream(fds[0]));

    const client = edgeStream(fds[1]);
    {
        var write_buf: [512]u8 = undefined;
        var writer = client.writer(io, &write_buf);
        try writer.interface.writeAll("GET /chat HTTP/1.1\r\nHost: t\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Key: c2FtcGxlIG5vbmNl\r\n\r\n");
        try writer.interface.flush();
    }

    var read_buf: [4096]u8 = undefined;
    var reader = client.reader(io, &read_buf);
    var head_buf: [2048]u8 = undefined;
    const head = try http1_head.readHead(&reader.interface, &head_buf);
    const response = try http1_head.parseResponse(head, "GET");
    try std.testing.expectEqual(@as(u16, 200), response.status);
    try std.testing.expect(std.mem.indexOf(u8, head, "Via: 1.1 zixer\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, head, "Upgrade") == null);

    var body: [64]u8 = undefined;
    const body_len: usize = @intCast(response.framing.content_length);
    try reader.interface.readSliceAll(body[0..body_len]);
    try std.testing.expectEqualStrings("echo:", body[0..body_len]);

    client.close(io);
    edge_thread.join();
    fake_thread.join();

    const seen = fake.seen_head[0..fake.seen_len];
    try std.testing.expect(std.mem.indexOf(u8, seen, "Connection: Upgrade\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, seen, "Upgrade: websocket\r\n") != null);
}

/// Test upstream for the SSE shape: an until-close response, one event
/// now, the second only after the client acknowledged the first. saw_ack
/// records whether the acknowledgment arrived inside the bounded wait.
const FakeSseUpstream = struct {
    io: std.Io,
    port: u16,
    release_second: std.atomic.Value(bool) = .init(false),
    saw_ack: bool = false,
    ready: std.atomic.Value(bool) = .init(false),

    fn serve(fake: *FakeSseUpstream) void {
        const io = fake.io;

        const addr = std.Io.net.IpAddress.parse("127.0.0.1", fake.port) catch return;
        var server = addr.listen(io, .{ .reuse_address = true, .kernel_backlog = 8 }) catch return;
        defer server.deinit(io);
        fake.ready.store(true, .release);

        const stream = server.accept(io) catch return;
        defer stream.close(io);

        var read_buf: [4096]u8 = undefined;
        var write_buf: [4096]u8 = undefined;
        var reader = stream.reader(io, &read_buf);
        var writer = stream.writer(io, &write_buf);

        var head_buf: [2048]u8 = undefined;
        _ = http1_head.readHead(&reader.interface, &head_buf) catch return;

        writer.interface.writeAll("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\ndata: one\n\n") catch return;
        writer.interface.flush() catch return;

        var tries: usize = 0;
        while (tries < 400 and !fake.release_second.load(.acquire)) : (tries += 1) {
            std.Io.sleep(io, std.Io.Duration.fromMilliseconds(5), .awake) catch {};
        }
        fake.saw_ack = fake.release_second.load(.acquire);

        writer.interface.writeAll("data: two\n\n") catch return;
        writer.interface.flush() catch return;
    }
};

test "zix zixer: http1 proxy, sse stream relays each event as it arrives" {
    if (comptime @import("builtin").os.tag != .linux) return error.SkipZigTest;

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var fake = FakeSseUpstream{ .io = io, .port = 39876 };
    const fake_thread = try std.Thread.spawn(.{}, FakeSseUpstream.serve, .{&fake});
    try waitReadyFlag(io, &fake.ready);

    const upstreams = [_]site_cfg.Upstream{.{ .host = "127.0.0.1", .port = 39876 }};
    var pool = try upstream_pool.Pool.init(std.testing.allocator, &upstreams, upstream_pool.DEFAULT_COOLDOWN_MS);
    defer pool.deinit(std.testing.allocator);
    var idle = try upstream_conn.IdleCache.init(std.testing.allocator, 1);
    defer idle.deinit(std.testing.allocator, io);
    const proxy = Proxy{ .io = io, .pool = &pool, .idle = &idle };

    var fds: [2]std.posix.fd_t = undefined;
    try std.testing.expectEqual(@as(usize, 0), std.os.linux.socketpair(std.os.linux.AF.UNIX, std.os.linux.SOCK.STREAM, 0, &fds));
    const edge_thread = try spawnServeConn(&proxy, edgeStream(fds[0]));

    const client = edgeStream(fds[1]);
    var read_buf: [4096]u8 = undefined;
    var write_buf: [512]u8 = undefined;
    var reader = client.reader(io, &read_buf);
    var writer = client.writer(io, &write_buf);

    try writer.interface.writeAll("GET /events HTTP/1.1\r\nHost: t\r\n\r\n");
    try writer.interface.flush();

    var head_buf: [2048]u8 = undefined;
    const head = try http1_head.readHead(&reader.interface, &head_buf);
    try std.testing.expect(std.mem.startsWith(u8, head, "HTTP/1.1 200 OK\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, head, "Content-Type: text/event-stream\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, head, "Connection: close\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, head, "Content-Length") == null);

    // The first event arrives while the upstream still holds the stream
    // open, that is the streamed passthrough.
    var event_one: [11]u8 = undefined;
    try reader.interface.readSliceAll(&event_one);
    try std.testing.expectEqualStrings("data: one\n\n", &event_one);
    fake.release_second.store(true, .release);

    var rest_buf: [64]u8 = undefined;
    var rest_len: usize = 0;
    while (rest_len < rest_buf.len) {
        const got = reader.interface.readSliceShort(rest_buf[rest_len .. rest_len + 1]) catch break;
        if (got == 0) break;
        rest_len += got;
    }
    try std.testing.expectEqualStrings("data: two\n\n", rest_buf[0..rest_len]);

    client.close(io);
    edge_thread.join();
    fake_thread.join();

    try std.testing.expect(fake.saw_ack);
}
