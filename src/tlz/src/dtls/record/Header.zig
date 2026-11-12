//! TLZ dtls record Header
//!
//! ### file: src/tlz/src/dtls/record/Header.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! One DTLS 1.2 record header (RFC 6347 4.1): type, version, epoch, 48-bit
//! sequence number, and fragment length.
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
const ContentType = @import("../../record/content_type.zig").ContentType;

// --------------------------------------------------------- //
// Fields:

content_type: ContentType,
version: u16,
/// Cipher state counter, incremented on every ChangeCipherSpec.
epoch: u16,
/// This record's number inside its epoch.
sequence_number: u48,
/// Length of the fragment that follows, header excluded.
length: u16,

const Self = @This();

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "tlz dtls record: Header, holds a 48-bit sequence number" {
    const header: Self = .{
        .content_type = .HANDSHAKE,
        .version = 0xFEFD,
        .epoch = 1,
        .sequence_number = 0xFFFFFFFFFFFF,
        .length = 0,
    };

    try std.testing.expectEqual(@as(u48, 0xFFFFFFFFFFFF), header.sequence_number);
}

