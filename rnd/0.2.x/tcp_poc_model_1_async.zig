//! PoC: TCP Model 1: ASYNC: single accept loop + io.async() per connection.
//!
//! Concurrency: each accepted connection is dispatched via io.async().
//! workers and pool_size are ignored, always 1 accept thread.
//! After async_limit is reached, io.async() falls back to inline on the accept
//! thread. The accept loop stalls for that connection's lifetime.
//!
//! Protocol: length-prefix framing, [4 bytes u32 big-endian][N bytes payload].
//! Server echoes each message back verbatim.
//!
//! Self-contained: no imports from zix src.
//!
//! Run:  zig run rnd/tcp_poc_model_1_async.zig
//! Test: zig run rnd/tcp_poc_client.zig  (PORT = 9200)

const std = @import("std");

const IP: []const u8 = "127.0.0.1";
const PORT: u16 = 9200;
const MAX_MSG: usize = 4096;
const RESPONSE: []const u8 = "Hi from TCP Server";

// --------------------------------------------------------- //

fn handleConnection(stream: std.Io.net.Stream, io: std.Io) void {
    defer stream.close(io);

    var rd_buf: [MAX_MSG + 4]u8 = undefined;
    var wr_buf: [MAX_MSG + 4]u8 = undefined;
    var rd = stream.reader(io, &rd_buf);
    var wr = stream.writer(io, &wr_buf);

    while (true) {
        const len = rd.interface.takeVarInt(u32, .big, 4) catch break;
        if (len == 0 or len > MAX_MSG) break;

        var body: [MAX_MSG]u8 = undefined;
        rd.interface.readSliceAll(body[0..len]) catch break;

        std.debug.print("recv ({d} bytes): {s}\n", .{ len, body[0..len] });

        var hdr: [4]u8 = undefined;
        std.mem.writeInt(u32, &hdr, @intCast(RESPONSE.len), .big);
        wr.interface.writeAll(&hdr) catch break;
        wr.interface.writeAll(RESPONSE) catch break;
        wr.interface.flush() catch break;
    }
}

// --------------------------------------------------------- //

pub fn main(process: std.process.Init) !void {
    const io = process.io;

    const addr = try std.Io.net.IpAddress.resolve(io, IP, PORT);
    var net_server = try addr.listen(io, .{
        .mode = .stream,
        .protocol = .tcp,
        .reuse_address = true,
        .kernel_backlog = 4096,
    });
    defer net_server.deinit(io);

    std.debug.print("zix tcp server (async): {s}:{d}\n", .{ IP, PORT });

    while (true) {
        const stream = net_server.accept(io) catch |err| {
            std.debug.print("accept: {}\n", .{err});
            continue;
        };
        _ = io.async(handleConnection, .{ stream, io });
    }
}
