//! ZIX Http1 request
//!
//! ### file: src/zix/tcp/http1/Request.zig
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
const builtint = @import("builtin");
const ParsedHead = @import("ParsedHead.zig");
const Method = @import("../../utils/http/method.zig");
const core = @import("core.zig");
const router = @import("router.zig");

// --------------------------------------------------------- //
// Fields:

fd: std.posix.fd_t,
head: *const ParsedHead,
body_bytes: []const u8,
body_received: u64 = 0,
body_complete: bool = true,

const Self = @This();

// --------------------------------------------------------- //
// Public:

/// Build a request view over a parsed head, body, and fd.
///
/// Note:
/// - The defaults describe a body that arrived whole and fits the delivered
///   slice, which is every request the engine did not have to measure. A
///   dispatch model that drained or cut a body overrides both fields through
///   core.tl_body_info.
///
/// Param:
/// head - *const core.ParsedHead (borrows the receive buffer)
/// body_data - []const u8 (already drained by the engine, empty when none)
/// fd - std.posix.fd_t (the connection)
///
/// Return:
/// - Request
pub fn init(head: *const ParsedHead, body_data: []const u8, fd: std.posix.fd_t) Self {
    return .{ .head = head, .body_bytes = body_data, .fd = fd, .body_received = body_data.len };
}

/// The HTTP method as the typed code. An unknown or oversized method token
/// maps to GET (the Method.enumFromString contract).
pub fn method(self: Self) Method.Code {
    if (self.head.method.len > 8) return .GET;

    return Method.enumFromString(self.head.method);
}

/// The path without the query string.
pub fn path(self: Self) []const u8 {
    return self.head.path;
}

/// The raw query string after the "?", or empty.
pub fn query(self: Self) []const u8 {
    return self.head.query;
}

/// One query parameter value, or null.
pub fn queryParam(self: Self, name: []const u8) ?[]const u8 {
    return core.queryParam(self.head, name);
}

/// One request header value by name (case-insensitive), or null.
pub fn header(self: Self, name: []const u8) ?[]const u8 {
    return core.getHeader(self.head, name);
}

/// A path parameter captured by a PARAM route, or null. Reads the request's
/// own captured set first (async lane), then falls back to the router
/// threadlocal (sync path).
pub fn pathParam(self: Self, name: []const u8) ?[]const u8 {
    for (self.path_params) |path_param| {
        if (std.mem.eql(u8, path_param.name, name)) return path_param.value;
    }

    return router.pathParam(name);
}

/// The body bytes handed to this handler. Identical call shape to zix.Http.
/// The engine already took the body off the socket before the handler ran,
/// so this never reads the socket and never blocks.
///
/// Note:
/// - This is the DATA. bodyReceived() is the COUNT of what came off the
///   socket. They answer different questions, see bodyReceived().
/// - The slice borrows the connection receive buffer and is only valid for
///   the duration of the handler call. Copy it to keep it.
/// - Empty when the request declared no body, and also when the engine
///   could not deliver one (a body past the receive buffer is discarded).
///
/// Return:
/// - []const u8 (the engine-delivered body slice, empty when none)
pub fn body(self: *Self) ![]const u8 {
    return self.body_bytes;
}

/// How many body bytes the engine took off the socket for this request.
/// Counted from the reads that received them, never read from the
/// Content-Length header, so a lying header cannot inflate it.
///
/// Note:
/// - This is the COUNT. body() is the DATA. A handler that only needs the
///   size (an upload receipt, a metric) reads this and skips the bytes.
/// - bodyReceived() == body().len means the handler was given everything.
///   A larger count means bytes arrived that body() does not contain, so
///   any parse of body() is working on a fragment.
/// - The two are equal whenever the body fit the receive buffer.
/// - Past the receive buffer every dispatch model counts the drained
///   remainder as well, so the same request reports the same number on all
///   three and one handler can be written against any of them. That holds
///   for a body that arrived whole. One the peer cut short never reaches a
///   handler on .EPOLL or .URING, see bodyComplete().
/// - For a chunked body this counts the wire bytes, framing included, so it
///   is larger than body().len by the size of that framing.
///
/// Return:
/// - u64 (counted received body bytes)
pub fn bodyReceived(self: Self) u64 {
    return self.body_received;
}

