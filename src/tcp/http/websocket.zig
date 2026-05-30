//! zix http websocket
//! RFC 6455 — frame parsing, handshake, room-based broadcast.

const std = @import("std");

// --------------------------------------------------------- //

/// RFC 6455 5.2 — WebSocket opcodes.
pub const Opcode = enum(u8) {
    continuation = 0x0,
    text = 0x1,
    binary = 0x2,
    close = 0x8,
    ping = 0x9,
    pong = 0xA,
    _,
};

/// Parsed WebSocket frame.
/// payload is a slice into caller-supplied payload_buf (masked) or into the source buffer (unmasked).
pub const Frame = struct {
    fin: bool,
    opcode: Opcode,
    payload: []const u8,
};

/// Return value of parseFrame.
pub const ParseResult = struct {
    frame: Frame,
    consumed: usize,
};

/// Parse one WebSocket frame from buf.
///
/// Note:
/// - Client->server frames are masked, the unmasked payload is written into payload_buf.
///   payload_buf must be at least as large as the expected payload (max 4 KB recommended).
/// - Returns null if buf does not yet contain a complete frame.
///
/// Param:
/// buf         - []const u8 (raw bytes from the TCP connection)
/// payload_buf - []u8       (caller-provided buffer for unmasked payload)
///
/// Return:
/// ?ParseResult
pub fn parseFrame(buf: []const u8, payload_buf: []u8) ?ParseResult {
    if (buf.len < 2) return null;

    var byte_offset: usize = 0;
    const fin = (buf[0] & 0x80) != 0;
    const opcode: Opcode = @enumFromInt(buf[0] & 0x0F);
    byte_offset += 1;

    const masked = (buf[1] & 0x80) != 0;
    var payload_len: u64 = buf[1] & 0x7F;
    byte_offset += 1;

    if (payload_len == 126) {
        if (buf.len < byte_offset + 2) return null;
        payload_len = (@as(u64, buf[byte_offset]) << 8) | buf[byte_offset + 1];
        byte_offset += 2;
    } else if (payload_len == 127) {
        if (buf.len < byte_offset + 8) return null;
        payload_len = 0;
        for (0..8) |i| payload_len = (payload_len << 8) | buf[byte_offset + i];
        byte_offset += 8;
    }

    var mask: [4]u8 = .{ 0, 0, 0, 0 };
    if (masked) {
        if (buf.len < byte_offset + 4) return null;
        @memcpy(&mask, buf[byte_offset .. byte_offset + 4]);
        byte_offset += 4;
    }

    const capped_len: usize = @intCast(@min(payload_len, payload_buf.len));
    if (buf.len < byte_offset + capped_len) return null;

    const payload: []const u8 = if (masked) blk: {
        for (0..capped_len) |i| payload_buf[i] = buf[byte_offset + i] ^ mask[i % 4];
        break :blk payload_buf[0..capped_len];
    } else buf[byte_offset .. byte_offset + capped_len];

    return .{
        .frame = .{ .fin = fin, .opcode = opcode, .payload = payload },
        .consumed = byte_offset + capped_len,
    };
}

/// Build a server->client WebSocket frame (unmasked per RFC 6455 5.1).
///
/// Note:
/// - buf must be large enough: payload.len + 10 bytes for the header.
/// - Payload is capped at payload.len, caller is responsible for sizing buf.
///
/// Param:
/// buf     - []u8        (destination, must be at least payload.len + 10)
/// opcode  - Opcode
/// payload - []const u8
///
/// Return:
/// usize (bytes written into buf)
pub fn buildFrame(buf: []u8, opcode: Opcode, payload: []const u8) usize {
    var byte_offset: usize = 0;
    buf[byte_offset] = 0x80 | @intFromEnum(opcode);
    byte_offset += 1;

    if (payload.len <= 125) {
        buf[byte_offset] = @intCast(payload.len);
        byte_offset += 1;
    } else if (payload.len <= 65535) {
        buf[byte_offset] = 126;
        buf[byte_offset + 1] = @intCast((payload.len >> 8) & 0xFF);
        buf[byte_offset + 2] = @intCast(payload.len & 0xFF);
        byte_offset += 3;
    } else {
        buf[byte_offset] = 127;
        for (0..8) |i| {
            const shift: u6 = @intCast((7 - i) * 8);
            buf[byte_offset + 1 + i] = @intCast((payload.len >> shift) & 0xFF);
        }
        byte_offset += 9;
    }

    @memcpy(buf[byte_offset .. byte_offset + payload.len], payload);
    return byte_offset + payload.len;
}

