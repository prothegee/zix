//! zix http websocket client
//! RFC 6455 client: HTTP upgrade handshake, masked send, unmasked recv.

const std = @import("std");

// --------------------------------------------------------- //

const ws_len_max_7bit = 125;
const ws_len_16bit_marker = 126;
const ws_len_64bit_marker = 127;
const ws_len_max_16bit = std.math.maxInt(u16);
const ws_mask_len: usize = 4;
const ws_len_64bit_field_size: usize = 8;
const ws_max_frame_header: usize = 14;

// --------------------------------------------------------- //

/// RFC 6455 5.2 WebSocket opcodes.
pub const Opcode = enum(u8) {
    continuation = 0x0,
    text = 0x1,
    binary = 0x2,
    close = 0x8,
    ping = 0x9,
    pong = 0xA,
    _,
};

/// Received WebSocket frame. payload points into the caller-supplied buffer.
pub const Frame = struct {
    fin: bool,
    opcode: Opcode,
    payload: []const u8,
};

// --------------------------------------------------------- //

/// Configuration for a WebSocket client.
pub const WsClientConfig = struct {
    /// Event-loop backend. Caller owns and must outlive the client.
    io: std.Io,
    /// TCP connect timeout in milliseconds. 0 = no timeout.
    connect_timeout_ms: u32 = 0,
};

// --------------------------------------------------------- //

/// Active WebSocket connection after a successful upgrade handshake.
/// Call deinit() to close.
pub const WsConn = struct {
    const Self = @This();

    fd: std.posix.fd_t,

    // --------------------------------------------------------- //

    /// Send a masked client-to-server frame (RFC 6455 5.1 mandates masking).
    ///
    /// Note:
    /// - A fresh 4-byte random mask is generated per call.
    /// - Large payloads are written in 4096-byte chunks to avoid large stack copies.
    ///
    /// Param:
    /// opcode  - Opcode
    /// payload - []const u8
    ///
    /// Return:
    /// - !void
    pub fn send(self: Self, opcode: Opcode, payload: []const u8) !void {
        var mask_key: [ws_mask_len]u8 = undefined;
        _ = std.os.linux.getrandom(&mask_key, mask_key.len, 0);

        var header: [ws_max_frame_header]u8 = undefined;
        var header_len: usize = 0;

        header[header_len] = 0x80 | @intFromEnum(opcode);
        header_len += 1;

        if (payload.len <= ws_len_max_7bit) {
            header[header_len] = 0x80 | @as(u8, @intCast(payload.len));
            header_len += 1;
        } else if (payload.len <= ws_len_max_16bit) {
            header[header_len] = 0x80 | ws_len_16bit_marker;
            header[header_len + 1] = @intCast((payload.len >> 8) & 0xFF);
            header[header_len + 2] = @intCast(payload.len & 0xFF);
            header_len += 3;
        } else {
            header[header_len] = 0x80 | ws_len_64bit_marker;
            for (0..ws_len_64bit_field_size) |i| {
                const shift: u6 = @intCast((7 - i) * 8);
                header[header_len + 1 + i] = @intCast((payload.len >> shift) & 0xFF);
            }
            header_len += 1 + ws_len_64bit_field_size;
        }

        @memcpy(header[header_len..][0..ws_mask_len], &mask_key);
        header_len += ws_mask_len;

        try fdWriteAll(self.fd, header[0..header_len]);

        var byte_offset: usize = 0;
        var chunk: [4096]u8 = undefined;

        while (byte_offset < payload.len) {
            const batch_size = @min(payload.len - byte_offset, chunk.len);
            for (0..batch_size) |i| chunk[i] = payload[byte_offset + i] ^ mask_key[(byte_offset + i) % ws_mask_len];
            try fdWriteAll(self.fd, chunk[0..batch_size]);
            byte_offset += batch_size;
        }
    }

    /// Receive one server-to-client frame (unmasked per RFC 6455 5.1).
    ///
    /// Note:
    /// - Blocks until a complete frame arrives.
    /// - payload_buf must be large enough for the expected payload.
    /// - null when the connection closes cleanly before the next frame header arrives.
    ///
    /// Param:
    /// payload_buf - []u8 (scratch for the frame payload)
    ///
    /// Return:
    /// - ?Frame
    /// - error.ConnectionClosed (EOF mid-frame)
    pub fn recv(self: Self, payload_buf: []u8) !?Frame {
        var header: [2]u8 = undefined;
        if (!try recvExact(self.fd, &header)) return null;

        const fin = (header[0] & 0x80) != 0;
        const opcode: Opcode = @enumFromInt(header[0] & 0x0F);
        const masked = (header[1] & 0x80) != 0;
        var payload_len: u64 = header[1] & 0x7F;

        if (payload_len == ws_len_16bit_marker) {
            var ext: [2]u8 = undefined;
            if (!try recvExact(self.fd, &ext)) return error.ConnectionClosed;
            payload_len = (@as(u64, ext[0]) << 8) | ext[1];
        } else if (payload_len == ws_len_64bit_marker) {
            var ext: [ws_len_64bit_field_size]u8 = undefined;
            if (!try recvExact(self.fd, &ext)) return error.ConnectionClosed;
            payload_len = 0;
            for (0..ws_len_64bit_field_size) |i| payload_len = (payload_len << 8) | ext[i];
        }

        var mask: [ws_mask_len]u8 = .{ 0, 0, 0, 0 };
        if (masked) {
            if (!try recvExact(self.fd, &mask)) return error.ConnectionClosed;
        }

        const capped_len: usize = @intCast(@min(payload_len, payload_buf.len));
        if (!try recvExact(self.fd, payload_buf[0..capped_len])) return error.ConnectionClosed;

        if (masked) {
            for (0..capped_len) |i| payload_buf[i] ^= mask[i % ws_mask_len];
        }

        return Frame{ .fin = fin, .opcode = opcode, .payload = payload_buf[0..capped_len] };
    }

    /// Close the underlying TCP connection.
    pub fn deinit(self: Self) void {
        _ = std.posix.system.close(self.fd);
    }
};

