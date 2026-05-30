const std = @import("std");
const zix = @import("zix");

const DEFAULT_IP: []const u8 = "127.0.0.1";
const DEFAULT_PORT: u16 = 9500;
const DEFAULT_TARGET: []const u8 = "ZIX";
const COMP_ID: []const u8 = "CLIENT";

// --------------------------------------------------------- //

// Usage:
//   zig build example-fix_client
//   zig build example-fix_client -- --port 9500 --target ZIX

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

    var rd_buf: [zix.Fix.MAX_MSG_SIZE]u8 = undefined;
    var wr_buf: [zix.Fix.MAX_MSG_SIZE]u8 = undefined;
    var reader = stream.reader(io, &rd_buf);
    var writer = stream.writer(io, &wr_buf);

    var seq_out: u32 = 1;
    var out_buf: [zix.Fix.MAX_MSG_SIZE]u8 = undefined;
    var recv_buf: [zix.Fix.MAX_MSG_SIZE * 2]u8 = undefined;
    var recv_len: usize = 0;

    // Logon
    {
        const extra = [_]zix.Fix.BuildField{
            .{ .tag = .EncryptMethod, .value = "0" },
            .{ .tag = .HeartBtInt, .value = "30" },
        };
        const n = try zix.Fix.buildMessage(&out_buf, COMP_ID, target, seq_out, "A", &extra);
        seq_out += 1;
        try writer.interface.writeAll(out_buf[0..n]);
        try writer.interface.flush();
        std.debug.print("client: sent Logon\n", .{});
    }

    // Receive Logon response.
    {
        const raw = try recvMessage(&reader.interface, &recv_buf, &recv_len);
        var fields: [zix.Fix.MAX_FIELDS]zix.Fix.Field = undefined;
        const nf = try zix.Fix.parseFields(raw, &fields);
        const msgtype = zix.Fix.getField(fields[0..nf], .MsgType) orelse return error.MissingMsgType;
        if (!std.mem.eql(u8, msgtype, "A")) return error.ExpectedLogon;
        std.debug.print("client: recv Logon from server\n", .{});
    }

    // Send NewOrderSingle (35=D)
    {
        const extra = [_]zix.Fix.BuildField{
            .{ .tag = .ClOrdID, .value = "ORD001" },
            .{ .tag = .Symbol, .value = "AAPL" },
            .{ .tag = .Side, .value = "1" },
            .{ .tag = .OrderQty, .value = "100" },
            .{ .tag = .OrdType, .value = "2" },
            .{ .tag = .Price, .value = "150.00" },
        };
        const n = try zix.Fix.buildMessage(&out_buf, COMP_ID, target, seq_out, "D", &extra);
        seq_out += 1;
        try writer.interface.writeAll(out_buf[0..n]);
        try writer.interface.flush();
        std.debug.print("client: sent NewOrderSingle\n", .{});
    }

    // Receive echo.
    {
        const raw = try recvMessage(&reader.interface, &recv_buf, &recv_len);
        var fields: [zix.Fix.MAX_FIELDS]zix.Fix.Field = undefined;
        const nf = try zix.Fix.parseFields(raw, &fields);
        const fslice = fields[0..nf];
        const msgtype = zix.Fix.getField(fslice, .MsgType) orelse return error.MissingMsgType;
        const symbol = zix.Fix.getField(fslice, .Symbol) orelse "(missing)";
        const qty = zix.Fix.getField(fslice, .OrderQty) orelse "(missing)";
        std.debug.print("client: recv echo 35={s} symbol={s} qty={s}\n", .{ msgtype, symbol, qty });
    }

    // Logout
    {
        const n = try zix.Fix.buildMessage(&out_buf, COMP_ID, target, seq_out, "5", &.{});
        seq_out += 1;
        try writer.interface.writeAll(out_buf[0..n]);
        try writer.interface.flush();
        std.debug.print("client: sent Logout\n", .{});
    }

    // Receive Logout response.
    {
        const raw = try recvMessage(&reader.interface, &recv_buf, &recv_len);
        var fields: [zix.Fix.MAX_FIELDS]zix.Fix.Field = undefined;
        const nf = try zix.Fix.parseFields(raw, &fields);
        const msgtype = zix.Fix.getField(fields[0..nf], .MsgType) orelse return error.MissingMsgType;
        if (!std.mem.eql(u8, msgtype, "5")) return error.ExpectedLogout;
        std.debug.print("client: recv Logout — session complete\n", .{});
    }
}

fn recvMessage(
    reader: *std.Io.Reader,
    recv_buf: []u8,
    recv_len: *usize,
) ![]const u8 {
    while (true) {
        if (zix.Fix.findMessageEnd(recv_buf[0..recv_len.*])) |end| {
            const msg = recv_buf[0..end];
            const remaining = recv_len.* - end;
            if (remaining > 0) {
                std.mem.copyForwards(u8, recv_buf[0..remaining], recv_buf[end..recv_len.*]);
            }
            recv_len.* = remaining;
            return msg;
        }
        if (recv_len.* >= recv_buf.len) return error.MessageTooLarge;
        const b = try reader.takeByte();
        recv_buf[recv_len.*] = b;
        recv_len.* += 1;
    }
}
