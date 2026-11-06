//! ZIX Http1 header
//!
//! ### file: src/zix/tcp/http1/header.zig
//! 
//! ### author: Prana Ron
//! 
//! ---------------------------------------------------------
//! 
//! ### brief:
//! 
//! Response extra-header capacity for one worker.
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

// --------------------------------------------------------- //
// Public:

/// Response extra-header capacity (Response.addHeader) for this worker, from
/// config.max_response_headers. The backing buffer is allocated lazily per
/// request on the first addHeader call, so requests that add none pay nothing.
pub threadlocal var tl_max_response_headers: usize = 16;

/// Header size
/// Controls how many custom response headers addHeader() will accept per request.
///
/// max_response_headers in Http1ServerConfig sets the cap. The backing buffer is
/// arena-allocated lazily on the first addHeader() call, requests that add no
/// custom headers pay zero allocation cost.
/// Any addHeader() call beyond the cap yields error.ZixTooManyHeaders.
///
/// - SMALL (8): small controlled constrained environments
/// - MINIMAL (16): simple APIs, constrained environments
/// - COMMON (32): most web applications, single proxy/load balancer
/// - LARGE (64): behind load balancers, CDN + proxy
/// - EXTRA_LARGE (128): k8s, service mesh, many CORS/caching/forwarding headers
/// - CUSTOM (N): explicit non-standard cap
pub const Size = union(enum) {
    SMALL,
    MINIMAL,
    COMMON,
    LARGE,
    EXTRA_LARGE,
    CUSTOM: usize,

    pub fn value(self: Size) usize {
        return switch (self) {
            .SMALL => 8,
            .MINIMAL => 16,
            .COMMON => 32,
            .LARGE => 64,
            .EXTRA_LARGE => 128,
            .CUSTOM => |n| n,
        };
    }
};

/// Install the Response extra-header capacity for this worker thread. Called
/// once per worker at startup.
///
/// Param:
/// count - usize (maximum custom response headers per request)
pub fn setMaxResponseHeaders(count: usize) void {
    tl_max_response_headers = count;
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "zix http1: header, installs the capacity" {
    setMaxResponseHeaders(64);
    defer setMaxResponseHeaders(16);

    try std.testing.expectEqual(@as(usize, 64), tl_max_response_headers);
}

test "zix http1: header, capacity accepts zero" {
    defer setMaxResponseHeaders(16);

    setMaxResponseHeaders(0);

    try std.testing.expectEqual(@as(usize, 0), tl_max_response_headers);
}

