//! ZIX Http1 response sink
//!
//! ### file: src/zix/tcp/http1/Self.zig
//! 
//! ### author: Prana Ron
//! 
//! ---------------------------------------------------------
//! 
//! ### brief:
//! 
//! Coalescing buffer for response bytes staged for one connection.
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
const Status = @import("../../utils/http/status.zig");
const head = @import("head.zig");
const writer = @import("writer.zig");
const cache = @import("cache.zig");

// --------------------------------------------------------- //
// Fields:

fd: std.posix.fd_t,
buf: []u8,
len: usize = 0,
failed: bool = false,
// TODO: spill: ?*TlsStreamSink = null,
grow_allocator: ?std.mem.Allocator = null,
grow_cap: usize = 0,
buf_owned: bool = true,
allow_direct: bool = false,
direct: []const u8 = &.{},
direct_slot: u32 = 0,
off: usize = 0,

const Self = @This();

// --------------------------------------------------------- //
// Public:

/// ZIX Http1 response sink error
pub const Error = error {
    ZixHttp1_RespSink_HeadBuild,
};

// --------------------------------------------------------- //
// Private:

/// Send bytes that are not staying in buf: through the spill sink when one is installed (https,
/// where the fd is a sentinel and every write has to become a TLS record), straight to the
/// descriptor otherwise. A write that does not land marks the sink failed, which the caller
/// reads as a broken peer.
fn writeOut(self: *Self, bytes: []const u8) void {
    std.log.info("TODO: self.spill as sink and write", .{});
    // if write the bytes failed, set failed to true

    writer.writeAllDirectFD(self.fd, bytes) catch |err| switch (err) {
        error.ZixHttp1_Writer_BrokenPipe,
        error.ZixHttp1_Writer_HeadBuild,
        => self.failed = true,
    };
}

// --------------------------------------------------------- //
// Public:

/// Fold a captured zero-copy replay back into the staged batch: a later
/// response in the same batch means the send must carry both in order, so
/// the borrowed bytes are copied after all and the pin drops. The copy
/// happens before unpin could matter: this worker owns the cache, so
/// nothing can overwrite the region between the unpin and the memcpy.
pub fn materializeDirect(self: *Self) void {
    if (self.direct.len == 0) return;

    const bytes = self.direct;
    self.direct = &.{};
    if (cache.tl_cache) |c| c.unpin(self.direct_slot);

    self.append(bytes);
}

pub fn append(self: *Self, bytes: []const u8) void {
    // Single response larger than the whole buffer: grow to hold it when
    // backed by an allocator, otherwise flush the staged batch and write
    // this payload straight through.
    if (bytes.len > self.buf.len) {
        if (self.grow(self.len + bytes.len)) {
            @memcpy(self.buf[self.len..][0..bytes.len], bytes);
            self.len += bytes.len;

            return;
        }

        self.flush();
        self.writeOut(bytes);

        return;
    }

    // Cumulative overflow: the staged batch plus these bytes exceed the
    // buffer. Grow to keep the batch on the ring, otherwise flush it first.
    if (self.len + bytes.len > self.buf.len) {
        if (!self.grow(self.len + bytes.len)) self.flush();
    }

    @memcpy(self.buf[self.len..][0..bytes.len], bytes);
    self.len += bytes.len;
}

pub fn flush(self: *Self) void {
    if (self.len == 0) return;

    self.writeOut(self.buf[self.off..self.len]);
    self.len = 0;
    self.off = 0;
}

/// Reserve an in-place body region for a response rendered directly into
/// the sink buffer, so the body bytes are written exactly once (no
/// handler-side scratch buffer, no append copy). The region starts at
/// HEADER_BUF_SIZE: commitSimple builds the header right-aligned so it
/// ends exactly where the body starts.
///
/// Note:
/// - Returns null when the sink already stages bytes (a pipelined batch),
///   a zero-copy replay is captured, or max_body does not fit. The caller
///   falls back to rendering its own buffer and writeAllFD.
/// - Between reserve and commitSimple the caller must not stage any other
///   response bytes for this sink.
///
/// Return:
/// - []u8 body region of max_body bytes
/// - null when unavailable, the caller uses the writeAllFD path
pub fn reserve(self: *Self, max_body: usize) ?[]u8 {
    if (self.len != 0 or self.direct.len != 0 or self.failed) return null;
    if (head.HEADER_BUF_SIZE + max_body > self.buf.len) {
        if (!self.grow(head.HEADER_BUF_SIZE + max_body)) return null;
    }

    return self.buf[head.HEADER_BUF_SIZE..][0..max_body];
}

