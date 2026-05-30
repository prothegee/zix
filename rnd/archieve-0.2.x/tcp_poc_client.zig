//! TCP PoC client — shared across all 3 server models.
//!
//! Connects, sends one framed message, reads the echo, prints result.
//! IP and PORT are runtime-overridable via CLI args; constants are the fallback.
//!
//! Run: zig run rnd/tcp_poc_client.zig
//!      zig run rnd/tcp_poc_client.zig -- --port 9201
//!      zig run rnd/tcp_poc_client.zig -- --ip 192.168.1.10 --port 9202
//!
//! Default port targets:
//!   9200  ->  tcp_poc_model_1_async.zig
//!   9201  ->  tcp_poc_model_2_pool.zig
//!   9202  ->  tcp_poc_model_3_mixed.zig

const std = @import("std");

const IP: []const u8 = "127.0.0.1";
const PORT: u16 = 9200;
const MAX_MSG: usize = 4096;
const MESSAGE: []const u8 = "Hello from TCP client";

// --------------------------------------------------------- //

pub fn main(process: std.process.Init) !void {
    const io = process.io;

    var ip: []const u8 = IP;
    var port: u16 = PORT;

    var args_it = std.process.Args.Iterator.init(process.minimal.args);
    _ = args_it.skip(); // skip argv[0]
    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--ip")) {
            if (args_it.next()) |val| ip = val;
        } else if (std.mem.eql(u8, arg, "--port")) {
            if (args_it.next()) |val| {
                port = std.fmt.parseInt(u16, val, 10) catch port;
            }
        }
    }

    const addr = try std.Io.net.IpAddress.resolve(io, ip, port);
    const stream = addr.connect(io, .{ .mode = .stream, .protocol = .tcp }) catch |err| {
        std.debug.print("error: cannot connect to {s}:{d}: {}\n", .{ ip, port, err });
        return;
    };
    defer stream.close(io);

    std.debug.print("connected: {s}:{d}\n", .{ ip, port });

    var rd_buf: [MAX_MSG + 4]u8 = undefined;
    var wr_buf: [MAX_MSG + 4]u8 = undefined;
    var rd = stream.reader(io, &rd_buf);
    var wr = stream.writer(io, &wr_buf);

    // send: [4-byte length][payload]
    var hdr: [4]u8 = undefined;
    std.mem.writeInt(u32, &hdr, @intCast(MESSAGE.len), .big);
    wr.interface.writeAll(&hdr) catch |err| {
        std.debug.print("error: send failed: {}\n", .{err});
        return;
    };
    wr.interface.writeAll(MESSAGE) catch |err| {
        std.debug.print("error: send failed: {}\n", .{err});
        return;
    };
    wr.interface.flush() catch |err| {
        std.debug.print("error: flush failed: {}\n", .{err});
        return;
    };

    std.debug.print("sent ({d} bytes): {s}\n", .{ MESSAGE.len, MESSAGE });

    // recv: [4-byte length][payload]
    const len = rd.interface.takeVarInt(u32, .big, 4) catch |err| {
        std.debug.print("error: recv failed: {}\n", .{err});
        return;
    };
    var body: [MAX_MSG]u8 = undefined;
    rd.interface.readSliceAll(body[0..len]) catch |err| {
        std.debug.print("error: recv body failed: {}\n", .{err});
        return;
    };

    std.debug.print("echo ({d} bytes): {s}\n", .{ len, body[0..len] });
}