/// Compute Sec-WebSocket-Accept from Sec-WebSocket-Key (RFC 6455 4.2.2).
///
/// Param:
/// key - []const u8 (value of the Sec-WebSocket-Key request header)
/// out - *[64]u8    (caller-provided output buffer, result is a sub-slice of it)
///
/// Return:
/// ![]const u8
pub fn acceptKey(key: []const u8, out: *[64]u8) ![]const u8 {
    // RFC 6455 1.3 — this exact GUID is mandated by the WebSocket spec, do not change it.
    const rfc6455_guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
    var hash_input: [128]u8 = undefined;
    if (key.len + rfc6455_guid.len > hash_input.len) return error.KeyTooLong;
    @memcpy(hash_input[0..key.len], key);
    @memcpy(hash_input[key.len..][0..rfc6455_guid.len], rfc6455_guid);
    var hash: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(hash_input[0 .. key.len + rfc6455_guid.len], &hash, .{});
    const encoded_len = std.base64.standard.Encoder.calcSize(20);
    return std.base64.standard.Encoder.encode(out[0..encoded_len], &hash);
}

/// Perform the HTTP -> WebSocket upgrade handshake.
/// Writes the 101 Switching Protocols response directly onto the stream,
/// bypassing the zix Response layer.
///
/// Param:
/// stream  - std.Io.net.Stream (ctx.stream from the handler)
/// io      - std.Io
/// accept  - []const u8 (value returned by acceptKey)
///
/// Return:
/// !void
pub fn upgrade(stream: std.Io.net.Stream, io: std.Io, accept: []const u8) !void {
    var hdr_buf: [256]u8 = undefined;
    const response = try std.fmt.bufPrint(
        &hdr_buf,
        "HTTP/1.1 101 Switching Protocols\r\n" ++
            "Upgrade: websocket\r\n" ++
            "Connection: Upgrade\r\n" ++
            "Sec-WebSocket-Accept: {s}\r\n\r\n",
        .{accept},
    );
    var write_buf: [256]u8 = undefined;
    var writer = stream.writer(io, &write_buf);
    try writer.interface.writeAll(response);
    try writer.interface.flush();
}

// --------------------------------------------------------- //

/// Heap-allocated per-connection handle.
/// Created by the handler with smp_allocator, destroyed when the WS session ends.
pub const Conn = struct {
    stream: std.Io.net.Stream,
    io: std.Io,
};

const Room = struct {
    conns: std.ArrayList(*Conn),
};

