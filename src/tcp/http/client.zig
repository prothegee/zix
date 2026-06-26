//! zix http client

const std = @import("std");
const Config = @import("client_config.zig");
const HttpClientConfig = Config.HttpClientConfig;
const Method = @import("method.zig");
const h2_client = @import("h2_client.zig");

/// Request body write buffer.
const REQUEST_WRITE_BUF: usize = 8192;
/// Response body transfer buffer.
const BODY_TRANSFER_BUF: usize = 4096;
/// Request path build buffer.
const REQUEST_PATH_BUF: usize = 2048;
/// Request build buffer (request line plus headers).
const REQUEST_BUILD_BUF: usize = 4096;
/// Response head scan buffer.
const HEAD_SCAN_BUF: usize = 8192;
/// Body read chunk buffer.
const BODY_READ_CHUNK: usize = 4096;
/// Response head buffer for a redirect hop (caps the redirect response head size).
const REDIRECT_HEAD_BUF: usize = 8 * 1024;

// --------------------------------------------------------- //

/// Options for a single HTTP request. All fields that accept null use the client config value.
pub const RequestOpts = struct {
    /// Additional request headers. Slice must outlive the request call.
    headers: []const std.http.Header = &.{},
    /// Request body bytes. null means no body.
    /// For methods that require a body (POST, PUT, PATCH), null sends Content-Length: 0.
    /// For methods that disallow a body (GET, HEAD, DELETE, OPTIONS, TRACE), body is ignored.
    body: ?[]const u8 = null,
    /// Per-request connect timeout in milliseconds. null uses the client config value.
    connect_timeout_ms: ?u32 = null,
};

// --------------------------------------------------------- //

/// Parsed HTTP response. Caller must call deinit() to release owned memory.
pub const ClientResponse = struct {
    const Self = @This();

    status_code: u16,
    /// Owned body bytes. Released by deinit().
    body_data: []u8,
    /// Owned copy of the raw response head (status line and headers). Released by deinit().
    head_bytes: []u8,
    allocator: std.mem.Allocator,

    // --------------------------------------------------------- //

    /// HTTP status code (e.g. 200, 404).
    pub fn status(self: Self) u16 {
        return self.status_code;
    }

    /// First value of the named response header (case-insensitive). null when absent.
    pub fn header(self: Self, name: []const u8) ?[]const u8 {
        var it = std.http.HeaderIterator.init(self.head_bytes);
        while (it.next()) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
        }
        return null;
    }

    /// Iterator over all response headers as name/value pairs.
    pub fn iterateHeaders(self: Self) std.http.HeaderIterator {
        return std.http.HeaderIterator.init(self.head_bytes);
    }

    /// Response body bytes. Empty slice when the server sent no body.
    pub fn body(self: Self) []const u8 {
        return self.body_data;
    }

    /// Release body and head memory.
    pub fn deinit(self: *Self) void {
        if (self.body_data.len > 0) self.allocator.free(self.body_data);
        if (self.head_bytes.len > 0) self.allocator.free(self.head_bytes);
    }
};

// --------------------------------------------------------- //

