//! Client side of the http1-family demo rows: plain proxy, sse, websocket,
//! static-only, mixed, and round robin.
//!
//! Each function drives a native zix client against the edge port and asserts
//! what the site config promises. The runner owns the daemon and the upstreams,
//! so nothing here spawns a process.

const std = @import("std");
const zix = @import("zix");

const common = @import("runner_common");

/// Body the echo route must return byte for byte.
const ECHO_PAYLOAD: []const u8 = "zixer runner payload";
/// Longest reply any of these checks reads.
const MAX_BODY: usize = 64 * 1024;

// --------------------------------------------------------- //

/// Plain proxy: the reply comes from the upstream, the response carries zixer's
/// Via, and the upstream saw both Via and Forwarded. Then a body round trip.
pub fn runHttp1(io: std.Io, port: u16) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();

    var client = newClient(arena.allocator(), io);
    defer client.deinit();

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/", .{port});

    var resp = try client.get(url, .{});
    defer resp.deinit();

    if (resp.status() != 200) return error.ZixUnexpectedStatus;
    if (resp.header("Via") == null) return error.MissingVia;
    if (std.mem.indexOf(u8, resp.body(), "upstream: proxies/http1") == null) return error.NotFromUpstream;
    if (std.mem.indexOf(u8, resp.body(), "via: 1.1 zixer") == null) return error.UpstreamMissedVia;
    if (std.mem.indexOf(u8, resp.body(), "forwarded: for=") == null) return error.UpstreamMissedForwarded;

    var echo_url_buf: [64]u8 = undefined;
    const echo_url = try std.fmt.bufPrint(&echo_url_buf, "http://127.0.0.1:{d}/echo", .{port});

    var echo = try client.post(echo_url, .{ .body = ECHO_PAYLOAD });
    defer echo.deinit();

    if (echo.status() != 200) return error.UnexpectedEchoStatus;
    if (!std.mem.eql(u8, echo.body(), ECHO_PAYLOAD)) return error.EchoMismatch;
}

/// Server-sent events: two events arrive one at a time. A relay that buffered
/// the stream would hand back nothing until the upstream closed it.
pub fn runSse(io: std.Io, port: u16) !void {
    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/events", .{port});

    var sse_client = zix.Http.SseClient.init(.{
        .io = io,
        .connect_timeout_ms = 3000,
        .response_timeout_ms = common.RESPONSE_TIMEOUT_MS,
        .read_timeout_ms = common.RESPONSE_TIMEOUT_MS,
    });
    var stream = try sse_client.open(url);
    defer stream.deinit();

    var seen: usize = 0;
    while (seen < 2) : (seen += 1) {
        var buf: [4096]u8 = undefined;
        const event = try stream.next(&buf) orelse return error.StreamEndedEarly;

        if (std.mem.indexOf(u8, event.data, "tick") == null) return error.UnexpectedEvent;
    }
}

/// WebSocket: the upgrade crosses the proxy and the tunnel echoes.
pub fn runWs(io: std.Io, port: u16) !void {
    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "ws://127.0.0.1:{d}/ws", .{port});

    var ws_client = zix.Http.WsClient.init(.{
        .io = io,
        .connect_timeout_ms = 3000,
        .response_timeout_ms = common.RESPONSE_TIMEOUT_MS,
        .read_timeout_ms = common.RESPONSE_TIMEOUT_MS,
    });
    var conn = try ws_client.connect(url);
    defer conn.deinit();

    try conn.send(.text, ECHO_PAYLOAD);

    var payload_buf: [256]u8 = undefined;
    const frame = try conn.recv(&payload_buf) orelse return error.NoWsFrame;

    if (!std.mem.eql(u8, frame.payload, ECHO_PAYLOAD)) return error.EchoMismatch;
}

