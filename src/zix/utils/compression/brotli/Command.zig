//! ZIX utils compression brotli Command
//!
//! ### file: src/zix/utils/compression/brotli/Command.zig
//! 
//! ### author: Prana Ron
//! 
//! ---------------------------------------------------------
//! 
//! ### brief:
//! 
//! One encoder command: insert literals, then copy from a distance (RFC 7932 sec 5).
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

/// Number of literals to insert.
insert_len: u32,
/// Input offset of the first literal.
lit_off: usize,
/// Copy length. 0 marks a trailing insert-only command.
copy_len: u32,
/// Backward distance, or the dictionary reference distance.
distance: u32,
/// True when the copy is a static dictionary word.
is_dict: bool,

const Self = @This();

// --------------------------------------------------------- //
// Public:

/// An insert-only command for the literals at the end of the input.
///
/// Param:
/// lit_off - usize (input offset of the first literal)
/// insert_len - u32 (number of literals)
///
/// Return:
/// - Self
pub fn insertOnly(lit_off: usize, insert_len: u32) Self {
    return .{
        .insert_len = insert_len,
        .lit_off = lit_off,
        .copy_len = 0,
        .distance = 0,
        .is_dict = false,
    };
}

/// Whether the command carries a copy.
///
/// Return:
/// - bool
pub fn hasCopy(self: *const Self) bool {
    return self.copy_len > 0;
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "zix utils compression brotli: Command, insertOnly has no copy" {
    const command = insertOnly(5, 3);

    try std.testing.expect(!command.hasCopy());
    try std.testing.expectEqual(@as(usize, 5), command.lit_off);
    try std.testing.expectEqual(@as(u32, 3), command.insert_len);
}

test "zix utils compression brotli: Command, copy length marks a copy" {
    const command: Self = .{
        .insert_len = 0,
        .lit_off = 0,
        .copy_len = 4,
        .distance = 1,
        .is_dict = false,
    };

    try std.testing.expect(command.hasCopy());
}

