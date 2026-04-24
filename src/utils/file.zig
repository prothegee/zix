//! File utils

const std = @import("std");

/// Brief:
/// Get file extension from file path
///
/// Note:
/// - Returns "" if '.' is not found or if '.' is the last character
///
/// Param:
/// fp - []const u8 (file path)
///
/// Return:
/// []const u8
pub fn extension(fp: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, fp, '.')) |dot_pos| {
        if (dot_pos + 1 < fp.len) {
            return fp[dot_pos + 1 ..];
        }
    }
    return "";
}
