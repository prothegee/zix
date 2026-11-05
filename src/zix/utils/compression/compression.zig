//! ZIX utils compression
//!
//! ### file: src/zix/utils/compression/compression.zig
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
const Encoding = @import("../http/encoding.zig").Encoding;

// --------------------------------------------------------- //
// Private:

/// The qualities a coding token carries in the header: its explicit entry and the
/// wildcard entry, each in milli units (0 to 1000), or null when not present.
const Scan = struct {
    explicit: ?u16 = null,
    wildcard: ?u16 = null,
};

/// Scan the header for a coding token, capturing both an explicit entry and a wildcard.
///
/// Param:
/// header - []const u8 (trimmed Accept-Encoding value)
/// token - []const u8 (coding name to score, matched case-insensitively)
///
/// Return:
/// - Scan (explicit and wildcard qualities, each null when absent)
fn scan(header: []const u8, token: []const u8) Scan {
    var result: Scan = .{};

    var entry_iter = std.mem.splitScalar(u8, header, ',');
    while (entry_iter.next()) |raw_entry| {
        const entry = std.mem.trim(u8, raw_entry, " \t");
        if (entry.len == 0) continue;

        var field_iter = std.mem.splitScalar(u8, entry, ';');
        const name = std.mem.trim(u8, field_iter.next().?, " \t");

        var quality: u16 = 1000;
        while (field_iter.next()) |raw_param| {
            const param = std.mem.trim(u8, raw_param, " \t");

            if (param.len >= 2 and (param[0] == 'q' or param[0] == 'Q') and param[1] == '=') {
                quality = parseQuality(std.mem.trim(u8, param[2..], " \t"));
            }
        }

        if (std.mem.eql(u8, name, "*")) {
            result.wildcard = quality;
        } else if (std.ascii.eqlIgnoreCase(name, token)) {
            result.explicit = quality;
        }
    }

    return result;
}

/// Parse an HTTP quality value into milli units (0 to 1000).
///
/// Note:
/// - Grammar is ( "0" [ "." 0*3DIGIT ] ) / ( "1" [ "." 0*3("0") ] ). A malformed value
///   is treated leniently as 1000 (as if no q param was present), never as a silent 0
///   that would wrongly forbid a coding.
///
/// Param:
/// text - []const u8 (the value after q=)
///
/// Return:
/// - u16 (0 to 1000)
fn parseQuality(text: []const u8) u16 {
    if (text.len == 0) return 1000;

    if (text[0] == '1') return 1000;
    if (text[0] != '0') return 1000;

    if (text.len == 1) return 0;
    if (text[1] != '.') return 0;

    var fraction: u16 = 0;
    var scale: u16 = 100;
    var index: usize = 2;
    while (index < text.len and scale > 0) : (index += 1) {
        const digit = text[index];
        if (digit < '0' or digit > '9') break;

        fraction += @as(u16, digit - '0') * scale;
        scale /= 10;
    }

    return fraction;
}

// --------------------------------------------------------- //
// Public:

pub const MIN_SIZE_DEFAULT: usize = 256;

/// Pick the content coding to use for a response, honouring the client Accept-Encoding
/// preferences against the server-producible set.
///
/// Note:
/// - Policy is compression-leaning (the common server behaviour): the
///   best producible coding is chosen whenever it is acceptable (q greater than 0).
///   identity only wins when the client lists it EXPLICITLY with a strictly higher q.
///   An unlisted or wildcard-matched identity does not suppress compression.
/// - Among producible codings, the highest client q wins. At equal q, the earlier entry
///   in supported wins (server preference order).
/// - An absent header defaults to identity (conservative, only compress when the client
///   asks). An empty field value means the client wants identity only (RFC 9110).
///
/// Param:
/// accept_encoding - ?[]const u8 (the raw Accept-Encoding field value, or null if absent)
/// supported - []const Encoding (producible codings in server-preference order)
///
/// Return:
/// - Encoding (the chosen coding, possibly identity)
/// - null when nothing is acceptable (identity is forbidden via q=0 and no producible
///   coding is acceptable), which the caller answers with 406 Not Acceptable
pub fn negotiate(accept_encoding: ?[]const u8, supported: []const Encoding) ?Encoding {
    const header = accept_encoding orelse return .IDENTITY;

    const trimmed = std.mem.trim(u8, header, " \t");
    if (trimmed.len == 0) return .IDENTITY;

    const identity = scan(trimmed, "identity");
    const identity_available = identity.explicit orelse identity.wildcard orelse 1000;

    var best_encoding: ?Encoding = null;
    var best_quality: u16 = 0;
    for (supported) |encoding| {
        const match = scan(trimmed, encoding.token());
        const quality = match.explicit orelse match.wildcard orelse 0;

        if (quality > best_quality) {
            best_quality = quality;
            best_encoding = encoding;
        }
    }

    if (best_encoding) |encoding| {
        if (best_quality > 0) {
            if (identity.explicit) |identity_quality| {
                if (identity_quality > best_quality) return .IDENTITY;
            }

            return encoding;
        }
    }

    if (identity_available > 0) return .IDENTITY;

    return null;
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

// TODO: zix.utils.compression unit test

