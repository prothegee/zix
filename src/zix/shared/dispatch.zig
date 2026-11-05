//! ZIX share dispatch
//!
//! ### file: src/zix/shared/dispatch_model.zig
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
//! - (c) Prana Ron // @prothegee // prothegeee@pm.me
//! 
//! ### contributors:
//! 
//! - Prana Ron // @prothegee // prothegeee@pm.me
//!

// --------------------------------------------------------- //
// Public:

/// Shared dispatch model
pub const Model = enum(u8) {
    ASYNC = 0,
    EPOLL = 1,
    URING = 2,
    IOCP = 3,
    KQUEUE = 4,
};