/// Whether the engine read this request's body all the way to its end: the
/// declared Content-Length, or the chunked terminator.
///
/// Note:
/// - False means the peer stopped sending part way. The bytes in body() are
///   real, there are just fewer of them than the request promised, so an
///   upload that looks small may be a large one that was cut off.
/// - Only .ASYNC ever reports false. It reads the body inline and runs the
///   handler with whatever arrived. .EPOLL and .URING hold the request until
///   its body is whole, so a peer that quits part way never reaches a
///   handler there: the engine answers 400 with Connection: close itself and
///   drops the request. This reads true on both by construction.
/// - True for a request that declared no body, since there was nothing to
///   fall short of.
/// - True does not mean the handler was given every byte. A body past the
///   receive buffer arrives complete and is delivered short, which is what
///   bodyReceived() against body().len tells apart.
/// - Connection safety does not depend on this. A body only falls short when
///   the peer stopped sending, and the serve loop ends on the next read.
///   This is for the handler's own decision: reject the upload, log it, bill
///   the bytes that did arrive.
/// - zix.Http answers the same question with the same name, with one extra
///   case: there the body is read lazily, so a handler that never calls
///   body() leaves it unread and this reads false.
///
/// Usage:
/// ```zig
/// // The guard runs on .ASYNC. On .EPOLL and .URING the engine already
/// // refused the cut-short upload, so the handler only sees whole ones and
/// // the branch is never taken.
/// fn uploadHandler(req: *Request, res: *Response, _: *Context) !void {
///     if (!req.bodyComplete()) {
///         res.setStatus(.BAD_REQUEST);
///         try res.send("incomplete body");
///
///         return;
///     }
///
///     var buf: [32]u8 = undefined;
///     try res.send(try std.fmt.bufPrint(&buf, "{d}", .{req.bodyReceived()}));
/// }
/// ```
///
/// Return:
/// - bool
pub fn bodyComplete(self: Self) bool {
    return self.body_complete;
}

/// Whether the connection is keep-alive.
pub fn keepAlive(self: Self) bool {
    return self.head.keep_alive;
}

/// Split the request path into non-empty segments.
pub fn pathSegments(self: Self, allocator: std.mem.Allocator) ![][]const u8 {
    var list: std.ArrayList([]const u8) = .empty;

    var iter = std.mem.splitScalar(u8, self.path(), '/');
    while (iter.next()) |segment| {
        if (segment.len > 0) try list.append(allocator, segment);
    }

    return list.items;
}

pub const QueryParam = struct {
    key: []const u8,
    value: ?[]const u8,
};

/// Get all query parameters as a slice of QueryParam.
pub fn queryParams(self: Self, allocator: std.mem.Allocator) ![]QueryParam {
    const query_str = self.query();
    if (query_str.len == 0) return &.{};

    var list: std.ArrayList(QueryParam) = .empty;
    var pos: usize = 0;
    while (pos < query_str.len) {
        const amp_pos = std.mem.indexOfScalarPos(u8, query_str, pos, '&') orelse query_str.len;
        const pair = query_str[pos..amp_pos];
        if (pair.len > 0) {
            if (std.mem.indexOfScalar(u8, pair, '=')) |eq_pos| {
                const value = pair[eq_pos + 1 ..];
                try list.append(allocator, .{
                    .key = pair[0..eq_pos],
                    .value = if (value.len > 0) value else null,
                });
            } else {
                try list.append(allocator, .{ .key = pair, .value = null });
            }
        }
        if (amp_pos >= query_str.len) break;
        pos = amp_pos + 1;
    }

    return list.items;
}

/// Parse a complete raw HTTP/1.x head buffer into a Request.
/// Useful for tests and offline parsing. buf must contain a full head
/// (\r\n\r\n) and must outlive the Request (every slice borrows it). The
/// parsed head is one small allocation from allocator.
pub fn fromRaw(buf: []const u8, allocator: std.mem.Allocator) !Self {
    const result = try core.parseHead(buf);

    const head = try allocator.create(ParsedHead);
    head.* = result.head;

    const body_start = @min(result.body_offset, buf.len);
    return .{
        .fd = if (builtint.target.os.tag == .windows) std.os.windows.INVALID_HANDLE_VALUE else -1,
        .head = head,
        .body_bytes = buf[body_start..],
        .body_received = buf.len - body_start
    };
}

