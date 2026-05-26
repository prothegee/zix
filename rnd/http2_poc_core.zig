//! HTTP/2 PoC core — h2c direct, frame codec, HPACK (static table + Huffman).
//! No dynamic table in initial PoC (literals only on encode side).
//! All pub for test imports.
//! Run: zig run rnd/http2_poc_server.zig

const std = @import("std");

// ------------------------------------------------------------------ //
// Frame constants                                                     //
// ------------------------------------------------------------------ //

pub const PREFACE = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n";

pub const FT_DATA: u8 = 0x00;
pub const FT_HEADERS: u8 = 0x01;
pub const FT_PRIORITY: u8 = 0x02;
pub const FT_RST_STREAM: u8 = 0x03;
pub const FT_SETTINGS: u8 = 0x04;
pub const FT_PUSH_PROMISE: u8 = 0x05;
pub const FT_PING: u8 = 0x06;
pub const FT_GOAWAY: u8 = 0x07;
pub const FT_WINDOW_UPDATE: u8 = 0x08;
pub const FT_CONTINUATION: u8 = 0x09;

pub const FLAG_END_STREAM: u8 = 0x01;
pub const FLAG_END_HEADERS: u8 = 0x04;
pub const FLAG_PADDED: u8 = 0x08;
pub const FLAG_PRIORITY: u8 = 0x20;
pub const FLAG_ACK: u8 = 0x01;

pub const ERR_NO_ERROR: u32 = 0x00;
pub const ERR_PROTOCOL_ERROR: u32 = 0x01;
pub const ERR_INTERNAL_ERROR: u32 = 0x02;
pub const ERR_FLOW_CONTROL_ERROR: u32 = 0x03;
pub const ERR_SETTINGS_TIMEOUT: u32 = 0x04;
pub const ERR_STREAM_CLOSED: u32 = 0x05;
pub const ERR_FRAME_SIZE_ERROR: u32 = 0x06;
pub const ERR_REFUSED_STREAM: u32 = 0x07;
pub const ERR_CANCEL: u32 = 0x08;
pub const ERR_COMPRESSION_ERROR: u32 = 0x09;
pub const ERR_CONNECT_ERROR: u32 = 0x0a;
pub const ERR_ENHANCE_YOUR_CALM: u32 = 0x0b;
pub const ERR_INADEQUATE_SECURITY: u32 = 0x0c;
pub const ERR_HTTP_1_1_REQUIRED: u32 = 0x0d;

pub const SETTINGS_HEADER_TABLE_SIZE: u16 = 0x01;
pub const SETTINGS_ENABLE_PUSH: u16 = 0x02;
pub const SETTINGS_MAX_CONCURRENT_STREAMS: u16 = 0x03;
pub const SETTINGS_INITIAL_WINDOW_SIZE: u16 = 0x04;
pub const SETTINGS_MAX_FRAME_SIZE: u16 = 0x05;
pub const SETTINGS_MAX_HEADER_LIST_SIZE: u16 = 0x06;

pub const DEFAULT_INITIAL_WINDOW: u32 = 65535;
pub const DEFAULT_MAX_FRAME_SIZE: u32 = 16384;
pub const MAX_HEADERS: usize = 64;
pub const MAX_PAYLOAD: usize = 16384;

// ------------------------------------------------------------------ //
// Frame header                                                        //
// ------------------------------------------------------------------ //

pub const FrameHeader = struct {
    length: u24,
    frame_type: u8,
    flags: u8,
    stream_id: u31,
};

pub fn readFrameHeader(fd: std.posix.fd_t) !FrameHeader {
    var buf: [9]u8 = undefined;
    try recvExact(fd, &buf);
    const length: u24 = (@as(u24, buf[0]) << 16) | (@as(u24, buf[1]) << 8) | buf[2];
    const stream_id: u31 = @intCast(((@as(u32, buf[5]) << 24) | (@as(u32, buf[6]) << 16) | (@as(u32, buf[7]) << 8) | buf[8]) & 0x7FFF_FFFF);
    return .{
        .length = length,
        .frame_type = buf[3],
        .flags = buf[4],
        .stream_id = stream_id,
    };
}

pub fn writeFrameHeader(fd: std.posix.fd_t, fh: FrameHeader) !void {
    var buf: [9]u8 = undefined;
    buf[0] = @intCast((fh.length >> 16) & 0xFF);
    buf[1] = @intCast((fh.length >> 8) & 0xFF);
    buf[2] = @intCast(fh.length & 0xFF);
    buf[3] = fh.frame_type;
    buf[4] = fh.flags;
    const sid: u32 = fh.stream_id;
    buf[5] = @intCast((sid >> 24) & 0xFF);
    buf[6] = @intCast((sid >> 16) & 0xFF);
    buf[7] = @intCast((sid >> 8) & 0xFF);
    buf[8] = @intCast(sid & 0xFF);
    try fdWriteAll(fd, &buf);
}

// ------------------------------------------------------------------ //
// I/O helpers                                                         //
// ------------------------------------------------------------------ //

pub fn fdWriteAll(fd: std.posix.fd_t, data: []const u8) error{BrokenPipe}!void {
    var rem = data;
    while (rem.len > 0) {
        const rc = std.posix.system.write(fd, rem.ptr, rem.len);
        switch (std.posix.errno(rc)) {
            .SUCCESS => {
                const n: usize = @intCast(rc);
                if (n == 0) return error.BrokenPipe;
                rem = rem[n..];
            },
            .INTR => continue,
            else => return error.BrokenPipe,
        }
    }
}

pub fn recvExact(fd: std.posix.fd_t, buf: []u8) !void {
    var filled: usize = 0;
    while (filled < buf.len) {
        const n = std.posix.read(fd, buf[filled..]) catch return error.Closed;
        if (n == 0) return error.Closed;
        filled += n;
    }
}

// ------------------------------------------------------------------ //
// HPACK static table (RFC 7541 Appendix A)                           //
// ------------------------------------------------------------------ //

pub const HpackEntry = struct { name: []const u8, value: []const u8 };

