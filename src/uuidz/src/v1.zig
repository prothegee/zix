//! uuidz: uuid v1

const std = @import("std");

const hex = @import("hex.zig").hex;

const UUID_EPOCH_OFFSET = 122192928000000000;
const NODE_SIZE: usize = 6;
const DATA_SIZE: usize = 16;
const BUFF_SIZE: usize = 36;
const REFF_SIZE: usize = 32;

// --------------------------------------------------------- //

/// uuid v1
///
/// Note:
/// - Consider to use v7 or v4
///
/// Usage:
/// ```zig
/// const uuid = try v1.init(io);
///
/// var str:[36]u8 = undefined;
/// const str = uuid.asString(&str);
///
/// var ref:[32]u8 = undefined;
/// const uuid_ref = uuid.asReffID(&ref);
///
/// const uuid_str = "c535c140-a5c9-11f1-a5b5-878489497956";
/// const uuid_v1 = try v1.initFromString(uuid_str);
/// ```
pub const v1 = struct {
    const Self = @This();

    data: [DATA_SIZE]u8 = undefined,

    var mutex: std.Io.Mutex = .init;
    var node: [NODE_SIZE]u8 = undefined;
    var clock_sequence: u14 = undefined;
    var last_timestamp: u64 = 0;
    var is_initialized: bool = false;

    /// Init uuid
    pub fn init(io: std.Io) !Self {
        try mutex.lock(io);
        defer mutex.unlock(io);

        if (!is_initialized) {
            _ = try io.randomSecure(&node);
            node[0] |= 0x01;

            var tmp: [2]u8 = undefined;
            _ = try io.randomSecure(&tmp);
            clock_sequence = @as(u14, (@as(u14, tmp[0]) << 8) | tmp[1]) & 0x3FFF;
            is_initialized = true;
        }

        const now = std.Io.Clock.Timestamp.now(io, .real);
        const ns = now.raw.nanoseconds;
        const timestamp = @as(u64, @intCast(@divTrunc(ns, 100))) + UUID_EPOCH_OFFSET;

        if (timestamp <= last_timestamp) {
            clock_sequence = (clock_sequence + 1) & 0x3FFF;
        }
        last_timestamp = timestamp;

        const time_low = @as(u32, @truncate(timestamp));
        const time_mid = @as(u16, @truncate(timestamp >> 32));
        const time_high = @as(u16, @truncate(timestamp >> 48));
        const time_high_and_version = (time_high & 0x0FFF) | 0x1000;

        const clock_seq_high = @as(u8, @truncate(clock_sequence >> 8));
        const clock_seq_low = @as(u8, @truncate(clock_sequence & 0xFF));
        const clock_seq_high_and_reserved = clock_seq_high | 0x80;

        var self: Self = .{};
        std.mem.writeInt(u32, self.data[0..4], time_low, .big);
        std.mem.writeInt(u16, self.data[4..6], time_mid, .big);
        std.mem.writeInt(u16, self.data[6..8], time_high_and_version, .big);
        self.data[8] = clock_seq_high_and_reserved;
        self.data[9] = clock_seq_low;
        @memcpy(self.data[10..16], &node);

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

test "uuidz uuid v1: asString determenistic formatting & RFC 4122 compliance" {
    var uuid = v1{};

    // fill with specific pattern with RFC behalf
    // time low
    uuid.data[0] = 0x11;
    uuid.data[1] = 0x22;
    uuid.data[2] = 0x33;
    uuid.data[3] = 0x44;
    // time mid
    uuid.data[4] = 0x55;
    uuid.data[5] = 0x66;
    // time high and version (0x1... = Version 1)
    uuid.data[6] = 0x17;
    uuid.data[7] = 0x89;
    // clock sequence (0x8... = Variant 10xx)
    uuid.data[8] = 0x8A;
    uuid.data[9] = 0xBC;
    // node: 0xDE for to 0xDF
    // since node[0] |= 0x01
    // last but turn 1 / odd num
    uuid.data[10] = 0xDF;
    uuid.data[11] = 0xAD;
    uuid.data[12] = 0xBE;
    uuid.data[13] = 0xEF;
    uuid.data[14] = 0x12;
    uuid.data[15] = 0x34;

    var buf: [BUFF_SIZE]u8 = undefined;
    const str = uuid.asString(&buf);

    // 1. expect length 36
    try std.testing.expectEqual(@as(usize, 36), str.len);

    // 2. `-` position must in index 8, 13, 18, and 23
    try std.testing.expectEqual('-', str[8]);
    try std.testing.expectEqual('-', str[13]);
    try std.testing.expectEqual('-', str[18]);
    try std.testing.expectEqual('-', str[23]);

    // 3. Index 14 must `1`
    try std.testing.expectEqual('1', str[14]);

    // 4. Node multicast bit
    // first byte nide is data[0] (0xDF)
    // hex from 0xDF is `df`. Second char (idx 25) must `f`
    try std.testing.expectEqual('f', str[25]);

    // validate all chars is lowercase for non hyphen `-`
    for (str, 0..) |c, i| {
        if (i == 8 or i == 13 or i == 18 or i == 23) continue;
        try std.testing.expect(std.mem.indexOfScalar(u8, hex, c) != null);
    }
}

test "uuidz uuid v1: rapid generation uniqueness (clock collision)" {
    const io = std.testing.io;

    var prev_str: [BUFF_SIZE]u8 = undefined;
    var curr_str: [BUFF_SIZE]u8 = undefined;

    const uuid = try v1.init(io);

    _ = uuid.asString(&prev_str);

    for (0..100_000) |_| {
        const uuid_next = try v1.init(io);
        const curr_slice = uuid_next.asString(&curr_str);
        const prev_slice = prev_str[0..];

        // Must unique
        try std.testing.expect(!std.mem.eql(u8, prev_slice, curr_slice));

        // Copy current to prev for next itteration
        @memcpy(&prev_str, curr_slice);
    }
}

test "uuidz uuid v1: initFromString happy path (36 & 32 chars)" {
    const str_36 = "c535c140-a5c9-11f1-a5b5-878489497956";
    const str_32 = "c535c140a5c911f1a5b5878489497956";
    const str_36_upper = "C535C140-A5C9-11F1-A5B5-878489497956";

    const uuid_36 = try v1.initFromString(str_36);
    const uuid_32 = try v1.initFromString(str_32);
    const uuid_upper = try v1.initFromString(str_36_upper);

    // 1. 36 char and 32 char must identical on data
    try std.testing.expectEqualSlices(u8, &uuid_36.data, &uuid_32.data);

    // 2. Parse uppercase and must has identical slice
    try std.testing.expectEqualSlices(u8, &uuid_36.data, &uuid_upper.data);

    // 3. Validate first byte and last
    try std.testing.expectEqual(@as(u8, 0xc5), uuid_36.data[0]);
    try std.testing.expectEqual(@as(u8, 0x56), uuid_36.data[15]);
}

test "uuidz uuid v1: initFromString error handling" {
    // 1. Wrong length (terlalu pendek & terlalu panjang)
    try std.testing.expectError(error.InvalidUuidLength, v1.initFromString("too-short"));
    try std.testing.expectError(error.InvalidUuidLength, v1.initFromString("c535c140-a5c9-11f1-a5b5-8784894979560")); // 37 chars

    // 2. Wrong hyphen format
    try std.testing.expectError(error.InvalidUuidFormat, v1.initFromString("c535c1400a5c-11f1-a5b5-878489497956-"));

    // 3. Wrong hex character
    try std.testing.expectError(error.InvalidHexCharacter, v1.initFromString("g535c140-a5c9-11f1-a5b5-878489497956")); // 'g' invalid
    try std.testing.expectError(error.InvalidHexCharacter, v1.initFromString("c535c140-a5c9-11f1-a5b5-87848949795g")); // 'g' invalid on last
    try std.testing.expectError(error.InvalidHexCharacter, v1.initFromString("c535c140-a5c9-11f1-a5b5-87848949795 ")); // wrong whitespace
}

test "uuidz uuid v1: round-trip consistency (Serializer <--> Deserializer)" {
    var original_uuid = v1{ .data = undefined };
    for (0..16) |i| {
        original_uuid.data[i] = @as(u8, @intCast(i * 17));
    }

    var buf_str: [BUFF_SIZE]u8 = undefined;
    const str_output = original_uuid.asString(&buf_str);

    const parsed_uuid = try v1.initFromString(str_output);

    try std.testing.expectEqualSlices(u8, &original_uuid.data, &parsed_uuid.data);
}

test "uuidz uuid v1: asReffID formatting & length" {
    var uuid = v1{};
    for (0..16) |i| uuid.data[i] = 0xAA;

    var buf: [REFF_SIZE]u8 = undefined;
    const ref_str = uuid.asReffID(&buf);

    // 1. Length must 32
    try std.testing.expectEqual(@as(usize, 32), ref_str.len);

    // 2. No hyphen
    try std.testing.expect(std.mem.indexOfScalar(u8, ref_str, '-') == null);

    // 3. All chars must valid hex
    for (ref_str) |c| {
        try std.testing.expect(std.mem.indexOfScalar(u8, hex, c) != null);
    }

    // 4. Specific value (0xAA -> "aa")
    try std.testing.expectEqual('a', ref_str[0]);
    try std.testing.expectEqual('a', ref_str[1]);
    try std.testing.expectEqual('a', ref_str[30]);
    try std.testing.expectEqual('a', ref_str[31]);
}
