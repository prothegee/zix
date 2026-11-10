//! ZIX utils http range spec
//!
//! ### file: src/zix/utils/http/RangeSpec.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! A byte range as the client wrote it, before the file size is known.
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

/// First byte the client asked for.
start: u64,
/// Last byte the client asked for, inclusive. null means "to the end".
end: ?u64,

const Self = @This();

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "zix utils http: RangeSpec, keeps a closed range" {
    const spec: Self = .{
        .start = 2,
        .end = 5,
    };

    try std.testing.expectEqual(@as(u64, 2), spec.start);
    try std.testing.expectEqual(@as(u64, 5), spec.end.?);
}

test "zix utils http: RangeSpec, null end means open ended" {
    const spec: Self = .{
        .start = 100,
        .end = null,
    };

    try std.testing.expect(spec.end == null);
}