pub const HPACK_STATIC: [62]HpackEntry = blk: {
    // Index 0 is unused (1-based). Entry 0 is a sentinel.
    break :blk [62]HpackEntry{
        .{ .name = "", .value = "" }, // 0 (unused)
        .{ .name = ":authority", .value = "" }, // 1
        .{ .name = ":method", .value = "GET" }, // 2
        .{ .name = ":method", .value = "POST" }, // 3
        .{ .name = ":path", .value = "/" }, // 4
        .{ .name = ":path", .value = "/index.html" }, // 5
        .{ .name = ":scheme", .value = "http" }, // 6
        .{ .name = ":scheme", .value = "https" }, // 7
        .{ .name = ":status", .value = "200" }, // 8
        .{ .name = ":status", .value = "204" }, // 9
        .{ .name = ":status", .value = "206" }, // 10
        .{ .name = ":status", .value = "304" }, // 11
        .{ .name = ":status", .value = "400" }, // 12
        .{ .name = ":status", .value = "404" }, // 13
        .{ .name = ":status", .value = "500" }, // 14
        .{ .name = "accept-charset", .value = "" }, // 15
        .{ .name = "accept-encoding", .value = "gzip, deflate" }, // 16
        .{ .name = "accept-language", .value = "" }, // 17
        .{ .name = "accept-ranges", .value = "" }, // 18
        .{ .name = "accept", .value = "" }, // 19
        .{ .name = "access-control-allow-origin", .value = "" }, // 20
        .{ .name = "age", .value = "" }, // 21
        .{ .name = "allow", .value = "" }, // 22
        .{ .name = "authorization", .value = "" }, // 23
        .{ .name = "cache-control", .value = "" }, // 24
        .{ .name = "content-disposition", .value = "" }, // 25
        .{ .name = "content-encoding", .value = "" }, // 26
        .{ .name = "content-language", .value = "" }, // 27
        .{ .name = "content-length", .value = "" }, // 28
        .{ .name = "content-location", .value = "" }, // 29
        .{ .name = "content-range", .value = "" }, // 30
        .{ .name = "content-type", .value = "" }, // 31
        .{ .name = "cookie", .value = "" }, // 32
        .{ .name = "date", .value = "" }, // 33
        .{ .name = "etag", .value = "" }, // 34
        .{ .name = "expect", .value = "" }, // 35
        .{ .name = "expires", .value = "" }, // 36
        .{ .name = "from", .value = "" }, // 37
        .{ .name = "host", .value = "" }, // 38
        .{ .name = "if-match", .value = "" }, // 39
        .{ .name = "if-modified-since", .value = "" }, // 40
        .{ .name = "if-none-match", .value = "" }, // 41
        .{ .name = "if-range", .value = "" }, // 42
        .{ .name = "if-unmodified-since", .value = "" }, // 43
        .{ .name = "last-modified", .value = "" }, // 44
        .{ .name = "link", .value = "" }, // 45
        .{ .name = "location", .value = "" }, // 46
        .{ .name = "max-forwards", .value = "" }, // 47
        .{ .name = "proxy-authenticate", .value = "" }, // 48
        .{ .name = "proxy-authorization", .value = "" }, // 49
        .{ .name = "range", .value = "" }, // 50
        .{ .name = "referer", .value = "" }, // 51
        .{ .name = "refresh", .value = "" }, // 52
        .{ .name = "retry-after", .value = "" }, // 53
        .{ .name = "server", .value = "" }, // 54
        .{ .name = "set-cookie", .value = "" }, // 55
        .{ .name = "strict-transport-security", .value = "" }, // 56
        .{ .name = "transfer-encoding", .value = "" }, // 57
        .{ .name = "user-agent", .value = "" }, // 58
        .{ .name = "vary", .value = "" }, // 59
        .{ .name = "via", .value = "" }, // 60
        .{ .name = "www-authenticate", .value = "" }, // 61
    };
};

// ------------------------------------------------------------------ //
// HPACK Huffman decode (RFC 7541 Appendix B)                         //
// ------------------------------------------------------------------ //
// Table: index = symbol (0-255 + 256=EOS), fields = {code, bits}.
// Decoder: accumulate bits, linear scan for matching prefix.

const HuffSym = struct { code: u32, bits: u5 };

