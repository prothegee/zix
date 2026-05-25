//! zix http client

const std = @import("std");
const Config = @import("client_config.zig");
const HttpClientConfig = Config.HttpClientConfig;
const Method = @import("method.zig");

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
    /// Errors (named):
    ///   error.InvalidUrl    - malformed URL, unsupported scheme, or missing host
    ///   error.BodyTooLarge  - response body exceeded config.max_response_body bytes
    ///
    /// Other errors propagate from std.http.Client (network failures, protocol errors, OOM).
    pub fn request(self: *Self, method: Method.Code, url: []const u8, opts: RequestOpts) !ClientResponse {
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
            var write_buf: [8192]u8 = undefined;
            var bw = try req.sendBodyUnflushed(&write_buf);
            if (b.len > 0) try bw.writer.writeAll(b);
            try bw.end();
        } else {
            try req.sendBodiless();
        }

        var redirect_buf: [8 * 1024]u8 = undefined;
        var response = try req.receiveHead(&redirect_buf);

        // Copy head bytes before response.reader() invalidates the pointer.
        const head_copy = try gpa.dupe(u8, response.head.bytes);
        errdefer gpa.free(head_copy);

        const status_code: u16 = @intFromEnum(response.head.status);

        var transfer_buf: [4096]u8 = undefined;
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
