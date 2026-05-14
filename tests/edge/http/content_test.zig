//! Edge tests: zix.Http.Content.typeFromExtension boundary conditions.
//! Verifies that unknown and empty extensions fall back to APPLICATION_OCTET_STREAM.

const std = @import("std");
const zix = @import("zix");

const Content = zix.Http.Content;

// --------------------------------------------------------- //

test "zix edge: typeFromExtension, unknown extension returns APPLICATION_OCTET_STREAM" {
    try std.testing.expectEqual(zix.Http.ContentType.APPLICATION_OCTET_STREAM, Content.typeFromExtension("xyz"));
    try std.testing.expectEqual(zix.Http.ContentType.APPLICATION_OCTET_STREAM, Content.typeFromExtension("bin"));
    try std.testing.expectEqual(zix.Http.ContentType.APPLICATION_OCTET_STREAM, Content.typeFromExtension("dat"));
    try std.testing.expectEqual(zix.Http.ContentType.APPLICATION_OCTET_STREAM, Content.typeFromExtension("unknown"));
}

test "zix edge: typeFromExtension, empty string returns APPLICATION_OCTET_STREAM" {
    try std.testing.expectEqual(zix.Http.ContentType.APPLICATION_OCTET_STREAM, Content.typeFromExtension(""));
}

test "zix edge: fromExtension, unknown extension returns application/octet-stream string" {
    try std.testing.expectEqualStrings("application/octet-stream", Content.fromExtension("xyz"));
    try std.testing.expectEqualStrings("application/octet-stream", Content.fromExtension(""));
}
