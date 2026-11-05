//! ZIX Http1 ChunkedFrame
//!
//! ### file: src/zix/tcp/http1/ChunkedFrame.zig
//! 
//! ### author: Prana Ron
//! 
//! ---------------------------------------------------------
//! 
//! ### brief:
//! 
//! What a walk of the chunk framing found.
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
consumed: usize = 0,
stop: ChunkedStop,

