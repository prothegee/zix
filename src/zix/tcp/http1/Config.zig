//! ZIX Http1 Config
//!
//! ### file: src/zix/tcp/http1/Config.zig
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
const DispatchModel = @import("../../shared/dispatch.zig").Model;

// --------------------------------------------------------- //
// Fields:

io: std.Io,
ip: []const u8,
port: u16,
// tls: ?Tls = null,
// tls_port: u16,
// tls_redirect: bool = false,
// logger: ?*Logger = null,
dispatch_model: DispatchModel,
workers: usize = 0,
worker_stack_size_bytes: usize = 1 * 1024,
// worker_stack_compress_bytes: usize = 2 * 1024 * 1024,
compress_worker_stack_size_bytes: usize = 2 * 1024 * 1024,
kernel_backlog: u31 = 1 * 1024,

// --------------------------------------------------------- //

