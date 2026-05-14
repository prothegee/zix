//! Edge tests: zix.Udp packet and endianness boundary conditions.
//! Verifies: Endianness enum backing values are stable across builds,
//! and FeedbackResult ack/nack variants carry no payload.

const std = @import("std");
const zix = @import("zix");

// --------------------------------------------------------- //

test "zix edge: Endianness, enum backing values are stable" {
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(zix.Udp.Endianness.NATIVE));
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(zix.Udp.Endianness.LITTLE));
    try std.testing.expectEqual(@as(u8, 2), @intFromEnum(zix.Udp.Endianness.BIG));
}

test "zix edge: FeedbackResult, ack and nack are tag-only (zero-size payload)" {
    const Pkt = extern struct { id: u32 };
    const FB = zix.Udp.FeedbackResult(Pkt);
    const ack: FB = .ack;
    const nack: FB = .nack;
    try std.testing.expect(std.meta.activeTag(ack) == .ack);
    try std.testing.expect(std.meta.activeTag(nack) == .nack);
}
