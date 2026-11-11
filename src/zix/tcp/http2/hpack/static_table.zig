//! ZIX Http2 hpack static_table
//!
//! ### file: src/zix/tcp/http2/hpack/static_table.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! The HPACK static table (RFC 7541 appendix A): 61 fixed header fields.
//!
//! ### note:
//!
//! Index 0 is unused, so HPACK_STATIC[i] matches the RFC index i.
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
const Header = @import("Header.zig");

// --------------------------------------------------------- //
// Private:

const NAMES = [62][]const u8{
    "", // 0 (unused)
    ":authority", // 1
    ":method", // 2
    ":method", // 3
    ":path", // 4
    ":path", // 5
    ":scheme", // 6
    ":scheme", // 7
    ":status", // 8
    ":status", // 9
    ":status", // 10
    ":status", // 11
    ":status", // 12
    ":status", // 13
    ":status", // 14
    "accept-charset", // 15
    "accept-encoding", // 16
    "accept-language", // 17
    "accept-ranges", // 18
    "accept", // 19
    "access-control-allow-origin", // 20
    "age", // 21
    "allow", // 22
    "authorization", // 23
    "cache-control", // 24
    "content-disposition", // 25
    "content-encoding", // 26
    "content-language", // 27
    "content-length", // 28
    "content-location", // 29
    "content-range", // 30
    "content-type", // 31
    "cookie", // 32
    "date", // 33
    "etag", // 34
    "expect", // 35
    "expires", // 36
    "from", // 37
    "host", // 38
    "if-match", // 39
    "if-modified-since", // 40
    "if-none-match", // 41
    "if-range", // 42
    "if-unmodified-since", // 43
    "last-modified", // 44
    "link", // 45
    "location", // 46
    "max-forwards", // 47
    "proxy-authenticate", // 48
    "proxy-authorization", // 49
    "range", // 50
    "referer", // 51
    "refresh", // 52
    "retry-after", // 53
    "server", // 54
    "set-cookie", // 55
    "strict-transport-security", // 56
    "transfer-encoding", // 57
    "user-agent", // 58
    "vary", // 59
    "via", // 60
    "www-authenticate", // 61
};

/// Values for the entries that have one. Every other index has an empty value.
const VALUES = blk: {
    var values: [62][]const u8 = @splat("");
    values[2] = "GET";
    values[3] = "POST";
    values[4] = "/";
    values[5] = "/index.html";
    values[6] = "http";
    values[7] = "https";
    values[8] = "200";
    values[9] = "204";
    values[10] = "206";
    values[11] = "304";
    values[12] = "400";
    values[13] = "404";
    values[14] = "500";
    values[16] = "gzip, deflate";

    break :blk values;
};

// --------------------------------------------------------- //
// Public:

/// Highest valid static table index.
pub const STATIC_LEN: usize = 61;

/// The static table, indexed by RFC index (0 is unused).
pub const HPACK_STATIC: [62]Header = blk: {
    var table: [62]Header = undefined;
    for (&table, NAMES, VALUES) |*entry, name, value| {
        entry.* = .{
            .name = name,
            .value = value,
        };
    }

    break :blk table;
};

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "zix http2 hpack: static_table, index 2 is :method GET" {
    try std.testing.expectEqualStrings(":method", HPACK_STATIC[2].name);
    try std.testing.expectEqualStrings("GET", HPACK_STATIC[2].value);
}

test "zix http2 hpack: static_table, index 8 is :status 200" {
    try std.testing.expectEqualStrings(":status", HPACK_STATIC[8].name);
    try std.testing.expectEqualStrings("200", HPACK_STATIC[8].value);
}

test "zix http2 hpack: static_table, index 16 is accept-encoding gzip, deflate" {
    try std.testing.expectEqualStrings("accept-encoding", HPACK_STATIC[16].name);
    try std.testing.expectEqualStrings("gzip, deflate", HPACK_STATIC[16].value);
}

test "zix http2 hpack: static_table, last index is www-authenticate" {
    try std.testing.expectEqualStrings("www-authenticate", HPACK_STATIC[STATIC_LEN].name);
    try std.testing.expectEqualStrings("", HPACK_STATIC[STATIC_LEN].value);
}

test "zix http2 hpack: static_table, index 0 is empty" {
    try std.testing.expectEqualStrings("", HPACK_STATIC[0].name);
}

test "zix http2 hpack: static_table, every name is lowercase" {
    for (HPACK_STATIC[1..]) |entry| {
        for (entry.name) |char| {
            try std.testing.expect(!std.ascii.isUpper(char));
        }
    }
}

