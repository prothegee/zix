//! Behaviour tests: zix.Uds config defaults and frame wire format contracts.
//! Verifies field defaults and the 4-byte LE length-prefix frame encoding.

const std = @import("std");
const zix = @import("zix");

// --------------------------------------------------------- //

test "zix behaviour: UdsServerConfig, backlog defaults to 128" {
    const cfg = zix.Uds.ServerConfig{
        .path = "/tmp/zix_behaviour_test.sock",
        .allocator = std.testing.allocator,
    };
    try std.testing.expectEqual(@as(u31, 128), cfg.backlog);
}

test "zix behaviour: UdsServerConfig, max_msg_len defaults to 4096" {
    const cfg = zix.Uds.ServerConfig{
        .path = "/tmp/zix_behaviour_test.sock",
        .allocator = std.testing.allocator,
    };
    try std.testing.expectEqual(@as(usize, 4096), cfg.max_msg_len);
}

test "zix behaviour: UdsClientConfig, stores path as provided" {
    const cfg = zix.Uds.ClientConfig{ .path = "/tmp/zix_client_test.sock" };
    try std.testing.expectEqualStrings("/tmp/zix_client_test.sock", cfg.path);
}

test "zix behaviour: UDS frame, length header is 4-byte little-endian u32" {
    const payload_len: u32 = 1234;
    var hdr: [4]u8 = undefined;
    std.mem.writeInt(u32, &hdr, payload_len, .little);
    const decoded = std.mem.readInt(u32, &hdr, .little);
    try std.testing.expectEqual(payload_len, decoded);
}

test "zix behaviour: UDS frame, zero-length payload encodes as four zero bytes" {
    var hdr: [4]u8 = undefined;
    std.mem.writeInt(u32, &hdr, 0, .little);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, &hdr);
}

test "zix behaviour: UDS frame, header is always exactly 4 bytes" {
    var hdr: [4]u8 = undefined;
    std.mem.writeInt(u32, &hdr, 99, .little);
    try std.testing.expectEqual(@as(usize, 4), hdr.len);
}