/// Commit a reserved render: build the simple header right-aligned so it
/// ends exactly where the body starts, and stage header + body as one
/// contiguous region (off marks the dead prefix before the header).
pub fn commitSimple(
    self: *Self,
    io: std.Io,
    status: Status.Code,
    content_type: []const u8,
    body_len: usize,
) Error!void {
    std.debug.assert(self.len == 0 and self.direct.len == 0);

    var hdr_buf: [head.HEADER_BUF_SIZE]u8 = undefined;
    const hdr = head.buildSimpleHeader(
        io, &hdr_buf, status, content_type, body_len,
    ) catch |err| switch (err) {
        error.ZixHttp1_Head_DateFormat => return Error.ZixHttp1_RespSink_HeadBuild,
    };
    const start = head.HEADER_BUF_SIZE - hdr.len;
    @memcpy(self.buf[start..head.HEADER_BUF_SIZE], hdr);

    self.off = start;
    self.len = head.HEADER_BUF_SIZE + body_len;
}

/// Grow buf to hold at least need bytes when backed by a growable allocator.
/// Returns false when growth is unavailable (no allocator) or would exceed
/// grow_cap, so the caller falls back to a direct flush. Never shrinks, so a
/// grown per-connection buffer is reused by later requests on that fd.
fn grow(self: *Self, need: usize) bool {
    const gpa = self.grow_allocator orelse return false;
    if (need <= self.buf.len) return true;
    if (need > self.grow_cap) return false;

    var new_len = @max(self.buf.len, 1) * 2;
    while (new_len < need) new_len *= 2;
    if (new_len > self.grow_cap) new_len = self.grow_cap;

    if (!self.buf_owned) {
        const grown = gpa.alloc(u8, new_len) catch |err| switch (err) {
            error.OutOfMemory => return false,
        };
        @memcpy(grown[0..self.len], self.buf[0..self.len]);
        self.buf = grown;
        self.buf_owned = true;

        return true;
    }

    const grown = gpa.realloc(self.buf, new_len) catch |err| switch (err) {
        error.OutOfMemory => return false,
    };
    self.buf = grown;

    return true;
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const pair = @import("../../utils/socket/pair.zig");

test "zix http1: RespSink, flushes appended bytes" {
    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    var buf: [64]u8 = undefined;
    var sink = Self{ .fd = fds[0], .buf = &buf };

    sink.append("abc");
    sink.append("def");
    try std.testing.expectEqual(@as(usize, 6), sink.len);

    sink.flush();
    try std.testing.expectEqual(@as(usize, 0), sink.len);

    var out: [64]u8 = undefined;
    const n = try std.posix.read(fds[1], &out);

    try std.testing.expectEqualStrings("abcdef", out[0..n]);
}

test "zix http1: RespSink, flushes before an oversized append" {
    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    var buf: [4]u8 = undefined;
    var sink = Self{ .fd = fds[0], .buf = &buf };

    sink.append("ab");
    sink.append("01234567");

    var out: [64]u8 = undefined;
    const n = try std.posix.read(fds[1], &out);

    try std.testing.expectEqualStrings("ab01234567", out[0..n]);
}

test "zix http1: RespSink, commits a reserved body" {
    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    head.setDateHeader(false);
    defer head.setDateHeader(true);

    var buf: [1024]u8 = undefined;
    var sink = Self{ .fd = fds[0], .buf = &buf };

    const body = sink.reserve(5).?;
    @memcpy(body[0..2], "hi");
    try sink.commitSimple(std.testing.io, .OK, "text/plain", 2);
    sink.flush();

    var out: [256]u8 = undefined;
    const n = try std.posix.read(fds[1], &out);

    try std.testing.expectEqualStrings(
        "HTTP/1.1 200 Ok\r\nContent-Type: text/plain\r\nContent-Length: 2\r\n\r\nhi",
        out[0..n],
    );
}

test "zix http1: RespSink, materializes a direct replay without a cache" {
    var buf: [8]u8 = undefined;
    var sink = Self{ .fd = -1, .buf = &buf };

    sink.direct = "xyz";
    sink.materializeDirect();

    try std.testing.expectEqual(@as(usize, 0), sink.direct.len);
    try std.testing.expectEqualStrings("xyz", sink.buf[0..sink.len]);
}

