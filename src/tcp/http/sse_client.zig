//! zix http SSE client
//! Consumes a Server-Sent Events stream: HTTP GET + line-by-line event parsing.

const std = @import("std");

// --------------------------------------------------------- //

/// A single Server-Sent Event.
/// All slice fields point into the buf passed to SseStream.next().
pub const SseEvent = struct {
    /// Event type field. null when the stream omitted the event: line (default type "message").
    event: ?[]const u8,
    /// Accumulated data (multiple data: lines joined with '\n').
    data: []const u8,
    /// Last-event-ID field. null when the stream omitted the id: line.
    id: ?[]const u8,
    /// Reconnect time hint in milliseconds. null when the stream omitted the retry: line.
    retry: ?u32,
};

// --------------------------------------------------------- //

/// Configuration for an SSE client connection.
pub const SseClientConfig = struct {
    /// Event-loop backend. Caller owns and must outlive the client.
    io: std.Io,
    /// TCP connect timeout in milliseconds. 0 = no timeout.
    connect_timeout_ms: u32 = 0,
};

// --------------------------------------------------------- //

/// Live SSE stream. Yields parsed events via next().
/// Call deinit() when done.
pub const SseStream = struct {
    const Self = @This();

    fd: std.posix.fd_t,
    read_buf: [4096]u8,
    read_len: usize,
    read_pos: usize,

    // --------------------------------------------------------- //

    /// Read and parse one event from the stream.
    ///
    /// Note:
    /// - All returned slices point into buf. Do not call next() again until
    ///   you have finished using the previous SseEvent's fields.
    /// - buf layout after return: [0..data_end] = data, then event type, then id.
    ///   Caller must size buf generously (4096 B recommended).
    /// - null when the server closes the stream cleanly.
    ///
    /// Param:
    /// buf - []u8 (workspace, must be large enough for data + event + id combined)
    ///
    /// Return:
    /// - ?SseEvent
    pub fn next(self: *Self, buf: []u8) !?SseEvent {
        var data_len: usize = 0;
        var event_scratch: [256]u8 = undefined;
        var event_scratch_len: usize = 0;
        var id_scratch: [256]u8 = undefined;
        var id_scratch_len: usize = 0;
        var retry: ?u32 = null;
        var has_data = false;

        var line_scratch: [1024]u8 = undefined;

        while (true) {
            const maybe_line = try self.readLine(&line_scratch);

            if (maybe_line == null) {
                if (has_data) break;
                return null;
            }

            const line = maybe_line.?;

            if (line.len == 0) {
                if (has_data) break;
                event_scratch_len = 0;
                id_scratch_len = 0;
                retry = null;
                continue;
            }

            if (line[0] == ':') continue;

            if (splitField(line, "data")) |value| {
                if (has_data and data_len < buf.len) {
                    buf[data_len] = '\n';
                    data_len += 1;
                }
                const copy_len = @min(value.len, buf.len - data_len);
                @memcpy(buf[data_len..][0..copy_len], value[0..copy_len]);
                data_len += copy_len;
                has_data = true;
            } else if (splitField(line, "event")) |value| {
                event_scratch_len = @min(value.len, event_scratch.len);
                @memcpy(event_scratch[0..event_scratch_len], value[0..event_scratch_len]);
            } else if (splitField(line, "id")) |value| {
                id_scratch_len = @min(value.len, id_scratch.len);
                @memcpy(id_scratch[0..id_scratch_len], value[0..id_scratch_len]);
            } else if (splitField(line, "retry")) |value| {
                retry = std.fmt.parseInt(u32, value, 10) catch null;
            }
        }

        const data_slice = buf[0..data_len];
        var write_pos = data_len;

        const event_slice: ?[]const u8 = if (event_scratch_len > 0) event_blk: {
            const copy_len = @min(event_scratch_len, buf.len - write_pos);
            if (copy_len == 0) break :event_blk null;
            @memcpy(buf[write_pos..][0..copy_len], event_scratch[0..copy_len]);
            const s = buf[write_pos..][0..copy_len];
            write_pos += copy_len;
            break :event_blk s;
        } else null;

        const id_slice: ?[]const u8 = if (id_scratch_len > 0) id_blk: {
            const copy_len = @min(id_scratch_len, buf.len - write_pos);
            if (copy_len == 0) break :id_blk null;
            @memcpy(buf[write_pos..][0..copy_len], id_scratch[0..copy_len]);
            const s = buf[write_pos..][0..copy_len];
            break :id_blk s;
        } else null;

        return SseEvent{
            .event = event_slice,
            .data = data_slice,
            .id = id_slice,
            .retry = retry,
        };
    }

    /// Close the underlying TCP connection.
    pub fn deinit(self: Self) void {
        _ = std.posix.system.close(self.fd);
    }

    // --------------------------------------------------------- //

    fn readLine(self: *Self, out: []u8) !?[]const u8 {
        var line_len: usize = 0;

        while (true) {
            while (self.read_pos < self.read_len) {
                const byte = self.read_buf[self.read_pos];
                self.read_pos += 1;

                if (byte == '\n') {
                    if (line_len > 0 and out[line_len - 1] == '\r') line_len -= 1;
                    return out[0..line_len];
                }

                if (line_len < out.len) {
                    out[line_len] = byte;
                    line_len += 1;
                }
            }

            const n = std.posix.read(self.fd, &self.read_buf) catch return null;
            if (n == 0) return if (line_len > 0) out[0..line_len] else null;
            self.read_pos = 0;
            self.read_len = n;
        }
    }
};