/// Thread-safe registry of named rooms, each holding a list of active connections.
///
/// Lifecycle:
/// - Initialize once in main() before server.run().
/// - Call join() when a WebSocket connection opens.
/// - Call leave() (via defer) when a WebSocket connection closes.
/// - broadcast() sends a text frame to every connection in a room.
pub const RoomMap = struct {
    rooms: std.StringHashMap(Room),
    mu: std.Io.Mutex,
    allocator: std.mem.Allocator,

    /// Brief:
    /// Initialize the room map
    ///
    /// Param:
    /// allocator - std.mem.Allocator (process-lifetime allocator, e.g. smp_allocator)
    ///
    /// Return:
    /// RoomMap
    pub fn init(allocator: std.mem.Allocator) RoomMap {
        return .{
            .rooms = std.StringHashMap(Room).init(allocator),
            .mu = .init,
            .allocator = allocator,
        };
    }

    /// Brief:
    /// Free all room and connection list storage, including owned-copy room keys
    pub fn deinit(self: *RoomMap) void {
        var it = self.rooms.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.conns.deinit(self.allocator);
            self.allocator.free(entry.key_ptr.*);
        }
        self.rooms.deinit();
    }

    /// Brief:
    /// Add a connection to a room, creating the room if needed
    ///
    /// Note:
    /// - The room key is owned-copied so its lifetime is independent of any connection buffer.
    ///
    /// Param:
    /// room - []const u8
    /// conn - *Conn
    /// io   - std.Io
    pub fn join(self: *RoomMap, room: []const u8, conn: *Conn, io: std.Io) void {
        self.mu.lock(io) catch return;
        defer self.mu.unlock(io);

        const room_entry = self.rooms.getOrPut(room) catch return;
        if (!room_entry.found_existing) {
            // Own-copy the key so it doesn't dangle when the connection's read
            // buffer is freed after the WebSocket session ends.
            const owned = self.allocator.dupe(u8, room) catch {
                _ = self.rooms.remove(room);
                return;
            };
            room_entry.key_ptr.* = owned;
            room_entry.value_ptr.* = .{ .conns = .empty };
        }
        room_entry.value_ptr.conns.append(self.allocator, conn) catch return;
        std.debug.print("ws: join room='{s}' total={d}\n", .{ room, room_entry.value_ptr.conns.items.len });
    }

    /// Brief:
    /// Remove a connection from its room, removes the room if it becomes empty
    ///
    /// Note:
    /// - Safe to call from defer, no-op if the conn is not found.
    /// - When the last connection leaves, the owned-copy room key is freed.
    ///
    /// Param:
    /// room - []const u8
    /// conn - *Conn
    /// io   - std.Io
    pub fn leave(self: *RoomMap, room: []const u8, conn: *Conn, io: std.Io) void {
        self.mu.lock(io) catch return;
        defer self.mu.unlock(io);

        const room_ptr = self.rooms.getPtr(room) orelse return;

        var i: usize = 0;
        while (i < room_ptr.conns.items.len) {
            if (room_ptr.conns.items[i] == conn) {
                _ = room_ptr.conns.orderedRemove(i);
            } else {
                i += 1;
            }
        }
        const count = room_ptr.conns.items.len;
        std.debug.print("ws: leave room='{s}' total={d}\n", .{ room, count });

        if (count == 0) {
            if (self.rooms.fetchRemove(room)) |kv| {
                var conns = kv.value.conns;
                conns.deinit(self.allocator);
                self.allocator.free(kv.key);
                std.debug.print("ws: room='{s}' removed (empty)\n", .{room});
            }
        }
    }

    /// Brief:
    /// Broadcast a text message to all connections in a room
    ///
    /// Note:
    /// - Frames are serialized once and sent to every connection.
    /// - Payload is capped at 4 KB, larger messages are silently truncated.
    /// - Failed writes are skipped, dead connections are cleaned up by their own handler's leave().
    ///
    /// Param:
    /// room    - []const u8
    /// message - []const u8
    /// io      - std.Io
    pub fn broadcast(self: *RoomMap, room: []const u8, message: []const u8, io: std.Io) void {
        self.mu.lock(io) catch return;
        defer self.mu.unlock(io);

        const room_ptr = self.rooms.getPtr(room) orelse return;

        const payload = message[0..@min(message.len, 4096)];
        var frame_buf: [4106]u8 = undefined; // 4096 payload + up to 10 header bytes
        const frame_len = buildFrame(&frame_buf, .text, payload);
        const frame_data = frame_buf[0..frame_len];

        for (room_ptr.conns.items) |conn| {
            var write_buf: [4106]u8 = undefined;
            var writer = conn.stream.writer(conn.io, &write_buf);
            writer.interface.writeAll(frame_data) catch continue;
            writer.interface.flush() catch continue;
        }
    }
};

// --------------------------------------------------------- //
// --------------------------------------------------------- //

test "zix test: http websocket acceptKey" {
    var out: [64]u8 = undefined;
    const accept = try acceptKey("dGhlIHNhbXBsZSBub25jZQ==", &out);
    try std.testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", accept);
}

test "zix test: http websocket frame" {
    const payload = "hello";
    var buf: [128]u8 = undefined;
    const len = buildFrame(&buf, .text, payload);

    try std.testing.expect(len > payload.len);
    try std.testing.expectEqual(@as(u8, 0x81), buf[0]); // fin | text
    try std.testing.expectEqual(@as(u8, 5), buf[1]); // unmasked, len 5
    try std.testing.expectEqualStrings(payload, buf[2..len]);

    var payload_buf: [128]u8 = undefined;
    const result = parseFrame(buf[0..len], &payload_buf).?;
    try std.testing.expect(result.frame.fin);
    try std.testing.expectEqual(Opcode.text, result.frame.opcode);
    try std.testing.expectEqualStrings(payload, result.frame.payload);
    try std.testing.expectEqual(len, result.consumed);
}

test "zix test: http websocket masked frame" {
    // Masked "Hello" from RFC 6455 5.7
    const raw = [_]u8{ 0x81, 0x85, 0x37, 0xfa, 0x21, 0x3d, 0x7f, 0x9f, 0x4d, 0x51, 0x58 };
    var payload_buf: [128]u8 = undefined;
    const result = parseFrame(&raw, &payload_buf).?;
    try std.testing.expect(result.frame.fin);
    try std.testing.expectEqual(Opcode.text, result.frame.opcode);
    try std.testing.expectEqualStrings("Hello", result.frame.payload);
}
