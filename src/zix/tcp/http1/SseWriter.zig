//! ZIX Http1 SSE writer
//!
//! ### file: src/zix/tcp/http1/SseWriter.zig
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

// --------------------------------------------------------- //
// Fields:

fd: std.posix.fd_t,

const Self = @This();

// --------------------------------------------------------- //
// Public:

/// Sends: data: <data>\n\n
pub fn writeEvent(self: Self, data: []const u8) !void {
    try core.writeAllFD(self.fd, "data: ");
    try core.writeAllFD(self.fd, data);
    try core.writeAllFD(self.fd, "\n\n");
}

/// Sends: event: <event>\ndata: <data>\n\n
pub fn writeNamedEvent(self: Self, event: []const u8, data: []const u8) !void {
    try core.writeAllFD(self.fd, "event: ");
    try core.writeAllFD(self.fd, event);
    try core.writeAllFD(self.fd, "\ndata: ");
    try core.writeAllFD(self.fd, data);
    try core.writeAllFD(self.fd, "\n\n");
}

/// Sends: : <text>\n  (comment / keepalive heartbeat)
pub fn comment(self: Self, text: []const u8) !void {
    try core.writeAllFD(self.fd, ": ");
    try core.writeAllFD(self.fd, text);
    try core.writeAllFD(self.fd, "\n");
}

