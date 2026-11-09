//! ZIX utils MultipartField
//!
//! ### file: src/zix/utils/MultipartField.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! One parsed part of a multipart/form-data body.
//!
//! ### note:
//!
//! Every slice borrows the body passed to Multipart.parse, file data included.
//! Copy what has to survive the handler call.
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

/// Field name from the Content-Disposition `name` parameter.
name: []const u8,
/// File name from the Content-Disposition `filename` parameter, null for a form field.
filename: ?[]const u8,
/// Value of the part's Content-Type header, null when the part has none.
content_type: ?[]const u8,
/// Part content without the framing CRLF in front of the next delimiter.
data: []const u8,
/// True when the part carries a filename.
is_file: bool,

const Self = @This();

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "zix utils: MultipartField, holds a file part" {
    const field: Self = .{
        .name = "upload",
        .filename = "a.bin",
        .content_type = "application/octet-stream",
        .data = "payload",
        .is_file = true,
    };

    try std.testing.expectEqualStrings("upload", field.name);
    try std.testing.expectEqualStrings("a.bin", field.filename.?);
    try std.testing.expectEqualStrings("application/octet-stream", field.content_type.?);
    try std.testing.expectEqualStrings("payload", field.data);
    try std.testing.expect(field.is_file);
}

test "zix utils: MultipartField, form part has no filename" {
    const field: Self = .{
        .name = "note",
        .filename = null,
        .content_type = null,
        .data = "",
        .is_file = false,
    };

    try std.testing.expect(field.filename == null);
    try std.testing.expect(field.content_type == null);
    try std.testing.expectEqual(@as(usize, 0), field.data.len);
    try std.testing.expect(!field.is_file);
}

