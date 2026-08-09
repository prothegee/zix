//! zixer grpc relay rules: h2 header blocks validated and re-encoded for
//! the h2 upstream leg, plus the local grpc answers

const std = @import("std");
const zix = @import("zix");

const request_scheme = @import("request_scheme.zig");

const Http2 = zix.Http2;

/// Via element for the h2 upstream leg (rfc 9110: the protocol version of
/// the received request, no minor for h2).
pub const VIA_H2: []const u8 = "2 zixer";

/// grpc-status for an unreachable upstream (UNAVAILABLE), the retryable
/// code a grpc client understands.
pub const GRPC_STATUS_UNAVAILABLE: []const u8 = "14";

/// Longest header name the re-encoders lowercase. Longer names drop.
const NAME_LOWER_MAX: usize = 128;

pub const Error = error{
    /// The block breaks an rfc 9113 8.2 or 8.3 rule: the stream answers a
    /// protocol error, the upstream never sees it.
    Malformed,
};

/// What the request validation hands back for the forwarded element.
///
/// Note:
/// - The client's own `:scheme` is required by rfc 9113 8.3 and is still
///   checked, but it is not carried here. The scheme the upstream is told
///   comes from the site, see request_scheme.
pub const RequestInfo = struct {
    authority: []const u8,
};

/// Validate the decoded request header list of one HEADERS block for the
/// h2 relay (rfc 9113 8.3).
///
/// Note:
/// - CONNECT (plain or extended) is malformed here: the grpc edge never
///   advertises the rfc 8441 setting, tunnels belong to the http2 edge.
/// - te survives the relay only as "trailers" (rfc 9113 8.2.2), any other
///   value is malformed rather than silently dropped.
///
/// Return:
/// - RequestInfo (slices borrow the decode scratch, copy before reuse)
/// - error.Malformed on any 8.2 / 8.3 violation
pub fn validateRequest(headers: []const Http2.Header) Error!RequestInfo {
    var method: ?[]const u8 = null;
    var target: ?[]const u8 = null;
    var scheme: ?[]const u8 = null;
    var authority: ?[]const u8 = null;
    var host_value: []const u8 = "";
    var seen_regular = false;

    for (headers) |header| {
        if (header.name.len == 0) return error.Malformed;

        if (header.name[0] == ':') {
            if (seen_regular) return error.Malformed;

            if (std.mem.eql(u8, header.name, ":method")) {
                if (method != null) return error.Malformed;
                method = header.value;
            } else if (std.mem.eql(u8, header.name, ":path")) {
                if (target != null) return error.Malformed;
                target = header.value;
            } else if (std.mem.eql(u8, header.name, ":scheme")) {
                if (scheme != null) return error.Malformed;
                scheme = header.value;
            } else if (std.mem.eql(u8, header.name, ":authority")) {
                if (authority != null) return error.Malformed;
                authority = header.value;
            } else {
                return error.Malformed;
            }
            continue;
        }

        seen_regular = true;
        try validateRegularName(header.name);

        if (std.mem.eql(u8, header.name, "te")) {
            if (!std.ascii.eqlIgnoreCase(header.value, "trailers")) return error.Malformed;
        } else if (std.mem.eql(u8, header.name, "host")) {
            host_value = header.value;
        }
    }

    const method_value = method orelse return error.Malformed;
    if (method_value.len == 0) return error.Malformed;
    if (std.mem.eql(u8, method_value, "CONNECT")) return error.Malformed;

    if (scheme == null) return error.Malformed;

    const target_value = target orelse return error.Malformed;
    if (target_value.len == 0) return error.Malformed;

    const final_authority = if (authority) |value| value else host_value;
    if (final_authority.len == 0) return error.Malformed;

    return .{ .authority = final_authority };
}

/// Re-encode a validated request block for the upstream conn: pseudo
/// headers first in received order, regular headers lowercased, then
/// zixer's own via and forwarded elements appended (existing chains pass
/// through untouched).
pub fn encodeRequestBlock(block_buf: []u8, headers: []const Http2.Header, info: *const RequestInfo, client_addr: std.Io.net.IpAddress, scheme: request_scheme.Scheme) ![]const u8 {
    var encoder = Http2.HpackEncoder.init(block_buf);

    for (headers) |header| {
        if (header.name[0] == ':') {
            try encoder.writeHeader(header.name, header.value);
            continue;
        }

        try writeLowerHeader(&encoder, header.name, header.value);
    }

    try encoder.writeHeader("via", VIA_H2);

    var forwarded_buf: [160]u8 = undefined;
    if (forwardedValue(&forwarded_buf, info, client_addr, scheme)) |value| {
        try encoder.writeHeader("forwarded", value);
    }

    return encoder.encoded();
}

