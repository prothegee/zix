//! uuidz: uuid v7

const std = @import("std");

const hex = @import("hex.zig").hex;

const DATA_SIZE: usize = 16;
const BUFF_SIZE: usize = 36;
const REFF_SIZE: usize = 32;

// --------------------------------------------------------- //

/// uuid v7 (Time-ordered, Sortable)
///
/// Note:
/// - Recommended for database primary keys and distributed systems.
/// - Sortable by creation time.
/// - Does not leak MAC address.
///
/// Usage:
/// ```zig
/// const uuid = try v7.init(io);
///
/// var str: [36]u8 = undefined;
/// const str_out = uuid.asString(&str);
///
/// var ref: [32]u8 = undefined;
/// const ref_out = uuid.asReffID(&ref);
///
/// const uuid_str = "018f3b2a-7c8d-7123-8a4b-9c5d6e7f8a9b";
/// const uuid_v7 = try v7.initFromString(uuid_str);
/// ```
pub const v7 = struct {
    const Self = @This();

    data: [DATA_SIZE]u8 = undefined,

    // State to guarantee monotonicity in exact milliseconds
    var mutex: std.Io.Mutex = .init;
    var last_timtestamp_ms: u64 = 0;

    /// Init uuid v7
    pub fn init(io: std.Io) !Self {
        try mutex.lock(io);
        defer mutex.unlock(io);

        var self: Self = .{};

        const now = std.Io.Clock.Timestamp.now(io, .real);
        var current_ms = @as(u64, @intCast(@divTrunc(now.raw.nanoseconds, 1_000_000)));

        // 1. NTP sync
        // handle if system clock backward
        if (current_ms < last_timtestamp_ms) {
            current_ms = last_timtestamp_ms;
        }

        if (current_ms > last_timtestamp_ms) {
            // Randomize the random part (74 bits)
            try io.randomSecure(self.data[6..16]);
            last_timtestamp_ms = current_ms;
        } else {
            // Same millisecond: increment 74-bit random field
            var old_random: [10]u8 = self.data[6..16].*;

            var carry: u8 = 1;
            var i: usize = 15;
            while (i >= 6 and carry > 0) : (i -= 1) {
                const sum = @as(u16, self.data[i]) + carry;
                self.data[i] = @as(u8, @truncate(sum));
                carry = @as(u8, @truncate(sum >> 8));
            }

            // Terapkan mask Version 7 dan Variant RFC 4122
            // Implement mask v7 and variant of RFC 4122
            self.data[6] = (self.data[6] & 0x0F) | 0x70;
            self.data[8] = (self.data[8] & 0x3F) | 0x80;

            // Overflow detection if new result les or equal from old one,
            // meaning 74-bit already full (0x7F increment to 0x80, then masked as 0x70)
            if (std.mem.order(u8, self.data[6..16], &old_random) != .gt) {
                // Overflow detected, forward timestamp for 1ms and re-randomize
                current_ms += 1;
                try io.randomSecure(self.data[6..16]);
                last_timtestamp_ms = current_ms;

                // Re-apply the mask for the new random data
                self.data[6] = (self.data[6] & 0x0F) | 0x70;
                self.data[8] = (self.data[8] & 0x3F) | 0x80;
            }
        }

        // 2. Write 48-bit timestamp to data[0..6] too big-endian format
        self.data[0] = @as(u8, @truncate(current_ms >> 40));
        self.data[1] = @as(u8, @truncate(current_ms >> 32));
        self.data[2] = @as(u8, @truncate(current_ms >> 24));
        self.data[3] = @as(u8, @truncate(current_ms >> 16));
        self.data[4] = @as(u8, @truncate(current_ms >> 8));
        self.data[5] = @as(u8, @truncate(current_ms));

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

        // Strict validation: ensure this one is uuid v7
        if ((self.data[6] & 0xF0) != 0x70) return error.InvalidUuidVersion;
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

test "uuidz uuid v7: asString deterministic formatting & RFC 9562 compliance" {
    var uuid = v7{};

    // Set byte 6 to 0x75 (Version 7: 0111xxxx)
    // Set byte 8 to 0x8A (Variant RFC: 10xxxxxx)
    for (0..16) |i| {
        uuid.data[i] = 0xFF;
    }
    uuid.data[6] = 0x75;
    uuid.data[8] = 0x8A;

    var buf: [BUFF_SIZE]u8 = undefined;
    const str = uuid.asString(&buf);

    try std.testing.expectEqual(@as(usize, 36), str.len);
    try std.testing.expectEqual('-', str[8]);
    try std.testing.expectEqual('-', str[13]);
    try std.testing.expectEqual('-', str[18]);
    try std.testing.expectEqual('-', str[23]);

    // Index 14 must `7`
    try std.testing.expectEqual('7', str[14]);

    // Index 19 must `8`, `9`, `a`, or `b` (0x8A -> `8`)
    try std.testing.expectEqual('8', str[19]);

    for (str, 0..) |c, i| {
        if (i == 8 or i == 13 or i == 18 or i == 23) continue;
        try std.testing.expect(std.mem.indexOfScalar(u8, hex, c) != null);
    }
}

test "uuidz uuid v7: rapid generation monotonicity & uniqueness" {
    const io = std.testing.io;

    var prev_str: [BUFF_SIZE]u8 = undefined;
    var curr_str: [BUFF_SIZE]u8 = undefined;

    const uuid = try v7.init(io);

    _ = uuid.asString(&prev_str);

    // Since v7 design for sortable,
    // every new uuid must larger with lexiograph based.
    for (0..100_000) |_| {
        const uuid_next = try v7.init(io);
        const curr_slice = uuid_next.asString(&curr_str);

        // 1. Must unique
        try std.testing.expect(!std.mem.eql(u8, prev_str[0..], curr_slice));

        // 2. Must larger (monotonic ascending)
        try std.testing.expect(std.mem.order(u8, prev_str[0..], curr_slice) == .lt);

        // Copy current to prev for the next iteration. 
        // This is safe because curr_slice points to curr_str,
        // whereas the target is prev_str (different memory addresses).
        @memcpy(&prev_str, curr_slice);
    }
}

test "uuidz uuid v7: initFromString happy path & strict validation" {
    const str_36 = "018f3b2a-7c8d-7123-8a4b-9c5d6e7f8a9b";
    const str_32 = "018f3b2a7c8d71238a4b9c5d6e7f8a9b";
    const str_36_upper = "018F3B2A-7C8D-7123-8A4B-9C5D6E7F8A9B";

    const uuid_36 = try v7.initFromString(str_36);
    const uuid_32 = try v7.initFromString(str_32);
    const uuid_upper = try v7.initFromString(str_36_upper);

    try std.testing.expectEqualSlices(u8, &uuid_36.data, &uuid_32.data);
    try std.testing.expectEqualSlices(u8, &uuid_36.data, &uuid_upper.data);

    try std.testing.expectEqual(@as(u8, 0x71), uuid_36.data[6]);
    try std.testing.expectEqual(@as(u8, 0x8A), uuid_36.data[8]);
}

test "uuidz uuid v7: initFromString error handling" {
    try std.testing.expectError(error.InvalidUuidLength, v7.initFromString("too-short"));
    try std.testing.expectError(error.InvalidUuidLength, v7.initFromString("018f3b2a-7c8d-7123-8a4b-9c5d6e7f8a9b0"));

    try std.testing.expectError(error.InvalidUuidFormat, v7.initFromString("018f3b2a7c8d-7123-8a4b-9c5d6e7f8a9b-"));
    try std.testing.expectError(error.InvalidHexCharacter, v7.initFromString("018f3b2a-7c8d-7123-8a4b-9c5d6e7f8a9g"));

    // STRICT VALIDATION: String valid hex, but this one UUID v4 (index 14 = '4'), not v7 ('7')
    try std.testing.expectError(error.InvalidUuidVersion, v7.initFromString("f47ac10b-58cc-4372-a567-0e02b2c3d479"));
}

test "uuidz uuid v7: round-trip consistency" {
    var original_uuid = v7{};
    for (0..16) |i| original_uuid.data[i] = @as(u8, @intCast(i * 17));

    // Force v7 valid pattern
    original_uuid.data[6] = (original_uuid.data[6] & 0x0F) | 0x70;
    original_uuid.data[8] = (original_uuid.data[8] & 0x3F) | 0x80;

    var buf_str: [BUFF_SIZE]u8 = undefined;
    const str_output = original_uuid.asString(&buf_str);

    const parsed_uuid = try v7.initFromString(str_output);
    try std.testing.expectEqualSlices(u8, &original_uuid.data, &parsed_uuid.data);
}

test "uuidz uuid v7: asReffID formatting & length" {
    var uuid = v7{};
    for (0..16) |i| uuid.data[i] = 0xCC;
    uuid.data[6] = 0x7C;
    uuid.data[8] = 0x8C;

    var buf: [REFF_SIZE]u8 = undefined;
    const ref_str = uuid.asReffID(&buf);

    try std.testing.expectEqual(@as(usize, 32), ref_str.len);
    try std.testing.expect(std.mem.indexOfScalar(u8, ref_str, '-') == null);

    for (ref_str) |c| {
        try std.testing.expect(std.mem.indexOfScalar(u8, hex, c) != null);
    }

    try std.testing.expectEqual('c', ref_str[0]);
    try std.testing.expectEqual('c', ref_str[1]);
}
