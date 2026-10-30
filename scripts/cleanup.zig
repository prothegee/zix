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
//! - (c) Prana Ron // @prothegee // prothegee@protonmail.com
//! 
//! ### contributors:
//! 
//! - Prana Ron // @prothegee // prothegee@protonmail.com
//!

const std = @import("std");

// --------------------------------------------------------- //

const REQUIRED_DIRS = [_][]const u8 {
    "./.zig-cache",
    //
    "./zig-out",
};

// --------------------------------------------------------- //

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    inline for (REQUIRED_DIRS) |dir| {
        std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    }
}

