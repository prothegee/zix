//! uuidz: uuid v4

const std = @import("std");

const hex = @import("hex.zig").hex;

const DATA_SIZE: usize = 16;
const BUFF_SIZE: usize = 36;
const REFF_SIZE: usize = 32;

// --------------------------------------------------------- //

/// uuid v4 (Random)
///
/// Note:
/// - Recommended for general purpose unique identifiers.
/// - Does not leak timestamp or MAC address.
///
/// Usage:
/// ```zig
/// const uuid = try v4.init(io);
///
/// var str: [36]u8 = undefined;
/// const str_out = uuid.asString(&str);
///
/// var ref: [32]u8 = undefined;
/// const ref_out = uuid.asReffID(&ref);
///
/// const uuid_str = "f47ac10b-58cc-4372-a567-0e02b2c3d479";
/// const uuid_v4 = try v4.initFromString(uuid_str);
/// ```
pub const v4 = struct {
    const Self = @This();

    data: [DATA_SIZE]u8 = undefined,

    /// Init uuid v4 (Purely random)
    pub fn init(io: std.Io) !Self {
        var self: Self = .{};

        // 1. Generate 16 random bytes
        try io.randomSecure(&self.data);

        // 2. Set Version to 4 (0100 in binary)
        // Clear top 4 bits of byte 6, then set to 0x40
        self.data[6] = (self.data[6] & 0x0F) | 0x40;

        // 3. Set Variant to RFC 4122 (10 in binary)
        // Clear top 2 bits of byte 8, then set to 0x80
        self.data[8] = (self.data[8] & 0x3F) | 0x80;

        return self;
    }

    /// Init uuid from string
    ///
    /// Note:
    /// - Support 36 chars with `-` or 32 chars without `-`
    pub fn initFromString(str: []const u8) !Self {
        if (str.len != 36 and str.len != 32) return error.InvalidUuidLength;

        var self: Self = .{};
        var str_idx: usize = 0;

        for (0..16) |i| {
            // Skip and validate `-` if format 36 chars
            if (str.len == 36 and (str_idx == 8 or str_idx == 13 or str_idx == 18 or str_idx == 23)) {
                if (str[str_idx] != '-') return error.InvalidUuidFormat;
                str_idx += 1;
            }

            const high = switch (str[str_idx]) {
                '0'...'9' => |c| c - '0',
                'a'...'f' => |c| c - 'a' + 10,
                'A'...'F' => |c| c - 'A' + 10,
                else => return error.InvalidHexCharacter,
            };

            const low = switch (str[str_idx + 1]) {
                '0'...'9' => |c| c - '0',
                'a'...'f' => |c| c - 'a' + 10,
                'A'...'F' => |c| c - 'A' + 10,
                else => return error.InvalidHexCharacter,
            };

            self.data[i] = (high << 4) | low;
            str_idx += 2;
        }

        // Optional but recommended: Validate that the parsed string is actually a v4 UUID
        if ((self.data[6] & 0xF0) != 0x40) return error.InvalidUuidVersion;
        if ((self.data[8] & 0xC0) != 0x80) return error.InvalidUuidVariant;

        return self;
    }

    /// Return uuid as a string.
    pub fn asString(self: Self, buf: *[BUFF_SIZE]u8) []u8 {
        var i: usize = 0;

        inline for (0..4) |j| {
            const b = self.data[j];
            buf[i] = hex[(b >> 4) & 0xF];
            buf[i + 1] = hex[b & 0xF];
            i += 2;
        }
        buf[i] = '-';
        i += 1;

        inline for (4..6) |j| {
            const b = self.data[j];
            buf[i] = hex[(b >> 4) & 0xF];
            buf[i + 1] = hex[b & 0xF];
            i += 2;
        }
        buf[i] = '-';
        i += 1;

        inline for (6..8) |j| {
            const b = self.data[j];
            buf[i] = hex[(b >> 4) & 0xF];
            buf[i + 1] = hex[b & 0xF];
            i += 2;
        }
        buf[i] = '-';
        i += 1;

        inline for (8..10) |j| {
            const b = self.data[j];
            buf[i] = hex[(b >> 4) & 0xF];
            buf[i + 1] = hex[b & 0xF];
            i += 2;
        }
        buf[i] = '-';
        i += 1;

        inline for (10..16) |j| {
            const b = self.data[j];
            buf[i] = hex[(b >> 4) & 0xF];
            buf[i + 1] = hex[b & 0xF];
            i += 2;
        }

        return buf[0..];
    }

    /// Return uuid as a string without `-`.
    pub fn asReffID(self: Self, buf: *[REFF_SIZE]u8) []u8 {
        var i: usize = 0;

        inline for (0..4) |j| {
            const b = self.data[j];
            buf[i] = hex[(b >> 4) & 0xF];
            buf[i + 1] = hex[b & 0xF];
            i += 2;
        }

        inline for (4..6) |j| {
            const b = self.data[j];
            buf[i] = hex[(b >> 4) & 0xF];
            buf[i + 1] = hex[b & 0xF];
            i += 2;
        }

        inline for (6..8) |j| {
            const b = self.data[j];
            buf[i] = hex[(b >> 4) & 0xF];
            buf[i + 1] = hex[b & 0xF];
            i += 2;
        }

        inline for (8..10) |j| {
            const b = self.data[j];
            buf[i] = hex[(b >> 4) & 0xF];
            buf[i + 1] = hex[b & 0xF];
            i += 2;
        }

        inline for (10..16) |j| {
            const b = self.data[j];
            buf[i] = hex[(b >> 4) & 0xF];
            buf[i + 1] = hex[b & 0xF];
            i += 2;
        }

        return buf[0..];
    }
};