/// HTTP client. One instance can make many sequential requests, reusing connections via the pool.
///
/// Usage:
/// ```zig
/// var client = zix.Http.Client.init(config);
/// defer client.deinit();
/// var resp = try client.get("http://localhost:9000/", .{});
/// defer resp.deinit();
/// std.debug.print("{d}: {s}\n", .{ resp.status(), resp.body() });
/// ```
pub const HttpClient = struct {
    const Self = @This();

    config: HttpClientConfig,
    inner: std.http.Client,

    // --------------------------------------------------------- //

    /// Initialise the client. No connections are opened until the first request.
    pub fn init(config: HttpClientConfig) Self {
        return .{
            .config = config,
            .inner = .{ .allocator = config.allocator, .io = config.io },
        };
    }

    /// Close all pooled connections and free client memory.
    /// Must not be called while a request is in flight.
    pub fn deinit(self: *Self) void {
        self.inner.deinit();
    }

    // --------------------------------------------------------- //

    pub fn get(self: *Self, url: []const u8, opts: RequestOpts) !ClientResponse {
        return self.request(.GET, url, opts);
    }

    pub fn head(self: *Self, url: []const u8, opts: RequestOpts) !ClientResponse {
        return self.request(.HEAD, url, opts);
    }

    pub fn post(self: *Self, url: []const u8, opts: RequestOpts) !ClientResponse {
        return self.request(.POST, url, opts);
    }

    pub fn put(self: *Self, url: []const u8, opts: RequestOpts) !ClientResponse {
        return self.request(.PUT, url, opts);
    }

    pub fn delete(self: *Self, url: []const u8, opts: RequestOpts) !ClientResponse {
        return self.request(.DELETE, url, opts);
    }

    pub fn patch(self: *Self, url: []const u8, opts: RequestOpts) !ClientResponse {
        return self.request(.PATCH, url, opts);
    }

    // --------------------------------------------------------- //

    /// Make an HTTP request and return the parsed response.
    ///
    /// Note:
    /// - HTTP_2 (config.version) takes the native h2-over-TLS path (requestHttp2), https only.
    ///   HTTP_3 returns error.UnsupportedVersion.
    ///
    /// Errors (named):
    /// error.InvalidUrl          - malformed URL, unsupported scheme, or missing host
    /// error.BodyTooLarge        - response body exceeded config.max_response_body bytes
    /// error.UnsupportedVersion  - config.version is HTTP_3
    /// error.UnsupportedScheme   - HTTP_2 was requested for a non-https URL
    /// error.TlsNoTrustAnchor    - HTTP_2 with tls_verify set but no tls_ca_path
    ///
    /// Other errors propagate from std.http.Client (network failures, protocol errors, OOM).
    pub fn request(self: *Self, method: Method.Code, url: []const u8, opts: RequestOpts) !ClientResponse {
        switch (self.config.version) {
            .HTTP_1 => {},
            .HTTP_2 => return self.requestHttp2(method, url, opts),
            .HTTP_3 => return error.UnsupportedVersion,
        }

        const gpa = self.config.allocator;

        const uri = std.Uri.parse(url) catch return error.InvalidUrl;
        const protocol = std.http.Client.Protocol.fromUri(uri) orelse return error.InvalidUrl;

        var host_buf: [std.Io.net.HostName.max_len]u8 = undefined;
        const host_name = uri.getHost(&host_buf) catch return error.InvalidUrl;
        const port = uri.port orelse switch (protocol) {
            .plain => @as(u16, 80),
            .tls => @as(u16, 443),
        };

        const connect_ms = opts.connect_timeout_ms orelse self.config.connect_timeout_ms;
        const timeout: std.Io.Timeout = if (connect_ms > 0) .{
            .duration = .{
                .raw = std.Io.Duration.fromMilliseconds(@as(i64, connect_ms)),
                .clock = .real,
            },
        } else .none;

        // https needs the inner std.http.Client's realtime clock + CA bundle set before the
        // handshake (zix connects directly, so std's own lazy init in its request flow does not
        // run first). Use std's own clock choice (Io.Clock.real), load the system roots, then add
        // the configured extra CA (tls_ca_path). Done once.
        if (protocol == .tls and self.inner.now == null) {
            const now = std.Io.Clock.real.now(self.config.io);
            self.inner.ca_bundle.rescan(gpa, self.config.io, now) catch {};
            if (self.config.tls_ca_path) |ca_path| {
                self.inner.ca_bundle.addCertsFromFilePath(gpa, self.config.io, now, std.Io.Dir.cwd(), ca_path) catch return error.TlsCaLoadFailed;
            }
            self.inner.now = now;
        }

        const conn = try self.inner.connectTcpOptions(.{
            .host = host_name,
            .port = port,
            .protocol = protocol,
            .timeout = timeout,
        });

        const redirect_behavior: std.http.Client.Request.RedirectBehavior = if (!self.config.follow_redirects)
            .unhandled
        else if (self.config.max_redirects == 0)
            .not_allowed
        else
            std.http.Client.Request.RedirectBehavior.init(@as(u16, self.config.max_redirects));

        const std_method = methodToStd(method);
        var req = try self.inner.request(std_method, uri, .{
            .connection = conn,
            .redirect_behavior = redirect_behavior,
            .extra_headers = opts.headers,
            .headers = .{
                .user_agent = if (self.config.user_agent.len > 0)
                    .{ .override = self.config.user_agent }
                else
                    .omit,
            },
        });
        defer req.deinit();

        if (std_method.requestHasBody()) {
            const b = opts.body orelse &.{};
            req.transfer_encoding = .{ .content_length = b.len };
            var write_buf: [REQUEST_WRITE_BUF]u8 = undefined;
            var body_writer = try req.sendBodyUnflushed(&write_buf);
            if (b.len > 0) try body_writer.writer.writeAll(b);
            try body_writer.end();
        } else {
            try req.sendBodiless();
        }

        var redirect_buf: [REDIRECT_HEAD_BUF]u8 = undefined;
        var response = try req.receiveHead(&redirect_buf);

        // Copy head bytes before response.reader() invalidates the pointer.
        const head_copy = try gpa.dupe(u8, response.head.bytes);
        errdefer gpa.free(head_copy);

        const status_code: u16 = @intFromEnum(response.head.status);

        var transfer_buf: [BODY_TRANSFER_BUF]u8 = undefined;
        const body_reader = response.reader(&transfer_buf);
        const body_bytes = body_reader.allocRemaining(gpa, .limited(self.config.max_response_body)) catch |err| switch (err) {
            error.StreamTooLong => return error.BodyTooLarge,
            else => |e| return e,
        };

        return .{
            .status_code = status_code,
            .body_data = body_bytes,
            .head_bytes = head_copy,
            .allocator = gpa,
        };
    }

    // --------------------------------------------------------- //

    /// HTTP/2 over TLS 1.3 via the native zix.Tls client (the h2_client transport). https only,
    /// since h2 here is always ALPN-negotiated over TLS. Trust + cert verification follow the config
    /// (tls_verify / tls_ca_path), see h2_client.fetch.
    fn requestHttp2(self: *Self, method: Method.Code, url: []const u8, opts: RequestOpts) !ClientResponse {
        const gpa = self.config.allocator;

        const uri = std.Uri.parse(url) catch return error.InvalidUrl;
        if (!std.ascii.eqlIgnoreCase(uri.scheme, "https")) return error.UnsupportedScheme;

        var host_buf: [std.Io.net.HostName.max_len]u8 = undefined;
        const host_name = uri.getHost(&host_buf) catch return error.InvalidUrl;
        const port = uri.port orelse 443;

        // origin-form request target (:path), the path plus any query, e.g. "/echo?foo=bar".
        var path_buf: [REQUEST_PATH_BUF]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{f}", .{uri.fmt(.{ .path = true, .query = true })}) catch return error.InvalidUrl;

        const parts = try h2_client.fetch(self.config, method, host_name, port, path, opts.headers, opts.body);

        return .{
            .status_code = parts.status_code,
            .body_data = parts.body_data,
            .head_bytes = parts.head_bytes,
            .allocator = gpa,
        };
    }

    // --------------------------------------------------------- //

    /// Make an HTTP/1.1 GET over a Unix domain socket.
    ///
    /// Param:
    /// socket_path - []const u8 (path to the Unix socket file)
    /// http_path   - []const u8 (HTTP path, e.g. "/api/v1/info")
    /// opts        - RequestOpts
    ///
    /// Return:
    /// - ClientResponse
    /// - error.UdsNotSupported (non-Unix platform)
    /// - error.InvalidPath (path rejected by the OS)
    pub fn getUds(self: *Self, socket_path: []const u8, http_path: []const u8, opts: RequestOpts) !ClientResponse {
        return self.requestUds(.GET, socket_path, http_path, opts);
    }

    /// Make an HTTP/1.1 POST over a Unix domain socket.
    ///
    /// Param:
    /// socket_path - []const u8 (path to the Unix socket file)
    /// http_path   - []const u8 (HTTP path)
    /// opts        - RequestOpts
    ///
    /// Return:
    /// - ClientResponse
    pub fn postUds(self: *Self, socket_path: []const u8, http_path: []const u8, opts: RequestOpts) !ClientResponse {
        return self.requestUds(.POST, socket_path, http_path, opts);
    }

    /// Make an HTTP/1.1 request over a Unix domain socket.
    ///
    /// Note:
    /// - Sends Connection: close so the server closes after the response.
    ///   Content-Length is read when present, otherwise body is read until EOF.
    /// - wss:// and TLS are not supported. Use the TCP-based request() for those.
    ///
    /// Param:
    /// method      - Method.Code
    /// socket_path - []const u8 (path to the Unix socket file)
    /// http_path   - []const u8 (HTTP path, e.g. "/v1/info")
    /// opts        - RequestOpts
    ///
    /// Return:
    /// - ClientResponse
    /// - error.UdsNotSupported (non-Unix platform)
    /// - error.InvalidPath (socket path rejected by OS, e.g. too long)
    /// - error.BodyTooLarge (response body exceeded config.max_response_body)
    pub fn requestUds(self: *Self, method: Method.Code, socket_path: []const u8, http_path: []const u8, opts: RequestOpts) !ClientResponse {
        if (comptime !std.Io.net.has_unix_sockets) return error.UdsNotSupported;

        const gpa = self.config.allocator;

        const unix_addr = std.Io.net.UnixAddress.init(socket_path) catch return error.InvalidPath;
        const uds_stream = try unix_addr.connect(self.config.io);
        defer uds_stream.close(self.config.io);
        const fd = uds_stream.socket.handle;

        const method_name = udsMethodStr(method);

        var req_buf: [REQUEST_BUILD_BUF]u8 = undefined;
        var req_len: usize = 0;

        const status_line = std.fmt.bufPrint(
            req_buf[req_len..],
            "{s} {s} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n",
            .{ method_name, http_path },
        ) catch return error.InvalidPath;
        req_len += status_line.len;

        for (opts.headers) |hdr| {
            const h = std.fmt.bufPrint(req_buf[req_len..], "{s}: {s}\r\n", .{ hdr.name, hdr.value }) catch break;
            req_len += h.len;
        }

        if (opts.body) |body| {
            const cl_line = std.fmt.bufPrint(req_buf[req_len..], "Content-Length: {d}\r\n\r\n", .{body.len}) catch return error.InvalidPath;
            req_len += cl_line.len;
            try udsWriteAll(fd, req_buf[0..req_len]);
            try udsWriteAll(fd, body);
        } else {
            const end = std.fmt.bufPrint(req_buf[req_len..], "\r\n", .{}) catch return error.InvalidPath;
            req_len += end.len;
            try udsWriteAll(fd, req_buf[0..req_len]);
        }

        var head_scan_buf: [HEAD_SCAN_BUF]u8 = undefined;
        var head_scan_len: usize = 0;
        var header_end: usize = 0;

        while (head_scan_len < head_scan_buf.len) {
            const n = std.posix.read(fd, head_scan_buf[head_scan_len..]) catch return error.ConnectionClosed;
            if (n == 0) return error.ConnectionClosed;
            head_scan_len += n;
            if (std.mem.indexOf(u8, head_scan_buf[0..head_scan_len], "\r\n\r\n")) |pos| {
                header_end = pos + 4;
                break;
            }
        }

        if (header_end == 0) return error.InvalidResponse;

        const head_raw = head_scan_buf[0..header_end];

        const status_code: u16 = blk: {
            const first_line_end = std.mem.indexOfScalar(u8, head_raw, '\r') orelse break :blk 0;
            const first_line = head_raw[0..first_line_end];
            const space1 = std.mem.indexOfScalar(u8, first_line, ' ') orelse break :blk 0;
            const after_sp = first_line[space1 + 1 ..];
            const space2 = std.mem.indexOfScalar(u8, after_sp, ' ') orelse after_sp.len;
            break :blk std.fmt.parseInt(u16, after_sp[0..space2], 10) catch 0;
        };

        const head_copy = try gpa.dupe(u8, head_raw);
        errdefer gpa.free(head_copy);

        const content_length: ?usize = blk: {
            const cl_val = udsResponseHeader(head_raw, "content-length") orelse break :blk null;
            break :blk std.fmt.parseInt(usize, std.mem.trim(u8, cl_val, " \t"), 10) catch null;
        };

        const already_read = head_scan_len - header_end;

        var body_list: std.ArrayList(u8) = .empty;
        errdefer body_list.deinit(gpa);

        if (content_length) |cl| {
            if (cl > self.config.max_response_body) return error.BodyTooLarge;
            try body_list.resize(gpa, cl);
            const initial = @min(already_read, cl);
            @memcpy(body_list.items[0..initial], head_scan_buf[header_end..][0..initial]);
            var body_received = initial;
            while (body_received < cl) {
                const n = std.posix.read(fd, body_list.items[body_received..]) catch break;
                if (n == 0) break;
                body_received += n;
            }
        } else {
            if (already_read > 0) try body_list.appendSlice(gpa, head_scan_buf[header_end..][0..already_read]);
            var read_chunk: [BODY_READ_CHUNK]u8 = undefined;
            while (true) {
                const n = std.posix.read(fd, &read_chunk) catch break;
                if (n == 0) break;
                if (body_list.items.len + n > self.config.max_response_body) return error.BodyTooLarge;
                try body_list.appendSlice(gpa, read_chunk[0..n]);
            }
        }

        const body_bytes = try body_list.toOwnedSlice(gpa);

        return ClientResponse{
            .status_code = status_code,
            .body_data = body_bytes,
            .head_bytes = head_copy,
            .allocator = gpa,
        };
    }

    // --------------------------------------------------------- //

    fn methodToStd(m: Method.Code) std.http.Method {
        return switch (m) {
            .GET => .GET,
            .HEAD => .HEAD,
            .POST => .POST,
            .PUT => .PUT,
            .DELETE => .DELETE,
            .PATCH => .PATCH,
            .OPTIONS => .OPTIONS,
            .TRACE => .TRACE,
            .CONNECT => .CONNECT,
        };
    }
};

