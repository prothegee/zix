//! zix http1 core — zero-alloc HTTP/1.x request parsing and response writing.
//! All parsing operates on caller-owned buffers. No std.http dependency.

const std = @import("std");

pub const MAX_HEADERS: usize = 32;
pub const BUF_SIZE: usize = 16 * 1024;
pub const GZIP_OUT_SIZE: usize = 256 * 1024;

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const ParsedHead = struct {
    method: []const u8,
    path: []const u8,
    query: []const u8,
    headers: [MAX_HEADERS]Header,
    header_count: usize,
    version_minor: u8,
    keep_alive: bool,
    content_length: u64,
    chunked_request: bool,
    expect_continue: bool,
};

pub const Range = struct { start: u64, end: u64 };

/// Handler signature. All slices are valid only for the duration of the call.
pub const HandlerFn = *const fn (
    head: *const ParsedHead,
    body: []const u8,
    fd: std.posix.fd_t,
) void;

/// Options for serveConn.
pub const ServeOpts = struct {
    nodelay: bool = true,
};

// --------------------------------------------------------- //

/// Parse a complete HTTP/1.x request from buf.
/// buf must contain the full header block ending with \r\n\r\n.
/// All slices in ParsedHead point into buf (zero copy).
///
/// Return:
/// - !struct{ head: ParsedHead, body_offset: usize }
pub fn parseHead(buf: []const u8) !struct { head: ParsedHead, body_offset: usize } {
    const header_end = std.mem.indexOf(u8, buf, "\r\n\r\n") orelse return error.IncompleteHeader;
    const body_offset = header_end + 4;

    const head_buf = buf[0..body_offset];

    const first_crlf = std.mem.indexOf(u8, head_buf, "\r\n") orelse head_buf.len;
    const req_line = head_buf[0..first_crlf];

    const sp1 = std.mem.indexOfScalar(u8, req_line, ' ') orelse return error.InvalidRequest;
    if (sp1 == 0) return error.InvalidRequest;
    const method = req_line[0..sp1];

    const rest = req_line[sp1 + 1 ..];
    const sp2 = std.mem.lastIndexOfScalar(u8, rest, ' ') orelse return error.InvalidRequest;
    const target = rest[0..sp2];
    const version_str = rest[sp2 + 1 ..];

    const version_minor: u8 = if (std.mem.eql(u8, version_str, "HTTP/1.1"))
        1
    else if (std.mem.eql(u8, version_str, "HTTP/1.0"))
        0
    else
        return error.InvalidRequest;

    var path = target;
    var query: []const u8 = "";
    if (std.mem.indexOfScalar(u8, target, '?')) |q| {
        path = target[0..q];
        query = target[q + 1 ..];
    }

    var headers: [MAX_HEADERS]Header = undefined;
    var header_count: usize = 0;
    var keep_alive = (version_minor == 1);
    var content_length: u64 = 0;
    var chunked_request = false;
    var expect_continue = false;

    var pos: usize = first_crlf + 2;
    while (pos < head_buf.len) {
        const line_end = std.mem.indexOfPos(u8, head_buf, pos, "\r\n") orelse head_buf.len;
        const line = head_buf[pos..line_end];
        if (line.len == 0) break;

        const colon = std.mem.indexOfScalar(u8, line, ':') orelse {
            pos = line_end + 2;
            continue;
        };
        var val_off: usize = colon + 1;
        while (val_off < line.len and line[val_off] == ' ') val_off += 1;

        if (header_count >= MAX_HEADERS) return error.TooManyHeaders;
        const name = line[0..colon];
        const value = line[val_off..];
        headers[header_count] = .{ .name = name, .value = value };
        header_count += 1;

        if (std.ascii.eqlIgnoreCase(name, "content-length")) {
            content_length = std.fmt.parseInt(u64, value, 10) catch 0;
        } else if (std.ascii.eqlIgnoreCase(name, "connection")) {
            if (std.ascii.eqlIgnoreCase(value, "close")) keep_alive = false;
            if (std.ascii.eqlIgnoreCase(value, "keep-alive")) keep_alive = true;
        } else if (std.ascii.eqlIgnoreCase(name, "transfer-encoding")) {
            if (std.ascii.indexOfIgnoreCase(value, "chunked") != null) chunked_request = true;
        } else if (std.ascii.eqlIgnoreCase(name, "expect")) {
            if (std.ascii.eqlIgnoreCase(value, "100-continue")) expect_continue = true;
        }

        pos = line_end + 2;
    }

    return .{ .head = .{
        .method = method,
        .path = path,
        .query = query,
        .headers = headers,
        .header_count = header_count,
        .version_minor = version_minor,
        .keep_alive = keep_alive,
        .content_length = content_length,
        .chunked_request = chunked_request,
        .expect_continue = expect_continue,
    }, .body_offset = body_offset };
}