// --------------------------------------------------------- //
// --------------------------------------------------------- //

test "uuidz uuid v4: asString deterministic formatting & RFC 4122 compliance" {
    var uuid = v4{};

    // Fill with specific pattern to verify bit masking logic
    // We set byte 6 to 0x45 (Version 4: 0100xxxx)
    // We set byte 8 to 0x8A (Variant RFC: 10xxxxxx)
    for (0..16) |i| uuid.data[i] = 0xFF;
    uuid.data[6] = 0x45;
    uuid.data[8] = 0x8A;

    var buf: [BUFF_SIZE]u8 = undefined;
    const str = uuid.asString(&buf);

    // 1. Expect length 36
    try std.testing.expectEqual(@as(usize, 36), str.len);

    // 2. `-` position must be in index 8, 13, 18, and 23
    try std.testing.expectEqual('-', str[8]);
    try std.testing.expectEqual('-', str[13]);
    try std.testing.expectEqual('-', str[18]);
    try std.testing.expectEqual('-', str[23]);

    // 3. Index 14 must be `4` (Version 4)
    try std.testing.expectEqual('4', str[14]);

    // 4. Variant digit (index 19) must be '8', '9', 'a', or 'b'
    // 0x8A in hex is "8a", so index 19 is '8'
    try std.testing.expectEqual('8', str[19]);

    // 5. Validate all chars are lowercase hex for non-hyphen
    for (str, 0..) |c, i| {
        if (i == 8 or i == 13 or i == 18 or i == 23) continue;
        try std.testing.expect(std.mem.indexOfScalar(u8, hex, c) != null);
    }
}

test "uuidz uuid v4: rapid generation uniqueness (randomness check)" {
    const io = std.testing.io;

    var prev_str: [BUFF_SIZE]u8 = undefined;
    var curr_str: [BUFF_SIZE]u8 = undefined;

    const uuid = try v4.init(io);
    _ = uuid.asString(&prev_str);

    // Probability of collision is virtually zero.
    // This proves the RNG is actually being called and not returning static data.
    for (0..100_000) |_| {
        const uuid_next = try v4.init(io);
        const curr_slice = uuid_next.asString(&curr_str);
        const prev_slice = prev_str[0..];

        try std.testing.expect(!std.mem.eql(u8, prev_slice, curr_slice));
        @memcpy(&prev_str, curr_slice);
    }
}

