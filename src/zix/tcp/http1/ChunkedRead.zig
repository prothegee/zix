//! ZIX Http1 ChunkedRead
//!
//! ### file: src/zix/tcp/http1/ChunkedRead.zig
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

const ChunkedStop = @import("chunk.zig").ChunkedStop;

// --------------------------------------------------------- //
// Fields:

len: usize = 0,
received: u64 = 0,
leftover_off: usize = 0,
leftover: usize = 0,
stop: ChunkedStop,