// --------------------------------------------------------- //

/// SSE client. Connects to an SSE endpoint and returns a live SseStream.
///
/// Usage:
/// ```zig
/// var sse_client = zix.Http.SseClient.init(.{ .io = process.io });
/// var stream = try sse_client.open("http://127.0.0.1:9010/events");
/// defer stream.deinit();
/// var buf: [4096]u8 = undefined;
/// while (try stream.next(&buf)) |ev| {
///     std.debug.print("data: {s}\n", .{ev.data});
/// }
/// ```
pub const SseClient = struct {
    const Self = @This();

    config: SseClientConfig,

    // --------------------------------------------------------- //

    /// Initialise the client. No connection is opened until open() is called.
    pub fn init(config: SseClientConfig) Self {
        return .{ .config = config };
    }

    /// Connect to an SSE endpoint and return a live stream.
    ///
    /// Note:
    /// - https:// is not yet supported.
    /// - Caller owns the returned SseStream and must call deinit() on it.
    ///
    /// Param:
    /// url - []const u8 (http://host:port/path)
    ///
    /// Return:
    /// - SseStream
    /// - error.InvalidUrl (malformed URL or missing host)
    /// - error.TlsNotSupported (https:// scheme)
    /// - error.ConnectionFailed (TCP error or server closed early)
    /// - error.NotEventStream (server did not respond with text/event-stream)
    /// - error.UnexpectedStatus (server did not respond 200)
    pub fn open(self: Self, url: []const u8) !SseStream {
        const parsed = try parseHttpUrl(url);

        const addr = try std.Io.net.IpAddress.resolve(self.config.io, parsed.host, parsed.port);
        const tcp_stream = try addr.connect(self.config.io, .{ .mode = .stream, .protocol = .tcp });
        const fd = tcp_stream.socket.handle;
        errdefer _ = std.posix.system.close(fd);

        var req_buf: [1024]u8 = undefined;
        const req = std.fmt.bufPrint(
            &req_buf,
            "GET {s} HTTP/1.1\r\n" ++
                "Host: {s}:{d}\r\n" ++
                "Accept: text/event-stream\r\n" ++
                "Cache-Control: no-cache\r\n" ++
                "Connection: keep-alive\r\n" ++
                "\r\n",
            .{ parsed.path, parsed.host, parsed.port },
        ) catch return error.InvalidUrl;

        fdWriteAll(fd, req) catch return error.ConnectionFailed;

        var head_buf: [4096]u8 = undefined;
        var head_len: usize = 0;
        var header_end: usize = 0;

        while (head_len < head_buf.len) {
            const n = std.posix.read(fd, head_buf[head_len..]) catch return error.ConnectionFailed;
            if (n == 0) return error.ConnectionFailed;
            head_len += n;
            if (std.mem.indexOf(u8, head_buf[0..head_len], "\r\n\r\n")) |pos| {
                header_end = pos + 4;
                break;
            }
        }

        if (header_end == 0) return error.ConnectionFailed;
        if (!std.mem.startsWith(u8, head_buf[0..header_end], "HTTP/1.1 200")) return error.UnexpectedStatus;

        const content_type = findHeader(head_buf[0..header_end], "content-type") orelse return error.NotEventStream;
        if (std.mem.indexOf(u8, content_type, "text/event-stream") == null) return error.NotEventStream;

        var result = SseStream{
            .fd = fd,
            .read_buf = undefined,
            .read_len = 0,
            .read_pos = 0,
        };

        const already_read = head_len - header_end;
        if (already_read > 0) {
            const copy_len = @min(already_read, result.read_buf.len);
            @memcpy(result.read_buf[0..copy_len], head_buf[header_end..][0..copy_len]);
            result.read_len = copy_len;
        }

        return result;
    }
};

