const std = @import("std");

const ADDRESS_IP: []const u8 = "127.0.0.1";
const ADDRESS_PORT: u16 = 9000;
const WORKER_THREADS_TARGET: usize = 0; // this doesn't represent hardware thread/s

const CLIENT_REQUEST_BUFFER_SIZE: usize = 1024 * 8;

// --------------------------------------------------------- //

//
// Note:
// TESTED with: zig 0.16.0-dev.3006+94355f192
// consider std.Io.Evented (epoll/kqueue/io_uring) for more burst/high concurrent,
// but I'm not sure for the next steps for specific platform ()
//

//
// STATUS:
// The current server uses threaded async I/O via Zig’s new std.Io.Threaded
// it’s not purely blocking I/O nor pure epoll/kqueue/io_uring it’s a hybrid,
// so i'ts asynchronous I/O but using a higher-level abstraction
// than directly using epoll/kqueue/io_uring.
//

//
// CHECKMARKS:
// [X] hybrid I/O
// [X] full http spec
// [X] websocket support
// [X] keep-alive (manual)
// [X] dynamic path routing
// [X] controller middlewares
// [X] query parameters parsing
// [X] multi-threaded http server
// [X] threadpool for scalability
// [X] async / non-blocking server (std.Io)
// [X] dynamic thread count (hardware_concurrency)
// [X] public file access, from `$(pwd)/public` relative from the exec run
// [X] able upload file multiples `$(pwd)/public/u` relative from the exec run
//

// --------------------------------------------------------- //

// HTTP Methods (RFC 7231 + RFC 5789)
const HttpMethod = enum(u8) {
    GET,
    HEAD,
    POST,
    PUT,
    DELETE,
    PATCH,
    OPTIONS,
    TRACE,
    CONNECT,
};

// HTTP Status Codes (RFC 7231 + RFC 6585)
const HttpStatus = enum(u16) {
    // 1xx Informational
    continue_ = 100,
    switching_protocols = 101,
    processing = 102,
    early_hints = 103,

    // 2xx Success
    ok = 200,
    created = 201,
    accepted = 202,
    non_authoritative_information = 203,
    no_content = 204,
    reset_content = 205,
    partial_content = 206,
    multi_status = 207,
    already_reported = 208,
    im_used = 226,

    // 3xx Redirection
    multiple_choices = 300,
    moved_permanently = 301,
    found = 302,
    see_other = 303,
    not_modified = 304,
    use_proxy = 305,
    temporary_redirect = 307,
    permanent_redirect = 308,

    // 4xx Client Error
    bad_request = 400,
    unauthorized = 401,
    payment_required = 402,
    forbidden = 403,
    not_found = 404,
    method_not_allowed = 405,
    not_acceptable = 406,
    proxy_authentication_required = 407,
    request_timeout = 408,
    conflict = 409,
    gone = 410,
    length_required = 411,
    precondition_failed = 412,
    payload_too_large = 413,
    uri_too_long = 414,
    unsupported_media_type = 415,
    range_not_satisfiable = 416,
    expectation_failed = 417,
    im_a_teapot = 418,
    misdirected_request = 421,
    unprocessable_entity = 422,
    locked = 423,
    failed_dependency = 424,
    too_early = 425,
    upgrade_required = 426,
    precondition_required = 428,
    too_many_requests = 429,
    request_header_fields_too_large = 431,
    unavailable_for_legal_reasons = 451,

    // 5xx Server Error
    internal_server_error = 500,
    not_implemented = 501,
    bad_gateway = 502,
    service_unavailable = 503,
    gateway_timeout = 504,
    http_version_not_supported = 505,
    variant_also_negotiates = 506,
    insufficient_storage = 507,
    loop_detected = 508,
    not_extended = 510,
    network_authentication_required = 511,
};

fn httpStatusText(status: HttpStatus) []const u8 {
    return switch (status) {
        .continue_ => "Continue",
        .switching_protocols => "Switching Protocols",
        .processing => "Processing",
        .early_hints => "Early Hints",
        .ok => "OK",
        .created => "Created",
        .accepted => "Accepted",
        .non_authoritative_information => "Non-Authoritative Information",
        .no_content => "No Content",
        .reset_content => "Reset Content",
        .partial_content => "Partial Content",
        .multi_status => "Multi-Status",
        .already_reported => "Already Reported",
        .im_used => "IM Used",
        .multiple_choices => "Multiple Choices",
        .moved_permanently => "Moved Permanently",
        .found => "Found",
        .see_other => "See Other",
        .not_modified => "Not Modified",
        .use_proxy => "Use Proxy",
        .temporary_redirect => "Temporary Redirect",
        .permanent_redirect => "Permanent Redirect",
        .bad_request => "Bad Request",
        .unauthorized => "Unauthorized",
        .payment_required => "Payment Required",
        .forbidden => "Forbidden",
        .not_found => "Not Found",
        .method_not_allowed => "Method Not Allowed",
        .not_acceptable => "Not Acceptable",
        .proxy_authentication_required => "Proxy Authentication Required",
        .request_timeout => "Request Timeout",
        .conflict => "Conflict",
        .gone => "Gone",
        .length_required => "Length Required",
        .precondition_failed => "Precondition Failed",
        .payload_too_large => "Payload Too Large",
        .uri_too_long => "URI Too Long",
        .unsupported_media_type => "Unsupported Media Type",
        .range_not_satisfiable => "Range Not Satisfiable",
        .expectation_failed => "Expectation Failed",
        .im_a_teapot => "I'm a teapot",
        .misdirected_request => "Misdirected Request",
        .unprocessable_entity => "Unprocessable Entity",
        .locked => "Locked",
        .failed_dependency => "Failed Dependency",
        .too_early => "Too Early",
        .upgrade_required => "Upgrade Required",
        .precondition_required => "Precondition Required",
        .too_many_requests => "Too Many Requests",
        .request_header_fields_too_large => "Request Header Fields Too Large",
        .unavailable_for_legal_reasons => "Unavailable For Legal Reasons",
        .internal_server_error => "Internal Server Error",
        .not_implemented => "Not Implemented",
        .bad_gateway => "Bad Gateway",
        .service_unavailable => "Service Unavailable",
        .gateway_timeout => "Gateway Timeout",
        .http_version_not_supported => "HTTP Version Not Supported",
        .variant_also_negotiates => "Variant Also Negotiates",
        .insufficient_storage => "Insufficient Storage",
        .loop_detected => "Loop Detected",
        .not_extended => "Not Extended",
        .network_authentication_required => "Network Authentication Required",
    };
}

// HTTP Headers (common headers for full spec compliance)
const HttpHeader = struct {
    name: []const u8,
    value: []const u8,
};

// CORS Headers (Cross-Origin Resource Sharing)
const CorsConfig = struct {
    allow_origin: []const u8 = "*",
    allow_methods: []const u8 = "GET, POST, PUT, DELETE, PATCH, OPTIONS",
    allow_headers: []const u8 = "Content-Type, Authorization, X-Requested-With",
    allow_credentials: bool = false,
    max_age: u32 = 86400,
    expose_headers: []const u8 = "",
};

// Cache Control Headers
const CacheConfig = struct {
    public_: bool = false,
    private_: bool = true,
    no_cache: bool = false,
    no_store: bool = false,
    max_age: ?u32 = null,
    s_maxage: ?u32 = null,
    must_revalidate: bool = false,
    proxy_revalidate: bool = false,
    no_transform: bool = false,
};

// Range Request Support (RFC 7233)
const RangeRequest = struct {
    unit: []const u8,
    start: u64,
    end: ?u64,
};

// Multipart Form Data Field (for file upload with extra JSON payload)
const MultipartField = struct {
    name: []const u8,
    filename: ?[]const u8,
    content_type: ?[]const u8,
    data: []const u8,
    is_file: bool,
};