/// Static-only site: the index page, an asset, and a deep link the spa
/// fallback answers with that same page.
pub fn runStatic(io: std.Io, port: u16) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();

    var client = newClient(arena.allocator(), io);
    defer client.deinit();

    var index_url_buf: [64]u8 = undefined;
    const index_url = try std.fmt.bufPrint(&index_url_buf, "http://127.0.0.1:{d}/", .{port});

    var index = try client.get(index_url, .{});
    defer index.deinit();

    if (index.status() != 200) return error.ZixUnexpectedStatus;
    if (std.mem.indexOf(u8, index.body(), "Served by zixer") == null) return error.NotTheIndexPage;
    if (index.header("Vary") == null) return error.MissingVary;

    var asset_url_buf: [64]u8 = undefined;
    const asset_url = try std.fmt.bufPrint(&asset_url_buf, "http://127.0.0.1:{d}/assets/app.css", .{port});

    var asset = try client.get(asset_url, .{});
    defer asset.deinit();

    if (asset.status() != 200) return error.UnexpectedAssetStatus;
    const asset_type = asset.header("Content-Type") orelse return error.MissingContentType;
    if (std.mem.indexOf(u8, asset_type, "text/css") == null) return error.UnexpectedAssetType;

    var deep_url_buf: [80]u8 = undefined;
    const deep_url = try std.fmt.bufPrint(&deep_url_buf, "http://127.0.0.1:{d}/docs/getting-started", .{port});

    var deep = try client.get(deep_url, .{});
    defer deep.deinit();

    if (deep.status() != 200) return error.SpaFallbackMissed;
    if (std.mem.indexOf(u8, deep.body(), "Served by zixer") == null) return error.SpaFallbackWrongPage;
}

/// Mixed site: the prefix is served from disk by zixer, everything else is the
/// upstream's. The Via header tells the two planes apart, since a file zixer
/// opened itself is an origin response and carries none.
pub fn runMixed(io: std.Io, port: u16) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();

    var client = newClient(arena.allocator(), io);
    defer client.deinit();

    var asset_url_buf: [64]u8 = undefined;
    const asset_url = try std.fmt.bufPrint(&asset_url_buf, "http://127.0.0.1:{d}/assets/app.css", .{port});

    var asset = try client.get(asset_url, .{});
    defer asset.deinit();

    if (asset.status() != 200) return error.UnexpectedAssetStatus;
    if (asset.header("Via") != null) return error.StaticPlaneProxied;

    var api_url_buf: [64]u8 = undefined;
    const api_url = try std.fmt.bufPrint(&api_url_buf, "http://127.0.0.1:{d}/api/health", .{port});

    var api = try client.get(api_url, .{});
    defer api.deinit();

    if (api.status() != 200) return error.UnexpectedApiStatus;
    if (api.header("Via") == null) return error.ApiPlaneNotProxied;
    if (std.mem.indexOf(u8, api.body(), "proxies/mixed") == null) return error.NotFromUpstream;
}

/// Round robin: four requests must reach both instances, and every one of them
/// must be answered.
pub fn runRoundRobin(io: std.Io, port: u16, first_port: u16, second_port: u16) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();

    var client = newClient(arena.allocator(), io);
    defer client.deinit();

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/", .{port});

    var first_mark_buf: [32]u8 = undefined;
    const first_mark = try std.fmt.bufPrint(&first_mark_buf, ":{d}", .{first_port});

    var second_mark_buf: [32]u8 = undefined;
    const second_mark = try std.fmt.bufPrint(&second_mark_buf, ":{d}", .{second_port});

    var saw_first = false;
    var saw_second = false;

    var attempt: usize = 0;
    while (attempt < 4) : (attempt += 1) {
        var resp = try client.get(url, .{});
        defer resp.deinit();

        if (resp.status() != 200) return error.ZixUnexpectedStatus;
        if (std.mem.indexOf(u8, resp.body(), first_mark) != null) saw_first = true;
        if (std.mem.indexOf(u8, resp.body(), second_mark) != null) saw_second = true;
    }

    if (!saw_first or !saw_second) return error.NoRotation;
}

// --------------------------------------------------------- //

/// One cleartext http client with the runner's timeouts.
fn newClient(allocator: std.mem.Allocator, io: std.Io) zix.Http.Client {
    return zix.Http.Client.init(.{
        .allocator = allocator,
        .io = io,
        .connect_timeout_ms = 3000,
        .response_timeout_ms = common.RESPONSE_TIMEOUT_MS,
        .read_timeout_ms = common.RESPONSE_TIMEOUT_MS,
        .max_response_body = MAX_BODY,
    });
}
