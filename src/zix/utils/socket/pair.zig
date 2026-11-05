//! ZIX utils socket pair
//!
//! ### file: src/zix/utils/socket/pair.zig
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

pub const Error = error {
    ZixUtils_SocketPair_Failed,
};

/// Open two connected stream descriptors.
///
/// Note:
/// - Anything written to one end is readable from the other, in both directions.
///
/// Param:
/// io - std.Io (only used by the Windows loopback path, ignored elsewhere)
/// fds - *[2]posix.fd_t (filled with the two connected ends)
///
/// Return:
/// - void on success
/// - error.ZixUtils_SocketPair_Failed when the pair could not be established
pub fn open(io: std.Io, fds: *[2]std.posix.fd_t) Error!void {
    _ = io;
    const rc = std.posix.system.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, fds);

    if (std.posix.errno(rc) != .SUCCESS) return Error.ZixUtils_SocketPair_Failed;
}