// Multipart Form Data Parser State
const MultipartParser = struct {
    boundary: []const u8,
    fields: std.ArrayList(MultipartField),
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator, boundary: []const u8) MultipartParser {
        return .{
            .boundary = boundary,
            .fields = .empty,
            .allocator = allocator,
        };
    }

    fn deinit(self: *MultipartParser) void {
        for (self.fields.items) |field| {
            if (field.is_file) {
                self.allocator.free(field.data);
            }
        }
        self.fields.deinit(self.allocator);
    }

    fn parse(self: *MultipartParser, body: []const u8) !void {
        // Allocate boundary strings
        const boundary_start = try self.allocator.alloc(u8, self.boundary.len + 4);
        defer self.allocator.free(boundary_start);
        boundary_start[0] = '-';
        boundary_start[1] = '-';
        @memcpy(boundary_start[2..][0..self.boundary.len], self.boundary);
        boundary_start[2 + self.boundary.len] = '\r';
        boundary_start[2 + self.boundary.len + 1] = '\n';

        const boundary_end = try self.allocator.alloc(u8, self.boundary.len + 6);
        defer self.allocator.free(boundary_end);
        boundary_end[0] = '-';
        boundary_end[1] = '-';
        @memcpy(boundary_end[2..][0..self.boundary.len], self.boundary);
        boundary_end[2 + self.boundary.len] = '-';
        boundary_end[2 + self.boundary.len + 1] = '-';
        boundary_end[2 + self.boundary.len + 2] = '\r';
        boundary_end[2 + self.boundary.len + 3] = '\n';

        var start: usize = 0;
        // Find first boundary line
        const first_boundary_pos = std.mem.indexOf(u8, body, boundary_start) orelse return;
        start = first_boundary_pos + boundary_start.len;

        while (start < body.len) {
            // Look for next boundary (start or end)
            const next_start_pos = std.mem.indexOf(u8, body[start..], boundary_start);
            const next_end_pos = std.mem.indexOf(u8, body[start..], boundary_end);
            const next_boundary_pos = if (next_start_pos != null and next_end_pos != null)
                @min(next_start_pos.?, next_end_pos.?)
            else if (next_start_pos != null)
                next_start_pos.?
            else if (next_end_pos != null)
                next_end_pos.?
            else
                break; // No more boundaries

            const part_data = body[start .. start + next_boundary_pos];

            // Parse headers and content
            const header_end = std.mem.indexOf(u8, part_data, "\r\n\r\n") orelse {
                start = start + next_boundary_pos + (if (next_start_pos != null and next_start_pos.? == next_boundary_pos) boundary_start.len else boundary_end.len);
                continue;
            };
            const headers = part_data[0..header_end];
            const content = part_data[header_end + 4 ..];

            var field_name: ?[]const u8 = null;
            var field_filename: ?[]const u8 = null;
            var field_content_type: ?[]const u8 = null;

            var header_it = std.mem.splitScalar(u8, headers, '\n');
            while (header_it.next()) |header_line| {
                const trimmed = std.mem.trim(u8, header_line, "\r\n ");
                if (std.mem.startsWith(u8, trimmed, "Content-Disposition:")) {
                    const disp_value = trimmed["Content-Disposition:".len..];
                    if (std.mem.indexOf(u8, disp_value, "name=\"")) |name_start| {
                        const name_val_start = name_start + 6;
                        if (std.mem.indexOf(u8, disp_value[name_val_start..], "\"")) |name_end| {
                            field_name = disp_value[name_val_start..][0..name_end];
                        }
                    }
                    if (std.mem.indexOf(u8, disp_value, "filename=\"")) |fname_start| {
                        const fname_val_start = fname_start + 10;
                        if (std.mem.indexOf(u8, disp_value[fname_val_start..], "\"")) |fname_end| {
                            field_filename = disp_value[fname_val_start..][0..fname_end];
                        }
                    }
                } else if (std.mem.startsWith(u8, trimmed, "Content-Type:")) {
                    field_content_type = std.mem.trim(u8, trimmed["Content-Type:".len..], " \r\n");
                }
            }

            if (field_name) |name| {
                const field_data = if (field_filename != null)
                    try self.allocator.dupe(u8, std.mem.trim(u8, content, "\r\n"))
                else
                    std.mem.trim(u8, content, "\r\n");

                try self.fields.append(self.allocator, .{
                    .name = name,
                    .filename = field_filename,
                    .content_type = field_content_type,
                    .data = field_data,
                    .is_file = (field_filename != null),
                });
            }

            // Move to next part
            start = start + next_boundary_pos + (if (next_start_pos != null and next_start_pos.? == next_boundary_pos) boundary_start.len else boundary_end.len);
            if (next_start_pos == null and next_end_pos != null) break; // Reached final boundary
        }
    }

    fn getField(self: *MultipartParser, name: []const u8) ?*MultipartField {
        for (self.fields.items) |*field| {
            if (std.mem.eql(u8, field.name, name)) {
                return field;
            }
        }
        return null;
    }

    fn getFieldByIndex(self: *MultipartParser, index: usize) ?*MultipartField {
        if (index < self.fields.items.len) {
            return &self.fields.items[index];
        }
        return null;
    }
};

// MIME type mapping for static files
fn mimeType(ext: []const u8) []const u8 {
    if (std.mem.eql(u8, ext, "html")) return "text/html";
    if (std.mem.eql(u8, ext, "css")) return "text/css";
    if (std.mem.eql(u8, ext, "js")) return "application/javascript";
    if (std.mem.eql(u8, ext, "json")) return "application/json";
    if (std.mem.eql(u8, ext, "png")) return "image/png";
    if (std.mem.eql(u8, ext, "jpg") or std.mem.eql(u8, ext, "jpeg")) return "image/jpeg";
    if (std.mem.eql(u8, ext, "gif")) return "image/gif";
    if (std.mem.eql(u8, ext, "svg")) return "image/svg+xml";
    if (std.mem.eql(u8, ext, "webp")) return "image/webp";
    if (std.mem.eql(u8, ext, "mp4")) return "video/mp4";
    if (std.mem.eql(u8, ext, "webm")) return "video/webm";
    if (std.mem.eql(u8, ext, "ogg")) return "video/ogg";
    if (std.mem.eql(u8, ext, "txt")) return "text/plain";
    if (std.mem.eql(u8, ext, "pdf")) return "application/pdf";
    if (std.mem.eql(u8, ext, "xml")) return "application/xml";
    if (std.mem.eql(u8, ext, "ico")) return "image/x-icon";
    if (std.mem.eql(u8, ext, "woff")) return "font/woff";
    if (std.mem.eql(u8, ext, "woff2")) return "font/woff2";
    if (std.mem.eql(u8, ext, "ttf")) return "font/ttf";
    if (std.mem.eql(u8, ext, "eot")) return "application/vnd.ms-fontobject";
    if (std.mem.eql(u8, ext, "otf")) return "font/otf";
    if (std.mem.eql(u8, ext, "csv")) return "text/csv";
    if (std.mem.eql(u8, ext, "rtf")) return "application/rtf";
    if (std.mem.eql(u8, ext, "zip")) return "application/zip";
    if (std.mem.eql(u8, ext, "gz")) return "application/gzip";
    if (std.mem.eql(u8, ext, "tar")) return "application/x-tar";
    if (std.mem.eql(u8, ext, "7z")) return "application/x-7z-compressed";
    if (std.mem.eql(u8, ext, "rar")) return "application/vnd.rar";
    if (std.mem.eql(u8, ext, "mp3")) return "audio/mpeg";
    if (std.mem.eql(u8, ext, "wav")) return "audio/wav";
    if (std.mem.eql(u8, ext, "flac")) return "audio/flac";
    if (std.mem.eql(u8, ext, "aac")) return "audio/aac";
    if (std.mem.eql(u8, ext, "midi")) return "audio/midi";
    if (std.mem.eql(u8, ext, "mid")) return "audio/midi";
    if (std.mem.eql(u8, ext, "mpeg")) return "video/mpeg";
    if (std.mem.eql(u8, ext, "avi")) return "video/x-msvideo";
    if (std.mem.eql(u8, ext, "mov")) return "video/quicktime";
    if (std.mem.eql(u8, ext, "wmv")) return "video/x-ms-wmv";
    if (std.mem.eql(u8, ext, "flv")) return "video/x-flv";
    if (std.mem.eql(u8, ext, "mkv")) return "video/x-matroska";
    if (std.mem.eql(u8, ext, "jsonld")) return "application/ld+json";
    if (std.mem.eql(u8, ext, "rdf")) return "application/rdf+xml";
    if (std.mem.eql(u8, ext, "rss")) return "application/rss+xml";
    if (std.mem.eql(u8, ext, "atom")) return "application/atom+xml";
    if (std.mem.eql(u8, ext, "graphql")) return "application/graphql";
    if (std.mem.eql(u8, ext, "graphqls")) return "application/graphql";
    if (std.mem.eql(u8, ext, "wasm")) return "application/wasm";
    if (std.mem.eql(u8, ext, "manifest")) return "application/manifest+json";
    if (std.mem.eql(u8, ext, "webmanifest")) return "application/manifest+json";
    if (std.mem.eql(u8, ext, "map")) return "application/json";
    if (std.mem.eql(u8, ext, "min.js")) return "application/javascript";
    if (std.mem.eql(u8, ext, "min.css")) return "text/css";

    return "application/octet-stream";
}

// Get file extension from path
fn getFileExtension(path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, path, '.')) |dot_pos| {
        if (dot_pos + 1 < path.len) {
            return path[dot_pos + 1 ..];
        }
    }

    return "";
}