/// Re-encode a response head block for the client conn: :status leads,
/// regular headers lowercased, zixer's via element appended.
///
/// Return:
/// - the encoded block
/// - error.Malformed when :status is missing or another pseudo appears
pub fn encodeResponseBlock(block_buf: []u8, headers: []const Http2.Header) ![]const u8 {
    var encoder = Http2.HpackEncoder.init(block_buf);

    var seen_status = false;
    for (headers) |header| {
        if (header.name.len == 0) return error.Malformed;

        if (header.name[0] == ':') {
            if (!std.mem.eql(u8, header.name, ":status") or seen_status) return error.Malformed;

            seen_status = true;
            try encoder.writeHeader(":status", header.value);
            continue;
        }

        try writeLowerHeader(&encoder, header.name, header.value);
    }
    if (!seen_status) return error.Malformed;

    try encoder.writeHeader("via", VIA_H2);

    return encoder.encoded();
}

/// Re-encode a trailer block (either direction): regular headers only,
/// lowercased, nothing added. This surviving the hop is the point of the
/// h2 end-to-end leg.
pub fn encodeTrailerBlock(block_buf: []u8, headers: []const Http2.Header) ![]const u8 {
    var encoder = Http2.HpackEncoder.init(block_buf);

    for (headers) |header| {
        if (header.name.len == 0 or header.name[0] == ':') return error.Malformed;

        try writeLowerHeader(&encoder, header.name, header.value);
    }

    return encoder.encoded();
}

/// The local trailers-only answer when no upstream is reachable: a valid
/// grpc response carrying UNAVAILABLE, so the client retries instead of
/// surfacing a transport error.
pub fn encodeUnavailableBlock(block_buf: []u8) ![]const u8 {
    var encoder = Http2.HpackEncoder.init(block_buf);

    try encoder.writeHeader(":status", "200");
    try encoder.writeHeader("content-type", "application/grpc");
    try encoder.writeHeader("grpc-status", GRPC_STATUS_UNAVAILABLE);
    try encoder.writeHeader("grpc-message", "upstream unavailable");

    return encoder.encoded();
}

/// rfc 9113 8.2: field names travel lowercase, and connection-specific
/// headers make the whole block malformed.
fn validateRegularName(name: []const u8) Error!void {
    for (name) |char| {
        if (char >= 'A' and char <= 'Z') return error.Malformed;
    }

    const forbidden = [_][]const u8{ "connection", "proxy-connection", "keep-alive", "transfer-encoding", "upgrade" };
    for (forbidden) |bad| {
        if (std.mem.eql(u8, name, bad)) return error.Malformed;
    }
}

/// Format the rfc 7239 forwarded value for one client. Null when the
/// buffer cannot hold it (the element drops, the request still relays).
///
/// Note:
/// - proto is the site's scheme. Echoing the client's `:scheme` here would let
///   a cleartext caller tell the backend its request arrived over https.
fn forwardedValue(buf: []u8, info: *const RequestInfo, client_addr: std.Io.net.IpAddress, scheme: request_scheme.Scheme) ?[]const u8 {
    var writer = std.Io.Writer.fixed(buf);

    writer.print("for=\"{f}\";proto={s}", .{ client_addr, scheme.token() }) catch return null;
    if (info.authority.len != 0) writer.print(";host=\"{s}\"", .{info.authority}) catch return null;

    return writer.buffered();
}

/// Lowercased header write shared by the re-encoders. Names past the
/// bound drop rather than truncate.
fn writeLowerHeader(encoder: *Http2.HpackEncoder, name: []const u8, value: []const u8) !void {
    if (name.len > NAME_LOWER_MAX) return;

    var lower_buf: [NAME_LOWER_MAX]u8 = undefined;
    for (name, 0..) |char, index| lower_buf[index] = std.ascii.toLower(char);

    try encoder.writeHeader(lower_buf[0..name.len], value);
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //

const testing = std.testing;

fn makeHeader(name: []const u8, value: []const u8) Http2.Header {
    return .{ .name = name, .value = value };
}

fn decodeBlock(block: []const u8, out: []Http2.Header, scratch: []u8) !usize {
    var decoder = Http2.HpackDecoder.init();

    return decoder.decode(block, out, scratch);
}

fn findValue(headers: []const Http2.Header, count: usize, name: []const u8) ?[]const u8 {
    for (headers[0..count]) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry.value;
    }

    return null;
}