/// Case-insensitive header lookup.
pub fn getHeader(head: *const ParsedHead, name: []const u8) ?[]const u8 {
    for (head.headers[0..head.header_count]) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
    }
    return null;
}

/// Linear scan for a single query parameter by exact name.
/// Does not percent-decode keys or values.
///
/// Return:
/// - ?[]const u8 (raw value slice, or null if not found)
pub fn queryParam(head: *const ParsedHead, name: []const u8) ?[]const u8 {
    if (head.query.len == 0) return null;

    var it = std.mem.splitScalar(u8, head.query, '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (std.mem.eql(u8, pair[0..eq], name)) return pair[eq + 1 ..];
    }

    return null;
}

/// Percent-decode buf in place.
///
/// Return:
/// - []u8 (decoded slice, shorter or equal length)
pub fn percentDecode(buf: []u8) []u8 {
    return std.Uri.percentDecodeInPlace(buf);
}

/// Parse "bytes=start-end" or "bytes=start-" (open-ended).
///
/// Return:
/// - ?Range (null for invalid or unsatisfiable range)
pub fn parseRange(val: []const u8, total: u64) ?Range {
    if (!std.mem.startsWith(u8, val, "bytes=")) return null;
    const spec = val[6..];
    const dash = std.mem.indexOfScalar(u8, spec, '-') orelse return null;
    if (total == 0) return null;

    const start_str = spec[0..dash];
    const end_str = spec[dash + 1 ..];

    const start = std.fmt.parseInt(u64, start_str, 10) catch return null;
    if (start >= total) return null;

    const end: u64 = if (end_str.len == 0)
        total - 1
    else blk: {
        const e = std.fmt.parseInt(u64, end_str, 10) catch return null;
        break :blk if (e >= total) total - 1 else e;
    };

    if (start > end) return null;
    return .{ .start = start, .end = end };
}

// --------------------------------------------------------- //

fn statusPhrase(code: u16) []const u8 {
    return switch (code) {
        100 => "Continue",
        200 => "OK",
        201 => "Created",
        204 => "No Content",
        206 => "Partial Content",
        301 => "Moved Permanently",
        302 => "Found",
        304 => "Not Modified",
        400 => "Bad Request",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        405 => "Method Not Allowed",
        416 => "Range Not Satisfiable",
        431 => "Request Header Fields Too Large",
        500 => "Internal Server Error",
        501 => "Not Implemented",
        503 => "Service Unavailable",
        else => "Unknown",
    };
}

fn formatHttpDate(secs: u64, buf: []u8) []u8 {
    const ep = std.time.epoch;
    const es = ep.EpochSeconds{ .secs = secs };
    const epoch_day = es.getEpochDay();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_secs = es.getDaySeconds();
    const day_names = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
    const month_names = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
    const dow = (@as(u64, epoch_day.day) % 7 + 4) % 7;

    return std.fmt.bufPrint(buf, "{s}, {d:0>2} {s} {d} {d:0>2}:{d:0>2}:{d:0>2} GMT", .{
        day_names[dow],
        @as(u32, month_day.day_index) + 1,
        month_names[@intFromEnum(month_day.month) - 1],
        year_day.year,
        day_secs.getHoursIntoDay(),
        day_secs.getMinutesIntoHour(),
        day_secs.getSecondsIntoMinute(),
    }) catch buf[0..0];
}

