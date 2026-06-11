//! Unit tests: FIX parsing, building, and checksum, no I/O.
//! Run: zig test rnd/fix_unit_test.zig

const std = @import("std");
const core = @import("fix_poc_core.zig");

// ------------------------------------------------------------------- //
// findMessageEnd                                                       //
// ------------------------------------------------------------------- //

test "unit: findMessageEnd returns null for empty buf" {
    try std.testing.expect(core.findMessageEnd("") == null);
}

test "unit: findMessageEnd returns null when tag 10 absent" {
    const buf = "8=FIX.4.2\x019=5\x0135=A\x01";
    try std.testing.expect(core.findMessageEnd(buf) == null);
}

test "unit: findMessageEnd finds end of a complete message" {
    const buf = "8=FIX.4.2\x019=5\x0135=A\x0110=123\x01";
    const end = core.findMessageEnd(buf);
    try std.testing.expect(end != null);
    try std.testing.expectEqual(buf.len, end.?);
}

test "unit: findMessageEnd stops at first message when two messages are present" {
    const msg1 = "8=FIX.4.2\x019=5\x0135=A\x0110=001\x01";
    const msg2 = "8=FIX.4.2\x019=5\x0135=5\x0110=002\x01";
    const buf = msg1 ++ msg2;
    const end = core.findMessageEnd(buf);
    try std.testing.expect(end != null);
    try std.testing.expectEqual(msg1.len, end.?);
}

// ------------------------------------------------------------------- //
// parseFields                                                          //
// ------------------------------------------------------------------- //

test "unit: parseFields extracts all tag=value pairs" {
    const msg = "8=FIX.4.2\x019=5\x0135=A\x0149=CLIENT\x0156=SERVER\x0134=1\x01";
    var fields: [16]core.Field = undefined;
    const n = try core.parseFields(msg, &fields);
    try std.testing.expectEqual(6, n);
    try std.testing.expectEqual(8, fields[0].tag);
    try std.testing.expectEqualStrings("FIX.4.2", fields[0].value);
    try std.testing.expectEqual(35, fields[2].tag);
    try std.testing.expectEqualStrings("A", fields[2].value);
    try std.testing.expectEqual(56, fields[4].tag);
    try std.testing.expectEqualStrings("SERVER", fields[4].value);
}

test "unit: parseFields returns error.BadTag on non-numeric tag" {
    const msg = "bad=value\x01";
    var fields: [4]core.Field = undefined;
    try std.testing.expectError(error.BadTag, core.parseFields(msg, &fields));
}

// ------------------------------------------------------------------- //
// getField                                                             //
// ------------------------------------------------------------------- //

test "unit: getField finds a tag" {
    const fields = [_]core.Field{
        .{ .tag = 8, .value = "FIX.4.2" },
        .{ .tag = 35, .value = "D" },
        .{ .tag = 49, .value = "CLIENT" },
    };
    try std.testing.expectEqualStrings("D", core.getField(&fields, 35).?);
    try std.testing.expectEqualStrings("CLIENT", core.getField(&fields, 49).?);
}

test "unit: getField returns null for absent tag" {
    const fields = [_]core.Field{.{ .tag = 8, .value = "FIX.4.2" }};
    try std.testing.expect(core.getField(&fields, 35) == null);
}

// ------------------------------------------------------------------- //
// computeChecksum                                                      //
// ------------------------------------------------------------------- //

test "unit: computeChecksum of empty buf is 0" {
    try std.testing.expectEqual(0, core.computeChecksum(""));
}

test "unit: computeChecksum wraps at 256" {
    // 256 bytes of value 0x01 should sum to 256, mod 256 = 0
    const buf = [_]u8{0x01} ** 256;
    try std.testing.expectEqual(0, core.computeChecksum(&buf));
}

test "unit: computeChecksum known value" {
    const buf = "8=FIX.4.2\x01";
    // sum: 56+61+70+73+88+46+52+46+50+1 = 543, mod 256 = 31
    try std.testing.expectEqual(31, core.computeChecksum(buf));
}

// ------------------------------------------------------------------- //
// buildMessage + verifyChecksum round-trip                             //
// ------------------------------------------------------------------- //

test "unit: buildMessage produces a verifiable checksum" {
    var out: [core.MAX_MSG_SIZE]u8 = undefined;
    const n = try core.buildMessage(&out, "SERVER", "CLIENT", 1, "A", &.{
        .{ .tag = 98, .value = "0" },
        .{ .tag = 108, .value = "30" },
    });
    try std.testing.expect(core.verifyChecksum(out[0..n]));
}

test "unit: buildMessage parses back with correct MsgType and CompIDs" {
    var out: [core.MAX_MSG_SIZE]u8 = undefined;
    const n = try core.buildMessage(&out, "SRV", "CLT", 5, "D", &.{
        .{ .tag = 11, .value = "ORD001" },
        .{ .tag = 55, .value = "AAPL" },
    });
    var fields: [core.MAX_FIELDS]core.Field = undefined;
    const nf = try core.parseFields(out[0..n], &fields);
    const fslice = fields[0..nf];

    try std.testing.expectEqualStrings("D", core.getField(fslice, 35).?);
    try std.testing.expectEqualStrings("SRV", core.getField(fslice, 49).?);
    try std.testing.expectEqualStrings("CLT", core.getField(fslice, 56).?);
    try std.testing.expectEqualStrings("5", core.getField(fslice, 34).?);
    try std.testing.expectEqualStrings("ORD001", core.getField(fslice, 11).?);
    try std.testing.expectEqualStrings("AAPL", core.getField(fslice, 55).?);
}

test "unit: verifyChecksum returns false for tampered byte" {
    var out: [core.MAX_MSG_SIZE]u8 = undefined;
    const n = try core.buildMessage(&out, "S", "C", 1, "0", &.{});
    // Flip one byte in the body.
    out[5] ^= 0xFF;
    try std.testing.expect(!core.verifyChecksum(out[0..n]));
}

test "unit: bodyLength field equals byte count from tag 35 to last SOH before tag 10" {
    var out: [core.MAX_MSG_SIZE]u8 = undefined;
    const n = try core.buildMessage(&out, "SRV", "CLT", 1, "A", &.{
        .{ .tag = 98, .value = "0" },
    });
    const raw = out[0..n];

    // Find BodyLength value from the message.
    var fields: [core.MAX_FIELDS]core.Field = undefined;
    const nf = try core.parseFields(raw, &fields);
    const bl_str = core.getField(fields[0..nf], 9).?;
    const bl = try std.fmt.parseInt(usize, bl_str, 10);

    // Locate tag 35 start: find "35=" in the raw bytes.
    const tag35_start = std.mem.indexOf(u8, raw, "35=").?;

    // Locate start of "10=" (preceded by SOH).
    var i: usize = 0;
    var tag10_soh: usize = 0;
    while (i + 4 <= raw.len) : (i += 1) {
        if (raw[i] == core.SOH and raw[i + 1] == '1' and raw[i + 2] == '0' and raw[i + 3] == '=') {
            tag10_soh = i + 1; // position of '1' in "10="
            break;
        }
    }
    const measured = tag10_soh - tag35_start;
    try std.testing.expectEqual(bl, measured);
}
