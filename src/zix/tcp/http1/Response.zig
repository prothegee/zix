//! ZIX Http1 response
//!
//! ### file: src/zix/tcp/http1/Response.zig
//! 
//! ### author: Prana Ron
//! 
//! ---------------------------------------------------------
//! 
//! ### brief:
//! 
//! n/a
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
const core = @import("core.zig");
const Status = @import("../../utils/http/status.zig");
const Content = @import("../../utils/http/content.zig");
const HttpHeader = @import("HttpHeader.zig");
const Request = @import("Request.zig");
const compression = @import("../../utils/compression/compression.zig");
const SseWriter = @import("SseWriter.zig");

// --------------------------------------------------------- //

fd: std.posix.fd_t,
io: std.Io,
allocator: std.mem.Allocator,
sent: bool = false,
status: Status.Code = .OK,
content_type: ?Content.Type = null,
keep_alive: ?bool = null,
bytes_written: usize = 0,
extra_buf: ?[]HttpHeader = null,
extra_len: usize = 0,

const Self = @This();

// --------------------------------------------------------- //

/// Scratch for one extra header line during a streamed header write.
const EXTRA_HEADER_BUF: usize = 256;

fn appendBytes(buf: []u8, pos: usize, str: []const u8) usize {
    @memcpy(buf[pos..][0..str.len], str);
    return pos + str.len;
}

fn contentTypeString(self: *const Self) []const u8 {
    return if (self.content_type) |content_type| content_type.asString() else "";
}

/// Serialize the full response (base headers, extra headers, Connection
/// override, body) into one arena buffer. Same byte layout as the fast path
/// with the extra lines spliced in before the final CRLF.
fn buildFull(self: *Self, body: []const u8) ![]u8 {
    var extra_bytes: usize = 0;
    if (self.extra_buf) |extra| {
        for (extra[0..self.extra_len]) |hdr| extra_bytes += hdr.name.len + hdr.value.len + 4;
    }
    if (self.keep_alive != null) extra_bytes += "Connection: keep-alive\r\n".len;

    const buf = try self.allocator.alloc(u8, core.HEADER_BUF_SIZE + extra_bytes + body.len);
    const base_len = try core.buildSimpleHeaderInto(buf, self.status, self.contentTypeString(), body.len);

    var pos = base_len - 2;
    if (self.extra_buf) |extra| {
        for (extra[0..self.extra_len]) |hdr| {
            pos = appendBytes(buf, pos, hdr.name);
            pos = appendBytes(buf, pos, ": ");
            pos = appendBytes(buf, pos, hdr.value);
            pos = appendBytes(buf, pos, "\r\n");
        }
    }
    if (self.keep_alive) |keep_alive| {
        pos = appendBytes(buf, pos, if (keep_alive) "Connection: keep-alive\r\n" else "Connection: close\r\n");
    }
    pos = appendBytes(buf, pos, "\r\n");
    pos = appendBytes(buf, pos, body);

    return buf[0..pos];
}

// --------------------------------------------------------- //

/// ZIX Http1 Response error
pub const Error = error {
    ZixHttp1_Response_TooManyHeaders,
    ZixHttp1_Response_ErrorHeaderName,
    ZixHttp1_Response_ErrorHeaderValue,
    ZixHttp1_Response_BrokenPipe,
};

/// Build a response over a connection fd.
///
/// Param:
/// fd - std.posix.fd_t (the connection)
/// io - std.Io (the worker io, carried for symmetry with Context)
/// allocator - std.mem.Allocator (per-request scratch)
///
/// Return:
/// - Response
pub fn init(fd: std.posix.fd_t, io: std.Io, allocator: std.mem.Allocator) Self {
    return .{ .fd = fd, .io = io, .allocator = allocator };
}

/// Set the response status code.
pub fn setStatus(self: *Self, status: Status.Code) void {
    self.status = status;
}

/// Set the Content-Type.
pub fn setContentType(self: *Self, content_type: Content.Type) void {
    self.content_type = content_type;
}

