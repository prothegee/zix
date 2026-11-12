//! TLZ dtls connection FinishResult
//!
//! ### file: src/tlz/src/dtls/connection/FinishResult.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! What the DTLS server finish produces (RFC 6347 4.2.4 flight 6): the records to
//! send, the established `Connection`, and the SRTP keys when media was agreed.
//!
//! ### note:
//!
//! The SRTP keys are exported here because this is the only point where the master
//! secret exists (RFC 5764 4.2). They are not kept on `Connection`: a caller that
//! wants media takes them once. The keys and their profile travel together, a key
//! with the wrong profile picks the wrong tag length.
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
const Connection = @import("Connection.zig");
const SrtpKeys = @import("../exporter/SrtpKeys.zig");
const SrtpProfile = @import("../exporter/srtp_profile.zig").SrtpProfile;

// --------------------------------------------------------- //
// Fields:

/// ChangeCipherSpec and the protected server Finished, back to back.
to_send: []const u8,
connection: Connection,
/// The SRTP master keys and salts, or null when no profile was agreed.
srtp_keys: ?SrtpKeys = null,
/// The profile those keys belong to.
srtp_profile: ?SrtpProfile = null,

const Self = @This();

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "tlz dtls connection: FinishResult, defaults carry no media" {
    const result: Self = .{
        .to_send = "",
        .connection = .{
            .km = .{
                .client_write_key = @splat(0x11),
                .server_write_key = @splat(0x22),
                .client_write_iv = @splat(0x33),
                .server_write_iv = @splat(0x44),
            },
        },
    };

    try std.testing.expectEqual(@as(?SrtpKeys, null), result.srtp_keys);
    try std.testing.expectEqual(@as(?SrtpProfile, null), result.srtp_profile);
}

