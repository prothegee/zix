//! zixer proxy header rules: hop-by-hop strip (rfc 9110) and Forwarded (rfc 7239)

const std = @import("std");

/// Via element zixer appends on both legs (rfc 9110 intermediary rule).
pub const VIA: []const u8 = "1.1 zixer";

/// The fixed hop-by-hop list from rfc 9110. These never cross zixer in either
/// direction. Transfer-Encoding and Trailer sit here because zixer re-frames
/// the body itself (re-originate, the rfc 9112 smuggling defense).
const HOP_BY_HOP = [_][]const u8{
    "connection",
    "keep-alive",
    "proxy-authenticate",
    "proxy-authorization",
    "te",
    "trailer",
    "transfer-encoding",
    "upgrade",
};

/// True when name never crosses the proxy. Content-Length is stripped too:
/// zixer emits its own framing header for the rebuilt message.
pub fn isStripped(name: []const u8) bool {
    for (HOP_BY_HOP) |hop| {
        if (std.ascii.eqlIgnoreCase(name, hop)) return true;
    }

    return std.ascii.eqlIgnoreCase(name, "content-length");
}

/// True when name appears as a token in a Connection header value. Anything
/// named there is hop-by-hop as well (rfc 9110).
pub fn namedInConnection(name: []const u8, connection_value: []const u8) bool {
    var tokens = std.mem.splitScalar(u8, connection_value, ',');
    while (tokens.next()) |token| {
        const trimmed = std.mem.trim(u8, token, " \t");
        if (trimmed.len != 0 and std.ascii.eqlIgnoreCase(name, trimmed)) return true;
    }

    return false;
}

/// The Host or authority value without its port. A bracketed IPv6 literal
/// keeps its inner address, a bare IPv6 literal (several colons) stays
/// whole.
pub fn stripHostPort(host: []const u8) []const u8 {
    if (host.len == 0) return host;

    if (host[0] == '[') {
        if (std.mem.indexOfScalar(u8, host, ']')) |close| return host[1..close];

        return host;
    }

    if (std.mem.indexOfScalar(u8, host, ':')) |first| {
        if (std.mem.lastIndexOfScalar(u8, host, ':').? == first) return host[0..first];
    }

    return host;
}

/// Write the Forwarded header line for one client (rfc 7239).
///
/// Note:
/// - The for= node is always quoted: the address carries a port, and rfc 7239
///   requires the quoted form as soon as a port (or an ipv6 bracket) appears.
/// - host is the client's original Host value, empty skips the parameter.
///
/// Param:
/// out - *std.Io.Writer (upstream request head in progress)
/// client_addr - std.Io.net.IpAddress (accepted connection's peer)
/// host - []const u8 (original Host header value, may be empty)
///
/// Return:
/// - void, the full `Forwarded: ...\r\n` line is written
pub fn writeForwarded(out: *std.Io.Writer, client_addr: std.Io.net.IpAddress, host: []const u8) !void {
    try out.print("Forwarded: for=\"{f}\";proto=http", .{client_addr});
    if (host.len != 0) try out.print(";host=\"{s}\"", .{host});
    try out.writeAll("\r\n");
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //

test "zix zixer: proxy headers, hop-by-hop and framing names are stripped" {
    try std.testing.expect(isStripped("Connection"));
    try std.testing.expect(isStripped("keep-alive"));
    try std.testing.expect(isStripped("Proxy-Authenticate"));
    try std.testing.expect(isStripped("proxy-authorization"));
    try std.testing.expect(isStripped("TE"));
    try std.testing.expect(isStripped("Trailer"));
    try std.testing.expect(isStripped("Transfer-Encoding"));
    try std.testing.expect(isStripped("Upgrade"));
    try std.testing.expect(isStripped("Content-Length"));
}

test "zix zixer: proxy headers, end-to-end names pass" {
    try std.testing.expect(!isStripped("Host"));
    try std.testing.expect(!isStripped("Accept"));
    try std.testing.expect(!isStripped("Authorization"));
    try std.testing.expect(!isStripped("Cookie"));
    try std.testing.expect(!isStripped("Forwarded"));
    try std.testing.expect(!isStripped("Via"));
}

test "zix zixer: proxy headers, connection tokens mark extra hop-by-hop names" {
    try std.testing.expect(namedInConnection("X-Custom-Hop", "close, X-Custom-Hop"));
    try std.testing.expect(namedInConnection("x-custom-hop", " X-Custom-Hop "));

    try std.testing.expect(!namedInConnection("Accept", "close, X-Custom-Hop"));
    try std.testing.expect(!namedInConnection("Accept", ""));
}

test "zix zixer: proxy headers, host port strip keeps every literal shape" {
    try std.testing.expectEqualStrings("example.com", stripHostPort("example.com:8443"));
    try std.testing.expectEqualStrings("example.com", stripHostPort("example.com"));
    try std.testing.expectEqualStrings("::1", stripHostPort("[::1]:443"));
    try std.testing.expectEqualStrings("::1", stripHostPort("[::1]"));
    try std.testing.expectEqualStrings("fe80::1:2", stripHostPort("fe80::1:2"));
    try std.testing.expectEqualStrings("", stripHostPort(""));
}

test "zix zixer: proxy headers, forwarded line quotes the node and carries host" {
    var line_buf: [128]u8 = undefined;
    var out = std.Io.Writer.fixed(&line_buf);

    const addr = std.Io.net.IpAddress{ .ip4 = .{ .bytes = .{ 192, 0, 2, 60 }, .port = 51000 } };
    try writeForwarded(&out, addr, "example.com");

    try std.testing.expectEqualStrings("Forwarded: for=\"192.0.2.60:51000\";proto=http;host=\"example.com\"\r\n", out.buffered());
}

test "zix zixer: proxy headers, forwarded line without host skips the parameter" {
    var line_buf: [128]u8 = undefined;
    var out = std.Io.Writer.fixed(&line_buf);

    const addr = std.Io.net.IpAddress{ .ip4 = .{ .bytes = .{ 10, 0, 0, 9 }, .port = 40000 } };
    try writeForwarded(&out, addr, "");

    try std.testing.expectEqualStrings("Forwarded: for=\"10.0.0.9:40000\";proto=http\r\n", out.buffered());
}