// --------------------------------------------------------- //

/// WebSocket client. Performs the RFC 6455 HTTP upgrade handshake and returns a WsConn.
///
/// Usage:
/// ```zig
/// var wsc = zix.Http.WsClient.init(.{ .io = process.io });
/// var conn = try wsc.connect("ws://127.0.0.1:9008/chat");
/// defer conn.deinit();
/// try conn.send(.text, "hello");
/// var buf: [4096]u8 = undefined;
/// if (try conn.recv(&buf)) |frame| {
///     std.debug.print("{s}\n", .{frame.payload});
/// }
/// ```
pub const WsClient = struct {
    const Self = @This();

    config: WsClientConfig,

    // --------------------------------------------------------- //

    /// Initialise the client. No connection is opened until connect() is called.
    pub fn init(config: WsClientConfig) Self {
        return .{ .config = config };
    }

    /// Connect to a WebSocket server and complete the RFC 6455 upgrade handshake.
    ///
    /// Note:
    /// - wss:// (TLS) is not yet supported.
    /// - Caller owns the returned WsConn and must call deinit() on it.
    ///
    /// Param:
    /// url - []const u8 (ws://host:port/path)
    ///
    /// Return:
    /// - WsConn
    /// - error.InvalidUrl (malformed URL or missing host)
    /// - error.TlsNotSupported (wss:// scheme)
    /// - error.HandshakeFailed (server did not send 101 or accept key mismatch)
    pub fn connect(self: Self, url: []const u8) !WsConn {
        const parsed = try parseWsUrl(url);

        const addr = try std.Io.net.IpAddress.resolve(self.config.io, parsed.host, parsed.port);
        const stream = try addr.connect(self.config.io, .{ .mode = .stream, .protocol = .tcp });
        const fd = stream.socket.handle;
        errdefer _ = std.posix.system.close(fd);

        var nonce: [16]u8 = undefined;
        _ = std.os.linux.getrandom(&nonce, nonce.len, 0);
        var key_buf: [24]u8 = undefined;
        const key_enc_len = std.base64.standard.Encoder.calcSize(16);
        const ws_key = std.base64.standard.Encoder.encode(key_buf[0..key_enc_len], &nonce);

        var req_buf: [512]u8 = undefined;
        const req = std.fmt.bufPrint(
            &req_buf,
            "GET {s} HTTP/1.1\r\n" ++
                "Host: {s}:{d}\r\n" ++
                "Upgrade: websocket\r\n" ++
                "Connection: Upgrade\r\n" ++
                "Sec-WebSocket-Key: {s}\r\n" ++
                "Sec-WebSocket-Version: 13\r\n" ++
                "\r\n",
            .{ parsed.path, parsed.host, parsed.port, ws_key },
        ) catch return error.HandshakeFailed;

        fdWriteAll(fd, req) catch return error.HandshakeFailed;

        var resp_buf: [4096]u8 = undefined;
        var resp_len: usize = 0;
        var header_end: usize = 0;

        while (resp_len < resp_buf.len) {
            const n = std.posix.read(fd, resp_buf[resp_len..]) catch return error.HandshakeFailed;
            if (n == 0) return error.HandshakeFailed;
            resp_len += n;
            if (std.mem.indexOf(u8, resp_buf[0..resp_len], "\r\n\r\n")) |pos| {
                header_end = pos + 4;
                break;
            }
        }

        if (header_end == 0) return error.HandshakeFailed;
        if (!std.mem.startsWith(u8, resp_buf[0..header_end], "HTTP/1.1 101")) return error.HandshakeFailed;

        var accept_out: [64]u8 = undefined;
        const expected_accept = acceptKey(ws_key, &accept_out) catch return error.HandshakeFailed;
        const server_accept = findHeader(resp_buf[0..header_end], "sec-websocket-accept") orelse return error.HandshakeFailed;

        if (!std.mem.eql(u8, std.mem.trim(u8, server_accept, " \t"), expected_accept)) {
            return error.HandshakeFailed;
        }

        return WsConn{ .fd = fd };
    }
};