// Only the 256 printable/control ASCII codes are stored; EOS (256) is used
// only for padding and is handled separately.
pub const HUFF: [256]HuffSym = .{
    .{ .code = 0x1ff8, .bits = 13 }, // 0
    .{ .code = 0x7fffd8, .bits = 23 }, // 1
    .{ .code = 0xfffffe2, .bits = 28 }, // 2
    .{ .code = 0xfffffe3, .bits = 28 }, // 3
    .{ .code = 0xfffffe4, .bits = 28 }, // 4
    .{ .code = 0xfffffe5, .bits = 28 }, // 5
    .{ .code = 0xfffffe6, .bits = 28 }, // 6
    .{ .code = 0xfffffe7, .bits = 28 }, // 7
    .{ .code = 0xfffffe8, .bits = 28 }, // 8
    .{ .code = 0xffffea, .bits = 24 }, // 9
    .{ .code = 0x3ffffffc, .bits = 30 }, // 10
    .{ .code = 0xfffffe9, .bits = 28 }, // 11
    .{ .code = 0xfffffea, .bits = 28 }, // 12
    .{ .code = 0x3ffffffd, .bits = 30 }, // 13
    .{ .code = 0xfffffeb, .bits = 28 }, // 14
    .{ .code = 0xfffffec, .bits = 28 }, // 15
    .{ .code = 0xfffffed, .bits = 28 }, // 16
    .{ .code = 0xfffffee, .bits = 28 }, // 17
    .{ .code = 0xfffffef, .bits = 28 }, // 18
    .{ .code = 0xffffff0, .bits = 28 }, // 19
    .{ .code = 0xffffff1, .bits = 28 }, // 20
    .{ .code = 0xffffff2, .bits = 28 }, // 21
    .{ .code = 0x3ffffffe, .bits = 30 }, // 22
    .{ .code = 0xffffff3, .bits = 28 }, // 23
    .{ .code = 0xffffff4, .bits = 28 }, // 24
    .{ .code = 0xffffff5, .bits = 28 }, // 25
    .{ .code = 0xffffff6, .bits = 28 }, // 26
    .{ .code = 0xffffff7, .bits = 28 }, // 27
    .{ .code = 0xffffff8, .bits = 28 }, // 28
    .{ .code = 0xffffff9, .bits = 28 }, // 29
    .{ .code = 0xffffffa, .bits = 28 }, // 30
    .{ .code = 0xffffffb, .bits = 28 }, // 31
    .{ .code = 0x14, .bits = 6 }, // 32 ' '
    .{ .code = 0x3f8, .bits = 10 }, // 33 '!'
    .{ .code = 0x3f9, .bits = 10 }, // 34 '"'
    .{ .code = 0xffa, .bits = 12 }, // 35 '#'
    .{ .code = 0x1ff9, .bits = 13 }, // 36 '$'
    .{ .code = 0x15, .bits = 6 }, // 37 '%'
    .{ .code = 0xf8, .bits = 8 }, // 38 '&'
    .{ .code = 0x7fa, .bits = 11 }, // 39 '\''
    .{ .code = 0x3fa, .bits = 10 }, // 40 '('
    .{ .code = 0x3fb, .bits = 10 }, // 41 ')'
    .{ .code = 0xf9, .bits = 8 }, // 42 '*'
    .{ .code = 0x7fb, .bits = 11 }, // 43 '+'
    .{ .code = 0xfa, .bits = 8 }, // 44 ','
    .{ .code = 0x16, .bits = 6 }, // 45 '-'
    .{ .code = 0x17, .bits = 6 }, // 46 '.'
    .{ .code = 0x18, .bits = 6 }, // 47 '/'
    .{ .code = 0x0, .bits = 5 }, // 48 '0'
    .{ .code = 0x1, .bits = 5 }, // 49 '1'
    .{ .code = 0x2, .bits = 5 }, // 50 '2'
    .{ .code = 0x19, .bits = 6 }, // 51 '3'
    .{ .code = 0x1a, .bits = 6 }, // 52 '4'
    .{ .code = 0x1b, .bits = 6 }, // 53 '5'
    .{ .code = 0x1c, .bits = 6 }, // 54 '6'
    .{ .code = 0x1d, .bits = 6 }, // 55 '7'
    .{ .code = 0x1e, .bits = 6 }, // 56 '8'
    .{ .code = 0x1f, .bits = 6 }, // 57 '9'
    .{ .code = 0x5c, .bits = 7 }, // 58 ':'
    .{ .code = 0xfb, .bits = 8 }, // 59 ';'
    .{ .code = 0x7ffc, .bits = 15 }, // 60 '<'
    .{ .code = 0x20, .bits = 6 }, // 61 '='
    .{ .code = 0xffb, .bits = 12 }, // 62 '>'
    .{ .code = 0x3fc, .bits = 10 }, // 63 '?'
    .{ .code = 0x1ffa, .bits = 13 }, // 64 '@'
    .{ .code = 0x21, .bits = 6 }, // 65 'A'
    .{ .code = 0x5d, .bits = 7 }, // 66 'B'
    .{ .code = 0x5e, .bits = 7 }, // 67 'C'
    .{ .code = 0x5f, .bits = 7 }, // 68 'D'
    .{ .code = 0x60, .bits = 7 }, // 69 'E'
    .{ .code = 0x61, .bits = 7 }, // 70 'F'
    .{ .code = 0x62, .bits = 7 }, // 71 'G'
    .{ .code = 0x63, .bits = 7 }, // 72 'H'
    .{ .code = 0x64, .bits = 7 }, // 73 'I'
    .{ .code = 0x65, .bits = 7 }, // 74 'J'
    .{ .code = 0x66, .bits = 7 }, // 75 'K'
    .{ .code = 0x67, .bits = 7 }, // 76 'L'
    .{ .code = 0x68, .bits = 7 }, // 77 'M'
    .{ .code = 0x69, .bits = 7 }, // 78 'N'
    .{ .code = 0x6a, .bits = 7 }, // 79 'O'
    .{ .code = 0x6b, .bits = 7 }, // 80 'P'
    .{ .code = 0x6c, .bits = 7 }, // 81 'Q'
    .{ .code = 0x6d, .bits = 7 }, // 82 'R'
    .{ .code = 0x6e, .bits = 7 }, // 83 'S'
    .{ .code = 0x6f, .bits = 7 }, // 84 'T'
    .{ .code = 0x70, .bits = 7 }, // 85 'U'
    .{ .code = 0x71, .bits = 7 }, // 86 'V'
    .{ .code = 0x72, .bits = 7 }, // 87 'W'
    .{ .code = 0xfc, .bits = 8 }, // 88 'X'
    .{ .code = 0x73, .bits = 7 }, // 89 'Y'
    .{ .code = 0xfd, .bits = 8 }, // 90 'Z'
    .{ .code = 0x1ffb, .bits = 13 }, // 91 '['
    .{ .code = 0x7fff0, .bits = 19 }, // 92 '\\'
    .{ .code = 0x1ffc, .bits = 13 }, // 93 ']'
    .{ .code = 0x3ffc, .bits = 14 }, // 94 '^'
    .{ .code = 0x22, .bits = 6 }, // 95 '_'
    .{ .code = 0x7ffd, .bits = 15 }, // 96 '`'
    .{ .code = 0x3, .bits = 5 }, // 97 'a'
    .{ .code = 0x23, .bits = 6 }, // 98 'b'
    .{ .code = 0x4, .bits = 5 }, // 99 'c'
    .{ .code = 0x24, .bits = 6 }, // 100 'd'
    .{ .code = 0x5, .bits = 5 }, // 101 'e'
    .{ .code = 0x25, .bits = 6 }, // 102 'f'
    .{ .code = 0x26, .bits = 6 }, // 103 'g'
    .{ .code = 0x27, .bits = 6 }, // 104 'h'
    .{ .code = 0x6, .bits = 5 }, // 105 'i'
    .{ .code = 0x74, .bits = 7 }, // 106 'j'
    .{ .code = 0x75, .bits = 7 }, // 107 'k'
    .{ .code = 0x28, .bits = 6 }, // 108 'l'
    .{ .code = 0x29, .bits = 6 }, // 109 'm'
    .{ .code = 0x2a, .bits = 6 }, // 110 'n'
    .{ .code = 0x7, .bits = 5 }, // 111 'o'
    .{ .code = 0x2b, .bits = 6 }, // 112 'p'
    .{ .code = 0x76, .bits = 7 }, // 113 'q'
    .{ .code = 0x2c, .bits = 6 }, // 114 'r'
    .{ .code = 0x8, .bits = 5 }, // 115 's'
    .{ .code = 0x9, .bits = 5 }, // 116 't'
    .{ .code = 0x2d, .bits = 6 }, // 117 'u'
    .{ .code = 0x77, .bits = 7 }, // 118 'v'
    .{ .code = 0x78, .bits = 7 }, // 119 'w'
    .{ .code = 0x79, .bits = 7 }, // 120 'x'
    .{ .code = 0x7a, .bits = 7 }, // 121 'y'
    .{ .code = 0x7b, .bits = 7 }, // 122 'z'
    .{ .code = 0x7ffe, .bits = 15 }, // 123 '{'
    .{ .code = 0x7fc, .bits = 11 }, // 124 '|'
    .{ .code = 0x3ffd, .bits = 14 }, // 125 '}'
    .{ .code = 0x1ffd, .bits = 13 }, // 126 '~'
    .{ .code = 0xffffffc, .bits = 28 }, // 127
    .{ .code = 0xfffe6, .bits = 20 }, // 128
    .{ .code = 0x3fffd2, .bits = 22 }, // 129
    .{ .code = 0xfffe7, .bits = 20 }, // 130
    .{ .code = 0xfffe8, .bits = 20 }, // 131
    .{ .code = 0x3fffd3, .bits = 22 }, // 132
    .{ .code = 0x3fffd4, .bits = 22 }, // 133
    .{ .code = 0x3fffd5, .bits = 22 }, // 134
    .{ .code = 0x7fffd9, .bits = 23 }, // 135
    .{ .code = 0x3fffd6, .bits = 22 }, // 136
    .{ .code = 0x7fffda, .bits = 23 }, // 137
    .{ .code = 0x7fffdb, .bits = 23 }, // 138
    .{ .code = 0x7fffdc, .bits = 23 }, // 139
    .{ .code = 0x7fffdd, .bits = 23 }, // 140
    .{ .code = 0x7fffde, .bits = 23 }, // 141
    .{ .code = 0xffffeb, .bits = 24 }, // 142
    .{ .code = 0x7fffdf, .bits = 23 }, // 143
    .{ .code = 0xffffec, .bits = 24 }, // 144
    .{ .code = 0xffffed, .bits = 24 }, // 145
    .{ .code = 0x3fffd7, .bits = 22 }, // 146
    .{ .code = 0x7fffe0, .bits = 23 }, // 147
    .{ .code = 0xffffee, .bits = 24 }, // 148
    .{ .code = 0x7fffe1, .bits = 23 }, // 149
    .{ .code = 0x7fffe2, .bits = 23 }, // 150
    .{ .code = 0x7fffe3, .bits = 23 }, // 151
    .{ .code = 0x7fffe4, .bits = 23 }, // 152
    .{ .code = 0x1fffdc, .bits = 21 }, // 153
    .{ .code = 0x3fffd8, .bits = 22 }, // 154
    .{ .code = 0x7fffe5, .bits = 23 }, // 155
    .{ .code = 0x3fffd9, .bits = 22 }, // 156
    .{ .code = 0x7fffe6, .bits = 23 }, // 157
    .{ .code = 0x7fffe7, .bits = 23 }, // 158
    .{ .code = 0xffffef, .bits = 24 }, // 159
    .{ .code = 0x3fffda, .bits = 22 }, // 160
    .{ .code = 0x1fffdd, .bits = 21 }, // 161
    .{ .code = 0xfffe9, .bits = 20 }, // 162
    .{ .code = 0x3fffdb, .bits = 22 }, // 163
    .{ .code = 0x3fffdc, .bits = 22 }, // 164
    .{ .code = 0x7fffe8, .bits = 23 }, // 165
    .{ .code = 0x7fffe9, .bits = 23 }, // 166
    .{ .code = 0x1fffde, .bits = 21 }, // 167
    .{ .code = 0x7fffea, .bits = 23 }, // 168
    .{ .code = 0x3fffdd, .bits = 22 }, // 169
    .{ .code = 0x3fffde, .bits = 22 }, // 170
    .{ .code = 0xfffff0, .bits = 24 }, // 171
    .{ .code = 0x1fffdf, .bits = 21 }, // 172
    .{ .code = 0x3fffdf, .bits = 22 }, // 173
    .{ .code = 0x7fffeb, .bits = 23 }, // 174
    .{ .code = 0x7fffec, .bits = 23 }, // 175
    .{ .code = 0x1fffe0, .bits = 21 }, // 176
    .{ .code = 0x1fffe1, .bits = 21 }, // 177
    .{ .code = 0x3fffe0, .bits = 22 }, // 178
    .{ .code = 0x1fffe2, .bits = 21 }, // 179
    .{ .code = 0x7fffed, .bits = 23 }, // 180
    .{ .code = 0x3fffe1, .bits = 22 }, // 181
    .{ .code = 0x7fffee, .bits = 23 }, // 182
    .{ .code = 0x7fffef, .bits = 23 }, // 183
    .{ .code = 0xfffea, .bits = 20 }, // 184
    .{ .code = 0x3fffe2, .bits = 22 }, // 185
    .{ .code = 0x3fffe3, .bits = 22 }, // 186
    .{ .code = 0x3fffe4, .bits = 22 }, // 187
    .{ .code = 0x7ffff0, .bits = 23 }, // 188
    .{ .code = 0x3fffe5, .bits = 22 }, // 189
    .{ .code = 0x3fffe6, .bits = 22 }, // 190
    .{ .code = 0x7ffff1, .bits = 23 }, // 191
    .{ .code = 0x3ffffe0, .bits = 26 }, // 192
    .{ .code = 0x3ffffe1, .bits = 26 }, // 193
    .{ .code = 0xfffeb, .bits = 20 }, // 194
    .{ .code = 0x7fff1, .bits = 19 }, // 195
    .{ .code = 0x3fffe7, .bits = 22 }, // 196
    .{ .code = 0x7ffff2, .bits = 23 }, // 197
    .{ .code = 0x3fffe8, .bits = 22 }, // 198
    .{ .code = 0x1ffffec, .bits = 25 }, // 199
    .{ .code = 0x3ffffe2, .bits = 26 }, // 200
    .{ .code = 0x3ffffe3, .bits = 26 }, // 201
    .{ .code = 0x3ffffe4, .bits = 26 }, // 202
    .{ .code = 0x7ffffde, .bits = 27 }, // 203
    .{ .code = 0x7ffffdf, .bits = 27 }, // 204
    .{ .code = 0x3ffffe5, .bits = 26 }, // 205
    .{ .code = 0xfffff1, .bits = 24 }, // 206
    .{ .code = 0x1ffffed, .bits = 25 }, // 207
    .{ .code = 0x7fff2, .bits = 19 }, // 208
    .{ .code = 0x1fffe3, .bits = 21 }, // 209
    .{ .code = 0x3ffffe6, .bits = 26 }, // 210
    .{ .code = 0x7ffffe0, .bits = 27 }, // 211
    .{ .code = 0x7ffffe1, .bits = 27 }, // 212
    .{ .code = 0x3ffffe7, .bits = 26 }, // 213
    .{ .code = 0x7ffffe2, .bits = 27 }, // 214
    .{ .code = 0xfffff2, .bits = 24 }, // 215
    .{ .code = 0x1fffe4, .bits = 21 }, // 216
    .{ .code = 0x1fffe5, .bits = 21 }, // 217
    .{ .code = 0x3ffffe8, .bits = 26 }, // 218
    .{ .code = 0x3ffffe9, .bits = 26 }, // 219
    .{ .code = 0xffffffd, .bits = 28 }, // 220
    .{ .code = 0x7ffffe3, .bits = 27 }, // 221
    .{ .code = 0x7ffffe4, .bits = 27 }, // 222
    .{ .code = 0x7ffffe5, .bits = 27 }, // 223
    .{ .code = 0xfffec, .bits = 20 }, // 224
    .{ .code = 0xfffff3, .bits = 24 }, // 225
    .{ .code = 0xfffed, .bits = 20 }, // 226
    .{ .code = 0x1fffe6, .bits = 21 }, // 227
    .{ .code = 0x3fffe9, .bits = 22 }, // 228
    .{ .code = 0x1fffe7, .bits = 21 }, // 229
    .{ .code = 0x1fffe8, .bits = 21 }, // 230
    .{ .code = 0x7ffff3, .bits = 23 }, // 231
    .{ .code = 0x3fffea, .bits = 22 }, // 232
    .{ .code = 0x3fffeb, .bits = 22 }, // 233
    .{ .code = 0x1ffffee, .bits = 25 }, // 234
    .{ .code = 0x1ffffef, .bits = 25 }, // 235
    .{ .code = 0xfffff4, .bits = 24 }, // 236
    .{ .code = 0xfffff5, .bits = 24 }, // 237
    .{ .code = 0x3ffffea, .bits = 26 }, // 238
    .{ .code = 0x7ffff4, .bits = 23 }, // 239
    .{ .code = 0x3ffffeb, .bits = 26 }, // 240
    .{ .code = 0x7ffffe6, .bits = 27 }, // 241
    .{ .code = 0x3ffffec, .bits = 26 }, // 242
    .{ .code = 0x3ffffed, .bits = 26 }, // 243
    .{ .code = 0x7ffffe7, .bits = 27 }, // 244
    .{ .code = 0x7ffffe8, .bits = 27 }, // 245
    .{ .code = 0x7ffffe9, .bits = 27 }, // 246
    .{ .code = 0x7ffffea, .bits = 27 }, // 247
    .{ .code = 0x7ffffeb, .bits = 27 }, // 248
    .{ .code = 0xffffffe, .bits = 28 }, // 249
    .{ .code = 0x7ffffec, .bits = 27 }, // 250
    .{ .code = 0x7ffffed, .bits = 27 }, // 251
    .{ .code = 0x7ffffee, .bits = 27 }, // 252
    .{ .code = 0x7ffffef, .bits = 27 }, // 253
    .{ .code = 0x7fffff0, .bits = 27 }, // 254
    .{ .code = 0x3ffffee, .bits = 26 }, // 255
};

