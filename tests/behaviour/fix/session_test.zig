//! Behaviour tests: observable FIX session contract.
//! Verifies: Logon response fields, echo body preservation, clean Logout.

const std = @import("std");
const zix = @import("zix");

const TEST_PORT: u16 = 19640;

// --------------------------------------------------------- //

const ServerCtx = struct {
    listener: std.Io.net.Server,
    err: ?anyerror = null,
};

fn runServer(ctx: *ServerCtx, io: std.Io) void {
    const stream = ctx.listener.accept(io) catch |e| {
        ctx.err = e;
        return;
    };
    zix.Fix.serveConn(stream, io, "SERVER", .{}) catch |e| {
        if (e != error.ConnectionClosed and e != error.BrokenPipe) ctx.err = e;
    };
}

fn setup(io: std.Io, ctx: *ServerCtx, port: u16) !std.Thread {
    ctx.err = null;
    const addr = try std.Io.net.IpAddress.resolve(io, "127.0.0.1", port);
    ctx.listener = try addr.listen(io, .{
        .reuse_address = true,
        .kernel_backlog = 4,
    });
    return std.Thread.spawn(.{ .stack_size = 512 * 1024 }, runServer, .{ ctx, io });
}

fn recvMsg(
    rd: *std.Io.Reader,
    recv_buf: []u8,
    recv_len: *usize,
    out_fields: []zix.Fix.Field,
) !usize {
    while (true) {
        if (zix.Fix.findMessageEnd(recv_buf[0..recv_len.*])) |end| {
            const raw = recv_buf[0..end];
            const nf = try zix.Fix.parseFields(raw, out_fields);
            const remaining = recv_len.* - end;
            if (remaining > 0) {
                std.mem.copyForwards(u8, recv_buf[0..remaining], recv_buf[end..recv_len.*]);
            }
            recv_len.* = remaining;
            return nf;
        }
        if (recv_len.* >= recv_buf.len) return error.MessageTooLarge;
        const b = try rd.takeByte();
        recv_buf[recv_len.*] = b;
        recv_len.* += 1;
    }
}

fn sendMsg(
    wr: anytype,
    out_buf: []u8,
    sender: []const u8,
    target: []const u8,
    seq: *u32,
    msgtype: []const u8,
    extra: []const zix.Fix.BuildField,
) !void {
    const n = try zix.Fix.buildMessage(out_buf, sender, target, seq.*, msgtype, extra);
    seq.* += 1;
    try wr.interface.writeAll(out_buf[0..n]);
    try wr.interface.flush();
}

// --------------------------------------------------------- //

test "zix behaviour: Logon response has MsgType=A and CompIDs swapped" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .stack_size = 512 * 1024 });
    defer threaded.deinit();
    const io = threaded.io();

    var ctx: ServerCtx = undefined;
    const t = try setup(io, &ctx, TEST_PORT);

    const sa = try std.Io.net.IpAddress.resolve(io, "127.0.0.1", TEST_PORT);
    const stream = try sa.connect(io, .{ .mode = .stream });
    defer stream.close(io);

    var rd_buf: [zix.Fix.MAX_MSG_SIZE]u8 = undefined;
    var wr_buf: [zix.Fix.MAX_MSG_SIZE]u8 = undefined;
    var rd = stream.reader(io, &rd_buf);
    var wr = stream.writer(io, &wr_buf);
    var recv_buf: [zix.Fix.MAX_MSG_SIZE * 2]u8 = undefined;
    var recv_len: usize = 0;
    var out_buf: [zix.Fix.MAX_MSG_SIZE]u8 = undefined;
    var fields: [zix.Fix.MAX_FIELDS]zix.Fix.Field = undefined;
    var seq: u32 = 1;

    try sendMsg(&wr, &out_buf, "CLIENT", "SERVER", &seq, "A", &.{
        .{ .tag = 98, .value = "0" }, .{ .tag = 108, .value = "30" },
    });
    const nf = try recvMsg(&rd.interface, &recv_buf, &recv_len, &fields);
    const fslice = fields[0..nf];

    try std.testing.expectEqualStrings("A", zix.Fix.getField(fslice, 35).?);
    try std.testing.expectEqualStrings("SERVER", zix.Fix.getField(fslice, 49).?);
    try std.testing.expectEqualStrings("CLIENT", zix.Fix.getField(fslice, 56).?);
    try std.testing.expectEqualStrings("1", zix.Fix.getField(fslice, 34).?);

    try sendMsg(&wr, &out_buf, "CLIENT", "SERVER", &seq, "5", &.{});
    _ = try recvMsg(&rd.interface, &recv_buf, &recv_len, &fields);

    t.join();
    ctx.listener.deinit(io);
    try std.testing.expect(ctx.err == null);
}