const VALID_REQUEST = [_]Http2.Header{
    makeHeader(":method", "POST"),
    makeHeader(":scheme", "http"),
    makeHeader(":path", "/pkg.Svc/Call"),
    makeHeader(":authority", "backend"),
    makeHeader("content-type", "application/grpc"),
    makeHeader("te", "trailers"),
};

test "zix zixer: grpc relay, valid request passes and yields the authority" {
    const info = try validateRequest(&VALID_REQUEST);

    try testing.expectEqualStrings("backend", info.authority);
}

test "zix zixer: grpc relay, a request with no scheme pseudo header is malformed" {
    // rfc 9113 8.3 requires it, so its absence is still refused even though
    // nothing downstream reads the value.
    const no_scheme = [_]Http2.Header{
        makeHeader(":method", "POST"),
        makeHeader(":path", "/pkg.Svc/Call"),
        makeHeader(":authority", "backend"),
        makeHeader("content-type", "application/grpc"),
    };

    try testing.expectError(error.Malformed, validateRequest(&no_scheme));
}

test "zix zixer: grpc relay, connection specific headers are malformed" {
    const bad_connection = [_]Http2.Header{
        makeHeader(":method", "POST"),
        makeHeader(":scheme", "http"),
        makeHeader(":path", "/x"),
        makeHeader(":authority", "backend"),
        makeHeader("connection", "keep-alive"),
    };
    try testing.expectError(error.Malformed, validateRequest(&bad_connection));

    const bad_te = [_]Http2.Header{
        makeHeader(":method", "POST"),
        makeHeader(":scheme", "http"),
        makeHeader(":path", "/x"),
        makeHeader(":authority", "backend"),
        makeHeader("te", "gzip"),
    };
    try testing.expectError(error.Malformed, validateRequest(&bad_te));

    const bad_upper = [_]Http2.Header{
        makeHeader(":method", "POST"),
        makeHeader(":scheme", "http"),
        makeHeader(":path", "/x"),
        makeHeader(":authority", "backend"),
        makeHeader("X-Custom", "1"),
    };
    try testing.expectError(error.Malformed, validateRequest(&bad_upper));
}

test "zix zixer: grpc relay, pseudo header rules hold" {
    const after_regular = [_]Http2.Header{
        makeHeader(":method", "POST"),
        makeHeader("content-type", "application/grpc"),
        makeHeader(":path", "/x"),
    };
    try testing.expectError(error.Malformed, validateRequest(&after_regular));

    const unknown_pseudo = [_]Http2.Header{
        makeHeader(":method", "POST"),
        makeHeader(":scheme", "http"),
        makeHeader(":path", "/x"),
        makeHeader(":authority", "backend"),
        makeHeader(":protocol", "websocket"),
    };
    try testing.expectError(error.Malformed, validateRequest(&unknown_pseudo));

    const no_path = [_]Http2.Header{
        makeHeader(":method", "POST"),
        makeHeader(":scheme", "http"),
        makeHeader(":authority", "backend"),
    };
    try testing.expectError(error.Malformed, validateRequest(&no_path));

    const connect_method = [_]Http2.Header{
        makeHeader(":method", "CONNECT"),
        makeHeader(":scheme", "http"),
        makeHeader(":path", "/x"),
        makeHeader(":authority", "backend"),
    };
    try testing.expectError(error.Malformed, validateRequest(&connect_method));
}