// EOS Huffman code: 0x3fffffff (30 bits)
const HUFF_EOS_CODE: u32 = 0x3fffffff;
const HUFF_EOS_BITS: u5 = 30;

/// Decode a Huffman-encoded byte string into out_buf.
/// Returns the number of decoded bytes.
pub fn huffDecode(src: []const u8, out: []u8) !usize {
    var acc: u64 = 0; // bit accumulator (up to 30 bits needed)
    var bits: u8 = 0; // valid bits in acc (MSB side)
    var out_pos: usize = 0;

    for (src) |byte| {
        acc = (acc << 8) | byte;
        bits += 8;
        while (bits >= 5) {
            var matched = false;
            for (HUFF, 0..) |sym, sym_idx| {
                if (bits < sym.bits) continue;
                const shift: u6 = @intCast(bits - sym.bits);
                const extracted: u32 = @intCast((acc >> shift) & (@as(u64, 1) << sym.bits) - 1);
                if (extracted == sym.code) {
                    if (out_pos >= out.len) return error.OutputTooSmall;
                    out[out_pos] = @intCast(sym_idx);
                    out_pos += 1;
                    acc &= (@as(u64, 1) << shift) - 1;
                    bits -= sym.bits;
                    matched = true;
                    break;
                }
            }
            if (!matched) break;
        }
    }
    // Remaining bits must be EOS padding (all 1s, up to 7 bits).
    if (bits > 7) return error.InvalidHuffman;
    return out_pos;
}

/// Encode src into out using HPACK Huffman. Returns bytes written.
pub fn huffEncode(src: []const u8, out: []u8) !usize {
    var acc: u64 = 0;
    var bits: u8 = 0;
    var pos: usize = 0;

    for (src) |byte| {
        const sym = HUFF[byte];
        acc = (acc << sym.bits) | sym.code;
        bits += sym.bits;
        while (bits >= 8) {
            bits -= 8;
            if (pos >= out.len) return error.OutputTooSmall;
            out[pos] = @intCast((acc >> @as(u6, @intCast(bits))) & 0xFF);
            pos += 1;
        }
    }
    if (bits > 0) {
        // Pad with EOS bits (all 1s).
        const pad_bits: u6 = @intCast(8 - bits);
        const padded: u8 = @intCast(((acc << pad_bits) | ((@as(u64, 1) << pad_bits) - 1)) & 0xFF);
        if (pos >= out.len) return error.OutputTooSmall;
        out[pos] = padded;
        pos += 1;
    }
    return pos;
}

