//! Integration tests: FIX session round-trips and FixServer lifecycle.

const std = @import("std");
const zix = @import("zix");

const TEST_PORT: u16 = 19630;

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

fn spawnServer(ctx: *ServerCtx, io: std.Io, port: u16) !std.Thread {
    ctx.err = null;
    const addr = try std.Io.net.IpAddress.resolve(io, "127.0.0.1", port);
    ctx.listener = try addr.listen(io, .{
        .reuse_address = true,
        .kernel_backlog = 4,
    });
    return std.Thread.spawn(.{ .stack_size = 512 * 1024 }, runServer, .{ ctx, io });
}

fn sendAndRecv(
    wr: anytype,
    rd_interface: *std.Io.Reader,
    recv_buf: []u8,
    recv_len: *usize,
    out_buf: []u8,
    sender: []const u8,
    target: []const u8,
    seq: *u32,
    msgtype: []const u8,
    extra: []const zix.Fix.BuildField,
    reply_fields: []zix.Fix.Field,
) !usize {
    const n = try zix.Fix.buildMessage(out_buf, sender, target, seq.*, msgtype, extra);
    seq.* += 1;
    try wr.interface.writeAll(out_buf[0..n]);
    try wr.interface.flush();
    return recvMsg(rd_interface, recv_buf, recv_len, reply_fields);
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

// --------------------------------------------------------- //

test "zix integration: FixServer init and deinit do not error" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var server = try zix.Fix.Server.init(&.{}, .{ .io = io, .ip = "127.0.0.1", .port = 9500, .comp_id = "SERVER", .dispatch_model = .ASYNC });
    server.deinit();
}

test "zix integration: FixServer EPOLL dispatch model init succeeds and deinit is safe" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var server = try zix.Fix.Server.init(&.{}, .{
        .io = io,
        .ip = "127.0.0.1",
        .port = 9500,
        .comp_id = "SERVER",
        .dispatch_model = .EPOLL,
        .workers = 2,
    });
    server.deinit();
    try std.testing.expectEqual(@as(usize, 2), server.config.workers);
}

test "zix integration: FixServer init, port zero returns PortNotConfigured" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    try std.testing.expectError(
        error.PortNotConfigured,
        zix.Fix.Server.init(&.{}, .{ .io = io, .ip = "127.0.0.1", .port = 0, .comp_id = "SERVER", .dispatch_model = .ASYNC }),
    );
}

test "zix integration: Logon handshake and echo round-trip succeed" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .stack_size = 512 * 1024 });
    defer threaded.deinit();
    const io = threaded.io();

    var ctx: ServerCtx = undefined;
    const thread = try spawnServer(&ctx, io, TEST_PORT);

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

    const logon_nf = try sendAndRecv(
        &wr,
        &rd.interface,
        &recv_buf,
        &recv_len,
        &out_buf,
        "CLIENT",
        "SERVER",
        &seq,
        "A",
        &.{ .{ .tag = .EncryptMethod, .value = "0" }, .{ .tag = .HeartBtInt, .value = "30" } },
        &fields,
    );
    try std.testing.expectEqualStrings("A", zix.Fix.getField(fields[0..logon_nf], .MsgType).?);

    const echo_nf = try sendAndRecv(
        &wr,
        &rd.interface,
        &recv_buf,
        &recv_len,
        &out_buf,
        "CLIENT",
        "SERVER",
        &seq,
        "D",
        &.{ .{ .tag = .ClOrdID, .value = "ORD001" }, .{ .tag = .Symbol, .value = "AAPL" } },
        &fields,
    );
    try std.testing.expectEqualStrings("D", zix.Fix.getField(fields[0..echo_nf], .MsgType).?);
    try std.testing.expectEqualStrings("ORD001", zix.Fix.getField(fields[0..echo_nf], .ClOrdID).?);
    try std.testing.expectEqualStrings("AAPL", zix.Fix.getField(fields[0..echo_nf], .Symbol).?);

    const logout_nf = try sendAndRecv(
        &wr,
        &rd.interface,
        &recv_buf,
        &recv_len,
        &out_buf,
        "CLIENT",
        "SERVER",
        &seq,
        "5",
        &.{},
        &fields,
    );
    try std.testing.expectEqualStrings("5", zix.Fix.getField(fields[0..logout_nf], .MsgType).?);

    thread.join();
    ctx.listener.deinit(io);
    try std.testing.expect(ctx.err == null);
}

test "zix integration: multiple sequential messages are all echoed" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .stack_size = 512 * 1024 });
    defer threaded.deinit();
    const io = threaded.io();

    var ctx: ServerCtx = undefined;
    const thread = try spawnServer(&ctx, io, TEST_PORT + 1);

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

    _ = try sendAndRecv(
        &wr,
        &rd.interface,
        &recv_buf,
        &recv_len,
        &out_buf,
        "CLIENT",
        "SERVER",
        &seq,
        "A",
        &.{ .{ .tag = .EncryptMethod, .value = "0" }, .{ .tag = .HeartBtInt, .value = "30" } },
        &fields,
    );

    const order_ids = [_][]const u8{ "ORD001", "ORD002", "ORD003" };
    for (order_ids) |oid| {
        const nf = try sendAndRecv(
            &wr,
            &rd.interface,
            &recv_buf,
            &recv_len,
            &out_buf,
            "CLIENT",
            "SERVER",
            &seq,
            "D",
            &.{.{ .tag = .ClOrdID, .value = oid }},
            &fields,
        );
        try std.testing.expectEqualStrings("D", zix.Fix.getField(fields[0..nf], .MsgType).?);
        try std.testing.expectEqualStrings(oid, zix.Fix.getField(fields[0..nf], .ClOrdID).?);
    }

    _ = try sendAndRecv(
        &wr,
        &rd.interface,
        &recv_buf,
        &recv_len,
        &out_buf,
        "CLIENT",
        "SERVER",
        &seq,
        "5",
        &.{},
        &fields,
    );

    thread.join();
    ctx.listener.deinit(io);
    try std.testing.expect(ctx.err == null);
}

test "zix integration: FixClient, recv_timeout_ms fires when server sends no data" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const addr = try std.Io.net.IpAddress.resolve(io, "127.0.0.1", 9541);
    var stall_listener = try addr.listen(io, .{
        .mode = .stream,
        .reuse_address = true,
        .kernel_backlog = 4,
    });
    defer stall_listener.deinit(io);

    var client = try zix.Fix.Client.connect(.{
        .ip = "127.0.0.1",
        .port = 9541,
        .comp_id = "CLIENT",
        .target_comp_id = "SERVER",
        .recv_timeout_ms = 200,
    }, io);
    defer client.deinit(io);

    const result = client.recvMessage(io);
    if (result) |_| return error.ExpectedRecvTimeout else |_| {}
}