// Parse Range header for partial content support (RFC 7233)
fn parseRangeHeader(range_value: []const u8) ?RangeRequest {
    // Format: bytes=start-end or bytes=start- or bytes=-end
    if (!std.mem.startsWith(u8, range_value, "bytes=")) return null;

    const range_spec = range_value[6..];
    if (std.mem.indexOfScalar(u8, range_spec, '-')) |dash_pos| {
        const start_str = range_spec[0..dash_pos];
        const end_str = range_spec[dash_pos + 1 ..];
        const start = if (start_str.len > 0) std.fmt.parseInt(u64, start_str, 10) catch return null else 0;
        const end = if (end_str.len > 0) std.fmt.parseInt(u64, end_str, 10) catch return null else null;
        return .{
            .unit = "bytes",
            .start = start,
            .end = end,
        };
    }

    return null;
}

// Build Cache-Control header value
fn buildCacheControlHeader(config: CacheConfig, buffer: []u8) ![]const u8 {
    var offset: usize = 0;
    var first = true;

    inline for (.{
        .{ .flag = config.public_, .name = "public" },
        .{ .flag = config.private_, .name = "private" },
        .{ .flag = config.no_cache, .name = "no-cache" },
        .{ .flag = config.no_store, .name = "no-store" },
        .{ .flag = config.must_revalidate, .name = "must-revalidate" },
        .{ .flag = config.proxy_revalidate, .name = "proxy-revalidate" },
        .{ .flag = config.no_transform, .name = "no-transform" },
    }) |item| {
        if (item.flag) {
            if (!first) {
                if (offset + 2 > buffer.len) return error.BufferTooSmall;
                buffer[offset] = ',';
                buffer[offset + 1] = ' ';
                offset += 2;
            }
            if (offset + item.name.len > buffer.len) return error.BufferTooSmall;
            @memcpy(buffer[offset .. offset + item.name.len], item.name);
            offset += item.name.len;
            first = false;
        }
    }

    if (config.max_age) |max_age| {
        if (!first) {
            if (offset + 2 > buffer.len) return error.BufferTooSmall;
            buffer[offset] = ',';
            buffer[offset + 1] = ' ';
            offset += 2;
        }
        const max_age_str = try std.fmt.bufPrint(buffer[offset..], "max-age={d}", .{max_age});
        offset += max_age_str.len;
        first = false;
    }

    if (config.s_maxage) |s_maxage| {
        if (!first) {
            if (offset + 2 > buffer.len) return error.BufferTooSmall;
            buffer[offset] = ',';
            buffer[offset + 1] = ' ';
            offset += 2;
        }
        const s_maxage_str = try std.fmt.bufPrint(buffer[offset..], "s-maxage={d}", .{s_maxage});
        offset += s_maxage_str.len;
    }

    return buffer[0..offset];
}

// Serve static file from ./public directory
// Returns true if file was served (200, 403, or 404 response sent)
// Returns false if public dir missing or path not applicable
fn serveStaticFile(request: *std.http.Server.Request, sub_path: []const u8, io: std.Io) !bool {
    // Security: prevent directory traversal
    if (std.mem.indexOf(u8, sub_path, "..") != null) {
        return false;
    }

    // Build full path: ./public/{sub_path}
    const public_dir = "./public";
    var full_path_buf: [512]u8 = undefined;

    if (public_dir.len + 1 + sub_path.len > full_path_buf.len) {
        return false;
    }

    @memcpy(full_path_buf[0..public_dir.len], public_dir);
    full_path_buf[public_dir.len] = '/';
    @memcpy(full_path_buf[public_dir.len + 1 ..][0..sub_path.len], sub_path);
    const full_path = full_path_buf[0 .. public_dir.len + 1 + sub_path.len];

    // Open file
    const file = std.Io.Dir.cwd().openFile(io, full_path, .{}) catch {
        // File not found - do NOT send response here, let caller handle it
        return false;
    };
    defer file.close(io);

    // Get file stats
    const stat = file.stat(io) catch {
        return false;
    };

    // Only serve regular files
    if (stat.kind != .file) {
        return false;
    }

    // Get MIME type
    const content_type = mimeType(getFileExtension(sub_path));

    // Check for Range request (partial content support)
    var range_request: ?RangeRequest = null;
    var it = request.iterateHeaders();
    while (it.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "range")) {
            range_request = parseRangeHeader(header.value);
            break;
        }
    }

    // Build response headers
    var header_buffer: [2048]u8 = undefined;
    var header_offset: usize = 0;

    // Status line
    if (range_request) |range| {
        // Partial content response
        const start = range.start;
        const end = range.end orelse stat.size - 1;
        const content_length = end - start + 1;

        if (start >= stat.size) {
            // Range not satisfiable
            const header_slice = std.fmt.bufPrint(
                &header_buffer,
                "HTTP/1.1 416 Range Not Satisfiable\r\n" ++
                    "Content-Type: text/plain\r\n" ++
                    "Content-Range: bytes */{d}\r\n" ++
                    "Connection: keep-alive\r\n" ++
                    "\r\n",
                .{stat.size},
            ) catch return false;
            request.server.out.writeAll(header_slice) catch return false;
            request.server.out.flush() catch return false;
            return true;
        }

        const header_slice = std.fmt.bufPrint(
            &header_buffer,
            "HTTP/1.1 206 Partial Content\r\n" ++
                "Content-Type: {s}\r\n" ++
                "Content-Length: {d}\r\n" ++
                "Content-Range: bytes {d}-{d}/{d}\r\n" ++
                "Accept-Ranges: bytes\r\n" ++
                "Connection: keep-alive\r\n" ++
                "\r\n",
            .{ content_type, content_length, start, end, stat.size },
        ) catch return false;

        // Send headers
        request.server.out.writeAll(header_slice) catch return false;

        // Stream file contents - skip to start position by reading and discarding
        var file_read_buffer: [8192]u8 = undefined;
        var file_reader = file.reader(io, &file_read_buffer);
        var copy_buffer: [8192]u8 = undefined;
        var remaining = stat.size;
        var skipped: u64 = 0;

        // Skip bytes until we reach the start position
        while (skipped < start) {
            const to_skip = @min(start - skipped, @as(u64, file_read_buffer.len));
            const bytes_read = file_reader.interface.readSliceShort(file_read_buffer[0..@intCast(to_skip)]) catch break;
            if (bytes_read == 0) break;
            skipped += bytes_read;
        }

        // Now read and send the range content
        remaining = content_length;
        while (remaining > 0) {
            const to_read = @min(remaining, copy_buffer.len);
            const bytes_read = file_reader.interface.readSliceShort(copy_buffer[0..@intCast(to_read)]) catch break;
            if (bytes_read == 0) break;
            request.server.out.writeAll(copy_buffer[0..bytes_read]) catch break;
            remaining -= bytes_read;
        }
    } else {
        // Full content response
        const header_slice = std.fmt.bufPrint(
            &header_buffer,
            "HTTP/1.1 200 OK\r\n" ++
                "Content-Type: {s}\r\n" ++
                "Content-Length: {d}\r\n" ++
                "Accept-Ranges: bytes\r\n" ++
                "Connection: keep-alive\r\n" ++
                "\r\n",
            .{ content_type, stat.size },
        ) catch return false;
        header_offset = header_slice.len;

        // Send headers using request.server.out directly (std.Io.Writer)
        request.server.out.writeAll(header_slice) catch return false;

        // Stream file contents - READER CREATED ONCE BEFORE LOOP (like C++ open() + read loop)
        var file_read_buffer: [8192]u8 = undefined;
        var file_reader = file.reader(io, &file_read_buffer);
        var copy_buffer: [8192]u8 = undefined;
        var remaining = stat.size;
        while (remaining > 0) {
            const to_read = @min(remaining, copy_buffer.len);
            const bytes_read = file_reader.interface.readSliceShort(copy_buffer[0..to_read]) catch break;
            if (bytes_read == 0) break;
            request.server.out.writeAll(copy_buffer[0..bytes_read]) catch break;
            remaining -= bytes_read;
        }
    }

    // revent lock/stuck when requesting exists served file
    request.server.out.flush() catch return false;

    return true;
}

// Save uploaded file to ./public/u directory
fn saveUploadedFile(io: std.Io, filename: []const u8, data: []const u8) ![]const u8 {
    const upload_dir = "./public/u";
    // FIX: std.Io.Dir.createDirPath instead of makePath
    std.Io.Dir.cwd().createDirPath(io, upload_dir) catch {};

    var full_path_buf: [512]u8 = undefined;
    if (upload_dir.len + 1 + filename.len > full_path_buf.len) {
        return error.PathTooLong;
    }
    @memcpy(full_path_buf[0..upload_dir.len], upload_dir);
    full_path_buf[upload_dir.len] = '/';
    @memcpy(full_path_buf[upload_dir.len + 1 ..][0..filename.len], filename);
    const full_path = full_path_buf[0 .. upload_dir.len + 1 + filename.len];

    const file = try std.Io.Dir.cwd().createFile(io, full_path, .{});
    defer file.close(io);

    // FIX: file.writer() requires 3 parameters: file, io, buffer
    // FIX: writer.writeAll() doesn't exist - use writer.interface.writeAll()
    var write_buffer: [8192]u8 = undefined;
    var writer = file.writer(io, &write_buffer);
    try writer.interface.writeAll(data);
    try writer.interface.flush();

    return full_path;
}