const DateCache = struct {
    secs: u64,
    buf: [40]u8,
    len: usize,
};

threadlocal var tl_date: DateCache = .{ .secs = 0, .buf = undefined, .len = 0 };

fn cachedDate() []const u8 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.REALTIME, &ts);
    const secs: u64 = if (ts.sec >= 0) @intCast(ts.sec) else 0;

    if (secs != tl_date.secs or tl_date.len == 0) {
        const d = formatHttpDate(secs, &tl_date.buf);
        tl_date.secs = secs;
        tl_date.len = d.len;
    }

    return tl_date.buf[0..tl_date.len];
}

// --------------------------------------------------------- //

pub fn fdWriteAll(fd: std.posix.fd_t, data: []const u8) error{BrokenPipe}!void {
    var rem = data;
    while (rem.len > 0) {
        const rc = std.posix.system.write(fd, rem.ptr, rem.len);
        switch (std.posix.errno(rc)) {
            .SUCCESS => {
                const n: usize = @intCast(rc);
                if (n == 0) return error.BrokenPipe;
                rem = rem[n..];
            },
            .INTR => continue,
            // Non-blocking socket with a full send buffer: wait for the peer
            // to drain it, then retry. Blocking sockets never hit this branch.
            .AGAIN => {
                var pfd = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.OUT, .revents = 0 }};
                _ = std.posix.poll(&pfd, -1) catch return error.BrokenPipe;
            },
            else => return error.BrokenPipe,
        }
    }
}

/// Response with Content-Length body.
/// Fast path: headers + body combined in one write when total fits in 512 bytes.
/// Slow path: two writes for large bodies.
pub fn writeSimple(
    fd: std.posix.fd_t,
    status: u16,
    content_type: []const u8,
    body: []const u8,
) !void {
    var buf: [512]u8 = undefined;

    const date = cachedDate();
    const headers = if (content_type.len > 0)
        std.fmt.bufPrint(
            &buf,
            "HTTP/1.1 {d} {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nDate: {s}\r\n\r\n",
            .{ status, statusPhrase(status), content_type, body.len, date },
        ) catch return error.BufferTooSmall
    else
        std.fmt.bufPrint(
            &buf,
            "HTTP/1.1 {d} {s}\r\nContent-Length: {d}\r\nDate: {s}\r\n\r\n",
            .{ status, statusPhrase(status), body.len, date },
        ) catch return error.BufferTooSmall;

    if (headers.len + body.len <= buf.len) {
        @memcpy(buf[headers.len..][0..body.len], body);
        return fdWriteAll(fd, buf[0 .. headers.len + body.len]);
    }

    try fdWriteAll(fd, headers);
    if (body.len > 0) try fdWriteAll(fd, body);
}

/// Headers-only response (no body). Used for HEAD method responses.
pub fn writeSimpleNoBody(
    fd: std.posix.fd_t,
    status: u16,
    content_type: []const u8,
    content_length: usize,
) !void {
    var buf: [512]u8 = undefined;

    const date = cachedDate();
    const headers = if (content_type.len > 0)
        std.fmt.bufPrint(
            &buf,
            "HTTP/1.1 {d} {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nDate: {s}\r\n\r\n",
            .{ status, statusPhrase(status), content_type, content_length, date },
        ) catch return error.BufferTooSmall
    else
        std.fmt.bufPrint(
            &buf,
            "HTTP/1.1 {d} {s}\r\nContent-Length: {d}\r\nDate: {s}\r\n\r\n",
            .{ status, statusPhrase(status), content_length, date },
        ) catch return error.BufferTooSmall;

    try fdWriteAll(fd, headers);
}

/// JSON response. Shorthand for writeSimple with "application/json".
pub fn writeJson(fd: std.posix.fd_t, status: u16, body: []const u8) !void {
    return writeSimple(fd, status, "application/json", body);
}

/// Send 100 Continue before reading a large body.
pub fn write100Continue(fd: std.posix.fd_t) !void {
    try fdWriteAll(fd, "HTTP/1.1 100 Continue\r\n\r\n");
}

