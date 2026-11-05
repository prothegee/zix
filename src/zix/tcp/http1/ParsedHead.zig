//! ZIX Http1 parsed head
//!
//! ### file: src/zix/tcp/http1/ParsedHead.zig
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

const HeaderSpan = @import("HeaderSpan.zig");

// --------------------------------------------------------- //
// Fields:

path: []const u8,
query: []const u8,
method: []const u8,
keep_alive: bool,
raw_headers: []const u8,
version_minor: u8,
content_length: u64,
chunked_request: bool,
expect_continue: bool,
accept_encoding: HeaderSpan = .{},

