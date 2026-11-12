//! ZIX cleanup artifacts run
//!
//! ### file: scripts/cleanup.zig
//! 
//! ### author: Prana Ron
//! 
//! ---------------------------------------------------------
//! 
//! ### brief:
//! 
//! Deletes the build artifact directories.
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

const REQUIRED_DIRS = [_][]const u8 {
    "./.zig-cache",
    "./src/tlz/.zig-cache",
    "./src/jzon/.zig-cache",
    //
    "./zig-out",
    "./src/tlz/zig-out",
    "./src/jzon/zig-out",
};

// --------------------------------------------------------- //

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    inline for (REQUIRED_DIRS) |dir| {
        std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    }
}