/// gzip-compressed response via std.compress.flate.
/// Heap-allocates the compressor to avoid blowing the stack.
pub fn writeGzip(
    fd: std.posix.fd_t,
    status: u16,
    content_type: []const u8,
    body: []const u8,
) !void {
    const out_buf = try std.heap.smp_allocator.alloc(u8, GZIP_OUT_SIZE);
    defer std.heap.smp_allocator.free(out_buf);

    const hist_buf = try std.heap.smp_allocator.alloc(u8, std.compress.flate.max_window_len);
    defer std.heap.smp_allocator.free(hist_buf);

    const comp = try std.heap.smp_allocator.create(std.compress.flate.Compress);
    defer std.heap.smp_allocator.destroy(comp);

    var out_w: std.Io.Writer = .fixed(out_buf);
    comp.* = try std.compress.flate.Compress.init(
        &out_w,
        hist_buf,
        .gzip,
        std.compress.flate.Compress.Options.default,
    );
    try comp.writer.writeAll(body);
    try comp.finish();

    const compressed = out_w.buffered();
    var hdr: [256]u8 = undefined;
    const h = try std.fmt.bufPrint(
        &hdr,
        "HTTP/1.1 {d} {s}\r\nContent-Type: {s}\r\nContent-Encoding: gzip\r\nContent-Length: {d}\r\n\r\n",
        .{ status, statusPhrase(status), content_type, compressed.len },
    );
    try fdWriteAll(fd, h);
    try fdWriteAll(fd, compressed);
}

/// Start a chunked response. Call writeChunk for each chunk, then writeChunkedEnd.
pub fn writeChunkedStart(fd: std.posix.fd_t, status: u16, content_type: []const u8) !void {
    var hdr: [256]u8 = undefined;
    const s = try std.fmt.bufPrint(
        &hdr,
        "HTTP/1.1 {d} {s}\r\nContent-Type: {s}\r\nTransfer-Encoding: chunked\r\n\r\n",
        .{ status, statusPhrase(status), content_type },
    );
    try fdWriteAll(fd, s);
}

/// Write one chunk: hex_len CRLF data CRLF.
pub fn writeChunk(fd: std.posix.fd_t, data: []const u8) !void {
    if (data.len == 0) return;
    var sz: [32]u8 = undefined;
    const s = try std.fmt.bufPrint(&sz, "{x}\r\n", .{data.len});
    try fdWriteAll(fd, s);
    try fdWriteAll(fd, data);
    try fdWriteAll(fd, "\r\n");
}

/// Terminate the chunked body with the final zero-length chunk.
pub fn writeChunkedEnd(fd: std.posix.fd_t) !void {
    try fdWriteAll(fd, "0\r\n\r\n");
}

/// 206 Partial Content or 416 Range Not Satisfiable based on parseRange result.
pub fn writeRange(
    fd: std.posix.fd_t,
    content_type: []const u8,
    full_body: []const u8,
    range_val: []const u8,
) !void {
    const total: u64 = full_body.len;
    const range = parseRange(range_val, total) orelse {
        var hdr: [256]u8 = undefined;
        const s = try std.fmt.bufPrint(
            &hdr,
            "HTTP/1.1 416 Range Not Satisfiable\r\nContent-Range: bytes */{d}\r\nContent-Length: 0\r\n\r\n",
            .{total},
        );
        return fdWriteAll(fd, s);
    };

    const slice = full_body[range.start .. range.end + 1];
    var hdr: [256]u8 = undefined;
    const s = try std.fmt.bufPrint(
        &hdr,
        "HTTP/1.1 206 Partial Content\r\nContent-Type: {s}\r\nContent-Range: bytes {d}-{d}/{d}\r\nContent-Length: {d}\r\n\r\n",
        .{ content_type, range.start, range.end, total, slice.len },
    );
    try fdWriteAll(fd, s);
    try fdWriteAll(fd, slice);
}

// --------------------------------------------------------- //

pub const RecvHeadResult = struct {
    body_offset: usize,
    filled: usize,
};