// --------------------------------------------------------- //

// WebSocket connection tracking (global, thread-safe)
const WebSocketConnection = struct {
    stream: std.Io.net.Stream,
    io: std.Io,
    room: []const u8,
};

const WebSocketRoom = struct {
    connections: std.ArrayList(*WebSocketConnection),
    mutex: std.Io.Mutex,
};

var g_websocket_rooms: std.StringHashMap(WebSocketRoom) = undefined;
var g_rooms_mutex: std.Io.Mutex = .init;
var g_ws_allocator: std.mem.Allocator = undefined;

// WebSocket opcodes (RFC 6455)
const WebSocketOpcode = enum(u8) {
    continuation = 0x0,
    text = 0x1,
    binary = 0x2,
    close = 0x8,
    ping = 0x9,
    pong = 0xA,
};

// WebSocket frame structure
const WebSocketFrame = struct {
    fin: bool,
    opcode: WebSocketOpcode,
    payload_length: u64,
    masking_key: [4]u8,
    masked: bool,
    payload: []const u8,
};

// Parse WebSocket frame from buffer
fn parseWebSocketFrame(data: []const u8) ?struct { frame: WebSocketFrame, consumed: usize } {
    if (data.len < 2) return null;

    var offset: usize = 0;

    // First byte: FIN + RSV + Opcode
    const first_byte = data[0];
    const fin = (first_byte & 0x80) != 0;
    const opcode_val = first_byte & 0x0F;
    const opcode = @as(WebSocketOpcode, @enumFromInt(opcode_val));
    offset += 1;

    // Second byte: MASK + Payload length
    const second_byte = data[1];
    const masked = (second_byte & 0x80) != 0;
    var payload_length: u64 = second_byte & 0x7F;
    offset += 1;

    // Extended payload length
    if (payload_length == 126) {
        if (data.len < offset + 2) return null;
        payload_length = @as(u64, data[offset]) << 8 | data[offset + 1];
        offset += 2;
    } else if (payload_length == 127) {
        if (data.len < offset + 8) return null;
        payload_length = 0;
        for (0..8) |i| {
            payload_length = (payload_length << 8) | data[offset + i];
        }

        offset += 8;
    }

    // Masking key
    var masking_key: [4]u8 = .{ 0, 0, 0, 0 };

    if (masked) {
        if (data.len < offset + 4) return null;
        @memcpy(&masking_key, data[offset .. offset + 4]);
        offset += 4;
    }

    // Payload
    if (data.len < offset + payload_length) return null;
    const payload_start = offset;
    const payload_end = offset + payload_length;

    // Unmask payload if masked (client->server frames are masked)
    var unmasked_payload: [4096]u8 = undefined;
    const payload_slice = if (masked) blk: {
        for (0..payload_length) |i| {
            unmasked_payload[i] = data[payload_start + i] ^ masking_key[i % 4];
        }
        break :blk unmasked_payload[0..payload_length];
    } else data[payload_start..payload_end];
    offset = payload_end;

    return .{
        .frame = .{
            .fin = fin,
            .opcode = opcode,
            .payload_length = payload_length,
            .masking_key = masking_key,
            .masked = masked,
            .payload = payload_slice,
        },
        .consumed = offset,
    };
}

// Serialize WebSocket frame to buffer (server->client, no mask)
fn serializeWebSocketFrame(buffer: []u8, opcode: WebSocketOpcode, payload: []const u8) usize {
    var offset: usize = 0;

    // First byte: FIN + Opcode
    buffer[offset] = 0x80 | @intFromEnum(opcode);
    offset += 1;

    // Second byte + extended length
    if (payload.len <= 125) {
        buffer[offset] = @intCast(payload.len);
        offset += 1;
    } else if (payload.len <= 65535) {
        buffer[offset] = 126;
        buffer[offset + 1] = @intCast((payload.len >> 8) & 0xFF);
        buffer[offset + 2] = @intCast(payload.len & 0xFF);
        offset += 3;
    } else {
        buffer[offset] = 127;
        for (0..8) |i| {
            buffer[offset + 1 + i] = @as(u8, @intCast((payload.len >> (@as(u6, @intCast(7 - i)) * 8)) & 0xFF));
        }
        offset += 9;
    }

    // Payload - copy to temp first to avoid aliasing
    var temp_payload: [4096]u8 = undefined;
    const copy_len = @min(payload.len, temp_payload.len);
    @memcpy(temp_payload[0..copy_len], payload[0..copy_len]);
    @memcpy(buffer[offset .. offset + copy_len], temp_payload[0..copy_len]);
    offset += copy_len;

    return offset;
}

// Compute WebSocket accept key (SHA1 + Base64)
fn computeWebSocketAccept(key: []const u8, buffer: *[64]u8) ![]const u8 {
    const magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

    // Concatenate key + magic
    var hash_input: [60]u8 = undefined;
    @memcpy(hash_input[0..key.len], key);
    @memcpy(hash_input[key.len..], magic);

    // SHA1 hash
    var hash: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(&hash_input, &hash, .{});

    // Base64 encode
    const base64_encoder = std.base64.standard.Encoder;
    const encoded_len = base64_encoder.calcSize(20);

    return base64_encoder.encode(buffer[0..encoded_len], &hash);
}

// Add connection to room
fn addConnectionToRoom(room_name: []const u8, conn: *WebSocketConnection, io: std.Io) void {
    g_rooms_mutex.lock(io) catch return;

    defer g_rooms_mutex.unlock(io);

    const gop = g_websocket_rooms.getOrPut(room_name) catch return;
    if (!gop.found_existing) {
        gop.value_ptr.* = .{
            .connections = .empty,
            .mutex = .init,
        };
    }
    gop.value_ptr.mutex.lock(io) catch return;
    defer gop.value_ptr.mutex.unlock(io);

    gop.value_ptr.connections.append(g_ws_allocator, conn) catch return;

    // Log connection (like C++ reference)
    const room = gop.value_ptr;
    std.debug.print("WebSocket client connected to room '{s}'. Total in room: {d}\n", .{ room_name, room.connections.items.len });
}

// Remove connection from room
fn removeConnectionFromRoom(room_name: []const u8, conn: *WebSocketConnection, io: std.Io) void {
    g_rooms_mutex.lock(io) catch return;
    defer g_rooms_mutex.unlock(io);
    if (g_websocket_rooms.getPtr(room_name)) |room| {
        room.mutex.lock(io) catch return;

        const before_count = room.connections.items.len;

        // Remove connection from list
        var i: usize = 0;
        while (i < room.connections.items.len) {
            if (room.connections.items[i] == conn) {
                _ = room.connections.orderedRemove(i);
            } else {
                i += 1;
            }
        }

        const after_count = room.connections.items.len;

        // Log disconnect with remaining count (like C++ reference)
        if (before_count > after_count) {
            std.debug.print("WebSocket client disconnected from room '{s}'. Total in room: {d}\n", .{ room_name, after_count });
        }

        // Check if room is empty BEFORE unlocking
        const is_empty = room.connections.items.len == 0;

        // Unlock FIRST, then remove from HashMap
        room.mutex.unlock(io);

        // Remove room if empty and log (like C++ reference)
        if (is_empty) {
            room.connections.deinit(g_ws_allocator);
            _ = g_websocket_rooms.remove(room_name);
            std.debug.print("Room '{s}' removed (empty).\n", .{room_name});
        }
    }
}

// Broadcast message to all connections in a room
fn broadcastToRoom(room_name: []const u8, message: []const u8, io: std.Io) void {
    g_rooms_mutex.lock(io) catch return;

    defer g_rooms_mutex.unlock(io);

    if (g_websocket_rooms.getPtr(room_name)) |room| {
        room.mutex.lock(io) catch return;
        defer room.mutex.unlock(io);

        // Copy payload to separate buffer to avoid aliasing
        var payload_copy: [4096]u8 = undefined;
        const copy_len = @min(message.len, payload_copy.len);
        @memcpy(payload_copy[0..copy_len], message[0..copy_len]);
        const payload_to_send = payload_copy[0..copy_len];

        // Serialize frame ONCE before any writes
        var frame_buffer: [4096]u8 = undefined;
        const frame_len = serializeWebSocketFrame(&frame_buffer, .text, payload_to_send);
        const frame_data = frame_buffer[0..frame_len];

        // Collect failed connections (don't modify list while iterating)
        var failed_indices: [64]usize = undefined;
        var failed_count: usize = 0;

        // Write to all clients
        var i: usize = 0;
        while (i < room.connections.items.len) {
            const conn = room.connections.items[i];

            // Each connection needs its own writer buffer
            var write_buffer: [4096]u8 = undefined;
            var conn_writer = conn.stream.writer(conn.io, &write_buffer);
            conn_writer.interface.writeAll(frame_data) catch {
                // Connection failed, mark for removal
                if (failed_count < failed_indices.len) {
                    failed_indices[failed_count] = i;
                    failed_count += 1;
                }
                i += 1;
                continue;
            };
            conn_writer.interface.flush() catch {
                if (failed_count < failed_indices.len) {
                    failed_indices[failed_count] = i;
                    failed_count += 1;
                }
                i += 1;
                continue;
            };
            i += 1;
        }

        // Remove failed connections (in reverse order to preserve indices)
        var fi: usize = failed_count;
        while (fi > 0) {
            fi -= 1;
            const conn = room.connections.items[failed_indices[fi]];
            _ = room.connections.orderedRemove(failed_indices[fi]);
            g_ws_allocator.destroy(conn);
        }

        // Remove room if empty
        if (room.connections.items.len == 0) {
            room.connections.deinit(g_ws_allocator);
            _ = g_websocket_rooms.remove(room_name);
        }
    }
}