// ------------------------------------------------------------------ //
// HPACK decode                                                        //
// ------------------------------------------------------------------ //

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const HpackDecoder = struct {
    // Dynamic table: stored as ring of (name, value) pairs in a scratch buffer.
    // For the PoC: no dynamic table eviction tracking — just a flat list.
    dyn: [128]HpackEntry = undefined,
    dyn_count: usize = 0,
    dyn_size: usize = 0, // current byte size (name.len + value.len + 32 per RFC)
    max_size: usize = 4096, // SETTINGS_HEADER_TABLE_SIZE default

    pub fn init() HpackDecoder {
        return .{};
    }

    fn staticEntry(idx: usize) ?HpackEntry {
        if (idx == 0 or idx > 61) return null;
        return HPACK_STATIC[idx];
    }

    fn dynEntry(self: *const HpackDecoder, idx: usize) ?HpackEntry {
        // idx 1-based within dynamic table
        if (idx == 0 or idx > self.dyn_count) return null;
        return self.dyn[idx - 1];
    }

    fn getEntry(self: *const HpackDecoder, idx: usize) ?HpackEntry {
        if (idx <= 61) return staticEntry(idx);
        return self.dynEntry(idx - 61);
    }

    fn evictTo(self: *HpackDecoder, target: usize) void {
        while (self.dyn_count > 0 and self.dyn_size > target) {
            const last = self.dyn[self.dyn_count - 1];
            self.dyn_size -= last.name.len + last.value.len + 32;
            self.dyn_count -= 1;
        }
    }

    fn addDynamic(self: *HpackDecoder, name: []const u8, value: []const u8) void {
        const entry_size = name.len + value.len + 32;
        if (entry_size > self.max_size) {
            self.evictTo(0); // entry too large — evict all, don't add
            return;
        }
        self.evictTo(self.max_size - entry_size);
        if (self.dyn_count >= 128) return; // hard cap for PoC
        var i: usize = self.dyn_count;
        while (i > 0) : (i -= 1) self.dyn[i] = self.dyn[i - 1];
        self.dyn[0] = .{ .name = name, .value = value };
        self.dyn_count += 1;
        self.dyn_size += entry_size;
    }

    /// Decode one integer from src at bit offset. RFC 7541 5.1.
    fn decodeInt(src: []const u8, pos: *usize, prefix_bits: u3) !u64 {
        if (pos.* >= src.len) return error.UnexpectedEOF;
        const mask: u8 = (@as(u8, 1) << prefix_bits) - 1;
        var val: u64 = src[pos.*] & mask;
        pos.* += 1;
        if (val < mask) return val;
        var shift: u6 = 0;
        while (true) {
            if (pos.* >= src.len) return error.UnexpectedEOF;
            const b = src[pos.*];
            pos.* += 1;
            val += (@as(u64, b & 0x7F)) << shift;
            shift += 7;
            if ((b & 0x80) == 0) break;
            if (shift > 56) return error.IntegerOverflow;
        }
        return val;
    }

    /// Decode one HPACK string (length-prefixed, optional Huffman). Uses scratch for decoded bytes.
    fn decodeString(src: []const u8, pos: *usize, scratch: []u8, scratch_pos: *usize) ![]const u8 {
        if (pos.* >= src.len) return error.UnexpectedEOF;
        const hbit = (src[pos.*] & 0x80) != 0;
        const slen: usize = @intCast(try decodeInt(src, pos, 7));
        if (pos.* + slen > src.len) return error.UnexpectedEOF;
        const raw = src[pos.*..][0..slen];
        pos.* += slen;
        if (!hbit) {
            if (scratch_pos.* + slen > scratch.len) return error.ScratchFull;
            @memcpy(scratch[scratch_pos.*..][0..slen], raw);
            const out = scratch[scratch_pos.*..][0..slen];
            scratch_pos.* += slen;
            return out;
        }
        // Huffman decode.
        const out_start = scratch_pos.*;
        const available = scratch.len - out_start;
        if (available == 0) return error.ScratchFull;
        const n = try huffDecode(raw, scratch[out_start..]);
        const out = scratch[out_start..][0..n];
        scratch_pos.* += n;
        return out;
    }

    /// Decode a HPACK header block into out. Uses scratch buffer for string storage.
    /// Returned Header slices point into scratch or into static table string literals.
    pub fn decode(
        self: *HpackDecoder,
        block: []const u8,
        out: []Header,
        scratch: []u8,
    ) !usize {
        var pos: usize = 0;
        var n_out: usize = 0;
        var scratch_pos: usize = 0;

        while (pos < block.len) {
            if (n_out >= out.len) return error.TooManyHeaders;
            const first = block[pos];

            if ((first & 0x80) != 0) {
                // Indexed header field (7-bit index).
                const idx: usize = @intCast(try decodeInt(block, &pos, 7));
                const entry = self.getEntry(idx) orelse return error.InvalidIndex;
                out[n_out] = .{ .name = entry.name, .value = entry.value };
                n_out += 1;
            } else if ((first & 0x40) != 0) {
                // Literal with incremental indexing (6-bit name index).
                const idx: usize = @intCast(try decodeInt(block, &pos, 6));
                const name = if (idx == 0) blk: {
                    break :blk try decodeString(block, &pos, scratch, &scratch_pos);
                } else blk: {
                    const entry = self.getEntry(idx) orelse return error.InvalidIndex;
                    break :blk entry.name;
                };
                const value = try decodeString(block, &pos, scratch, &scratch_pos);
                self.addDynamic(name, value);
                out[n_out] = .{ .name = name, .value = value };
                n_out += 1;
            } else if ((first & 0x20) != 0) {
                // Dynamic table size update (5-bit max size).
                const new_max: usize = @intCast(try decodeInt(block, &pos, 5));
                self.max_size = new_max;
                self.evictTo(new_max);
            } else {
                // Literal without indexing or never-indexed (4-bit name index).
                _ = (first & 0x10) != 0; // never-indexed flag — ignored for PoC
                const idx: usize = @intCast(try decodeInt(block, &pos, 4));
                const name = if (idx == 0) blk: {
                    break :blk try decodeString(block, &pos, scratch, &scratch_pos);
                } else blk: {
                    const entry = self.getEntry(idx) orelse return error.InvalidIndex;
                    break :blk entry.name;
                };
                const value = try decodeString(block, &pos, scratch, &scratch_pos);
                out[n_out] = .{ .name = name, .value = value };
                n_out += 1;
            }
        }
        return n_out;
    }
};

// ------------------------------------------------------------------ //
// HPACK encode (literal without indexing, Huffman strings)           //
// ------------------------------------------------------------------ //

