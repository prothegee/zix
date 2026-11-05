//! ZIX Http1 chunk
//!
//! ### file: src/zix/tcp/http1/chunk.zig
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

// --------------------------------------------------------- //
// Public:

/// Why a chunked body read or decode stopped.
pub const ChunkedStop = enum {
    /// The terminal chunk arrived, the body is whole.
    COMPLETE,
    /// The bytes in hand end mid-body. Read more and try again.
    NEED_MORE,
    /// The body does not fit the buffer the engine can hand a handler.
    TOO_LARGE,
    /// A chunk size line is not valid hex.
    MALFORMED,
};

