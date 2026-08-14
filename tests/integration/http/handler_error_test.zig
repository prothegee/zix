//! Integration tests: what zix.Http puts on the wire when a handler fails.
//!
//! One rule, checked over a real connection: a handler that returns an error is answered exactly
//! once. It answered nothing, the engine sends a 500. It already answered, the engine stays quiet.
//! An error the handler swallows itself is the handler's own business and the engine adds nothing.

const std = @import("std");
const zix = @import("zix");

const IP: []const u8 = "127.0.0.1";
const PORT: u16 = 18230;

// --------------------------------------------------------- //
// Handlers

/// Returns an error having answered nothing. The engine owes this request a 500.
fn errorBeforeAnswer(_: *zix.Http.Request, _: *zix.Http.Response, _: *zix.Http.Context) anyerror!void {
    return error.ZixProbeFailure;
}

/// Answers, then returns an error. The engine must not append a second status line.
fn answerThenError(_: *zix.Http.Request, res: *zix.Http.Response, _: *zix.Http.Context) anyerror!void {
    try res.sendText("answered first");

    return error.ZixProbeFailure;
}

/// Swallows its own failure and returns cleanly. The engine adds nothing, the handler owns it.
fn swallowedError(_: *zix.Http.Request, res: *zix.Http.Response, _: *zix.Http.Context) anyerror!void {
    res.sendText("swallowed") catch {
        // The send is against a live connection here, so reaching this block at all means the wire
        // broke and the status-line count below would be reading a truncated response.
        return error.ZixProbeFailure;
    };
}

const Routes = [_]zix.Http.Route{
    .{ .path = "/err-before", .handler = errorBeforeAnswer },
    .{ .path = "/err-after", .handler = answerThenError },
    .{ .path = "/caught", .handler = swallowedError },
};
const router = zix.Http.Router(&Routes);

// --------------------------------------------------------- //

/// The server thread runs forever (run() never returns), so what it holds is intentionally leaked
/// for the lifetime of the test binary.
fn serve(io: std.Io) void {
    var server = zix.Http.Server.init(router.dispatch, .{
        .io = io,
        .ip = IP,
        .port = PORT,
        .dispatch_model = .ASYNC,
        .workers = 1,
    });
    defer server.deinit();

    server.run() catch {};
}

fn connectRetry(io: std.Io) !std.Io.net.Stream {
    const addr = try std.Io.net.IpAddress.resolve(io, IP, PORT);

    var attempt: usize = 0;
    while (attempt < 100) : (attempt += 1) {
        if (addr.connect(io, .{ .mode = .stream })) |stream| {
            return stream;
        } else |_| {
            std.Io.sleep(io, std.Io.Duration.fromMilliseconds(20), .awake) catch {};
        }
    }

    return error.ServerNotUp;
}

var server_started = false;

fn startServerOnce() !void {
    if (server_started) return;
    server_started = true;

    // Leaked by design: the detached server thread outlives every test in this binary, so its io
    // cannot come from the testing allocator, which checks for leaks when each test ends.
    const gpa = std.heap.smp_allocator;

    const threaded = try gpa.create(std.Io.Threaded);
    threaded.* = std.Io.Threaded.init(gpa, .{});

    const thread = try std.Thread.spawn(.{}, serve, .{threaded.io()});
    thread.detach();
}

/// Send one request with Connection: close and read everything the server answers with, so a
/// second response glued onto the first is visible rather than left in the socket.
fn wireOf(io: std.Io, path: []const u8, buf: []u8) ![]u8 {
    var stream = try connectRetry(io);
    defer stream.close(io);

    var read_buf: [2048]u8 = undefined;
    var write_buf: [1024]u8 = undefined;
    var reader = stream.reader(io, &read_buf);
    var writer = stream.writer(io, &write_buf);

    var req_buf: [128]u8 = undefined;
    const req = try std.fmt.bufPrint(&req_buf, "GET {s} HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", .{path});
    try writer.interface.writeAll(req);
    try writer.interface.flush();

    // Connection: close, so the server ends the stream after answering: read to EOF, which is what
    // makes a second response glued onto the first visible instead of left in the socket.
    var total: usize = 0;
    while (total < buf.len) {
        const n = reader.interface.readSliceShort(buf[total..]) catch break;
        if (n == 0) break;

        total += n;
    }

    return buf[0..total];
}

fn countStatusLines(wire: []const u8) usize {
    return std.mem.count(u8, wire, "HTTP/1.1 ");
}

// --------------------------------------------------------- //

test "zix integration: a zix.Http handler error with nothing answered is completed as one 500" {
    try startServerOnce();

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{ .stack_size = 512 * 1024 });
    defer threaded.deinit();
    const io = threaded.io();

    var buf: [2048]u8 = undefined;
    const wire = try wireOf(io, "/err-before", &buf);

    std.log.info(".WIRE: {d} bytes, {d} status lines", .{ wire.len, countStatusLines(wire) });

    try std.testing.expectEqual(@as(usize, 1), countStatusLines(wire));
    try std.testing.expect(std.mem.indexOf(u8, wire, "HTTP/1.1 500 Internal Server Error") != null);
}

test "zix integration: a zix.Http answer followed by a handler error is not answered a second time" {
    try startServerOnce();

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{ .stack_size = 512 * 1024 });
    defer threaded.deinit();
    const io = threaded.io();

    var buf: [2048]u8 = undefined;
    const wire = try wireOf(io, "/err-after", &buf);

    try std.testing.expectEqual(@as(usize, 1), countStatusLines(wire));
    try std.testing.expect(std.mem.indexOf(u8, wire, "answered first") != null);
    try std.testing.expect(std.mem.indexOf(u8, wire, "500") == null);
}

test "zix integration: a zix.Http error the handler swallows gets nothing from the engine" {
    try startServerOnce();

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{ .stack_size = 512 * 1024 });
    defer threaded.deinit();
    const io = threaded.io();

    var buf: [2048]u8 = undefined;
    const wire = try wireOf(io, "/caught", &buf);

    try std.testing.expectEqual(@as(usize, 1), countStatusLines(wire));
    try std.testing.expect(std.mem.indexOf(u8, wire, "swallowed") != null);
    try std.testing.expect(std.mem.indexOf(u8, wire, "500") == null);
}