test "uuidz uuid v4: initFromString happy path & strict validation" {
    const str_36 = "f47ac10b-58cc-4372-a567-0e02b2c3d479"; // Valid v4
    const str_32 = "f47ac10b58cc4372a5670e02b2c3d479";
    const str_36_upper = "F47AC10B-58CC-4372-A567-0E02B2C3D479";

    const uuid_36 = try v4.initFromString(str_36);
    const uuid_32 = try v4.initFromString(str_32);
    const uuid_upper = try v4.initFromString(str_36_upper);

    try std.testing.expectEqualSlices(u8, &uuid_36.data, &uuid_32.data);
    try std.testing.expectEqualSlices(u8, &uuid_36.data, &uuid_upper.data);

    // Verify version 4 and variant were correctly parsed
    try std.testing.expectEqual(@as(u8, 0x43), uuid_36.data[6]); // 0x43 = 0100 0011 (Version 4)

    // The original string has "a5" at index 8
    // 0xA5 = 1010 0101 (The top two bits are '10', which is valid for the RFC variant)
    try std.testing.expectEqual(@as(u8, 0xA5), uuid_36.data[8]);
}

test "uuidz uuid v4: initFromString error handling" {
    // 1. Wrong length
    try std.testing.expectError(error.InvalidUuidLength, v4.initFromString("too-short"));
    try std.testing.expectError(error.InvalidUuidLength, v4.initFromString("f47ac10b-58cc-4372-a567-0e02b2c3d4790"));

    // 2. Wrong hyphen format (length 36, but hyphen missing at index 8)
    try std.testing.expectError(error.InvalidUuidFormat, v4.initFromString("f47ac10b58cc-4372-a567-0e02b2c3d479-"));

    // 3. Invalid hex character
    try std.testing.expectError(error.InvalidHexCharacter, v4.initFromString("g47ac10b-58cc-4372-a567-0e02b2c3d479"));
    try std.testing.expectError(error.InvalidHexCharacter, v4.initFromString("f47ac10b-58cc-4372-a567-0e02b2c3d47g"));

    // 4. STRICT VALIDATION: String is valid hex, but NOT version 4 (e.g., version 1: "c535c140...")
    try std.testing.expectError(error.InvalidUuidVersion, v4.initFromString("c535c140-a5c9-11f1-a5b5-878489497956"));
}

test "uuidz uuid v4: round-trip consistency (Serializer <--> Deserializer)" {
    var original_uuid = v4{ .data = undefined };
    for (0..16) |i| {
        // Force it to be a valid v4 pattern for the test
        original_uuid.data[i] = @as(u8, @intCast(i * 17));
    }
    original_uuid.data[6] = (original_uuid.data[6] & 0x0F) | 0x40;
    original_uuid.data[8] = (original_uuid.data[8] & 0x3F) | 0x80;

    var buf_str: [BUFF_SIZE]u8 = undefined;
    const str_output = original_uuid.asString(&buf_str);

    const parsed_uuid = try v4.initFromString(str_output);

    try std.testing.expectEqualSlices(u8, &original_uuid.data, &parsed_uuid.data);
}

test "uuidz uuid v4: asReffID formatting & length" {
    var uuid = v4{};
    for (0..16) |i| uuid.data[i] = 0xBB;
    uuid.data[6] = 0x4B;
    uuid.data[8] = 0x8B;

    var buf: [REFF_SIZE]u8 = undefined;
    const ref_str = uuid.asReffID(&buf);

    try std.testing.expectEqual(@as(usize, 32), ref_str.len);
    try std.testing.expect(std.mem.indexOfScalar(u8, ref_str, '-') == null);

    for (ref_str) |c| {
        try std.testing.expect(std.mem.indexOfScalar(u8, hex, c) != null);
    }

    try std.testing.expectEqual('b', ref_str[0]);
    try std.testing.expectEqual('b', ref_str[1]);
}