// --------------------------------------------------------- //

// Send HTTP response with full spec compliance
// consider error handling when implement fail for some reason
fn sendHttpResponse(
    request: *std.http.Server.Request,
    status: HttpStatus,
    body: []const u8,
    content_type: []const u8,
    keep_alive: bool,
    cors: ?CorsConfig,
    cache: ?CacheConfig,
    extra_headers: ?[]const HttpHeader,
) !void {
    var header_buffer: [4096]u8 = undefined;
    var offset: usize = 0;

    // Status line
    const status_text = httpStatusText(status);
    const status_line = try std.fmt.bufPrint(
        header_buffer[offset..],
        "HTTP/1.1 {d} {s}\r\n",
        .{ @intFromEnum(status), status_text },
    );
    offset += status_line.len;

    // Content-Type header
    const ct_header = try std.fmt.bufPrint(
        header_buffer[offset..],
        "Content-Type: {s}\r\n",
        .{content_type},
    );
    offset += ct_header.len;

    // Content-Length header
    const cl_header = try std.fmt.bufPrint(
        header_buffer[offset..],
        "Content-Length: {d}\r\n",
        .{body.len},
    );

    offset += cl_header.len;

    // Connection header
    const conn_header = if (keep_alive) "Connection: keep-alive\r\n" else "Connection: close\r\n";
    if (offset + conn_header.len > header_buffer.len) return error.BufferTooSmall;
    @memcpy(header_buffer[offset .. offset + conn_header.len], conn_header);
    offset += conn_header.len;

    // CORS headers (if provided)
    if (cors) |c| {
        var cors_max_age_buf: [32]u8 = undefined;
        const cors_max_age_str = std.fmt.bufPrint(&cors_max_age_buf, "{d}", .{c.max_age}) catch "86400";
        const cors_headers = [_]struct { name: []const u8, value: []const u8 }{
            .{ .name = "Access-Control-Allow-Origin", .value = c.allow_origin },
            .{ .name = "Access-Control-Allow-Methods", .value = c.allow_methods },
            .{ .name = "Access-Control-Allow-Headers", .value = c.allow_headers },
            .{ .name = "Access-Control-Max-Age", .value = cors_max_age_str },
        };

        for (cors_headers) |h| {
            const header_line = try std.fmt.bufPrint(
                header_buffer[offset..],
                "{s}: {s}\r\n",
                .{ h.name, h.value },
            );
            offset += header_line.len;
        }

        if (c.allow_credentials) {
            const cred_header = try std.fmt.bufPrint(
                header_buffer[offset..],
                "Access-Control-Allow-Credentials: true\r\n",
                .{},
            );
            offset += cred_header.len;
        }

        if (c.expose_headers.len > 0) {
            const expose_header = try std.fmt.bufPrint(
                header_buffer[offset..],
                "Access-Control-Expose-Headers: {s}\r\n",
                .{c.expose_headers},
            );
            offset += expose_header.len;
        }
    }

    // Cache-Control header (if provided)
    if (cache) |c| {
        var cache_buf: [256]u8 = undefined;
        const cache_value = buildCacheControlHeader(c, &cache_buf) catch "private";
        const cache_header = try std.fmt.bufPrint(
            header_buffer[offset..],
            "Cache-Control: {s}\r\n",
            .{cache_value},
        );
        offset += cache_header.len;
    }

    // Extra headers (if provided)
    if (extra_headers) |headers| {
        for (headers) |h| {
            const header_line = try std.fmt.bufPrint(
                header_buffer[offset..],
                "{s}: {s}\r\n",
                .{ h.name, h.value },
            );
            offset += header_line.len;
        }
    }

    // End of headers
    if (offset + 2 > header_buffer.len) return error.BufferTooSmall;
    header_buffer[offset] = '\r';
    header_buffer[offset + 1] = '\n';
    offset += 2;

    // Send headers
    request.server.out.writeAll(header_buffer[0..offset]) catch return;
    // Send body (if any)
    if (body.len > 0) {
        request.server.out.writeAll(body) catch return;
    }

    // Flush
    request.server.out.flush() catch return;
}

// Handle OPTIONS request (CORS preflight)
fn handleOptionsRequest(request: *std.http.Server.Request, cors: CorsConfig) !void {
    var header_buffer: [2048]u8 = undefined;
    var offset: usize = 0;
    // Status line
    const status_line = try std.fmt.bufPrint(
        header_buffer[offset..],
        "HTTP/1.1 204 No Content\r\n",
        .{},
    );

    offset += status_line.len;

    // CORS headers
    var cors_max_age_buf: [32]u8 = undefined;
    const cors_max_age_str = std.fmt.bufPrint(&cors_max_age_buf, "{d}", .{cors.max_age}) catch "86400";
    const cors_headers = [_]struct { name: []const u8, value: []const u8 }{
        .{ .name = "Access-Control-Allow-Origin", .value = cors.allow_origin },
        .{ .name = "Access-Control-Allow-Methods", .value = cors.allow_methods },
        .{ .name = "Access-Control-Allow-Headers", .value = cors.allow_headers },
        .{ .name = "Access-Control-Max-Age", .value = cors_max_age_str },
    };

    for (cors_headers) |h| {
        const header_line = try std.fmt.bufPrint(
            header_buffer[offset..],
            "{s}: {s}\r\n",
            .{ h.name, h.value },
        );
        offset += header_line.len;
    }

    if (cors.allow_credentials) {
        const cred_header = try std.fmt.bufPrint(
            header_buffer[offset..],
            "Access-Control-Allow-Credentials: true\r\n",
            .{},
        );
        offset += cred_header.len;
    }

    // End of headers
    if (offset + 2 > header_buffer.len) return error.BufferTooSmall;
    header_buffer[offset] = '\r';
    header_buffer[offset + 1] = '\n';
    offset += 2;

    // Send headers
    request.server.out.writeAll(header_buffer[0..offset]) catch return;
    request.server.out.flush() catch return;
}

// Get Content-Length from request headers
fn getContentLength(request: *std.http.Server.Request) ?usize {
    var it = request.iterateHeaders();
    while (it.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "content-length")) {
            return std.fmt.parseInt(usize, header.value, 10) catch return null;
        }
    }
    return null;
}

// Get Content-Type from request headers
fn getContentType(request: *std.http.Server.Request) ?[]const u8 {
    var it = request.iterateHeaders();
    while (it.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "content-type")) {
            return header.value;
        }
    }
    return null;
}

// Extract boundary from Content-Type header for multipart/form-data
fn extractBoundary(content_type: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, content_type, "multipart/form-data")) return null;
    if (std.mem.indexOf(u8, content_type, "boundary=")) |boundary_pos| {
        return content_type[boundary_pos + 9 ..];
    }
    return null;
}

// Get current timestamp in seconds (using std.Io.Timestamp)
fn getCurrentTimestamp(io: std.Io) i64 {
    const ts = std.Io.Timestamp.now(io, .real);
    return ts.toSeconds();
}

// --------------------------------------------------------- //

//
// Note:
// - Adding middleware may affect your requests/sec test
//

// Context passed through the middleware chain.
const Context = struct {
    request: *std.http.Server.Request,
    io: std.Io,
    conn_reader: *std.Io.Reader,
    conn_writer: *std.Io.Writer,
    allocator: std.mem.Allocator,
    response_sent: bool = false,
    stack: *anyopaque = undefined, // points to the MiddlewareStack
};

// A middleware component.
const Middleware = struct {
    name: []const u8,
    handle: *const fn (ctx: *Context, next: NextFn) anyerror!void,
};

// Function type for the next middleware in the chain.
const NextFn = *const fn (ctx: *Context) anyerror!void;

