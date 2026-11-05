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

/// Fold a captured zero-copy replay back into the staged batch: a later
/// response in the same batch means the send must carry both in order, so
/// the borrowed bytes are copied after all and the pin drops. The copy
/// happens before unpin could matter: this worker owns the cache, so
/// nothing can overwrite the region between the unpin and the memcpy.
pub fn materializeDirect(self: *Self) void {
    if (self.direct.len == 0) return;

    const bytes = self.direct;
    self.direct = &.{};
    if (core.tl_cache) |c| c.unpin(self.direct_slot);

    self.append(bytes);
}

/// Send bytes that are not staying in buf: through the spill sink when one is installed (https,
/// where the fd is a sentinel and every write has to become a TLS record), straight to the
/// descriptor otherwise. A write that does not land marks the sink failed, which the caller
/// reads as a broken peer.
fn writeOut(self: *Self, bytes: []const u8) void {
    std.log.info("TODO: self.spill as sink and write", .{});
    // if write the bytes failed, set failed to true

    core.writeAllDirectFD(self.fd, bytes) catch {
        self.failed = true;
    };
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
    if (core.HEADER_BUF_SIZE + max_body > self.buf.len) {
        if (!self.grow(core.HEADER_BUF_SIZE + max_body)) return null;
    }

    return self.buf[core.HEADER_BUF_SIZE..][0..max_body];
}

/// Commit a reserved render: build the simple header right-aligned so it
/// ends exactly where the body starts, and stage header + body as one
/// contiguous region (off marks the dead prefix before the header).
pub fn commitSimple(self: *Self, status: u16, content_type: []const u8, body_len: usize) void {
    std.debug.assert(self.len == 0 and self.direct.len == 0);

    var hdr_buf: [core.HEADER_BUF_SIZE]u8 = undefined;
    const hdr = core.buildSimpleHeader(&hdr_buf, status, content_type, body_len);
    const start = core.HEADER_BUF_SIZE - hdr.len;
    @memcpy(self.buf[start..core.HEADER_BUF_SIZE], hdr);

    self.off = start;
    self.len = core.HEADER_BUF_SIZE + body_len;
}