/// Set the Connection header for this response. The engine's connection
/// lifetime still follows the request head: false emits Connection: close
/// (the client closes, the engine then reaps the socket), true emits
/// Connection: keep-alive (e.g. for an HTTP/1.0 client).
pub fn setKeepAlive(self: *Self, keep_alive: bool) void {
    self.keep_alive = keep_alive;
}

/// Append a custom header to the response.
/// Allocates the full header buffer on the first call (lazy, capacity =
/// config.max_response_headers via the worker install).
///
/// Return:
/// - Error.ZixHttp1_Response_TooManyHeaders if the header cap is exceeded
/// - Error.ZixHttp1_Response_ErrorHeaderName or Error.ZixHttp1_Response_ErrorHeaderValue on CR/LF injection
pub fn addHeader(self: *Self, name: []const u8, value: []const u8) !void {
    for (name) |byte| if (byte == '\r' or byte == '\n') return Error.ZixHttp1_Response_ErrorHeaderName;
    for (value) |byte| if (byte == '\r' or byte == '\n') return Error.ZixHttp1_Response_ErrorHeaderValue;

    if (self.extra_buf == null) {
        if (core.tl_max_response_headers == 0) return Error.ZixHttp1_Response_TooManyHeaders;
        self.extra_buf = try self.allocator.alloc(HttpHeader, core.tl_max_response_headers);
    }
    if (self.extra_len >= self.extra_buf.?.len) return Error.ZixHttp1_Response_TooManyHeaders;

    self.extra_buf.?[self.extra_len] = .{ .name = name, .value = value };
    self.extra_len += 1;
}

/// Send body with the current status and Content-Type. With no extra
/// headers this is byte-identical to a direct core.sendSimpleFD and routes
/// through the coalescing sink when the .EPOLL or .URING worker has one
/// installed. With extra headers (or a Connection override) the same header
/// block is built once with the extra lines spliced in, then written whole.
///
/// Param:
/// body - []const u8 (response body)
///
/// Return:
/// - !void (propagates the core writer error, e.g. Error.ZixHttp1_Response_BrokenPipe)
pub fn send(self: *Self, body: []const u8) !void {
    self.bytes_written = body.len;
    self.sent = true;

    if (self.extra_len == 0 and self.keep_alive == null) {
        return core.sendSimpleFD(self.fd, self.status, self.contentTypeString(), body);
    }

    const full = try self.buildFull(body);

    return core.writeAllFD(self.fd, full);
}

/// Send body as application/json. Byte-identical to core.sendJsonFD.
pub fn sendJson(self: *Self, body: []const u8) !void {
    self.content_type = .APPLICATION_JSON;

    return self.send(body);
}

/// Send body as text/plain.
pub fn sendText(self: *Self, body: []const u8) !void {
    self.content_type = .TEXT_PLAIN;

    return self.send(body);
}

/// Write caller-owned bytes verbatim, a full response the handler built
/// itself. Routes through the coalescing sink like every other write.
///
/// Param:
/// bytes - []const u8 (the exact wire bytes to send)
///
/// Return:
/// - !void (propagates the core writer error, e.g. Error.ZixHttp1_Response_BrokenPipe)
pub fn sendRaw(self: *Self, bytes: []const u8) !void {
    self.bytes_written = bytes.len;
    self.sent = true;

    return core.writeAllFD(self.fd, bytes);
}

/// Send a 204 No Content response with an empty body.
pub fn sendNoContent(self: *Self) !void {
    self.status = .NO_CONTENT;

    return self.send("");
}

/// Serve this request from the per-worker response cache when it holds a
/// fresh entry. A no-op returning false on workers without a cache.
///
/// Usage:
/// ```zig
/// if (res.sendFromCache(req)) return;
/// const body = buildExpensiveBody(...);
/// try res.sendCached(req, body, 0);
/// ```
///
/// Return:
/// - bool (true when served from cache, the handler should return)
pub fn sendFromCache(self: *Self, req: *const Request) bool {
    const bytes = core.cacheLookup(req.head) orelse return false;

    self.bytes_written = bytes.len;
    self.sent = true;
    core.writeAllFD(self.fd, bytes) catch return true;

    return true;
}

