//! TLZ extensions EncryptedExtensionsOptions
//!
//! ### file: src/tlz/src/extensions/EncryptedExtensionsOptions.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! What the server puts in EncryptedExtensions (RFC 8446 section 4.3.1). Each field
//! is emitted only when set.
//!
//! ### note:
//!
//! Only extensions the client offered may be set (RFC 8446 4.3.1 MUST NOT).
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
const Alpn = @import("../alpn.zig").Alpn;

// --------------------------------------------------------- //
// Fields:

/// The raw NamedGroupList body to echo in supported_groups.
groups_list: ?[]const u8 = null,
/// The record_size_limit value (RFC 8449).
record_size_limit: ?u16 = null,
/// The ALPN protocol the server selected.
alpn_selected: ?Alpn = null,
/// Send the empty server_name acknowledgement (RFC 6066 3).
server_name_ack: bool = false,

const Self = @This();

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "tlz extensions: EncryptedExtensionsOptions, default emits nothing" {
    const opts: Self = .{};

    try std.testing.expect(opts.groups_list == null);
    try std.testing.expect(opts.record_size_limit == null);
    try std.testing.expect(opts.alpn_selected == null);
    try std.testing.expect(!opts.server_name_ack);
}

test "tlz extensions: EncryptedExtensionsOptions, keeps the selected ALPN" {
    const opts: Self = .{
        .alpn_selected = .H2,
    };

    try std.testing.expectEqual(Alpn.H2, opts.alpn_selected.?);
}

