// Test runner for the high-level zix.Http.Client HTTP/2 backend (examples/tls/tls_http2_basic.zig).
// Spawns the h2 https server, then issues a GET through zix.Http.Client with version = HTTP_2 and
// tls_ca_path pointing at the fixture cert. This exercises the native ALPN-h2 transport end to end
// (TLS 1.3 handshake + cert trust + h2 framing) behind the ordinary client API, asserting status
// 200 and the expected body. No curl, no manual frame handling.
//
// Invoked by `zig build test-runner-tls-http2-client`.
// argv[1]: server binary path, argv[2]: label, argv[3]: port.

const std = @import("std");
const zix = @import("zix");
const common = @import("common.zig");

const WAIT_MS: u64 = 5000;
const CA_PATH = "examples/tls/certs/ecdsa_p256_cert.pem";

// --------------------------------------------------------- //

pub fn main(process: std.process.Init) void {
    var arg_iter = std.process.Args.Iterator.init(process.minimal.args);
    _ = arg_iter.skip();
    const server_path = arg_iter.next() orelse {
        std.debug.print("FAIL tls-http2-client: missing server path\n", .{});
        std.process.exit(1);
    };
    const label = arg_iter.next() orelse {
        std.debug.print("FAIL tls-http2-client: missing label\n", .{});
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

    var client = zix.Http.Client.init(.{
        .allocator = arena.allocator(),
        .io = io,
        .version = .HTTP_2,
        .tls_ca_path = CA_PATH,
        .max_response_body = 16384,
    });
    defer client.deinit();

    // host "localhost" matches the fixture cert SAN (DNS:localhost), so cert hostname verify passes.
    var url_buf: [128]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "https://localhost:{d}/", .{port});

    var resp = try client.get(url, .{});
    defer resp.deinit();

    if (resp.status() != 200) return error.UnexpectedStatus;
    if (!std.mem.containsAtLeast(u8, resp.body(), 1, "hello over h2 tls 1.3")) return error.MissingExpectedBody;

    // one request per run: the example's TLS terminator serves a single connection, and this proves
    // the zix.Http.Client h2 backend (handshake + cert trust + h2 framing) end to end.
}
