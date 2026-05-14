//! Integration tests: UDP packet endianness round-trips with the example Packet type.
//! Uses the same extern struct as the udp_server/udp_client examples.

const std = @import("std");
const zix = @import("zix");

const Packet = extern struct {
    id: [16]u8,
    packet_type: i32,
    register: u32,
    position: [3]f64,
};

test "zix integration: Packet round-trip LITTLE endian preserves all values" {
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

test "zix integration: Packet round-trip BIG endian preserves all values" {
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

test "zix integration: FeedbackResult, packet variant stores full Packet" {
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