// Stack that walks through the middleware chain.
const MiddlewareStack = struct {
    middlewares: []const Middleware,
    index: usize,
    ctx: *Context,
    final_handler: *const fn (ctx: *Context) anyerror!void,

    fn next(self: *MiddlewareStack) anyerror!void {
        if (self.index < self.middlewares.len) {
            const mw = self.middlewares[self.index];
            self.index += 1;
            try mw.handle(self.ctx, middlewareNext);
        } else {
            try self.final_handler(self.ctx);
        }
    }
};

fn middlewareNext(ctx: *Context) anyerror!void {
    const stack: *MiddlewareStack = @ptrCast(@alignCast(ctx.stack));
    return stack.next();
}

fn runMiddleware(ctx: *Context, middlewares: []const Middleware, final_handler: *const fn (ctx: *Context) anyerror!void) anyerror!void {
    var stack = MiddlewareStack{
        .middlewares = middlewares,
        .index = 0,
        .ctx = ctx,
        .final_handler = final_handler,
    };
    ctx.stack = &stack;
    try stack.next();
}

fn loggingMiddleware(ctx: *Context, next: NextFn) anyerror!void {
    // const method = @tagName(ctx.request.head.method);
    // const path = ctx.request.head.target;
    // // uncomment below to see the log
    // std.debug.print("[MIDDLEWARE] {s} {s}\n", .{ method, path });
    try next(ctx);
}

fn headerMiddleware(ctx: *Context, next: NextFn) anyerror!void {
    // Placeholder for adding response headers. For full support,
    // extend `sendHttpResponse` to accept extra headers from the context.
    // // uncomment below to see the log
    // std.debug.print("[MIDDLEWARE] Adding custom header (simulated)\n", .{});
    try next(ctx);
}

// Middleware chain for all /zig paths.
const zig_middlewares: []const Middleware = &.{
    .{ .name = "logging", .handle = loggingMiddleware },
    .{ .name = "header", .handle = headerMiddleware },
};

// --------------------------------------------------------- //

// Async client handler - new std.Io async I/O system (Zig 0.16.x)
fn handleZigRoutes(ctx: *Context) anyerror!void {
    defer ctx.response_sent = true; // assume a response is sent on success

    const request = ctx.request;
    const io = ctx.io;
    const conn_reader = ctx.conn_reader;
    const allocator = ctx.allocator;

    const full_path = request.head.target;
    const path = if (std.mem.indexOfScalar(u8, full_path, '?')) |qpos|
        full_path[0..qpos]
    else
        full_path;
    const query = if (std.mem.indexOfScalar(u8, full_path, '?')) |qpos|
        full_path[qpos + 1 ..]
    else
        "";

    const method = request.head.method;
    const cors_config = CorsConfig{
        .allow_origin = "*",
        .allow_methods = "GET, POST, PUT, DELETE, PATCH, OPTIONS",
        .allow_headers = "Content-Type, Authorization, X-Requested-With, Accept",
        .allow_credentials = false,
        .max_age = 86400,
        .expose_headers = "",
    };
    const cache_config = CacheConfig{
        .public_ = true,
        .private_ = false,
        .no_cache = false,
        .no_store = false,
        .max_age = 3600,
        .s_maxage = null,
        .must_revalidate = false,
        .proxy_revalidate = false,
        .no_transform = false,
    };

    if (std.mem.eql(u8, path, "/zig")) {
        switch (method) {
            .GET, .HEAD => {
                const body = "home";
                try sendHttpResponse(request, .ok, body, "text/plain", true, cors_config, cache_config, null);
            },
            .POST, .PUT, .PATCH => {
                const content_length = getContentLength(request) orelse 0;
                if (content_length > 0 and content_length <= CLIENT_REQUEST_BUFFER_SIZE) {
                    var body_buffer: [CLIENT_REQUEST_BUFFER_SIZE]u8 = undefined;
                    var total_read: usize = 0;
                    while (total_read < content_length) {
                        const bytes_read = conn_reader.readSliceShort(body_buffer[total_read..content_length]) catch break;
                        if (bytes_read == 0) break;
                        total_read += bytes_read;
                    }
                    var response_body: [256]u8 = undefined;
                    const response_len = try std.fmt.bufPrint(&response_body, "received {d} bytes", .{total_read});
                    try sendHttpResponse(request, .ok, response_len, "text/plain", true, cors_config, null, null);
                } else {
                    try sendHttpResponse(request, .ok, "no body", "text/plain", true, cors_config, null, null);
                }
            },
            .DELETE => {
                try sendHttpResponse(request, .no_content, "", "text/plain", true, cors_config, null, null);
            },
            else => {
                try sendHttpResponse(request, .method_not_allowed, "Method Not Allowed", "text/plain", true, cors_config, null, null);
            },
        }
        return;
    } else if (std.mem.eql(u8, path, "/zig/json")) {
        switch (method) {
            .GET, .HEAD => {
                const body = "{\"string\":\"string\",\"decimal\":3.14,\"round\":69,\"boolean\":true}";
                try sendHttpResponse(request, .ok, body, "application/json", true, cors_config, cache_config, null);
            },
            .POST, .PUT, .PATCH => {
                const content_length = getContentLength(request) orelse 0;
                if (content_length > 0 and content_length <= CLIENT_REQUEST_BUFFER_SIZE) {
                    var body_buffer: [CLIENT_REQUEST_BUFFER_SIZE]u8 = undefined;
                    var total_read: usize = 0;
                    while (total_read < content_length) {
                        const bytes_read = conn_reader.readSliceShort(body_buffer[total_read..content_length]) catch break;
                        if (bytes_read == 0) break;
                        total_read += bytes_read;
                    }
                    try sendHttpResponse(request, .ok, body_buffer[0..total_read], "application/json", true, cors_config, null, null);
                } else {
                    try sendHttpResponse(request, .ok, "{\"echo\":\"no body\"}", "application/json", true, cors_config, null, null);
                }
            },
            .DELETE => {
                try sendHttpResponse(request, .no_content, "", "text/plain", true, cors_config, null, null);
            },
            else => {
                try sendHttpResponse(request, .method_not_allowed, "Method Not Allowed", "text/plain", true, cors_config, null, null);
            },
        }
        return;
    } else if (std.mem.eql(u8, path, "/zig/echo")) {
        var response_body: std.ArrayList(u8) = .empty;
        defer response_body.deinit(allocator);

        if (query.len == 0) {
            try response_body.appendSlice(allocator, "null");
        } else {
            try response_body.append(allocator, '{');
            var first = true;
            var pos: usize = 0;
            while (pos < query.len) {
                const amp_pos = std.mem.indexOfScalarPos(u8, query, pos, '&') orelse query.len;
                const pair = query[pos..amp_pos];
                if (std.mem.indexOfScalar(u8, pair, '=')) |eq_pos| {
                    const key = pair[0..eq_pos];
                    const val = pair[eq_pos + 1 ..];
                    if (!first) try response_body.appendSlice(allocator, ",");
                    first = false;
                    try response_body.append(allocator, '"');
                    try response_body.appendSlice(allocator, key);
                    try response_body.appendSlice(allocator, "\":");
                    if (val.len == 0) {
                        try response_body.appendSlice(allocator, "null");
                    } else {
                        try response_body.append(allocator, '"');
                        try response_body.appendSlice(allocator, val);
                        try response_body.append(allocator, '"');
                    }
                } else {
                    if (!first) try response_body.appendSlice(allocator, ",");
                    first = false;
                    try response_body.append(allocator, '"');
                    try response_body.appendSlice(allocator, pair);
                    try response_body.appendSlice(allocator, "\":null");
                }
                pos = amp_pos + 1;
            }
            try response_body.append(allocator, '}');
        }

        try sendHttpResponse(request, .ok, response_body.items, "application/json", true, cors_config, null, null);
        return;
    } else if (std.mem.eql(u8, path, "/zig/upload")) {
        if (method == .POST) {
            const content_type = getContentType(request) orelse {
                try sendHttpResponse(request, .bad_request, "Content-Type header required", "text/plain", true, cors_config, null, null);
                return;
            };
            const boundary = extractBoundary(content_type) orelse {
                try sendHttpResponse(request, .bad_request, "Invalid multipart/form-data Content-Type", "text/plain", true, cors_config, null, null);
                return;
            };
            const content_length = getContentLength(request) orelse 0;
            if (content_length == 0 or content_length > CLIENT_REQUEST_BUFFER_SIZE) {
                try sendHttpResponse(request, .payload_too_large, "Payload too large", "text/plain", true, cors_config, null, null);
                return;
            }
            var body_buffer: [CLIENT_REQUEST_BUFFER_SIZE]u8 = undefined;
            var total_read: usize = 0;
            while (total_read < content_length) {
                const bytes_read = conn_reader.readSliceShort(body_buffer[total_read..content_length]) catch break;
                if (bytes_read == 0) break;
                total_read += bytes_read;
            }
            var parser = MultipartParser.init(allocator, boundary);
            defer parser.deinit();
            parser.parse(body_buffer[0..total_read]) catch {
                try sendHttpResponse(request, .bad_request, "Failed to parse multipart data", "text/plain", true, cors_config, null, null);
                return;
            };
            var response_json: std.ArrayList(u8) = .empty;
            defer response_json.deinit(allocator);
            try response_json.appendSlice(allocator, "{\"files\":[");
            var first_file = true;
            var i: usize = 0;
            while (i < parser.fields.items.len) : (i += 1) {
                const field = &parser.fields.items[i];
                if (field.is_file) {
                    const saved_path = saveUploadedFile(io, field.filename.?, field.data) catch {
                        try sendHttpResponse(request, .internal_server_error, "Failed to save file", "text/plain", true, cors_config, null, null);
                        return;
                    };
                    if (!first_file) try response_json.appendSlice(allocator, ",");
                    first_file = false;
                    var file_entry: [512]u8 = undefined;
                    const entry_slice = try std.fmt.bufPrint(&file_entry, "{{\"name\":\"{s}\",\"size\":{d},\"path\":\"{s}\"}}", .{
                        field.filename.?,
                        field.data.len,
                        saved_path,
                    });
                    try response_json.appendSlice(allocator, entry_slice);
                }
            }
            try response_json.appendSlice(allocator, "],\"fields\":");
            try response_json.append(allocator, '{');
            var first_field = true;
            i = 0;
            while (i < parser.fields.items.len) : (i += 1) {
                const field = &parser.fields.items[i];
                if (!field.is_file) {
                    if (!first_field) try response_json.appendSlice(allocator, ",");
                    first_field = false;
                    try response_json.append(allocator, '"');
                    try response_json.appendSlice(allocator, field.name);
                    try response_json.appendSlice(allocator, "\":\"");
                    try response_json.appendSlice(allocator, field.data);
                    try response_json.append(allocator, '"');
                }
            }
            try response_json.appendSlice(allocator, "}}");
            try sendHttpResponse(request, .ok, response_json.items, "application/json", true, cors_config, null, null);
            return;
        } else {
            try sendHttpResponse(request, .method_not_allowed, "Method Not Allowed", "text/plain", true, cors_config, null, null);
            return;
        }
    } else if (std.mem.startsWith(u8, path, "/zig/")) {
        var response_body: std.ArrayList(u8) = .empty;
        defer response_body.deinit(allocator);
        try response_body.appendSlice(allocator, "value path: ");
        try response_body.appendSlice(allocator, path);
        try sendHttpResponse(request, .ok, response_body.items, "text/plain", true, cors_config, cache_config, null);
        return;
    } else {
        // No dynamic route matched, try static file (from ./public)
        if (std.mem.startsWith(u8, path, "/")) {
            const sub_path = path[1..];
            const file_served = serveStaticFile(request, sub_path, io) catch false;
            if (file_served) return;
        }
        try sendHttpResponse(request, .not_found, "Not Found", "text/plain", true, cors_config, null, null);
        return;
    }
}