test "zix zixer: grpc relay, request block keeps order and appends via and forwarded" {
    const info = try validateRequest(&VALID_REQUEST);
    const addr = try std.Io.net.IpAddress.parse("10.1.2.3", 41000);

    var block_buf: [1024]u8 = undefined;
    const block = try encodeRequestBlock(&block_buf, &VALID_REQUEST, &info, addr, .HTTP);

    var out: [16]Http2.Header = undefined;
    var scratch: [1024]u8 = undefined;
    const count = try decodeBlock(block, &out, &scratch);

    try testing.expectEqual(@as(usize, 8), count);
    try testing.expectEqualStrings(":method", out[0].name);
    try testing.expectEqualStrings(":authority", out[3].name);
    try testing.expectEqualStrings("trailers", findValue(&out, count, "te").?);
    try testing.expectEqualStrings(VIA_H2, findValue(&out, count, "via").?);

    const forwarded = findValue(&out, count, "forwarded").?;
    try testing.expect(std.mem.indexOf(u8, forwarded, "for=\"10.1.2.3:41000\"") != null);
    try testing.expect(std.mem.indexOf(u8, forwarded, "proto=http") != null);
    try testing.expect(std.mem.indexOf(u8, forwarded, "host=\"backend\"") != null);
}

test "zix zixer: grpc relay, response block requires status and appends via" {
    const head = [_]Http2.Header{
        makeHeader(":status", "200"),
        makeHeader("content-type", "application/grpc"),
        makeHeader("X-Server", "fake"),
    };

    var block_buf: [512]u8 = undefined;
    const block = try encodeResponseBlock(&block_buf, &head);

    var out: [16]Http2.Header = undefined;
    var scratch: [512]u8 = undefined;
    const count = try decodeBlock(block, &out, &scratch);

    try testing.expectEqualStrings(":status", out[0].name);
    try testing.expectEqualStrings("fake", findValue(&out, count, "x-server").?);
    try testing.expectEqualStrings(VIA_H2, findValue(&out, count, "via").?);

    const no_status = [_]Http2.Header{makeHeader("content-type", "application/grpc")};
    try testing.expectError(error.Malformed, encodeResponseBlock(&block_buf, &no_status));

    const bad_pseudo = [_]Http2.Header{
        makeHeader(":status", "200"),
        makeHeader(":path", "/x"),
    };
    try testing.expectError(error.Malformed, encodeResponseBlock(&block_buf, &bad_pseudo));
}

test "zix zixer: grpc relay, trailer block passes through and refuses pseudo" {
    const trailers = [_]Http2.Header{
        makeHeader("grpc-status", "0"),
        makeHeader("grpc-message", "ok"),
        makeHeader("X-Detail", "kept"),
    };

    var block_buf: [512]u8 = undefined;
    const block = try encodeTrailerBlock(&block_buf, &trailers);

    var out: [16]Http2.Header = undefined;
    var scratch: [512]u8 = undefined;
    const count = try decodeBlock(block, &out, &scratch);

    try testing.expectEqual(@as(usize, 3), count);
    try testing.expectEqualStrings("0", findValue(&out, count, "grpc-status").?);
    try testing.expectEqualStrings("kept", findValue(&out, count, "x-detail").?);

    const with_pseudo = [_]Http2.Header{makeHeader(":status", "200")};
    try testing.expectError(error.Malformed, encodeTrailerBlock(&block_buf, &with_pseudo));
}

test "zix zixer: grpc relay, unavailable block is a trailers-only grpc answer" {
    var block_buf: [512]u8 = undefined;
    const block = try encodeUnavailableBlock(&block_buf);

    var out: [8]Http2.Header = undefined;
    var scratch: [512]u8 = undefined;
    const count = try decodeBlock(block, &out, &scratch);

    try testing.expectEqual(@as(usize, 4), count);
    try testing.expectEqualStrings("200", findValue(&out, count, ":status").?);
    try testing.expectEqualStrings("application/grpc", findValue(&out, count, "content-type").?);
    try testing.expectEqualStrings(GRPC_STATUS_UNAVAILABLE, findValue(&out, count, "grpc-status").?);
}

test "zix zixer: grpc relay, the forwarded proto is the site's and not the client's claim" {
    // The block says http, and a tls site has to report https regardless: the
    // pseudo header is a claim, the site's own setting is the fact.
    const info = try validateRequest(&VALID_REQUEST);
    const addr = try std.Io.net.IpAddress.parse("10.1.2.3", 41000);

    var block_buf: [1024]u8 = undefined;
    const block = try encodeRequestBlock(&block_buf, &VALID_REQUEST, &info, addr, .HTTPS);

    var out: [16]Http2.Header = undefined;
    var scratch: [1024]u8 = undefined;
    const count = try decodeBlock(block, &out, &scratch);

    const forwarded = findValue(&out, count, "forwarded").?;
    try testing.expect(std.mem.indexOf(u8, forwarded, "proto=https") != null);
}
