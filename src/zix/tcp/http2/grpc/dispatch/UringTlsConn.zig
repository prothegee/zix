//! ZIX http2 grpc uring tls connection
//!
//! ### file: src/zix/tcp/http2/grpc/dispatch/UringTlsConn.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! One ring-hosted gRPC over TLS connection (dual listener): the shared tls_mux
//! connection plus the ring generation tag and the ciphertext recv buffer.
//!
//! ### note:
//!
//! The recv buffer is per connection because a ring recv owns it until the
//! completion arrives.
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
const ServeOpts = @import("../ServeOpts.zig");
const TlsConn = @import("../tls_mux/TlsConn.zig");
const tls_conn = @import("../../../../multiplexers/tls_conn.zig");

// --------------------------------------------------------- //
// Fields:

/// The shared TLS connection logic (tls_mux).
conn: *TlsConn,
/// Matches completions to this connection, not to an earlier one on the same fd.
gen: u24,
/// Ciphertext recv target, owned.
cipher_buf: []u8,

const Self = @This();

// --------------------------------------------------------- //
// Private:

const allocator = std.heap.smp_allocator;

// --------------------------------------------------------- //
// Public:

/// Allocate a ring-hosted TLS connection for an accepted, non-blocking socket.
///
/// Return:
/// - *Self
/// - null when out of memory
pub fn create(
    io: std.Io,
    fd: std.posix.fd_t,
    ctx: *const tlz.Context,
    opts: ServeOpts,
    gen: u24,
) ?*Self {
    const self = allocator.create(Self) catch |err| switch (err) {
        error.OutOfMemory => return null,
    };
    const cipher_buf = allocator.alloc(u8, tls_conn.READ_STAGING_SIZE) catch |err| switch (err) {
        error.OutOfMemory => {
            allocator.destroy(self);

            return null;
        },
    };
    const conn = TlsConn.create(io, fd, ctx, opts) orelse {
        allocator.free(cipher_buf);
        allocator.destroy(self);

        return null;
    };

    self.* = .{
        .conn = conn,
        .gen = gen,
        .cipher_buf = cipher_buf,
    };

    return self;
}

/// Free the connection, its recv buffer, and itself. Does not close fd.
pub fn destroy(self: *Self) void {
    self.conn.destroy();
    allocator.free(self.cipher_buf);
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

test "zix http2 grpc: UringTlsConn, create owns a full staging recv buffer" {
    const ctx = testContext();

    const ring_conn = create(std.testing.io, 9, &ctx, .{}, 3) orelse {
        return error.ZixTest_OutOfMemory;
    };
    defer ring_conn.destroy();

    try std.testing.expectEqual(tls_conn.READ_STAGING_SIZE, ring_conn.cipher_buf.len);
    try std.testing.expectEqual(@as(u24, 3), ring_conn.gen);
    try std.testing.expectEqual(@as(std.posix.fd_t, 9), ring_conn.conn.transport.fd);
}

test "zix http2 grpc: UringTlsConn, gen tells two connections on one fd apart" {
    const ctx = testContext();

    const first = create(std.testing.io, 9, &ctx, .{}, 1) orelse {
        return error.ZixTest_OutOfMemory;
    };
    defer first.destroy();

    const second = create(std.testing.io, 9, &ctx, .{}, 2) orelse {
        return error.ZixTest_OutOfMemory;
    };
    defer second.destroy();

    try std.testing.expect(first.gen != second.gen);
}