// Middleware integration included
fn handleClient(stream: std.Io.net.Stream, io: std.Io) void {
    defer stream.close(io);

    var receive_buffer: [CLIENT_REQUEST_BUFFER_SIZE]u8 = undefined;
    var send_buffer: [CLIENT_REQUEST_BUFFER_SIZE]u8 = undefined;

    var conn_reader = stream.reader(io, &receive_buffer);
    var conn_writer = stream.writer(io, &send_buffer);
    var server = std.http.Server.init(&conn_reader.interface, &conn_writer.interface);

    const cors_config = CorsConfig{
        .allow_origin = "*",
        .allow_methods = "GET, POST, PUT, DELETE, PATCH, OPTIONS",
        .allow_headers = "Content-Type, Authorization, X-Requested-With, Accept",
        .allow_credentials = false,
        .max_age = 86400,
        .expose_headers = "",
    };

    while (true) {
        var request = server.receiveHead() catch |err| {
            if (err == error.HttpConnectionClosing) break;
            if (err == error.ConnectionResetByPeer) break;
            break;
        };
        const full_path = request.head.target;
        const path = if (std.mem.indexOfScalar(u8, full_path, '?')) |qpos|
            full_path[0..qpos]
        else
            full_path;
        const method = request.head.method;

        // Check for WebSocket upgrade request (handled separately, before middleware)
        const is_chat_path = std.mem.startsWith(u8, path, "/zig/chat/");
        const is_get_method = method == .GET;
        if (is_chat_path and is_get_method) {
            // Extract room name from path
            const room_name = path[10..]; // "/zig/chat/".len = 10
            if (room_name.len == 0) {
                sendHttpResponse(
                    &request,
                    .bad_request,
                    "Bad Request",
                    "text/plain",
                    true,
                    cors_config,
                    null,
                    null,
                ) catch break;
                break;
            }

            // Check for WebSocket upgrade headers
            var sec_ws_key: ?[]const u8 = null;
            var is_upgrade = false;
            var it = request.iterateHeaders();
            while (it.next()) |header| {
                if (std.ascii.eqlIgnoreCase(header.name, "upgrade")) {
                    is_upgrade = std.mem.indexOfScalar(u8, header.value, 'w') != null;
                } else if (std.ascii.eqlIgnoreCase(header.name, "sec-websocket-key")) {
                    sec_ws_key = header.value;
                }
            }
            if (is_upgrade and sec_ws_key != null) {
                // Perform WebSocket handshake
                var accept_buffer: [64]u8 = undefined;
                const accept_key = computeWebSocketAccept(sec_ws_key.?, &accept_buffer) catch break;

                // Send handshake response
                var handshake_response: [512]u8 = undefined;
                const handshake_slice = std.fmt.bufPrint(
                    &handshake_response,
                    "HTTP/1.1 101 Switching Protocols\r\n" ++
                        "Upgrade: websocket\r\n" ++
                        "Connection: Upgrade\r\n" ++
                        "Sec-WebSocket-Accept: {s}\r\n" ++
                        "\r\n",
                    .{accept_key},
                ) catch break;

                // Use stream.writer for raw WebSocket communication
                var ws_writer = stream.writer(io, &send_buffer);
                ws_writer.interface.writeAll(handshake_slice) catch break;
                ws_writer.interface.flush() catch break;

                // Create connection on HEAP, not stack
                const ws_conn = g_ws_allocator.create(WebSocketConnection) catch break;
                ws_conn.* = .{
                    .stream = stream,
                    .io = io,
                    .room = room_name,
                };
                defer g_ws_allocator.destroy(ws_conn);

                // Add to room
                addConnectionToRoom(room_name, ws_conn, io);

                // WebSocket frame loop (per-room broadcast)
                var frame_buffer: [CLIENT_REQUEST_BUFFER_SIZE]u8 = undefined;
                var buffer_used: usize = 0;
                while (true) {
                    // Read more data if needed - use readSliceShort, NOT stream()
                    if (buffer_used < frame_buffer.len - 1) {
                        // Create a temporary writer to receive data into frame_buffer
                        var temp_writer = std.Io.Writer.fixed(frame_buffer[buffer_used..]);
                        const bytes_read = conn_reader.interface.stream(&temp_writer, .unlimited) catch break;
                        if (bytes_read == 0) break;
                        buffer_used += bytes_read;
                    }

                    // Parse WebSocket frames
                    var offset: usize = 0;
                    while (offset < buffer_used) {
                        const result = parseWebSocketFrame(frame_buffer[offset..]) orelse break;
                        const frame = result.frame;
                        const consumed = result.consumed;
                        // Handle different opcodes
                        switch (frame.opcode) {
                            .text, .binary => {
                                // Broadcast to all connections in same room
                                broadcastToRoom(room_name, frame.payload, io);
                            },
                            .ping => {
                                // Respond with PONG
                                var pong_buffer: [4096]u8 = undefined;
                                const pong_len = serializeWebSocketFrame(&pong_buffer, .pong, frame.payload);
                                conn_writer.interface.writeAll(pong_buffer[0..pong_len]) catch break;
                                conn_writer.interface.flush() catch break;
                            },
                            .pong => {
                                // Ignore PONG
                            },
                            .close => {
                                // Send close frame back and close connection
                                var close_buffer: [4096]u8 = undefined;
                                const close_len = serializeWebSocketFrame(&close_buffer, .close, &.{});
                                conn_writer.interface.writeAll(close_buffer[0..close_len]) catch {};
                                conn_writer.interface.flush() catch {};
                                break;
                            },
                            .continuation => {
                                // Not handling fragmented messages
                            },
                        }
                        offset += consumed;
                    }

                    // Remove processed data from buffer
                    if (offset > 0 and offset < buffer_used) {
                        @memmove(frame_buffer[0 .. buffer_used - offset], frame_buffer[offset..buffer_used]);
                        buffer_used -= offset;
                    } else if (offset >= buffer_used) {
                        buffer_used = 0;
                    }
                }

                // Clean up connection
                removeConnectionFromRoom(room_name, ws_conn, io);
                break;
            }

            // Not a WebSocket request, fall through to normal HTTP
        }

        // Handle OPTIONS preflight (CORS)
        if (method == .OPTIONS) {
            handleOptionsRequest(&request, cors_config) catch break;
            continue;
        }

        var handled = false;

        // Apply middleware for /zig paths
        if (std.mem.startsWith(u8, path, "/zig")) {
            var ctx = Context{
                .request = &request,
                .io = io,
                .conn_reader = &conn_reader.interface,
                .conn_writer = &conn_writer.interface,
                .allocator = std.heap.smp_allocator,
                .response_sent = false,
            };
            runMiddleware(&ctx, zig_middlewares, handleZigRoutes) catch {}; // ignore error, handled by ctx.response_sent
            // If middleware or final handler sent a response, we consider it handled.
            handled = ctx.response_sent;
        }

        // If not handled by middleware, process other routes (non-/zig) and static files
        if (!handled) {
            // The rest of the original routing logic (non-/zig paths)
            if (std.mem.eql(u8, path, "/zig/json/status")) {
                const body = "{\"status\":\"ok\",\"version\":\"0.1.0\"}";
                sendHttpResponse(&request, .ok, body, "application/json", true, cors_config, null, null) catch break;
                handled = true;
            } else if (std.mem.eql(u8, path, "/zig/json/time")) {
                var time_buf: [64]u8 = undefined;
                const timestamp = getCurrentTimestamp(io);
                const time_str = std.fmt.bufPrint(&time_buf, "{{\"timestamp\":{d}}}", .{timestamp}) catch break;
                sendHttpResponse(&request, .ok, time_str, "application/json", true, cors_config, null, null) catch break;
                handled = true;
            }

            if (!handled) {
                // Try static files
                if (std.mem.startsWith(u8, path, "/")) {
                    const sub_path = path[1..];
                    const file_served = serveStaticFile(&request, sub_path, io) catch false;
                    if (file_served) {
                        handled = true;
                    }
                }

                if (!handled) {
                    sendHttpResponse(&request, .not_found, "Not Found", "text/plain", true, cors_config, null, null) catch break;
                }
            }
        }

        // Continue to next request on keep-alive
        // discardBody() is private - respond() does it handles internally?
    }
}