pub const HpackEncoder = struct {
    buf: []u8,
    pos: usize,

    pub fn init(buf: []u8) HpackEncoder {
        return .{ .buf = buf, .pos = 0 };
    }

    pub fn encoded(self: *const HpackEncoder) []const u8 {
        return self.buf[0..self.pos];
    }

    fn writeInt(self: *HpackEncoder, val: u64, prefix_bits: u3, first_byte_high: u8) !void {
        const mask: u64 = (@as(u64, 1) << prefix_bits) - 1;
        if (val < mask) {
            if (self.pos >= self.buf.len) return error.BufferFull;
            self.buf[self.pos] = first_byte_high | @as(u8, @intCast(val));
            self.pos += 1;
            return;
        }
        if (self.pos >= self.buf.len) return error.BufferFull;
        self.buf[self.pos] = first_byte_high | @as(u8, @intCast(mask));
        self.pos += 1;
        var rem = val - mask;
        while (rem >= 0x80) {
            if (self.pos >= self.buf.len) return error.BufferFull;
            self.buf[self.pos] = @intCast((rem & 0x7F) | 0x80);
            self.pos += 1;
            rem >>= 7;
        }
        if (self.pos >= self.buf.len) return error.BufferFull;
        self.buf[self.pos] = @intCast(rem);
        self.pos += 1;
    }

    fn writeString(self: *HpackEncoder, s: []const u8) !void {
        var hbuf: [256]u8 = undefined;
        const hn = huffEncode(s, &hbuf) catch null;
        if (hn != null and hn.? < s.len) {
            // Huffman is shorter: write with H=1.
            try self.writeInt(hn.?, 7, 0x80);
            if (self.pos + hn.? > self.buf.len) return error.BufferFull;
            @memcpy(self.buf[self.pos..][0..hn.?], hbuf[0..hn.?]);
            self.pos += hn.?;
        } else {
            // Literal: H=0.
            try self.writeInt(s.len, 7, 0x00);
            if (self.pos + s.len > self.buf.len) return error.BufferFull;
            @memcpy(self.buf[self.pos..][0..s.len], s);
            self.pos += s.len;
        }
    }

    /// Encode a header as indexed (from static table), or literal without indexing.
    pub fn writeHeader(self: *HpackEncoder, name: []const u8, value: []const u8) !void {
        // Check static table for exact match.
        for (HPACK_STATIC[1..], 1..) |entry, i| {
            if (std.ascii.eqlIgnoreCase(entry.name, name) and
                std.mem.eql(u8, entry.value, value))
            {
                try self.writeInt(i, 7, 0x80);
                return;
            }
        }
        // Literal without indexing (0x00 prefix, 4-bit name index).
        // Check for name-only match in static table.
        for (HPACK_STATIC[1..], 1..) |entry, i| {
            if (std.ascii.eqlIgnoreCase(entry.name, name)) {
                try self.writeInt(i, 4, 0x00);
                try self.writeString(value);
                return;
            }
        }
        // No match: name + value both literal.
        try self.writeInt(0, 4, 0x00);
        try self.writeString(name);
        try self.writeString(value);
    }
};

// ------------------------------------------------------------------ //
// Frame write helpers                                                 //
// ------------------------------------------------------------------ //

pub fn sendSettings(fd: std.posix.fd_t, params: []const [2]u32) !void {
    const payload_len: usize = params.len * 6;
    try writeFrameHeader(fd, .{
        .length = @intCast(payload_len),
        .frame_type = FT_SETTINGS,
        .flags = 0,
        .stream_id = 0,
    });
    var buf: [6]u8 = undefined;
    for (params) |p| {
        const id: u16 = @intCast(p[0]);
        const val: u32 = p[1];
        buf[0] = @intCast((id >> 8) & 0xFF);
        buf[1] = @intCast(id & 0xFF);
        buf[2] = @intCast((val >> 24) & 0xFF);
        buf[3] = @intCast((val >> 16) & 0xFF);
        buf[4] = @intCast((val >> 8) & 0xFF);
        buf[5] = @intCast(val & 0xFF);
        try fdWriteAll(fd, &buf);
    }
}

pub fn sendSettingsAck(fd: std.posix.fd_t) !void {
    try writeFrameHeader(fd, .{
        .length = 0,
        .frame_type = FT_SETTINGS,
        .flags = FLAG_ACK,
        .stream_id = 0,
    });
}

pub fn sendPingAck(fd: std.posix.fd_t, payload: [8]u8) !void {
    try writeFrameHeader(fd, .{
        .length = 8,
        .frame_type = FT_PING,
        .flags = FLAG_ACK,
        .stream_id = 0,
    });
    try fdWriteAll(fd, &payload);
}

pub fn sendGoaway(fd: std.posix.fd_t, last_stream: u31, error_code: u32) !void {
    try writeFrameHeader(fd, .{
        .length = 8,
        .frame_type = FT_GOAWAY,
        .flags = 0,
        .stream_id = 0,
    });
    var buf: [8]u8 = undefined;
    const ls: u32 = last_stream;
    buf[0] = @intCast((ls >> 24) & 0xFF);
    buf[1] = @intCast((ls >> 16) & 0xFF);
    buf[2] = @intCast((ls >> 8) & 0xFF);
    buf[3] = @intCast(ls & 0xFF);
    buf[4] = @intCast((error_code >> 24) & 0xFF);
    buf[5] = @intCast((error_code >> 16) & 0xFF);
    buf[6] = @intCast((error_code >> 8) & 0xFF);
    buf[7] = @intCast(error_code & 0xFF);
    try fdWriteAll(fd, &buf);
}

pub fn sendRstStream(fd: std.posix.fd_t, stream_id: u31, error_code: u32) !void {
    try writeFrameHeader(fd, .{
        .length = 4,
        .frame_type = FT_RST_STREAM,
        .flags = 0,
        .stream_id = stream_id,
    });
    var buf: [4]u8 = undefined;
    buf[0] = @intCast((error_code >> 24) & 0xFF);
    buf[1] = @intCast((error_code >> 16) & 0xFF);
    buf[2] = @intCast((error_code >> 8) & 0xFF);
    buf[3] = @intCast(error_code & 0xFF);
    try fdWriteAll(fd, &buf);
}

pub fn sendWindowUpdate(fd: std.posix.fd_t, stream_id: u31, increment: u31) !void {
    try writeFrameHeader(fd, .{
        .length = 4,
        .frame_type = FT_WINDOW_UPDATE,
        .flags = 0,
        .stream_id = stream_id,
    });
    var buf: [4]u8 = undefined;
    const inc: u32 = increment;
    buf[0] = @intCast((inc >> 24) & 0xFF);
    buf[1] = @intCast((inc >> 16) & 0xFF);
    buf[2] = @intCast((inc >> 8) & 0xFF);
    buf[3] = @intCast(inc & 0xFF);
    try fdWriteAll(fd, &buf);
}

/// Send HEADERS + optional DATA for a response.
pub fn sendResponse(
    fd: std.posix.fd_t,
    stream_id: u31,
    status: u16,
    content_type: []const u8,
    body: []const u8,
) !void {
    var hdr_buf: [512]u8 = undefined;
    var enc = HpackEncoder.init(&hdr_buf);

    // :status pseudo-header.
    var status_str: [4]u8 = undefined;
    const status_s = std.fmt.bufPrint(&status_str, "{d}", .{status}) catch "200";
    try enc.writeHeader(":status", status_s);
    if (content_type.len > 0)
        try enc.writeHeader("content-type", content_type);
    if (body.len > 0) {
        var cl_buf: [20]u8 = undefined;
        const cl_s = std.fmt.bufPrint(&cl_buf, "{d}", .{body.len}) catch "0";
        try enc.writeHeader("content-length", cl_s);
    }

    const hblock = enc.encoded();
    const end_stream_flag: u8 = if (body.len == 0) FLAG_END_STREAM | FLAG_END_HEADERS else FLAG_END_HEADERS;

    try writeFrameHeader(fd, .{
        .length = @intCast(hblock.len),
        .frame_type = FT_HEADERS,
        .flags = end_stream_flag,
        .stream_id = stream_id,
    });
    try fdWriteAll(fd, hblock);

    if (body.len > 0) {
        try writeFrameHeader(fd, .{
            .length = @intCast(body.len),
            .frame_type = FT_DATA,
            .flags = FLAG_END_STREAM,
            .stream_id = stream_id,
        });
        try fdWriteAll(fd, body);
    }
}

