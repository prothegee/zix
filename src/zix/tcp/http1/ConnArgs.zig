//! ZIX Http1 ConnArgs
//!
//! ### file: src/zix/tcp/http1/ConnArgs.zig
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
const core = @import("core.zig");
const HandlerFn = @import("core.zig").HandlerFn;
const ConnRegistry = @import("ConnRegistry.zig");

// --------------------------------------------------------- //
// Fields:

io: std.Io,
stream: std.Io.net.Stream,
handler: HandlerFn,
handler_timeout_ms: u32 = 0,
conn_timeout_ms: u32 = 0,
registry: ?*ConnRegistry = null,
send_date_header: bool = true,
large_body_recv_buf: usize = 0,
max_recv_buf: usize = core.BUF_SIZE,
max_request_body: usize = 0,
max_response_headers: usize = 16, // TODO: check max header config
public_dir: []const u8 = "",
// logger: ?*Logger = null, // TODO: ConnArgs logger
compress: bool = false,
compression_min_size: usize = 256,
compression_max_out: usize = 256 * 1024,
cache_response: bool = false,
cache_ttl_ms: u32 = 0,
cache_max_entries: u32 = 256,
cache_max_value_bytes: u32 = 16 * 1024,
cache_max_total_bytes: usize = 0,

const Self = @This();