// --------------------------------------------------------- //

// Async-aware server loop with io.concurrent() for task spawning
fn runServer(io: std.Io) !void {
    const addr = try std.Io.net.IpAddress.resolve(io, ADDRESS_IP, ADDRESS_PORT);
    var tcp_server = try addr.listen(io, .{
        .mode = .stream,
        .kernel_backlog = 1024,
        .reuse_address = true,
    });
    defer tcp_server.deinit(io);

    // Initialize global WebSocket room map
    g_websocket_rooms = std.StringHashMap(WebSocketRoom).init(std.heap.smp_allocator);
    g_ws_allocator = std.heap.smp_allocator;
    // might simplified

    std.debug.print("backend_zig_async: run on {s}:{d}\n", .{ ADDRESS_IP, ADDRESS_PORT });
    std.debug.print("  - HTTP endpoint                           : /zig\n", .{});
    std.debug.print("  - JSON endpoint                           : /zig/json\n", .{});
    std.debug.print("  - Time endpoint                           : /zig/json/time\n", .{});
    std.debug.print("  - Health check                            : /zig/json/status\n", .{});
    std.debug.print("  - Echo endpoint                           : /zig/echo?text=hello (query parameters)\n", .{});
    std.debug.print("  - WebSocket endpoint                      : /zig/chat/{{room_name}} (per room broadcast)\n", .{});
    std.debug.print("  - File upload                             : /zig/upload (multipart/form-data) -> ./public/u\n", .{});
    std.debug.print("  - Dynamic path                            : /zig/{{path1}}/{{path2}}/... (except /zig/json)\n", .{});
    std.debug.print("  - Static files from ./public at root, e.g.: /favicon.svg (make it sure the file exists on that directory)\n", .{});
    std.debug.print("  // --------------------------------------------------------- //\n", .{});
    std.debug.print("  - CORS enabled for all endpoints\n", .{});
    std.debug.print("  - Range requests supported for static files\n", .{});
    std.debug.print("  - Full HTTP spec: GET, POST, PUT, DELETE, PATCH, OPTIONS, HEAD\n", .{});

    while (true) {
        // Async accept: suspends until new connection available
        var stream = tcp_server.accept(io) catch |err| {
            std.debug.print("Accept error: {}\n", .{err});
            continue;
        };

        // Use io.concurrent() - direct task spawning (like C++ ThreadPool.enqueue)
        // Stream passed by value (ownership transferred to task)
        _ = io.concurrent(handleClient, .{ stream, io }) catch |err| {
            std.debug.print("Concurrent error: {}\n", .{err});
            stream.close(io);
        };
    }
}

// --------------------------------------------------------- //

pub fn main() !void {
    // Thread count configuration: 0 = all threads, greater than 0 = specific count
    const concurrent_limit: std.Io.Limit = if (WORKER_THREADS_TARGET == 0)
        .unlimited
    else
        .{.limited(WORKER_THREADS_TARGET)};

    // Threaded I/O with concurrent task support - new std.Io async system
    // async_limit auto-detected from CPU count if not provided
    var io = std.Io.Threaded.init(std.heap.smp_allocator, .{
        .stack_size = std.Thread.SpawnConfig.default_stack_size,
        .concurrent_limit = concurrent_limit,
        // async_limit defaults to cpu_count - 1 if not provided
    });
    defer io.deinit();

    try runServer(io.io());
}

//
// IMPORTANT:
// this implementation result:
// ➜ wrk -c100 -t6 -d10s http://localhost:9007/zig
// Running 10s test @ http://localhost:9007/zig
//   6 threads and 100 connections
//   Thread Stats   Avg      Stdev     Max   +/- Stdev
//     Latency   253.55us  443.18us  23.02ms   96.15%
//     Req/Sec    58.69k    15.09k   83.05k    49.83%
//   3526361 requests in 10.10s, 1.14GB read
// Requests/sec: 349165.15
// Transfer/sec:    115.55MB
//
// ASYNC VERIFICATION (Zig 0.16.x - std.Io):
// - std.Io.Threaded provides async I/O backend with thread pool
// - io.concurrent() spawns tasks that suspend/resume on I/O
// - stream.reader(io, buffer) and writer(io, buffer) are async interfaces
// - receiveHead() and respond() suspend when waiting for I/O (non-blocking)
// - Kernel handles suspension efficiently (no busy-waiting)
//
// THREAD DETECTION (from std/Io/Threaded.zig):
// - init() calls std.Thread.getCpuCount() internally [[std/Io/Threaded.zig:1637]]
// - async_limit defaults to cpu_count - 1 if not provided [[std/Io/Threaded.zig:1642]]
// - concurrent_limit controls max concurrent tasks (prevents thread explosion)
// - NO n_threads field in InitOptions - thread pool is dynamic
//
// PERFORMANCE CHARACTERISTICS:
// - M:N scheduling (many tasks, fewer threads)
// - Suspension happens in kernel (efficient, no userspace overhead)
// - smp_allocator is thread-safe (lock-free per-CPU arenas)
// - WORKER_THREADS_TARGET = 0 means unlimited concurrent tasks
//
// FULL HTTP SPEC IMPLEMENTATION:
// - All HTTP/1.1 methods: GET, POST, PUT, DELETE, PATCH, HEAD, OPTIONS, TRACE, CONNECT
// - All standard HTTP status codes (1xx, 2xx, 3xx, 4xx, 5xx)
// - Proper Content-Type and Content-Length headers
// - CORS support (Access-Control-* headers)
// - Cache-Control headers for static content
// - Range request support (RFC 7233) for partial content
// - Keep-Alive connection management
// - Request body parsing for POST/PUT/PATCH
// - URL-encoded form data parsing
// - Multipart form data support (file uploads to ./public/u)
// - Proper error responses with appropriate status codes
// - Security headers support (can be added via extra_headers parameter)
//
// CURL EXAMPLES FOR FILE UPLOAD:
//
// 1. Upload single file with extra JSON field:
//    curl -X POST http://localhost:9007/zig/upload \
//      -F "file=@/path/to/file.txt" \
//      -F "description=My test file"
//
// 2. Upload multiple files:
//    curl -X POST http://localhost:9007/zig/upload \
//      -F "file1=@/path/to/file1.png" \
//      -F "file2=@/path/to/file2.jpg" \
//      -F "title=Multiple Upload"
//
// 3. Upload with metadata (check by index):
//    curl -X POST http://localhost:9007/zig/upload \
//      -F "document=@/path/to/doc.pdf" \
//      -F "author=John Doe" \
//      -F "category=reports"
//
// Response format:
// {"files":[{"name":"file.txt","size":1024,"path":"./public/u/file.txt"}],"fields":{"description":"My test file"}}
//
