//! ZIX http2 grpc tls mux connection
//!
//! ### file: src/zix/tcp/http2/grpc/tls_mux/TlsConn.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! One gRPC over TLS connection on a multiplexed worker: the TLS transport, the
//! gRPC mux once the handshake is done, and the plaintext the mux wrote this pass.
//!
//! ### note:
//!
//! One worker owns a connection for its whole lifetime (shared-nothing). The
//! mux exists only after the handshake selected ALPN h2.
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
const tlz = @import("tlz");
const tls_conn = @import("../../../../multiplexers/tls_conn.zig");
const MuxConn = @import("../mux/MuxConn.zig");
const ServeOpts = @import("../ServeOpts.zig");

// --------------------------------------------------------- //
// Fields:

/// Session plus staged outbound ciphertext.
transport: tls_conn.Transport,
/// The gRPC mux, set once the handshake is established with ALPN h2.
mux: ?*MuxConn = null,
/// Stream, frame, and body limits handed to the mux.
opts: ServeOpts,
/// Worker io, carried onto every call Context.
io: std.Io,
/// Plaintext frames the mux wrote this pass, sealed in record-sized chunks.
plain: [tlz.MAX_PLAINTEXT]u8 = undefined,
/// Live bytes in plain.
plain_len: usize = 0,

const Self = @This();

// --------------------------------------------------------- //
// Private:

const allocator = std.heap.smp_allocator;

// --------------------------------------------------------- //
// Public:

/// Allocate a connection for an accepted, non-blocking socket.
///
/// Param:
/// io - std.Io (worker io, also the CSPRNG for the session)
/// fd - std.posix.fd_t (the accepted socket)
/// ctx - *const tlz.Context (borrowed identity, must outlive the connection)
/// opts - ServeOpts (mux limits and the first write buffer size)
///
/// Return:
/// - *Self
/// - null when out of memory
pub fn create(
    io: std.Io,
    fd: std.posix.fd_t,
    ctx: *const tlz.Context,
    opts: ServeOpts,
) ?*Self {
    const conn = allocator.create(Self) catch |err| switch (err) {
        error.OutOfMemory => return null,
    };

    conn.* = .{
        .transport = tls_conn.Transport.init(io, fd, ctx),
        .opts = opts,
        .io = io,
    };
    conn.transport.wbuf_initial = opts.tls_write_buf_initial;

    return conn;
}

/// Free the mux, the staged ciphertext, and the connection. Does not close fd.
pub fn destroy(self: *Self) void {
    if (self.mux) |mux| mux.deinit();
    self.transport.deinit();
    allocator.destroy(self);
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

fn testContext() tlz.Context {
    var ctx: tlz.Context = undefined;
    ctx.cert_der = &.{};
    ctx.signing_key = .{ .rsa = .{} };
    ctx.alpn = &.{};

    return ctx;
}

test "zix http2 grpc: TlsConn, create starts without a mux" {
    const ctx = testContext();

    const conn = create(std.testing.io, 7, &ctx, .{}) orelse {
        return error.ZixTest_OutOfMemory;
    };
    defer conn.destroy();

    try std.testing.expectEqual(@as(std.posix.fd_t, 7), conn.transport.fd);
    try std.testing.expect(conn.mux == null);
    try std.testing.expectEqual(@as(usize, 0), conn.plain_len);
}

test "zix http2 grpc: TlsConn, create takes the write buffer size from opts" {
    const ctx = testContext();

    const conn = create(std.testing.io, 7, &ctx, .{
        .tls_write_buf_initial = 4096,
    }) orelse {
        return error.ZixTest_OutOfMemory;
    };
    defer conn.destroy();

    try std.testing.expectEqual(@as(usize, 4096), conn.transport.wbuf_initial);
}

test "zix http2 grpc: TlsConn, plain holds one full TLS record" {
    const plain_size = @sizeOf(@FieldType(Self, "plain"));

    try std.testing.expectEqual(tlz.MAX_PLAINTEXT, plain_size);
}

