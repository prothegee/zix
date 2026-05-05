//! Integration tests: UDP packet endianness with the example Packet type.
//! Uses the same extern struct as udp_server.zig / udp_client.zig examples
//! to verify correct wire-format encoding for real-world field layouts:
//!   - [16]u8 id field must not be byte-swapped
//!   - i32 packet_type must be swapped for non-native endianness
//!   - u32 register must be swapped for non-native endianness
//!   - [3]f64 position elements must each be swapped for non-native endianness
//! Also covers FeedbackResult.packet value round-trip with the example type.

const std = @import("std");
const zix = @import("zix");

// --------------------------------------------------------- //
// Same Packet as defined in examples/udp_server.zig and examples/udp_client.zig.
// extern struct guarantees a fixed C ABI layout — required for cross-language use.

const Packet = extern struct {
    id: [16]u8,
    packet_type: i32,
    register: u32,
    position: [3]f64,
};

const Server = zix.Udp.Server(Packet);

// --------------------------------------------------------- //

test "zix integration: example Packet — NATIVE endian is a no-op" {
    const pkt = Packet{
        .id = "client-9101\x00\x00\x00\x00\x00".*,
        .packet_type = 1,
        .register = 42,
        .position = .{ 0.5, -1.0, 2.75 },
    };
    const result = zix.Udp.toEndian(Packet, pkt, .NATIVE);
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&pkt), std.mem.asBytes(&result));
}

test "zix integration: example Packet — id field never byte-swapped" {
    const pkt = Packet{
        .id = "client-9101\x00\x00\x00\x00\x00".*,
        .packet_type = 1,
        .register = 1,
        .position = .{ 0.0, 0.0, 0.0 },
    };
    const le = zix.Udp.toEndian(Packet, pkt, .LITTLE);
    const be = zix.Udp.toEndian(Packet, pkt, .BIG);
    try std.testing.expectEqualSlices(u8, &pkt.id, &le.id);
    try std.testing.expectEqualSlices(u8, &pkt.id, &be.id);
}

test "zix integration: example Packet — round-trip LITTLE preserves all values" {
    const pkt = Packet{
        .id = "client-9101\x00\x00\x00\x00\x00".*,
        .packet_type = -999,
        .register = 0xDEAD_BEEF,
        .position = .{ 1.23, -4.56, 7.89 },
    };
    const wire = zix.Udp.toEndian(Packet, pkt, .LITTLE);
    const back = zix.Udp.fromEndian(Packet, wire, .LITTLE);
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&pkt), std.mem.asBytes(&back));
}

test "zix integration: example Packet — round-trip BIG preserves all values" {
    const pkt = Packet{
        .id = "client-9102\x00\x00\x00\x00\x00".*,
        .packet_type = 42,
        .register = 1_000_000,
        .position = .{ -0.5, 0.25, 100.0 },
    };
    const wire = zix.Udp.toEndian(Packet, pkt, .BIG);
    const back = zix.Udp.fromEndian(Packet, wire, .BIG);
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&pkt), std.mem.asBytes(&back));
}

test "zix integration: example Packet — non-native endian swaps numeric fields" {
    const builtin = @import("builtin");
    const non_native: zix.Udp.Endianness = if (builtin.cpu.arch.endian() == .little) .BIG else .LITTLE;

    const pkt = Packet{
        .id = "test\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00".*,
        .packet_type = 0x01020304,
        .register = 0xAABBCCDD,
        .position = .{ 1.0, -2.0, 3.0 },
    };
    const result = zix.Udp.toEndian(Packet, pkt, non_native);

    try std.testing.expectEqual(@byteSwap(pkt.packet_type), result.packet_type);
    try std.testing.expectEqual(@byteSwap(pkt.register), result.register);
    // position elements must each be individually byte-swapped
    for (0..3) |i| {
        const expected: f64 = @bitCast(@byteSwap(@as(u64, @bitCast(pkt.position[i]))));
        try std.testing.expectEqual(expected, result.position[i]);
    }
    // id unchanged
    try std.testing.expectEqualSlices(u8, &pkt.id, &result.id);
}

test "zix integration: FeedbackResult — packet variant stores full example Packet" {
    const FB = zix.Udp.FeedbackResult(Packet);

    const pkt = Packet{
        .id = "client-9101\x00\x00\x00\x00\x00".*,
        .packet_type = 7,
        .register = 99,
        .position = .{ 0.1, 0.2, 0.3 },
    };
    const fb: FB = .{ .packet = pkt };

    try std.testing.expect(std.meta.activeTag(fb) == .packet);
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&pkt), std.mem.asBytes(&fb.packet));
}

test "zix integration: UdpServer — compile-time size guard accepts example Packet" {
    // Verifies the example Packet fits within the RFC 768 UDP payload limit (65,507 bytes).
    // This is a compile-time check; if it fails the program won't compile.
    comptime {
        if (@sizeOf(Packet) > 65_507) @compileError("Packet exceeds UDP payload limit");
    }
    // runtime assertion for visibility in test output
    try std.testing.expect(@sizeOf(Packet) <= 65_507);
}
