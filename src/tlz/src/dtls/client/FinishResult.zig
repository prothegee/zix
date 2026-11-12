//! TLZ dtls client FinishResult
//!
//! ### file: src/tlz/src/dtls/client/FinishResult.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! What the DTLS client finish produces (RFC 6347 4.2.4 flight 5): the records to
//! send, the server verify_data to expect back, and the established connection.
//!
//! ### note:
//!
//! The handshake is sound only once the server Finished carries exactly
//! `server_verify_data`.
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
const client = @import("../client.zig");
const ClientConnection = @import("ClientConnection.zig");

// --------------------------------------------------------- //
// Fields:

/// ClientKeyExchange, ChangeCipherSpec, and the protected client Finished, back to
/// back. The caller packs them into datagrams on record boundaries.
to_send: []const u8,
/// What the server Finished has to carry for this handshake to be sound.
server_verify_data: [client.VERIFY_DATA_LEN]u8,
connection: ClientConnection,

const Self = @This();

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "tlz dtls client: FinishResult, carries the expected server verify_data" {
    const result: Self = .{
        .to_send = "",
        .server_verify_data = @splat(0x5A),
        .connection = .{
            .km = .{
                .client_write_key = @splat(0x11),
                .server_write_key = @splat(0x22),
                .client_write_iv = @splat(0x33),
                .server_write_iv = @splat(0x44),
            },
        },
    };

    try std.testing.expectEqual(@as(usize, 12), result.server_verify_data.len);
    try std.testing.expectEqual(@as(u48, 1), result.connection.client_seq);
}

