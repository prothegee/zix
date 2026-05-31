//! FIX 4.x PoC client — Logon, send a NewOrderSingle, receive echo, Logout.
//!
//! Self-contained: no imports from zix src.
//!
//! Run:
//!   zig run rnd/fix_poc_client.zig
//!   zig run rnd/fix_poc_client.zig -- --port 9401 --target MY_SERVER

const std = @import("std");
const core = @import("fix_poc_core.zig");

const DEFAULT_IP: []const u8 = "127.0.0.1";
const DEFAULT_PORT: u16 = 9400;
const DEFAULT_TARGET: []const u8 = "SERVER";
const COMP_ID: []const u8 = "CLIENT";

pub fn main(process: std.process.Init) !void {
    var ip: []const u8 = DEFAULT_IP;
    var port: u16 = DEFAULT_PORT;
    var target: []const u8 = DEFAULT_TARGET;

    var args = std.process.Args.Iterator.init(process.minimal.args);
    _ = args.next();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--ip")) {
            ip = args.next() orelse return error.MissingArg;
        } else if (std.mem.eql(u8, arg, "--port")) {
            const s = args.next() orelse return error.MissingArg;
            port = try std.fmt.parseInt(u16, s, 10);
        } else if (std.mem.eql(u8, arg, "--target")) {
            target = args.next() orelse return error.MissingArg;
        }
    }

    const io = process.io;

    const addr = try std.Io.net.IpAddress.resolve(io, ip, port);
    const stream = try addr.connect(io, .{ .mode = .stream, .protocol = .tcp });
    defer stream.close(io);

    var rd_buf: [core.MAX_MSG_SIZE]u8 = undefined;
    var wr_buf: [core.MAX_MSG_SIZE]u8 = undefined;
    var rd = stream.reader(io, &rd_buf);
    var wr = stream.writer(io, &wr_buf);

    var seq_out: u32 = 1;
    var out_buf: [core.MAX_MSG_SIZE]u8 = undefined;
    var recv_buf: [core.MAX_MSG_SIZE * 2]u8 = undefined;
    var recv_len: usize = 0;

    // Logon
    {
        const extra = [_]core.BuildField{
            .{ .tag = 98, .value = "0" },
            .{ .tag = 108, .value = "30" },
        };
        const n = try core.buildMessage(&out_buf, COMP_ID, target, seq_out, "A", &extra);
        seq_out += 1;
        try wr.interface.writeAll(out_buf[0..n]);
        try wr.interface.flush();
        std.debug.print("client: sent Logon\n", .{});
    }

    // Receive Logon response.
    {
        const raw = try recvMessage(&rd.interface, &recv_buf, &recv_len);
        var fields: [core.MAX_FIELDS]core.Field = undefined;
        const nf = try core.parseFields(raw, &fields);
        const msgtype = core.getField(fields[0..nf], 35) orelse return error.MissingMsgType;
        if (!std.mem.eql(u8, msgtype, "A")) return error.ExpectedLogon;
        std.debug.print("client: recv Logon from server\n", .{});
    }

    // Send NewOrderSingle (35=D)
    {
        const extra = [_]core.BuildField{
            .{ .tag = 11, .value = "ORD001" }, // ClOrdID
            .{ .tag = 55, .value = "AAPL" }, // Symbol
            .{ .tag = 54, .value = "1" }, // Side: Buy
            .{ .tag = 38, .value = "100" }, // OrderQty
            .{ .tag = 40, .value = "2" }, // OrdType: Limit
            .{ .tag = 44, .value = "150.00" }, // Price
        };
        const n = try core.buildMessage(&out_buf, COMP_ID, target, seq_out, "D", &extra);
        seq_out += 1;
        try wr.interface.writeAll(out_buf[0..n]);
        try wr.interface.flush();
        std.debug.print("client: sent NewOrderSingle\n", .{});
    }

    // Receive echo.
    {
        const raw = try recvMessage(&rd.interface, &recv_buf, &recv_len);
        var fields: [core.MAX_FIELDS]core.Field = undefined;
        const nf = try core.parseFields(raw, &fields);
        const fslice = fields[0..nf];
        const msgtype = core.getField(fslice, 35) orelse return error.MissingMsgType;
        const symbol = core.getField(fslice, 55) orelse "(missing)";
        const qty = core.getField(fslice, 38) orelse "(missing)";
        std.debug.print("client: recv echo 35={s} symbol={s} qty={s}\n", .{ msgtype, symbol, qty });
    }

    // Logout
    {
        const n = try core.buildMessage(&out_buf, COMP_ID, target, seq_out, "5", &.{});
        seq_out += 1;
        try wr.interface.writeAll(out_buf[0..n]);
        try wr.interface.flush();
        std.debug.print("client: sent Logout\n", .{});
    }

    // Receive Logout response.
    {
        const raw = try recvMessage(&rd.interface, &recv_buf, &recv_len);
        var fields: [core.MAX_FIELDS]core.Field = undefined;
        const nf = try core.parseFields(raw, &fields);
        const msgtype = core.getField(fields[0..nf], 35) orelse return error.MissingMsgType;
        if (!std.mem.eql(u8, msgtype, "5")) return error.ExpectedLogout;
        std.debug.print("client: recv Logout — session complete\n", .{});
    }
}

/// Read bytes from rd until a complete FIX message is found.
/// recv_buf is the accumulation buffer. recv_len tracks how many bytes are filled.
///
/// Return:
/// - ![]const u8 (slice into recv_buf containing exactly one complete message)
fn recvMessage(
    rd: *std.Io.Reader,
    recv_buf: []u8,
    recv_len: *usize,
) ![]const u8 {
    while (true) {
        if (core.findMessageEnd(recv_buf[0..recv_len.*])) |end| {
            const msg = recv_buf[0..end];
            const remaining = recv_len.* - end;
            if (remaining > 0) {
                std.mem.copyForwards(u8, recv_buf[0..remaining], recv_buf[end..recv_len.*]);
            }
            recv_len.* = remaining;
            return msg;
        }
        if (recv_len.* >= recv_buf.len) return error.MessageTooLarge;
        const b = try rd.takeByte();
        recv_buf[recv_len.*] = b;
        recv_len.* += 1;
    }
}
