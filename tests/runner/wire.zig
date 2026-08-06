//! Low-level wire helpers shared by the protocol checks in all_runner.zig.
//!
//! These are the raw byte movers the checks reach for when zix's own clients
//! cannot exercise a path: TLS record framing, response-header lookup, and the
//! HTTP/2 frame scan that hunts for a :status 200 reply.
//!
//! Note:
//! - Descriptor reads and writes go through zix.utils.fd_io, which carries a backend for
//!   Windows, Linux and the other POSIX targets. These helpers used raw Linux syscalls, which
//!   forced a Windows skip and issued Linux syscall numbers at the BSD and macOS kernels.

const std = @import("std");
const zix = @import("zix");

const Http2 = zix.Http2;
const fd_io = zix.utils.fd_io;
const socket_poll = zix.utils.socket_poll;

/// Ceiling for one raw descriptor read. A check's server answers in well under a second, so this
/// only fires when it accepted the connection and then went silent. Without it the read has no end,
/// and an infinite park is not an error the runner's retry layer can see.
const RAW_READ_TIMEOUT_MS: u32 = 5000;

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

/// Read exactly buf.len bytes from fd, looping over short reads and bounding each one.
///
/// Note:
/// - fd_io.readAll is the same loop without a bound, which is why it is not used here: a server
///   that accepts and then stops answering parks the check forever, and the runner reports that as
///   a killed child rather than a named failure.
/// - Raw descriptor, no reader buffer above it, so the readiness gate is safe to place directly in
///   front of the read.
pub fn tlsReadAll(fd: std.posix.fd_t, buf: []u8) !void {
    var filled: usize = 0;

    while (filled < buf.len) {
        if (!socket_poll.readableWithin(fd, RAW_READ_TIMEOUT_MS)) return error.ReadTimeout;

        const got = try fd_io.readOnce(fd, buf[filled..]);
        if (got == 0) return error.ConnectionClosed;

        filled += got;
    }
}

/// Read whatever has arrived on fd, once, bounded.
///
/// Note:
/// - For a scan that cannot say in advance how many bytes it needs, i.e. the h2 frame scan below,
///   which reads once and pushes what arrives. fd_io.readOnce is the same call without a bound.
/// - A server can hold a connection open without ever sending what the scan is looking for: an h2
///   edge that answers a status the scan does not accept then goes back to waiting for the next
///   client frame, and neither side ever speaks again. That is a park, not a close, so the round
///   counter above never advances and the check never fails on its own.
/// - Raw descriptor, no reader buffer above it, so the readiness gate is safe to place directly in
///   front of the read.
///
/// Param:
/// fd - std.posix.fd_t (a connected, blocking descriptor)
/// buf - []u8 (receives whatever arrived)
///
/// Return:
/// - usize bytes read, 0 when the peer closed
/// - error.ReadTimeout when nothing arrived inside the bound
pub fn readOnceBounded(fd: std.posix.fd_t, buf: []u8) !usize {
    if (!socket_poll.readableWithin(fd, RAW_READ_TIMEOUT_MS)) return error.ReadTimeout;

    return fd_io.readOnce(fd, buf);
}

/// Write all bytes to fd, looping over short writes and retrying on EINTR.
pub fn tlsWriteAll(fd: std.posix.fd_t, bytes: []const u8) !void {
    return fd_io.writeAll(fd, bytes);
}

// --------------------------------------------------------- //

/// Look up a response header value by case-insensitive name, or null when absent.
pub fn headerValue(head: []const u8, name: []const u8) ?[]const u8 {
    var line_iter = std.mem.tokenizeSequence(u8, head, "\r\n");
    while (line_iter.next()) |line| {
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
///     const plain = try readOnceBytes();
///     if (try scanner.push(plain)) return; // saw :status 200
/// }
/// return error.NoStatus200;
/// ```
pub const H2Scanner = struct {
    recv_accum: [16384]u8 = undefined,
    recv_len: usize = 0,

    /// Append a plaintext chunk, parse complete frames, and report whether :status 200 was seen.
    /// Consumed frames are compacted out so the buffer only holds the unparsed tail.
    pub fn push(self: *H2Scanner, plain: []const u8) !bool {
        @memcpy(self.recv_accum[self.recv_len..][0..plain.len], plain);
        self.recv_len += plain.len;

        var off: usize = 0;
        while (off + Http2.FRAME_HEADER_LEN <= self.recv_len) {
            const frame = Http2.parseFrameHeader(self.recv_accum[off..][0..Http2.FRAME_HEADER_LEN]);
            const total = Http2.FRAME_HEADER_LEN + @as(usize, frame.length);
            if (off + total > self.recv_len) break;

            const payload = self.recv_accum[off + Http2.FRAME_HEADER_LEN .. off + total];
            if (frame.frame_type == Http2.FRAME_TYPE_HEADERS) {
                if (try headersHaveStatus200(payload)) return true;
            }
            off += total;
        }

        if (off >= self.recv_len) {
            self.recv_len = 0;
        } else if (off > 0) {
            std.mem.copyForwards(u8, self.recv_accum[0 .. self.recv_len - off], self.recv_accum[off..self.recv_len]);
            self.recv_len -= off;
        }

        return false;
    }
};

/// Decode an HPACK header block and report whether it carries :status 200.
fn headersHaveStatus200(payload: []const u8) !bool {
    var hpack_decoder = Http2.HpackDecoder.init();
    var hdrs: [Http2.MAX_HEADERS]Http2.Header = undefined;
    var scratch: [4096]u8 = undefined;
    const header_count = try hpack_decoder.decode(payload, &hdrs, &scratch);

    for (hdrs[0..header_count]) |h| {
        if (std.mem.eql(u8, h.name, ":status") and std.mem.eql(u8, h.value, "200")) return true;
    }

    return false;
}