// ------------------------------------------------------------------ //
// Stream state                                                        //
// ------------------------------------------------------------------ //

const StreamState = enum { IDLE, OPEN, HALF_CLOSED_REMOTE, CLOSED };

const Stream = struct {
    id: u31,
    state: StreamState,
    headers: [MAX_HEADERS]Header,
    header_count: usize,
    body: [65536]u8,
    body_len: usize,
    header_scratch: [4096]u8,
    end_headers: bool,
    end_stream: bool,
};

// ------------------------------------------------------------------ //
// Handler type and connection loop                                    //
// ------------------------------------------------------------------ //

pub const HandlerFn = *const fn (
    method: []const u8,
    path: []const u8,
    headers: []const Header,
    body: []const u8,
    fd: std.posix.fd_t,
    sid: u31,
) void;

/// h2c direct connection loop. Expects the client PRI preface immediately.
pub fn serveConn(stream: std.Io.net.Stream, io: std.Io, handler: HandlerFn) void {
    defer stream.close(io);
    const fd = stream.socket.handle;

    // Set TCP_NODELAY.
    if (comptime @import("builtin").target.os.tag != .windows) {
        std.posix.setsockopt(fd, std.posix.IPPROTO.TCP, std.posix.TCP.NODELAY, std.mem.asBytes(&@as(c_int, 1))) catch {};
    }

    serveConnInner(fd, handler) catch |err| {
        if (err != error.Closed and err != error.BrokenPipe)
            std.debug.print("h2: conn error: {}\n", .{err});
    };
}

fn serveConnInner(fd: std.posix.fd_t, handler: HandlerFn) !void {
    // Peek first 3 bytes to distinguish h2c direct (PRI) from h2c upgrade (HTTP/1.1).
    var peek: [3]u8 = undefined;
    try recvExact(fd, &peek);

    if (std.mem.eql(u8, &peek, "PRI")) {
        var rest: [21]u8 = undefined;
        try recvExact(fd, &rest);
        var preface: [24]u8 = undefined;
        @memcpy(preface[0..3], &peek);
        @memcpy(preface[3..], &rest);
        if (!std.mem.eql(u8, &preface, PREFACE)) {
            sendGoaway(fd, 0, ERR_PROTOCOL_ERROR) catch {};
            return error.BadPreface;
        }
        try sendSettings(fd, &.{
            .{ SETTINGS_MAX_CONCURRENT_STREAMS, 128 },
            .{ SETTINGS_INITIAL_WINDOW_SIZE, 65535 },
            .{ SETTINGS_MAX_FRAME_SIZE, MAX_PAYLOAD },
            .{ SETTINGS_ENABLE_PUSH, 0 },
        });
        var hpack = HpackDecoder.init();
        try serveH2cLoop(fd, &hpack, handler, 0);
    } else {
        try serveH2cUpgrade(fd, handler, &peek);
    }
}

fn getHttp1Header(buf: []const u8, name: []const u8) ?[]const u8 {
    const first_crlf = std.mem.indexOf(u8, buf, "\r\n") orelse return null;
    var pos = first_crlf + 2;
    while (pos < buf.len) {
        const line_end = std.mem.indexOfPos(u8, buf, pos, "\r\n") orelse break;
        const line = buf[pos..line_end];
        if (line.len == 0) break;
        if (std.mem.indexOfScalar(u8, line, ':')) |colon| {
            if (std.ascii.eqlIgnoreCase(line[0..colon], name)) {
                var vs: usize = colon + 1;
                while (vs < line.len and line[vs] == ' ') vs += 1;
                return line[vs..];
            }
        }
        pos = line_end + 2;
    }
    return null;
}

fn serveH2cUpgrade(fd: std.posix.fd_t, handler: HandlerFn, prefix: *const [3]u8) !void {
    // Read HTTP/1.1 headers (prefix holds first 3 bytes already consumed).
    var head_buf: [8192]u8 = undefined;
    var filled: usize = 3;
    @memcpy(head_buf[0..3], prefix);
    while (std.mem.indexOf(u8, head_buf[0..filled], "\r\n\r\n") == null) {
        if (filled >= head_buf.len) return error.HeaderTooLarge;
        const n = std.posix.read(fd, head_buf[filled..]) catch return error.Closed;
        if (n == 0) return error.Closed;
        filled += n;
    }
    const hdr_end = std.mem.indexOf(u8, head_buf[0..filled], "\r\n\r\n").? + 4;

    // Require Upgrade: h2c.
    const upgrade = getHttp1Header(head_buf[0..hdr_end], "upgrade") orelse {
        fdWriteAll(fd, "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n") catch {};
        return error.BadRequest;
    };
    if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, upgrade, " "), "h2c")) {
        fdWriteAll(fd, "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n") catch {};
        return error.BadRequest;
    }

    // Parse method and path from the request line for stream 1 dispatch.
    var method: []const u8 = "GET";
    var path: []const u8 = "/";
    if (std.mem.indexOfScalar(u8, head_buf[0..hdr_end], ' ')) |sp1| {
        method = head_buf[0..sp1];
        const after = head_buf[sp1 + 1 .. hdr_end];
        if (std.mem.indexOfScalar(u8, after, ' ')) |sp2| path = after[0..sp2];
    }

    // Send 101 Switching Protocols.
    try fdWriteAll(
        fd,
        "HTTP/1.1 101 Switching Protocols\r\n" ++
            "Connection: Upgrade\r\nUpgrade: h2c\r\n\r\n",
    );

    // Read client's connection preface (sent by client after receiving 101).
    var preface: [24]u8 = undefined;
    try recvExact(fd, &preface);
    if (!std.mem.eql(u8, &preface, PREFACE)) {
        sendGoaway(fd, 0, ERR_PROTOCOL_ERROR) catch {};
        return error.BadPreface;
    }

    // Initialize HPACK; apply client's HTTP2-Settings header if present.
    var hpack = HpackDecoder.init();
    if (getHttp1Header(head_buf[0..hdr_end], "http2-settings")) |b64| {
        const trimmed = std.mem.trim(u8, b64, " ");
        var decoded: [256]u8 = undefined;
        const dlen = std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(trimmed) catch 0;
        if (dlen > 0 and dlen <= decoded.len) {
            std.base64.url_safe_no_pad.Decoder.decode(decoded[0..dlen], trimmed) catch {};
            var i: usize = 0;
            while (i + 6 <= dlen) : (i += 6) {
                const id: u16 = (@as(u16, decoded[i]) << 8) | decoded[i + 1];
                const val: u32 = (@as(u32, decoded[i + 2]) << 24) | (@as(u32, decoded[i + 3]) << 16) |
                    (@as(u32, decoded[i + 4]) << 8) | decoded[i + 5];
                if (id == SETTINGS_HEADER_TABLE_SIZE) {
                    hpack.max_size = val;
                    hpack.evictTo(val);
                }
            }
        }
    }

    // Send server's SETTINGS.
    try sendSettings(fd, &.{
        .{ SETTINGS_MAX_CONCURRENT_STREAMS, 128 },
        .{ SETTINGS_INITIAL_WINDOW_SIZE, 65535 },
        .{ SETTINGS_MAX_FRAME_SIZE, MAX_PAYLOAD },
        .{ SETTINGS_ENABLE_PUSH, 0 },
    });

    // Dispatch stream 1 (the upgrade request — half-closed remote, no body).
    var s1_hdrs = [3]Header{
        .{ .name = ":method", .value = method },
        .{ .name = ":path", .value = path },
        .{ .name = ":scheme", .value = "http" },
    };
    handler(method, path, &s1_hdrs, &.{}, fd, 1);

    // Continue frame loop; stream IDs now start from 3.
    try serveH2cLoop(fd, &hpack, handler, 1);
}

