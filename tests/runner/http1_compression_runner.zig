// Test runner for the zix.Http1 response-compression example (http1_compression).
// Uses a raw TCP socket so the exact Accept-Encoding is under test control (the
// std-backed Http.Client injects its own Accept-Encoding: gzip, which would mask
// deflate and identity negotiation). For /data it checks that:
//   - Accept-Encoding: gzip    -> Content-Encoding: gzip, body decodes to the original
//   - Accept-Encoding: deflate -> Content-Encoding: deflate, body decodes to the original
//   - no Accept-Encoding       -> no Content-Encoding, body is the original
// and that a body under the size floor (/ping) is never compressed.
//
// Invoked by `zig build test-runner-http1-compression`.
// argv[1]: server binary path, argv[2]: label, argv[3]: port.

const std = @import("std");
const zix = @import("zix");
const common = @import("common.zig");
const flate = zix.utils.compression.flate;

const WAIT_MS: u64 = 5000;
const EXPECTED_PREFIX: []const u8 = "zix response compression demo";

// --------------------------------------------------------- //

pub fn main(process: std.process.Init) void {
    var arg_iter = std.process.Args.Iterator.init(process.minimal.args);
    _ = arg_iter.skip();
    const server_path = arg_iter.next() orelse {
        std.debug.print("FAIL http1-compression: missing server path\n", .{});
        std.process.exit(1);
    };
    const label = arg_iter.next() orelse {
        std.debug.print("FAIL http1-compression: missing label\n", .{});
        std.process.exit(1);
    };
    const port_str = arg_iter.next() orelse {
        std.debug.print("FAIL {s}: missing port\n", .{label});
        std.process.exit(1);
    };
    const port = std.fmt.parseInt(u16, port_str, 10) catch {
        std.debug.print("FAIL {s}: invalid port\n", .{label});
        std.process.exit(1);
    };

    run(process.io, server_path, port) catch |err| {
        std.debug.print("FAIL {s}: {}\n", .{ label, err });
        std.process.exit(1);
    };
    common.printPass(label);
}

fn run(io: std.Io, server_path: []const u8, port: u16) !void {
    var server_child = try common.spawnServer(io, server_path);
    defer server_child.kill(io);

    try common.waitForTcpPort(io, &server_child, port, WAIT_MS);

    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var resp_buf: [8192]u8 = undefined;

    // gzip: compressed, decodes back to the original.
    {
        const resp = try request(io, port, "/data", "gzip", &resp_buf);
        if (!statusIs200(resp)) return error.UnexpectedStatus;
        const enc = headerValue(resp, "content-encoding") orelse return error.MissingContentEncoding;
        if (!std.mem.eql(u8, enc, "gzip")) return error.WrongEncoding;

        const restored = try flate.decompressGzipAlloc(alloc, bodyOf(resp), 4096);
        if (!std.mem.startsWith(u8, restored, EXPECTED_PREFIX)) return error.BadRoundtrip;
    }

    // deflate: compressed with the zlib container, decodes back to the original.
    {
        const resp = try request(io, port, "/data", "deflate", &resp_buf);
        if (!statusIs200(resp)) return error.UnexpectedStatus;
        const enc = headerValue(resp, "content-encoding") orelse return error.MissingContentEncoding;
        if (!std.mem.eql(u8, enc, "deflate")) return error.WrongEncoding;

        const restored = try flate.decompressDeflateAlloc(alloc, bodyOf(resp), 4096);
        if (!std.mem.startsWith(u8, restored, EXPECTED_PREFIX)) return error.BadRoundtrip;
    }

    // no Accept-Encoding: identity, the original bytes unchanged.
    {
        const resp = try request(io, port, "/data", null, &resp_buf);
        if (!statusIs200(resp)) return error.UnexpectedStatus;
        if (headerValue(resp, "content-encoding") != null) return error.UnexpectedContentEncoding;
        if (!std.mem.startsWith(u8, bodyOf(resp), EXPECTED_PREFIX)) return error.UnexpectedBody;
    }

    // under the size floor: never compressed, even when gzip is accepted.
    {
        const resp = try request(io, port, "/ping", "gzip", &resp_buf);
        if (!statusIs200(resp)) return error.UnexpectedStatus;
        if (headerValue(resp, "content-encoding") != null) return error.FloorNotApplied;
        if (!std.mem.eql(u8, bodyOf(resp), "pong")) return error.UnexpectedBody;
    }
}

// Send one HTTP/1.1 request over a raw socket and read the whole response
// (Connection: close, so the server closes after the body and the read sees EOF).
fn request(io: std.Io, port: u16, path: []const u8, accept_encoding: ?[]const u8, out: []u8) ![]const u8 {
    const addr = try std.Io.net.IpAddress.parse("127.0.0.1", port);
    const stream = try addr.connect(io, .{ .mode = .stream, .protocol = .tcp });
    defer stream.close(io);

    var req_buf: [256]u8 = undefined;
    const req = if (accept_encoding) |enc|
        try std.fmt.bufPrint(&req_buf, "GET {s} HTTP/1.1\r\nHost: 127.0.0.1\r\nAccept-Encoding: {s}\r\nConnection: close\r\n\r\n", .{ path, enc })
    else
        try std.fmt.bufPrint(&req_buf, "GET {s} HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n", .{path});

    var write_buf: [512]u8 = undefined;
    var writer = stream.writer(io, &write_buf);
    try writer.interface.writeAll(req);
    try writer.interface.flush();

    var read_buf: [2048]u8 = undefined;
    var reader = stream.reader(io, &read_buf);
    var total: usize = 0;
    while (total < out.len) {
        const n = reader.interface.readSliceShort(out[total..]) catch break;
        if (n == 0) break;
        total += n;
    }

    return out[0..total];
}

fn statusIs200(resp: []const u8) bool {
    return std.mem.startsWith(u8, resp, "HTTP/1.1 200 ");
}

// Case-insensitive lookup of a response header value (between ": " and CRLF), scoped
// to the header block before the body. Returns null when absent.
fn headerValue(resp: []const u8, name: []const u8) ?[]const u8 {
    const head_end = std.mem.indexOf(u8, resp, "\r\n\r\n") orelse resp.len;
    const head = resp[0..head_end];

    var line_iter = std.mem.splitSequence(u8, head, "\r\n");
    _ = line_iter.next(); // skip the status line
    while (line_iter.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " \t"), name)) {
            return std.mem.trim(u8, line[colon + 1 ..], " \t");
        }
    }

    return null;
}

fn bodyOf(resp: []const u8) []const u8 {
    const sep = std.mem.indexOf(u8, resp, "\r\n\r\n") orelse return &.{};

    return resp[sep + 4 ..];
}