/// Serialize the response once, write it, and store it under the request
/// key for later sendFromCache hits. ttl_ms of 0 uses the worker default
/// (core.cacheTtl). Falls back to a plain send when no cache is installed
/// or the serialization allocation fails.
///
/// Param:
/// req - *const Request (source of the cache key: method, path, query)
/// body - []const u8 (response body)
/// ttl_ms - u32 (freshness in milliseconds, 0 means the worker default)
///
/// Return:
/// - !void
pub fn sendCached(self: *Self, req: *const Request, body: []const u8, ttl_ms: u32) !void {
    if (core.tl_cache == null) return self.send(body);

    const full = self.buildFull(body) catch return self.send(body);
    self.bytes_written = body.len;
    self.sent = true;

    const ttl = if (ttl_ms == 0) core.cacheTtl() else ttl_ms;
    core.cacheStore(req.head, full, ttl);

    return core.writeAllFD(self.fd, full);
}

/// Send body with Accept-Encoding negotiation. Compresses only when the
/// worker has compression enabled, the client accepts a producible coding,
/// the body clears the size floor and is not an already-compressed media
/// type, and the compressed result is both smaller than the original and
/// within the cap. In every other case the body is sent uncompressed,
/// identical to send().
///
/// Note:
/// - Opt-in like sendCached: the handler passes the request for its
///   Accept-Encoding.
/// - The compressed path sets Content-Encoding and Vary: Accept-Encoding,
///   then reuses send() so Content-Length and the header block stay correct.
/// - Does not touch the cache.
///
/// Param:
/// req - *const Request (for the Accept-Encoding header)
/// body - []const u8 (uncompressed body)
///
/// Return:
/// - !void (propagates send() and addHeader errors)
pub fn sendNegotiated(self: *Self, req: *const Request, body: []const u8) !void {
    if (!core.tl_compression) return self.send(body);

    const accept = core.acceptEncoding(req.head);
    const encoding = compression.negotiate(accept, &compression.supported_default) orelse {
        self.setStatus(.NOT_ACCEPTABLE);

        return self.send("");
    };

    if (encoding == .IDENTITY or !compression.shouldCompress(body.len, self.contentTypeString(), core.tl_compression_min_size)) {
        return self.send(body);
    }

    const encoded = compression.encode(self.allocator, encoding, body, .DEFAULT) catch {
        return self.send(body);
    };

    if (encoded.len > core.tl_compression_max_out or encoded.len >= body.len) {
        return self.send(body);
    }

    try self.addHeader("Content-Encoding", encoding.contentEncoding().?);
    try self.addHeader("Vary", "Accept-Encoding");

    return self.send(encoded);
}

/// Begin an SSE (Server-Sent Events) stream and return an SseWriter.
/// Sends HTTP 200 with Content-Type: text/event-stream (no Content-Length)
/// plus any headers added via addHeader. Detaches the coalescing sink first
/// (core.beginStream), so each event flushes to the socket immediately, in
/// cleartext and over TLS. An SSE handler never returns.
pub fn sendStream(self: *Self) !SseWriter {
    core.beginStream();

    const fixed = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: keep-alive\r\n";
    core.writeAllFD(self.fd, fixed) catch return Error.ZixHttp1_Response_BrokenPipe;

    if (self.extra_buf) |extra| {
        for (extra[0..self.extra_len]) |hdr| {
            var hdr_buf: [EXTRA_HEADER_BUF]u8 = undefined;
            const line = std.fmt.bufPrint(&hdr_buf, "{s}: {s}\r\n", .{ hdr.name, hdr.value }) catch continue;
            core.writeAllFD(self.fd, line) catch return Error.ZixHttp1_Response_BrokenPipe;
        }
    }
    core.writeAllFD(self.fd, "\r\n") catch return Error.ZixHttp1_Response_BrokenPipe;

    self.sent = true;
    return SseWriter{ .fd = self.fd };
}

