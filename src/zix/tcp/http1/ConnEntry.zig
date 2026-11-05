//! ZIX Http1 ConnEntry
//!
//! ### file: src/zix/tcp/http1/ConnEntry.zig
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
// Fields:

fd: std.posix.fd_t,
done: std.atomic.Value(bool) = .init(false),
deadline: std.Io.Clock.Timestamp,

const Self = @This();

