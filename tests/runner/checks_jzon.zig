//! jzon-over-HTTP wire checks, shared by all_runner.zig and jzon_runner.zig.
//!
//! Drives the http1_jzon example: a rendered record leaves the server, comes back
//! in as a request body, and is read into the same record. The case table pins
//! what each route answers, then a round trip proves the two directions agree on
//! the wire rather than only in a test.
//!
//! A raw TCP socket is used rather than zix.Http.Client: every case here is a POST
//! carrying a body, and the round trip has to send back the exact bytes the render
//! produced, byte for byte.

const std = @import("std");
const common = @import("common.zig");

/// One request to send and what the answer must be.
const Case = struct {
    what: []const u8,
    method: []const u8,
    route: []const u8,
    body: []const u8 = "",
    want_status: u16,
    want_body_substr: ?[]const u8 = null,
};

/// A body the record takes, minified the way a client on the wire sends it.
const VALID_BODY =
    "{\"id\":42,\"customer\":\"Ada\",\"status\":\"PENDING\",\"tags\":[\"gift\"]," ++
    "\"lines\":[{\"sku\":\"AB-1\",\"qty\":2,\"price_cents\":1299}]}";

/// The same body plus a key the record does not declare, nested so skipping it has
/// to step over a whole object rather than one scalar.
const EXTRA_KEY_BODY =
    "{\"id\":42,\"customer\":\"Ada\",\"status\":\"PENDING\",\"tags\":[]," ++
    "\"lines\":[],\"coupon\":{\"code\":\"X\",\"off\":5}}";

const cases = [_]Case{
    .{
        .what = "the catalog order is rendered whole",
        .method = "GET",
        .route = "/order",
        .want_status = 200,
        .want_body_substr = "\"customer\":\"Rekha Nair\"",
    },
    .{
        // 1299 * 2, summed off the lines the parse read back.
        .what = "a body the record takes is answered with a receipt",
        .method = "POST",
        .route = "/order",
        .body = VALID_BODY,
        .want_status = 200,
        .want_body_substr = "\"total_cents\":2598",
    },
    .{
        .what = "an unknown key is refused by name on the strict route",
        .method = "POST",
        .route = "/order",
        .body = EXTRA_KEY_BODY,
        .want_status = 400,
        .want_body_substr = "UnknownField",
    },
    .{
        .what = "the same unknown key is stepped over on the lenient route",
        .method = "POST",
        .route = "/order/lenient",
        .body = EXTRA_KEY_BODY,
        .want_status = 200,
        .want_body_substr = "\"order_id\":42",
    },
    .{
        .what = "an enum value the record has no tag for is refused",
        .method = "POST",
        .route = "/order",
        .body = "{\"id\":42,\"customer\":\"Ada\",\"status\":\"GONE\",\"tags\":[],\"lines\":[]}",
        .want_status = 400,
        .want_body_substr = "UnknownEnumValue",
    },
    .{
        .what = "a body that stops mid-document is refused",
        .method = "POST",
        .route = "/order",
        .body = "{\"id\":42,\"customer\":\"Ada\"",
        .want_status = 400,
        .want_body_substr = "Truncated",
    },
    .{
        .what = "a body missing a field the record declares is refused",
        .method = "POST",
        .route = "/order",
        .body = "{\"id\":42,\"customer\":\"Ada\",\"status\":\"PENDING\",\"tags\":[]}",
        .want_status = 400,
        .want_body_substr = "MissingField",
    },
    .{
        .what = "an empty body is refused before the parse runs",
        .method = "POST",
        .route = "/order",
        .want_status = 400,
        .want_body_substr = "empty body",
    },
    .{
        .what = "a GET on the lenient route draws 405",
        .method = "GET",
        .route = "/order/lenient",
        .want_status = 405,
    },
};

// --------------------------------------------------------- //

