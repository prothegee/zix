//! Behaviour tests: zix.Udp.toEndian / fromEndian contracts.
//! Verifies the rules callers rely on: NATIVE is a no-op, u8 arrays are
//! never swapped, and non-native endian swaps integer and float fields.

const std = @import("std");
const zix = @import("zix");

const Packet = extern struct {
    id: [4]u8,
    value: i32,
    ratio: f32,
    coords: [2]f64,
};

// --------------------------------------------------------- //

test "zix behaviour: toEndian, NATIVE is a no-op regardless of host" {
    const pkt = Packet{ .id = "abcd".*, .value = 42, .ratio = 1.5, .coords = .{ 1.0, -2.0 } };
    const result = zix.Udp.toEndian(Packet, pkt, .NATIVE);
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&pkt), std.mem.asBytes(&result));
}

test "zix behaviour: toEndian, u8 array fields are never byte-swapped" {
    const pkt = Packet{ .id = "abcd".*, .value = 1, .ratio = 1.0, .coords = .{ 0.0, 0.0 } };
    const result_le = zix.Udp.toEndian(Packet, pkt, .LITTLE);
    const result_be = zix.Udp.toEndian(Packet, pkt, .BIG);
    try std.testing.expectEqualSlices(u8, &pkt.id, &result_le.id);
    try std.testing.expectEqualSlices(u8, &pkt.id, &result_be.id);
}

test "zix behaviour: toEndian, non-native endian swaps integer fields" {
    const builtin = @import("builtin");
    const non_native: zix.Udp.Endianness = if (builtin.cpu.arch.endian() == .little) .BIG else .LITTLE;
    const pkt = Packet{ .id = "abcd".*, .value = 0x01020304, .ratio = 1.0, .coords = .{ 1.0, 0.0 } };
    const result = zix.Udp.toEndian(Packet, pkt, non_native);
    try std.testing.expectEqual(@byteSwap(pkt.value), result.value);
}

test "zix behaviour: toEndian, non-native endian swaps float array elements" {
    const builtin = @import("builtin");
    const non_native: zix.Udp.Endianness = if (builtin.cpu.arch.endian() == .little) .BIG else .LITTLE;
    const pkt = Packet{ .id = "abcd".*, .value = 1, .ratio = 1.0, .coords = .{ 1.0, 2.0 } };
    const result = zix.Udp.toEndian(Packet, pkt, non_native);
    const expected_x: f64 = @bitCast(@byteSwap(@as(u64, @bitCast(pkt.coords[0]))));
    const expected_y: f64 = @bitCast(@byteSwap(@as(u64, @bitCast(pkt.coords[1]))));
    try std.testing.expectEqual(expected_x, result.coords[0]);
    try std.testing.expectEqual(expected_y, result.coords[1]);
}