/// Bulk-read into buf until \r\n\r\n is found.
/// pre_filled bytes are already in buf from a previous iteration (keep-alive leftover).
///
/// Return:
/// - !RecvHeadResult
pub fn recvHead(fd: std.posix.fd_t, buf: []u8, pre_filled: usize) !RecvHeadResult {
    var filled = pre_filled;

    if (filled >= 4) {
        if (std.mem.indexOf(u8, buf[0..filled], "\r\n\r\n")) |pos| {
            return .{ .body_offset = pos + 4, .filled = filled };
        }
    }

    while (true) {
        if (filled >= buf.len) return error.HeaderTooLarge;
        const n = std.posix.read(fd, buf[filled..]) catch return error.Closed;
        if (n == 0) return error.Closed;
        const search_from = if (filled > 3) filled - 3 else 0;
        filled += n;
        if (std.mem.indexOfPos(u8, buf[0..filled], search_from, "\r\n\r\n")) |pos| {
            return .{ .body_offset = pos + 4, .filled = filled };
        }
    }
}

/// Decode a chunked request body (RFC 9112 7.1).
/// peeked contains bytes already read past the header.
/// Ignores chunk extensions. Skips trailer section.
///
/// Return:
/// - !usize (decoded bytes written into out)
pub fn readChunkedBody(fd: std.posix.fd_t, peeked: []const u8, out: []u8) !usize {
    const Rd = struct {
        fd: std.posix.fd_t,
        buf: [BUF_SIZE]u8 = undefined,
        pos: usize = 0,
        len: usize = 0,

        fn refill(r: *@This()) !void {
            const rem = r.len - r.pos;
            if (rem > 0) std.mem.copyForwards(u8, &r.buf, r.buf[r.pos..r.len]);
            r.pos = 0;
            r.len = rem;
            const n = std.posix.read(r.fd, r.buf[r.len..]) catch return error.Closed;
            if (n == 0) return error.Closed;
            r.len += n;
        }

        fn next(r: *@This()) !u8 {
            if (r.pos >= r.len) try r.refill();
            const b = r.buf[r.pos];
            r.pos += 1;
            return b;
        }
    };

    var rd: Rd = .{ .fd = fd };
    const seed = @min(peeked.len, rd.buf.len);
    @memcpy(rd.buf[0..seed], peeked[0..seed]);
    rd.len = seed;

    var out_pos: usize = 0;

    while (true) {
        var line: [64]u8 = undefined;
        var line_len: usize = 0;
        while (true) {
            const b = try rd.next();
            if (b == '\r') {
                _ = try rd.next();
                break;
            }
            if (b == '\n') break;
            if (line_len < line.len) {
                line[line_len] = b;
                line_len += 1;
            }
        }

        var hex_end: usize = line_len;
        for (line[0..line_len], 0..) |c, i| {
            if (c == ';') {
                hex_end = i;
                break;
            }
        }
        const chunk_size = std.fmt.parseInt(
            usize,
            std.mem.trimEnd(u8, line[0..hex_end], " "),
            16,
        ) catch return error.InvalidChunkSize;

        if (chunk_size == 0) {
            while (true) {
                var blank = true;
                while (true) {
                    const b = try rd.next();
                    if (b == '\r') {
                        _ = try rd.next();
                        break;
                    }
                    if (b == '\n') break;
                    blank = false;
                }
                if (blank) break;
            }
            break;
        }

        var left = chunk_size;
        while (left > 0) {
            if (rd.pos >= rd.len) try rd.refill();
            const avail = rd.len - rd.pos;
            const take = @min(avail, left);
            const copy = @min(take, out.len - out_pos);
            if (copy > 0) {
                @memcpy(out[out_pos..][0..copy], rd.buf[rd.pos..][0..copy]);
                out_pos += copy;
            }
            rd.pos += take;
            left -= take;
        }

        _ = try rd.next();
        _ = try rd.next();
    }

    return out_pos;
}

pub const ConnOutcome = enum { keep_alive, close };