fn serveH2cLoop(fd: std.posix.fd_t, hpack: *HpackDecoder, handler: HandlerFn, initial_last_stream: u31) !void {
    var payload_buf: [MAX_PAYLOAD + 256]u8 = undefined;

    // Heap-allocate the stream table — each Stream is ~70 KB (64 KB body buffer).
    const streams = try std.heap.smp_allocator.alloc(Stream, 16);
    defer std.heap.smp_allocator.free(streams);
    var stream_slots: [16]bool = .{false} ** 16;

    var last_stream_id: u31 = initial_last_stream;

    while (true) {
        const fh = try readFrameHeader(fd);

        if (fh.length > MAX_PAYLOAD + 256) {
            sendGoaway(fd, last_stream_id, ERR_FRAME_SIZE_ERROR) catch {};
            return error.FrameTooLarge;
        }

        const payload = payload_buf[0..fh.length];
        if (fh.length > 0) try recvExact(fd, payload);

        switch (fh.frame_type) {
            FT_SETTINGS => {
                if ((fh.flags & FLAG_ACK) != 0) continue;
                var i: usize = 0;
                while (i + 6 <= payload.len) : (i += 6) {
                    const id: u16 = (@as(u16, payload[i]) << 8) | payload[i + 1];
                    const val: u32 = (@as(u32, payload[i + 2]) << 24) | (@as(u32, payload[i + 3]) << 16) |
                        (@as(u32, payload[i + 4]) << 8) | payload[i + 5];
                    if (id == SETTINGS_HEADER_TABLE_SIZE) {
                        hpack.max_size = val;
                        hpack.evictTo(val);
                    }
                }
                try sendSettingsAck(fd);
                try sendWindowUpdate(fd, 0, 65535);
            },

            FT_WINDOW_UPDATE => {},

            FT_PING => {
                if ((fh.flags & FLAG_ACK) != 0) continue;
                if (payload.len != 8) {
                    sendGoaway(fd, last_stream_id, ERR_FRAME_SIZE_ERROR) catch {};
                    return error.ProtocolError;
                }
                var p8: [8]u8 = undefined;
                @memcpy(&p8, payload[0..8]);
                try sendPingAck(fd, p8);
            },

            FT_HEADERS => {
                const sid = fh.stream_id;
                if (sid == 0) {
                    sendGoaway(fd, last_stream_id, ERR_PROTOCOL_ERROR) catch {};
                    return error.ProtocolError;
                }
                if (sid <= last_stream_id and sid % 2 == 1) {
                    sendRstStream(fd, sid, ERR_STREAM_CLOSED) catch {};
                    continue;
                }
                last_stream_id = @max(last_stream_id, sid);

                const slot = slotFor(sid, streams, &stream_slots) orelse {
                    sendRstStream(fd, sid, ERR_REFUSED_STREAM) catch {};
                    continue;
                };
                const s = &streams[slot];
                s.* = std.mem.zeroes(Stream);
                s.id = sid;
                s.state = .OPEN;

                var block = payload;
                var offset: usize = 0;
                var pad_len: usize = 0;
                if ((fh.flags & FLAG_PADDED) != 0 and block.len > 0) {
                    pad_len = block[0];
                    offset = 1;
                }
                if ((fh.flags & FLAG_PRIORITY) != 0 and offset + 5 <= block.len) {
                    offset += 5;
                }
                if (pad_len + offset > block.len) {
                    sendGoaway(fd, last_stream_id, ERR_PROTOCOL_ERROR) catch {};
                    return error.ProtocolError;
                }
                block = block[offset .. block.len - pad_len];

                s.header_count = hpack.decode(block, &s.headers, &s.header_scratch) catch |e| {
                    std.debug.print("h2: hpack decode error: {}\n", .{e});
                    sendRstStream(fd, sid, ERR_COMPRESSION_ERROR) catch {};
                    stream_slots[slot] = false;
                    continue;
                };
                s.end_headers = (fh.flags & FLAG_END_HEADERS) != 0;
                s.end_stream = (fh.flags & FLAG_END_STREAM) != 0;

                if (s.end_headers and s.end_stream) {
                    dispatchStream(s, handler, fd);
                    stream_slots[slot] = false;
                }
            },

            FT_CONTINUATION => {
                const sid = fh.stream_id;
                const slot = findSlot(sid, streams, &stream_slots) orelse {
                    sendGoaway(fd, last_stream_id, ERR_PROTOCOL_ERROR) catch {};
                    return error.ProtocolError;
                };
                const s = &streams[slot];
                const count = hpack.decode(payload, s.headers[s.header_count..], &s.header_scratch) catch {
                    sendRstStream(fd, sid, ERR_COMPRESSION_ERROR) catch {};
                    stream_slots[slot] = false;
                    continue;
                };
                s.header_count += count;
                s.end_headers = (fh.flags & FLAG_END_HEADERS) != 0;
                if (s.end_headers and s.end_stream) {
                    dispatchStream(s, handler, fd);
                    stream_slots[slot] = false;
                }
            },

            FT_DATA => {
                const sid = fh.stream_id;
                if (sid == 0) {
                    sendGoaway(fd, last_stream_id, ERR_PROTOCOL_ERROR) catch {};
                    return error.ProtocolError;
                }
                const slot = findSlot(sid, streams, &stream_slots) orelse {
                    sendRstStream(fd, sid, ERR_STREAM_CLOSED) catch {};
                    continue;
                };
                const s = &streams[slot];

                var data = payload;
                var pad_len: usize = 0;
                if ((fh.flags & FLAG_PADDED) != 0 and data.len > 0) {
                    pad_len = data[0];
                    data = data[1..];
                }
                if (pad_len > data.len) {
                    sendGoaway(fd, last_stream_id, ERR_PROTOCOL_ERROR) catch {};
                    return error.ProtocolError;
                }
                data = data[0 .. data.len - pad_len];

                if (data.len > 0) {
                    sendWindowUpdate(fd, 0, @intCast(data.len)) catch {};
                    sendWindowUpdate(fd, sid, @intCast(data.len)) catch {};
                }

                const to_copy = @min(data.len, s.body.len - s.body_len);
                @memcpy(s.body[s.body_len..][0..to_copy], data[0..to_copy]);
                s.body_len += to_copy;

                s.end_stream = (fh.flags & FLAG_END_STREAM) != 0;
                if (s.end_stream) {
                    dispatchStream(s, handler, fd);
                    stream_slots[slot] = false;
                }
            },

            FT_RST_STREAM => {
                const sid = fh.stream_id;
                if (findSlot(sid, streams, &stream_slots)) |slot| {
                    stream_slots[slot] = false;
                }
            },

            FT_GOAWAY => {
                return;
            },

            FT_PRIORITY => {},

            else => {},
        }
    }
}

fn slotFor(sid: u31, streams: []Stream, used: []bool) ?usize {
    for (used, 0..) |u, i| {
        if (!u) {
            used[i] = true;
            streams[i].id = sid;
            return i;
        }
    }
    return null;
}

fn findSlot(sid: u31, streams: []Stream, used: []bool) ?usize {
    for (used, 0..) |u, i| {
        if (u and streams[i].id == sid) return i;
    }
    return null;
}

fn dispatchStream(s: *Stream, handler: HandlerFn, fd: std.posix.fd_t) void {
    var method: []const u8 = "GET";
    var path: []const u8 = "/";
    for (s.headers[0..s.header_count]) |h| {
        if (std.mem.eql(u8, h.name, ":method")) method = h.value;
        if (std.mem.eql(u8, h.name, ":path")) path = h.value;
    }
    handler(method, path, s.headers[0..s.header_count], s.body[0..s.body_len], fd, s.id);
}
