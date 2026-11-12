//! TLZ dtls connection Flight
//!
//! ### file: src/tlz/src/dtls/connection/Flight.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! The DTLS server flight (RFC 6347 4.2.4 flight 4): the records to send and the
//! state the finish needs.
//!
//! ### note:
//!
//! `to_send` is one or more records back to back. The caller packs them into
//! datagrams, splitting only on record boundaries.
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
const State = @import("State.zig");

// --------------------------------------------------------- //
// Fields:

to_send: []const u8,
state: State,

const Self = @This();

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "tlz dtls connection: Flight, holds the records next to the state" {
    const flight: Self = .{
        .to_send = "records",
        .state = .{
            .client_random = @splat(0x11),
            .server_random = @splat(0x33),
            .server_eph_scalar = @splat(0x22),
            .transcript = std.crypto.hash.sha2.Sha256.init(.{}),
            .next_record_seq = 4,
        },
    };

    try std.testing.expectEqualStrings("records", flight.to_send);
    try std.testing.expectEqual(@as(u48, 4), flight.state.next_record_seq);
}