// --------------------------------------------------------- //

fn udsMethodStr(m: Method.Code) []const u8 {
    return switch (m) {
        .GET => "GET",
        .HEAD => "HEAD",
        .POST => "POST",
        .PUT => "PUT",
        .DELETE => "DELETE",
        .PATCH => "PATCH",
        .OPTIONS => "OPTIONS",
        .TRACE => "TRACE",
        .CONNECT => "CONNECT",
    };
}

fn udsWriteAll(fd: std.posix.fd_t, data: []const u8) !void {
    var written: usize = 0;
    while (written < data.len) {
        const rc = std.posix.system.write(fd, data[written..].ptr, data.len - written);
        switch (std.posix.errno(rc)) {
            .SUCCESS => {
                const n: usize = @intCast(rc);
                if (n == 0) return error.BrokenPipe;
                written += n;
            },
            .INTR => continue,
            else => return error.BrokenPipe,
        }
    }
}

fn udsResponseHeader(head: []const u8, name: []const u8) ?[]const u8 {
    var it = std.mem.splitSequence(u8, head, "\r\n");
    _ = it.next();
    while (it.next()) |line| {
        const colon_pos = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const header_name = std.mem.trim(u8, line[0..colon_pos], " \t");
        if (std.ascii.eqlIgnoreCase(header_name, name)) {
            return std.mem.trim(u8, line[colon_pos + 1 ..], " \t");
        }
    }
    return null;
}

// --------------------------------------------------------------- //
// --------------------------------------------------------------- //

test "zix test: http client, HTTP_2 over a non-https URL is rejected before connecting" {
    // requestHttp2 checks the scheme up front, so io is never touched (undefined is safe here).
    var client = HttpClient.init(.{
        .allocator = std.testing.allocator,
        .io = undefined,
        .version = .HTTP_2,
    });
    defer client.deinit();

    try std.testing.expectError(error.UnsupportedScheme, client.get("http://localhost:9061/", .{}));
}

test "zix test: http client, HTTP_3 still yields UnsupportedVersion" {
    var client = HttpClient.init(.{
        .allocator = std.testing.allocator,
        .io = undefined,
        .version = .HTTP_3,
    });
    defer client.deinit();

    try std.testing.expectError(error.UnsupportedVersion, client.get("https://localhost:9061/", .{}));
}