/// Build one raw HTTP/1.1 request. Connection: close, so the server closes after
/// the body and the read side sees a clean end.
fn buildRequest(buf: []u8, method: []const u8, route: []const u8, body: []const u8) ![]const u8 {
    var len: usize = 0;

    len += (try std.fmt.bufPrint(buf[len..], "{s} {s} HTTP/1.1\r\nHost: 127.0.0.1\r\n", .{ method, route })).len;
    len += (try std.fmt.bufPrint(buf[len..], "Content-Type: application/json\r\n", .{})).len;
    len += (try std.fmt.bufPrint(buf[len..], "Content-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ body.len, body })).len;

    return buf[0..len];
}

/// Send one request on its own connection and read the whole answer.
fn exchange(io: std.Io, port: u16, method: []const u8, route: []const u8, body: []const u8, out: []u8) ![]const u8 {
    const addr = try std.Io.net.IpAddress.parse("127.0.0.1", port);
    const stream = try addr.connect(io, .{ .mode = .stream, .protocol = .tcp });
    defer stream.close(io);

    var req_buf: [2048]u8 = undefined;
    const req = try buildRequest(&req_buf, method, route, body);

    var write_buf: [2048]u8 = undefined;
    var writer = stream.writer(io, &write_buf);
    try writer.interface.writeAll(req);
    try writer.interface.flush();

    var read_buf: [2048]u8 = undefined;
    var reader = stream.reader(io, &read_buf);
    var total: usize = 0;
    while (total < out.len) {
        const read = reader.interface.readSliceShort(out[total..]) catch break;
        if (read == 0) break;
        total += read;
    }

    return out[0..total];
}

/// The status line code, or an error when the answer is not an HTTP response.
fn statusOf(resp: []const u8) !u16 {
    const prefix = "HTTP/1.1 ";
    if (!std.mem.startsWith(u8, resp, prefix)) return error.NotAnHttpResponse;

    const rest = resp[prefix.len..];
    if (rest.len < 3) return error.TruncatedStatusLine;

    return std.fmt.parseInt(u16, rest[0..3], 10) catch error.BadStatusLine;
}

fn bodyOf(resp: []const u8) []const u8 {
    const head_end = std.mem.indexOf(u8, resp, "\r\n\r\n") orelse return &.{};

    return resp[head_end + 4 ..];
}

/// GET the rendered order, POST those exact bytes back, and check the receipt adds
/// up. This is the one case the table cannot carry: the request body is whatever
/// the render just wrote, not a literal.
fn roundTrip(io: std.Io, port: u16, resp_buf: []u8) !void {
    var rendered_buf: [1024]u8 = undefined;

    const rendered = blk: {
        const resp = try exchange(io, port, "GET", "/order", "", resp_buf);
        if (try statusOf(resp) != 200) return error.RoundTripGetFailed;

        const body = bodyOf(resp);
        if (body.len == 0 or body.len > rendered_buf.len) return error.RoundTripBodyUnusable;

        @memcpy(rendered_buf[0..body.len], body);
        break :blk rendered_buf[0..body.len];
    };

    const resp = try exchange(io, port, "POST", "/order", rendered, resp_buf);
    if (try statusOf(resp) != 200) return error.RoundTripPostFailed;

    // 1299 * 2 plus 4500 * 1, off the lines the render wrote and the parse read.
    if (!std.mem.containsAtLeast(u8, bodyOf(resp), 1, "\"total_cents\":7098")) {
        std.debug.print("FAIL jzon round trip: receipt does not total the rendered lines\n", .{});
        return error.UnexpectedBody;
    }
}

/// Spawn the jzon example and walk every case against it, then round trip.
///
/// Param:
/// io - std.Io
/// server_path - []const u8 (the built example binary)
/// port - u16 (the port that example listens on)
///
/// Return:
/// - void
/// - An error naming the first case that answered wrong
pub fn runJzon(io: std.Io, server_path: []const u8, port: u16) !void {
    var server_child = try common.spawnServer(io, server_path);
    defer server_child.kill(io);

    try common.waitForTcpPort(io, &server_child, port, common.START_TIMEOUT_MS);

    var resp_buf: [8192]u8 = undefined;

    for (cases) |case| {
        const resp = try exchange(io, port, case.method, case.route, case.body, &resp_buf);
        const status = try statusOf(resp);

        if (status != case.want_status) {
            std.debug.print("FAIL jzon case: {s}, got {d} want {d}\n", .{ case.what, status, case.want_status });
            return error.UnexpectedStatus;
        }

        if (case.want_body_substr) |want| {
            if (!std.mem.containsAtLeast(u8, bodyOf(resp), 1, want)) {
                std.debug.print("FAIL jzon case: {s}, body does not carry {s}\n", .{ case.what, want });
                return error.UnexpectedBody;
            }
        }
    }

    try roundTrip(io, port, &resp_buf);
}
