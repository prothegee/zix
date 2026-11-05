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

// --------------------------------------------------------- //
// Public:

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

