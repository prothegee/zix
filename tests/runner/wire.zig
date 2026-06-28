//! Low-level wire helpers shared by the protocol checks in all_runner.zig.
//!
//! These are the raw byte movers the checks reach for when zix's own clients
//! cannot exercise a path: TLS record framing, response-header lookup, and the
//! HTTP/2 frame scan that hunts for a :status 200 reply.

const std = @import("std");
const zix = @import("zix");

const Http2 = zix.Http2;

// --------------------------------------------------------- //

/// Write one TLS record: a 5-byte header (content type + version + length) then the payload.
pub fn tlsWriteRecord(fd: std.posix.fd_t, content_type: u8, msg: []const u8) !void {
    var header: [5]u8 = undefined;
    header[0] = content_type;
    header[1] = 0x03;
    header[2] = 0x03;
    std.mem.writeInt(u16, header[3..5], @intCast(msg.len), .big);

    try tlsWriteAll(fd, &header);
    try tlsWriteAll(fd, msg);
}

/// Read one TLS record (header + body) into buf, returning the total byte count.
pub fn tlsReadRecord(fd: std.posix.fd_t, buf: []u8) !usize {
    try tlsReadAll(fd, buf[0..5]);
    const len = std.mem.readInt(u16, buf[3..5], .big);
    try tlsReadAll(fd, buf[5 .. 5 + len]);

    return 5 + len;
}

/// Read exactly buf.len bytes from fd, looping over short reads and retrying on EINTR.
pub fn tlsReadAll(fd: std.posix.fd_t, buf: []u8) !void {
    var read: usize = 0;
    while (read < buf.len) {
        const rc = std.os.linux.read(fd, buf[read..].ptr, buf.len - read);
        switch (std.posix.errno(rc)) {
            .SUCCESS => {},
            .INTR => continue,
            else => return error.ReadFailed,
        }
        if (rc == 0) return error.ConnectionClosed;

        read += rc;
    }
}

/// Write all bytes to fd, looping over short writes and retrying on EINTR.
pub fn tlsWriteAll(fd: std.posix.fd_t, bytes: []const u8) !void {
    var written: usize = 0;
    while (written < bytes.len) {
        const rc = std.os.linux.write(fd, bytes[written..].ptr, bytes.len - written);
        switch (std.posix.errno(rc)) {
            .SUCCESS => {},
            .INTR => continue,
            else => return error.WriteFailed,
        }

        written += rc;
    }
}

// --------------------------------------------------------- //

/// Look up a response header value by case-insensitive name, or null when absent.
pub fn headerValue(head: []const u8, name: []const u8) ?[]const u8 {
    var it = std.mem.tokenizeSequence(u8, head, "\r\n");
    while (it.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " "), name)) {
            return std.mem.trim(u8, line[colon + 1 ..], " ");
        }
    }

    return null;
}

/// Parse the Content-Length response header into a byte count, or null when absent or malformed.
pub fn parseContentLength(head: []const u8) ?usize {
    const value = headerValue(head, "content-length") orelse return null;

    return std.fmt.parseInt(usize, value, 10) catch null;
}

// --------------------------------------------------------- //

/// Incremental HTTP/2 frame scanner: feed it plaintext chunks (already decrypted when over TLS) and
/// it accumulates, parses frames, and reports once a HEADERS frame carries :status 200.
///
/// Note:
/// - The three h2 checks (h2c, h2-over-TLS, gRPC-over-TLS) only differ in how bytes arrive (raw fd
///   read versus TLS record decrypt). This holds the shared frame-scan so that loop lives once.
///
/// Usage:
/// ```zig
/// var scanner: wire.H2Scanner = .{};
/// while (rounds < 64) : (rounds += 1) {
///     const plain = try readSomeBytes();
///     if (try scanner.push(plain)) return; // saw :status 200
/// }
/// return error.NoStatus200;
/// ```
pub const H2Scanner = struct {
    acc: [16384]u8 = undefined,
    acc_len: usize = 0,

    /// Append a plaintext chunk, parse complete frames, and report whether :status 200 was seen.
    /// Consumed frames are compacted out so the buffer only holds the unparsed tail.
    pub fn push(self: *H2Scanner, plain: []const u8) !bool {
        @memcpy(self.acc[self.acc_len..][0..plain.len], plain);
        self.acc_len += plain.len;

        var off: usize = 0;
        while (off + Http2.FRAME_HEADER_LEN <= self.acc_len) {
            const frame = Http2.parseFrameHeader(self.acc[off..][0..Http2.FRAME_HEADER_LEN]);
            const total = Http2.FRAME_HEADER_LEN + @as(usize, frame.length);
            if (off + total > self.acc_len) break;

            const payload = self.acc[off + Http2.FRAME_HEADER_LEN .. off + total];
            if (frame.frame_type == Http2.FRAME_TYPE_HEADERS) {
                if (try headersHaveStatus200(payload)) return true;
            }
            off += total;
        }

        if (off >= self.acc_len) {
            self.acc_len = 0;
        } else if (off > 0) {
            std.mem.copyForwards(u8, self.acc[0 .. self.acc_len - off], self.acc[off..self.acc_len]);
            self.acc_len -= off;
        }

        return false;
    }
};

/// Decode an HPACK header block and report whether it carries :status 200.
fn headersHaveStatus200(payload: []const u8) !bool {
    var hdec = Http2.HpackDecoder.init();
    var hdrs: [Http2.MAX_HEADERS]Http2.Header = undefined;
    var scratch: [4096]u8 = undefined;
    const cnt = try hdec.decode(payload, &hdrs, &scratch);

    for (hdrs[0..cnt]) |h| {
        if (std.mem.eql(u8, h.name, ":status") and std.mem.eql(u8, h.value, "200")) return true;
    }

    return false;
}
