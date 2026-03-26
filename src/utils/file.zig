const std = @import("std");

/// Brief:
/// Get file extension from `fp` param
///
/// Note:
/// - Default return "" or empty
/// - If `.` is not found, it return "" or empty
///
/// Param:
/// fp - file path
///
/// Return:
/// []const u8
pub fn getFileExt(fp: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, fp, '.')) |dot_pos| {
        if (dot_pos + 1 < fp.len) {
            return fp[dot_pos + 1 ..];
        }
    }
    return "";
}