test "zix behaviour: NewOrderSingle body fields are preserved in echo" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .stack_size = 512 * 1024 });
    defer threaded.deinit();
    const io = threaded.io();

    var ctx: ServerCtx = undefined;
    const t = try setup(io, &ctx, TEST_PORT + 1);

    const sa = try std.Io.net.IpAddress.resolve(io, "127.0.0.1", TEST_PORT + 1);
    const stream = try sa.connect(io, .{ .mode = .stream });
    defer stream.close(io);

    var rd_buf: [zix.Fix.MAX_MSG_SIZE]u8 = undefined;
    var wr_buf: [zix.Fix.MAX_MSG_SIZE]u8 = undefined;
    var rd = stream.reader(io, &rd_buf);
    var wr = stream.writer(io, &wr_buf);
    var recv_buf: [zix.Fix.MAX_MSG_SIZE * 2]u8 = undefined;
    var recv_len: usize = 0;
    var out_buf: [zix.Fix.MAX_MSG_SIZE]u8 = undefined;
    var fields: [zix.Fix.MAX_FIELDS]zix.Fix.Field = undefined;
    var seq: u32 = 1;

    try sendMsg(&wr, &out_buf, "CLIENT", "SERVER", &seq, "A", &.{
        .{ .tag = 98, .value = "0" }, .{ .tag = 108, .value = "30" },
    });
    _ = try recvMsg(&rd.interface, &recv_buf, &recv_len, &fields);

    try sendMsg(&wr, &out_buf, "CLIENT", "SERVER", &seq, "D", &.{
        .{ .tag = 11, .value = "ORD999" },
        .{ .tag = 55, .value = "GOOG" },
        .{ .tag = 54, .value = "2" },
        .{ .tag = 38, .value = "500" },
    });
    const nf = try recvMsg(&rd.interface, &recv_buf, &recv_len, &fields);
    const fslice = fields[0..nf];

    try std.testing.expectEqualStrings("D", zix.Fix.getField(fslice, 35).?);
    try std.testing.expectEqualStrings("ORD999", zix.Fix.getField(fslice, 11).?);
    try std.testing.expectEqualStrings("GOOG", zix.Fix.getField(fslice, 55).?);
    try std.testing.expectEqualStrings("2", zix.Fix.getField(fslice, 54).?);
    try std.testing.expectEqualStrings("500", zix.Fix.getField(fslice, 38).?);

    try sendMsg(&wr, &out_buf, "CLIENT", "SERVER", &seq, "5", &.{});
    _ = try recvMsg(&rd.interface, &recv_buf, &recv_len, &fields);

    t.join();
    ctx.listener.deinit(io);
    try std.testing.expect(ctx.err == null);
}

test "zix behaviour: clean Logout causes no server-side error" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .stack_size = 512 * 1024 });
    defer threaded.deinit();
    const io = threaded.io();

    var ctx: ServerCtx = undefined;
    const t = try setup(io, &ctx, TEST_PORT + 2);

    const sa = try std.Io.net.IpAddress.resolve(io, "127.0.0.1", TEST_PORT + 2);
    const stream = try sa.connect(io, .{ .mode = .stream });
    defer stream.close(io);

    var rd_buf: [zix.Fix.MAX_MSG_SIZE]u8 = undefined;
    var wr_buf: [zix.Fix.MAX_MSG_SIZE]u8 = undefined;
    var rd = stream.reader(io, &rd_buf);
    var wr = stream.writer(io, &wr_buf);
    var recv_buf: [zix.Fix.MAX_MSG_SIZE * 2]u8 = undefined;
    var recv_len: usize = 0;
    var out_buf: [zix.Fix.MAX_MSG_SIZE]u8 = undefined;
    var fields: [zix.Fix.MAX_FIELDS]zix.Fix.Field = undefined;
    var seq: u32 = 1;

    try sendMsg(&wr, &out_buf, "CLIENT", "SERVER", &seq, "A", &.{
        .{ .tag = 98, .value = "0" }, .{ .tag = 108, .value = "30" },
    });
    _ = try recvMsg(&rd.interface, &recv_buf, &recv_len, &fields);

    try sendMsg(&wr, &out_buf, "CLIENT", "SERVER", &seq, "5", &.{});
    const nf = try recvMsg(&rd.interface, &recv_buf, &recv_len, &fields);
    try std.testing.expectEqualStrings("5", zix.Fix.getField(fields[0..nf], 35).?);

    t.join();
    ctx.listener.deinit(io);
    try std.testing.expect(ctx.err == null);
}
