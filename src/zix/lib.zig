//! ZIX
//! Zero sIX; 06;
//! A network backend library written in zig.
//!
//! ### file: src/zix/lib.zig
//! 
//! ### author: Prana Ron
//! 
//! ---------------------------------------------------------
//! 
//! ### brief:
//! 
//! ZIX library entry: the version truth and the public module exports.
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
const builtin = @import("builtin");

// --------------------------------------------------------- //
// Private:

fn getVersionString() []const u8 {
    return std.fmt.comptimePrint("{d}.{d}.{d}{s}", .{
        VERSION.MAJOR,
        VERSION.MINOR,
        VERSION.PATCH,
        if (VERSION.RELEASE_CANDIDATE) |rc|
            std.fmt.comptimePrint("-rc{d}", .{rc})
        else
            "",
    });
}

// --------------------------------------------------------- //
// Public:

/// THE ONLY SOURCE OF TRUTH for Zig SEMVER for zix source code.
///
/// Note:
/// - Do not create in other place
pub const ZIG_SEMVER = struct {
    pub const MAJOR: usize = builtin.zig_version.major;
    pub const MINOR: usize = builtin.zig_version.minor;
    pub const PATCH: usize = builtin.zig_version.patch;
};

/// THE ONLY SOURCE OF TRUTH for ZIX SEMVER.
///
/// Note:
/// - Do not create in other place
pub const VERSION = struct {
    pub const MAJOR
        = @import("zix_options").zix_version_info.major;
    pub const MINOR
        = @import("zix_options").zix_version_info.minor;
    pub const PATCH
        = @import("zix_options").zix_version_info.patch;
    pub const RELEASE_CANDIDATE: ?usize
        = @import("zix_options").zix_version_info.release_candidate;
};

/// THE ONLY SOURCE OF TRUTH for ZIX string version.
///
/// Note:
/// - Do not create in other place
pub const VERSION_STRING = getVersionString();

// --------------------------------------------------------- //

// ZIX Http1
pub const Http1 = @import("tcp/http1/Http1.zig");

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test {
    _ = @import("multiplexers/slab.zig");
    _ = @import("shared/dispatch.zig");
    _ = @import("tcp/http1/BodyInfo.zig");
    _ = @import("tcp/http1/ChunkedFrame.zig");
    _ = @import("tcp/http1/ChunkedRead.zig");
    _ = @import("tcp/http1/Config.zig");
    _ = @import("tcp/http1/ConnArgs.zig");
    _ = @import("tcp/http1/ConnEntry.zig");
    _ = @import("tcp/http1/ConnRegistry.zig");
    _ = @import("tcp/http1/Context.zig");
    _ = @import("tcp/http1/HeaderSpan.zig");
    _ = @import("tcp/http1/Http1.zig");
    _ = @import("tcp/http1/HttpHeader.zig");
    _ = @import("tcp/http1/ParseResult.zig");
    _ = @import("tcp/http1/ParsedHead.zig");
    _ = @import("tcp/http1/PathParam.zig");
    _ = @import("tcp/http1/Request.zig");
    _ = @import("tcp/http1/RespSink.zig");
    _ = @import("tcp/http1/Response.zig");
    _ = @import("tcp/http1/ServeOpts.zig");
    _ = @import("tcp/http1/Server.zig");
    _ = @import("tcp/http1/SseWriter.zig");
    _ = @import("tcp/http1/cache.zig");
    _ = @import("tcp/http1/chunk.zig");
    _ = @import("tcp/http1/compress.zig");
    _ = @import("tcp/http1/connection.zig");
    _ = @import("tcp/http1/date.zig");
    _ = @import("tcp/http1/dispatch/async.zig");
    _ = @import("tcp/http1/dispatch/common.zig");
    _ = @import("tcp/http1/handler.zig");
    _ = @import("tcp/http1/head.zig");
    _ = @import("tcp/http1/header.zig");
    _ = @import("tcp/http1/parser.zig");
    _ = @import("tcp/http1/reader.zig");
    _ = @import("tcp/http1/router.zig");
    _ = @import("tcp/http1/serve.zig");
    _ = @import("tcp/http1/writer.zig");
    _ = @import("utils/ResponseCache.zig");
    _ = @import("utils/compression/compression.zig");
    _ = @import("utils/date_and_time.zig");
    _ = @import("utils/http/content.zig");
    _ = @import("utils/http/encoding.zig");
    _ = @import("utils/http/method.zig");
    _ = @import("utils/http/status.zig");
    _ = @import("utils/media_type.zig");
    _ = @import("utils/peer_address.zig");
    _ = @import("utils/socket/pair.zig");
}

test "zix: version, semver fields follow the compiler" {
    try std.testing.expectEqual(builtin.zig_version.major, ZIG_SEMVER.MAJOR);
    try std.testing.expectEqual(builtin.zig_version.minor, ZIG_SEMVER.MINOR);
    try std.testing.expectEqual(builtin.zig_version.patch, ZIG_SEMVER.PATCH);
}

test "zix: version, string is not empty" {
    try std.testing.expect(VERSION_STRING.len > 0);
}

