// HTTP/3 static file serving from public_dir, over QUIC. Any request matching no route falls
// through to the engine static fallback, which serves files out of the process static cache.
//
// This engine differs from zix.Http1 / zix.Http / zix.Http2 in one way worth knowing. An HTTP/3
// response body OUTLIVES the handler: a file too large for one packet is parked in a send-stream
// slot and read again for every packet, and again for every retransmission after a loss, until the
// client has acknowledged all of it. So the body has to be stable memory, which is why static
// serving here is only active when public_dir_cache_ttl_ms is above 0. With caching off, an
// unmatched path goes straight to 404 rather than serving something the engine could not hold.

const std = @import("std");
const zix = @import("zix");

// --------------------------------------------------------- //

const IP: []const u8 = "127.0.0.1";
const PORT: u16 = 9078;
// Demo fixtures. For a real domain, point CERT / KEY at your certbot files:
// CERT: /etc/letsencrypt/live/sub.domain.tld/fullchain.pem
// KEY: /etc/letsencrypt/live/sub.domain.tld/privkey.pem
const CERT: []const u8 = "examples/certs/ecdsa_p256_cert.pem";
const KEY: []const u8 = "examples/certs/ecdsa_p256_key.pem";

const PUBLIC_DIR = "./public-h3";

// Required for static serving on this engine, not merely an optimization. See the note above.
const PUBLIC_DIR_CACHE_TTL_MS: u32 = 30_000;
const PUBLIC_DIR_CACHE_MAX_ENTRIES: u32 = 64;

// Large enough to cross the single-packet path and be fragmented by the pump across many packets,
// which is the case that needs the body to outlive the handler.
const BIG_FILE_SIZE: usize = 256 * 1024;

// --------------------------------------------------------- //

fn seedDemoFiles(io: std.Io) void {
    std.Io.Dir.cwd().createDirPath(io, PUBLIC_DIR) catch {};

    writeFile(io, PUBLIC_DIR ++ "/hello.txt", "served from public_dir over http/3\n");

    // A precompressed sibling pair. The engine picks one from Accept-Encoding, resolved once when
    // the cache entry is built. These stand in for real brotli output: this example is about which
    // file is picked and which content-encoding is emitted, so the bytes are plain text on purpose.
    writeFile(io, PUBLIC_DIR ++ "/app.js", "console.log('identity build');\n");
    writeFile(io, PUBLIC_DIR ++ "/app.js.br", "pretend-brotli\n");

    var big: [BIG_FILE_SIZE]u8 = undefined;
    for (&big, 0..) |*byte, index| byte.* = @intCast('a' + index % 26);
    writeFile(io, PUBLIC_DIR ++ "/big.bin", &big);
}

fn writeFile(io: std.Io, path: []const u8, data: []const u8) void {
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data }) catch {};
}

// --------------------------------------------------------- //

fn home(_: *const zix.Http3.Request, res: *zix.Http3.Response, _: *zix.Http3.Context) !void {
    res.send("try /hello.txt, /app.js and /big.bin\n");
}

// --------------------------------------------------------- //

// Only "/" is routed. Everything else falls through to the static fallback.
//
// curl usage:
// curl --http3-only -k https://127.0.0.1:9078/hello.txt
// curl --http3-only -k --compressed -D- https://127.0.0.1:9078/app.js   (-> content-encoding: br)
// curl --http3-only -k https://127.0.0.1:9078/big.bin -o /dev/null -w '%{size_download}\n' (-> 262144)
// curl --http3-only -k -o /dev/null -w '%{http_code}\n' https://127.0.0.1:9078/absent.txt  (-> 404)
const Routes = zix.Http3.Router(&[_]zix.Http3.Route{
    .{ .path = "/", .handler = home },
});

pub fn main(process: std.process.Init) !void {
    seedDemoFiles(process.io);

    var tls = try zix.Tls.Context.init(std.heap.smp_allocator, process.io, .{
        .cert_path = CERT,
        .key_path = KEY,
    });
    defer tls.deinit();

    var server = zix.Http3.Server.init(Routes.dispatch, .{
        .io = process.io,
        .allocator = std.heap.smp_allocator,
        .ip = IP,
        .port = PORT,
        .dispatch_model = .ASYNC,
        .tls = &tls,
        .public_dir = PUBLIC_DIR,
        .public_dir_cache_ttl_ms = PUBLIC_DIR_CACHE_TTL_MS,
        .public_dir_cache_max_entries = PUBLIC_DIR_CACHE_MAX_ENTRIES,
    });
    defer server.deinit();

    try server.run();
}
