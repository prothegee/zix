//! TLZ connection RetryState
//!
//! ### file: src/tlz/src/connection/RetryState.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! The state carried between a HelloRetryRequest and the client's second
//! ClientHello (RFC 8446 section 4.1.4).
//!
//! ### note:
//!
//! The transcript already holds the synthetic message_hash(ClientHello1) and the
//! HelloRetryRequest (RFC 8446 4.4.1).
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
const HandshakeOptions = @import("HandshakeOptions.zig");
const Transcript = @import("../key_schedule/Transcript.zig");
const NamedGroup = @import("../named_group.zig").NamedGroup;

// --------------------------------------------------------- //
// Fields:

/// The options of the first round, reused for the second.
opts: HandshakeOptions,
/// The running transcript through the HelloRetryRequest.
transcript: Transcript,
/// The group the client must send a key share for.
group: NamedGroup,

const Self = @This();

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "tlz connection: RetryState, keeps the requested group" {
    const state: Self = .{
        .opts = .{
            .certificate_der = &.{},
            .signing_key = .{ .rsa = .{} },
            .ephemeral_secret = @splat(0),
            .server_random = @splat(0),
        },
        .transcript = .init(),
        .group = .SECP256R1,
    };

    try std.testing.expectEqual(NamedGroup.SECP256R1, state.group);
}

test "tlz connection: RetryState, copies keep an independent transcript" {
    var state: Self = .{
        .opts = .{
            .certificate_der = &.{},
            .signing_key = .{ .rsa = .{} },
            .ephemeral_secret = @splat(0),
            .server_random = @splat(0),
        },
        .transcript = .init(),
        .group = .X25519,
    };
    const before = state.transcript.current();

    var copy = state;
    copy.transcript.update("client hello 2");

    try std.testing.expectEqualSlices(u8, &before, &state.transcript.current());
}

