//! Behaviour tests: SSE (Server-Sent Events) observable contracts.
//! Verifies the TEXT_EVENT_STREAM MIME string and the streaming field default.

const std = @import("std");
const zix = @import("zix");

// --------------------------------------------------------- //

test "zix behaviour: ContentType.TEXT_EVENT_STREAM, asString returns text/event-stream" {
    const ct: zix.Http.ContentType = .TEXT_EVENT_STREAM;
    try std.testing.expectEqualStrings("text/event-stream", ct.asString());
}

test "zix behaviour: Response.streaming, defaults to false" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const res = zix.Http.Response.init(undefined, false, undefined, arena.allocator(), 32);
    try std.testing.expect(!res.streaming);
}
