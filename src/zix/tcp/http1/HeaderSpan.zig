//! ZIX Http1 HeaderSpan
//!
//! ### file: src/zix/tcp/http1/HeaderSpan.zig
//! 
//! ### author: Prana Ron
//! 
//! ---------------------------------------------------------
//! 
//! ### brief:
//! 
//! Byte range of a captured header value inside raw_headers,
//! so a hot header read is O(1) instead of a per-request rescan of the header block.
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
// Fields:

off: u32 = SPAN_UNSCANNED,
len: u32 = 0,

// --------------------------------------------------------- //
// Public:

/// HeaderSpan offset marking a span the producing parse pass never scanned
/// for: readers fall back to a getHeader scan.
pub const SPAN_UNSCANNED: u32 = std.math.maxInt(u32);

/// HeaderSpan offset marking a header the parse pass scanned for and did not
/// find (a definitive absence, no fallback scan needed).
pub const SPAN_ABSENT: u32 = std.math.maxInt(u32) - 1;