// --------------------------------------------------------- //

/// Compute Sec-WebSocket-Accept from Sec-WebSocket-Key (RFC 6455 4.2.2).
///
/// Param:
/// key - []const u8 (base64-encoded 16-byte nonce)
/// out - *[64]u8 (caller buffer, result is a sub-slice)
///
/// Return:
/// - ![]const u8
pub fn acceptKey(key: []const u8, out: *[64]u8) ![]const u8 {
    // RFC 6455 1.3: this GUID is mandated by the spec, do not change it.
    const rfc6455_guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
    var hash_input: [128]u8 = undefined;
    if (key.len + rfc6455_guid.len > hash_input.len) return error.KeyTooLong;

    @memcpy(hash_input[0..key.len], key);
    @memcpy(hash_input[key.len..][0..rfc6455_guid.len], rfc6455_guid);

    var hash: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(hash_input[0 .. key.len + rfc6455_guid.len], &hash, .{});

    const enc_len = std.base64.standard.Encoder.calcSize(20);

    return std.base64.standard.Encoder.encode(out[0..enc_len], &hash);
}

// --------------------------------------------------------- //

const WsUrlParsed = struct { host: []const u8, port: u16, path: []const u8 };

fn parseWsUrl(url: []const u8) !WsUrlParsed {
    if (std.mem.startsWith(u8, url, "wss://")) return error.TlsNotSupported;
    if (!std.mem.startsWith(u8, url, "ws://")) return error.InvalidUrl;

    const authority_start: usize = "ws://".len;
    const path_start = std.mem.indexOfScalarPos(u8, url, authority_start, '/') orelse url.len;
    const authority = url[authority_start..path_start];
    const path_str: []const u8 = if (path_start < url.len) url[path_start..] else "/";

    if (authority.len == 0) return error.InvalidUrl;

    const colon_pos = std.mem.lastIndexOfScalar(u8, authority, ':');
    const host: []const u8 = if (colon_pos) |cp| authority[0..cp] else authority;
    const port: u16 = if (colon_pos) |cp|
        (std.fmt.parseInt(u16, authority[cp + 1 ..], 10) catch return error.InvalidUrl)
    else
        80;

    if (host.len == 0) return error.InvalidUrl;

    return WsUrlParsed{ .host = host, .port = port, .path = path_str };
}

fn fdWriteAll(fd: std.posix.fd_t, data: []const u8) !void {
    var written: usize = 0;
    while (written < data.len) {
        const rc = std.posix.system.write(fd, data[written..].ptr, data.len - written);
        switch (std.posix.errno(rc)) {
            .SUCCESS => {
                const n: usize = @intCast(rc);
                if (n == 0) return error.BrokenPipe;
                written += n;
            },
            .INTR => continue,
            else => return error.BrokenPipe,
        }
    }
}

fn recvExact(fd: std.posix.fd_t, buf: []u8) !bool {
    if (buf.len == 0) return true;
    var received: usize = 0;
    while (received < buf.len) {
        const n = std.posix.read(fd, buf[received..]) catch return error.ConnectionClosed;
        if (n == 0) return if (received == 0) false else error.ConnectionClosed;
        received += n;
    }
    return true;
}

fn findHeader(head: []const u8, name: []const u8) ?[]const u8 {
    var it = std.mem.splitSequence(u8, head, "\r\n");
    _ = it.next();
    while (it.next()) |line| {
        const colon_pos = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const header_name = std.mem.trim(u8, line[0..colon_pos], " \t");
        if (std.ascii.eqlIgnoreCase(header_name, name)) {
            return std.mem.trim(u8, line[colon_pos + 1 ..], " \t");
        }
    }
    return null;
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //

test "zix http ws client: acceptKey RFC 6455 vector" {
    var out: [64]u8 = undefined;
    const accept = try acceptKey("dGhlIHNhbXBsZSBub25jZQ==", &out);
    try std.testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", accept);
}

test "zix http ws client: parseWsUrl basic URL" {
    const parsed = try parseWsUrl("ws://127.0.0.1:9000/chat");
    try std.testing.expectEqualStrings("127.0.0.1", parsed.host);
    try std.testing.expectEqual(@as(u16, 9000), parsed.port);
    try std.testing.expectEqualStrings("/chat", parsed.path);
}

test "zix http ws client: parseWsUrl no path defaults to /" {
    const parsed = try parseWsUrl("ws://127.0.0.1:9000");
    try std.testing.expectEqualStrings("/", parsed.path);
}

test "zix http ws client: parseWsUrl default port 80" {
    const parsed = try parseWsUrl("ws://example.com/chat");
    try std.testing.expectEqual(@as(u16, 80), parsed.port);
}

test "zix http ws client: parseWsUrl wss returns TlsNotSupported" {
    try std.testing.expectError(error.TlsNotSupported, parseWsUrl("wss://example.com/ws"));
}

test "zix http ws client: parseWsUrl non-ws scheme returns InvalidUrl" {
    try std.testing.expectError(error.InvalidUrl, parseWsUrl("http://example.com/"));
}