// --------------------------------------------------------- //

const HttpUrlParsed = struct { host: []const u8, port: u16, path: []const u8 };

fn parseHttpUrl(url: []const u8) !HttpUrlParsed {
    if (std.mem.startsWith(u8, url, "https://")) return error.TlsNotSupported;
    if (!std.mem.startsWith(u8, url, "http://")) return error.InvalidUrl;

    const authority_start: usize = "http://".len;
    const path_start = std.mem.indexOfScalarPos(u8, url, authority_start, '/') orelse url.len;
    const authority = url[authority_start..path_start];
    const path_str: []const u8 = if (path_start < url.len) url[path_start..] else "/";

    if (authority.len == 0) return error.InvalidUrl;

    const colon_pos = std.mem.lastIndexOfScalar(u8, authority, ':');
    const host: []const u8 = if (colon_pos) |cp| authority[0..cp] else authority;
    const port: u16 = if (colon_pos) |cp|
        (std.fmt.parseInt(u16, authority[cp + 1 ..], 10) catch return error.InvalidUrl)
    else
        80;

    if (host.len == 0) return error.InvalidUrl;

    return HttpUrlParsed{ .host = host, .port = port, .path = path_str };
}

fn splitField(line: []const u8, name: []const u8) ?[]const u8 {
    const colon_pos = std.mem.indexOfScalar(u8, line, ':');
    if (colon_pos == null) {
        if (std.mem.eql(u8, line, name)) return "";
        return null;
    }
    const cp = colon_pos.?;
    if (!std.mem.eql(u8, line[0..cp], name)) return null;
    const value = line[cp + 1 ..];
    if (value.len > 0 and value[0] == ' ') return value[1..];
    return value;
}

fn fdWriteAll(fd: std.posix.fd_t, data: []const u8) !void {
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

fn findHeader(head: []const u8, name: []const u8) ?[]const u8 {
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

// --------------------------------------------------------- //
// --------------------------------------------------------- //

test "zix http sse client: splitField data line" {
    const value = splitField("data: hello", "data");
    try std.testing.expectEqualStrings("hello", value.?);
}

test "zix http sse client: splitField event line" {
    const value = splitField("event: update", "event");
    try std.testing.expectEqualStrings("update", value.?);
}

test "zix http sse client: splitField retry line" {
    const value = splitField("retry: 3000", "retry");
    try std.testing.expectEqualStrings("3000", value.?);
}

test "zix http sse client: splitField no colon, bare field name" {
    const value = splitField("data", "data");
    try std.testing.expectEqualStrings("", value.?);
}

test "zix http sse client: splitField name mismatch returns null" {
    const value = splitField("event: update", "data");
    try std.testing.expectEqual(null, value);
}

test "zix http sse client: splitField no leading space preserved" {
    const value = splitField("data:noSpace", "data");
    try std.testing.expectEqualStrings("noSpace", value.?);
}

test "zix http sse client: parseHttpUrl basic" {
    const parsed = try parseHttpUrl("http://127.0.0.1:9010/events");
    try std.testing.expectEqualStrings("127.0.0.1", parsed.host);
    try std.testing.expectEqual(@as(u16, 9010), parsed.port);
    try std.testing.expectEqualStrings("/events", parsed.path);
}

test "zix http sse client: parseHttpUrl default port 80" {
    const parsed = try parseHttpUrl("http://example.com/events");
    try std.testing.expectEqual(@as(u16, 80), parsed.port);
}

test "zix http sse client: parseHttpUrl https returns TlsNotSupported" {
    try std.testing.expectError(error.TlsNotSupported, parseHttpUrl("https://example.com/events"));
}
