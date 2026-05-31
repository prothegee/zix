// uds_http.zig: HTTP frontend backed by a UDS data provider (Process B)
//
// Requires uds_server running on /tmp/zix.sock (Process A).
//
// Architecture:
//   [uds_server]->/tmp/zix.sock->[uds fetcher task]->Channel(u64)->[SSE handler]
//                                                               \->[/data handler]
//
// Endpoints:
// GET /data: one-shot UDS query, returns JSON {"count": N}
// GET /stream: SSE stream, queries UDS every 500 ms via Channel, streams events
//
// Run:
// zig build example-uds_http && ./zig-out/bin/example-uds_http
// curl http://localhost:9200/data
// curl -N http://localhost:9200/stream
// browser: http://localhost:9200/

const std = @import("std");
const zix = @import("zix");

const IP: []const u8 = "127.0.0.1";
const PORT: u16 = 9200;
const SOCK_PATH: []const u8 = "/tmp/zix.sock";

const MAX_KERNEL_BACKLOG: usize = 1024;
const MAX_CLIENT_REQUEST: usize = 1024 * 4;
const MAX_ALLOCATOR_SIZE: usize = 1024 * 4;
const MAX_CLIENT_RESPONSE: usize = 1024 * 8;

// --------------------------------------------------------- //

// Channel between the UDS fetcher task and SSE handlers.
// Capacity 16: absorbs bursts without blocking the fetcher.
const CountChan = zix.Channel(u64);
var g_channel: CountChan = undefined;

// --------------------------------------------------------- //

// Fetcher task capture: passed by value to io.concurrent so it must be copyable.
const FetchCap = struct {
    io: std.Io,
};

// Background task: maintains a persistent UDS connection to the data server.
// Sends a "get" frame every 500 ms, reads the counter reply, pushes into g_channel.
// On connection failure it waits 1 s and reconnects.
fn fetcherTask(cap: FetchCap) void {
    const io = cap.io;

    while (true) {
        var client = zix.Uds.Client.connect(.{ .path = SOCK_PATH }, io) catch {
            std.Io.sleep(io, std.Io.Duration.fromMilliseconds(1000), .awake) catch {};
            continue;
        };
        defer client.deinit(io);

        while (true) {
            client.sendMsg(io, "get") catch break;

            var buf: [32]u8 = undefined;
            const reply = client.recvMsg(io, &buf) catch break;
            const count = std.fmt.parseInt(u64, reply, 10) catch break;

            g_channel.send(io, count) catch break;

            std.Io.sleep(io, std.Io.Duration.fromMilliseconds(500), .awake) catch break;
        }

        std.debug.print("uds_http: UDS connection lost, reconnecting...\n", .{});
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(1000), .awake) catch {};
    }
}

// --------------------------------------------------------- //

// GET /data: one-shot UDS query, returns {"count": N}
pub fn dataHandler(req: *zix.Http.Request, res: *zix.Http.Response, ctx: *zix.Http.Context) !void {
    _ = req;

    var client = zix.Uds.Client.connect(.{ .path = SOCK_PATH }, ctx.io) catch {
        res.setStatus(.SERVICE_UNAVAILABLE);
        return res.send("UDS server unavailable");
    };
    defer client.deinit(ctx.io);

    client.sendMsg(ctx.io, "get") catch {
        res.setStatus(.SERVICE_UNAVAILABLE);
        return res.send("UDS send failed");
    };

    var buf: [32]u8 = undefined;
    const reply = client.recvMsg(ctx.io, &buf) catch {
        res.setStatus(.SERVICE_UNAVAILABLE);
        return res.send("UDS recv failed");
    };

    var json_buf: [64]u8 = undefined;
    const body = std.fmt.bufPrint(&json_buf, "{{\"count\": {s}}}", .{reply}) catch return;
    res.setContentType(.APPLICATION_JSON);
    try res.send(body);
}

// GET /stream: SSE stream, reads from Channel, sends one event per value
pub fn streamHandler(req: *zix.Http.Request, res: *zix.Http.Response, ctx: *zix.Http.Context) !void {
    _ = req;

    const sse = try res.stream();
    while (true) {
        const count = g_channel.recv(ctx.io) catch break;
        var buf: [32]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "count: {d}", .{count}) catch break;
        sse.writeEvent(msg) catch break;
    }
}

// GET /: HTML page with EventSource and a fetch button
pub fn homeHandler(req: *zix.Http.Request, res: *zix.Http.Response, ctx: *zix.Http.Context) !void {
    _ = req;
    _ = ctx;
    res.setContentType(.TEXT_HTML);
    try res.send(
        \\<!DOCTYPE html>
        \\<html>
        \\<head><meta charset="utf-8"><title>zix UDS + Channel</title></head>
        \\<body>
        \\<h2>zix UDS + Channel demo</h2>
        \\<button onclick="fetchData()">GET /data (one-shot)</button>
        \\<pre id="data" style="font-family:monospace"></pre>
        \\<h3>SSE stream (/stream)</h3>
        \\<pre id="stream-val" style="font-family:monospace">waiting...</pre>
        \\<script>
        \\async function fetchData() {
        \\  const r = await fetch('/data');
        \\  document.getElementById('data').textContent = await r.text();
        \\}
        \\const es = new EventSource('/stream');
        \\es.onmessage = e => { document.getElementById('stream-val').textContent = e.data; };
        \\es.onerror = () => { document.getElementById('stream-val').textContent = '[reconnecting...]'; };
        \\</script>
        \\</body>
        \\</html>
    );
}

// --------------------------------------------------------- //

pub fn main(process: std.process.Init) !void {
    const io = process.io;

    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();

    // Channel is used for the lifetime of the process, init before server.
    g_channel = try CountChan.init(arena.allocator(), 16);
    defer g_channel.deinit();

    // Spawn the background UDS fetcher as a concurrent task.
    // It runs alongside the HTTP accept loop for the process lifetime.
    if (io.concurrent(fetcherTask, .{FetchCap{ .io = io }})) |_| {} else |err| {
        std.debug.print("uds_http: fetcher spawn error: {}\n", .{err});
    }

    var server = try zix.Http.Server.init(4096, &[_]zix.Http.Route{
        .{ .path = "/data", .handler = dataHandler },
        .{ .path = "/stream", .handler = streamHandler },
        .{ .path = "/", .handler = homeHandler },
    }, .{
        .io = io,
        .ip = IP,
        .port = PORT,
        .max_kernel_backlog = MAX_KERNEL_BACKLOG,
        .max_client_request = MAX_CLIENT_REQUEST,
        .max_allocator_size = MAX_ALLOCATOR_SIZE,
        .max_client_response = MAX_CLIENT_RESPONSE,
        .dispatch_model = .ASYNC, // .ASYNC preferred for SSE: long-lived connections do not hold pool threads
    });
    defer server.deinit();

    std.debug.print("uds_http: listening on {s}:{d}\n", .{ IP, PORT });
    try server.run();
}