/// Handle exactly one request on fd and return whether the connection may be reused.
/// For use with EPOLL one-shot dispatch. buf and body_buf are caller-owned (min BUF_SIZE each).
///
/// Return:
/// - .keep_alive when the client sent Connection: keep-alive and parsing succeeded
/// - .close on error, peer hangup, or Connection: close
pub fn serveConnOne(
    fd: std.posix.fd_t,
    handler: HandlerFn,
    buf: []u8,
    body_buf: []u8,
) ConnOutcome {
    const hdr = recvHead(fd, buf, 0) catch |err| {
        if (err == error.HeaderTooLarge) {
            fdWriteAll(fd, "HTTP/1.1 431 Request Header Fields Too Large\r\nContent-Length: 0\r\n\r\n") catch {};
        }
        return .close;
    };

    const result = parseHead(buf[0..hdr.filled]) catch {
        fdWriteAll(fd, "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n") catch {};
        return .close;
    };
    const head = result.head;

    if (head.expect_continue and (head.content_length > 0 or head.chunked_request)) {
        write100Continue(fd) catch return .close;
    }

    var body_len: usize = 0;
    if (head.chunked_request) {
        const peeked = buf[hdr.body_offset..hdr.filled];
        body_len = readChunkedBody(fd, peeked, body_buf) catch 0;
    } else if (head.content_length > 0) {
        const to_read: usize = @intCast(@min(head.content_length, body_buf.len));
        const peeked = hdr.filled - hdr.body_offset;
        const from_peek = @min(peeked, to_read);
        if (from_peek > 0) {
            @memcpy(body_buf[0..from_peek], buf[hdr.body_offset..][0..from_peek]);
        }
        body_len = from_peek;
        while (body_len < to_read) {
            const n = std.posix.read(fd, body_buf[body_len..to_read]) catch break;
            if (n == 0) break;
            body_len += n;
        }
    }

    handler(&head, body_buf[0..body_len], fd);

    return if (head.keep_alive) .keep_alive else .close;
}

