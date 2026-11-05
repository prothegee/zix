//! ZIX Http1 ServeOpts
//!
//! ### file: src/zix/tcp/http1/ServeOpts.zig
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

const core = @import("core.zig");

// --------------------------------------------------------- //
// Fields:

nodelay: bool = true,
handler_timeout_ms: u32 = 0,
large_body_recv_buf: usize = 0,
max_recv_buf: usize = core.BUF_SIZE,
max_request_body: usize = 0,