/// Keep-alive connection loop. The caller owns closing the fd. Pass raw fd extracted
/// from the accepted stream.
pub fn serveConn(fd: std.posix.fd_t, handler: HandlerFn, opts: ServeOpts) void {
    if (opts.nodelay) {
        if (comptime @import("builtin").target.os.tag != .windows) {
            std.posix.setsockopt(
                fd,
                std.posix.IPPROTO.TCP,
                std.posix.TCP.NODELAY,
                std.mem.asBytes(&@as(c_int, 1)),
            ) catch {};
        }
    }

    var recv_buf: [BUF_SIZE]u8 = undefined;
    var body_buf: [8192]u8 = undefined;
    var leftover: usize = 0;

    while (true) {
        const hdr = recvHead(fd, &recv_buf, leftover) catch |err| {
            if (err == error.HeaderTooLarge) {
                fdWriteAll(fd, "HTTP/1.1 431 Request Header Fields Too Large\r\nContent-Length: 0\r\n\r\n") catch {};
            }
            return;
        };

        const result = parseHead(recv_buf[0..hdr.filled]) catch {
            fdWriteAll(fd, "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n") catch {};
            return;
        };
        const head = result.head;

        if (head.expect_continue and (head.content_length > 0 or head.chunked_request)) {
            write100Continue(fd) catch return;
        }

        var body_len: usize = 0;
        if (head.chunked_request) {
            const peeked = recv_buf[hdr.body_offset..hdr.filled];
            body_len = readChunkedBody(fd, peeked, &body_buf) catch 0;
        } else if (head.content_length > 0) {
            const to_read: usize = @intCast(@min(head.content_length, body_buf.len));
            const peeked = hdr.filled - hdr.body_offset;
            const from_peek = @min(peeked, to_read);
            if (from_peek > 0) {
                @memcpy(body_buf[0..from_peek], recv_buf[hdr.body_offset..][0..from_peek]);
            }
            body_len = from_peek;
            while (body_len < to_read) {
                const n = std.posix.read(fd, body_buf[body_len..to_read]) catch break;
                if (n == 0) break;
                body_len += n;
            }
        }

        handler(&head, body_buf[0..body_len], fd);

        if (!head.keep_alive) return;

        if (head.chunked_request) {
            leftover = 0;
        } else {
            const body_consumed: usize = @intCast(@min(head.content_length, @as(u64, body_buf.len)));
            const request_end = hdr.body_offset + body_consumed;
            if (hdr.filled > request_end) {
                leftover = hdr.filled - request_end;
                std.mem.copyForwards(u8, recv_buf[0..leftover], recv_buf[request_end..hdr.filled]);
            } else {
                leftover = 0;
            }
        }
    }
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //

test "zix http1: parseHead, GET request fields" {
    const result = try parseHead("GET /ping HTTP/1.1\r\nHost: localhost\r\n\r\n");
    try std.testing.expectEqualStrings("GET", result.head.method);
    try std.testing.expectEqualStrings("/ping", result.head.path);
    try std.testing.expectEqualStrings("", result.head.query);
    try std.testing.expectEqual(@as(u8, 1), result.head.version_minor);
    try std.testing.expect(result.head.keep_alive);
}

test "zix http1: parseHead, query string split from path" {
    const result = try parseHead("GET /search?q=zig&page=2 HTTP/1.1\r\n\r\n");
    try std.testing.expectEqualStrings("/search", result.head.path);
    try std.testing.expectEqualStrings("q=zig&page=2", result.head.query);
}

test "zix http1: parseHead, POST with Content-Length" {
    const result = try parseHead("POST /api HTTP/1.1\r\nContent-Length: 13\r\n\r\n");
    try std.testing.expectEqualStrings("POST", result.head.method);
    try std.testing.expectEqual(@as(u64, 13), result.head.content_length);
}

test "zix http1: parseHead, HTTP/1.0 defaults keep_alive to false" {
    const result = try parseHead("GET / HTTP/1.0\r\nHost: localhost\r\n\r\n");
    try std.testing.expectEqual(@as(u8, 0), result.head.version_minor);
    try std.testing.expect(!result.head.keep_alive);
}

test "zix http1: parseHead, Connection keep-alive overrides HTTP/1.0 default" {
    const result = try parseHead("GET / HTTP/1.0\r\nConnection: keep-alive\r\n\r\n");
    try std.testing.expect(result.head.keep_alive);
}

test "zix http1: parseHead, Expect: 100-continue sets flag" {
    const result = try parseHead("POST /up HTTP/1.1\r\nContent-Length: 512\r\nExpect: 100-continue\r\n\r\n");
    try std.testing.expect(result.head.expect_continue);
}

test "zix http1: getHeader, case-insensitive lookup" {
    const result = try parseHead("GET / HTTP/1.1\r\nContent-Type: text/plain\r\n\r\n");
    try std.testing.expectEqualStrings("text/plain", getHeader(&result.head, "content-type").?);
    try std.testing.expectEqualStrings("text/plain", getHeader(&result.head, "CONTENT-TYPE").?);
    try std.testing.expect(getHeader(&result.head, "x-missing") == null);
}

test "zix http1: queryParam, single and multiple params" {
    const result = try parseHead("GET /p?name=alice&age=30 HTTP/1.1\r\n\r\n");
    try std.testing.expectEqualStrings("alice", queryParam(&result.head, "name").?);
    try std.testing.expectEqualStrings("30", queryParam(&result.head, "age").?);
    try std.testing.expect(queryParam(&result.head, "missing") == null);
}

test "zix http1: parseRange, valid and boundary cases" {
    try std.testing.expectEqual(Range{ .start = 0, .end = 99 }, parseRange("bytes=0-99", 200).?);
    try std.testing.expectEqual(Range{ .start = 100, .end = 199 }, parseRange("bytes=100-", 200).?);
    try std.testing.expectEqual(Range{ .start = 0, .end = 199 }, parseRange("bytes=0-999", 200).?);
    try std.testing.expect(parseRange("bytes=200-", 200) == null);
    try std.testing.expect(parseRange("notbytes=0-99", 200) == null);
}

test "zix http1: percentDecode, encoded chars decoded in place" {
    var buf = [_]u8{ 'a', '%', '2', '0', 'b' };
    const decoded = percentDecode(&buf);
    try std.testing.expectEqualStrings("a b", decoded);
}
